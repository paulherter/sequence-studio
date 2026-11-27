/// FFmpeg's GPU decoder on this system: D3D11VA on Windows, VA-API on Linux (the Mac decodes through VideoToolbox, another crate).
pub const HARDWARE_API: &str = if cfg!(windows) { "d3d11va" } else { "vaapi" };

/// Whether FFmpeg has a GPU decoder to try on this system.
pub const HARDWARE_PATH: bool = cfg!(any(windows, target_os = "linux"));

/// Whether a decoded frame holds a texture of the decoder's pool until it is dropped (D3D11VA). VA-API surfaces are copied to
/// memory as they leave the decoder, so a call may hold any number of frames.
pub const HOLDS_POOL: bool = cfg!(windows);

/// The `extra_hw_frames` to open a decoder with: the caller's headroom where frames hold the pool, two spare surfaces otherwise.
pub fn pool_frames(requested: i32) -> i32 {
    if HOLDS_POOL { requested } else { requested.min(2) }
}

/// Pictures below this many pixels decode in software where the GPU's decoder is one shared engine (Linux): measured on an
/// RX 9070 XT, one 4K 10-bit HEVC picture takes the engine 18 ms (software: 34 ms on a core), so four more 1080p H.264
/// lanes on it queued every lane past the 33 ms frame period (decode 25 ms per 1080p picture against 13 ms in software, and
/// the 4K lane at 36 ms). The big picture is what software cannot carry, so it gets the engine; small ones stay on the CPU.
/// Windows keeps every stream on the GPU as before (not measured there). `SQ_HW_MIN_PIXELS` overrides (0: all on the GPU).
pub const DEFAULT_MIN_HARDWARE_PIXELS: u64 = if cfg!(windows) { 0 } else { 3_000_000 };

/// Whether a `width` x `height` stream is big enough for the GPU decoder under the `SQ_HW_MIN_PIXELS` rule.
pub fn big_enough_for_hardware(width: i64, height: i64) -> bool {
    let min = std::env::var("SQ_HW_MIN_PIXELS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(DEFAULT_MIN_HARDWARE_PIXELS);
    u64::try_from(width.max(0)).unwrap_or(0) * u64::try_from(height.max(0)).unwrap_or(0) >= min
}

/// Which video streams the GPU decoder opens. Hardware video decoders on PCs take 4:2:0 only, and H.264 only at 8 bits:
/// a 4K 4:2:2 10-bit H.264 clip opened the GPU decoder, failed on its first packet and fell back to software while the hardware
/// flag (the proxy Auto rule's input) said hardware until then. Those streams open the software decoder at once.
/// `codec`: FFmpeg codec name; `pixel_format`: the stream's pixel format name ("unknown" when not probed).
pub fn supports_hardware_decode(codec: &str, pixel_format: &str) -> bool {
    const CODECS: [&str; 8] = ["h264", "hevc", "av1", "vp9", "vp8", "mpeg2video", "vc1", "wmv3"];
    const EIGHT_BIT: [&str; 3] = ["yuv420p", "yuvj420p", "nv12"];
    const TEN_BIT: [&str; 3] = ["yuv420p10le", "yuv420p10be", "p010le"];
    if !CODECS.contains(&codec) {
        return false;
    }
    if pixel_format == "unknown" || pixel_format.is_empty() {
        return true;
    }
    if codec == "h264" {
        return EIGHT_BIT.contains(&pixel_format);
    }
    EIGHT_BIT.contains(&pixel_format) || TEN_BIT.contains(&pixel_format)
}

/// Hardware decoder sessions open at once in this process. Every D3D11VA decoder owns a texture pool and a driver
/// session; past the limit a new decoder opens in software (a project with many layers of different media) instead of
/// failing on its first packet and leaving the playback without that layer. `SQ_MAX_HW_DECODERS` overrides the default.
pub const DEFAULT_MAX_HARDWARE_SESSIONS: usize = 8;

/// The count of open hardware sessions behind a limit.
#[derive(Debug)]
pub struct HardwareSessions {
    max: usize,
    open: std::sync::atomic::AtomicUsize,
    /// Pixels per second the open sessions decode (width x height x frame rate): the load on the one decode engine.
    load: std::sync::atomic::AtomicU64,
}

/// One open hardware session; dropping it frees the slot.
#[derive(Debug)]
pub struct SessionGuard<'a>(&'a HardwareSessions, u64);

impl HardwareSessions {
    pub const fn new(max: usize) -> HardwareSessions {
        HardwareSessions {
            max,
            open: std::sync::atomic::AtomicUsize::new(0),
            load: std::sync::atomic::AtomicU64::new(0),
        }
    }

    /// A slot, or `None` when `max` sessions are open.
    pub fn acquire(&self) -> Option<SessionGuard<'_>> {
        self.acquire_up_to(self.max)
    }

    /// A slot, or `None` when `limit` sessions are open: the caller's limit instead of `max` (the environment's override).
    pub fn acquire_up_to(&self, limit: usize) -> Option<SessionGuard<'_>> {
        use std::sync::atomic::Ordering::AcqRel;
        let taken =
            self.open.try_update(AcqRel, std::sync::atomic::Ordering::Acquire, |n| (n < limit).then_some(n + 1));
        taken.ok().map(|_| SessionGuard(self, 0))
    }

    /// A slot for a stream of `rate` pixels per second, or `None` when the session limit is reached or the engine's
    /// `budget` is used up. The first stream of the engine always gets it (a lone 4K60 clip stays on the GPU).
    pub fn acquire_loaded(&self, limit: usize, rate: u64, budget: u64) -> Option<SessionGuard<'_>> {
        use std::sync::atomic::Ordering::{AcqRel, Acquire};
        self.load
            .try_update(AcqRel, Acquire, |l| (l == 0 || l.saturating_add(rate) <= budget).then_some(l + rate))
            .ok()?;
        match self.acquire_up_to(limit) {
            Some(mut g) => {
                g.1 = rate;
                Some(g)
            }
            None => {
                self.load.fetch_sub(rate, AcqRel);
                None
            }
        }
    }

    /// Pixels per second of the open sessions.
    pub fn load(&self) -> u64 {
        self.load.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Sessions open right now.
    pub fn open(&self) -> usize {
        self.open.load(std::sync::atomic::Ordering::Relaxed)
    }
}

impl Drop for SessionGuard<'_> {
    fn drop(&mut self) {
        self.0.open.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
        self.0.load.fetch_sub(self.1, std::sync::atomic::Ordering::AcqRel);
    }
}

/// Consecutive failed downloads of a hardware decoder's pictures before the stream moves to software.
pub const DOWNLOAD_FAILURES_BEFORE_SOFTWARE: usize = 3;

/// Counts the failed downloads of one stream in a row (`report` returns true once the limit is reached).
#[derive(Debug, Default)]
pub struct DownloadWatch(std::sync::atomic::AtomicUsize);

impl DownloadWatch {
    /// `ok`: a picture came out; a success resets the run. True when this failure is the `limit`-th in a row.
    pub fn report(&self, ok: bool, limit: usize) -> bool {
        use std::sync::atomic::Ordering::Relaxed;
        if ok {
            if self.0.load(Relaxed) != 0 {
                self.0.store(0, Relaxed);
            }
            return false;
        }
        self.0.fetch_add(1, Relaxed) + 1 == limit
    }
}

static SESSIONS: HardwareSessions = HardwareSessions::new(DEFAULT_MAX_HARDWARE_SESSIONS);

/// The most `SQ_MAX_HW_DECODERS` may allow: a D3D11VA session owns a texture pool and a driver session, so an unbounded count
/// would only trade a software fallback for out-of-memory.
pub const MAX_HARDWARE_SESSIONS_OVERRIDE: usize = 32;

/// The session limit for the `SQ_MAX_HW_DECODERS` value `text`: a number from 1 to [`MAX_HARDWARE_SESSIONS_OVERRIDE`] (larger
/// ones are cut to it); a missing value, 0 and junk keep [`DEFAULT_MAX_HARDWARE_SESSIONS`].
pub fn session_limit(text: Option<&str>) -> usize {
    match text.and_then(|v| v.trim().parse::<usize>().ok()).filter(|n| *n > 0) {
        Some(n) => n.min(MAX_HARDWARE_SESSIONS_OVERRIDE),
        None => default_session_limit(tier_memory()),
    }
}

/// The RAM tiers apply where the hardware decoder pools surfaces out of shared system memory. Only the Windows path
/// (D3D11VA, `HOLDS_POOL`) was measured so; VA-API on Linux and VideoToolbox (not on this path) keep the plain defaults.
// shortcut: Windows stands for "integrated GPU"; a discrete GPU there also gets the tiers on <= 16 GB. Upgrade to the DXGI
// adapter's DedicatedVideoMemory once the app reports it here.
const SHARED_MEMORY_POOLS: bool = HOLDS_POOL;

/// Physical memory of the machine in bytes, 0 until the app reports it ([`set_machine_memory`]).
static MACHINE_MEMORY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// The app reports the machine's RAM once at start so the default session limit can follow it.
pub fn set_machine_memory(bytes: u64) {
    MACHINE_MEMORY.store(bytes, std::sync::atomic::Ordering::Relaxed);
}

/// Sessions allowed without an override. Each D3D11VA session pools 4K P010 surfaces (about 25 MB each, 20 or more per
/// session) out of the iGPU's shared system RAM: 8 sessions on an 8 GB machine pushed the guest to 11 GB committed and
/// 2-6 % of the frames at 4 layers of 4K effects, 2 sessions played 59-73 % (win11-vm, notes/tempo/win-fx4k-2026-11-24.md).
/// Unknown memory (0) keeps the plain default.
// shortcut: memory tiers by guess; upgrade to counting the pooled surface bytes against the free GPU memory.
pub fn default_session_limit(memory_bytes: u64) -> usize {
    const GIB: u64 = 1 << 30;
    match memory_bytes {
        0 => DEFAULT_MAX_HARDWARE_SESSIONS,
        m if m <= 8 * GIB => 2,
        m if m <= 16 * GIB => 4,
        _ => DEFAULT_MAX_HARDWARE_SESSIONS,
    }
}

/// Pooled hardware frames beyond the decoder's references, from the same memory tiers: 12 up to 16 GB, the plain
/// `default_extra` above. win11-vm (8 GB, 2 sessions, carry follows the pool): extra 12 played 14 of 15 runs >= 93 %
/// (one 60 %), 8 about 3 of 4, 10 and 16 one or two bad runs in 5, 5 mostly bad; the pool must stay deep enough for
/// the carry plus a call's frames more than it must be small (notes/tempo/win-fx4k-2026-11-24.md round 5).
/// Unknown memory (0) keeps `default_extra`.
pub fn default_extra_hw_frames(memory_bytes: u64, default_extra: i32) -> i32 {
    const GIB: u64 = 1 << 30;
    match memory_bytes {
        0 => default_extra,
        m if m <= 8 * GIB => default_extra.min(12),
        m if m <= 16 * GIB => default_extra.min(12),
        _ => default_extra,
    }
}

/// The memory the RAM tiers see: the machine's where surfaces come from shared system memory, else 0 (plain defaults).
pub fn tier_memory() -> u64 {
    if SHARED_MEMORY_POOLS { machine_memory() } else { 0 }
}

/// The machine memory the app reported ([`set_machine_memory`]), 0 if none.
pub fn machine_memory() -> u64 {
    MACHINE_MEMORY.load(std::sync::atomic::Ordering::Relaxed)
}

/// A slot in the process-wide limit (`SQ_MAX_HW_DECODERS` lowers or raises it, see [`session_limit`]).
pub fn acquire_hardware_session() -> Option<SessionGuard<'static>> {
    SESSIONS.acquire_up_to(session_limit(std::env::var("SQ_MAX_HW_DECODERS").ok().as_deref()))
}

/// Pixels per second the one GPU decode engine carries before more big streams go to the CPU. Measured on an RX 9070 XT
/// (VA-API, 4K H.264 at 100 Mbit/s): the engine decodes one picture at a time at 11 ms (3 streams in parallel take 33 ms
/// each, `ffmpeg -hwaccel vaapi`), so three 4K30 layers (747 Mpixel/s) never fit and dropped 26 % of the frames, while
/// one engine stream plus two software decoders played all 569. 400 Mpixel/s lets one 4K30 stream (249) in and sends the
/// second (498 together) to software. Windows keeps every stream on the GPU: measured on a Radeon 610M (D3D11VA) the engine carried 4 parallel 4K
/// H.264 streams at 99 % shown, and a 400 budget dropped it to 64 % (notes/tempo/winbudget-2026-11-24.md).
/// `SQ_HW_BUDGET_MPIX` overrides (0 = no budget).
pub const DEFAULT_ENGINE_BUDGET: u64 = if cfg!(windows) { u64::MAX } else { 400_000_000 };

/// The engine budget in pixels per second for the `SQ_HW_BUDGET_MPIX` value `text`.
pub fn engine_budget(text: Option<&str>) -> u64 {
    match text.and_then(|v| v.trim().parse::<u64>().ok()) {
        Some(0) => u64::MAX,
        Some(m) => m.saturating_mul(1_000_000),
        None => DEFAULT_ENGINE_BUDGET,
    }
}

/// A slot for a stream of `rate` pixels per second inside the engine budget.
pub fn acquire_hardware_session_for(rate: u64) -> Option<SessionGuard<'static>> {
    SESSIONS.acquire_loaded(
        session_limit(std::env::var("SQ_MAX_HW_DECODERS").ok().as_deref()),
        rate,
        engine_budget(std::env::var("SQ_HW_BUDGET_MPIX").ok().as_deref()),
    )
}

/// Hardware frames a call may hold at once: the decoder's texture pool has its own reference pictures plus
/// `extra_hw_frames`, and the carry of pictures past the range (`carry`) holds some of those. Holding more (30 frames of a
/// range returned in one list) ran the pool dry and the decoder failed.
pub fn hardware_hold_limit(extra_hw_frames: i32, carry: usize) -> usize {
    usize::try_from(extra_hw_frames).unwrap_or(0).saturating_sub(carry + 1).max(1)
}

/// Pictures a decoder may carry to the next call with `extra_hw_frames` pooled surfaces: at most half of them (so a call
/// can still hold `extra - carry - 1`, never forcing every range of two frames or more into software), at most `max`.
pub fn carry_limit(extra_hw_frames: i32, max: usize) -> usize {
    (usize::try_from(extra_hw_frames).unwrap_or(0) / 2).clamp(1, max)
}

/// How one `decode` call runs on a decoder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DecodePath {
    /// The decoder as it is.
    Open,
    /// A throw-away software decoder: the call returns the whole range as a list that a hardware pool cannot hold; the
    /// hardware decoder keeps its place and its session.
    OneShotSoftware,
}

/// Frames delivered one by one are downloaded as they come (the pool refills); a list is held until the call ends.
pub fn decode_path(hardware: bool, delivering: bool, range_len: usize, hold_limit: usize) -> DecodePath {
    if hardware && !delivering && range_len > hold_limit { DecodePath::OneShotSoftware } else { DecodePath::Open }
}

#[cfg(test)]
mod tests {
    use super::supports_hardware_decode as supports;
    use super::*;

    #[test]
    fn the_engine_budget_sends_the_streams_past_it_to_software_and_frees_on_drop() {
        let s = HardwareSessions::new(8);
        let k30 = 249_000_000;
        let a = s.acquire_loaded(8, k30, 400_000_000);
        assert!(a.is_some(), "the first stream always gets the engine");
        assert!(s.acquire_loaded(8, k30, 400_000_000).is_none(), "498 Mpixel/s is over the budget");
        assert_eq!(s.open(), 1);
        assert_eq!(s.load(), k30);
        let small = s.acquire_loaded(8, 62_000_000, 400_000_000);
        assert!(small.is_some(), "a small stream still fits");
        drop(a);
        assert_eq!(s.load(), 62_000_000);
        let lone = HardwareSessions::new(8);
        assert!(lone.acquire_loaded(8, 498_000_000, 400_000_000).is_some(), "a lone 4K60 stays on the GPU");
    }

    #[test]
    fn a_run_of_failed_downloads_asks_for_software_once_and_a_success_resets_the_run() {
        let w = DownloadWatch::default();
        let n = DOWNLOAD_FAILURES_BEFORE_SOFTWARE;
        assert!((0..n - 1).all(|_| !w.report(false, n)));
        assert!(!w.report(true, n));
        assert!((0..n - 1).all(|_| !w.report(false, n)), "the success restarted the run");
        assert!(w.report(false, n), "the n-th failure in a row asks for software");
        assert!(!w.report(false, n), "and only once");
    }

    #[test]
    fn engine_budget_reads_the_override() {
        assert_eq!(engine_budget(Some("0")), u64::MAX);
        assert_eq!(engine_budget(Some("600")), 600_000_000);
        assert_eq!(engine_budget(Some("x")), DEFAULT_ENGINE_BUDGET);
        assert_eq!(engine_budget(None), DEFAULT_ENGINE_BUDGET);
    }

    #[test]
    fn sessions_stop_at_the_limit_and_free_a_slot_on_drop() {
        let s = HardwareSessions::new(2);
        let a = s.acquire();
        let b = s.acquire();
        assert!(a.is_some() && b.is_some());
        assert!(s.acquire().is_none(), "a third decoder opens in software");
        assert_eq!(s.open(), 2);
        drop(a);
        assert_eq!(s.open(), 1);
        assert!(s.acquire().is_some());
    }

    #[test]
    fn the_environment_override_can_raise_the_limit_but_only_to_a_bound() {
        assert_eq!(session_limit(None), DEFAULT_MAX_HARDWARE_SESSIONS);
        assert_eq!(session_limit(Some("12")), 12, "above the default of 8");
        assert_eq!(session_limit(Some("3")), 3, "and below it");
        assert_eq!(session_limit(Some("1000")), MAX_HARDWARE_SESSIONS_OVERRIDE);
        assert_eq!(session_limit(Some("0")), DEFAULT_MAX_HARDWARE_SESSIONS);
        const G: u64 = 1 << 30;
        assert_eq!(default_session_limit(0), DEFAULT_MAX_HARDWARE_SESSIONS, "unknown memory");
        assert_eq!(default_session_limit(8 * G), 2, "an 8 GB machine");
        assert_eq!(default_session_limit(16 * G), 4);
        assert_eq!(default_session_limit(32 * G), DEFAULT_MAX_HARDWARE_SESSIONS);
        assert_eq!(default_extra_hw_frames(0, 16), 16);
        assert_eq!(default_extra_hw_frames(8 * G, 16), 12);
        assert_eq!(default_extra_hw_frames(16 * G, 16), 12);
        assert_eq!(default_extra_hw_frames(32 * G, 16), 16);
        assert_eq!(default_extra_hw_frames(8 * G, 4), 4, "never raises a smaller default");
        assert_eq!(session_limit(Some("many")), DEFAULT_MAX_HARDWARE_SESSIONS);
        // A pool with the default maximum of 2 still opens a third session when the override says 3.
        let s = HardwareSessions::new(2);
        let held: Vec<_> = (0..3).filter_map(|_| s.acquire_up_to(session_limit(Some("3")))).collect();
        assert_eq!(held.len(), 3);
        assert!(s.acquire_up_to(3).is_none(), "the override is the ceiling");
    }

    #[test]
    fn sessions_count_across_threads() {
        let s = std::sync::Arc::new(HardwareSessions::new(5));
        let got: usize = (0..16)
            .map(|_| {
                let s = std::sync::Arc::clone(&s);
                std::thread::spawn(move || std::mem::forget(s.acquire()))
            })
            .map(|t| usize::from(t.join().is_ok()))
            .sum();
        assert_eq!(got, 16);
        assert_eq!(s.open(), 5, "never more than the limit, however the threads race");
    }

    #[test]
    fn a_range_wider_than_the_pool_headroom_decodes_in_software_once() {
        // 16 extra surfaces, 8 of them in the carry: 7 frames may be held by one call.
        let limit = hardware_hold_limit(16, 8);
        assert_eq!(limit, 7);
        assert_eq!(decode_path(true, false, 30, limit), DecodePath::OneShotSoftware, "30 frames exhaust the pool");
        assert_eq!(decode_path(true, false, 7, limit), DecodePath::Open);
        assert_eq!(decode_path(true, true, 30, limit), DecodePath::Open, "delivered frames are downloaded one by one");
        assert_eq!(decode_path(false, false, 30, limit), DecodePath::Open, "software has no pool");
        assert_eq!(hardware_hold_limit(0, 8), 1, "never below one frame");
    }

    #[test]
    fn small_machine_tiers_keep_ranges_in_hardware() {
        const GIB: u64 = 1 << 30;
        for mem in [4 * GIB, 8 * GIB, 16 * GIB, 64 * GIB] {
            let extra = default_extra_hw_frames(mem, 16);
            let carry = carry_limit(extra, 8);
            assert!(
                hardware_hold_limit(extra, carry) >= if extra >= 12 { 5 } else { 1 },
                "{mem}: extra {extra} carry {carry}"
            );
        }
        assert_eq!(carry_limit(16, 8), 8, "the default pool keeps the old carry");
        assert_eq!(hardware_hold_limit(16, carry_limit(16, 8)), 7);
        assert_eq!(hardware_hold_limit(12, carry_limit(12, 8)), 5);
    }

    #[test]
    fn only_big_pictures_take_the_shared_gpu_decoder_on_linux() {
        if cfg!(windows) {
            assert!(big_enough_for_hardware(640, 360), "Windows sends every stream to the GPU");
            return;
        }
        assert!(big_enough_for_hardware(3840, 2160));
        assert!(big_enough_for_hardware(2560, 1440));
        assert!(!big_enough_for_hardware(1920, 1080), "1080p is cheap in software and would queue behind the big one");
        assert!(!big_enough_for_hardware(0, 0));
    }

    #[test]
    fn four_two_zero_streams_of_hardware_codecs_go_to_the_gpu() {
        assert!(supports("h264", "yuv420p"));
        assert!(supports("h264", "yuvj420p"));
        assert!(supports("hevc", "yuv420p10le"));
        assert!(supports("av1", "yuv420p10le"));
        assert!(supports("vp9", "yuv420p"));
        assert!(supports("hevc", "unknown")); // not probed: let FFmpeg try
    }

    #[test]
    fn other_streams_open_the_software_decoder() {
        assert!(!supports("h264", "yuv422p10le")); // XAVC S 4:2:2 10-bit
        assert!(!supports("h264", "yuv420p10le")); // High 10
        assert!(!supports("hevc", "yuv422p10le"));
        assert!(!supports("hevc", "yuv444p"));
        assert!(!supports("prores", "yuv422p10le"));
        assert!(!supports("qtrle", "argb"));
        assert!(!supports("mjpeg", "yuvj420p"));
    }
}

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
}

/// One open hardware session; dropping it frees the slot.
#[derive(Debug)]
pub struct SessionGuard<'a>(&'a HardwareSessions);

impl HardwareSessions {
    pub const fn new(max: usize) -> HardwareSessions {
        HardwareSessions { max, open: std::sync::atomic::AtomicUsize::new(0) }
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
        taken.ok().map(|_| SessionGuard(self))
    }

    /// Sessions open right now.
    pub fn open(&self) -> usize {
        self.open.load(std::sync::atomic::Ordering::Relaxed)
    }
}

impl Drop for SessionGuard<'_> {
    fn drop(&mut self) {
        self.0.open.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
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
        None => DEFAULT_MAX_HARDWARE_SESSIONS,
    }
}

/// A slot in the process-wide limit (`SQ_MAX_HW_DECODERS` lowers or raises it, see [`session_limit`]).
pub fn acquire_hardware_session() -> Option<SessionGuard<'static>> {
    SESSIONS.acquire_up_to(session_limit(std::env::var("SQ_MAX_HW_DECODERS").ok().as_deref()))
}

/// Hardware frames a call may hold at once: the decoder's texture pool has its own reference pictures plus
/// `extra_hw_frames`, and the carry of pictures past the range (`carry`) holds some of those. Holding more (30 frames of a
/// range returned in one list) ran the pool dry and the decoder failed.
pub fn hardware_hold_limit(extra_hw_frames: i32, carry: usize) -> usize {
    usize::try_from(extra_hw_frames).unwrap_or(0).saturating_sub(carry + 1).max(1)
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

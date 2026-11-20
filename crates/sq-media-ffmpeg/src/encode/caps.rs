//! What each video encoder can do (a table by FFmpeg name), and what the encoder of THIS computer really did in a short
//! test (`probe`, run once per session). The export sheet shows an option the encoder cannot honor as not available on
//! this computer instead of writing a file that quietly ignores it.
//!
//! Bit depth and B-frames are measured, not looked up: whether a VA-API driver or a Media Foundation transform takes
//! them is not in the encoder's name. The rest (CBR, constant quality, multi-pass) follows from the encoder's own
//! rate-control modes, which `options.rs` maps.

use super::{EncodeConfig, Encoder, PixelLayout, Platform};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

/// What an encoder can do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EncoderCaps {
    pub hardware: bool,
    /// A target bitrate steers the file size (average bitrate / VBR with a cap).
    pub bitrate: bool,
    /// Constant bitrate.
    pub cbr: bool,
    /// A constant-quality mode with no bitrate target.
    pub constant_quality: bool,
    /// HEVC Main 10 (10-bit 4:2:0).
    pub ten_bit: bool,
    /// B-frames (frame reordering).
    pub b_frames: bool,
    /// The H.264 profiles Baseline, Main and High (an encoder that is not an H.264 one, or does not take a profile, writes
    /// whatever it writes).
    pub profile: bool,
    /// Several passes over the picture to hit the size (no encoder of our LGPL builds is driven that way).
    pub multi_pass: bool,
}

/// The table, by FFmpeg encoder name. `ten_bit` and `b_frames` say what the encoder can do at best; `probe` replaces
/// them with what this machine's driver did.
pub fn caps_of(name: &str) -> EncoderCaps {
    let hardware = ["_vaapi", "_nvenc", "_amf", "_qsv", "_mf", "_videotoolbox"].iter().any(|s| name.ends_with(s));
    let base = EncoderCaps {
        hardware,
        bitrate: true,
        cbr: true,
        constant_quality: true,
        ten_bit: false,
        b_frames: true,
        profile: true,
        multi_pass: false,
    };
    match name {
        // Hardware: 10-bit is HEVC Main 10 only.
        n if hardware => EncoderCaps { ten_bit: n.starts_with("hevc"), ..base },
        "libx265" => EncoderCaps { ten_bit: true, ..base },
        "libx264" => base,
        // OpenH264 has no B-frames and no 10-bit; its "bitrate" mode is the constant one.
        "libopenh264" => EncoderCaps { b_frames: false, ..base },
        // Kvazaar (HEVC) has a bitrate target and a QP, no constant bitrate, 8-bit only.
        "libkvazaar" => EncoderCaps { cbr: false, profile: false, ..base },
        // A name this table does not know promises only an average bitrate.
        _ => EncoderCaps { cbr: false, constant_quality: false, b_frames: false, profile: false, ..base },
    }
}

/// An option the encoder cannot honor.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Missing {
    /// No encoder of the chosen codec (and depth) opens on this computer: the export cannot run.
    Encoder,
    TenBit,
    BFrames,
    ConstantBitrate,
    ConstantQuality,
    MultiPass,
    /// The H.264 profile (Baseline, Main or High).
    Profile,
}

/// What the export asks for beyond a plain average bitrate.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Wish {
    pub ten_bit: bool,
    pub b_frames: bool,
    pub cbr: bool,
    pub constant_quality: bool,
    pub multi_pass: bool,
    /// An H.264 profile other than "the encoder decides".
    pub profile: bool,
}

/// The options of `wish` that `caps` cannot do, in a fixed order.
pub fn missing(caps: &EncoderCaps, wish: &Wish) -> Vec<Missing> {
    let mut out = Vec::new();
    let mut check = |wanted: bool, can: bool, what: Missing| {
        if wanted && !can {
            out.push(what);
        }
    };
    check(wish.ten_bit, caps.ten_bit, Missing::TenBit);
    check(wish.b_frames, caps.b_frames, Missing::BFrames);
    check(wish.cbr, caps.cbr, Missing::ConstantBitrate);
    check(wish.constant_quality, caps.constant_quality, Missing::ConstantQuality);
    check(wish.multi_pass, caps.multi_pass, Missing::MultiPass);
    check(wish.profile, caps.profile, Missing::Profile);
    out
}

/// One kind of video file the probe tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ProbeKind {
    pub hevc: bool,
    pub ten_bit: bool,
    /// Hardware encoders allowed.
    pub hardware: bool,
}

/// The encoder this computer opened for a `ProbeKind`, with what it did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Probe {
    /// FFmpeg name ("hevc_vaapi", "libkvazaar", ...).
    pub name: String,
    pub caps: EncoderCaps,
}

/// What the session knows about the encoder of one `ProbeKind`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProbeState {
    /// The probe has not run (yet): the sheet restricts nothing.
    Pending,
    /// The probe ran and no encoder of this kind opened: the sheet shows the choice as not available, the export refuses.
    NoEncoder,
    Found(Probe),
}

static CACHE: OnceLock<Mutex<HashMap<ProbeKind, Option<Probe>>>> = OnceLock::new();

fn cache() -> &'static Mutex<HashMap<ProbeKind, Option<Probe>>> {
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The result of an earlier `probe` or `warm_up`.
pub fn cached(kind: ProbeKind) -> ProbeState {
    match cache().lock().ok().and_then(|c| c.get(&kind).cloned()) {
        None => ProbeState::Pending,
        Some(None) => ProbeState::NoEncoder,
        Some(Some(p)) => ProbeState::Found(p),
    }
}

/// Opens the encoder for `kind` once per session and keeps the answer. Blocks for the first call of a kind (a hardware
/// encoder opens in tens of milliseconds, a software one writes a second of video); `warm_up` does it in the background.
pub fn probe(kind: ProbeKind) -> Option<Probe> {
    if let Some(known) = cache().lock().ok().and_then(|c| c.get(&kind).cloned()) {
        return known;
    }
    // Not probed here: no answer is kept, or "no encoder" would grey out every H.264 / HEVC choice of the sheet.
    if probe_is_off(crate::shim::AVAILABLE, Platform::current()) {
        return None;
    }
    let found = run(kind);
    // The proof of which encoder a computer picked for which kind of file, for the app log (also on a VM run).
    let yes = |b: bool| if b { "yes" } else { "no" };
    sq_core_time::milestones::info(&match &found {
        Some(p) => format!(
            "encoder probe: {} {}-bit hardware {} -> {} (B-frames {}, 10-bit {})",
            if kind.hevc { "HEVC" } else { "H.264" },
            if kind.ten_bit { 10 } else { 8 },
            if kind.hardware { "allowed" } else { "off" },
            p.name,
            yes(p.caps.b_frames),
            yes(p.caps.ten_bit),
        ),
        None => format!("encoder probe: no encoder answered for {kind:?}"),
    });
    if let Ok(mut c) = cache().lock() {
        c.insert(kind, found.clone());
    }
    found
}

/// The background probe thread of `warm_up`, kept so the process can wait for it before it ends.
static WARM_UP: std::sync::Mutex<Option<(std::thread::JoinHandle<()>, std::sync::mpsc::Receiver<()>)>> =
    std::sync::Mutex::new(None);
/// How long the end of the process waits for the probe thread.
const WARM_UP_DEADLINE: std::time::Duration = std::time::Duration::from_secs(2);
/// Set by `finish_warm_up`: the probe thread starts no further kind.
static WARM_UP_STOP: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The kinds `warm_up` probes, hardware first.
fn warm_up_kinds() -> impl Iterator<Item = ProbeKind> {
    [true, false].into_iter().flat_map(|hardware| {
        [(false, false), (true, false), (true, true)]
            .into_iter()
            .map(move |(hevc, ten_bit)| ProbeKind { hevc, ten_bit, hardware })
    })
}

/// Probes every kind the export sheet can ask for, on a background thread, so the sheet opens with the answers.
/// The caller ends the run with `finish_warm_up`.
pub fn warm_up() {
    WARM_UP_STOP.store(false, std::sync::atomic::Ordering::SeqCst);
    let (done, finished) = std::sync::mpsc::channel();
    let started = std::thread::Builder::new().name("encoder-probe".to_string()).spawn(move || {
        for kind in warm_up_kinds() {
            if WARM_UP_STOP.load(std::sync::atomic::Ordering::SeqCst) {
                break;
            }
            let _ = probe(kind);
        }
        let _ = done.send(());
    });
    if let (Ok(handle), Ok(mut slot)) = (started, WARM_UP.lock()) {
        *slot = Some((handle, finished));
    }
}

/// Waits for the probe thread (at most the kind it is in) and stops it from starting more. The process must not end
/// while that thread is inside a GPU driver: exit runs the driver's teardown under it and the run died with a segfault
/// in `radeonsi_drv_video.so` (a short headless mode such as `--perf-project`, which has no work of its own to wait for).
/// Safe to call without `warm_up`, and twice.
pub fn finish_warm_up() {
    WARM_UP_STOP.store(true, std::sync::atomic::Ordering::SeqCst);
    let taken = WARM_UP.lock().ok().and_then(|mut slot| slot.take());
    if let Some((handle, finished)) = taken {
        wait_for_probe(handle, &finished, WARM_UP_DEADLINE);
    }
}

/// Joins the probe thread when it reports done within `deadline`; else lets it go (a hung driver call must not hold the
/// exit) and logs one line. Returns whether it was joined.
fn wait_for_probe(handle: std::thread::JoinHandle<()>, finished: &std::sync::mpsc::Receiver<()>, deadline: std::time::Duration) -> bool {
    // A disconnected channel means the thread ended (or died): joining returns at once.
    if matches!(finished.recv_timeout(deadline), Err(std::sync::mpsc::RecvTimeoutError::Timeout)) {
        sq_core_time::milestones::info("encoder probe: still running at exit, left behind");
        return false;
    }
    let _ = handle.join();
    true
}

/// Frames the test writes: enough for the B-frame decision of a hardware encoder to show.
const PROBE_FRAMES: i64 = 16;
const PROBE_SIZE: (i32, i32) = (1280, 720);

// shortcut: the Mac's VideoToolbox path is not probed (its B-frames are off by a documented shim shortcut); the sheet
// shows no limits there. Upgrade when the Mac export gets measured B-frames.
fn probe_is_off(shim_linked: bool, platform: Platform) -> bool {
    !shim_linked || platform == Platform::Apple
}

fn run(kind: ProbeKind) -> Option<Probe> {
    static COUNTER: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!("sq-encoder-probe-{}-{n}.mp4", std::process::id()));
    let (w, h) = PROBE_SIZE;
    let cfg = EncodeConfig {
        path,
        hevc: kind.hevc,
        hardware: kind.hardware,
        width: w,
        height: h,
        fps_num: 24,
        fps_den: 1,
        bitrate: 4_000_000,
        gop: 12,
        b_frames: 2,
        ten_bit: kind.ten_bit,
        speed: 2,
        ..EncodeConfig::default()
    };
    // Dropping the encoder aborts and deletes the test file.
    let mut enc = Encoder::open(&cfg).ok()?;
    let mut rgba = vec![0u8; (w * h * 4) as usize];
    for i in 0..PROBE_FRAMES {
        // A moving gradient: a static picture can make a B-frame decision pick P.
        for (x, px) in rgba.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let (col, row) = (x as i64 % i64::from(w), x as i64 / i64::from(w));
            *px = [(col + i * 9) as u8, (row * 2 + i * 5) as u8, ((col ^ row) + i * 3) as u8, 255];
        }
        enc.video(&rgba, PixelLayout::Rgba, w * 4, i).ok()?;
    }
    enc.drain_video().ok()?;
    let facts = enc.video_facts();
    let name = enc.video_name();
    let mut caps = caps_of(&name);
    caps.b_frames = caps.b_frames && facts.reordered;
    if kind.ten_bit {
        caps.ten_bit = facts.bit_depth >= 10;
    }
    Some(Probe { name, caps })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_run_waits_for_the_probe_thread_before_it_ends() {
        let kinds: Vec<_> = warm_up_kinds().collect();
        assert_eq!(kinds.len(), 6);
        assert!(kinds[..3].iter().all(|k| k.hardware) && kinds[3..].iter().all(|k| !k.hardware));
        finish_warm_up(); // without warm_up: nothing to wait for
        warm_up();
        assert!(WARM_UP.lock().expect("lock").is_some(), "the thread handle is kept");
        finish_warm_up();
        assert!(WARM_UP.lock().expect("lock").is_none(), "the thread was joined");
        finish_warm_up(); // twice is fine
    }

    #[test]
    fn a_hung_probe_does_not_hold_the_exit() {
        let (release, wait) = std::sync::mpsc::channel::<()>();
        let (_done, finished) = std::sync::mpsc::channel::<()>();
        let hung = std::thread::spawn(move || {
            let _ = wait.recv();
        });
        let start = std::time::Instant::now();
        assert!(!wait_for_probe(hung, &finished, std::time::Duration::from_millis(50)));
        assert!(start.elapsed() < std::time::Duration::from_secs(1), "gave up at the deadline");
        let _ = release.send(());
        let (done, finished) = std::sync::mpsc::channel::<()>();
        let quick = std::thread::spawn(move || {
            let _ = done.send(());
        });
        assert!(wait_for_probe(quick, &finished, std::time::Duration::from_secs(5)), "a finished probe is joined");
    }

    #[test]
    fn hardware_encoders_do_ten_bit_only_as_hevc() {
        for name in ["hevc_vaapi", "hevc_nvenc", "hevc_amf", "hevc_qsv", "hevc_mf"] {
            let c = caps_of(name);
            assert!(c.hardware && c.ten_bit && c.cbr && c.constant_quality && c.bitrate, "{name}");
        }
        for name in ["h264_vaapi", "h264_nvenc", "h264_amf", "h264_qsv", "h264_mf"] {
            assert!(caps_of(name).hardware && !caps_of(name).ten_bit, "{name}");
        }
    }

    #[test]
    fn the_software_fallbacks_are_8_bit_and_none_does_multi_pass() {
        for name in ["libopenh264", "libkvazaar", "libx264"] {
            let c = caps_of(name);
            assert!(!c.hardware && !c.ten_bit && !c.multi_pass, "{name}");
        }
        assert!(!caps_of("libopenh264").b_frames);
        assert!(caps_of("libkvazaar").b_frames && !caps_of("libkvazaar").cbr);
        assert!(caps_of("libx265").ten_bit);
    }

    #[test]
    fn an_unknown_encoder_promises_only_an_average_bitrate() {
        let c = caps_of("something_new");
        assert_eq!((c.bitrate, c.cbr, c.constant_quality, c.b_frames, c.ten_bit), (true, false, false, false, false));
    }

    #[test]
    fn missing_lists_what_the_wish_asks_beyond_the_encoder_in_a_fixed_order() {
        let all =
            Wish { ten_bit: true, b_frames: true, cbr: true, constant_quality: true, multi_pass: true, profile: true };
        assert_eq!(missing(&caps_of("libopenh264"), &all), [Missing::TenBit, Missing::BFrames, Missing::MultiPass]);
        assert_eq!(missing(&caps_of("hevc_vaapi"), &all), [Missing::MultiPass]);
        assert_eq!(
            missing(&caps_of("libkvazaar"), &all),
            [Missing::TenBit, Missing::ConstantBitrate, Missing::MultiPass, Missing::Profile]
        );
        assert!(missing(&caps_of("libopenh264"), &Wish::default()).is_empty());
    }

    #[test]
    fn the_h264_profile_is_missing_only_where_the_encoder_has_no_such_profiles() {
        let wish = Wish { profile: true, ..Wish::default() };
        for name in [
            "h264_vaapi",
            "h264_nvenc",
            "h264_amf",
            "h264_qsv",
            "h264_mf",
            "h264_videotoolbox",
            "libx264",
            "libopenh264",
        ] {
            assert!(missing(&caps_of(name), &wish).is_empty(), "{name}");
        }
        for name in ["libkvazaar", "something_new"] {
            assert_eq!(missing(&caps_of(name), &wish), [Missing::Profile], "{name}");
        }
    }

    #[test]
    fn a_probe_that_found_no_b_frames_says_so_even_for_an_encoder_that_can() {
        let measured = EncoderCaps { b_frames: false, ..caps_of("h264_vaapi") };
        assert_eq!(missing(&measured, &Wish { b_frames: true, ..Wish::default() }), [Missing::BFrames]);
    }

    /// Main 10 asked of the software encoders: Kvazaar and OpenH264 are 8-bit, so nothing opens unless libx265 is there.
    /// The shim used to retry in 8-bit, so a file of another profile (or MPEG-4) came out under the name "HEVC Main 10".
    #[test]
    fn a_10_bit_request_never_opens_an_8_bit_encoder() {
        if !crate::shim::AVAILABLE || Platform::current() == Platform::Apple {
            return;
        }
        let path = std::env::temp_dir().join(format!("sq-ten-bit-refusal-{}.mp4", std::process::id()));
        let cfg = EncodeConfig {
            path: path.clone(),
            hevc: true,
            hardware: false,
            width: 320,
            height: 180,
            fps_num: 24,
            fps_den: 1,
            bitrate: 1_000_000,
            gop: 12,
            ten_bit: true,
            ..EncodeConfig::default()
        };
        match Encoder::open(&cfg) {
            Ok(enc) => assert_eq!(enc.video_name(), "libx265"),
            Err(e) => assert_eq!(e.code, crate::encode::ENCODER_NOT_FOUND, "{e}"),
        }
        let _ = std::fs::remove_file(path);
    }

    /// The real encoder of this machine, when FFmpeg is linked: the answer is cached and the 8-bit H.264 kind always
    /// finds an encoder (hardware or software). Skipped on a Mac, where the probe is off.
    #[test]
    fn a_probe_names_an_encoder_and_is_cached() {
        let kind = ProbeKind { hevc: false, ten_bit: false, hardware: false };
        let first = probe(kind);
        if !crate::shim::AVAILABLE || Platform::current() == Platform::Apple {
            assert!(first.is_none());
            return;
        }
        let first = first.expect("a software H.264 encoder");
        assert!(["libx264", "libopenh264"].contains(&first.name.as_str()), "{}", first.name);
        assert!(!first.caps.hardware && !first.caps.ten_bit);
        assert_eq!(cached(kind), ProbeState::Found(first.clone()));
        assert_eq!(probe(kind), Some(first));
    }

    /// The Mac does not probe: no answer is kept there, or `cached` would say "no encoder" and grey out every H.264 / HEVC
    /// choice of the sheet.
    #[test]
    fn an_unprobed_platform_keeps_no_answer() {
        assert!(probe_is_off(true, Platform::Apple) && probe_is_off(false, Platform::Linux));
        assert!(!probe_is_off(true, Platform::Linux) && !probe_is_off(true, Platform::Windows));
    }
}

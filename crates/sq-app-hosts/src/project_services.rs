//! What the Project panel needs from the machine: revealing a file in the system file manager and the poster decode
//! behind [`ThumbnailSource`]. Both sit behind small seams so the host stays testable without a file manager or media.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use sq_core_model::PixelAspect;
use sq_core_time::{Id, Time};
use sq_editor_session::{Thumbnail, ThumbnailJob, ThumbnailSource};
use sq_media::demuxing::Demuxing;
use sq_media_ffmpeg::decode::{FFmpegDemuxer, FFmpegFrame, FFmpegVideoDecoder};
use sq_os::Platform;

/// The file manager of the platform (Finder, Explorer).
pub trait FileManager {
    /// Shows `path` selected in the file manager.
    fn reveal(&self, path: &Path) -> Result<(), String>;
    /// Opens `path` in the system's default app (Edit Original).
    fn open(&self, path: &Path) -> Result<(), String>;
}

/// The program and arguments that show `path` in the file manager of `platform`.
pub fn reveal_command(platform: Platform, path: &Path) -> (&'static str, Vec<OsString>) {
    match platform {
        Platform::Mac => ("open", vec!["-R".into(), path.into()]),
        Platform::Windows => {
            let mut arg = OsString::from("/select,");
            arg.push(sq_os::paths::os_form(Platform::Windows, &path.to_string_lossy()));
            ("explorer", vec![arg])
        }
        Platform::Linux => ("xdg-open", vec![path.parent().unwrap_or(path).into()]),
    }
}

/// The Explorer command line tail that selects `path`: `/select,"path"`. Explorer ignores a whole-argument quote
/// (`"/select,C:\a b\c"`, what `Command::arg` makes of a path with a space) and opens its default folder instead.
#[cfg(any(windows, test))]
pub fn explorer_select_raw(path: &Path) -> OsString {
    let mut arg = OsString::from("/select,\"");
    arg.push(sq_os::paths::os_form(Platform::Windows, &path.to_string_lossy()));
    arg.push("\"");
    arg
}

/// The program and arguments that open `path` in its default app on `platform`. `None` on Windows: there the shell opens
/// it (`sq_platform_win::open`, `ShellExecuteW`), no program is started. A child `cmd /c start` from the window-less app
/// opened nothing and read the path as a command line.
#[cfg(any(not(windows), test))]
pub fn open_command(platform: Platform, path: &Path) -> Option<(&'static str, Vec<OsString>)> {
    match platform {
        Platform::Mac => Some(("open", vec![path.into()])),
        Platform::Windows => None,
        Platform::Linux => Some(("xdg-open", vec![path.into()])),
    }
}

static EXTERNAL_OPEN_OFF: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

static BLOCKED_OPENS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// How many system opens and reveals [`external_open_allowed`] has blocked in this process: an offscreen click sweep reads it
/// to tell a button that opens a link from a button that does nothing.
pub fn blocked_external_opens() -> usize {
    BLOCKED_OPENS.load(std::sync::atomic::Ordering::Relaxed)
}

/// Turns off every system open and reveal for this process: offscreen shots, exports and test runs must never open
/// Mail, a browser, Discord or the file manager on the user's desktop.
pub fn disable_external_open() {
    EXTERNAL_OPEN_OFF.store(true, std::sync::atomic::Ordering::Relaxed);
}

/// False after [`disable_external_open`], in this crate's tests, and when `SQ_NO_EXTERNAL_OPEN` is set (the workspace
/// `.cargo/config.toml` sets it for every cargo build, test and run; the packaged app never has it).
pub fn external_open_allowed() -> bool {
    !cfg!(test)
        && !EXTERNAL_OPEN_OFF.load(std::sync::atomic::Ordering::Relaxed)
        && std::env::var_os("SQ_NO_EXTERNAL_OPEN").is_none()
}

/// [`FileManager`] over a child process of the system's file manager.
pub struct SystemPlatform;

impl FileManager for SystemPlatform {
    fn reveal(&self, path: &Path) -> Result<(), String> {
        if !external_open_allowed() {
            BLOCKED_OPENS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            eprintln!("sq: external reveal skipped (tests or offscreen run): {}", path.display());
            return Ok(());
        }
        // Explorer exits with 1 even when it worked, so only a failed start is an error.
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            Command::new("explorer").raw_arg(explorer_select_raw(path)).spawn().map(drop).map_err(|e| e.to_string())
        }
        #[cfg(not(windows))]
        {
            let (program, args) = reveal_command(Platform::current(), path);
            Command::new(program).args(args).spawn().map(drop).map_err(|e| e.to_string())
        }
    }

    fn open(&self, path: &Path) -> Result<(), String> {
        if !external_open_allowed() {
            BLOCKED_OPENS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            eprintln!("sq: external open skipped (tests or offscreen run): {}", path.display());
            return Ok(());
        }
        #[cfg(windows)]
        {
            sq_platform_win::open(sq_os::paths::for_os(path).as_os_str())
        }
        #[cfg(not(windows))]
        {
            let (program, args) =
                open_command(Platform::current(), path).ok_or("no way to open files on this system")?;
            Command::new(program).args(args).spawn().map(drop).map_err(|e| e.to_string())
        }
    }
}

/// Averages `rgba` (`width` x `height`, 4 bytes a pixel) down to `out_w` x `out_h`; every output pixel is the mean of the
/// source pixels it covers. Sizes that do not shrink repeat the nearest source pixel.
pub fn scale_rgba(rgba: &[u8], width: usize, height: usize, out_w: usize, out_h: usize) -> Vec<u8> {
    let mut out = vec![0u8; out_w * out_h * 4];
    if width == 0 || height == 0 || rgba.len() < width * height * 4 {
        return out;
    }
    for oy in 0..out_h {
        let (y0, y1) = span(oy, out_h, height);
        for ox in 0..out_w {
            let (x0, x1) = span(ox, out_w, width);
            let mut sum = [0u64; 4];
            for y in y0..y1 {
                for x in x0..x1 {
                    let p = (y * width + x) * 4;
                    for (s, v) in sum.iter_mut().zip(&rgba[p..p + 4]) {
                        *s += u64::from(*v);
                    }
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u64;
            let o = (oy * out_w + ox) * 4;
            for (d, s) in out[o..o + 4].iter_mut().zip(sum) {
                *d = u8::try_from(s / n).unwrap_or(u8::MAX);
            }
        }
    }
    out
}

/// The source rows (or columns) `i` of `out` covers; never empty.
fn span(i: usize, out: usize, source: usize) -> (usize, usize) {
    let start = (i * source / out).min(source - 1);
    let end = ((i + 1) * source / out).clamp(start + 1, source);
    (start, end)
}

/// The size of a poster `height` tall for a picture of `width` x `height` shown with `aspect`.
pub fn poster_size(width: usize, source_height: usize, height: i64, aspect: Option<PixelAspect>) -> (usize, usize) {
    let h = usize::try_from(height).unwrap_or(1).clamp(1, source_height.max(1));
    let shown = match aspect {
        Some(a) if !a.is_square() && a.den() > 0 => width as f64 * a.num() as f64 / a.den() as f64,
        _ => width as f64,
    };
    let w = (shown * h as f64 / source_height.max(1) as f64).round().max(1.0);
    (w as usize, h)
}

fn shared_demuxer(path: &Path) -> Option<Arc<FFmpegDemuxer>> {
    FFmpegDemuxer::open_shared(path).ok()
}

/// Threads of a poster decoder: one picture does not need the cores playback needs.
const POSTER_THREADS: i32 = 1;
/// Decoders kept for the next posters of the same files (a clip's tiles ask many frames of one file; a 4K software
/// decoder costs 30-60 ms to open).
const KEPT_DECODERS: usize = 3;

type Kept = (PathBuf, Arc<FFmpegDemuxer>, Arc<FFmpegVideoDecoder>);
static KEPT: std::sync::Mutex<Vec<Kept>> = std::sync::Mutex::new(Vec::new());

/// The demuxer and the one-thread decoder of `path`, the most recently used kept (`KEPT_DECODERS`).
fn poster_decoder(path: &Path) -> Option<(Arc<FFmpegDemuxer>, Arc<FFmpegVideoDecoder>)> {
    let demuxer = shared_demuxer(path)?;
    {
        let mut kept = KEPT.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(i) = kept.iter().position(|(p, d, _)| p == path && Arc::ptr_eq(d, &demuxer)) {
            let hit = kept.remove(i);
            let out = (Arc::clone(&hit.1), Arc::clone(&hit.2));
            kept.push(hit);
            return Some(out);
        }
    }
    let decoder = Arc::new(FFmpegVideoDecoder::new_background(Arc::clone(&demuxer), Id::from_u128(0), POSTER_THREADS).ok()?);
    let mut kept = KEPT.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    kept.retain(|(p, _, _)| p != path);
    if kept.len() >= KEPT_DECODERS {
        kept.remove(0);
    }
    kept.push((path.to_path_buf(), Arc::clone(&demuxer), Arc::clone(&decoder)));
    Some((demuxer, decoder))
}

/// A pool for poster decodes: its threads take the Background class once, at their start (a thread keeps its class, so the
/// pool must run nothing else).
pub fn poster_pool(threads: usize) -> sq_runtime::WorkerPool {
    sq_runtime::WorkerPool::threads_with_init(
        threads,
        Some(Arc::new(|| {
            sq_os::thread::set_current_thread_role(sq_os::thread::Role::Background);
        })),
    )
}

/// One picture of `path` at `at`, `height` tall, decoded with FFmpeg (blocking). Background work (run it on a `poster_pool`):
/// one decoder thread, and it waits while the timeline plays or is scrubbed (`thumbnail_gate`).
pub fn decode_thumbnail(path: &Path, at: Time, height: i64, aspect: Option<PixelAspect>) -> Option<Thumbnail> {
    crate::thumbnail_gate::wait_until_clear();
    let (demuxer, decoder) = poster_decoder(path)?;
    let index = demuxer.index().frame_at(at).unwrap_or(0);
    let frames = decoder.decode_blocking(index..=index, None, None).ok()?;
    let decoded = frames.first()?;
    let rgba = decoded.frame.storage_as::<FFmpegFrame>()?.download_rgba().ok()?;
    let (w, h) = (decoded.frame.width, decoded.frame.height);
    Some(upright_thumbnail(&rgba, w, h, demuxer.rotation(), height, aspect))
}

/// A picture stored `width` x `source_height` and tagged with `rotation` (clockwise degrees, the display matrix) as the
/// upright poster `height` tall: the same turn the player applies, so a phone clip is not lying on its side.
pub fn upright_thumbnail(
    rgba: &[u8],
    width: usize,
    source_height: usize,
    rotation: i64,
    height: i64,
    aspect: Option<PixelAspect>,
) -> Thumbnail {
    let sideways = ((rotation / 90) % 2 + 2) % 2 == 1;
    // Scale first (small), turn after.
    let (shown_w, shown_h) = if sideways { (source_height, width) } else { (width, source_height) };
    let (out_w, out_h) = poster_size(shown_w, shown_h, height, aspect);
    let (sw, sh) = if sideways { (out_h, out_w) } else { (out_w, out_h) };
    let scaled = scale_rgba(rgba, width, source_height, sw, sh);
    let turned = sq_analysis::edge_tamonnx::SubjectFrame::new(sw, sh, scaled).upright(rotation);
    Thumbnail { width: turned.width, height: turned.height, rgba: Arc::new(turned.rgba) }
}

/// [`ThumbnailSource`] over FFmpeg: the poster frame, hover-scrub frames and clip frames of video and still files.
pub struct FfmpegPosters;

impl ThumbnailSource for FfmpegPosters {
    fn run(&self, job: &ThumbnailJob) -> Vec<Option<Thumbnail>> {
        let one = |path: &str, at: Time, height: i64, aspect: Option<PixelAspect>| {
            decode_thumbnail(&PathBuf::from(path), at, height, aspect)
        };
        match job {
            ThumbnailJob::Poster { path, at, height, aspect, .. }
            | ThumbnailJob::Frame { path, at, height, aspect, .. }
            | ThumbnailJob::Scrub { path, at, height, aspect, .. } => vec![one(path, *at, *height, *aspect)],
            ThumbnailJob::PosterAndFrame { path, poster_at, frame_at, height, aspect, .. } => {
                vec![one(path, *poster_at, *height, *aspect), one(path, *frame_at, *height, *aspect)]
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_runs_and_offscreen_runs_never_open_anything_on_the_desktop() {
        // A test run must never reach `open mailto:` / a browser / Finder (it opened Mail windows on the Mac before).
        assert!(!external_open_allowed());
        disable_external_open();
        assert!(!external_open_allowed());
        assert_eq!(SystemPlatform.open(Path::new("mailto:info@getsequencestudio.com")), Ok(()));
        assert_eq!(SystemPlatform.reveal(Path::new("/tmp")), Ok(()));
    }

    #[test]
    fn explorer_gets_the_backslash_path_of_a_stored_or_verbatim_media_path() {
        // The old project spelling `//?/C:/...` made Explorer open the Desktop and ShellExecute answer "not found".
        let (_, args) = reveal_command(Platform::Windows, Path::new("//?/C:/sq-w47-light/pl-4k-hevc.mp4"));
        assert_eq!(args, vec![OsString::from("/select,C:\\sq-w47-light\\pl-4k-hevc.mp4")]);
        assert_eq!(explorer_select_raw(Path::new("C:/a b/c.mp4")), OsString::from("/select,\"C:\\a b\\c.mp4\""));
        assert_eq!(
            explorer_select_raw(Path::new("//server/share/c.mp4")),
            OsString::from("/select,\"\\\\server\\share\\c.mp4\"")
        );
    }

    #[test]
    fn reveal_selects_the_file_on_mac_and_windows() {
        let p = Path::new("/media/a.mov");
        let (program, args) = reveal_command(Platform::Mac, p);
        assert_eq!((program, args), ("open", vec![OsString::from("-R"), OsString::from("/media/a.mov")]));
        let (program, args) = reveal_command(Platform::Windows, Path::new("C:\\media\\a.mov"));
        assert_eq!((program, args), ("explorer", vec![OsString::from("/select,C:\\media\\a.mov")]));
        assert_eq!(reveal_command(Platform::Linux, p), ("xdg-open", vec![OsString::from("/media")]));
        assert_eq!(open_command(Platform::Linux, p), Some(("xdg-open", vec![OsString::from("/media/a.mov")])));
        assert_eq!(open_command(Platform::Mac, p), Some(("open", vec![OsString::from("/media/a.mov")])));
    }

    #[test]
    fn windows_opens_through_the_shell_and_starts_no_cmd() {
        // `cmd /c start` from the window-less GUI process opened nothing, and a `&` in the path was a command separator.
        assert_eq!(open_command(Platform::Windows, Path::new("C:\\Logs & More\\sq.log")), None);
        assert_eq!(open_command(Platform::Windows, Path::new("https://getsequencestudio.com")), None);
    }

    #[test]
    fn explorer_gets_the_path_quoted_after_select() {
        let raw = explorer_select_raw(Path::new("C:\\My Videos\\Sequence 01.mp4"));
        assert_eq!(raw, OsString::from("/select,\"C:\\My Videos\\Sequence 01.mp4\""));
    }

    #[test]
    fn scaling_averages_the_covered_pixels() {
        // 2x2: black, white / white, black, averaged into one gray pixel.
        let px = |v: u8| [v, v, v, 255];
        let src: Vec<u8> = [px(0), px(200), px(200), px(0)].concat();
        assert_eq!(scale_rgba(&src, 2, 2, 1, 1), [100, 100, 100, 255]);
        // Growing repeats pixels.
        assert_eq!(scale_rgba(&px(7), 1, 1, 2, 2).len(), 16);
        assert!(scale_rgba(&[], 0, 0, 2, 2).iter().all(|b| *b == 0));
    }

    #[test]
    fn poster_size_keeps_the_shape_and_never_upscales() {
        assert_eq!(poster_size(1920, 1080, 90, None), (160, 90));
        assert_eq!(poster_size(100, 50, 400, None), (100, 50));
        assert_eq!(poster_size(720, 480, 240, PixelAspect::new(32, 27)), (427, 240));
    }

    #[test]
    fn a_rotation_tag_turns_the_poster_upright() {
        // Stored 8 x 4, tagged 90 clockwise: the poster is portrait and the stored left side ends on top.
        let mut px = Vec::new();
        for _y in 0..4 {
            for x in 0..8 {
                px.extend([if x < 4 { 10 } else { 200 }, 0, 0, 255]);
            }
        }
        let t = upright_thumbnail(&px, 8, 4, 90, 8, None);
        assert_eq!((t.width, t.height), (4, 8), "portrait after the turn");
        assert_eq!(t.rgba[0], 10, "the stored left side is on top");
        assert_eq!(t.rgba[(7 * 4) * 4], 200, "the stored right side is at the bottom");
        let upright = upright_thumbnail(&px, 8, 4, 0, 4, None);
        assert_eq!((upright.width, upright.height), (8, 4));
        let flipped = upright_thumbnail(&px, 8, 4, 270, 8, None);
        assert_eq!((flipped.width, flipped.height), (4, 8));
        assert_eq!(flipped.rgba[0], 200);
    }

    #[test]
    fn a_clip_with_a_display_matrix_gets_a_portrait_poster() {
        let dir = std::env::temp_dir().join(format!("sq-poster-rot-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (src, rot) = (dir.join("src.mp4"), dir.join("rot.mp4"));
        let ok = |c: &mut Command| c.output().is_ok_and(|o| o.status.success());
        let made = ok(Command::new("ffmpeg")
            .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25:duration=1"])
            .args(["-c:v", "mpeg4"])
            .arg(&src));
        let turned = made
            && ok(Command::new("ffmpeg")
                .args(["-v", "error", "-y", "-display_rotation", "90", "-i"])
                .arg(&src)
                .args(["-c", "copy"])
                .arg(&rot));
        if !turned {
            eprintln!("skipped: ffmpeg cannot write the rotated clip");
            return;
        }
        let t = decode_thumbnail(&rot, Time::ZERO, 120, None).expect("a poster");
        assert!(t.height > t.width, "portrait, not lying on its side: {}x{}", t.width, t.height);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn a_missing_file_gives_no_picture() {
        assert!(decode_thumbnail(Path::new("/no/such/file.mp4"), Time::ZERO, 64, None).is_none());
    }

    #[test]
    fn posters_of_one_file_reuse_one_decoder_and_keep_at_most_three() {
        let dir = std::env::temp_dir().join(format!("sq-poster-kept-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut files = Vec::new();
        for n in 0..4 {
            let f = dir.join(format!("c{n}.mp4"));
            let ok = Command::new("ffmpeg")
                .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25:duration=1"])
                .args(["-c:v", "mpeg4"])
                .arg(&f)
                .output()
                .is_ok_and(|o| o.status.success());
            if !ok {
                eprintln!("skipped: ffmpeg cannot write a clip");
                return;
            }
            files.push(f);
        }
        let (_, first) = poster_decoder(&files[0]).expect("decoder");
        let (_, again) = poster_decoder(&files[0]).expect("decoder");
        assert!(Arc::ptr_eq(&first, &again), "the second poster of a file reuses its decoder");
        assert!(decode_thumbnail(&files[0], Time::new(1, 25), 60, None).is_some());
        for f in &files[1..] {
            assert!(decode_thumbnail(f, Time::ZERO, 60, None).is_some());
        }
        let mine = KEPT.lock().unwrap().iter().filter(|(p, _, _)| p.starts_with(&dir)).count();
        assert!(mine <= KEPT_DECODERS, "{mine} decoders kept");
        std::fs::remove_dir_all(dir).ok();
    }
}

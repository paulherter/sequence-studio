//! A project that opens shows its first picture in the Program monitor without any input: the window loop sleeps between
//! events, so the picture has to arrive together with the wake that asks for its frame.

use crate::export::tests::ffmpeg_tool;
use sq_app_hosts::MonitorPicture;
use sq_app_shell::{AppDeps, Headless};
use sq_core_model::{Clip, MediaFingerprint, MediaRef, Project, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_media_ffmpeg::decode::FFmpegDemuxer;
use sq_runtime::{Clock, SystemClock};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// A saved one second project around the 1 s test clip, `None` without an `ffmpeg` command.
fn project_with_clip(dir: &Path) -> Option<std::path::PathBuf> {
    let tool = ffmpeg_tool()?;
    project_around(dir, &crate::export::tests::make_clip(&tool, dir)?)
}

/// A saved one second project that plays the first second of `clip`.
pub(crate) fn project_around(dir: &Path, clip: &Path) -> Option<std::path::PathBuf> {
    project_starting_at(dir, clip, Time::ZERO)
}

/// Like `project_around`, with the clip starting at `start` on the timeline (a gap before it).
fn project_starting_at(dir: &Path, clip: &Path, start: Time) -> Option<std::path::PathBuf> {
    let media = Id::from_u128(100);
    let reference = MediaRef::new(media, "clip", &clip.to_string_lossy(), MediaFingerprint::new(1));
    let mut track = Track::new(Id::from_u128(900), TrackKind::Video);
    let source = TimeRange::new(Time::ZERO, Time::seconds(1));
    track.set_clips(vec![Clip::new(Id::from_u128(10), "c", media, TrackKind::Video, source, start)]);
    let mut format = SequenceFormat::new(Time::new(1, 25));
    (format.width, format.height) = (320, 180);
    let timeline = Timeline::new(Id::from_u128(1), "t", format, vec![track]);
    let project = Project::new(Id::from_u128(2), "p", vec![reference], vec![timeline]);
    let file = dir.join("clip.sqproj");
    let mut session =
        sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.to_path_buf()));
    session.save_as(&file).ok()?;
    Some(file)
}

/// True when the monitor picture shows the clip: a picture of one flat color is the placeholder a composite makes while the
/// clip still opens (the test clips are test patterns).
fn shows_content(picture: &MonitorPicture) -> bool {
    picture.get().is_some_and(|image| {
        let first = image.pixels.get(..3).map(<[u8]>::to_vec).unwrap_or_default();
        image.pixels.as_chunks::<4>().0.iter().any(|p| p[..3] != first[..])
    })
}

/// What a window loop that sleeps between events saw of a project that was opened.
struct Opened {
    /// When the first frame that carried a monitor picture with the clip's pixels (not a flat placeholder) was drawn, counted from the open.
    first_picture: Option<Duration>,
    /// The monitor picture generations the drawn frames carried.
    drawn_generations: Vec<i64>,
}

/// Opens `file` the way `Shell::open` does and runs the window loop's rule for `limit`: a turn at start, then a turn only
/// when something woke the loop (the engine's wake, a posted message), or a frame is due. No input ever arrives.
fn open_and_wait(file: &Path, support: &Path, limit: Duration) -> Opened {
    open_with(file, support, limit, OpenPath::CommandLine)
}

/// How the project reaches the window.
#[derive(Clone, Copy, PartialEq)]
enum OpenPath {
    /// The command line: the session opens the project before the window exists.
    CommandLine,
    /// The session's own `open` in the running app (no shell flow).
    SessionOpen,
    /// The shell's Open flow, which File > Open, Open Recent, a drop, the dock and a double click all run.
    ShellFlow,
    /// A real press on the Recent card of the start window (it runs the same flow).
    RecentCard,
}

/// The running app the window loop drives: the real engine, the real panels and the start window over an empty project (or
/// the project of the command line); the wake counter stands for the window's `Wake::Inbox`.
pub(crate) fn start_app(project: Option<&Path>, support: &Path) -> (Headless, MonitorPicture, Arc<AtomicUsize>) {
    let clock = Arc::new(SystemClock::new());
    let wakes = Arc::new(AtomicUsize::new(0));
    let mut deps = AppDeps::headless(Arc::clone(&clock) as Arc<dyn Clock>);
    let counted = Arc::clone(&wakes);
    deps.wake = Box::new(move || {
        counted.fetch_add(1, Ordering::SeqCst);
    });
    let theme = deps.theme;
    let engine_wake = crate::playback::WakeSlot::default();
    let (session, picture) = crate::session_for(project, support, Arc::clone(&engine_wake));
    let app = Headless::new(session, deps, 1280, 800);
    crate::playback::connect_wake(&engine_wake, &app);
    crate::add_root(&app, clock, theme, support, picture.clone(), sq_editor_session::WorkspacePage::Edit);
    (app, picture, wakes)
}

/// The window's first frames of the empty app, before anything is opened.
pub(crate) fn first_frames(app: &Headless) {
    for _ in 0..3 {
        app.turn();
    }
}

/// The app starts on an empty project and draws its first frames, and the project is opened afterwards the way `path` says,
/// except for `OpenPath::CommandLine`, where the project is opened before the window exists.
fn open_with(file: &Path, support: &Path, limit: Duration, path: OpenPath) -> Opened {
    // A project opened by the command line starts opening its media inside `session_for`: count from before it.
    let mut began = Instant::now();
    if path == OpenPath::RecentCard {
        // The start window lists the project; its card is the first thing under the pointer's way.
        let entry = serde_json::json!({"entries": [{"path": file.to_string_lossy(), "name": "p", "opened": 1.0}]});
        std::fs::create_dir_all(support).expect("support folder");
        std::fs::write(support.join("recents.json"), serde_json::to_vec(&entry).expect("json")).expect("recents");
    }
    let (app, picture, wakes) = start_app((path == OpenPath::CommandLine).then_some(file), support);
    if path != OpenPath::CommandLine {
        first_frames(&app);
        began = Instant::now();
        match path {
            OpenPath::SessionOpen => {
                let opened = app.with(|a| a.session_mut().open(file).is_ok());
                assert_eq!(opened, Some(true), "the project did not open");
            }
            OpenPath::RecentCard => click_recent_card(&app),
            _ => {
                app.with(|a| a.emit_flow(sq_draw_shell::ShellFlow::OpenProject(file.to_path_buf())));
            }
        }
    }
    run_loop(&app, &picture, &wakes, began, limit)
}

/// A real press on the first card of the start window (1280 x 800 at scale 1, where the card of the only recent project sits).
fn click_recent_card(app: &Headless) {
    use sq_draw::{InputEvent, InputModifiers};
    let (x, y) = (370.0_f32, 200.0_f32);
    app.input(&InputEvent::MouseMoved { x, y });
    app.input(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE });
    app.input(&InputEvent::MouseUp { x, y });
}

fn run_loop(
    app: &Headless,
    picture: &MonitorPicture,
    wakes: &Arc<AtomicUsize>,
    began: Instant,
    limit: Duration,
) -> Opened {
    let mut opened = Opened { first_picture: None, drawn_generations: Vec::new() };
    let mut seen = usize::MAX; // the first turn runs without a wake (the window's first redraw)
    let end = Instant::now() + limit;
    let mut frame_due = false;
    while Instant::now() < end {
        let woken = wakes.load(Ordering::SeqCst);
        if woken != seen || frame_due {
            seen = woken;
            let (_, list) = app.turn();
            if list.is_some() {
                // The generation also moves for a cleared picture: the frame has to carry pixels.
                let generation = picture.generation();
                opened.drawn_generations.push(generation);
                if picture.size().is_some() && opened.first_picture.is_none() && shows_content(picture) {
                    opened.first_picture = Some(began.elapsed());
                    return opened;
                }
            }
            // An animation or a retry keeps asking for frames; otherwise the loop sleeps (`ControlFlow::Wait`).
            frame_due = app.with(|a| a.needs_redraw()).unwrap_or(false);
        }
        std::thread::sleep(Duration::from_millis(if frame_due { 16 } else { 2 }));
    }
    opened
}

#[test]
fn a_project_shows_its_first_picture_without_any_input() {
    let dir = std::env::temp_dir().join(format!("sq-first-picture-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp folder");
    let Some(file) = project_with_clip(&dir) else {
        eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
        return;
    };
    if crate::surface::shared_gpu().is_none() {
        eprintln!("skipped: no GPU adapter");
        return;
    }
    let opened = open_and_wait(&file, &dir.join("support"), Duration::from_secs(10));
    let _ = std::fs::remove_dir_all(&dir);
    eprintln!(
        "first picture drawn after {:?}; frames drawn with generations {:?}",
        opened.first_picture, opened.drawn_generations
    );
    let at = opened.first_picture.expect("no frame with a monitor picture was drawn within 10 s without any input");
    assert!(at < Duration::from_secs(5), "the first picture took {at:?} without any input");
}

/// `SQ_FIRST_PICTURE_CLIP=<file>`: the same measurement on a heavy real clip (a 4K HEVC file takes seconds to decode its
/// first picture); without the variable the test has nothing to open.
#[test]
fn a_heavy_clip_shows_its_first_picture_without_any_input() {
    let Some(clip) = std::env::var_os("SQ_FIRST_PICTURE_CLIP").map(std::path::PathBuf::from) else { return };
    let dir = std::env::temp_dir().join(format!("sq-first-picture-heavy-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp folder");
    let file = project_around(&dir, &clip).expect("a project");
    // SQ_KEEP_PROJECT=<file>: keeps the project for `sequence-studio <project> --play-bench` runs on the same clip.
    if let Some(keep) = std::env::var_os("SQ_KEEP_PROJECT") {
        // A project is a folder or a file: `cp -r` takes both.
        let kept = std::process::Command::new("cp").arg("-r").arg(&file).arg(&keep).status();
        assert!(kept.is_ok_and(|s| s.success()), "the project could not be kept");
    }
    let opened = open_and_wait(&file, &dir.join("support"), Duration::from_secs(30));
    let _ = std::fs::remove_dir_all(&dir);
    eprintln!(
        "first picture drawn after {:?}; frames drawn with generations {:?}",
        opened.first_picture, opened.drawn_generations
    );
    let at = opened.first_picture.expect("no frame with a monitor picture was drawn within 30 s without any input");
    assert!(at < Duration::from_secs(25), "the first picture took {at:?} without any input");
}

#[test]
fn a_project_opened_in_the_running_app_shows_its_first_picture_without_any_input() {
    let dir = std::env::temp_dir().join(format!("sq-first-picture-app-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp folder");
    let Some(file) = project_with_clip(&dir) else {
        eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
        return;
    };
    if crate::surface::shared_gpu().is_none() {
        eprintln!("skipped: no GPU adapter");
        return;
    }
    let opened = open_with(&file, &dir.join("support"), Duration::from_secs(10), OpenPath::SessionOpen);
    let _ = std::fs::remove_dir_all(&dir);
    eprintln!(
        "in-app open: first picture after {:?}; generations {:?}",
        opened.first_picture, opened.drawn_generations
    );
    let at = opened.first_picture.expect("no frame with a monitor picture was drawn within 10 s without any input");
    assert!(at < Duration::from_secs(5), "the first picture took {at:?} without any input");
}

#[test]
fn a_project_opened_by_the_shell_flow_shows_its_first_picture_without_any_input() {
    let dir = std::env::temp_dir().join(format!("sq-first-picture-flow-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp folder");
    let Some(file) = project_with_clip(&dir) else {
        eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
        return;
    };
    if crate::surface::shared_gpu().is_none() {
        eprintln!("skipped: no GPU adapter");
        return;
    }
    let opened = open_with(&file, &dir.join("support"), Duration::from_secs(10), OpenPath::ShellFlow);
    let _ = std::fs::remove_dir_all(&dir);
    eprintln!(
        "shell flow open: first picture after {:?}; generations {:?}",
        opened.first_picture, opened.drawn_generations
    );
    let at = opened.first_picture.expect("no frame with a monitor picture was drawn within 10 s without any input");
    assert!(at < Duration::from_secs(5), "the first picture took {at:?} without any input");
}

/// Every file of a project is opened once at project open: the engine, the info probe, the posters and the proxy decision
/// share one demuxer (a second index pass over a multi-GB camera file is what made the open slow).
#[test]
fn a_project_opens_each_of_its_files_once() {
    let dir = std::env::temp_dir().join(format!("sq-first-picture-opens-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp folder");
    let Some(file) = project_with_clip(&dir) else {
        eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
        return;
    };
    if crate::surface::shared_gpu().is_none() {
        eprintln!("skipped: no GPU adapter");
        return;
    }
    let opened = open_and_wait(&file, &dir.join("support"), Duration::from_secs(10));
    assert!(opened.first_picture.is_some(), "no video picture within 10 s");
    // The posters and the proxy decision run on workers after the first picture.
    std::thread::sleep(Duration::from_millis(1500));
    let clip = dir.join("clip.mp4");
    let opens = FFmpegDemuxer::opens_of(&clip);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(opens, 1, "the clip was opened {opens} times at project open");
}

/// A 4K 10-bit 4:2:2 full-range H.264 clip like the Sony files: the open reads the container's index and the SPS only (no
/// payload, no decoded picture to learn the pixel format), and the first real video picture arrives without any input.
/// `ffmpeg` with libx264 makes the clip; without it the test has nothing to open.
#[test]
fn a_big_camera_clip_shows_its_first_real_picture_after_a_quick_open() {
    let dir = std::env::temp_dir().join(format!("sq-first-picture-camera-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp folder");
    let clip = dir.join("camera.mp4");
    let encoded = [crate::export::tests::ffmpeg_tool(), Some("ffmpeg".into())].into_iter().flatten().any(|tool| {
        std::process::Command::new(tool)
            .args(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=30:duration=1"])
            .args([
                "-c:v",
                "libx264",
                "-preset",
                "ultrafast",
                "-g",
                "1",
                "-pix_fmt",
                "yuv422p10le",
                "-color_range",
                "pc",
            ])
            .arg(&clip)
            .status()
            .is_ok_and(|s| s.success())
    });
    if !encoded || crate::surface::shared_gpu().is_none() {
        eprintln!("skipped: no ffmpeg with libx264 or no GPU adapter");
        let _ = std::fs::remove_dir_all(&dir);
        return;
    }
    let file = project_around(&dir, &clip).expect("a project");
    let opened = open_and_wait(&file, &dir.join("support"), Duration::from_secs(30));
    let shared = FFmpegDemuxer::open_shared(&clip).expect("the shared open");
    let opens = FFmpegDemuxer::opens_of(&clip);
    let _ = std::fs::remove_dir_all(&dir);
    eprintln!("camera clip: first real picture after {:?}, opened {opens} time(s)", opened.first_picture);
    let at = opened.first_picture.expect("no video picture within 30 s without any input");
    assert!(at < Duration::from_secs(10), "the first real picture took {at:?}");
    assert!(shared.index_without_payload(), "the open read the whole file to index it");
    assert!(shared.facts_from_sps(), "the open decoded a picture to learn the pixel format");
    assert_eq!(opens, 1, "the clip was opened {opens} times");
}

/// The temp folder, the saved project around the 1 s test clip and the clip itself, `None` when there is nothing to open with.
fn fixture(name: &str) -> Option<(std::path::PathBuf, std::path::PathBuf)> {
    let dir = std::env::temp_dir().join(format!("sq-first-picture-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp folder");
    let Some(file) = project_with_clip(&dir) else {
        eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
        return None;
    };
    if crate::surface::shared_gpu().is_none() {
        eprintln!("skipped: no GPU adapter");
        return None;
    }
    Some((dir, file))
}

fn assert_quick(opened: &Opened, what: &str) {
    let at = opened.first_picture.unwrap_or_else(|| panic!("{what}: no real picture within 10 s without any input"));
    assert!(at < Duration::from_secs(5), "{what}: the first picture took {at:?} without any input");
}

#[test]
fn a_press_on_the_recent_card_shows_the_first_picture_without_any_input() {
    let Some((dir, file)) = fixture("card") else { return };
    let opened = open_with(&file, &dir.join("support"), Duration::from_secs(10), OpenPath::RecentCard);
    let _ = std::fs::remove_dir_all(&dir);
    assert_quick(&opened, "Recent card");
}

/// Waits like the window loop does (a turn on a wake or while a frame is due) until `want` holds for the monitor picture;
/// the time it took, `None` after `limit`.
fn wait_for(
    app: &Headless,
    picture: &MonitorPicture,
    wakes: &Arc<AtomicUsize>,
    limit: Duration,
    want: impl Fn(&MonitorPicture) -> bool,
) -> Option<Duration> {
    let (began, mut seen, mut frame_due) = (Instant::now(), usize::MAX, false);
    while began.elapsed() < limit {
        let woken = wakes.load(Ordering::SeqCst);
        if woken != seen || frame_due {
            seen = woken;
            let (_, list) = app.turn();
            if list.is_some() && want(picture) {
                return Some(began.elapsed());
            }
            frame_due = app.with(|a| a.needs_redraw()).unwrap_or(false);
        }
        std::thread::sleep(Duration::from_millis(if frame_due { 16 } else { 2 }));
    }
    None
}

/// A project of two sequences: the first is empty, the second plays the first second of `clip` from 0.
fn two_sequences(dir: &Path, clip: &Path) -> Option<(std::path::PathBuf, Id)> {
    let media = Id::from_u128(100);
    let reference = MediaRef::new(media, "clip", &clip.to_string_lossy(), MediaFingerprint::new(1));
    let mut track = Track::new(Id::from_u128(900), TrackKind::Video);
    let source = TimeRange::new(Time::ZERO, Time::seconds(1));
    track.set_clips(vec![Clip::new(Id::from_u128(10), "c", media, TrackKind::Video, source, Time::ZERO)]);
    let mut format = SequenceFormat::new(Time::new(1, 25));
    (format.width, format.height) = (320, 180);
    let empty = Timeline::new(
        Id::from_u128(1),
        "empty",
        format.clone(),
        vec![Track::new(Id::from_u128(901), TrackKind::Video)],
    );
    let second = Id::from_u128(3);
    let plays = Timeline::new(second, "plays", format, vec![track]);
    let project = Project::new(Id::from_u128(2), "p", vec![reference], vec![empty, plays]);
    let file = dir.join("two.sqproj");
    let mut session =
        sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.to_path_buf()));
    session.save_as(&file).ok()?;
    Some((file, second))
}

#[test]
fn switching_the_sequence_shows_its_picture_without_any_input() {
    let Some((dir, _)) = fixture("tabs") else { return };
    let clip = dir.join("clip.mp4");
    let Some((file, second)) = two_sequences(&dir, &clip) else { return };
    let (app, picture, wakes) = start_app(Some(&file), &dir.join("support"));
    first_frames(&app);
    assert!(!shows_content(&picture), "the first sequence is empty");
    app.with(|a| a.session_mut().set_active_timeline(second));
    let at = wait_for(&app, &picture, &wakes, Duration::from_secs(10), shows_content);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(at.is_some_and(|t| t < Duration::from_secs(5)), "switching sequences showed no picture: {at:?}");
}

#[test]
fn undoing_a_delete_shows_the_picture_again_without_any_input() {
    let Some((dir, file)) = fixture("undo") else { return };
    let (app, picture, wakes) = start_app(Some(&file), &dir.join("support"));
    first_frames(&app);
    let shown = wait_for(&app, &picture, &wakes, Duration::from_secs(10), shows_content);
    assert!(shown.is_some(), "the opened project shows its picture");
    app.with(|a| {
        a.session_mut().perform("Delete", None, |p| {
            for t in &mut p.timelines {
                for track in &mut t.tracks {
                    track.set_clips(Vec::new());
                }
            }
        });
    });
    let cleared = wait_for(&app, &picture, &wakes, Duration::from_secs(10), |p| !shows_content(p));
    assert!(cleared.is_some(), "the deleted clip leaves the monitor empty");
    app.with(|a| a.session_mut().undo());
    let back = wait_for(&app, &picture, &wakes, Duration::from_secs(10), shows_content);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(back.is_some_and(|t| t < Duration::from_secs(5)), "undo showed no picture: {back:?}");
}

/// A first clip that starts after zero leaves the monitor black at open (the playhead is in a gap, there is nothing to show
/// and nothing to open); the picture comes with the move of the playhead into the clip, again without any further input.
/// A DMG check of such a project once looked like a failed open (bug 29) because the black was read as a missing frame.
#[test]
fn a_clip_after_a_gap_shows_its_picture_when_the_playhead_reaches_it_without_any_input() {
    let dir = std::env::temp_dir().join(format!("sq-first-picture-gap-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp folder");
    let clip = ffmpeg_tool().and_then(|tool| crate::export::tests::make_clip(&tool, &dir));
    let (Some(clip), Some(_)) = (clip, crate::surface::shared_gpu()) else {
        eprintln!("skipped: no ffmpeg command, no linked FFmpeg shim or no GPU adapter");
        let _ = std::fs::remove_dir_all(&dir);
        return;
    };
    let file = project_starting_at(&dir, &clip, Time::new(2, 5)).expect("a project");
    let (app, picture, wakes) = start_app(Some(&file), &dir.join("support"));
    let at_zero = run_loop(&app, &picture, &wakes, Instant::now(), Duration::from_millis(1500));
    assert!(at_zero.first_picture.is_none(), "the playhead sits in the gap, yet the monitor shows a clip");
    let inside = Time::new(1, 2);
    assert!(app.with(|a| a.session_mut().seek(inside)).is_some(), "the app was busy");
    let reached = run_loop(&app, &picture, &wakes, Instant::now(), Duration::from_secs(10));
    let _ = std::fs::remove_dir_all(&dir);
    eprintln!("gap project: black at zero, picture {:?} after the playhead reached the clip", reached.first_picture);
    let at = reached.first_picture.expect("no picture after the playhead moved into the clip, without any input");
    assert!(at < Duration::from_secs(5), "the picture took {at:?} after the playhead reached the clip");
}

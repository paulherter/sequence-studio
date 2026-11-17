//! The Export sheet over a running queue: the Export button end to end, and the cut-down jobs that write while the sheet stays up.

use super::*;
use crate::shell_live::test_rig::answer_swept;
use crate::tests::Rig;
use sq_core_model::{
    Clip, DeliveryPlatform, DeliveryTarget, Marker, MarkerColor, Project, SequenceFormat, Timeline, Track, TrackKind,
};
use sq_core_time::{IdSource, SequentialIds, TimeRange};
use sq_editor_session::{EditorSession, SessionDeps};
use sq_export::core::error::ExportError;
use sq_export::core::loudness::LoudnessReport;
use sq_export::core::preset::{ExportPreferences, QualityStep};
use sq_export::core::queue::ExportSources;
use sq_export::core::settings::{BitrateMode, ExportSettings, VideoCodec};
use sq_export::core::traits::{AudioSource, ExportEncoding, ExportFrame, FrameSource};
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat, SQFrameStorage};
use std::path::PathBuf;

struct Pixels;
impl SQFrameStorage for Pixels {}

struct Frames;
impl FrameSource for Frames {
    fn frame_count(&self) -> usize {
        50
    }
    fn frame_duration(&self) -> Time {
        Time::new(1, 25)
    }
    fn frame(&mut self, index: usize) -> Result<ExportFrame, ExportError> {
        Ok(SQFrame::new(
            4,
            2,
            SQFramePixelFormat::Rgba8,
            SQFrameColorSpace::Rec709,
            Time::new(index as i64, 25),
            Arc::new(Pixels),
        ))
    }
}

/// An encoder that writes a one byte file, so the queue has something to finish.
struct WritesAFile;
impl ExportEncoding for WritesAFile {
    fn export(
        &self,
        _: &mut dyn FrameSource,
        _: Option<&mut dyn AudioSource>,
        _: &ExportSettings,
        url: &Path,
        _: &CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Option<LoudnessReport>, ExportError> {
        std::fs::write(url, b"x").map_err(|e| ExportError::Other(e.to_string()))?;
        progress(1.0);
        Ok(None)
    }
}

fn cut_down_marker(at: i64) -> Marker {
    Marker {
        id: Id::from_u128(at as u128 + 1),
        time: Time::seconds(at),
        name: "cut-down 6".into(),
        color: MarkerColor::Cyan,
        comment: String::new(),
        duration: Time::seconds(6),
    }
}

/// A session over a two second clip with two cut-down markers.
fn session() -> EditorSession {
    session_at(None)
}

/// The same session, saved at `file` (so Export proposes the `Exports` folder beside it).
fn session_at(file: Option<PathBuf>) -> EditorSession {
    session_built(file, None)
}

/// The session of `session()` on a frame of `width` x `height`, made for `platform` when given.
fn session_shaped(width: i64, height: i64, platform: Option<DeliveryPlatform>) -> EditorSession {
    session_built(None, Some((width, height, platform)))
}

fn session_built(file: Option<PathBuf>, shape: Option<(i64, i64, Option<DeliveryPlatform>)>) -> EditorSession {
    let mut ids = SequentialIds::default();
    let clip = Clip::new(
        ids.next_id(),
        "c",
        ids.next_id(),
        TrackKind::Video,
        TimeRange::new(Time::ZERO, Time::new(2, 1)),
        Time::ZERO,
    );
    let mut video = Track::new(ids.next_id(), TrackKind::Video);
    video.overwrite(clip, &mut ids).expect("clip fits");
    let mut tl = Timeline::new(ids.next_id(), "Main", SequenceFormat::new(Time::new(1, 25)), vec![video]);
    tl.markers = vec![cut_down_marker(0), cut_down_marker(20)];
    if let Some((width, height, platform)) = shape {
        tl.format.width = width;
        tl.format.height = height;
        tl.delivery_target =
            platform.map(|platform| DeliveryTarget { platform, target_lufs: -14.0, true_peak_db: -1.0 });
    }
    let project = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-draw-shell-tests-export"));
    deps.ids = Box::new(ids);
    deps.file_url = file;
    EditorSession::new(project, deps)
}

fn folder(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("sq-export-flow-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    let _ = std::fs::create_dir_all(&d);
    d
}

/// A rig whose shell exports through a queue with the file-writing encoder into `dir`.
/// An encoder that reports 40 % and then waits for the test, like a long export.
struct Slow(Arc<std::sync::atomic::AtomicBool>);
impl ExportEncoding for Slow {
    fn export(
        &self,
        _: &mut dyn FrameSource,
        _: Option<&mut dyn AudioSource>,
        _: &ExportSettings,
        url: &Path,
        _: &CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Option<LoudnessReport>, ExportError> {
        progress(0.4);
        while !self.0.load(std::sync::atomic::Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(2));
        }
        std::fs::write(url, b"x").map_err(|e| ExportError::Other(e.to_string()))?;
        progress(1.0);
        Ok(None)
    }
}

fn rig(dir: &Path) -> (Rig, Arc<ExportQueue>) {
    let rig = Rig::new();
    let queue = Arc::new(ExportQueue::new(Arc::new(WritesAFile)));
    let (q, dir) = (Arc::clone(&queue), dir.to_path_buf());
    rig.with(|r| {
        r.session = session();
        r.shell.export.sources = Some(Arc::new(|_, _| Ok(ExportSources::new(Box::new(Frames), None))));
        r.shell.export.queue = Some(q);
        r.shell.export.directory = dir;
    });
    (rig, queue)
}

/// Runs the queue on a thread, like the app does on `RunExportQueue`.
fn run_queue(queue: &Arc<ExportQueue>) -> std::thread::JoinHandle<()> {
    let queue = Arc::clone(queue);
    std::thread::spawn(move || queue.run_all())
}

fn all_done(queue: &ExportQueue) -> bool {
    let all = queue.all_statuses();
    !all.is_empty() && all.iter().all(|s| matches!(s.state, ExportJobState::Done(_) | ExportJobState::Failed(_)))
}

/// Lets the flows poll until the jobs ended (the fake clock moves the 250 ms polls on).
fn settle(rig: &Rig, queue: &ExportQueue) {
    for _ in 0..400 {
        rig.rt.run_until_stalled();
        if all_done(queue) {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
        rig.rt.advance(Duration::from_millis(250));
    }
    rig.rt.advance(Duration::from_millis(250));
    rig.rt.run_until_stalled();
}

#[test]
fn the_export_button_writes_the_file() {
    let dir = folder("button");
    let (rig, queue) = rig(&dir);
    rig.rt.ex.spawn_local(ShellHost::show_export(rig.handle()));
    rig.rt.run_until_stalled();
    assert!(rig.has_dialog(), "the sheet is up");
    let titles =
        rig.with(|r| r.shell.dialog().map(|d| d.model.buttons.iter().map(|b| b.title.clone()).collect::<Vec<_>>()));
    assert_eq!(titles, Some(vec!["Export".to_string(), "Cancel".to_string(), "Other Formats\u{2026}".to_string()]));
    assert!(rig.with(|r| {
        r.shell.dialog().is_some_and(|d| d.content.is_some() && d.card_height == Some(740.0) && d.width == 1000.0)
    }));
    answer_swept(&rig, SQDialogResponse::FIRST);
    // A preflight note would ask once more: Export Anyway.
    if rig.has_dialog() {
        answer_swept(&rig, SQDialogResponse::FIRST);
    }
    assert!(!queue.all_statuses().is_empty(), "the Export button queued a job");
    let worker = run_queue(&queue);
    settle(&rig, &queue);
    worker.join().expect("the queue thread ends");
    assert!(dir.join("Main.mp4").is_file(), "the file is written: {:?}", queue.all_statuses());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_sheet_leaves_no_exports_folder_on_cancel_and_an_export_creates_it() {
    let root = folder("exports-folder");
    let exports = root.join("Exports");
    let (rig, queue) = rig(&root);
    rig.with(|r| r.session = session_at(Some(root.join("Film.sqproj"))));
    rig.rt.ex.spawn_local(ShellHost::show_export(rig.handle()));
    rig.rt.run_until_stalled();
    assert!(rig.has_dialog(), "the sheet is up");
    assert!(!exports.exists(), "opening the sheet creates no folder");
    answer_swept(&rig, SQDialogResponse::SECOND);
    assert!(!rig.has_dialog(), "Cancel closed the sheet");
    assert!(!exports.exists(), "Cancel leaves no folder behind");
    rig.rt.ex.spawn_local(ShellHost::show_export(rig.handle()));
    rig.rt.run_until_stalled();
    answer_swept(&rig, SQDialogResponse::FIRST);
    if rig.has_dialog() {
        answer_swept(&rig, SQDialogResponse::FIRST);
    }
    assert!(!queue.all_statuses().is_empty(), "the Export button queued a job");
    assert!(exports.is_dir(), "starting the export creates the folder");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn cut_downs_run_end_to_end_while_the_sheet_stays_up() {
    let dir = folder("cuts");
    let (rig, queue) = rig(&dir);
    rig.rt.ex.spawn_local(ShellHost::show_export(rig.handle()));
    rig.rt.run_until_stalled();
    // The Export Cut-downs button of the open sheet.
    rig.cx(|h, cx| h.route_form_changes(cx, vec![("cuts_run".to_string(), FormValue::Index(0))]));
    rig.rt.run_until_stalled();
    assert!(!queue.all_statuses().is_empty(), "the cut-down jobs are queued");
    assert!(rig.has_dialog(), "the sheet is still up");
    let worker = run_queue(&queue);
    settle(&rig, &queue);
    worker.join().expect("the queue thread ends");
    assert!(
        queue.all_statuses().iter().all(|s| matches!(s.state, ExportJobState::Done(_))),
        "{:?}",
        queue.all_statuses()
    );
    assert!(dir.join("Main_6s.mp4").is_file());
    rig.run_flows();
    assert!(
        rig.with(|r| r.shell.dialog().is_some_and(|d| d.content.is_some())),
        "no finished dialog replaced the sheet"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// One Export-button run into `dir`; `answers` are the responses to the questions that may follow the sheet.
/// Returns the queue ids of the new jobs after running the queue to its end.
fn export_again(rig: &Rig, queue: &Arc<ExportQueue>, answer: SQDialogResponse) -> usize {
    let before = queue.all_statuses().len();
    rig.rt.ex.spawn_local(ShellHost::show_export(rig.handle()));
    rig.rt.run_until_stalled();
    answer_swept(rig, SQDialogResponse::FIRST);
    // The question about the file that is already there.
    if rig.has_dialog() {
        answer_swept(rig, answer);
    }
    let worker = run_queue(queue);
    settle(rig, queue);
    worker.join().expect("the queue thread ends");
    queue.all_statuses().len() - before
}

#[test]
fn keep_both_writes_a_second_file_while_the_first_finished_card_is_up() {
    let dir = folder("keepboth");
    let (rig, queue) = rig(&dir);
    assert_eq!(export_again(&rig, &queue, SQDialogResponse::FIRST), 1);
    assert!(dir.join("Main.mp4").is_file());
    rig.run_flows();
    // The "Export finished" card of the first run stays up; a second run starts behind it.
    assert_eq!(export_again(&rig, &queue, SQDialogResponse::FIRST), 1);
    assert!(dir.join("Main 2.mp4").is_file(), "{:?}", queue.all_statuses());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn replace_overwrites_and_cancel_queues_nothing() {
    let dir = folder("replace");
    let (rig, queue) = rig(&dir);
    assert_eq!(export_again(&rig, &queue, SQDialogResponse::FIRST), 1);
    std::fs::write(dir.join("Main.mp4"), b"old file").expect("seed");
    assert_eq!(export_again(&rig, &queue, SQDialogResponse::SECOND), 1);
    assert_eq!(std::fs::read(dir.join("Main.mp4")).expect("read"), b"x");
    assert!(!dir.join("Main 2.mp4").exists());
    let cancelled = export_again(&rig, &queue, SQDialogResponse::THIRD);
    assert_eq!(cancelled, 0, "Cancel queues nothing");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_running_export_shows_its_ring_at_once() {
    let dir = folder("ring");
    let release = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (rig, _) = rig(&dir);
    let queue = Arc::new(ExportQueue::new(Arc::new(Slow(Arc::clone(&release)))));
    rig.with(|r| r.shell.export.queue = Some(Arc::clone(&queue)));
    rig.rt.ex.spawn_local(ShellHost::show_export(rig.handle()));
    rig.rt.run_until_stalled();
    answer_swept(&rig, SQDialogResponse::FIRST);
    if rig.has_dialog() {
        answer_swept(&rig, SQDialogResponse::FIRST);
    }
    assert_eq!(rig.with(|r| r.shell.export.progress), Some(0.0), "queued: the ring is up before the worker starts");
    let worker = run_queue(&queue);
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(5));
        rig.rt.advance(Duration::from_millis(250));
        rig.rt.run_until_stalled();
    }
    let p = rig.with(|r| r.shell.export.progress).expect("a running export has a ring");
    assert!(p > 0.0 && p < 1.0, "progress {p}");
    release.store(true, std::sync::atomic::Ordering::SeqCst);
    settle(&rig, &queue);
    worker.join().expect("the queue thread ends");
    assert_eq!(rig.with(|r| r.shell.export.progress), None, "the ring goes when the job ends");
    let _ = std::fs::remove_dir_all(&dir);
}

/// What the sheet shows of the picks: format, quality step and the rate of that step.
fn picks(m: &ExportDialogModel) -> (VideoCodec, Option<QualityStep>, BitrateMode) {
    (m.codec(), m.quality_step(), m.settings().video.bitrate)
}

/// Open the sheet, Cancel it; the model the next opening makes.
fn open_cancel_and_reopen(rig: &Rig) -> ExportDialogModel {
    rig.rt.ex.spawn_local(ShellHost::show_export(rig.handle()));
    rig.rt.run_until_stalled();
    answer_swept(rig, SQDialogResponse::SECOND);
    rig.with(|r| r.shell.prepare_export_model(&r.session)).expect("the sheet's model")
}

#[test]
fn a_closed_sheet_opens_again_with_the_last_picks() {
    let dir = folder("reopen");
    let shapes = [
        (1080, 1920, Some(DeliveryPlatform::Tiktok)),
        (1080, 1920, None),
        (1920, 1080, None),
        (1920, 1080, Some(DeliveryPlatform::Youtube)),
    ];
    for (w, h, platform) in shapes {
        let (rig, _) = rig(&dir);
        rig.with(|r| r.session = session_shaped(w, h, platform));
        let open = || rig.with(|r| r.shell.prepare_export_model(&r.session)).expect("the sheet's model");
        let mut first = open();
        assert_eq!(first.codec(), VideoCodec::H264, "{w}x{h} {platform:?}: the sheet starts on H.264");
        first.set_codec(VideoCodec::Hevc);
        first.set_quality_step(QualityStep::Smaller);
        let want = picks(&first);
        assert_eq!(want.1, Some(QualityStep::Smaller));
        rig.with(|r| r.shell.remember_export_choices(&first));
        assert_eq!(picks(&open()), want, "{w}x{h} {platform:?}: the next opening shows the last picks");
        // Cancel stores what the sheet showed, so a second Cancel keeps them too.
        assert_eq!(picks(&open_cancel_and_reopen(&rig)), want, "{w}x{h} {platform:?}: after Cancel");
        assert_eq!(picks(&open_cancel_and_reopen(&rig)), want, "{w}x{h} {platform:?}: after a second Cancel");
        // A new process: the stored values are read back from the defaults.
        let (data, last) = rig.with(|r| {
            (r.shell.defaults.data("sq.export.preferences"), r.shell.defaults.string("sq.export.lastPresetID"))
        });
        let (fresh, _) = self::rig(&dir);
        fresh.with(|r| {
            r.session = session_shaped(w, h, platform);
            r.shell.defaults.set_data("sq.export.preferences", &data.expect("stored picks"));
            r.shell.defaults.set_string("sq.export.lastPresetID", &last.expect("stored preset"));
        });
        let again = fresh.with(|r| r.shell.prepare_export_model(&r.session)).expect("the sheet's model");
        assert_eq!(picks(&again), want, "{w}x{h} {platform:?}: in a new process");
        assert_eq!(again.range_mode(), first.range_mode(), "the range follows the sequence as before");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn picks_made_on_another_shape_do_not_override_the_platform_preset() {
    let dir = folder("reshaped");
    let (rig, _) = rig(&dir);
    rig.with(|r| r.session = session_shaped(1920, 1080, Some(DeliveryPlatform::Youtube)));
    let mut m = rig.with(|r| r.shell.prepare_export_model(&r.session)).expect("the sheet's model");
    m.set_codec(VideoCodec::Hevc);
    rig.with(|r| r.shell.remember_export_choices(&m));
    // The sequence became a TikTok one: its own preset decides again.
    rig.with(|r| r.session = session_shaped(1080, 1920, Some(DeliveryPlatform::Tiktok)));
    let m = rig.with(|r| r.shell.prepare_export_model(&r.session)).expect("the sheet's model");
    assert_eq!(m.codec(), VideoCodec::H264);
    assert_ne!(m.shown_preset_id(), ExportPreferences::CUSTOM_PRESET_ID, "the TikTok preset, not the old Custom");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cancel_stores_the_picks_for_the_next_opening() {
    let dir = folder("cancel-keeps");
    let (rig, _) = rig(&dir);
    rig.rt.ex.spawn_local(ShellHost::show_export(rig.handle()));
    rig.rt.run_until_stalled();
    assert!(rig.has_dialog(), "the sheet is up");
    assert!(rig.with(|r| r.shell.defaults.data("sq.export.preferences")).is_none(), "nothing stored before");
    answer_swept(&rig, SQDialogResponse::SECOND);
    assert!(!rig.has_dialog(), "Cancel closed the sheet");
    let stored = rig.with(|r| r.shell.defaults.data("sq.export.preferences"));
    assert!(stored.is_some(), "Cancel kept the picks");
    assert!(rig.with(|r| r.shell.defaults.string("sq.export.lastPresetID")).is_some(), "and the preset");
    let _ = std::fs::remove_dir_all(&dir);
}

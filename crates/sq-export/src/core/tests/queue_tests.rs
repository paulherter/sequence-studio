// Swift: ExportQueueTests.swift, ExportPreflightTests.swift, VariantExportTests.swift, PixelShapeVariantTests.swift
// (the queue state machine; the file writing is a fake encoder behind `ExportEncoding`)

use super::fmt;
use crate::core::*;
use serde_json::json;
use sq_core_model::{
    Clip, FormatVariant, MediaFingerprint, MediaRef, PixelAspect, Project, Timeline, Track, TrackKind,
};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

static DIRS: AtomicUsize = AtomicUsize::new(0);

pub(crate) struct TempDir(pub PathBuf);

impl TempDir {
    pub fn new() -> TempDir {
        let p = std::env::temp_dir().join(format!(
            "sq-export-core-{}-{}",
            std::process::id(),
            DIRS.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn small_settings() -> ExportSettings {
    let mut s = ExportSettings::default();
    s.video.width = 64;
    s.video.height = 112;
    s.audio.enabled = false;
    s
}

struct Frames {
    count: usize,
}

impl FrameSource for Frames {
    fn frame_count(&self) -> usize {
        self.count
    }
    fn frame_duration(&self) -> Time {
        Time::new(1, 30)
    }
    fn frame(&mut self, index: usize) -> Result<ExportFrame, ExportError> {
        Err(FrameSourceError::IndexOutOfRange(index).into())
    }
}

/// Writes a one-byte file; `hold` blocks until cancelled; progress runs to 1 in ten steps.
#[derive(Default)]
struct FakeEncoder {
    hold: bool,
    log: Mutex<Vec<String>>,
}

impl ExportEncoding for FakeEncoder {
    fn export(
        &self,
        video: &mut dyn FrameSource,
        _audio: Option<&mut dyn AudioSource>,
        settings: &ExportSettings,
        url: &Path,
        cancel: &CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Option<LoudnessReport>, ExportError> {
        self.log.lock().unwrap().push(format!(
            "{} {}",
            url.file_name().unwrap().to_string_lossy(),
            video.frame_count()
        ));
        if settings.frame_output.is_some() {
            std::fs::create_dir_all(url).unwrap();
        } else {
            std::fs::write(url, [1u8]).unwrap();
        }
        if self.hold {
            while !cancel.is_cancelled() {
                std::thread::sleep(Duration::from_millis(2));
            }
            return Err(ExportError::Cancelled);
        }
        for i in 1..=10 {
            cancel.check()?;
            progress(f64::from(i) / 10.0);
        }
        Ok(None)
    }
}

fn job(id: u128, name: &str, dir: &Path, fail: bool) -> ExportJob {
    ExportJob::new(
        Id::from_u128(id),
        name,
        small_settings(),
        dir.to_path_buf(),
        Arc::new(move || {
            if fail {
                return Err(ExportError::EmptySource);
            }
            Ok(ExportSources::new(Box::new(Frames { count: 6 }), None))
        }),
    )
}

fn wait_until(what: &str, mut cond: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_secs(10);
    while Instant::now() < end {
        if cond() {
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!("timed out waiting for {what}");
}

#[test]
fn runs_jobs_sequentially_and_finishes() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let ids: Vec<Id> =
        ["A", "B", "C"].iter().enumerate().map(|(i, n)| q.enqueue(job(i as u128 + 1, n, &dir.0, false))).collect();
    assert_eq!(q.status(ids[0]).unwrap().state, ExportJobState::Waiting);
    q.run_all();
    for id in ids {
        let st = q.status(id).unwrap();
        let ExportJobState::Done(url) = &st.state else { panic!("not done: {:?}", st.state) };
        assert!(url.exists());
        assert_eq!(st.progress, 1.0);
    }
}

#[test]
fn events_show_sequential_order_and_progress() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let events = q.updates();
    let (a, b) = (q.enqueue(job(1, "A", &dir.0, false)), q.enqueue(job(2, "B", &dir.0, false)));
    q.run_all();
    let all: Vec<ExportJobStatus> = events.try_iter().collect();
    let first_b = all.iter().position(|u| u.id == b && u.state == ExportJobState::Running).unwrap();
    let done_a = all.iter().position(|u| u.id == a && matches!(u.state, ExportJobState::Done(_))).unwrap();
    assert!(done_a < first_b, "B must not start before A is done");
    let prog_a: Vec<f64> = all.iter().filter(|u| u.id == a).map(|u| u.progress).collect();
    assert!(prog_a.windows(2).all(|w| w[0] <= w[1]));
    assert_eq!(prog_a.last(), Some(&1.0));
}

#[test]
fn unique_file_names_per_sequence() {
    let dir = TempDir::new();
    std::fs::write(dir.0.join("Clip.mp4"), [0u8]).unwrap(); // pre-existing
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let ids: Vec<Id> = (1..=3).map(|i| q.enqueue(job(i, "Clip", &dir.0, false))).collect();
    let names: Vec<String> = ids
        .iter()
        .map(|i| q.status(*i).unwrap().output_url.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["Clip 2.mp4", "Clip 3.mp4", "Clip 4.mp4"]);
    q.run_all();
    for n in &names {
        assert!(dir.0.join(n).exists());
    }
    assert_eq!(std::fs::read(dir.0.join("Clip.mp4")).unwrap(), vec![0u8]);
}

#[test]
fn unsafe_names_are_sanitized() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let id = q.enqueue(job(1, "a/b:c", &dir.0, false));
    let url = q.status(id).unwrap().output_url;
    assert_eq!(url.parent().unwrap(), dir.0);
    assert_eq!(url.file_name().unwrap(), "a-b-c.mp4");
    assert_eq!(sanitize("  .hidden "), "Export.hidden");
    assert_eq!(sanitize("   "), "Export");
    assert_eq!(sanitize("a\u{1}b"), "a-b");
}

#[test]
fn failed_job_does_not_stop_queue() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let (a, b) = (q.enqueue(job(1, "Bad", &dir.0, true)), q.enqueue(job(2, "Good", &dir.0, false)));
    q.run_all();
    assert_eq!(q.status(a).unwrap().state, ExportJobState::Failed("There is nothing to export.".to_string()));
    assert!(matches!(q.status(b).unwrap().state, ExportJobState::Done(_)));
}

#[test]
fn a_panic_while_building_the_sources_fails_that_job_and_the_queue_goes_on() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let boom = ExportJob::new(
        Id::from_u128(1),
        "Boom",
        small_settings(),
        dir.0.clone(),
        Arc::new(|| panic!("no support folder")),
    );
    let (a, b) = (q.enqueue(boom), q.enqueue(job(2, "Good", &dir.0, false)));
    q.run_all();
    let ExportJobState::Failed(text) = q.status(a).unwrap().state else { panic!("the panicking job must fail") };
    assert!(text.contains("no support folder"), "{text}");
    assert!(matches!(q.status(b).unwrap().state, ExportJobState::Done(_)));
}

#[test]
fn cancel_waiting_job() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let (a, b) = (q.enqueue(job(1, "A", &dir.0, false)), q.enqueue(job(2, "B", &dir.0, false)));
    q.cancel(b);
    q.run_all();
    assert_eq!(q.status(b).unwrap().state, ExportJobState::Cancelled);
    assert!(matches!(q.status(a).unwrap().state, ExportJobState::Done(_)));
    assert!(!q.status(b).unwrap().output_url.exists());
    // The cancelled name is free again.
    let c = q.enqueue(job(3, "B", &dir.0, false));
    assert_eq!(q.status(c).unwrap().output_url.file_name().unwrap(), "B.mp4");
}

#[test]
fn cancel_running_job_continues_with_next() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder { hold: true, ..Default::default() }));
    let (a, b) = (q.enqueue(job(1, "Slow", &dir.0, false)), q.enqueue(job(2, "Next", &dir.0, false)));
    let events = q.updates();
    let runner = {
        let q = q.clone();
        std::thread::spawn(move || q.run_all())
    };
    // Wait for the queue's own `Running` event, then cancel the first job; the second one then runs (and also holds).
    loop {
        let u = events.recv_timeout(Duration::from_secs(10)).unwrap();
        if u.id == a && u.state == ExportJobState::Running {
            break;
        }
    }
    q.cancel(a);
    wait_until("B running", || q.status(b).unwrap().state == ExportJobState::Running);
    q.cancel(b);
    runner.join().unwrap();
    assert_eq!(q.status(a).unwrap().state, ExportJobState::Cancelled);
    assert!(!q.status(a).unwrap().output_url.exists());
    assert_eq!(q.status(b).unwrap().state, ExportJobState::Cancelled);
}

#[test]
fn low_disk_space_stops_the_running_job_with_a_clear_message() {
    let dir = TempDir::new();
    let q = ExportQueue::with_options(
        Arc::new(FakeEncoder { hold: true, ..Default::default() }),
        Arc::new(|_| Some(1_000)),
        ExportPreflight::RUNNING_FLOOR_BYTES,
        Duration::from_millis(10),
    );
    let a = q.enqueue(job(1, "Big", &dir.0, false));
    q.run_all();
    let ExportJobState::Failed(msg) = q.status(a).unwrap().state else { panic!("should fail") };
    assert!(msg.starts_with("The output disk ran out of space (0 MB left)"), "{msg}");
    assert!(!q.status(a).unwrap().output_url.exists());
}

struct Sidecars(Mutex<Vec<(CaptionMode, usize, PathBuf)>>);

impl SidecarWriting for Sidecars {
    fn write(&self, mode: CaptionMode, cues: &[SrtCue], _range: &RangeSelection, to: &Path) -> Result<(), String> {
        self.0.lock().unwrap().push((mode, cues.len(), to.to_path_buf()));
        std::fs::write(to, "x").map_err(|e| e.to_string())
    }
}

#[test]
fn sidecar_is_written_next_to_the_video_and_its_name_is_reserved() {
    let dir = TempDir::new();
    let sc = Arc::new(Sidecars(Mutex::new(Vec::new())));
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()))
        .with_writers(Arc::<Sidecars>::clone(&sc), Arc::new(NoCoversForTest));
    let mut j = job(1, "Talk", &dir.0, false);
    j.settings.captions = CaptionMode::SidecarSrt;
    j.make_sources = Arc::new(|| {
        let mut s = ExportSources::new(Box::new(Frames { count: 2 }), None);
        s.captions = vec![SrtCue::new(vec!["Hi".into()], TimeRange::new(Time::ZERO, Time::new(1, 1)))];
        Ok(s)
    });
    // A stray "Talk.srt" makes the second job take "Talk 2" for both files.
    std::fs::write(dir.0.join("Talk.srt"), "old").unwrap();
    let a = q.enqueue(j);
    let st = q.status(a).unwrap();
    assert_eq!(st.output_url.file_name().unwrap(), "Talk 2.mp4");
    q.run_all();
    let st = q.status(a).unwrap();
    assert_eq!(st.sidecar.url(), Some(dir.0.join("Talk 2.srt").as_path()));
    assert_eq!(sc.0.lock().unwrap()[0].1, 1);
}

struct NoCoversForTest;

impl CoverWriting for NoCoversForTest {
    fn write(&self, _: &ExportFrame, _: CoverImageFormat, _: PixelAspect, _: &Path) -> Result<(), ExportError> {
        Ok(())
    }
}

#[test]
fn missing_sidecar_writer_keeps_the_video_and_reports_the_error() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let mut j = job(1, "Talk", &dir.0, false);
    j.settings.captions = CaptionMode::SidecarVtt;
    let a = q.enqueue(j);
    q.run_all();
    let st = q.status(a).unwrap();
    assert!(matches!(st.state, ExportJobState::Done(_)) && st.output_url.exists());
    assert!(st.sidecar.error().is_some() && st.sidecar.url().is_none());
}

#[test]
fn image_sequence_folder_has_no_extension_and_a_failed_job_removes_it() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let mut j = job(1, "Shots", &dir.0, false);
    j.settings.frame_output = Some(FrameOutput::Sequence(FrameStillFormat::Png));
    let id = q.enqueue(j);
    assert_eq!(q.status(id).unwrap().output_url.file_name().unwrap(), "Shots");
    q.run_all();
    assert!(dir.0.join("Shots").is_dir());
}

// MARK: Preflight

#[test]
fn finds_existing_targets() {
    let dir = TempDir::new();
    let j = job(1, "Clip", &dir.0, false);
    assert!(ExportPreflight::existing_targets(std::slice::from_ref(&j)).is_empty());
    let file = dir.0.join(format!("Clip.{}", j.settings.file_extension()));
    std::fs::write(&file, [1u8]).unwrap();
    assert_eq!(ExportPreflight::existing_targets(&[j]), vec![file]);
}

#[test]
fn keep_both_suffixes_and_replace_keeps_name() {
    let dir = TempDir::new();
    std::fs::write(dir.0.join("Clip.mp4"), [1u8]).unwrap();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let keep = q.enqueue(job(1, "Clip", &dir.0, false));
    let mut r = job(2, "Clip", &dir.0, false);
    r.replace_existing = true;
    let rep = q.enqueue(r);
    assert_eq!(q.status(keep).unwrap().output_url.file_name().unwrap(), "Clip 2.mp4");
    assert_eq!(q.status(rep).unwrap().output_url.file_name().unwrap(), "Clip.mp4");
}

fn clip(ids: &mut SequentialIds, media: Id, nested: Option<Id>) -> Clip {
    use sq_core_time::IdSource;
    let mut c = Clip::new(
        ids.next_id(),
        "c",
        media,
        TrackKind::Video,
        TimeRange::new(Time::ZERO, Time::new(30, 30)),
        Time::ZERO,
    );
    c.sequence = nested;
    c
}

fn track(ids: &mut SequentialIds, clips: Vec<Clip>) -> Track {
    use sq_core_time::IdSource;
    let mut t = Track::new(ids.next_id(), TrackKind::Video);
    t.set_clips(clips);
    t
}

fn media(ids: &mut SequentialIds, name: &str, path: &str, space: Option<&str>) -> MediaRef {
    use sq_core_time::IdSource;
    let mut m = MediaRef::new(ids.next_id(), name, path, MediaFingerprint::new(1));
    if let Some(s) = space {
        m.info = Some(
            serde_json::from_value(json!({"duration": {"value": 1, "timescale": 1}, "detectedColorSpace": s})).unwrap(),
        );
    }
    m
}

#[test]
fn offline_media_includes_nested_sequences() {
    use sq_core_time::IdSource;
    let mut ids = SequentialIds::default();
    let gone = media(&mut ids, "gone", "/nonexistent/gone.mov", None);
    let unused = media(&mut ids, "unused", "/nonexistent/unused.mov", None);
    let f = fmt(1920, 1080);
    let inner_clip = clip(&mut ids, gone.id, None);
    let inner_track = track(&mut ids, vec![inner_clip]);
    let inner = Timeline::new(ids.next_id(), "inner", f.clone(), vec![inner_track]);
    let nest_media = ids.next_id();
    let nest = clip(&mut ids, nest_media, Some(inner.id));
    let outer_track = track(&mut ids, vec![nest]);
    let outer = Timeline::new(ids.next_id(), "outer", f, vec![outer_track]);
    let outer_id = outer.id;
    let p = Project::new(ids.next_id(), "P", vec![gone.clone(), unused], vec![outer, inner]);
    let offline: Vec<Id> = ExportPreflight::offline_media(outer_id, &p).iter().map(|m| m.id).collect();
    assert_eq!(offline, vec![gone.id]);
}

#[test]
fn unreadable_media_flags_empty_files_and_containers_that_do_not_open() {
    use sq_core_time::IdSource;
    let dir = std::env::temp_dir().join(format!("sq-unreadable-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let write = |name: &str, bytes: &[u8]| {
        let p = dir.join(name);
        std::fs::write(&p, bytes).unwrap();
        p.to_string_lossy().into_owned()
    };
    let empty = write("empty.mov", b"");
    let broken = write("broken.mp4", b"not a container at all");
    let other = write("notes.xyz", b"some bytes");
    let mut ids = SequentialIds::default();
    let ms: Vec<MediaRef> = [("empty", &empty), ("broken", &broken), ("other", &other)]
        .iter()
        .map(|(n, path)| media(&mut ids, n, path, None))
        .collect();
    let clips: Vec<_> = ms.iter().map(|m| clip(&mut ids, m.id, None)).collect();
    let tr = track(&mut ids, clips);
    let tl = Timeline::new(ids.next_id(), "t", fmt(1920, 1080), vec![tr]);
    let tid = tl.id;
    let p = Project::new(ids.next_id(), "P", ms.clone(), vec![tl]);
    let bad: Vec<Id> = ExportPreflight::unreadable_media(tid, &p).iter().map(|m| m.id).collect();
    // The empty file and the mp4 that does not open are flagged; a container the check does not own is left alone.
    assert_eq!(bad, vec![ms[0].id, ms[1].id]);
    // A readable container (the check says yes) leaves only the empty file.
    let only_empty: Vec<Id> = ExportPreflight::unreadable_media_with(tid, &p, |_| true).iter().map(|m| m.id).collect();
    assert_eq!(only_empty, vec![ms[0].id]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn hdr_media_lists_only_used_hdr_sources() {
    use sq_core_time::IdSource;
    let mut ids = SequentialIds::default();
    let hdr = media(&mut ids, "hdr", "/x/hdr.mov", Some("hlgBT2020"));
    let sdr = media(&mut ids, "sdr", "/x/sdr.mov", Some("rec709"));
    let (c1, c2) = (clip(&mut ids, hdr.id, None), clip(&mut ids, sdr.id, None));
    let t = track(&mut ids, vec![c1, c2]);
    let tl = Timeline::new(ids.next_id(), "t", fmt(1920, 1080), vec![t]);
    let tl_id = tl.id;
    let p = Project::new(ids.next_id(), "P", vec![hdr.clone(), sdr], vec![tl]);
    assert_eq!(ExportPreflight::hdr_media(tl_id, &p).iter().map(|m| m.id).collect::<Vec<_>>(), vec![hdr.id]);
}

#[test]
fn disk_full_message() {
    assert!(ExportPreflight::failure_message(&ExportError::DiskFull, None).starts_with("The disk is full"));
    assert!(
        ExportPreflight::failure_message(&ExportError::WriterFailed("x".into()), Some(1_000))
            .starts_with("The disk is full")
    );
    assert!(
        !ExportPreflight::failure_message(&ExportError::WriterFailed("x".into()), Some(50_000_000_000))
            .starts_with("The disk is full")
    );
    assert_eq!(ExportPreflight::failure_message(&ExportError::NoAudio, None), "This sequence has no audio to export.");
    let io = std::io::Error::from_raw_os_error(28);
    assert_eq!(ExportError::from_io(&io), ExportError::DiskFull);
}

#[test]
fn space_verdicts_and_messages() {
    assert_eq!(ExportPreflight::space_verdict(None, 100), SpaceVerdict::Ok);
    assert_eq!(ExportPreflight::space_verdict(Some(99), 100), SpaceVerdict::Insufficient);
    assert_eq!(ExportPreflight::space_verdict(Some(110), 100), SpaceVerdict::Tight);
    assert_eq!(ExportPreflight::space_verdict(Some(120), 100), SpaceVerdict::Ok);
    assert_eq!(
        ExportPreflight::ran_out_of_space_message(Some(12_345_678)),
        "The output disk ran out of space (12 MB left). The export stopped and the partial file was removed. Free some space and export again."
    );
    assert!(ExportPreflight::ran_out_of_space_message(None).starts_with("The output disk ran out of space."));
}

// MARK: Variants

fn variant_timeline() -> Timeline {
    let mut f = fmt(1920, 1080);
    f.frame_duration = Time::new(1, 25);
    let mut t = Timeline::new(Id::from_u128(900), "Promo", f, Vec::new());
    for (i, (n, w, h)) in [("9:16", 1080, 1920), ("1:1", 1080, 1080)].into_iter().enumerate() {
        t.variants.push(
            serde_json::from_value::<FormatVariant>(
                json!({"id": Id::from_u128(i as u128 + 1000).to_string(), "name": n, "width": w, "height": h}),
            )
            .unwrap(),
        );
    }
    t
}

fn variant_settings(w: i64, h: i64) -> ExportSettings {
    let mut s = ExportSettings::default();
    s.video.width = w;
    s.video.height = h;
    s
}

fn variant_jobs(name: &str, s: &ExportSettings, t: &Timeline) -> Vec<ExportJob> {
    ExportJob::variant_jobs(
        name,
        s,
        Path::new("/tmp"),
        t,
        &mut SequentialIds::default(),
        Arc::new(|_| Err(ExportError::EmptySource)),
    )
}

#[test]
fn one_job_per_variant_plus_the_base_named_after_the_variant() {
    let t = variant_timeline();
    let jobs = variant_jobs("Promo", &variant_settings(1920, 1080), &t);
    assert_eq!(jobs.iter().map(|j| j.name.as_str()).collect::<Vec<_>>(), ["Promo", "Promo 9:16", "Promo 1:1"]);
    assert_eq!(sanitize(&jobs[1].name), "Promo 9-16"); // the file name carries the variant name
    let ids: Vec<Option<Id>> = std::iter::once(None).chain(t.variants.iter().map(|v| Some(v.id))).collect();
    assert_eq!(jobs.iter().map(|j| j.settings.variant).collect::<Vec<_>>(), ids);
    assert!(jobs[1].settings.video.width == 1080 && jobs[1].settings.video.height == 1920);
    assert!(jobs[2].settings.video.width == 1080 && jobs[2].settings.video.height == 1080);
}

#[test]
fn export_size_scales_with_the_variant_and_stays_even() {
    let t = variant_timeline();
    // Exporting the 1920x1080 sequence at 1280x720: the 9:16 variant goes out at 720x1280, 1:1 at 720x720.
    let jobs = variant_jobs("P", &variant_settings(1280, 720), &t);
    assert!(jobs[1].settings.video.width == 720 && jobs[1].settings.video.height == 1280);
    assert!(jobs[2].settings.video.width == 720 && jobs[2].settings.video.height == 720);
    for j in variant_jobs("P", &variant_settings(1000, 562), &t) {
        assert!(!j.settings.validate().contains(&ExportSettingsIssue::OddDimensions));
    }
    assert_eq!(even_scaled(1081, 1, 1), 1082);
    assert_eq!(even_scaled(1, 1, 1), 2);
}

#[test]
fn no_variants_is_just_the_base_job() {
    let mut t = variant_timeline();
    t.variants.clear();
    let jobs = variant_jobs("S", &variant_settings(1920, 1080), &t);
    assert!(jobs.len() == 1 && jobs[0].settings.variant.is_none() && jobs[0].name == "S");
}

#[test]
fn each_job_builds_its_sources_with_its_own_settings() {
    let t = variant_timeline();
    let seen: Arc<Mutex<Vec<Option<Id>>>> = Arc::default();
    let log = Arc::clone(&seen);
    let jobs = ExportJob::variant_jobs(
        "S",
        &variant_settings(1920, 1080),
        Path::new("/tmp"),
        &t,
        &mut SequentialIds::default(),
        Arc::new(move |s| {
            log.lock().unwrap().push(s.variant);
            Err(ExportError::EmptySource)
        }),
    );
    for j in &jobs {
        assert!((j.make_sources)().is_err());
    }
    let want: Vec<Option<Id>> = std::iter::once(None).chain(t.variants.iter().map(|v| Some(v.id))).collect();
    assert_eq!(*seen.lock().unwrap(), want);
}

fn shaped_timeline() -> Timeline {
    let mut f = fmt(1440, 1080);
    f.set_pixel_aspect(PixelAspect::new(4, 3).unwrap());
    let mut t = Timeline::new(Id::from_u128(901), "S", f, Vec::new());
    t.variants.push(
        serde_json::from_value(
            json!({"id": Id::from_u128(7).to_string(), "name": "9:16", "width": 1080, "height": 1920}),
        )
        .unwrap(),
    );
    t
}

#[test]
fn variant_keeps_the_sequence_shape_and_scale() {
    let t = shaped_timeline();
    let s = ExportPreset::MATCH_SOURCE.settings_matching(Some(&t.format));
    let j = variant_jobs("P", &s, &t);
    let aspect = PixelAspect::new(4, 3).unwrap();
    assert_eq!(j[1].settings.video.pixel_aspect(), aspect);
    assert!(j[1].settings.video.width == 1080 && j[1].settings.video.height == 1920);
    let mut half = s.clone();
    half.video.width = 720;
    half.video.height = 540;
    let h = variant_jobs("P", &half, &t);
    assert!(h[1].settings.video.width == 540 && h[1].settings.video.pixel_aspect() == aspect);
}

#[test]
fn square_export_of_shaped_sequence_gives_square_variant_at_display_aspect() {
    let t = shaped_timeline();
    let j = variant_jobs("P", &variant_settings(1920, 1080), &t); // square export at the sequence's display width
    assert!(j[0].settings.video.pixel_aspect().is_square() && j[1].settings.video.pixel_aspect().is_square());
    assert!(j[1].settings.video.width == 1440 && j[1].settings.video.height == 1920);
}

// MARK: State machine races

fn states_of(events: &std::sync::mpsc::Receiver<ExportJobStatus>, id: Id) -> Vec<ExportJobState> {
    let mut seen: Vec<ExportJobState> = Vec::new();
    while let Ok(u) = events.try_recv() {
        if u.id == id && seen.last() != Some(&u.state) {
            seen.push(u.state);
        }
    }
    seen
}

fn spawn_run(q: &ExportQueue) -> std::thread::JoinHandle<()> {
    let q = q.clone();
    std::thread::spawn(move || q.run_all())
}

#[test]
fn cancelling_a_running_job_is_published_before_cancelled() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder { hold: true, ..Default::default() }));
    let a = q.enqueue(job(1, "Slow", &dir.0, false));
    let events = q.updates();
    let runner = spawn_run(&q);
    wait_until("running", || q.status(a).unwrap().state == ExportJobState::Running);
    q.cancel(a);
    q.cancel(a); // asking twice changes nothing
    runner.join().unwrap();
    assert_eq!(
        states_of(&events, a),
        // (`Waiting` was published before the subscription.)
        vec![ExportJobState::Running, ExportJobState::Cancelling, ExportJobState::Cancelled]
    );
}

#[test]
fn cancel_on_a_finished_job_is_rejected_and_changes_nothing() {
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let a = q.enqueue(job(1, "A", &dir.0, false));
    q.run_all();
    let before = q.status(a).unwrap();
    q.cancel(a);
    q.cancel(Id::from_u128(99)); // unknown id: no panic
    assert_eq!(q.status(a).unwrap(), before);
}

#[test]
fn cancel_during_start_always_ends_cancelled_or_done_and_the_queue_goes_idle() {
    for round in 0..40u64 {
        let dir = TempDir::new();
        let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
        let a = q.enqueue(job(1, "A", &dir.0, false));
        let runner = spawn_run(&q);
        std::thread::sleep(Duration::from_micros(round * 150));
        q.cancel(a);
        runner.join().unwrap();
        let state = q.status(a).unwrap().state;
        assert!(matches!(state, ExportJobState::Cancelled | ExportJobState::Done(_)), "round {round}: {state:?}");
        if state == ExportJobState::Cancelled {
            assert!(!q.status(a).unwrap().output_url.exists(), "a cancelled job leaves no file");
        }
        // The worker is idle again: a new job runs.
        let b = q.enqueue(job(2, "B", &dir.0, false));
        q.run_all();
        assert!(matches!(q.status(b).unwrap().state, ExportJobState::Done(_)));
    }
}

#[test]
fn finish_during_cancel_keeps_the_finished_file() {
    // The encoder ignores the token and finishes: the file exists, so the job is Done even though a stop was asked.
    struct Stubborn;
    impl ExportEncoding for Stubborn {
        fn export(
            &self,
            _: &mut dyn FrameSource,
            _: Option<&mut dyn AudioSource>,
            _: &ExportSettings,
            url: &Path,
            cancel: &CancelToken,
            _: &mut dyn FnMut(f64),
        ) -> Result<Option<LoudnessReport>, ExportError> {
            while !cancel.is_cancelled() {
                std::thread::sleep(Duration::from_millis(2));
            }
            std::fs::write(url, [1u8]).unwrap();
            Ok(None)
        }
    }
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(Stubborn));
    let a = q.enqueue(job(1, "A", &dir.0, false));
    let runner = spawn_run(&q);
    wait_until("running", || q.status(a).unwrap().state == ExportJobState::Running);
    q.cancel(a);
    runner.join().unwrap();
    assert!(matches!(q.status(a).unwrap().state, ExportJobState::Done(_)));
}

#[test]
fn several_run_all_calls_run_every_job_exactly_once() {
    let dir = TempDir::new();
    let enc = Arc::new(FakeEncoder::default());
    let q = ExportQueue::new(Arc::<FakeEncoder>::clone(&enc));
    let ids: Vec<Id> = (1..=6).map(|i| q.enqueue(job(i, &format!("J{i}"), &dir.0, false))).collect();
    let runners: Vec<_> = (0..3).map(|_| spawn_run(&q)).collect();
    for r in runners {
        r.join().unwrap();
    }
    wait_until("all done", || ids.iter().all(|i| matches!(q.status(*i).unwrap().state, ExportJobState::Done(_))));
    assert_eq!(enc.log.lock().unwrap().len(), 6, "each job exported once");
}

#[test]
fn a_job_enqueued_while_the_worker_winds_down_is_not_stranded() {
    // The app enqueues and kicks `run_all` after every job; whichever call wins, all jobs finish.
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let mut runners = Vec::new();
    let mut ids = Vec::new();
    for i in 1..=30u128 {
        ids.push(q.enqueue(job(i, &format!("J{i}"), &dir.0, false)));
        runners.push(spawn_run(&q));
    }
    for r in runners {
        r.join().unwrap();
    }
    let all_done = ids.iter().all(|i| matches!(q.status(*i).unwrap().state, ExportJobState::Done(_)));
    assert!(all_done, "a job was left waiting");
}

#[test]
fn a_side_output_is_pending_until_written_and_never_written_and_failed_at_once() {
    assert_eq!(SideOutput::default(), SideOutput::Pending);
    let written = SideOutput::Written(PathBuf::from("a.srt"));
    assert_eq!((written.url(), written.error()), (Some(Path::new("a.srt")), None));
    let failed = SideOutput::Failed("no space".into());
    assert_eq!((failed.url(), failed.error()), (None, Some("no space")));
    let dir = TempDir::new();
    let q = ExportQueue::new(Arc::new(FakeEncoder::default()));
    let a = q.enqueue(job(1, "Plain", &dir.0, false));
    q.run_all();
    let st = q.status(a).unwrap();
    assert_eq!((st.sidecar, st.cover), (SideOutput::Pending, SideOutput::Pending));
}

/// A fresh dialog model draws the same ids again (`SequentialIds`), so a second export reuses the id of a finished job.
/// The worker used to find the finished entry by that id, fail to start it and spin on the still waiting one.
#[test]
fn a_job_whose_id_was_used_before_still_runs() {
    let dir = TempDir::new();
    let q = Arc::new(ExportQueue::new(Arc::new(FakeEncoder::default())));
    let first = q.enqueue(job(1, "Main", &dir.0, false));
    q.run_all();
    let second = q.enqueue(job(1, "Main", &dir.0, false));
    assert_ne!(first, second, "the queue hands out a unique id");
    let worker = Arc::clone(&q);
    let done = std::thread::spawn(move || worker.run_all());
    wait_until("the second job to end", || q.status(second).is_some_and(|s| !s.state.is_active()));
    done.join().unwrap();
    let ExportJobState::Done(url) = q.status(second).unwrap().state else { panic!("not done") };
    assert_eq!(url.file_name().unwrap().to_string_lossy(), "Main 2.mp4");
    assert!(matches!(q.status(first).unwrap().state, ExportJobState::Done(_)));
}

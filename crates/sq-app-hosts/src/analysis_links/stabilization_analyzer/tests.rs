use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

fn scene(x: f64, y: f64) -> f64 {
    128.0
        + 34.0 * (x / 5.3 + y / 9.1).sin()
        + 28.0 * (x / 11.7 - y / 6.3).cos()
        + 22.0 * (x / 3.1).sin() * (y / 4.3).cos()
        + 18.0 * ((x + 2.0 * y) / 17.9).sin()
}

fn shot(dx: f64) -> GrayFrame {
    let (w, h) = (256, 144);
    GrayFrame::new(w, h, (0..w * h).map(|i| scene((i % w) as f64 - dx, (i / w) as f64) as f32).collect())
}

fn at(i: usize) -> Time {
    Time::new(i as i64, 24)
}

#[test]
fn a_panning_clip_gives_one_motion_per_frame_in_source_pixels() {
    let mut read = |i: usize| Some((at(i), shot(i as f64 * 2.0)));
    let a = analyze_frames(4, &mut read, (1024, 576), None, &CancelToken::new()).expect("analysis");
    assert_eq!(a.motions.len(), 4);
    assert_eq!(a.motions[0], CameraMotion::IDENTITY);
    // 2 px at 256 px wide = 8 px at 1024.
    assert!((a.motions[2].dx - 8.0).abs() < 0.5, "{:?}", a.motions[2]);
    assert!(a.cuts.is_empty() && a.confidence.iter().all(|c| *c > 0.5), "{:?}", a.confidence);
}

#[test]
fn a_flat_frame_keeps_the_identity_without_trust() {
    let flat = GrayFrame::new(256, 144, vec![90.0; 256 * 144]);
    let mut read = |i: usize| Some((at(i), if i == 0 { shot(0.0) } else { flat.clone() }));
    let a = analyze_frames(2, &mut read, (256, 144), None, &CancelToken::new()).expect("analysis");
    assert_eq!(a.motions[1], CameraMotion::IDENTITY);
    assert_eq!(a.confidence[1], 0.0);
}

#[test]
fn a_canceled_or_unreadable_run_gives_no_result() {
    let cancel = CancelToken::new();
    cancel.cancel();
    let mut read = |i: usize| Some((at(i), shot(0.0)));
    assert_eq!(analyze_frames(3, &mut read, (256, 144), None, &cancel), Err(StabilizationError::Cancelled));
    let mut none = |_: usize| None;
    assert_eq!(
        analyze_frames(3, &mut none, (256, 144), None, &CancelToken::new()),
        Err(StabilizationError::Unreadable)
    );
}

fn req(path: &Path, size: (i64, i64)) -> StabilizationRequest {
    StabilizationRequest { path: path.to_path_buf(), range: TimeRange::from_end(Time::ZERO, Time::seconds(2)), size }
}

struct Counting(AtomicUsize);
impl StabilizationAnalyzing for Counting {
    fn analyze(
        &self,
        _: TimeRange,
        w: i64,
        h: i64,
        _: Progress<'_>,
        _: &CancelToken,
    ) -> Result<StabilizationAnalysis, StabilizationError> {
        self.0.fetch_add(1, Ordering::SeqCst);
        let mut a = StabilizationAnalysis::new(
            w,
            h,
            vec![at(0), at(1)],
            vec![CameraMotion::IDENTITY, CameraMotion::new(1.5, -2.0, 0.25, 1.0)],
        );
        a.cuts = vec![1];
        a.confidence = vec![1.0, 0.5];
        Ok(a)
    }
}

#[test]
fn a_result_is_kept_in_memory_and_on_disk() {
    let dir = crate::test_rig::unique_dir("sq-stab");
    let media = dir.join("clip.mov");
    std::fs::create_dir_all(&dir).expect("dir");
    std::fs::write(&media, b"not really a movie").expect("media");
    let range = TimeRange::from_end(Time::ZERO, Time::seconds(2));
    let (analyzer, cancel) = (Counting(AtomicUsize::new(0)), CancelToken::new());
    let cache = dir.join("cache");
    let store = StabilizationStore::default();
    let n = analyze_into_store(&analyzer, &req(&media, (1920, 1080)), &store, Some(&cache), None, &cancel);
    assert_eq!(n, Ok(2));
    // Same store: no second measurement. New store (a new launch): read back from disk.
    let again = StabilizationStore::default();
    assert_eq!(analyze_into_store(&analyzer, &req(&media, (1920, 1080)), &again, Some(&cache), None, &cancel), Ok(2));
    assert_eq!(analyzer.0.load(Ordering::SeqCst), 1);
    let got = again.get(&media.to_string_lossy(), range, 1920, 1080).expect("stored");
    assert_eq!(got.motions[1], CameraMotion::new(1.5, -2.0, 0.25, 1.0));
    assert_eq!((got.cuts, got.confidence), (vec![1], vec![1.0, 0.5]));
    // Another picture size is measured again.
    let other = StabilizationStore::default();
    assert_eq!(analyze_into_store(&analyzer, &req(&media, (1280, 720)), &other, Some(&cache), None, &cancel), Ok(2));
    assert_eq!(analyzer.0.load(Ordering::SeqCst), 2);
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_new_launch_finds_the_result_without_a_run() {
    let dir = crate::test_rig::unique_dir("sq-stab-lookup");
    let media = dir.join("clip.mov");
    std::fs::create_dir_all(&dir).expect("dir");
    std::fs::write(&media, b"not really a movie").expect("media");
    let cache = dir.join("cache");
    let (analyzer, cancel) = (Counting(AtomicUsize::new(0)), CancelToken::new());
    let first = StabilizationStore::with_disk(cache.clone());
    analyze_into_store(&analyzer, &req(&media, (1920, 1080)), &first, Some(&cache), None, &cancel).expect("run");
    // A fresh store over the same folder: the re-plan's lookup reads the file, no analyzer involved.
    let launch = StabilizationStore::with_disk(cache);
    let inner = TimeRange::from_end(Time::ZERO, Time::seconds(1));
    let path = media.to_string_lossy();
    assert!(launch.get(&path, inner, 1920, 1080).is_some());
    assert!(launch.get(&path, inner, 1280, 720).is_none(), "another picture size");
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn the_job_reports_done() {
    let store = StabilizationStore::default();
    let range = TimeRange::from_end(Time::ZERO, Time::seconds(1));
    let job = StabilizationJob::spawn(
        Box::new(Counting(AtomicUsize::new(0))),
        StabilizationRequest { path: PathBuf::from("/no/such/a.mov"), range, size: (64, 64) },
        store,
        None,
        std::sync::Arc::new(|| {}),
    );
    let mut all = Vec::new();
    for _ in 0..500 {
        all.extend(job.poll());
        if all.iter().any(|m| matches!(m, StabilizationMessage::Done(_))) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(matches!(all.last(), Some(StabilizationMessage::Done(Ok(2)))), "{all:?}");
}

/// A frame 320 x 192 of the scene as a shaking camera sees it: content moved by (dx, dy) px, turned `deg`, and a
/// perspective tilt `k` (the right side nearer by a factor 1 + k * x / 160).
fn shaken(dx: f64, dy: f64, deg: f64, k: f64) -> GrayFrame {
    let (w, h) = (320usize, 192usize);
    let r = deg.to_radians();
    let (c, s) = (r.cos(), r.sin());
    let px = (0..w * h)
        .map(|i| {
            let (x, y) = ((i % w) as f64 - 160.0 - dx, (i / w) as f64 - 96.0 - dy);
            let (u, v) = (c * x + s * y, -s * x + c * y);
            let d = 1.0 + k * u / 160.0;
            scene(u / d, v / d) as f32
        })
        .collect();
    GrayFrame::new(w, h, px)
}

#[test]
fn a_shaking_clip_gives_motion_checks_and_rolling_samples() {
    // The camera path: frame i is shifted by (3 sin, 2 cos) px and turned by 0.8 sin degrees against the scene.
    let path = |i: usize| {
        let t = i as f64 * 0.9;
        (3.0 * t.sin() * 2.0, 2.0 * t.cos() * 2.0, 0.8 * t.sin())
    };
    let mut read = |i: usize| {
        let (dx, dy, deg) = path(i);
        Some((at(i), shaken(dx, dy, deg, 0.0)))
    };
    // Picture twice as wide as the measured frame: motions come back in source px (factor 2).
    let a = analyze_frames(8, &mut read, (640, 384), None, &CancelToken::new()).expect("analysis");
    assert_eq!(a.checks.len(), 8);
    assert_eq!(a.rolling.len(), 8);
    for i in 1..8 {
        let (x0, y0, r0) = path(i - 1);
        let (x1, y1, r1) = path(i);
        // Content moves by the difference of the two poses (small angles, so the rotation is close to additive).
        let m = a.motions[i];
        assert!((m.dx - 2.0 * (x1 - x0)).abs() < 1.5, "dx {i}: {m:?}");
        assert!((m.dy - 2.0 * (y1 - y0)).abs() < 1.5, "dy {i}: {m:?}");
        assert!((m.rotation - (r1 - r0)).abs() < 0.3, "rot {i}: {m:?}");
        let check = a.checks[i].expect("the check measured the pair");
        assert!((check.dx - m.dx).abs() < 1.5 && (check.dy - m.dy).abs() < 1.5, "check {i}: {check:?} vs {m:?}");
        assert!(a.rolling[i].is_some(), "rolling sample {i}");
    }
    assert!(a.cuts.is_empty() && a.perspective.is_empty(), "{:?} {:?}", a.cuts, a.perspective);
}

#[test]
fn a_tilting_camera_leaves_a_perspective_residual() {
    let mut read = |i: usize| Some((at(i), shaken(0.0, 0.0, 0.0, 0.05 * i as f64)));
    let a = analyze_frames(4, &mut read, (320, 192), None, &CancelToken::new()).expect("analysis");
    assert_eq!(a.perspective.len(), 4);
    assert!(a.perspective[0].is_zero());
    assert!(a.perspective[1..].iter().any(|p| !p.is_zero()), "{:?}", a.perspective);
}

#[test]
fn checks_rolling_and_perspective_survive_the_disk_cache() {
    let mut read = |i: usize| Some((at(i), shaken(i as f64 * 1.5, 0.0, 0.0, 0.05 * i as f64)));
    let a = analyze_frames(4, &mut read, (320, 192), None, &CancelToken::new()).expect("analysis");
    let dir = std::env::temp_dir().join(format!("sq-stab-cache-{}", std::process::id()));
    let file = dir.join("x.json");
    let range = TimeRange::new(Time::new(0, 24), Time::new(4, 24));
    save_analysis(&file, range, &a).expect("saved");
    let (r, back) = load_analysis(&file).expect("loaded");
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(r, range);
    // JSON text keeps floats to the last digit only within 1e-12.
    assert_eq!(back.rolling.len(), a.rolling.len());
    assert!(back.rolling.iter().zip(&a.rolling).all(|(b, a)| b.is_some() == a.is_some()));
    assert_eq!(
        back.checks.iter().map(Option::is_some).collect::<Vec<_>>(),
        a.checks.iter().map(Option::is_some).collect::<Vec<_>>()
    );
    assert!(back.checks.iter().flatten().zip(a.checks.iter().flatten()).all(|(b, a)| (b.dx - a.dx).abs() < 1e-12));
    assert!(
        back.perspective.iter().zip(&a.perspective).all(|(b, a)| b
            .values
            .iter()
            .zip(&a.values)
            .all(|(x, y)| (x - y).abs() < 1e-12))
    );
    assert_eq!(back.perspective.len(), a.perspective.len());
    assert!(a.perspective.iter().any(|p| !p.is_zero()));
}

#[test]
fn the_disk_cache_drops_the_least_recently_used_files_over_its_cap() {
    let dir = crate::test_rig::unique_dir("sq-stab-lru");
    std::fs::create_dir_all(&dir).expect("dir");
    let now = std::time::SystemTime::now();
    // Three files of 100 bytes; "b" was used last, "a" longest ago.
    for (name, ago) in [("a.json", 300u64), ("c.json", 200), ("b.json", 10)] {
        let f = dir.join(name);
        std::fs::write(&f, [b'x'; 100]).expect("file");
        let h = std::fs::OpenOptions::new().write(true).open(&f).expect("open");
        h.set_modified(now - std::time::Duration::from_secs(ago)).expect("mtime");
    }
    prune_cache(&dir, 250);
    assert!(!dir.join("a.json").exists(), "the oldest goes first");
    assert!(dir.join("c.json").exists() && dir.join("b.json").exists());
    // A read counts as a use: touching c makes b the older one.
    touch(&dir.join("c.json"));
    prune_cache(&dir, 150);
    assert!(dir.join("c.json").exists() && !dir.join("b.json").exists());
    assert_eq!(CACHE_LIMIT_BYTES, 200 * 1024 * 1024);
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_clip_stored_sideways_is_measured_upright_with_x_motion_along_the_picture() {
    // An upright pan, stored the way a phone does: turned a quarter counter-clockwise, rotation tag 90.
    let mut read = |i: usize| {
        let stored = rotate_gray(&shot(i as f64 * 2.0), 3);
        assert_eq!((stored.width, stored.height), (144, 256));
        Some((at(i), rotate_gray(&stored, 1)))
    };
    let a = analyze_frames_turned(4, &mut read, (1024, 576), 1, None, &CancelToken::new()).expect("analysis");
    assert!((a.motions[2].dx - 8.0).abs() < 0.5 && a.motions[2].dy.abs() < 0.5, "{:?}", a.motions[2]);
    assert_eq!(a.rolling_scan, 1);
    // Unturned stored pictures give the swapped motion the review found.
    let mut raw = |i: usize| Some((at(i), rotate_gray(&shot(i as f64 * 2.0), 3)));
    let swapped = analyze_frames(4, &mut raw, (1024, 576), None, &CancelToken::new()).expect("analysis");
    assert!(swapped.motions[2].dx.abs() < 0.5, "{:?}", swapped.motions[2]);
}

struct Panicking;
impl StabilizationAnalyzing for Panicking {
    fn analyze(
        &self,
        _: TimeRange,
        _: i64,
        _: i64,
        _: Progress<'_>,
        _: &CancelToken,
    ) -> Result<StabilizationAnalysis, StabilizationError> {
        panic!("decoder blew up");
    }
}

#[test]
fn a_panicking_analysis_still_reports_done_with_a_status_line() {
    let range = TimeRange::from_end(Time::ZERO, Time::seconds(1));
    let job = StabilizationJob::spawn(
        Box::new(Panicking),
        StabilizationRequest { path: PathBuf::from("/no/such/a.mov"), range, size: (64, 64) },
        StabilizationStore::default(),
        None,
        std::sync::Arc::new(|| {}),
    );
    let mut all = Vec::new();
    for _ in 0..500 {
        all.extend(job.poll());
        if all.iter().any(|m| matches!(m, StabilizationMessage::Done(_))) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(all.iter().any(|m| matches!(m, StabilizationMessage::Done(Err(_)))), "{all:?}");
}

#[test]
fn the_vision_fallback_reads_the_shift_between_two_measuring_frames_on_the_mac_and_nothing_elsewhere() {
    let (previous, current) = (shot(0.0), shot(3.0));
    let found = vision_motion(&previous, &current);
    if cfg!(target_os = "macos") {
        let m = found.expect("Vision matches the shifted pair");
        assert!((m.dx - 3.0).abs() <= 1.0 && m.dy.abs() <= 1.0, "{m:?}");
    } else {
        assert_eq!(found, None, "Windows and Linux keep the portable path");
    }
    // Different sizes never match.
    assert_eq!(vision_motion(&previous, &GrayFrame::new(8, 8, vec![0.0; 64])), None);
}

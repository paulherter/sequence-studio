//! Headless frame-time test (PLAN-ANGLEICHEN section 2): the first 30 scroll and zoom steps over a busy timeline with
//! waveforms. Run in release (`cargo test --release -p sq-draw-timeline perf_ -- --nocapture`) to read real numbers;
//! the asserted limits are loose enough for a loaded debug build.

use crate::media::TimelineMediaSource;
use crate::panel_tests::{Rig, uid};
use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_media::waveform_data::WaveformData;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Instant;

struct Waves(Arc<WaveformData>);
impl TimelineMediaSource for Waves {
    fn waveform(&self, _media: Id) -> Option<Arc<WaveformData>> {
        Some(Arc::clone(&self.0))
    }
    fn draw_revision(&self) -> Option<u64> {
        Some(1)
    }
}

/// 2 video + 6 audio tracks of 150 clips of 4 s: a 10 minute timeline.
fn busy() -> Timeline {
    let fd = Time::new(1, 25);
    let mut n = 100u128;
    let mut tracks = Vec::new();
    for t in 0..8u128 {
        let kind = if t < 2 { TrackKind::Video } else { TrackKind::Audio };
        let mut track = Track::new(uid(t + 1), kind);
        let clips = (0..150u128)
            .map(|i| {
                n += 1;
                Clip::new(
                    uid(n),
                    "clip",
                    uid(5000 + i),
                    kind,
                    TimeRange::new(Time::ZERO, fd * 100),
                    fd * (i as i64 * 100),
                )
            })
            .collect();
        track.set_clips(clips);
        tracks.push(track);
    }
    Timeline::new(uid(900), "T", SequenceFormat::new(fd), tracks)
}

fn waves() -> Arc<WaveformData> {
    let base = 256usize;
    let buckets = 48_000 * 60 / base;
    let mut l0 = Vec::with_capacity(buckets * 2);
    for i in 0..buckets {
        let v = ((i as f32 * 0.01).sin().abs() * 0.8) + 0.1;
        l0.extend([-v, v]);
    }
    let mut levels = vec![l0];
    while levels.last().unwrap().len() > 4 {
        let prev = levels.last().unwrap();
        let next: Vec<f32> = prev
            .chunks(4)
            .flat_map(|c| if c.len() == 4 { [c[0].min(c[2]), c[1].max(c[3])] } else { [c[0], c[1]] })
            .collect();
        levels.push(next);
    }
    Arc::new(WaveformData::new(48_000, 1, 48_000 * 60, base, levels))
}

fn report(name: &str, mut ms: Vec<f64>) -> (f64, f64) {
    let max = ms.iter().cloned().fold(0.0, f64::max);
    ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let p95 = ms[(ms.len() * 95 / 100).min(ms.len() - 1)];
    eprintln!("perf {name}: n={} p95={p95:.2} ms max={max:.2} ms", ms.len());
    (p95, max)
}

#[test]
fn perf_first_30_scroll_and_zoom_steps() {
    let mut r = Rig::new(busy(), 1600.0, 700.0);
    r.p.media = Some(Rc::new(Waves(waves())));
    let mut cv = sq_draw::Canvas::with_size(1600.0, 700.0, None, 1.0);
    let t0 = Instant::now();
    r.p.draw_timeline(&mut cv); // the very first frame builds fonts and layers
    eprintln!("perf first frame: {:.2} ms", t0.elapsed().as_secs_f64() * 1000.0);
    r.p.set_zoom(40.0, None);
    let mut scroll = Vec::new();
    for i in 0..30 {
        r.p.geometry.scroll_x += 37.0 + i as f64;
        let mut cv = sq_draw::Canvas::with_size(1600.0, 700.0, None, 1.0);
        let t = Instant::now();
        r.p.draw_timeline(&mut cv);
        scroll.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    let mut zoom = Vec::new();
    for i in 0..30 {
        r.p.set_zoom(if i % 2 == 0 { 55.0 + i as f64 } else { 30.0 + i as f64 }, Some(800.0));
        let mut cv = sq_draw::Canvas::with_size(1600.0, 700.0, None, 1.0);
        let t = Instant::now();
        r.p.draw_timeline(&mut cv);
        zoom.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    let mut cv = sq_draw::Canvas::with_size(1600.0, 700.0, None, 1.0);
    r.p.draw_timeline(&mut cv);
    let quads = cv.list.quads().len();
    eprintln!("perf quads in last frame: {quads}");
    assert!(quads > 500, "the busy timeline must draw clips and waveforms");
    let (_, smax) = report("scroll", scroll);
    let (_, zmax) = report("zoom", zoom);
    assert!(smax < 200.0 && zmax < 200.0, "a frame took far too long");
}

#[test]
fn perf_playing_with_the_view_following_the_playhead() {
    let mut r = Rig::new(busy(), 1600.0, 700.0);
    r.p.media = Some(Rc::new(Waves(waves())));
    r.p.set_zoom(60.0, None);
    r.p.is_playing = true;
    let mut ms = Vec::new();
    for i in 0..240i64 {
        r.s.seek(Time::new(i * 2, 25));
        let t = Instant::now();
        r.sync();
        let mut cv = sq_draw::Canvas::with_size(1600.0, 700.0, None, 1.0);
        r.p.draw_timeline(&mut cv);
        ms.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    let (_, max) = report("play-follow", ms);
    assert!(max < 100.0, "a frame while playing took far too long");
}

/// Swift `culledRangeNeverDropsAVisibleClip`: the culled range holds every clip the exact per-clip test would draw, also
/// with a long early clip that overlaps later ones.
#[test]
fn culled_range_never_drops_a_visible_clip() {
    let fd = Time::new(1, 30);
    let mut clips: Vec<Clip> = (0..300u128)
        .map(|i| {
            Clip::new(
                uid(100 + i),
                "c",
                uid(5000 + i),
                TrackKind::Audio,
                TimeRange::new(Time::ZERO, fd * 60),
                fd * (i as i64 * 60),
            )
        })
        .collect();
    clips[3].source = TimeRange::new(Time::ZERO, fd * 60 * 200); // overlaps clips 4..=202
    let mut track = Track::new(uid(1), TrackKind::Audio);
    track.set_clips(clips);
    let mut r = Rig::new(Timeline::new(uid(900), "T", SequenceFormat::new(fd), vec![track]), 1200.0, 400.0);
    let track = r.p.timeline.tracks[0].clone();
    for zoom in [2.0, 20.0, 90.0] {
        r.p.set_zoom(zoom, None);
        let mut scroll = 0.0;
        while scroll <= 9000.0 {
            r.p.geometry.scroll_x = scroll;
            scroll += 413.0;
            let (a, b) = (sq_timeline_ui::TimelineGeometry::CONTENT_ORIGIN_X, 1200.0);
            let range = r.p.visible_clip_indices(&track, a, b);
            for (i, c) in track.clips().iter().enumerate() {
                let (x0, x1) = (r.p.geometry.x(c.timeline().start), r.p.geometry.x(c.timeline().end()));
                if x1 >= a && x0 <= b {
                    assert!(range.contains(&i), "clip {i} at zoom {zoom} scroll {scroll}");
                }
            }
            if zoom == 90.0 {
                assert!(range.len() < 60);
            }
        }
    }
}

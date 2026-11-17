// Swift: VolumeLine.swift
//! The volume rubber band on an audio clip (Premiere): a line over the waveform at the clip's Volume level.
//! Drag it up or down to change the level, Cmd-click to add a key, drag a key to move it. Pure geometry and gesture
//! maths; the timeline view draws it and routes the mouse.

use crate::clip_body_metrics::ClipBodyMetrics;
use crate::timeline_geometry::TimelineGeometry;
use sq_core_audio::audio_gain::{AudioGain, VolumeLineExt};
use sq_core_model::Clip;
use sq_core_model::fades_curve::FadeCurve;
use sq_core_time::{Id, IdSource, Time};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};

/// What a pointer on the volume line grabs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VolumeHit {
    /// A key.
    Key(Id),
    /// On the line (not on a key) at this clip-local time.
    Line(Time),
}

/// The volume line.
pub struct VolumeLine;

impl VolumeLine {
    /// Rows shorter than this show no band (too little room to grab it).
    pub const MIN_ROW_HEIGHT: f64 = 40.0;
    /// Level at the top of the waveform area.
    pub const DB_TOP: f64 = AudioGain::MAX_VOLUME_DB;
    /// Level at the bottom of the waveform area. Below the bottom is silence.
    pub const DB_BOTTOM: f64 = -40.0;
    const LINE_GRAB: f64 = 4.0;
    const KEY_GRAB: f64 = 6.0;
    /// Within this many points of a clip's left or right edge the trim handle beats a key (without Cmd).
    pub const EDGE_TRIM_ZONE: f64 = 6.0;

    /// The row is tall enough for the band.
    pub fn is_available(row_height: f64) -> bool {
        row_height >= Self::MIN_ROW_HEIGHT
    }

    /// The area the line moves in: the waveform area of the clip rectangle.
    pub fn lane(clip_rect: &Rect) -> Rect {
        ClipBodyMetrics::waveform_rect(clip_rect)
    }

    /// View y of a level.
    pub fn y_for_db(db: f64, lane: &Rect) -> f64 {
        if db <= AudioGain::SILENCE_DB {
            return lane.max_y();
        }
        let f = (db.clamp(Self::DB_BOTTOM, Self::DB_TOP) - Self::DB_BOTTOM) / (Self::DB_TOP - Self::DB_BOTTOM);
        lane.max_y() - lane.height * f
    }

    /// Level at a view y.
    pub fn db_for_y(y: f64, lane: &Rect) -> f64 {
        if lane.height <= 0.0 {
            return 0.0;
        }
        if y >= lane.max_y() {
            return AudioGain::SILENCE_DB;
        }
        let f = (lane.max_y() - y) / lane.height;
        (Self::DB_BOTTOM + f * (Self::DB_TOP - Self::DB_BOTTOM)).min(Self::DB_TOP)
    }

    /// The trim handle of a clip edge wins over a key.
    pub fn edge_wins(p: Point, clip_rect: &Rect) -> bool {
        p.x - clip_rect.min_x() < Self::EDGE_TRIM_ZONE || clip_rect.max_x() - p.x < Self::EDGE_TRIM_ZONE
    }

    fn level_db(clip: &Clip, local: Time) -> f64 {
        AudioGain::db_from_linear(clip.animation.volume.value_at_local(local))
    }

    /// What `p` grabs: a key, the line, or nothing.
    pub fn hit(clip: &Clip, clip_rect: &Rect, p: Point, geometry: &TimelineGeometry) -> Option<VolumeHit> {
        if !clip_rect.inset_by(-Self::KEY_GRAB, 0.0).contains(Point::new(p.x, clip_rect.mid_y())) {
            return None;
        }
        let lane = Self::lane(clip_rect);
        if lane.height < 4.0 {
            return None;
        }
        for k in clip.animation.volume.track.keys.iter() {
            let kx = geometry.x(clip.start + k.time);
            let ky = Self::y_for_db(AudioGain::db_from_linear(k.value), &lane);
            if (p.x - kx).hypot(p.y - ky) <= Self::KEY_GRAB {
                return Some(VolumeHit::Key(k.id));
            }
        }
        if !clip_rect.contains(Point::new(p.x, clip_rect.mid_y())) {
            return None;
        }
        let local = (geometry.time(p.x) - clip.start).max(Time::ZERO).min(clip.duration());
        let ly = Self::y_for_db(Self::level_db(clip, local), &lane);
        if (p.y - ly).abs() <= Self::LINE_GRAB { Some(VolumeHit::Line(local)) } else { None }
    }

    /// Polyline of the line inside `visible`, `step` points apart (keys are always included).
    pub fn points(clip: &Clip, clip_rect: &Rect, visible: &Rect, step: f64) -> Vec<Point> {
        let lane = Self::lane(clip_rect);
        let x0 = clip_rect.min_x().max(visible.min_x());
        let x1 = clip_rect.max_x().min(visible.max_x());
        if !(x1 > x0 && lane.height > 0.0) {
            return Vec::new();
        }
        if clip.animation.volume.track.is_empty() {
            // constant level: one segment (the common case, and cheap)
            let y = Self::y_for_db(AudioGain::db_from_linear(clip.animation.volume.value), &lane);
            return vec![Point::new(x0, y), Point::new(x1, y)];
        }
        let d = clip.duration();
        let sec_per_point = d.value() as f64 / d.timescale() as f64 / clip_rect.width.max(1.0);
        let at = |x: f64| -> Point {
            let sec = (x - clip_rect.min_x()) * sec_per_point;
            let t = Time::new((sec * 1_000_000.0).round() as i64, 1_000_000);
            Point::new(x, Self::y_for_db(Self::level_db(clip, t), &lane))
        };
        let mut xs: Vec<f64> = Vec::new();
        let stride = step.max(1.0);
        let mut x = x0;
        while x < x1 {
            xs.push(x);
            x += stride;
        }
        xs.push(x1);
        xs.extend(
            clip.animation
                .volume
                .track
                .keys
                .iter()
                .map(|k| Self::geometry_x(k.time, clip, clip_rect))
                .filter(|x| *x > x0 && *x < x1),
        );
        xs.sort_by(f64::total_cmp);
        xs.into_iter().map(at).collect()
    }

    fn geometry_x(t: Time, clip: &Clip, rect: &Rect) -> f64 {
        let d = clip.duration().value() as f64 / clip.duration().timescale() as f64;
        let s = t.value() as f64 / t.timescale() as f64;
        rect.min_x() + (if d > 0.0 { s / d } else { 0.0 }) * rect.width
    }

    /// Key positions (view points) for drawing.
    pub fn key_points(clip: &Clip, clip_rect: &Rect) -> Vec<Point> {
        let lane = Self::lane(clip_rect);
        clip.animation
            .volume
            .track
            .keys
            .iter()
            .map(|k| {
                Point::new(
                    Self::geometry_x(k.time, clip, clip_rect),
                    Self::y_for_db(AudioGain::db_from_linear(k.value), &lane),
                )
            })
            .collect()
    }

    // MARK: Fade handles

    /// Size of a fade handle.
    pub const HANDLE_SIZE: f64 = 8.0;
    /// Gap between a handle's center and the clip edge when there is no fade (keeps the handle inside the clip).
    const HANDLE_INSET: f64 = 6.0;

    /// Centers of the head and tail handles (view points). They sit on the top edge of the waveform lane and move
    /// inward with the fade length.
    pub fn fade_handle_points(clip: &Clip, clip_rect: &Rect) -> (Point, Point) {
        let lane = Self::lane(clip_rect);
        let d = clip.duration().value() as f64 / clip.duration().timescale() as f64;
        let width = |t: Time| -> f64 {
            if d > 0.0 { t.value() as f64 / t.timescale() as f64 / d * clip_rect.width } else { 0.0 }
        };
        let y = lane.min_y() + Self::HANDLE_SIZE / 2.0 + 1.0;
        (
            Point::new(clip_rect.min_x() + Self::HANDLE_INSET + width(clip.audio_fade_in()), y),
            Point::new(clip_rect.max_x() - Self::HANDLE_INSET - width(clip.audio_fade_out()), y),
        )
    }

    /// The handle under `p`, if any. Tail wins when the two overlap on a very short clip.
    pub fn fade_handle(clip: &Clip, clip_rect: &Rect, p: Point, hidden: &[FadeHandle]) -> Option<FadeHandle> {
        if clip_rect.width < 4.0 * Self::HANDLE_SIZE {
            return None;
        }
        let pts = Self::fade_handle_points(clip, clip_rect);
        let r = Self::HANDLE_SIZE / 2.0 + 2.0;
        let hits = |c: Point| (p.x - c.x).abs() <= r && (p.y - c.y).abs() <= r;
        if !hidden.contains(&FadeHandle::Tail) && hits(pts.1) {
            return Some(FadeHandle::Tail);
        }
        if !hidden.contains(&FadeHandle::Head) && hits(pts.0) {
            return Some(FadeHandle::Head);
        }
        None
    }

    /// The clip with its fade set from a drag: `dx` points moved since the press (handle at `start_length` then).
    /// `default_curve` shapes a fade that did not exist before the drag (a fade that already has a shape keeps it).
    pub fn clip_dragging(
        clip: &Clip,
        drag: &FadeDrag,
        clip_rect: &Rect,
        frame_duration: Time,
        default_curve: FadeCurve,
        ids: &mut dyn IdSource,
    ) -> Clip {
        let FadeDrag { handle: h, start_length, dx } = *drag;
        let mut c = clip.clone();
        let d = clip.duration().value() as f64 / clip.duration().timescale() as f64;
        if !(clip_rect.width > 0.0 && d > 0.0) {
            return c;
        }
        let sec = dx / clip_rect.width * d * if h == FadeHandle::Head { 1.0 } else { -1.0 };
        // Milliseconds are enough: the fade snaps down to whole frames anyway.
        let len = start_length + Time::new((sec * 1000.0).round() as i64, 1000);
        match h {
            FadeHandle::Head => {
                let is_new = c.audio_fade_in_curve().is_none();
                c.set_audio_fade_in(len.max(Time::ZERO), frame_duration, ids);
                if is_new && default_curve != FadeCurve::Linear && c.audio_fade_in_curve().is_some() {
                    c.set_audio_fade_curve(default_curve, true);
                }
            }
            FadeHandle::Tail => {
                let is_new = c.audio_fade_out_curve().is_none();
                c.set_audio_fade_out(len.max(Time::ZERO), frame_duration, ids);
                if is_new && default_curve != FadeCurve::Linear && c.audio_fade_out_curve().is_some() {
                    c.set_audio_fade_curve(default_curve, false);
                }
            }
        }
        c
    }
}

/// Fade handles: the two small squares near the top corners of an audio clip (Premiere's fade handles). Dragging one
/// sets the head or tail fade as keys on the volume line.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FadeHandle {
    /// The fade in.
    Head,
    /// The fade out.
    Tail,
}

/// A fade handle dragged: `dx` points moved since the press (the handle was at `start_length` then).
#[derive(Clone, Copy, Debug)]
pub struct FadeDrag {
    /// The handle.
    pub handle: FadeHandle,
    /// Fade length at the press.
    pub start_length: Time,
    /// Pointer travel in points.
    pub dx: f64,
}

/// One drag on the volume line. Always recomputes from the clip it started with, so the result depends only on
/// where the pointer is now (dragging back to the start restores the original).
#[derive(Clone)]
pub struct VolumeLineGesture {
    /// The clip at the press.
    pub original: Clip,
    hit: VolumeHit,
    start: Point,
    clip_rect: Rect,
    geometry: TimelineGeometry,
    start_clip: Clip,
    key_id: Option<Id>,
}

impl VolumeLineGesture {
    /// `add_key`: Cmd-click on the line first adds a key there, then the drag moves that key.
    pub fn new(
        clip: &Clip,
        hit: VolumeHit,
        start: Point,
        clip_rect: Rect,
        geometry: TimelineGeometry,
        add_key: bool,
        ids: &mut dyn IdSource,
    ) -> VolumeLineGesture {
        let mut c = clip.clone();
        let mut key_id = None;
        match hit {
            VolumeHit::Key(id) => key_id = Some(id),
            VolumeHit::Line(t) => {
                if add_key {
                    key_id = Some(c.add_volume_key(t.snapped(geometry.frame_duration), ids));
                }
            }
        }
        VolumeLineGesture { original: clip.clone(), hit, start, clip_rect, geometry, start_clip: c, key_id }
    }

    /// The clip for the pointer at `p`.
    pub fn update(&mut self, p: Point) -> Clip {
        if (p.x - self.start.x).hypot(p.y - self.start.y) < 1.0 {
            return self.start_clip.clone(); // no real movement: nothing to commit
        }
        let mut c = self.start_clip.clone();
        let lane = VolumeLine::lane(&self.clip_rect);
        if let Some(id) = self.key_id {
            let t = self.geometry.time(p.x) - c.start;
            c.move_volume_key(id, t, VolumeLine::db_for_y(p.y, &lane));
        } else if let VolumeHit::Line(t) = self.hit {
            let delta = VolumeLine::db_for_y(p.y, &lane) - VolumeLine::db_for_y(self.start.y, &lane);
            c.shift_volume_line(t, delta);
        }
        c
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;
    use sq_core_model::TrackKind;
    use sq_core_time::{SequentialIds, TimeRange};

    const F30: Time = Time::new(1, 30);

    fn clip(start: i64, frames: i64) -> Clip {
        Clip::new(uid(), "a", uid(), TrackKind::Audio, TimeRange::new(Time::ZERO, F30 * frames), F30 * start)
    }

    fn geo() -> TimelineGeometry {
        TimelineGeometry::with_points_per_frame(F30, 4.0)
    }

    // Audio row 80 pt tall at y 100; 4 pt per frame; clip from frame 0.
    fn rect(c: &Clip) -> Rect {
        Rect::new(geo().x(c.start), 100.0, geo().width(c.source.duration), 80.0)
    }

    #[test]
    fn db_and_y_are_inverse_and_clamped_at_the_ends() {
        let lane = Rect::new(0.0, 0.0, 100.0, 55.0);
        assert!((VolumeLine::y_for_db(VolumeLine::DB_TOP, &lane) - 0.0).abs() < 1e-9);
        assert!((VolumeLine::y_for_db(VolumeLine::DB_BOTTOM, &lane) - 55.0).abs() < 1e-9);
        let mut db = -35.0;
        while db <= 15.0 {
            assert!((VolumeLine::db_for_y(VolumeLine::y_for_db(db, &lane), &lane) - db).abs() < 1e-9);
            db += 5.0;
        }
        assert_eq!(VolumeLine::db_for_y(-50.0, &lane), VolumeLine::DB_TOP);
        assert_eq!(VolumeLine::db_for_y(56.0, &lane), AudioGain::SILENCE_DB); // below the bottom = silence
        assert_eq!(VolumeLine::y_for_db(AudioGain::SILENCE_DB, &lane), 55.0);
    }

    #[test]
    fn only_tall_rows_get_a_band() {
        assert!(!VolumeLine::is_available(22.0) && !VolumeLine::is_available(38.0));
        assert!(VolumeLine::is_available(VolumeLine::MIN_ROW_HEIGHT));
    }

    #[test]
    fn hits_the_line_at_its_height_but_not_far_away() {
        let c = clip(0, 90);
        let r = rect(&c);
        let lane = VolumeLine::lane(&r);
        let y = VolumeLine::y_for_db(0.0, &lane);
        let x = geo().x(F30 * 30);
        assert_eq!(VolumeLine::hit(&c, &r, pt(x, y + 2.0), &geo()), Some(VolumeHit::Line(F30 * 30)));
        assert_eq!(VolumeLine::hit(&c, &r, pt(x, y + 15.0), &geo()), None);
        assert_eq!(VolumeLine::hit(&c, &r, pt(r.max_x() + 20.0, y), &geo()), None);
    }

    #[test]
    fn key_beats_line() {
        let mut c = clip(0, 90);
        let k = c.add_volume_key(F30 * 30, &mut SequentialIds::default());
        let r = rect(&c);
        let lane = VolumeLine::lane(&r);
        let p = pt(geo().x(F30 * 30) + 2.0, VolumeLine::y_for_db(0.0, &lane) + 2.0);
        assert_eq!(VolumeLine::hit(&c, &r, p, &geo()), Some(VolumeHit::Key(k)));
    }

    #[test]
    fn dragging_the_line_down_lowers_the_whole_clip() {
        let c = clip(0, 90);
        let r = rect(&c);
        let lane = VolumeLine::lane(&r);
        let y0 = VolumeLine::y_for_db(0.0, &lane);
        let mut g = VolumeLineGesture::new(
            &c,
            VolumeHit::Line(F30 * 30),
            pt(100.0, y0),
            r,
            geo(),
            false,
            &mut SequentialIds::default(),
        );
        let moved = g.update(pt(100.0, VolumeLine::y_for_db(-10.0, &lane)));
        assert!((AudioGain::db_from_linear(moved.animation.volume.value) + 10.0).abs() < 1e-6);
        assert!(!moved.animation.volume.is_animated());
        // Dragging back to the start restores the original (the gesture always starts from the clip it began with).
        let back = g.update(pt(100.0, y0));
        assert_eq!(back, c);
    }

    #[test]
    fn cmd_click_adds_a_key_on_the_line_and_dragging_it_moves_time_and_level() {
        let c = clip(0, 90);
        let r = rect(&c);
        let lane = VolumeLine::lane(&r);
        let x = geo().x(F30 * 30);
        let mut g = VolumeLineGesture::new(
            &c,
            VolumeHit::Line(F30 * 30),
            pt(x, VolumeLine::y_for_db(0.0, &lane)),
            r,
            geo(),
            true,
            &mut SequentialIds::default(),
        );
        let added = g.update(pt(x, VolumeLine::y_for_db(0.0, &lane)));
        assert_eq!(added.animation.volume.track.keys.len(), 1);
        let moved = g.update(pt(geo().x(F30 * 45), VolumeLine::y_for_db(-6.0, &lane)));
        let key = &moved.animation.volume.track.keys[0];
        assert!(key.time == F30 * 45 && (AudioGain::db_from_linear(key.value) + 6.0).abs() < 1e-6);
    }

    #[test]
    fn dragging_a_key_is_clamped_to_the_clip() {
        let mut c = clip(0, 90);
        let k = c.add_volume_key(F30 * 30, &mut SequentialIds::default());
        let r = rect(&c);
        let lane = VolumeLine::lane(&r);
        let mut g = VolumeLineGesture::new(
            &c,
            VolumeHit::Key(k),
            pt(geo().x(F30 * 30), VolumeLine::y_for_db(0.0, &lane)),
            r,
            geo(),
            false,
            &mut SequentialIds::default(),
        );
        let far = g.update(pt(r.max_x() + 500.0, VolumeLine::y_for_db(99.0, &lane)));
        let key = far.animation.volume.track.key(k).unwrap();
        assert_eq!(key.time, c.source.duration);
        assert!((AudioGain::db_from_linear(key.value) - AudioGain::MAX_VOLUME_DB).abs() < 1e-6);
    }

    #[test]
    fn line_samples_follow_the_keys() {
        let mut c = clip(0, 90);
        let mut ids = SequentialIds::default();
        let a = c.add_volume_key(Time::ZERO, &mut ids);
        let b = c.add_volume_key(F30 * 90, &mut ids);
        c.animation.volume.track.set(a, 1.0);
        c.animation.volume.track.set(b, 0.5);
        let r = rect(&c);
        let pts = VolumeLine::points(&c, &r, &r, 90.0);
        assert!(pts.len() >= 3);
        let lane = VolumeLine::lane(&r);
        assert!((pts[0].y - VolumeLine::y_for_db(0.0, &lane)).abs() < 0.5);
        assert!((pts[pts.len() - 1].y - VolumeLine::y_for_db(AudioGain::db_from_linear(0.5), &lane)).abs() < 0.5);
    }

    #[test]
    fn a_click_without_movement_changes_nothing() {
        let mut c = clip(0, 90);
        let k = c.add_volume_key(F30 * 30, &mut SequentialIds::default());
        let r = rect(&c);
        let lane = VolumeLine::lane(&r);
        let y = VolumeLine::y_for_db(-3.3, &lane);
        let mut ids = SequentialIds::default();
        let mut g = VolumeLineGesture::new(&c, VolumeHit::Line(F30 * 10), pt(80.0, y), r, geo(), false, &mut ids);
        assert_eq!(g.update(pt(80.0, y)), c);
        let mut kg = VolumeLineGesture::new(&c, VolumeHit::Key(k), pt(80.0, y), r, geo(), false, &mut ids);
        assert_eq!(kg.update(pt(80.3, y)), c);
        let mut plain = clip(0, 90);
        let before = plain.clone();
        plain.shift_volume_line(F30 * 3, 0.0);
        assert_eq!(plain, before);
    }

    #[test]
    fn edge_trim_beats_a_key_near_the_clip_ends() {
        let c = clip(0, 90);
        let r = rect(&c);
        assert!(VolumeLine::edge_wins(pt(r.min_x() + 3.0, r.mid_y()), &r));
        assert!(VolumeLine::edge_wins(pt(r.max_x() - 5.0, r.mid_y()), &r));
        assert!(!VolumeLine::edge_wins(pt(r.mid_x(), r.mid_y()), &r));
    }

    // Ports of DefaultFadeCurveTests (the drag part).
    fn fade_clip() -> Clip {
        Clip::new(uid(), "a", uid(), TrackKind::Audio, TimeRange::new(Time::ZERO, Time::new(10, 1)), Time::new(5, 1))
    }

    fn fade_rect() -> Rect {
        Rect::new(100.0, 0.0, 400.0, 60.0)
    }

    fn dragged(c: &Clip, handle: FadeHandle, from: Time, dx: f64, curve: FadeCurve) -> Clip {
        let d = FadeDrag { handle, start_length: from, dx };
        VolumeLine::clip_dragging(c, &d, &fade_rect(), F30, curve, &mut SequentialIds::default())
    }

    #[test]
    fn a_new_fade_gets_the_default_curve() {
        let h = dragged(&fade_clip(), FadeHandle::Head, Time::ZERO, 40.0, FadeCurve::SCurve);
        assert_eq!(h.audio_fade_in_curve(), Some(FadeCurve::SCurve));
        let t = dragged(&fade_clip(), FadeHandle::Tail, Time::ZERO, -40.0, FadeCurve::Minus3dB);
        assert_eq!(t.audio_fade_out_curve(), Some(FadeCurve::Minus3dB));
    }

    #[test]
    fn an_existing_fade_keeps_its_own_curve() {
        let mut c = fade_clip();
        c.set_audio_fade_in(Time::new(1, 1), F30, &mut SequentialIds::default());
        c.set_audio_fade_curve(FadeCurve::Plus3dB, true);
        let longer = dragged(&c, FadeHandle::Head, Time::new(1, 1), 40.0, FadeCurve::SCurve);
        assert_eq!(longer.audio_fade_in_curve(), Some(FadeCurve::Plus3dB));
        assert_eq!(longer.audio_fade_in(), Time::new(2, 1));
    }

    #[test]
    fn a_linear_default_and_a_sub_frame_drag_stay_plain() {
        let c = dragged(&fade_clip(), FadeHandle::Head, Time::ZERO, 40.0, FadeCurve::Linear);
        assert!(matches!(c.audio_fade_in_curve(), None | Some(FadeCurve::Linear)));
        let tiny = dragged(&fade_clip(), FadeHandle::Head, Time::ZERO, 0.5, FadeCurve::SCurve);
        assert_eq!(tiny.animation, fade_clip().animation);
    }
}

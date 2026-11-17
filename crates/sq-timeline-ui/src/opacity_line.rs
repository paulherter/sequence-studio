// Swift: OpacityLine.swift
//! The opacity rubber band on a video clip (Premiere: Opacity keyframes on the clip): a line over the picture at the
//! clip's Opacity. Cmd-click adds a key at the clicked time holding the value shown there, drag a key to move it, drag the
//! line to change the level. Pure geometry and gesture maths, the twin of `VolumeLine`.

use crate::clip_body_metrics::ClipBodyMetrics;
use crate::timeline_geometry::TimelineGeometry;
use crate::volume_line::VolumeLine;
use sq_core_effects::effects_editing::ClipEffectsEditingExt;
use sq_core_model::{Clip, TrackKind};
use sq_core_time::{Id, IdSource, Time};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};

/// What a pointer on the opacity line grabs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpacityHit {
    /// A key.
    Key(Id),
    /// On the line (not on a key) at this clip-local time.
    Line(Time),
}

/// The opacity line.
pub struct OpacityLine;

impl OpacityLine {
    /// Rows shorter than this show no band (too little room to grab it).
    pub const MIN_ROW_HEIGHT: f64 = VolumeLine::MIN_ROW_HEIGHT;
    const LINE_GRAB: f64 = 4.0;
    const KEY_GRAB: f64 = 6.0;

    /// The row is tall enough for the band.
    pub fn is_available(row_height: f64) -> bool {
        row_height >= Self::MIN_ROW_HEIGHT
    }

    /// The line is drawn (and grabbable) only when it says something: the opacity is not 100 % or it has keys. A plain clip
    /// shows nothing, selected or not (the board's selected clip has no line; the Controls panel is where opacity starts).
    pub fn is_visible(clip: &Clip, _selected: bool, row_height: f64) -> bool {
        if !(clip.kind == TrackKind::Video && Self::is_available(row_height)) {
            return false;
        }
        clip.animation.opacity.is_animated() || clip.animation.opacity.value != 1.0
    }

    /// The area the line moves in: the clip body below the name strip.
    pub fn lane(clip_rect: &Rect) -> Rect {
        ClipBodyMetrics::waveform_rect(clip_rect)
    }

    /// 100 % at the top of the lane, 0 % at the bottom.
    pub fn y_for_opacity(v: f64, lane: &Rect) -> f64 {
        lane.max_y() - lane.height * v.clamp(0.0, 1.0)
    }

    /// Opacity at a view y.
    pub fn opacity_for_y(y: f64, lane: &Rect) -> f64 {
        if lane.height <= 0.0 {
            return 1.0;
        }
        ((lane.max_y() - y) / lane.height).clamp(0.0, 1.0)
    }

    fn level(clip: &Clip, local: Time) -> f64 {
        clip.animation.opacity.value_at_local(local).clamp(0.0, 1.0)
    }

    /// What `p` grabs: a key, the line, or nothing.
    pub fn hit(clip: &Clip, clip_rect: &Rect, p: Point, geometry: &TimelineGeometry) -> Option<OpacityHit> {
        if !clip_rect.inset_by(-Self::KEY_GRAB, 0.0).contains(Point::new(p.x, clip_rect.mid_y())) {
            return None;
        }
        let lane = Self::lane(clip_rect);
        if lane.height < 4.0 {
            return None;
        }
        for k in clip.animation.opacity.track.keys.iter() {
            let kx = geometry.x(clip.start + k.time);
            let ky = Self::y_for_opacity(k.value, &lane);
            if (p.x - kx).hypot(p.y - ky) <= Self::KEY_GRAB {
                return Some(OpacityHit::Key(k.id));
            }
        }
        if !clip_rect.contains(Point::new(p.x, clip_rect.mid_y())) {
            return None;
        }
        let local = (geometry.time(p.x) - clip.start).max(Time::ZERO).min(clip.duration());
        if (p.y - Self::y_for_opacity(Self::level(clip, local), &lane)).abs() <= Self::LINE_GRAB {
            Some(OpacityHit::Line(local))
        } else {
            None
        }
    }

    fn x_of(t: Time, clip: &Clip, rect: &Rect) -> f64 {
        let d = clip.duration().value() as f64 / clip.duration().timescale() as f64;
        let s = t.value() as f64 / t.timescale() as f64;
        rect.min_x() + (if d > 0.0 { s / d } else { 0.0 }) * rect.width
    }

    /// Polyline of the line inside `visible`, `step` points apart (keys are always included).
    pub fn points(clip: &Clip, clip_rect: &Rect, visible: &Rect, step: f64) -> Vec<Point> {
        let lane = Self::lane(clip_rect);
        let x0 = clip_rect.min_x().max(visible.min_x());
        let x1 = clip_rect.max_x().min(visible.max_x());
        if !(x1 > x0 && lane.height > 0.0) {
            return Vec::new();
        }
        if clip.animation.opacity.track.is_empty() {
            let y = Self::y_for_opacity(clip.animation.opacity.value, &lane);
            return vec![Point::new(x0, y), Point::new(x1, y)];
        }
        let d = clip.duration();
        let sec_per_point = d.value() as f64 / d.timescale() as f64 / clip_rect.width.max(1.0);
        let at = |x: f64| -> Point {
            let t = Time::new(((x - clip_rect.min_x()) * sec_per_point * 1_000_000.0).round() as i64, 1_000_000);
            Point::new(x, Self::y_for_opacity(Self::level(clip, t), &lane))
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
                .opacity
                .track
                .keys
                .iter()
                .map(|k| Self::x_of(k.time, clip, clip_rect))
                .filter(|x| *x > x0 && *x < x1),
        );
        xs.sort_by(f64::total_cmp);
        xs.into_iter().map(at).collect()
    }

    /// Key positions (view points) for drawing.
    pub fn key_points(clip: &Clip, clip_rect: &Rect) -> Vec<Point> {
        let lane = Self::lane(clip_rect);
        clip.animation
            .opacity
            .track
            .keys
            .iter()
            .map(|k| Point::new(Self::x_of(k.time, clip, clip_rect), Self::y_for_opacity(k.value, &lane)))
            .collect()
    }
}

/// One drag on the opacity line. Always recomputes from the clip it started with, so the result depends only on where the
/// pointer is now (dragging back to the start restores the original).
#[derive(Clone)]
pub struct OpacityLineGesture {
    /// The clip at the press.
    pub original: Clip,
    hit: OpacityHit,
    start: Point,
    clip_rect: Rect,
    geometry: TimelineGeometry,
    start_clip: Clip,
    key_id: Option<Id>,
}

impl OpacityLineGesture {
    /// `add_key`: Cmd-click on the line first adds a key there (holding the value shown at that time), then the drag moves it.
    pub fn new(
        clip: &Clip,
        hit: OpacityHit,
        start: Point,
        clip_rect: Rect,
        geometry: TimelineGeometry,
        add_key: bool,
        ids: &mut dyn IdSource,
    ) -> OpacityLineGesture {
        let mut c = clip.clone();
        let mut key_id = None;
        match hit {
            OpacityHit::Key(id) => key_id = Some(id),
            OpacityHit::Line(t) => {
                if add_key {
                    key_id = c.add_opacity_key(t.snapped(geometry.frame_duration), ids);
                }
            }
        }
        OpacityLineGesture { original: clip.clone(), hit, start, clip_rect, geometry, start_clip: c, key_id }
    }

    /// The clip for the pointer at `p`.
    pub fn update(&mut self, p: Point) -> Clip {
        if (p.x - self.start.x).hypot(p.y - self.start.y) < 1.0 {
            return self.start_clip.clone(); // no real movement: nothing more to commit
        }
        let mut c = self.start_clip.clone();
        let lane = OpacityLine::lane(&self.clip_rect);
        if let Some(id) = self.key_id {
            c.move_opacity_key(
                id,
                self.geometry.time(p.x) - c.start,
                OpacityLine::opacity_for_y(p.y, &lane),
                Some(self.geometry.frame_duration),
            );
        } else if let OpacityHit::Line(t) = self.hit {
            c.shift_opacity_line(
                t,
                OpacityLine::opacity_for_y(p.y, &lane) - OpacityLine::opacity_for_y(self.start.y, &lane),
            );
        }
        c
    }
}

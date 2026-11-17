//! The Time Remapping speed rubber band on a video clip: pure geometry and gesture maths (the view draws it and routes
//! the mouse; tests drive it with a time <-> x mapping). Layout: a strip along the top of the lane holds the speed keys
//! and the shaded span of each transition; below it the line's height is the speed on a log scale (100 % in the middle,
//! `OCTAVES` doublings up and down).

use std::sync::Arc;

use sq_core_model::{ClipSpeed, SpeedKeys};
use sq_core_time::Time;
use sq_uikit::keyframe_graph_geometry::{Point, Rect};

/// Namespace of the band's constants and geometry (Swift caseless `enum SpeedBand`).
pub enum SpeedBand {}

// Swift: SpeedBand.swift:28
impl SpeedBand {
    /// Rows shorter than this show no band.
    pub const MIN_ROW_HEIGHT: f64 = 40.0;
    /// Height of the key strip at the top of the lane.
    // Swift: SpeedBand.swift:30
    pub const STRIP_HEIGHT: f64 = 9.0;
    /// Doublings between 100 % and the top / bottom of the line area (top = 16x, bottom = 1/16x).
    // Swift: SpeedBand.swift:32
    pub const OCTAVES: f64 = 4.0;
    // Swift: SpeedBand.swift:33
    pub const LINE_GRAB: f64 = 4.0;
    // Swift: SpeedBand.swift:34
    pub const KEY_GRAB: f64 = 5.0;
    const HANDLE_GRAB: f64 = 6.0;

    // Swift: SpeedBand.swift:36
    pub fn is_available(row_height: f64) -> bool {
        row_height >= Self::MIN_ROW_HEIGHT
    }

    /// The strip for keys and transitions.
    // Swift: SpeedBand.swift:40
    pub fn strip(lane: Rect) -> Rect {
        Rect::new(lane.x, lane.y, lane.width, Self::STRIP_HEIGHT.min(lane.height / 2.0))
    }

    /// The area the line moves in (below the strip).
    // Swift: SpeedBand.swift:42
    pub fn line_area(lane: Rect) -> Rect {
        let s = Self::strip(lane);
        Rect::new(lane.x, s.max_y() + 2.0, lane.width, (lane.height - s.height - 4.0).max(1.0))
    }

    /// y of a speed ratio (1 = 100 %), flipped coordinates (up = smaller y). Clamped to the area.
    // Swift: SpeedBand.swift:48
    pub fn y_for_speed(speed: f64, area: Rect) -> f64 {
        let o = speed.max(1e-6).log2().clamp(-Self::OCTAVES, Self::OCTAVES);
        area.mid_y() - o / Self::OCTAVES * area.height / 2.0
    }

    /// Speed ratio at a y (inverse of `y_for_speed`), within 1/16x ... 16x and the 1 % ... 10000 % of `ClipSpeed`.
    // Swift: SpeedBand.swift:54
    pub fn speed_for_y(y: f64, area: Rect) -> f64 {
        if area.height <= 0.0 {
            return 1.0;
        }
        let f = (area.mid_y() - y) / (area.height / 2.0);
        2f64.powf(f.clamp(-1.0, 1.0) * Self::OCTAVES).clamp(0.01, 100.0)
    }

    /// Typed-in precision: Shift snaps the percentage to steps of 5 %.
    // Swift: SpeedBand.swift:61
    pub fn snapped_percent(percent: f64, steps: bool) -> f64 {
        let p = percent.max(1.0);
        if steps { ((p / 5.0).round() * 5.0).max(5.0) } else { p.round() }
    }

    // Swift: SpeedBand.swift:65
    pub fn label(speed: f64) -> String {
        let s = format!("{:.0}", speed * 100.0);
        format!("{}%", if s == "0" { "1".to_string() } else { s })
    }

    /// Polyline of the rubber band (a ramp is sampled; speeds interpolate linearly in time, so the log-scale curve bends).
    // Swift: SpeedBand.swift:75
    pub fn line_points(keys: &SpeedKeys, clip_start: Time, lane: Rect, x: impl Fn(Time) -> f64) -> Vec<Point> {
        let area = Self::line_area(lane);
        let mut pts = Vec::new();
        let starts = keys.boundaries();
        for (i, s) in keys.segments.iter().enumerate() {
            let x0 = x(clip_start + starts[i]);
            let x1 = x(clip_start + starts[i + 1]);
            if !s.is_ramp() {
                let y = Self::y_for_speed(s.speed_value(Time::ZERO), area);
                pts.push(Point::new(x0, y));
                pts.push(Point::new(x1, y));
            } else {
                let n = (((x1 - x0).abs() / 4.0).min(24.0) as i64).max(4);
                for k in 0..=n {
                    let f = k as f64 / n as f64;
                    let t = Time::new((f * 1_000_000.0).round() as i64, 1_000_000);
                    let local = Time::new(s.duration.value() * t.value(), s.duration.timescale() * t.timescale());
                    pts.push(Point::new(x0 + (x1 - x0) * f, Self::y_for_speed(s.speed_value(local), area)));
                }
            }
        }
        pts
    }

    // Swift: SpeedBand.swift:112
    pub fn key_marks(keys: &SpeedKeys, clip_start: Time, x: impl Fn(Time) -> f64) -> Vec<KeyMark> {
        let b = keys.boundaries();
        (1..keys.segments.len())
            .map(|i| {
                let (left, right) = (&keys.segments[i - 1], &keys.segments[i]);
                KeyMark {
                    boundary: i,
                    x: x(clip_start + b[i]),
                    is_half: left.is_ramp() || right.is_ramp(),
                    is_left_half: right.is_ramp(),
                }
            })
            .collect()
    }

    // Swift: SpeedBand.swift:122
    pub fn ramp_marks(keys: &SpeedKeys, clip_start: Time, lane: Rect, x: impl Fn(Time) -> f64) -> Vec<RampMark> {
        let area = Self::line_area(lane);
        let b = keys.boundaries();
        keys.segments
            .iter()
            .enumerate()
            .filter(|(_, s)| s.is_ramp())
            .map(|(i, s)| {
                let x0 = x(clip_start + b[i]);
                let x1 = x(clip_start + b[i + 1]);
                let mid = s.speed_value(Time::new(s.duration.value(), s.duration.timescale() * 2));
                RampMark { segment: i, x0, x1, handle: Point::new((x0 + x1) / 2.0, Self::y_for_speed(mid, area)) }
            })
            .collect()
    }

    /// What is under the pointer: handles first (on the line), then keys, ramps, segments.
    // Swift: SpeedBand.swift:145
    pub fn hit(
        keys: &SpeedKeys,
        clip_start: Time,
        lane: Rect,
        p: Point,
        x: impl Fn(Time) -> f64,
    ) -> Option<SpeedBandHit> {
        let strip = Self::strip(lane);
        let area = Self::line_area(lane);
        if p.x < lane.min_x() - Self::KEY_GRAB || p.x > lane.max_x() + Self::KEY_GRAB {
            return None;
        }
        let ramps = Self::ramp_marks(keys, clip_start, lane, &x);
        if let Some(r) = ramps.iter().find(|r| (p.x - r.handle.x).hypot(p.y - r.handle.y) <= Self::HANDLE_GRAB) {
            return Some(SpeedBandHit::RampHandle(r.segment));
        }
        if p.y >= strip.min_y() - 2.0 && p.y <= strip.max_y() + 2.0 {
            if let Some(k) = Self::key_marks(keys, clip_start, &x).iter().find(|k| (p.x - k.x).abs() <= Self::KEY_GRAB)
            {
                return Some(SpeedBandHit::Key(k.boundary));
            }
            return ramps.iter().find(|r| p.x > r.x0 && p.x < r.x1).map(|r| SpeedBandHit::Ramp(r.segment));
        }
        if p.y < area.min_y() - Self::LINE_GRAB || p.y > area.max_y() + Self::LINE_GRAB {
            return None;
        }
        let starts = keys.boundaries();
        for (i, s) in keys.segments.iter().enumerate() {
            let x0 = x(clip_start + starts[i]);
            let x1 = x(clip_start + starts[i + 1]);
            if p.x < x0 || p.x > x1 {
                continue;
            }
            if s.is_ramp() {
                let f = if x1 > x0 { (p.x - x0) / (x1 - x0) } else { 0.0 };
                let local = Time::new(
                    ((f * 1_000_000.0).round() as i64) * s.duration.value(),
                    1_000_000 * s.duration.timescale(),
                );
                if (p.y - Self::y_for_speed(s.speed_value(local), area)).abs() <= Self::LINE_GRAB {
                    return Some(SpeedBandHit::Ramp(i));
                }
            } else if (p.y - Self::y_for_speed(s.speed_value(Time::ZERO), area)).abs() <= Self::LINE_GRAB {
                return Some(SpeedBandHit::Segment(i));
            }
        }
        None
    }

    /// Keys with the key / transition under `hit` removed (Delete). `None` when `hit` is not a key or transition.
    // Swift: SpeedBand.swift:245
    pub fn deleting(hit: SpeedBandHit, keys: &SpeedKeys, fd: Time) -> Option<SpeedKeys> {
        match hit {
            SpeedBandHit::Ramp(i) | SpeedBandHit::RampHandle(i) => keys.removing_ramp(i, fd),
            SpeedBandHit::Key(b) => {
                if b == 0 || b >= keys.segments.len() {
                    return None;
                }
                if keys.segments[b].is_ramp() {
                    return keys.removing_ramp(b, fd);
                }
                if keys.segments[b - 1].is_ramp() {
                    return keys.removing_ramp(b - 1, fd);
                }
                keys.removing_key(b)
            }
            SpeedBandHit::Segment(_) => None,
        }
    }
}

/// A key (boundary) of the band.
// Swift: SpeedBand.swift:94
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct KeyMark {
    /// Boundary index (1 ..< segments.count).
    // Swift: SpeedBand.swift:99
    pub boundary: usize,
    // Swift: SpeedBand.swift:100
    pub x: f64,
    /// True when the boundary belongs to a speed transition (a half of a split key).
    // Swift: SpeedBand.swift:102
    pub is_half: bool,
    /// Which side the half faces: a ramp starts at its left half's boundary.
    // Swift: SpeedBand.swift:104
    pub is_left_half: bool,
}

/// The shaded span of a speed transition with its center handle.
// Swift: SpeedBand.swift:103
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RampMark {
    // Swift: SpeedBand.swift:107
    pub segment: usize,
    // Swift: SpeedBand.swift:108
    pub x0: f64,
    pub x1: f64,
    /// Center handle on the line.
    // Swift: SpeedBand.swift:110
    pub handle: Point,
}

/// What a point on the band grabs (Swift `SpeedBand.Hit`).
// Swift: SpeedBand.swift:132
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpeedBandHit {
    /// A flat part of the line: change its speed.
    Segment(usize),
    /// A key (boundary) in the strip; may be a half of a transition.
    Key(usize),
    /// The shaded span of a transition: move it.
    Ramp(usize),
    /// The center handle of a transition: widen / narrow it.
    RampHandle(usize),
}

/// One drag on the band. `update` is pure: always computed from the keys at mouse-down, so a drag can overshoot and
/// come back.
// Swift: SpeedBand.swift:174
#[derive(Clone)]
pub struct SpeedBandGesture {
    // Swift: SpeedBand.swift:178
    pub original: SpeedKeys,
    // Swift: SpeedBand.swift:179
    pub hit: Option<SpeedBandHit>,
    // Swift: SpeedBand.swift:180
    pub start: Point,
    // Swift: SpeedBand.swift:181
    pub lane: Rect,
    // Swift: SpeedBand.swift:182
    pub frame_duration: Time,
    // Swift: SpeedBand.swift:183
    pub add_key_at: Option<Time>,
    // Swift: SpeedBand.swift:184
    pub move_unsplit: bool,
    // Swift: SpeedBand.swift:185
    pub steps: bool,
    // Swift: SpeedBand.swift:186
    pub time_at: Arc<dyn Fn(f64) -> Time + Send + Sync>,
    // Swift: SpeedBand.swift:187
    pub clip_start: Time,
}

/// Inputs of [`SpeedBandGesture::new`] (Swift's initializer labels).
pub struct SpeedBandGestureStart {
    pub keys: SpeedKeys,
    pub clip_start: Time,
    pub hit: Option<SpeedBandHit>,
    pub start: Point,
    pub lane: Rect,
    pub frame_duration: Time,
    /// Cmd-click.
    pub add_key: bool,
    /// Option moves an unsplit key.
    pub option: bool,
    /// Shift: 5 % steps.
    pub shift: bool,
    /// x -> absolute timeline time.
    pub time_at: Arc<dyn Fn(f64) -> Time + Send + Sync>,
}

impl SpeedBandGesture {
    // Swift: SpeedBand.swift:190
    pub fn new(s: SpeedBandGestureStart) -> SpeedBandGesture {
        let add_key_at = s.add_key.then(|| (s.time_at)(s.start.x) - s.clip_start);
        SpeedBandGesture {
            original: s.keys,
            hit: s.hit,
            start: s.start,
            lane: s.lane,
            frame_duration: s.frame_duration,
            add_key_at,
            move_unsplit: s.option,
            steps: s.shift,
            time_at: s.time_at,
            clip_start: s.clip_start,
        }
    }

    /// Whether this drag keeps keys that change nothing: a Cmd-click key (like the Effect Controls diamond) and any drag
    /// on a track that only has such keys. Decided once from the track at mouse-down, so the drag stays idempotent.
    // Swift: SpeedBand.swift:199
    pub fn keeps_keys(&self) -> bool {
        self.add_key_at.is_some() || (self.original.segments.len() > 1 && self.original.is_uniform())
    }

    /// Keys after the drag reached `p`. Equal to the original when the gesture does not apply yet.
    // Swift: SpeedBand.swift:202
    pub fn update(&self, p: Point) -> SpeedKeys {
        let fd = self.frame_duration;
        let o = &self.original;
        if let Some(t) = self.add_key_at {
            return o.adding_key(t, fd).map(|(k, _)| k).unwrap_or_else(|| o.clone());
        }
        let dt = (self.time_at)(p.x) - (self.time_at)(self.start.x);
        let area = SpeedBand::line_area(self.lane);
        let has = |i: usize| i < o.segments.len();
        match self.hit {
            Some(SpeedBandHit::Segment(i)) => {
                if !has(i) || o.segments[i].is_ramp() {
                    return o.clone();
                }
                let pct = SpeedBand::snapped_percent(SpeedBand::speed_for_y(p.y, area) * 100.0, self.steps);
                o.setting_speed(i, ClipSpeed::from_percent(pct), fd)
            }
            Some(SpeedBandHit::Key(b)) => {
                if !has(b) || b == 0 {
                    return o.clone();
                }
                let half_of_ramp = o.segments[b - 1].is_ramp() || o.segments[b].is_ramp();
                if half_of_ramp || self.move_unsplit {
                    return o.moving_key(b, dt, fd).unwrap_or_else(|| o.clone());
                }
                // A point (Resolve): it keeps its source frame, so the span before it gets slower to the right, faster to the left.
                if !self.steps {
                    return o.retiming_key(b, dt, fd).unwrap_or_else(|| o.clone());
                }
                let split = if dt > Time::ZERO {
                    o.splitting_key_taking(b, Time::ZERO, dt, fd)
                } else if dt < Time::ZERO {
                    o.splitting_key_taking(b, Time::ZERO - dt, Time::ZERO, fd)
                } else {
                    None
                };
                split.unwrap_or_else(|| o.clone())
            }
            Some(SpeedBandHit::Ramp(i)) => o.moving_ramp(i, dt, fd).unwrap_or_else(|| o.clone()),
            Some(SpeedBandHit::RampHandle(i)) => {
                if !has(i) {
                    return o.clone();
                }
                let w = o.segments[i].duration + dt + dt;
                o.setting_ramp_width(i, w, fd).unwrap_or_else(|| o.clone())
            }
            None => o.clone(),
        }
    }

    /// Text for the tooltip while dragging a segment ("Speed 250%"); `None` otherwise.
    // Swift: SpeedBand.swift:232
    pub fn tooltip(&self, p: Point) -> Option<String> {
        let o = &self.original;
        if let Some(SpeedBandHit::Key(b)) = self.hit
            && !self.steps
            && !self.move_unsplit
            && b >= 1
            && b < o.segments.len()
            && !o.segments[b - 1].is_ramp()
            && !o.segments[b].is_ramp()
        {
            let k = self.update(p);
            return k.segments.get(b - 1).map(|s| format!("Speed {}", SpeedBand::label(s.from.percent() / 100.0)));
        }
        let Some(SpeedBandHit::Segment(_)) = self.hit else { return None };
        let pct = SpeedBand::snapped_percent(
            SpeedBand::speed_for_y(p.y, SpeedBand::line_area(self.lane)) * 100.0,
            self.steps,
        );
        Some(format!("Speed {}", SpeedBand::label(pct / 100.0)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::SpeedSegment;

    fn fd() -> Time {
        Time::new(1, 30)
    }
    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }
    fn pct(p: f64) -> ClipSpeed {
        ClipSpeed::from_percent(p)
    }
    /// 30 points per second, clip starts at timeline 0 -> x = 30 * seconds + 10.
    fn x(t: Time) -> f64 {
        10.0 + 30.0 * t.value() as f64 / t.timescale() as f64
    }
    fn lane() -> Rect {
        Rect::new(10.0, 100.0, 300.0, 40.0)
    }
    fn seg(frames: i64, a: f64, b: Option<f64>) -> SpeedSegment {
        SpeedSegment::new(f(frames), pct(a), Some(pct(b.unwrap_or(a))), false, None)
    }
    fn keys(segs: Vec<SpeedSegment>) -> SpeedKeys {
        SpeedKeys::new(segs, Time::ZERO)
    }
    fn gesture(
        k: &SpeedKeys,
        hit: Option<SpeedBandHit>,
        start: Point,
        add_key: bool,
        option: bool,
        shift: bool,
    ) -> SpeedBandGesture {
        SpeedBandGesture::new(SpeedBandGestureStart {
            keys: k.clone(),
            clip_start: Time::ZERO,
            hit,
            start,
            lane: lane(),
            frame_duration: fd(),
            add_key,
            option,
            shift,
            time_at: Arc::new(|x| Time::new((((x - 10.0) / 30.0 * 3000.0).round()) as i64, 3000)),
        })
    }
    fn g(k: &SpeedKeys, hit: Option<SpeedBandHit>, start: Point) -> SpeedBandGesture {
        gesture(k, hit, start, false, false, false)
    }

    #[test]
    fn speed_height_is_logarithmic_and_invertible() {
        let area = SpeedBand::line_area(lane());
        assert_eq!(SpeedBand::y_for_speed(1.0, area), area.mid_y());
        assert!(SpeedBand::y_for_speed(2.0, area) < area.mid_y() && SpeedBand::y_for_speed(0.5, area) > area.mid_y());
        let sum =
            (SpeedBand::y_for_speed(4.0, area) - area.mid_y()) + (SpeedBand::y_for_speed(0.25, area) - area.mid_y());
        assert!(sum.abs() < 1e-9);
        for s in [0.1, 0.5, 1.0, 2.5, 8.0] {
            assert!((SpeedBand::speed_for_y(SpeedBand::y_for_speed(s, area), area) - s).abs() < 1e-9);
        }
        assert!(SpeedBand::snapped_percent(213.0, true) == 215.0 && SpeedBand::snapped_percent(213.4, false) == 213.0);
    }

    #[test]
    fn split_key_shows_two_halves_and_the_transition_span() {
        let k = keys(vec![seg(60, 100.0, None), seg(60, 300.0, None)]).splitting_key_taking(1, f(5), f(15), fd());
        let k = k.expect("split");
        let marks = SpeedBand::key_marks(&k, Time::ZERO, x);
        assert!(marks.len() == 2 && marks.iter().all(|m| m.is_half) && marks[0].is_left_half && !marks[1].is_left_half);
        assert!(marks[0].x == x(f(55)) && marks[1].x == x(f(75)));
        let ramps = SpeedBand::ramp_marks(&k, Time::ZERO, lane(), x);
        assert!(ramps.len() == 1 && ramps[0].x0 == x(f(55)) && ramps[0].x1 == x(f(75)));
    }

    #[test]
    fn ramp_handle_sits_in_the_middle_at_the_middle_speed() {
        let k = keys(vec![seg(30, 100.0, None), seg(30, 100.0, Some(400.0)), seg(30, 400.0, None)]);
        let r = SpeedBand::ramp_marks(&k, Time::ZERO, lane(), x)[0];
        assert!(r.segment == 1 && r.handle.x == (x(f(30)) + x(f(60))) / 2.0);
        let area = SpeedBand::line_area(lane());
        assert!((r.handle.y - SpeedBand::y_for_speed(2.5, area)).abs() < 1e-9);
    }

    #[test]
    fn hit_testing_finds_keys_ramps_handles_and_segments() {
        let k = keys(vec![seg(30, 100.0, None), seg(30, 100.0, Some(400.0)), seg(30, 400.0, None)]);
        let strip = SpeedBand::strip(lane());
        let area = SpeedBand::line_area(lane());
        let hit = |p: Point| SpeedBand::hit(&k, Time::ZERO, lane(), p, x);
        assert_eq!(hit(Point::new(x(f(30)), strip.mid_y())), Some(SpeedBandHit::Key(1)));
        assert_eq!(hit(Point::new(x(f(60)), strip.mid_y())), Some(SpeedBandHit::Key(2)));
        assert_eq!(hit(Point::new(x(f(45)), strip.mid_y())), Some(SpeedBandHit::Ramp(1)));
        let r = SpeedBand::ramp_marks(&k, Time::ZERO, lane(), x)[0];
        assert_eq!(hit(r.handle), Some(SpeedBandHit::RampHandle(1)));
        assert_eq!(hit(Point::new(x(f(10)), SpeedBand::y_for_speed(1.0, area))), Some(SpeedBandHit::Segment(0)));
        assert_eq!(hit(Point::new(x(f(80)), SpeedBand::y_for_speed(4.0, area))), Some(SpeedBandHit::Segment(2)));
        assert_eq!(hit(Point::new(x(f(10)), area.max_y() - 1.0)), None);
    }

    #[test]
    fn dragging_a_segment_changes_its_speed_and_the_clip_length() {
        let k = keys(vec![seg(30, 100.0, None), seg(30, 100.0, None)]);
        let area = SpeedBand::line_area(lane());
        let gs = g(&k, Some(SpeedBandHit::Segment(1)), Point::new(x(f(45)), SpeedBand::y_for_speed(1.0, area)));
        let up = gs.update(Point::new(x(f(45)), SpeedBand::y_for_speed(2.0, area)));
        assert!(up.segments.len() == 2 && up.segments[1].from == pct(200.0) && up.duration() == f(45));
        assert_eq!(up.end_position(), k.end_position());
        // overshoot and come back: computed from the original every time
        let _ = gs.update(Point::new(x(f(45)), SpeedBand::y_for_speed(8.0, area)));
        assert_eq!(gs.update(Point::new(x(f(45)), SpeedBand::y_for_speed(1.0, area))).duration(), k.duration());
        assert_eq!(gs.tooltip(Point::new(0.0, SpeedBand::y_for_speed(2.0, area))).as_deref(), Some("Speed 200%"));
    }

    #[test]
    fn cmd_click_adds_a_key_without_changing_the_mapping() {
        let k = SpeedKeys::new(vec![seg(60, 150.0, None)], f(7));
        let gs = gesture(&k, Some(SpeedBandHit::Segment(0)), Point::new(x(f(20)), 120.0), true, false, false);
        let n = gs.update(Point::new(x(f(50)), 90.0));
        assert!(n.segments.len() == 2 && n.boundaries()[1] == f(20));
        for i in (0..=60).step_by(6) {
            assert_eq!(n.position(f(i)), k.position(f(i)));
        }
    }

    #[test]
    fn dragging_the_halves_opens_and_moves_a_transition() {
        let k = keys(vec![seg(60, 100.0, None), seg(60, 300.0, None)]);
        let ly = lane().y + 3.0;
        let durations = |k: &SpeedKeys| k.segments.iter().map(|s| s.duration).collect::<Vec<_>>();
        let open = gesture(&k, Some(SpeedBandHit::Key(1)), Point::new(x(f(60)), ly), false, false, true)
            .update(Point::new(x(f(70)), ly));
        assert!(durations(&open) == vec![f(60), f(10), f(50)] && open.segments[1].is_ramp());
        let open_l = gesture(&k, Some(SpeedBandHit::Key(1)), Point::new(x(f(60)), ly), false, false, true)
            .update(Point::new(x(f(52)), ly));
        assert_eq!(durations(&open_l), vec![f(52), f(8), f(60)]);
        let wider = g(&open, Some(SpeedBandHit::Key(2)), Point::new(x(f(70)), ly)).update(Point::new(x(f(80)), ly));
        assert_eq!(durations(&wider), vec![f(60), f(20), f(40)]);
        let moved = g(&open, Some(SpeedBandHit::Ramp(1)), Point::new(x(f(65)), ly)).update(Point::new(x(f(75)), ly));
        assert!(durations(&moved) == vec![f(70), f(10), f(40)] && moved.duration() == open.duration());
        let h = SpeedBand::ramp_marks(&open, Time::ZERO, lane(), x)[0].handle;
        let widened = g(&open, Some(SpeedBandHit::RampHandle(1)), h).update(Point::new(h.x + 15.0, h.y));
        assert!(widened.segments[1].duration > open.segments[1].duration);
        let m = gesture(&k, Some(SpeedBandHit::Key(1)), Point::new(x(f(60)), ly), false, true, false)
            .update(Point::new(x(f(70)), ly));
        assert_eq!(durations(&m), vec![f(70), f(50)]);
    }

    #[test]
    fn dragging_a_point_retimes_the_span_before_it() {
        let k = keys(vec![seg(60, 100.0, None), seg(60, 100.0, None)]);
        let start = Point::new(x(f(60)), lane().y + 3.0);
        let gs = g(&k, Some(SpeedBandHit::Key(1)), start);
        let slower = gs.update(Point::new(x(f(90)), lane().y + 3.0));
        let ds: Vec<Time> = slower.segments.iter().map(|s| s.duration).collect();
        assert!(ds == vec![f(90), f(60)] && slower.duration() == k.duration() + f(30));
        assert!((slower.segments[0].from.percent() - 66.67).abs() < 0.1 && slower.segments[1].from.percent() == 100.0);
        let faster = gs.update(Point::new(x(f(30)), lane().y + 3.0));
        assert!(faster.segments[0].duration == f(30) && faster.segments[0].from.percent() == 200.0);
        assert_eq!(gs.update(start), k);
        assert_eq!(gs.tooltip(Point::new(x(f(30)), lane().y + 3.0)).as_deref(), Some("Speed 200%"));
    }

    #[test]
    fn delete_removes_a_key_or_a_transition() {
        let k = keys(vec![seg(60, 100.0, None), seg(60, 300.0, None)]);
        let split = k.splitting_key(1, f(5), fd()).expect("split");
        let reverted = SpeedBand::deleting(SpeedBandHit::Key(1), &split, fd()).expect("reverted");
        assert!(
            reverted.segments.len() == 2
                && !reverted.segments.iter().any(|s| s.is_ramp())
                && reverted.duration() == k.duration()
        );
        let gone = SpeedBand::deleting(SpeedBandHit::Key(1), &k, fd()).expect("gone");
        assert_eq!(gone.segments.len(), 1);
        assert!(SpeedBand::deleting(SpeedBandHit::Segment(0), &k, fd()).is_none());
    }

    #[test]
    fn line_points_follow_the_segments() {
        let k = keys(vec![seg(30, 100.0, None), seg(30, 100.0, Some(400.0))]);
        let pts = SpeedBand::line_points(&k, Time::ZERO, lane(), x);
        let area = SpeedBand::line_area(lane());
        assert_eq!(pts[0], Point::new(x(Time::ZERO), SpeedBand::y_for_speed(1.0, area)));
        let last = pts[pts.len() - 1];
        assert!((last.y - SpeedBand::y_for_speed(4.0, area)).abs() < 1e-9 && last.x == x(f(60)));
        assert!(pts.len() > 4);
    }
}

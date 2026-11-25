// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextAnimatorModel.swift (the saved type `TextAnimator` and its enums live in `sq-core-model`)
//
// Text animators: in/out animations that play per character, word or line with a stagger between the units.
//
// Timing is rational (`Time`) throughout: unit i of n starts at `rank(i) * stagger` (template-local) and plays for
// `duration`. Only the progress inside one unit's window becomes a f64 fraction (0...1), never a time. Pure model: timing,
// per-unit states and segmentation by UTF-16 line ranges. Layout and rasterizing stay with the text renderer.

use sq_core_model::anchored_animation::{
    AnimationAnchor, AnimationSet, KeyframeTemplate, SegmentShape, TextAnimator, TextAnimatorEffect, TextAnimatorOrder,
    TextAnimatorUnit, TextSlideDirection,
};
use sq_core_time::word_segmentation;
use sq_core_time::{Interpolation, Time};

/// Look of one unit at one time. At `REST` the unit is drawn exactly as the static text.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextUnitState {
    /// Opacity 0...1.
    pub opacity: f64,
    /// About the unit center.
    pub scale: f64,
    /// Sequence pixels, y down.
    pub offset_x: f64,
    /// Sequence pixels, y down.
    pub offset_y: f64,
    /// Blur radius in sequence pixels.
    pub blur: f64,
}

impl TextUnitState {
    /// Drawn as the static text.
    pub const REST: TextUnitState = TextUnitState { opacity: 1.0, scale: 1.0, offset_x: 0.0, offset_y: 0.0, blur: 0.0 };

    /// The unit is at rest.
    pub fn is_rest(&self) -> bool {
        *self == TextUnitState::REST
    }
}

/// a / b for b > 0 via exact i128 cross-multiplication (only the result is a f64).
fn ratio(a: Time, b: Time) -> f64 {
    let num = i128::from(a.value()) * i128::from(b.timescale());
    let den = i128::from(a.timescale()) * i128::from(b.value());
    num as f64 / den as f64
}

fn bezier(s: f64, a: f64, b: f64) -> f64 {
    let u = 1.0 - s;
    3.0 * u * u * s * a + 3.0 * u * s * s * b + s * s * s
}

/// Solves x(s) = t on the monotonic x curve by bisection (x1, x2 in 0...1).
fn solve(t: f64, x1: f64, x2: f64) -> f64 {
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..50 {
        let m = (lo + hi) / 2.0;
        if bezier(m, x1, x2) < t {
            lo = m;
        } else {
            hi = m;
        }
    }
    (lo + hi) / 2.0
}

/// Eased progress for linear progress `p` in 0...1, using the same handles as keyframe segments.
pub fn ease(p: f64, shape: SegmentShape) -> f64 {
    if p <= 0.0 {
        return 0.0;
    }
    if p >= 1.0 {
        return 1.0;
    }
    match shape.interpolation() {
        Interpolation::Linear => p,
        Interpolation::Hold => 0.0,
        Interpolation::HoldAhead => 1.0,
        Interpolation::Bezier => {
            let (out, inn) = shape.handles();
            let x1 = out.dx.clamp(0.0, 1.0);
            let x2 = 1.0 - inn.dx.clamp(0.0, 1.0);
            let s = solve(p, x1, x2);
            bezier(s, out.dy, 1.0 - inn.dy)
        }
    }
}

/// Timing and per-unit states of a `TextAnimator` (Swift `extension TextAnimator`).
pub trait TextAnimatorTimingExt {
    /// Position of unit `i` (0-based, reading order) in the play order.
    fn rank(&self, i: usize, n: usize) -> usize;
    /// Template-local start of unit `i`.
    fn start(&self, i: usize, n: usize) -> Time;
    /// From the first unit's start to the last unit's end; zero without units.
    fn total_duration(&self, n: usize) -> Time;
    /// Linear progress of unit `i` at template-local `t`: 0 before its start, 1 from its end on. Typewriter and a zero
    /// duration are a step at the start.
    fn progress(&self, i: usize, n: usize, t: Time) -> f64;
    /// State of unit `i` while it animates in (template-local time, 0 = clip start).
    fn in_state(&self, i: usize, n: usize, t: Time) -> TextUnitState;
    /// Clip time at which unit `i` starts leaving (the last one is gone exactly at the clip end).
    fn out_start(&self, i: usize, n: usize, clip_duration: Time) -> Time;
    /// State of unit `i` while it animates out; at the clip end every unit is gone.
    fn out_state(&self, i: usize, n: usize, clip_time: Time, clip_duration: Time) -> TextUnitState;
}

fn max_rank(a: &TextAnimator, n: usize) -> usize {
    if n == 0 {
        return 0;
    }
    if a.order == TextAnimatorOrder::Center { (n - 1) / 2 } else { n - 1 }
}

/// Typewriter ignores the duration: every unit is a step, so the out side ends exactly at the clip end.
fn effective_duration(a: &TextAnimator) -> Time {
    if a.effect == TextAnimatorEffect::Typewriter {
        return Time::ZERO;
    }
    let d = TextAnimator::sanitized(a.duration);
    if !a.effect.is_loop() || a.loops <= 1 {
        return d;
    }
    TextAnimator::sanitized(Time::new(d.value() * a.loops, d.timescale()))
}

/// `stagger * rank`, clamped instead of overflowing (stagger is at most 60 s on a <= 1 MHz grid).
fn staggered(a: &TextAnimator, rank: usize) -> Time {
    let s = TextAnimator::sanitized(a.stagger);
    let v = i128::from(s.value()) * rank as i128;
    // The cast is exact: the min keeps the value below i64::MAX / 4.
    Time::new(v.min(i128::from(i64::MAX / 4)) as i64, s.timescale())
}

/// Highest value of the `Overshoot` easing curve (handles 0.34/1.56 and 0.36/0.0).
const OVERSHOOT_CURVE_PEAK: f64 = 1.0978035;

/// Pop scale: the eased amount, with the part above 100 % stretched so the peak is `overshoot` (if set).
fn pop_scale(a: &TextAnimator, e: f64) -> f64 {
    match a.overshoot {
        Some(peak) if e > 1.0 => 1.0 + (e - 1.0) * (peak - 1.0) / (OVERSHOOT_CURVE_PEAK - 1.0),
        _ => e.max(0.0),
    }
}

/// `visible`: linear 0 (hidden) ... 1 (rest); `eased`: the eased amount (may overshoot past 1 or below 0).
fn state(a: &TextAnimator, v: f64, e: f64, leaving: bool) -> TextUnitState {
    let rest = TextUnitState::REST;
    if v >= 1.0 && e == 1.0 {
        return rest;
    }
    let clamped = e.clamp(0.0, 1.0);
    if a.effect.is_loop() {
        // Easing does not apply: a sine per cycle, 0 at both ends of every cycle.
        let phase = (if leaving { 1.0 - v } else { v }) * a.loops as f64;
        let wave = (std::f64::consts::PI * (phase - phase.floor())).sin();
        if a.effect == TextAnimatorEffect::Wave {
            return TextUnitState { offset_y: -a.distance * wave, ..rest };
        }
        return TextUnitState { scale: 1.0 + 0.25 * wave, ..rest };
    }
    match a.effect {
        TextAnimatorEffect::Fade | TextAnimatorEffect::Typewriter => TextUnitState { opacity: clamped, ..rest },
        TextAnimatorEffect::Pop => TextUnitState { opacity: (2.0 * v).clamp(0.0, 1.0), scale: pop_scale(a, e), ..rest },
        TextAnimatorEffect::Slide => {
            let d = (1.0 - e) * a.distance * if leaving { -1.0 } else { 1.0 };
            match a.direction {
                TextSlideDirection::Up => TextUnitState { opacity: clamped, offset_y: d, ..rest },
                TextSlideDirection::Down => TextUnitState { opacity: clamped, offset_y: -d, ..rest },
                TextSlideDirection::Left => TextUnitState { opacity: clamped, offset_x: d, ..rest },
                TextSlideDirection::Right => TextUnitState { opacity: clamped, offset_x: -d, ..rest },
            }
        }
        TextAnimatorEffect::Blur => TextUnitState { opacity: clamped, blur: (1.0 - clamped) * a.blur_radius, ..rest },
        TextAnimatorEffect::Wave | TextAnimatorEffect::Pulse => rest,
    }
}

impl TextAnimatorTimingExt for TextAnimator {
    fn rank(&self, i: usize, n: usize) -> usize {
        if n == 0 {
            return 0;
        }
        match self.order {
            TextAnimatorOrder::Forward => i,
            TextAnimatorOrder::Reverse => n - 1 - i,
            TextAnimatorOrder::Center => (2 * i as i64 - (n as i64 - 1)).unsigned_abs() as usize / 2,
        }
    }

    fn start(&self, i: usize, n: usize) -> Time {
        staggered(self, self.rank(i, n))
    }

    fn total_duration(&self, n: usize) -> Time {
        if n == 0 {
            return Time::ZERO;
        }
        staggered(self, max_rank(self, n)) + effective_duration(self)
    }

    fn progress(&self, i: usize, n: usize, t: Time) -> f64 {
        let s = self.start(i, n);
        if t < s {
            return 0.0;
        }
        let d = effective_duration(self);
        if d <= Time::ZERO || t >= s + d {
            return 1.0;
        }
        ratio(t - s, d)
    }

    fn in_state(&self, i: usize, n: usize, t: Time) -> TextUnitState {
        let p = self.progress(i, n, t);
        let eased = if self.effect == TextAnimatorEffect::Typewriter { p } else { ease(p, self.easing) };
        state(self, p, eased, false)
    }

    fn out_start(&self, i: usize, n: usize, clip_duration: Time) -> Time {
        clip_duration - self.total_duration(n) + self.start(i, n)
    }

    fn out_state(&self, i: usize, n: usize, clip_time: Time, clip_duration: Time) -> TextUnitState {
        let local = clip_time - (clip_duration - self.total_duration(n));
        let q = self.progress(i, n, local);
        let eased = 1.0 - if self.effect == TextAnimatorEffect::Typewriter { q } else { ease(q, self.easing) };
        state(self, 1.0 - q, eased, true)
    }
}

/// A UTF-16 range in a laid-out text (Swift `NSRange`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Utf16Range {
    /// First UTF-16 unit.
    pub location: usize,
    /// Number of UTF-16 units.
    pub length: usize,
}

/// One animatable character of a laid-out text.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TextUnitCharacter {
    /// Index among all characters (whitespace excluded), reading order.
    pub index: usize,
    /// Word it belongs to.
    pub word: usize,
    /// Line it belongs to.
    pub line: usize,
    /// UTF-16 range in the laid-out (display) text.
    pub range: Utf16Range,
}

/// The animatable units of a laid-out text: every non-whitespace grapheme with the word and line it belongs to.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct TextUnits {
    /// The characters, reading order.
    pub characters: Vec<TextUnitCharacter>,
    /// Number of words.
    pub word_count: usize,
    /// Number of lines.
    pub line_count: usize,
}

impl TextUnits {
    /// How many units of `unit` there are.
    pub fn count_of(&self, unit: TextAnimatorUnit) -> usize {
        match unit {
            TextAnimatorUnit::Character => self.characters.len(),
            TextAnimatorUnit::Word => self.word_count,
            TextAnimatorUnit::Line => self.line_count,
        }
    }

    /// The index of `c` among the units of `unit`.
    pub fn index_of(&self, c: &TextUnitCharacter, unit: TextAnimatorUnit) -> usize {
        match unit {
            TextAnimatorUnit::Character => c.index,
            TextAnimatorUnit::Word => c.word,
            TextAnimatorUnit::Line => c.line,
        }
    }

    /// `lines`: UTF-16 ranges of the laid-out lines in `text` (a character outside every line is dropped). Words follow
    /// `WordSegmentation` (whitespace and CJK characters separate); a word the wrap breaks keeps one index. Lines without a
    /// character still count.
    pub fn segment(text: &str, lines: &[Utf16Range]) -> TextUnits {
        let all: Vec<&str> = sq_core_time::text::graphemes(text).collect();
        let spans = word_segmentation::spans(&all);
        let mut word_of: Vec<Option<usize>> = vec![None; all.len()];
        for (w, span) in spans.iter().enumerate() {
            for i in span.clone() {
                word_of[i] = Some(w);
            }
        }
        let mut chars: Vec<TextUnitCharacter> = Vec::new();
        let mut offset = 0;
        for (i, ch) in all.iter().enumerate() {
            let len = ch.encode_utf16().count();
            let at = offset;
            offset += len;
            let Some(word) = word_of[i] else { continue };
            let Some(line) = lines.iter().position(|l| at >= l.location && at < l.location + l.length) else {
                continue;
            };
            chars.push(TextUnitCharacter {
                index: chars.len(),
                word,
                line,
                range: Utf16Range { location: at, length: len },
            });
        }
        TextUnits { characters: chars, word_count: spans.len(), line_count: lines.len() }
    }
}

/// Where a typewriter's cursor sits at one time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TypewriterCursorPlace {
    /// Index (`TextUnitCharacter::index`) of the last revealed character; the cursor sits right after it.
    pub after_character: usize,
    /// False in the off half of a blink.
    pub visible: bool,
}

impl TextUnits {
    /// The cursor of an in-animator typewriter at template-local time `t` (`None`: no cursor configured, nothing typed
    /// yet, or the cursor has been held long enough). Solid while units are still appearing, then it blinks (on first,
    /// `blink` per half) and goes `hold_after` after the last unit appeared. The last revealed character is the one latest in
    /// reading order, so the cursor sits there for every play order.
    pub fn typewriter_cursor(&self, a: &TextAnimator, t: Time) -> Option<TypewriterCursorPlace> {
        let cursor = a.cursor.as_ref().filter(|_| a.effect == TextAnimatorEffect::Typewriter)?;
        let n = self.count_of(a.unit);
        let after_character = self
            .characters
            .iter()
            .filter(|c| a.progress(self.index_of(c, a.unit), n, t) >= 1.0)
            .map(|c| c.index)
            .max()?;
        let typed_at = a.total_duration(n);
        if t < typed_at {
            return Some(TypewriterCursorPlace { after_character, visible: true });
        }
        let elapsed = t - typed_at;
        if elapsed >= cursor.hold_after {
            return None;
        }
        let (e, b) = (elapsed, cursor.blink);
        let halves = i128::from(e.value()) * i128::from(b.timescale()) / (i128::from(e.timescale()) * i128::from(b.value().max(1)));
        Some(TypewriterCursorPlace { after_character, visible: halves % 2 == 0 })
    }
}

/// One character's look: the in- and out-animator states of the units it belongs to (each about its own unit's center).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextCharacterState {
    /// The in-animator's state.
    pub in_state: TextUnitState,
    /// The out-animator's state.
    pub out_state: TextUnitState,
    /// Unit whose center the in-state scales about (`None` without an in-animator).
    pub in_unit: Option<TextAnimatorUnit>,
    /// Unit whose center the out-state scales about.
    pub out_unit: Option<TextAnimatorUnit>,
}

impl TextCharacterState {
    /// In and out opacity together.
    pub fn opacity(&self) -> f64 {
        self.in_state.opacity * self.out_state.opacity
    }

    /// Drawn as the static text.
    pub fn is_rest(&self) -> bool {
        self.in_state.is_rest() && self.out_state.is_rest()
    }
}

/// A template that carries only a text animator.
pub trait KeyframeTemplateTextExt {
    /// A template that only carries a text animator (no property tracks).
    fn with_text_animator(animator: TextAnimator, anchor: AnimationAnchor) -> KeyframeTemplate;
}

impl KeyframeTemplateTextExt for KeyframeTemplate {
    fn with_text_animator(animator: TextAnimator, anchor: AnimationAnchor) -> KeyframeTemplate {
        KeyframeTemplate {
            tracks: Vec::new(),
            duration: Time::ZERO,
            anchor,
            text_animator: Some(animator),
            loops: false,
        }
    }
}

/// Per-character states of an animation set.
pub trait AnimationSetTextExt {
    /// Either side has a text animator.
    fn has_text_animator(&self) -> bool;
    /// Per-character states at clip time `clip_time`; `None` when neither side has a text animator. In and out compose
    /// (opacities multiply, each scales about its own unit), so a clip shorter than both animations still ends hidden.
    fn character_states(
        &self,
        units: &TextUnits,
        clip_time: Time,
        clip_duration: Time,
    ) -> Option<Vec<TextCharacterState>>;
}

impl AnimationSetTextExt for AnimationSet {
    fn has_text_animator(&self) -> bool {
        self.animation_in.as_ref().is_some_and(|t| t.text_animator.is_some())
            || self.animation_out.as_ref().is_some_and(|t| t.text_animator.is_some())
    }

    fn character_states(
        &self,
        units: &TextUnits,
        clip_time: Time,
        clip_duration: Time,
    ) -> Option<Vec<TextCharacterState>> {
        let a = self.animation_in.as_ref().and_then(|t| t.text_animator.as_ref());
        let b = self.animation_out.as_ref().and_then(|t| t.text_animator.as_ref());
        if a.is_none() && b.is_none() {
            return None;
        }
        let n_in = a.map_or(0, |a| units.count_of(a.unit));
        let n_out = b.map_or(0, |b| units.count_of(b.unit));
        Some(
            units
                .characters
                .iter()
                .map(|c| TextCharacterState {
                    in_state: a.map_or(TextUnitState::REST, |a| a.in_state(units.index_of(c, a.unit), n_in, clip_time)),
                    out_state: b.map_or(TextUnitState::REST, |b| {
                        b.out_state(units.index_of(c, b.unit), n_out, clip_time, clip_duration)
                    }),
                    in_unit: a.map(|a| a.unit),
                    out_unit: b.map(|b| b.unit),
                })
                .collect(),
        )
    }
}

// Caption hand-over, animation part (Swift CaptionHandover.swift). `sq-core-audio` has the timing rule; the parts below need
// `TextUnits` and `TextAnimator` and therefore live here.

/// The entering caption's animator units, asked for only when its look has a text animator.
pub type TextUnitsProvider<'a> = &'a dyn Fn() -> Option<TextUnits>;

/// What one entering caption asks for at one frame: the clip time its look is evaluated at and how strongly the caption
/// before is drawn under it (0: not drawn).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HandoverDraw {
    /// The clip time the entering look is evaluated at.
    pub clip_time: Time,
    /// Opacity factor of the caption before, drawn under it.
    pub tail_opacity: f64,
}

/// Clip time from which an in-animation covers fully, and how much of the block it shows before.
pub trait AnimationSetEntranceExt {
    /// Clip time from which the in-animation covers fully whatever the text is (`entrance_coverage` is 1 from here on, without
    /// asking for units): the end of its block tracks, and of a text animator's first unit (the unit that starts at zero; the
    /// block is there as soon as one unit shows). Zero without an in-animation and for a loop. A caller on a hot path checks
    /// this first and skips the hand-over work for the rest of the caption.
    fn entrance_end(&self) -> Time;
    /// How much of the block its in-animation shows at `clip_time`, 0 (nothing) ... 1 (all of it): the in-animation's
    /// opacity, 0 while its scale is zero, and 0 while a text animator shows no unit yet. A loop, an out look and a set
    /// without an in-animation cover fully. Position, rotation and a partial scale do not count: the block is there.
    fn entrance_coverage(&self, clip_time: Time, units: TextUnitsProvider) -> f64;
}

impl AnimationSetEntranceExt for AnimationSet {
    fn entrance_end(&self) -> Time {
        let Some(a) = self.animation_in.as_ref().filter(|a| !a.loops) else { return Time::ZERO };
        let mut end = if a.tracks.is_empty() { Time::ZERO } else { a.duration.max(Time::ZERO) };
        if let Some(animator) = &a.text_animator {
            end = end.max(animator.duration);
        }
        end
    }

    fn entrance_coverage(&self, clip_time: Time, units: TextUnitsProvider) -> f64 {
        let Some(a) = self.animation_in.as_ref().filter(|a| !a.loops) else { return 1.0 };
        if clip_time >= self.entrance_end() {
            return 1.0;
        }
        let mut block = 1.0;
        if !a.tracks.is_empty() {
            let opacity = a.value_of("opacity", clip_time).unwrap_or(1.0).clamp(0.0, 1.0);
            block = if a.value_of("scale", clip_time).unwrap_or(1.0) > 0.0 { opacity } else { 0.0 };
        }
        let (true, Some(animator)) = (block > 0.0, a.text_animator.as_ref()) else { return block };
        let Some(u) = units() else { return block };
        let n = u.count_of(animator.unit);
        if n == 0 {
            return block;
        }
        for i in 0..n {
            let s = animator.in_state(i, n, clip_time);
            if s.opacity > 0.0 && s.scale > 0.0 {
                return block;
            }
        }
        0.0
    }
}

/// The animation rules of the caption hand-over (the timing rule is `sq_core_audio::CaptionHandover`).
pub trait CaptionHandoverAnimationExt {
    /// Most frames `entering_clip_time` steps into a hidden in-animation.
    const MAX_ENTERING_SHIFT_FRAMES: i64 = 3;

    /// Opacity factor of the tail (the caption before, drawn at its end state under the entering caption) while the entering
    /// caption is at `clip_time`: one minus what the entering caption's in-animation covers. Zero when the caption before has
    /// an out look (it is gone at its end) or the entering one covers fully.
    fn tail_opacity(
        previous: Option<&AnimationSet>,
        entering: Option<&AnimationSet>,
        clip_time: Time,
        units: TextUnitsProvider,
    ) -> f64;

    /// The clip time the entering caption is evaluated at. When the caption before ends in an out look (it is gone at its end,
    /// so nothing stays under the cut) and the entering caption's in-animation shows nothing on its first frame, that frame is
    /// evaluated one frame into the in-animation: the picture is never empty at a hand-over. Stored data and the out look
    /// stay as they are. Monitor and export burn-in both ask here.
    ///
    /// An in-animation that is still fully hidden one frame in (a delay, a slow ease) steps on to the first frame where the
    /// caption draws anything, at most `MAX_ENTERING_SHIFT_FRAMES` frames in. Every frame before that one is drawn at that
    /// time too (held until the natural time catches up), so no empty frame follows a drawn one. When no frame within the cap
    /// draws, only the first frame is shifted, by one frame. Callers ask for frames with
    /// `clip_time < frame_duration * MAX_ENTERING_SHIFT_FRAMES`.
    fn entering_clip_time(
        previous: Option<&AnimationSet>,
        entering: Option<&AnimationSet>,
        clip_time: Time,
        frame_duration: Time,
        units: TextUnitsProvider,
    ) -> Time;

    /// The whole per-frame hand-over request of a caption that follows `previous` closely (`Resolution::tail_duration` is
    /// set): `entering_clip_time`, then `tail_opacity` at that time while the in-animation still runs. The Program monitor and
    /// the export burn-in both call this one function, so they cannot ask for different frames. `natural_clip_time`: the
    /// playhead's time since the caption's start.
    fn draw(
        previous: Option<&AnimationSet>,
        entering: Option<&AnimationSet>,
        natural_clip_time: Time,
        frame_duration: Time,
        units: TextUnitsProvider,
    ) -> HandoverDraw;
}

impl CaptionHandoverAnimationExt for sq_core_audio::CaptionHandover {
    fn tail_opacity(
        previous: Option<&AnimationSet>,
        entering: Option<&AnimationSet>,
        clip_time: Time,
        units: TextUnitsProvider,
    ) -> f64 {
        let (None, Some(entering)) = (previous.and_then(|p| p.animation_out.as_ref()), entering) else { return 0.0 };
        1.0 - entering.entrance_coverage(clip_time, units)
    }

    fn entering_clip_time(
        previous: Option<&AnimationSet>,
        entering: Option<&AnimationSet>,
        clip_time: Time,
        frame_duration: Time,
        units: TextUnitsProvider,
    ) -> Time {
        let max = Self::MAX_ENTERING_SHIFT_FRAMES;
        let (Some(_), Some(entering)) = (previous.and_then(|p| p.animation_out.as_ref()), entering) else {
            return clip_time;
        };
        if frame_duration <= Time::ZERO || clip_time < Time::ZERO || clip_time >= frame_duration * max {
            return clip_time;
        }
        // Frame index of the natural time and the time of the caption's first frame on the same grid.
        let mut n: i64 = 0;
        while clip_time >= frame_duration * (n + 1) {
            n += 1;
        }
        let first = clip_time - frame_duration * n;
        if entering.entrance_coverage(first, units) != 0.0 {
            return clip_time;
        }
        for k in 1..=max {
            let t = first + frame_duration * k;
            if entering.entrance_coverage(t, units) > 0.0 {
                return if n < k { t } else { clip_time };
            }
        }
        if n == 0 { first + frame_duration } else { clip_time }
    }

    fn draw(
        previous: Option<&AnimationSet>,
        entering: Option<&AnimationSet>,
        natural_clip_time: Time,
        frame_duration: Time,
        units: TextUnitsProvider,
    ) -> HandoverDraw {
        let mut local = natural_clip_time;
        if natural_clip_time < frame_duration * Self::MAX_ENTERING_SHIFT_FRAMES {
            local = Self::entering_clip_time(previous, entering, natural_clip_time, frame_duration, units);
        }
        let Some(entering) = entering.filter(|e| local < e.entrance_end()) else {
            return HandoverDraw { clip_time: local, tail_opacity: 0.0 };
        };
        HandoverDraw { clip_time: local, tail_opacity: Self::tail_opacity(previous, Some(entering), local, units) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wave(loops: i64) -> TextAnimator {
        let mut a =
            TextAnimator::new(TextAnimatorEffect::Wave, TextAnimatorUnit::Character, Time::new(1, 1), Time::new(1, 10));
        a.distance = 20.0;
        a.loops = loops;
        a
    }

    #[test]
    fn loops_default_to_one_and_stay_out_of_old_files() {
        let a = TextAnimator::new(TextAnimatorEffect::Fade, TextAnimatorUnit::Word, Time::new(1, 2), Time::new(1, 10));
        assert_eq!(a.loops, 1);
        assert!(!serde_json::to_string(&a).unwrap().contains("loops"));
        let mut l = a.clone();
        l.loops = 3;
        let back: TextAnimator = serde_json::from_str(&serde_json::to_string(&l).unwrap()).unwrap();
        assert_eq!(back.loops, 3);
    }

    #[test]
    fn loops_stretch_the_unit_window() {
        assert_eq!(wave(3).total_duration(1), Time::new(3, 1));
        assert_eq!(wave(1).total_duration(1), Time::new(1, 1));
        // Loops only apply to loop effects.
        let mut fade = TextAnimator::new(TextAnimatorEffect::Fade, TextAnimatorUnit::Word, Time::new(1, 2), Time::ZERO);
        fade.loops = 4;
        assert_eq!(fade.total_duration(1), Time::new(1, 2));
    }

    #[test]
    fn wave_rests_at_cycle_ends_and_peaks_in_the_middle() {
        let a = wave(2);
        assert!(a.in_state(0, 1, Time::ZERO).is_rest());
        assert!(a.in_state(0, 1, Time::new(1, 1)).is_rest());
        assert!(a.in_state(0, 1, Time::new(2, 1)).is_rest());
        assert!((a.in_state(0, 1, Time::new(1, 2)).offset_y + 20.0).abs() < 1e-9);
        assert!((a.in_state(0, 1, Time::new(3, 2)).offset_y + 20.0).abs() < 1e-9);
    }

    #[test]
    fn pulse_scales_and_stagger_delays_units() {
        let a =
            TextAnimator::new(TextAnimatorEffect::Pulse, TextAnimatorUnit::Character, Time::new(1, 1), Time::new(1, 4));
        assert!(a.in_state(0, 2, Time::new(1, 2)).scale > 1.1);
        assert!(a.in_state(1, 2, Time::new(1, 8)).is_rest());
    }

    fn pop_peak(a: &TextAnimator) -> f64 {
        (0..=1000).map(|i| a.in_state(0, 1, Time::new(i, 1000)).scale).fold(0.0, f64::max)
    }

    #[test]
    fn pop_overshoot_sets_the_peak_and_default_keeps_the_curve() {
        let mut a = TextAnimator::starting(TextAnimatorEffect::Pop);
        a.duration = Time::new(1, 1);
        assert!((pop_peak(&a) - 1.0978).abs() < 0.002, "default look {}", pop_peak(&a));
        a.overshoot = Some(1.08);
        assert!((pop_peak(&a) - 1.08).abs() < 0.002, "peak {}", pop_peak(&a));
        a.overshoot = Some(1.3);
        assert!((pop_peak(&a) - 1.3).abs() < 0.003, "peak {}", pop_peak(&a));
        assert!(a.in_state(0, 1, Time::new(1, 1)).is_rest());
        assert!(a.in_state(0, 1, Time::ZERO).scale.abs() < 1e-9);
    }

    #[test]
    fn rank_follows_the_order() {
        let mut a =
            TextAnimator::new(TextAnimatorEffect::Fade, TextAnimatorUnit::Character, Time::new(1, 2), Time::new(1, 10));
        let ranks = |a: &TextAnimator| (0..5).map(|i| a.rank(i, 5)).collect::<Vec<_>>();
        assert_eq!(ranks(&a), vec![0, 1, 2, 3, 4]);
        a.order = TextAnimatorOrder::Reverse;
        assert_eq!(ranks(&a), vec![4, 3, 2, 1, 0]);
        a.order = TextAnimatorOrder::Center;
        assert_eq!(ranks(&a), vec![2, 1, 0, 1, 2]);
        assert_eq!(a.total_duration(5), Time::new(2, 10) + Time::new(1, 2));
        assert_eq!(a.total_duration(0), Time::ZERO);
    }

    #[test]
    fn fade_in_and_out_meet_the_clip_ends() {
        let a = TextAnimator::new(TextAnimatorEffect::Fade, TextAnimatorUnit::Word, Time::new(1, 1), Time::ZERO);
        assert_eq!(a.in_state(0, 1, Time::ZERO).opacity, 0.0);
        assert!(a.in_state(0, 1, Time::new(1, 1)).is_rest());
        let d = Time::new(4, 1);
        assert!(a.out_state(0, 1, Time::new(3, 1), d).is_rest());
        assert_eq!(a.out_state(0, 1, d, d).opacity, 0.0);
        assert_eq!(a.out_start(0, 1, d), Time::new(3, 1));
    }

    #[test]
    fn text_units_follow_the_same_words() {
        let u = TextUnits::segment("你好 ab", &[Utf16Range { location: 0, length: 5 }]);
        assert_eq!(u.word_count, 3);
        assert_eq!(u.characters.iter().map(|c| c.word).collect::<Vec<_>>(), vec![0, 1, 2, 2]);
        assert_eq!(u.count_of(TextAnimatorUnit::Line), 1);
    }

    #[test]
    fn animation_set_composes_in_and_out_states() {
        let fade =
            TextAnimator::new(TextAnimatorEffect::Fade, TextAnimatorUnit::Character, Time::new(1, 1), Time::ZERO);
        let tin = KeyframeTemplate::with_text_animator(fade.clone(), AnimationAnchor::Start);
        let tout = KeyframeTemplate::with_text_animator(fade, AnimationAnchor::End);
        let set = AnimationSet::new(Some(tin), Some(tout));
        assert!(set.has_text_animator());
        let units = TextUnits::segment("ab", &[Utf16Range { location: 0, length: 2 }]);
        let d = Time::new(1, 1); // shorter than both animations together: ends hidden
        let s = set.character_states(&units, d, d).unwrap();
        assert_eq!(s.len(), 2);
        assert!(s[0].opacity() == 0.0 && !s[0].is_rest());
        assert!(AnimationSet::new(None, None).character_states(&units, d, d).is_none());
    }

    // Caption hand-over (CaptionHandoverTests)

    use sq_core_audio::CaptionHandover as H;
    use sq_core_model::anchored_animation::AnimationTrack;

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn tpl(property: &str, keys: &[(Time, f64)], duration: Time) -> KeyframeTemplate {
        let keys: Vec<(Time, f64, SegmentShape)> = keys.iter().map(|(t, v)| (*t, *v, SegmentShape::Linear)).collect();
        KeyframeTemplate {
            tracks: vec![AnimationTrack::from_shapes(property, &keys)],
            duration,
            anchor: AnimationAnchor::Start,
            text_animator: None,
            loops: false,
        }
    }

    fn fade_in() -> KeyframeTemplate {
        tpl("opacity", &[(Time::ZERO, 0.0), (Time::new(1, 5), 1.0)], Time::new(1, 5))
    }

    fn as_out(mut t: KeyframeTemplate) -> KeyframeTemplate {
        t.anchor = AnimationAnchor::End;
        t
    }

    fn set(t: &KeyframeTemplate) -> AnimationSet {
        AnimationSet::single(Some(t)).unwrap()
    }

    fn no_units() -> Option<TextUnits> {
        None
    }

    fn in_hidden_until(h: Time) -> AnimationSet {
        let end = h + Time::new(1, 5);
        set(&tpl("opacity", &[(Time::ZERO, 0.0), (h, 0.0), (end, 1.0)], end))
    }

    fn out_set() -> AnimationSet {
        set(&as_out(tpl("opacity", &[(Time::ZERO, 1.0), (Time::new(1, 5), 0.0)], Time::new(1, 5))))
    }

    #[test]
    fn entrance_coverage_follows_the_in_animation() {
        let fade = fade_in();
        let s = set(&fade);
        assert_eq!(s.entrance_coverage(Time::ZERO, &no_units), 0.0);
        assert!((s.entrance_coverage(Time::new(1, 10), &no_units) - 0.5).abs() < 1e-9);
        assert_eq!(s.entrance_coverage(Time::new(1, 1), &no_units), 1.0);
        // Scale from zero: nothing on the first frame, all of it as soon as it has a size.
        let pop = tpl("scale", &[(Time::ZERO, 0.0), (fd() * 4, 1.2)], fd() * 4);
        let ps = set(&pop);
        assert_eq!(ps.entrance_coverage(Time::ZERO, &no_units), 0.0);
        assert_eq!(ps.entrance_coverage(fd(), &no_units), 1.0);
        // An out look, a loop and a start that is not hidden cover from the first frame.
        assert_eq!(set(&as_out(fade.clone())).entrance_coverage(Time::ZERO, &no_units), 1.0);
        let mut looped = fade;
        looped.loops = true;
        assert_eq!(set(&looped).entrance_coverage(Time::ZERO, &no_units), 1.0);
        let slide = tpl("positionY", &[(Time::ZERO, 80.0), (fd() * 6, 0.0)], fd() * 6);
        assert_eq!(set(&slide).entrance_coverage(Time::ZERO, &no_units), 1.0);
    }

    #[test]
    fn entering_clip_time_steps_to_the_first_visible_frame_within_three() {
        let prev = out_set();
        let shifted = |e: &AnimationSet, from: Time| H::entering_clip_time(Some(&prev), Some(e), from, fd(), &no_units);
        let z = Time::ZERO;
        assert_eq!(shifted(&in_hidden_until(Time::new(1, 100)), z), fd()); // visible one frame in
        assert_eq!(shifted(&in_hidden_until(fd()), z), fd() * 2); // zero at one frame, visible at two
        assert_eq!(shifted(&in_hidden_until(fd() * 2), z), fd() * 3);
        assert_eq!(shifted(&in_hidden_until(fd() * 3), z), fd()); // zero through three frames: keep one
        assert_eq!(shifted(&in_hidden_until(fd() * 30), z), fd());
        // Frames still hidden before the first visible one are held there; a visible frame is untouched.
        assert_eq!(shifted(&in_hidden_until(fd() * 2), fd()), fd() * 3);
        assert_eq!(shifted(&in_hidden_until(fd() * 2), fd() * 2), fd() * 3);
        assert_eq!(shifted(&in_hidden_until(fd() * 2), fd() * 3), fd() * 3);
        assert_eq!(shifted(&in_hidden_until(fd() * 3), fd()), fd()); // beyond the cap: frame 0 only
        assert_eq!(shifted(&in_hidden_until(fd() * 3), fd() * 2), fd() * 2);
        // Not a hand-over, or visible from the start: untouched.
        assert_eq!(H::entering_clip_time(None, Some(&in_hidden_until(fd())), z, fd(), &no_units), z);
        let shown = tpl("opacity", &[(Time::ZERO, 0.5), (Time::new(1, 5), 1.0)], Time::new(1, 5));
        assert_eq!(shifted(&set(&shown), z), z);
    }

    #[test]
    fn draw_is_the_shifted_time_and_the_tail_opacity() {
        let in_set = set(&fade_in());
        let out = out_set();
        // After an out look the first frame steps one frame in; the old caption is gone (opacity factor 0).
        let a = H::draw(Some(&out), Some(&in_set), Time::ZERO, fd(), &no_units);
        assert_eq!(a, HandoverDraw { clip_time: fd(), tail_opacity: 0.0 });
        // After a caption without an out look the time is natural and the tail fills what the fade has not covered.
        // An empty template is no set at all (Swift: nil), so there is no previous look.
        let still =
            AnimationSet::single(Some(&KeyframeTemplate { tracks: Vec::new(), duration: Time::ZERO, ..fade_in() }));
        assert!(still.is_none());
        let b = H::draw(still.as_ref(), Some(&in_set), fd() * 2, fd(), &no_units);
        assert_eq!(b.clip_time, fd() * 2);
        assert_eq!(b.tail_opacity, H::tail_opacity(still.as_ref(), Some(&in_set), fd() * 2, &no_units));
        assert!(b.tail_opacity > 0.0 && b.tail_opacity < 1.0);
        // Past the in-animation: no tail.
        let c = H::draw(still.as_ref(), Some(&in_set), Time::new(1, 2), fd(), &no_units);
        assert_eq!(c, HandoverDraw { clip_time: Time::new(1, 2), tail_opacity: 0.0 });
        // Hidden past the cap (4 frames): only frame 0 shifts by one frame, the rest keeps its natural time.
        let late = in_hidden_until(fd() * 4);
        for n in 0..4_i64 {
            let d = H::draw(Some(&out), Some(&late), fd() * n, fd(), &no_units);
            assert_eq!(d.clip_time, if n == 0 { fd() } else { fd() * n });
        }
    }

    /// Frame by frame (off the grid too): no hidden frame after a visible one, and none at all up to a delay of two frames.
    #[test]
    fn handover_frames_never_flash_after_a_delayed_in_look() {
        let prev = out_set();
        for delay in 0..=3_i64 {
            let hidden = fd() * delay;
            let end = hidden + Time::new(1, 5);
            let t = tpl("opacity", &[(Time::ZERO, 0.0), (hidden + Time::new(1, 1000), 0.0), (end, 1.0)], end);
            let s = set(&t);
            for offset in [Time::ZERO, Time::new(1, 90)] {
                let mut seen = false;
                for n in 0..10_i64 {
                    let natural = offset + fd() * n;
                    let at = H::entering_clip_time(Some(&prev), Some(&s), natural, fd(), &no_units);
                    let c = s.entrance_coverage(at, &no_units);
                    assert!(!seen || c > 0.0, "delay {delay} offset {offset:?} frame {n}: flash");
                    if c > 0.0 {
                        seen = true;
                    }
                    assert!(delay > 2 || c > 0.0, "delay {delay} offset {offset:?} frame {n}: empty");
                }
                assert!(seen);
            }
        }
    }

    #[test]
    fn a_typewriter_cursor_follows_the_last_character_and_blinks_after_typing() {
        use sq_core_model::anchored_animation::TextCursor;
        let units = TextUnits::segment("abc d", &[Utf16Range { location: 0, length: 5 }]);
        let mut a = TextAnimator::new(TextAnimatorEffect::Typewriter, TextAnimatorUnit::Character, Time::ZERO, Time::new(1, 10));
        let ms = |v: i64| Time::new(v, 1000);
        assert_eq!(units.typewriter_cursor(&a, ms(0)), None, "no cursor configured");
        a.cursor = Some(TextCursor::standard());
        let at = |t| units.typewriter_cursor(&a, t);
        // Characters appear at 0, 100, 200, 300 ms: the cursor is solid and after the newest one.
        assert_eq!(at(ms(0)), Some(TypewriterCursorPlace { after_character: 0, visible: true }));
        assert_eq!(at(ms(250)), Some(TypewriterCursorPlace { after_character: 2, visible: true }));
        assert_eq!(at(ms(299)), Some(TypewriterCursorPlace { after_character: 2, visible: true }));
        // Typing ends at 300 ms: on for 530 ms, off until the hold of 600 ms ends it.
        assert_eq!(at(ms(300)), Some(TypewriterCursorPlace { after_character: 3, visible: true }));
        assert_eq!(at(ms(829)).map(|p| p.visible), Some(true));
        assert_eq!(at(ms(830)), Some(TypewriterCursorPlace { after_character: 3, visible: false }));
        assert_eq!(at(ms(899)).map(|p| p.visible), Some(false));
        assert_eq!(at(ms(900)), None, "held 600 ms after the last character");
        // By word the cursor jumps to the end of the revealed word.
        a.unit = TextAnimatorUnit::Word;
        let by_word = |t| units.typewriter_cursor(&a, t).map(|p| p.after_character);
        assert_eq!(by_word(ms(0)), Some(2));
        assert_eq!(by_word(ms(100)), Some(3));
    }

    #[test]
    fn entrance_coverage_of_a_text_animator_is_all_or_nothing() {
        let units = TextUnits::segment("one two", &[Utf16Range { location: 0, length: 7 }]);
        assert_eq!(units.word_count, 2);
        let provider = || Some(units.clone());
        let cover = |effect, duration: Time, t: Time| {
            let anim = TextAnimator::new(effect, TextAnimatorUnit::Word, duration, Time::new(1, 10));
            set(&KeyframeTemplate::with_text_animator(anim, AnimationAnchor::Start)).entrance_coverage(t, &provider)
        };
        let d = Time::new(3, 10);
        for effect in
            [TextAnimatorEffect::Fade, TextAnimatorEffect::Pop, TextAnimatorEffect::Slide, TextAnimatorEffect::Blur]
        {
            assert_eq!(cover(effect, d, Time::ZERO), 0.0, "{effect:?}");
            assert_eq!(cover(effect, d, fd()), 1.0, "{effect:?}"); // the first word shows: the block is there
            assert_eq!(cover(effect, d, Time::new(2, 1)), 1.0, "{effect:?}");
        }
        // A typewriter without a fade shows its first unit on the first frame.
        assert_eq!(cover(TextAnimatorEffect::Typewriter, Time::ZERO, Time::ZERO), 1.0);
        // Without units (no layout yet) only the block counts.
        let anim = TextAnimator::new(TextAnimatorEffect::Fade, TextAnimatorUnit::Word, d, Time::new(1, 10));
        let s = set(&KeyframeTemplate::with_text_animator(anim, AnimationAnchor::Start));
        assert_eq!(s.entrance_coverage(Time::ZERO, &no_units), 1.0);
    }

    #[test]
    fn tail_opacity_is_what_the_entering_caption_leaves_uncovered() {
        let in_set = set(&fade_in());
        let out = out_set();
        let tail = |p: Option<&AnimationSet>, e: Option<&AnimationSet>, t| H::tail_opacity(p, e, t, &no_units);
        assert_eq!(tail(Some(&in_set), Some(&in_set), Time::ZERO), 1.0);
        assert!((tail(None, Some(&in_set), Time::new(1, 20)) - 0.75).abs() < 1e-9);
        assert_eq!(tail(Some(&in_set), Some(&in_set), Time::new(1, 5)), 0.0);
        assert_eq!(tail(Some(&out), Some(&in_set), Time::ZERO), 0.0); // gone at its end
        assert_eq!(tail(Some(&in_set), Some(&out), Time::ZERO), 0.0);
        assert_eq!(tail(Some(&in_set), None, Time::ZERO), 0.0);
    }

    #[test]
    fn entrance_end_needs_no_units() {
        let fade = fade_in();
        assert_eq!(set(&fade).entrance_end(), Time::new(1, 5));
        assert_eq!(set(&as_out(fade.clone())).entrance_end(), Time::ZERO);
        let mut looped = fade;
        looped.loops = true;
        assert_eq!(set(&looped).entrance_end(), Time::ZERO);
        // A text animator: over once its first unit is in, however many units follow; from then on nobody asks for units.
        let anim =
            TextAnimator::new(TextAnimatorEffect::Fade, TextAnimatorUnit::Word, Time::new(3, 10), Time::new(1, 10));
        let anim_set = set(&KeyframeTemplate::with_text_animator(anim, AnimationAnchor::Start));
        assert_eq!(anim_set.entrance_end(), Time::new(3, 10));
        let asked = std::cell::Cell::new(0);
        let units = TextUnits::segment("one two three", &[Utf16Range { location: 0, length: 13 }]);
        let provider = || {
            asked.set(asked.get() + 1);
            Some(units.clone())
        };
        assert_eq!(anim_set.entrance_coverage(Time::new(3, 10), &provider), 1.0);
        assert_eq!(anim_set.entrance_coverage(Time::new(2, 1), &provider), 1.0);
        assert_eq!(asked.get(), 0);
        assert_eq!(anim_set.entrance_coverage(Time::ZERO, &provider), 0.0);
        assert_eq!(asked.get(), 1);
        assert_eq!(H::tail_opacity(None, Some(&anim_set), Time::new(1, 1), &provider), 0.0);
        assert_eq!(asked.get(), 1);
    }
}

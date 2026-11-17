//! Speed text for the timeline badge and the logic of the Speed/Duration dialog (Cmd+R) without any view.
//!
//! Speed and duration are two views of one number while `is_linked` is on: typing one recomputes the other (the clip's
//! source range stays). With the link off, a typed speed keeps the clip's length and changes how much media it shows
//! (`SpeedChange::holding_duration`). Typing a duration always changes the speed. A negative speed means Reverse Speed.
//! Several clips: the speed applies to each; the duration field is disabled.

use sq_core_edit::timeline_speed::SpeedChange;
use sq_core_model::{Clip, ClipSpeed, TimeInterpolation};
use sq_core_time::Time;

/// Text for a clip's speed ("200%", "33.33%", "-100%" reversed) and the name suffix built from it.
pub enum SpeedLabel {}

impl SpeedLabel {
    /// At most two decimals, trailing zeros dropped; "-" in front when reversed.
    // Swift: SpeedDialogModel.swift:7
    pub fn text(speed: ClipSpeed, reversed: bool) -> String {
        let mut s = format!("{:.2}", speed.percent());
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
        format!("{}{s}%", if reversed { "-" } else { "" })
    }

    /// " [200%]" appended to the clip name; empty for a clip at 100 % that is not reversed.
    // Swift: SpeedDialogModel.swift:15
    pub fn name_suffix(clip: &Clip) -> String {
        if clip.speed_keys.is_some() {
            return " [Speed Ramp]".to_string();
        }
        if clip.speed.is_normal() && !clip.reversed {
            return String::new();
        }
        format!(" [{}]", Self::text(clip.speed, clip.reversed))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Edited {
    None,
    Speed,
    Duration,
}

/// Logic of the Speed/Duration dialog (Clip > Speed/Duration).
// Swift: SpeedDialogModel.swift:28
#[derive(Clone, Debug, PartialEq)]
pub struct SpeedDialogModel {
    // Swift: SpeedDialogModel.swift:29
    pub(crate) frame_duration: Time,
    /// Source duration of the first clip: the duration at 100 % speed.
    // Swift: SpeedDialogModel.swift:31
    pub(crate) source_duration: Time,
    // Swift: SpeedDialogModel.swift:32
    pub(crate) clip_count: usize,
    // Swift: SpeedDialogModel.swift:33
    pub(crate) has_audio: bool,
    pub(crate) percent: f64,
    pub(crate) duration: Time,
    // Swift: SpeedDialogModel.swift:36
    pub is_linked: bool,
    // Swift: SpeedDialogModel.swift:37
    pub reversed: bool,
    // Swift: SpeedDialogModel.swift:38
    pub keeps_pitch: bool,
    /// Time Interpolation (video clips only; the picker is hidden for audio).
    // Swift: SpeedDialogModel.swift:40
    pub time_interpolation: TimeInterpolation,
    // Swift: SpeedDialogModel.swift:41
    pub(crate) has_video: bool,
    // Swift: SpeedDialogModel.swift:42
    pub ripple: bool,
    edited: Edited,
    original_speed: ClipSpeed,
    original_duration: Time,
    original_reversed: bool,
    original_keeps_pitch: bool,
    original_interpolation: TimeInterpolation,
}

impl SpeedDialogModel {
    /// Allowed percent range of the speed field.
    // Swift: SpeedDialogModel.swift:71
    pub const PERCENT_RANGE: std::ops::RangeInclusive<f64> = 1.0..=10_000.0;

    /// `clips` = the selected retimable clips (at least one; an empty slice gives `None`).
    // Swift: SpeedDialogModel.swift:52
    pub fn new(clips: &[Clip], frame_duration: Time) -> Option<SpeedDialogModel> {
        let first = clips.first()?;
        let avg = first.average_speed();
        Some(SpeedDialogModel {
            frame_duration,
            source_duration: first.retime_span(),
            clip_count: clips.len(),
            has_audio: clips.iter().any(|c| c.kind == sq_core_model::TrackKind::Audio),
            percent: avg.percent(),
            duration: first.duration(),
            is_linked: true,
            reversed: first.reversed,
            keeps_pitch: first.keeps_pitch,
            time_interpolation: first.time_interpolation,
            has_video: clips.iter().any(|c| c.kind == sq_core_model::TrackKind::Video),
            ripple: false,
            edited: Edited::None,
            original_speed: avg,
            original_duration: first.duration(),
            original_reversed: first.reversed,
            original_keeps_pitch: first.keeps_pitch,
            original_interpolation: first.time_interpolation,
        })
    }

    pub fn frame_duration(&self) -> Time {
        self.frame_duration
    }
    pub fn source_duration(&self) -> Time {
        self.source_duration
    }
    pub fn clip_count(&self) -> usize {
        self.clip_count
    }
    pub fn has_audio(&self) -> bool {
        self.has_audio
    }
    pub fn has_video(&self) -> bool {
        self.has_video
    }
    pub fn percent(&self) -> f64 {
        self.percent
    }
    pub fn duration(&self) -> Time {
        self.duration
    }

    // Swift: SpeedDialogModel.swift:69
    pub fn can_edit_duration(&self) -> bool {
        self.clip_count == 1
    }

    // Swift: SpeedDialogModel.swift:72
    pub fn speed(&self) -> ClipSpeed {
        ClipSpeed::from_percent(self.percent)
    }

    /// Speed typed in the field (percent; negative = reverse).
    // Swift: SpeedDialogModel.swift:76
    pub fn set_percent(&mut self, typed: f64) {
        if !typed.is_finite() || typed == 0.0 {
            return;
        }
        if typed < 0.0 {
            self.reversed = true;
        }
        self.percent = typed.abs().clamp(*Self::PERCENT_RANGE.start(), *Self::PERCENT_RANGE.end());
        // typing the current value is no change
        self.edited = if self.speed() == self.original_speed { Edited::None } else { Edited::Speed };
        if self.is_linked || !self.can_edit_duration() {
            self.duration = frames(self.speed().unscale(self.source_duration), self.frame_duration);
        }
    }

    /// Duration typed in the field (any time; snapped to frames, at least one frame). The speed follows, clamped.
    // Swift: SpeedDialogModel.swift:85
    pub fn set_duration(&mut self, typed: Time) {
        if !self.can_edit_duration() {
            return;
        }
        let d = typed.snapped(self.frame_duration).max(self.frame_duration);
        let s =
            ClipSpeed::new(self.source_duration.value() * d.timescale(), self.source_duration.timescale() * d.value());
        self.percent = s.percent();
        self.duration = frames(s.unscale(self.source_duration), self.frame_duration);
        self.edited = if self.duration == self.original_duration { Edited::None } else { Edited::Duration };
    }

    /// True when OK would change something.
    // Swift: SpeedDialogModel.swift:97
    pub fn has_changes(&self) -> bool {
        self.edited != Edited::None
            || self.reversed != self.original_reversed
            || self.keeps_pitch != self.original_keeps_pitch
            || self.time_interpolation != self.original_interpolation
    }

    /// The edit to apply to every selected clip.
    // Swift: SpeedDialogModel.swift:102
    pub fn change(&self) -> SpeedChange {
        let base = SpeedChange {
            reversed: Some(self.reversed),
            keeps_pitch: Some(self.keeps_pitch),
            ripple: self.ripple,
            time_interpolation: (self.time_interpolation != self.original_interpolation)
                .then_some(self.time_interpolation),
            ..SpeedChange::default()
        };
        match self.edited {
            Edited::Duration => SpeedChange { duration: Some(self.duration), ..base },
            Edited::Speed => SpeedChange {
                speed: Some(self.speed()),
                holding_duration: !self.is_linked && self.can_edit_duration(),
                ..base
            },
            Edited::None => SpeedChange { speed: Some(self.original_speed), ..base },
        }
    }
}

fn frames(t: Time, fd: Time) -> Time {
    t.snapped(fd).max(fd)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::TrackKind;
    use sq_core_time::{Id, TimeRange};

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn clip(kind: TrackKind, frames: i64) -> Clip {
        Clip::new(Id::from_u128(1), "c", Id::from_u128(2), kind, TimeRange::new(Time::ZERO, fd() * frames), Time::ZERO)
    }

    #[test]
    fn label_drops_trailing_zeros_and_marks_reverse() {
        assert_eq!(SpeedLabel::text(ClipSpeed::from_percent(200.0), false), "200%");
        assert_eq!(SpeedLabel::text(ClipSpeed::new(1, 3), false), "33.33%");
        assert_eq!(SpeedLabel::text(ClipSpeed::NORMAL, true), "-100%");
    }

    #[test]
    fn name_suffix_is_empty_at_normal_speed() {
        let mut c = clip(TrackKind::Video, 30);
        assert_eq!(SpeedLabel::name_suffix(&c), "");
        c.speed = ClipSpeed::from_percent(50.0);
        assert_eq!(SpeedLabel::name_suffix(&c), " [50%]");
        c.speed = ClipSpeed::NORMAL;
        c.reversed = true;
        assert_eq!(SpeedLabel::name_suffix(&c), " [-100%]");
    }

    #[test]
    fn typing_a_speed_recomputes_the_duration_while_linked() {
        let mut m = SpeedDialogModel::new(&[clip(TrackKind::Video, 60)], fd()).unwrap_or_else(|| panic!("model"));
        assert!(!m.has_changes() && m.can_edit_duration());
        m.set_percent(200.0);
        assert_eq!((m.duration(), m.speed()), (fd() * 30, ClipSpeed::from_percent(200.0)));
        let c = m.change();
        assert_eq!((c.speed, c.duration, c.holding_duration), (Some(ClipSpeed::from_percent(200.0)), None, false));
        m.set_percent(100.0); // typing the current value is no change
        assert!(!m.has_changes());
    }

    #[test]
    fn unlinked_speed_holds_the_duration_and_a_duration_changes_the_speed() {
        let mut m = SpeedDialogModel::new(&[clip(TrackKind::Video, 60)], fd()).unwrap_or_else(|| panic!("model"));
        m.is_linked = false;
        m.set_percent(50.0);
        assert_eq!(m.duration(), fd() * 60);
        assert!(m.change().holding_duration);
        m.set_duration(fd() * 30);
        assert_eq!(m.percent(), 200.0);
        assert_eq!(m.change().duration, Some(fd() * 30));
    }

    #[test]
    fn negative_percent_reverses_and_several_clips_disable_the_duration() {
        let a = clip(TrackKind::Video, 60);
        let mut b = clip(TrackKind::Audio, 60);
        b.id = Id::from_u128(3);
        let mut m = SpeedDialogModel::new(&[a, b], fd()).unwrap_or_else(|| panic!("model"));
        assert!(!m.can_edit_duration() && m.has_audio() && m.has_video());
        m.set_percent(-50.0);
        assert!(m.reversed && m.has_changes());
        m.set_duration(fd() * 10);
        assert_eq!(m.percent(), 50.0);
        m.set_percent(f64::NAN);
        assert_eq!(m.percent(), 50.0);
        assert!(SpeedDialogModel::new(&[], fd()).is_none());
    }
}

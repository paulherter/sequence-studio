//! How a Fast Cut replace fits the new media into the replaced main-track clip.
// Swift: Timeline+ReplaceModes.swift

use crate::timeline_magnetic_ops::MagneticOpsExt as _;
use serde::{Deserialize, Serialize};
use sq_core_model::{Clip, ClipSpeed, EditError, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};

/// How a Fast Cut replace fits the new media into the replaced main-track clip (docs/NEXT F2). All four keep the
/// replaced clip's length and its id, so nothing ripples and attached clips stay attached.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReplaceMode {
    /// The source frame `sourceAnchor` lands on the timeline playhead.
    AtPlayhead,
    /// The source In point fills the clip from its start.
    FromStart,
    /// The source Out point fills the clip up to its end.
    FromEnd,
    /// The whole source range is sped up or slowed down to the clip's length.
    WithRetime,
}

impl ReplaceMode {
    /// The Swift raw value (the camelCase case name).
    pub fn raw_value(self) -> &'static str {
        match self {
            ReplaceMode::AtPlayhead => "atPlayhead",
            ReplaceMode::FromStart => "fromStart",
            ReplaceMode::FromEnd => "fromEnd",
            ReplaceMode::WithRetime => "withRetime",
        }
    }

    /// All four modes in declaration order.
    pub const ALL: [ReplaceMode; 4] =
        [ReplaceMode::AtPlayhead, ReplaceMode::FromStart, ReplaceMode::FromEnd, ReplaceMode::WithRetime];

    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            ReplaceMode::AtPlayhead => "Replace at Playhead",
            ReplaceMode::FromStart => "Replace from Start",
            ReplaceMode::FromEnd => "Replace from End",
            ReplaceMode::WithRetime => "Replace with Retime",
        }
    }
}

/// What a replace did that the user should hear about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReplaceOutcome {
    /// How much shorter than the replaced clip the new media came out (zero = it filled the clip). The clip keeps
    /// the shorter length then.
    pub short_by: Time,
}

impl ReplaceOutcome {
    /// The new media was shorter than the clip.
    pub fn is_short(&self) -> bool {
        self.short_by > Time::ZERO
    }

    /// Text to show the user, if any.
    pub fn warning(&self) -> Option<&'static str> {
        self.is_short().then_some("The new media is shorter than the clip it replaces; the clip got shorter.")
    }
}

/// `extension Timeline` of `Timeline+ReplaceModes.swift`.
pub trait TimelineReplaceModesExt {
    /// Replace on the main track in one of the four `ReplaceMode`s. `playhead` and `source_anchor` (the media time that sits
    /// on the playhead) matter for `AtPlayhead` only. Short media is not an error: the result is cropped to what exists
    /// and the outcome says by how much.
    fn replace_on_main_track_mode(
        &mut self,
        id: Id,
        clips: &[Clip],
        mode: ReplaceMode,
        playhead: Time,
        source_anchor: Time,
        ids: &mut dyn IdSource,
    ) -> Result<ReplaceOutcome, EditError>;
}

impl TimelineReplaceModesExt for Timeline {
    fn replace_on_main_track_mode(
        &mut self,
        id: Id,
        clips: &[Clip],
        mode: ReplaceMode,
        playhead: Time,
        source_anchor: Time,
        ids: &mut dyn IdSource,
    ) -> Result<ReplaceOutcome, EditError> {
        let old =
            self.find(id).map(|m| m.clip).filter(|c| c.kind == TrackKind::Video).ok_or(EditError::ClipNotFound)?;
        let v = clips.iter().find(|c| c.kind == TrackKind::Video).ok_or(EditError::WrongTrackKind)?;
        let target = old.timeline().duration;
        let mut src = clips.to_vec();
        let mut head_cut = Time::ZERO;
        let mut short = Time::ZERO;
        match mode {
            ReplaceMode::FromStart => short = (target - v.timeline().duration).max(Time::ZERO),
            ReplaceMode::FromEnd => {
                head_cut = (v.timeline().duration - target).max(Time::ZERO);
                short = (target - v.timeline().duration).max(Time::ZERO);
            }
            ReplaceMode::AtPlayhead => {
                let into = (playhead - old.start).max(Time::ZERO).min(target);
                let delta = source_anchor - v.source.start;
                let offset = if v.speed.is_normal() { delta } else { v.speed.unscale(delta) };
                let w = offset - into;
                head_cut = w.max(Time::ZERO);
                short = (target - (v.timeline().duration - head_cut)).max(Time::ZERO);
                if w.is_negative() {
                    short = short.max(Time::ZERO - w);
                }
            }
            ReplaceMode::WithRetime => {
                let (sd, ts) = (v.source.duration, target);
                let speed = match (sd.value().checked_mul(ts.timescale()), sd.timescale().checked_mul(ts.value())) {
                    (Some(n), Some(d)) if ts.value() > 0 => ClipSpeed::new(n, d),
                    _ => ClipSpeed::NORMAL,
                };
                for c in src.iter_mut().filter(|c| c.speed_keys.is_none() && !c.is_generator() && !c.is_still) {
                    c.speed = speed;
                }
            }
        }
        if head_cut > Time::ZERO {
            src = src
                .iter()
                .filter_map(|c| c.cropped(TimeRange::from_end(c.start + head_cut, c.timeline().end())))
                .collect();
        }
        self.replace_on_main_track(id, &src, true, ids)?;
        Ok(ReplaceOutcome { short_by: short })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outcome_warns_only_when_short() {
        assert_eq!(ReplaceOutcome { short_by: Time::ZERO }.warning(), None);
        assert!(ReplaceOutcome { short_by: Time::new(1, 30) }.warning().is_some());
    }

    #[test]
    fn modes_code_as_camel_case_strings() {
        assert_eq!(serde_json::to_string(&ReplaceMode::WithRetime).ok().as_deref(), Some("\"withRetime\""));
        assert_eq!(ReplaceMode::AtPlayhead.title(), "Replace at Playhead");
    }
}

// Swift: SplitRoll.swift
//! Option-drag on a cut: the ghost the timeline draws and which cuts may be split-rolled.

use sq_core_edit::timeline_split_edit::{SplitEditSide, TimelineSplitEditExt};
use sq_core_edit::timeline_whoosh::TimelineWhooshExt;
use sq_core_model::Timeline;
use sq_core_time::Time;
use sq_editor_session::EdgeRef;

/// What the timeline draws during an Option-drag on a cut: a ghost of the old audio edge and the offset label.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SplitRollGhost {
    /// The cut.
    pub cut: Time,
    /// Applied move of the audio edit; negative = audio starts early (J cut), positive = audio runs on (L cut).
    pub offset: Time,
}

impl SplitRollGhost {
    /// "J cut -0.50 s (-15 f)" / "L cut +0.50 s (+15 f)" / "0 s".
    pub fn label(&self, frame_duration: Time) -> String {
        if self.offset == Time::ZERO {
            return "0 s".to_string();
        }
        let seconds = self.offset.value() as f64 / self.offset.timescale() as f64;
        let frames = (self.offset.value() as f64 * frame_duration.timescale() as f64
            / (self.offset.timescale() as f64 * frame_duration.value() as f64))
            .round() as i64;
        format!(
            "{} cut {:+.2} s ({}{} f)",
            if self.offset < Time::ZERO { "J" } else { "L" },
            seconds,
            if frames > 0 { "+" } else { "" },
            frames
        )
    }
}

/// Which cuts an Option-drag may split-roll.
pub(crate) struct SplitRoll;

impl SplitRoll {
    /// The cut under a pressed clip edge when that clip is linked and the cut exists on at least one audio track;
    /// `None` otherwise (the press then behaves as a normal Option-trim).
    pub(crate) fn cut(r: &EdgeRef, t: &Timeline) -> Option<Time> {
        let c = t.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == r.clip)?;
        c.link?;
        let cut = t.cut_time_of_clip(r.clip, r.edge)?;
        let mut probe = t.clone();
        probe.split_edit(cut, SplitEditSide::Audio, cut, None).ok().map(|_| cut)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_j_and_l_cuts() {
        let fd = Time::new(1, 30);
        assert_eq!(SplitRollGhost { cut: Time::ZERO, offset: Time::new(-1, 2) }.label(fd), "J cut -0.50 s (-15 f)");
        assert_eq!(SplitRollGhost { cut: Time::ZERO, offset: Time::new(1, 2) }.label(fd), "L cut +0.50 s (+15 f)");
        assert_eq!(SplitRollGhost { cut: Time::ZERO, offset: Time::ZERO }.label(fd), "0 s");
    }
}

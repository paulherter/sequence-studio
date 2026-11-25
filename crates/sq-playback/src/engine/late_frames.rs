// SPDX-License-Identifier: GPL-3.0-or-later
//! Late frames while playing: a frame position whose last composite still drew a stand-in (a nearby older picture) when the
//! next frame position replaced it. The viewer sees an old picture in that layer for a whole frame, so it counts as late
//! beside the positions that never showed at all (`skipped_frames`); the engine's shown/skipped counters alone call a
//! stream of stand-ins "smooth".

/// The late-frame count of one play run and the stalest layer seen.
#[derive(Debug, Default)]
pub(crate) struct LateFrames {
    frame: Option<i64>,
    exact: bool,
    late: u64,
    max_lag: i64,
    first: Vec<i64>,
    /// Frame positions up to this one follow a cut: a stand-in there is a cold decoder opening, not a machine too slow.
    cut_until: i64,
}

/// How many late frame positions are remembered (where a stand-in run starts is what a measurement looks for).
const REMEMBERED: usize = 8;

/// A stand-in counts as late from this many frames behind its wanted picture.
pub(crate) const MIN_LATE_LAG: i64 = 3;

/// Frame positions after a cut that are not counted late (0.5 s at 30 fps: a software GOP decode of a 4K file).
pub(crate) const CUT_GRACE: i64 = 15;

impl LateFrames {
    /// Play started with `frame` on screen (a settled picture, exact).
    pub(crate) fn start(&mut self, frame: i64) {
        *self =
            LateFrames { frame: Some(frame), exact: true, late: 0, max_lag: 0, first: Vec::new(), cut_until: i64::MIN };
    }

    /// A composite of `frame` went on screen: `exact` when every layer drew its own picture, `lag` the frames the stalest
    /// layer was behind. The exact picture that replaces a stand-in inside the same frame position clears the mark.
    /// Not late: `lag` 0 is the right frame drawn at another size (a full-detail picture where half is wanted, or the
    /// reverse), sharper or softer but never old; a stand-in under `MIN_LATE_LAG` frames old is a picture 66 ms old at most. Both were
    /// counted late and stepped Auto down on a machine that kept up (real project, Linux: half at 2.6 s, quarter at 5.1 s).
    /// `cut`: this composite shows another clip or another place of a file than the one before it; the `CUT_GRACE` frame
    /// positions after it are not counted late (a lower quality does not fix a cold decoder; it was stepping Auto down at
    /// every cut of a cut-heavy project).
    pub(crate) fn shown(&mut self, frame: i64, exact: bool, lag: i64, cut: bool) {
        let exact = exact || lag < MIN_LATE_LAG;
        if cut {
            self.cut_until = frame + CUT_GRACE;
        }
        if self.frame != Some(frame) {
            if let Some(late) = self.frame.filter(|f| !self.exact && *f > self.cut_until) {
                self.late += 1;
                if self.first.len() < REMEMBERED {
                    self.first.push(late);
                }
            }
            self.frame = Some(frame);
        }
        self.exact = exact;
        self.max_lag = self.max_lag.max(lag);
    }

    /// Frame positions that went by with a stand-in on screen.
    pub(crate) fn late(&self) -> u64 {
        self.late
    }

    /// The first late frame positions (frame indexes), up to eight.
    pub(crate) fn first(&self) -> &[i64] {
        &self.first
    }

    /// The most frames any layer was behind its wanted picture.
    pub(crate) fn max_lag(&self) -> i64 {
        self.max_lag
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_frame_replaced_while_still_a_stand_in_is_late_once() {
        let mut l = LateFrames::default();
        l.start(10);
        l.shown(11, false, 3, false);
        l.shown(11, false, 3, false); // drawn again, still a stand-in
        l.shown(12, true, 0, false); // the next frame came: 11 was late
        l.shown(13, true, 0, false);
        assert_eq!((l.late(), l.max_lag()), (1, 3));
        assert_eq!(l.first(), [11], "the late frame is the one replaced, not its successor");
    }

    #[test]
    fn the_right_frame_at_another_size_is_not_late() {
        let mut l = LateFrames::default();
        l.start(10);
        for f in 11..20 {
            l.shown(f, false, 0, false); // same frame index, other divisor
        }
        assert_eq!((l.late(), l.max_lag()), (0, 0));
        l.shown(20, false, 1, false); // one frame old: not late
        l.shown(21, false, 4, false); // a real stand-in 4 frames old
        l.shown(22, true, 0, false);
        assert_eq!(l.late(), 1);
    }

    #[test]
    fn the_exact_picture_inside_the_frame_position_is_not_late() {
        let mut l = LateFrames::default();
        l.start(10);
        l.shown(11, false, 3, false);
        l.shown(11, true, 0, false); // the exact picture arrived in time
        l.shown(12, true, 0, false);
        assert_eq!(l.late(), 0);
    }

    #[test]
    fn a_stand_in_on_the_last_frame_counts_only_when_a_frame_follows() {
        let mut l = LateFrames::default();
        l.start(5);
        l.shown(6, false, 3, false);
        assert_eq!(l.late(), 0, "nothing replaced it yet");
        l.shown(9, true, 0, false); // frames 7 and 8 never showed: those are `skipped_frames`, not late
        assert_eq!(l.late(), 1);
    }

    #[test]
    fn stand_ins_right_after_a_cut_are_not_late_but_later_ones_are() {
        let mut l = LateFrames::default();
        l.start(10);
        l.shown(11, false, 8, true); // the cut: cold decoder
        l.shown(12, false, 8, false);
        l.shown(13, true, 0, false);
        assert_eq!(l.late(), 0);
        l.shown(40, false, 8, false); // far from any cut: a real stand-in
        l.shown(41, true, 0, false);
        assert_eq!(l.late(), 1);
    }

    #[test]
    fn start_clears_the_previous_run() {
        let mut l = LateFrames::default();
        l.start(0);
        l.shown(1, false, 4, false);
        l.shown(2, true, 0, false);
        l.start(7);
        assert_eq!((l.late(), l.max_lag()), (0, 0));
    }
}

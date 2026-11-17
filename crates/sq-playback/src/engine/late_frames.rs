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
}

/// How many late frame positions are remembered (where a stand-in run starts is what a measurement looks for).
const REMEMBERED: usize = 8;

impl LateFrames {
    /// Play started with `frame` on screen (a settled picture, exact).
    pub(crate) fn start(&mut self, frame: i64) {
        *self = LateFrames { frame: Some(frame), exact: true, late: 0, max_lag: 0, first: Vec::new() };
    }

    /// A composite of `frame` went on screen: `exact` when every layer drew its own picture, `lag` the frames the stalest
    /// layer was behind. The exact picture that replaces a stand-in inside the same frame position clears the mark.
    pub(crate) fn shown(&mut self, frame: i64, exact: bool, lag: i64) {
        if self.frame != Some(frame) {
            if let Some(late) = self.frame.filter(|_| !self.exact) {
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
        l.shown(11, false, 3);
        l.shown(11, false, 3); // drawn again, still a stand-in
        l.shown(12, true, 0); // the next frame came: 11 was late
        l.shown(13, true, 0);
        assert_eq!((l.late(), l.max_lag()), (1, 3));
        assert_eq!(l.first(), [11], "the late frame is the one replaced, not its successor");
    }

    #[test]
    fn the_exact_picture_inside_the_frame_position_is_not_late() {
        let mut l = LateFrames::default();
        l.start(10);
        l.shown(11, false, 1);
        l.shown(11, true, 0); // the exact picture arrived in time
        l.shown(12, true, 0);
        assert_eq!(l.late(), 0);
    }

    #[test]
    fn a_stand_in_on_the_last_frame_counts_only_when_a_frame_follows() {
        let mut l = LateFrames::default();
        l.start(5);
        l.shown(6, false, 2);
        assert_eq!(l.late(), 0, "nothing replaced it yet");
        l.shown(9, true, 0); // frames 7 and 8 never showed: those are `skipped_frames`, not late
        assert_eq!(l.late(), 1);
    }

    #[test]
    fn start_clears_the_previous_run() {
        let mut l = LateFrames::default();
        l.start(0);
        l.shown(1, false, 4);
        l.shown(2, true, 0);
        l.start(7);
        assert_eq!((l.late(), l.max_lag()), (0, 0));
    }
}

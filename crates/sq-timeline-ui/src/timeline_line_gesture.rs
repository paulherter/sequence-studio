// Swift: TimelineLineGesture.swift
//! One drag on a line or lane of the timeline (Opacity, Volume, Item Range) as the session hears it.

use sq_core_model::Clip;

type ReplaceClip<'a> = Box<dyn FnMut(&Clip, &str, bool) + 'a>;

/// Phase of a line drag (volume, opacity, item lane) the host turns into one undo step.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VolumeEditPhase {
    /// The drag began.
    Began,
    /// The drag moved.
    Changed,
    /// The drag ended.
    Ended,
}

/// One drag on a line or lane of the timeline as the session hears it: the first change starts an undo step, every later
/// one continues it, and the step is ended exactly once, when the drag ends. A click that changed nothing ends nothing.
/// A drag that begins while the last one never ended (a lost mouse-up) ends that one first, so its step is never left
/// open for the next edit to fall into.
pub struct TimelineLineGesture<'a> {
    name: String,
    replace: ReplaceClip<'a>,
    end: Box<dyn FnMut() + 'a>,
    emitted: bool,
}

impl<'a> TimelineLineGesture<'a> {
    /// `replace`: the clip, the undo name, and whether it continues the open step (`EditorSession::replace_clip`).
    /// `end`: ends the session's gesture (`EditorSession::end_gesture`).
    pub fn new(
        name: &str,
        replace: impl FnMut(&Clip, &str, bool) + 'a,
        end: impl FnMut() + 'a,
    ) -> TimelineLineGesture<'a> {
        TimelineLineGesture { name: name.to_string(), replace: Box::new(replace), end: Box::new(end), emitted: false }
    }

    /// A change of the running drag reached the session and its step is still open.
    pub fn emitted(&self) -> bool {
        self.emitted
    }

    /// Feeds one phase of the drag.
    pub fn handle(&mut self, clip: &Clip, phase: VolumeEditPhase) {
        match phase {
            VolumeEditPhase::Began => self.close(),
            VolumeEditPhase::Changed => {
                (self.replace)(clip, &self.name, self.emitted);
                self.emitted = true;
            }
            VolumeEditPhase::Ended => self.close(),
        }
    }

    fn close(&mut self) {
        if !self.emitted {
            return;
        }
        self.emitted = false;
        (self.end)();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::mkv;
    use std::cell::RefCell;

    #[test]
    fn one_step_per_drag_and_a_click_ends_nothing() {
        let log = RefCell::new(Vec::<String>::new());
        let clip = mkv(0, 10);
        let mut g = TimelineLineGesture::new(
            "Volume",
            |_, name, cont| log.borrow_mut().push(format!("{name} {cont}")),
            || log.borrow_mut().push("end".into()),
        );
        g.handle(&clip, VolumeEditPhase::Began);
        g.handle(&clip, VolumeEditPhase::Ended); // a click that changed nothing
        assert!(log.borrow().is_empty());
        g.handle(&clip, VolumeEditPhase::Began);
        g.handle(&clip, VolumeEditPhase::Changed);
        g.handle(&clip, VolumeEditPhase::Changed);
        assert!(g.emitted());
        // a drag begins while the last never ended: the open step is ended first
        g.handle(&clip, VolumeEditPhase::Began);
        g.handle(&clip, VolumeEditPhase::Ended);
        assert_eq!(*log.borrow(), vec!["Volume false", "Volume true", "end"]);
    }
}

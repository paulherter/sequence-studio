// Swift: LiveDragCoalescer.swift
//! K6: a pointer drag on a number control (ScrubField, SQSlider, LumetriSlider) moves the control on every mouse event,
//! but hands the value to its owner (model edit, session commit, Program re-render, every panel's sync) at most once per
//! display frame. The first change of a drag goes out at once, later ones wait until a frame has passed since the last
//! one ended and then send only the newest value; `flush()` before `onEnd` sends what is still waiting, so the final
//! value and the gesture's one undo step are exactly as without coalescing. `drop()` (Esc) forgets what is waiting.
//!
//! The gap is measured from the END of the previous hand-off, so a slow owner (say 30 ms per edit) still leaves the main
//! thread a full frame between two edits to draw the control and read the pointer.

/// Coalesces the values of one drag. Runs on the UI thread only.
pub struct LiveDragCoalescer<'a> {
    /// Seconds, monotonic.
    now: Box<dyn FnMut() -> f64 + 'a>,
    /// Asks the host to call `run_scheduled(generation)` after `delay` seconds on the UI thread.
    schedule: Box<dyn FnMut(f64, u64) + 'a>,
    emit: Box<dyn FnMut(f64) + 'a>,
    last_end: f64,
    pending: Option<f64>,
    scheduled: bool,
    /// Bumped by `begin` / `drop`, so a delayed flush of an earlier drag does nothing.
    generation: u64,
    emitted: usize,
    sent_in_drag: bool,
}

impl<'a> LiveDragCoalescer<'a> {
    /// Spacing between two hand-offs (one 60 Hz frame).
    pub const FRAME: f64 = 1.0 / 60.0;

    /// `now` is a monotonic clock in seconds, `schedule` defers `run_scheduled`, `emit` hands a value to the owner.
    pub fn new(emit: impl FnMut(f64) + 'a, now: impl FnMut() -> f64 + 'a, schedule: impl FnMut(f64, u64) + 'a) -> Self {
        LiveDragCoalescer {
            now: Box::new(now),
            schedule: Box::new(schedule),
            emit: Box::new(emit),
            last_end: f64::NEG_INFINITY,
            pending: None,
            scheduled: false,
            generation: 0,
            emitted: 0,
            sent_in_drag: false,
        }
    }

    /// Newest value not handed off yet.
    pub fn pending(&self) -> Option<f64> {
        self.pending
    }

    /// Hand-offs so far (tests).
    pub fn emitted(&self) -> usize {
        self.emitted
    }

    /// True once the open drag has handed any value to the owner (after `begin`). On Esc the owner may hold a value the
    /// control no longer shows, so the start value must be sent again even when the control is already at it.
    pub fn sent_in_drag(&self) -> bool {
        self.sent_in_drag
    }

    /// A new drag: its first value goes out at once.
    pub fn begin(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.last_end = f64::NEG_INFINITY;
        self.pending = None;
        self.scheduled = false;
        self.sent_in_drag = false;
    }

    /// A new value of the open drag.
    pub fn submit(&mut self, v: f64) {
        let t = (self.now)();
        let wait = Self::FRAME - (t - self.last_end);
        if wait <= 0.0 && !self.scheduled {
            self.pending = None;
            self.fire(v);
            return;
        }
        self.pending = Some(v);
        if self.scheduled {
            return;
        }
        self.scheduled = true;
        let g = self.generation;
        (self.schedule)(wait.max(0.0), g);
    }

    /// The delayed call `schedule` asked for; does nothing when the drag it belonged to ended or was dropped.
    pub fn run_scheduled(&mut self, generation: u64) {
        if generation != self.generation {
            return;
        }
        self.scheduled = false;
        self.flush();
    }

    /// Sends the waiting value now (drag end, before `onEnd`).
    pub fn flush(&mut self) {
        let Some(v) = self.pending.take() else { return };
        self.fire(v);
    }

    /// Forgets the waiting value (Esc: the control restores the start value itself).
    pub fn drop_pending(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.pending = None;
        self.scheduled = false;
    }

    fn fire(&mut self, v: f64) {
        self.emitted += 1;
        self.sent_in_drag = true;
        (self.emit)(v);
        self.last_end = (self.now)();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    struct Rig {
        clock: Cell<f64>,
        sent: RefCell<Vec<f64>>,
        timers: RefCell<Vec<(f64, u64)>>,
    }

    fn rig() -> Rig {
        Rig { clock: Cell::new(100.0), sent: RefCell::new(vec![]), timers: RefCell::new(vec![]) }
    }

    fn coalescer(r: &Rig) -> LiveDragCoalescer<'_> {
        LiveDragCoalescer::new(
            |v| r.sent.borrow_mut().push(v),
            || r.clock.get(),
            |d, g| r.timers.borrow_mut().push((d, g)),
        )
    }

    #[test]
    fn first_value_goes_out_at_once_and_later_ones_wait_a_frame() {
        let r = rig();
        let mut c = coalescer(&r);
        c.begin();
        c.submit(1.0);
        assert_eq!(*r.sent.borrow(), vec![1.0]);
        r.clock.set(100.005);
        c.submit(2.0);
        c.submit(3.0);
        assert_eq!(*r.sent.borrow(), vec![1.0]);
        assert_eq!(r.timers.borrow().len(), 1);
        assert_eq!(c.pending(), Some(3.0));
        let (delay, g) = r.timers.borrow()[0];
        assert!((delay - (LiveDragCoalescer::FRAME - 0.005)).abs() < 1e-9);
        r.clock.set(100.02);
        c.run_scheduled(g);
        assert_eq!(*r.sent.borrow(), vec![1.0, 3.0]);
        assert_eq!(c.emitted(), 2);
    }

    #[test]
    fn flush_sends_the_waiting_value_and_drop_forgets_it() {
        let r = rig();
        let mut c = coalescer(&r);
        c.begin();
        c.submit(1.0);
        c.submit(2.0);
        c.flush();
        assert_eq!(*r.sent.borrow(), vec![1.0, 2.0]);
        c.submit(3.0);
        let g = r.timers.borrow()[0].1;
        c.drop_pending();
        c.run_scheduled(g);
        assert_eq!(*r.sent.borrow(), vec![1.0, 2.0]);
        assert_eq!(c.pending(), None);
        assert!(c.sent_in_drag());
        c.begin();
        assert!(!c.sent_in_drag());
    }
}

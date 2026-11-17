//! Back-pressure for frames on the GPU: at most `limit` submissions are unfinished at once.
//!
//! wgpu queues a submission and returns, so a GPU that is slower than the frame rate (an integrated GPU with Blur on five
//! layers) lets the queue grow without bound: every queued frame holds its uploaded pictures and uniform chunks, the driver
//! pages, and the picture stalls for seconds. The limiter makes the producer wait for the oldest frame before it records a new
//! one, and gives up after a bound so the caller can drop that frame instead of queueing it.

use std::collections::VecDeque;
use std::time::Duration;

/// The answer of [`InFlight::admit`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Admit {
    /// Room for one more frame.
    Ready,
    /// The oldest frame did not finish in time: record nothing, the frame is dropped.
    Busy,
}

/// The length of one slice of a long wait for the GPU: a GPU that stopped answering is waited on slice by slice, so the waiter
/// can look at its command queue in between (a Stop must not sit behind a 30 s wait).
pub const WAIT_SLICE: Duration = Duration::from_millis(100);

/// How [`wait_in_slices`] ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Waited {
    /// The GPU finished the frame.
    Finished,
    /// The whole bound passed without the GPU finishing it.
    TimedOut,
    /// The caller asked to stop waiting (a command is queued for it); the GPU may still finish the frame later.
    Abandoned,
}

/// Waits up to `bound` in slices of [`WAIT_SLICE`]. `wait(slice)` waits one slice and says whether the GPU finished the
/// frame; `abandon()` is asked after every unfinished slice. A caller that must never give up early (the export) passes
/// `&|| false` and so waits the whole bound.
pub fn wait_in_slices(bound: Duration, abandon: &dyn Fn() -> bool, mut wait: impl FnMut(Duration) -> bool) -> Waited {
    let mut left = bound;
    loop {
        let slice = left.min(WAIT_SLICE);
        if wait(slice) {
            return Waited::Finished;
        }
        left = left.saturating_sub(slice);
        if left.is_zero() {
            return Waited::TimedOut;
        }
        if abandon() {
            return Waited::Abandoned;
        }
    }
}

/// The submissions of the frames the GPU has not finished yet, oldest first.
pub struct InFlight<T> {
    limit: usize,
    pending: VecDeque<T>,
}

/// Frames in flight at once: the one the GPU runs and the one queued behind it.
pub const FRAMES_IN_FLIGHT: usize = 2;

impl<T> InFlight<T> {
    pub fn new(limit: usize) -> Self {
        Self { limit: limit.max(1), pending: VecDeque::new() }
    }

    /// Makes room for a new frame. While `limit` frames are pending, `finished(oldest)` is asked: it waits (bounded) for that
    /// frame and says whether the GPU finished it. A finished frame leaves the queue; an unfinished one is [`Admit::Busy`].
    pub fn admit(&mut self, mut finished: impl FnMut(&T) -> bool) -> Admit {
        while self.pending.len() >= self.limit {
            let Some(oldest) = self.pending.front() else { break };
            if !finished(oldest) {
                return Admit::Busy;
            }
            self.pending.pop_front();
        }
        Admit::Ready
    }

    /// A frame was submitted.
    pub fn submitted(&mut self, frame: T) {
        self.pending.push_back(frame);
    }

    /// Frames submitted and not yet known to be finished.
    pub fn len(&self) -> usize {
        self.pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A GPU that finishes one frame per `cost` milliseconds of simulated time; a wait of `bound` ms advances the clock.
    struct FakeGpu {
        cost: u64,
        now: u64,
        /// When each submitted frame (by id) finishes.
        done_at: Vec<u64>,
        busy_until: u64,
    }

    impl FakeGpu {
        fn new(cost: u64) -> Self {
            Self { cost, now: 0, done_at: Vec::new(), busy_until: 0 }
        }

        fn submit(&mut self) -> usize {
            self.busy_until = self.busy_until.max(self.now) + self.cost;
            self.done_at.push(self.busy_until);
            self.done_at.len() - 1
        }

        /// Waits up to `bound` ms for frame `id`; true when it finished.
        fn wait(&mut self, id: usize, bound: u64) -> bool {
            let done = self.done_at[id];
            if done <= self.now {
                return true;
            }
            if done <= self.now + bound {
                self.now = done;
                return true;
            }
            self.now += bound;
            false
        }
    }

    /// The producer: every 33 ms a frame wants to be recorded. Returns (submitted, dropped, most frames ever pending).
    fn run(cost: u64, bound: u64, frames: u64) -> (u64, u64, usize) {
        let (mut gpu, mut flight) = (FakeGpu::new(cost), InFlight::new(FRAMES_IN_FLIGHT));
        let (mut submitted, mut dropped, mut most) = (0, 0, 0);
        for i in 0..frames {
            gpu.now = gpu.now.max(i * 33);
            let admit = flight.admit(|id| gpu.wait(*id, bound));
            if admit == Admit::Busy {
                dropped += 1;
                continue;
            }
            flight.submitted(gpu.submit());
            submitted += 1;
            most = most.max(flight.len());
        }
        (submitted, dropped, most)
    }

    #[test]
    fn a_slow_gpu_never_queues_more_than_the_limit_and_the_rest_is_dropped() {
        // 90 ms of GPU time per frame against a 33 ms frame period, bounded wait of 8 ms.
        let (submitted, dropped, most) = run(90, 8, 300);
        assert!(most <= FRAMES_IN_FLIGHT, "pending frames: {most}");
        assert!(dropped > 100, "an overloaded GPU drops frames: {dropped}");
        assert_eq!(submitted + dropped, 300, "every frame is either submitted or counted dropped");
        // The GPU keeps running at its own speed: about one frame per 90 ms over 9.9 s.
        assert!((100..=115).contains(&submitted), "submitted {submitted}");
    }

    #[test]
    fn a_fast_gpu_drops_nothing() {
        let (submitted, dropped, most) = run(10, 8, 300);
        assert_eq!((submitted, dropped), (300, 0));
        assert!(most <= FRAMES_IN_FLIGHT);
    }

    #[test]
    fn a_waiting_producer_such_as_the_export_never_drops() {
        // A bound far above the cost: the producer waits for the oldest frame every time and still never exceeds the limit.
        let (submitted, dropped, most) = run(90, 10_000, 100);
        assert_eq!((submitted, dropped), (100, 0));
        assert!(most <= FRAMES_IN_FLIGHT);
    }

    /// The sliced wait on the fake GPU; returns how it ended and the simulated milliseconds it took.
    fn sliced(cost: u64, bound_ms: u64, abandon_after_checks: Option<u32>) -> (Waited, u64) {
        let mut gpu = FakeGpu::new(cost);
        let id = gpu.submit();
        let checks = std::cell::Cell::new(0);
        let abandon = || {
            checks.set(checks.get() + 1);
            abandon_after_checks.is_some_and(|n| checks.get() >= n)
        };
        let waited = wait_in_slices(Duration::from_millis(bound_ms), &abandon, |d| gpu.wait(id, d.as_millis() as u64));
        (waited, gpu.now)
    }

    #[test]
    fn a_wedged_gpu_is_waited_on_in_slices_and_a_queued_command_ends_the_wait_within_one_slice() {
        // The frame needs an hour; the bound is 30 s; the first check after a slice finds a command queued.
        let (waited, took) = sliced(3_600_000, 30_000, Some(1));
        assert_eq!(waited, Waited::Abandoned);
        assert_eq!(took, WAIT_SLICE.as_millis() as u64, "the wait ends after one slice, not after 30 s");
        // Without a command in the queue the whole bound passes.
        assert_eq!(sliced(3_600_000, 30_000, None), (Waited::TimedOut, 30_000));
        // A command that arrives after 2.5 s ends it at the next slice boundary.
        let (waited, took) = sliced(3_600_000, 30_000, Some(25));
        assert_eq!((waited, took), (Waited::Abandoned, 2_500));
    }

    #[test]
    fn a_waiter_that_never_gives_up_waits_the_whole_bound_and_a_finishing_frame_ends_it_early() {
        // The export asks `&|| false`: the bound is used up even with commands queued elsewhere.
        let mut gpu = FakeGpu::new(3_600_000);
        let id = gpu.submit();
        let waited = wait_in_slices(Duration::from_secs(30), &|| false, |d| gpu.wait(id, d.as_millis() as u64));
        assert_eq!((waited, gpu.now), (Waited::TimedOut, 30_000));
        // A frame that finishes after 250 ms ends the wait then.
        assert_eq!(sliced(250, 30_000, None), (Waited::Finished, 250));
        // Short bounds (the playing 8 ms wait) are one slice of their own length.
        assert_eq!(sliced(3_600_000, 8, Some(1)), (Waited::TimedOut, 8));
    }

    #[test]
    fn a_limit_of_zero_still_allows_one_frame() {
        let mut flight = InFlight::new(0);
        assert_eq!(flight.admit(|_: &u8| true), Admit::Ready);
        flight.submitted(1u8);
        assert_eq!(flight.admit(|_| false), Admit::Busy);
        assert_eq!(flight.len(), 1, "an unfinished frame stays pending");
        assert_eq!(flight.admit(|_| true), Admit::Ready);
        assert!(flight.is_empty());
    }
}

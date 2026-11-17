// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: RingBuffer.swift
//! Lock-free single-producer / single-consumer stereo float ring (non-interleaved).
//!
//! Producer = mixer thread (`push`, `flush`), consumer = audio callback (`pop`). Neither locks or allocates. Indices are
//! monotonic frame counters, so `consumed_frames` doubles as the audio master clock counter. Samples live in relaxed
//! `AtomicU32` bit patterns (safe code, no `unsafe`); the write index publishes them with release/acquire.
//!
//! The producer and consumer halves are separate types, so the consumer-only state (fade ramps, old-tail snapshot) is
//! plain `&mut self` data and needs no synchronization.

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, AtomicU32, AtomicU64, Ordering::*, fence};
use std::time::{Duration, Instant};

/// State shared by both halves and by readers (clock, tests).
pub struct RingShared {
    capacity: usize,
    left: Vec<AtomicU32>,
    right: Vec<AtomicU32>,
    write_index: AtomicI64,
    read_index: AtomicI64,
    flush_epoch: AtomicI64,
    flush_target: AtomicI64,
    underruns: AtomicU64,
    consumed: AtomicI64,
    // Flush acknowledgement (seqlock: odd sequence = consumer is writing). Written by the consumer only.
    ack_seq: AtomicU64,
    ack_epoch: AtomicI64,
    ack_frames: AtomicI64,
}

fn load(slot: &AtomicU32) -> f32 {
    f32::from_bits(slot.load(Relaxed))
}

fn store(slot: &AtomicU32, v: f32) {
    slot.store(v.to_bits(), Relaxed);
}

impl RingShared {
    /// Frames the ring holds at most.
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// Read position as seen by the producer: frames dropped by `flush` count as consumed even before the consumer has
    /// run again (so a flush while the consumer is paused frees the whole ring).
    fn effective_read(&self) -> i64 {
        self.read_index.load(Acquire).max(self.flush_target.load(Acquire))
    }

    /// Frames the consumer can pop right now (flushed frames excluded).
    pub fn available_to_read(&self) -> usize {
        (self.write_index.load(Acquire) - self.effective_read()).max(0) as usize
    }

    /// Frames the producer can push right now.
    pub fn available_to_write(&self) -> usize {
        self.capacity - self.available_to_read()
    }

    /// Frames delivered to the consumer since creation (excludes flushed and underrun frames).
    pub fn consumed_frames(&self) -> i64 {
        self.consumed.load(Acquire)
    }

    /// Number of `pop` calls that could not be served completely.
    pub fn underrun_count(&self) -> u64 {
        self.underruns.load(Relaxed)
    }

    /// Latest flush the consumer has applied, with `consumed_frames` at that moment (frames popped before the cut).
    /// A clock that called `flush()` (epoch `e`) and wants to re-base exactly waits until `epoch >= e`, then counts
    /// `consumed_frames - frames` as time elapsed in the new anchor. `epoch == 0` = no flush applied yet.
    pub fn consumed_at_epoch(&self) -> (i64, i64) {
        loop {
            let s1 = self.ack_seq.load(Acquire);
            if s1 & 1 == 1 {
                std::hint::spin_loop();
                continue;
            }
            let e = self.ack_epoch.load(Relaxed);
            let f = self.ack_frames.load(Relaxed);
            fence(Acquire);
            if self.ack_seq.load(Relaxed) == s1 {
                return (e, f);
            }
        }
    }

    fn publish_ack(&self, epoch: i64, frames: i64) {
        self.ack_seq.fetch_add(1, AcqRel);
        self.ack_epoch.store(epoch, Relaxed);
        self.ack_frames.store(frames, Relaxed);
        self.ack_seq.fetch_add(1, Release);
    }
}

/// Raised-cosine ramp 0 -> 1 of `n` frames.
pub(crate) fn raised_cosine(n: usize) -> Vec<f32> {
    let n = n.max(1);
    (0..n).map(|k| (0.5 - 0.5 * (std::f64::consts::PI * (k as f64 + 0.5) / n as f64).cos()) as f32).collect()
}

/// Creates a ring of `capacity` frames.
///
/// - `fade_frames`: length of the fade around a flush (5 ms = 240 frames at 48 kHz). 0 = no fades.
/// - `stale_after`: if the consumer has not popped for this long (paused), the old tail is not played on a flush.
///
/// Panics when `capacity == 0`.
pub fn ring(capacity: usize, fade_frames: usize, stale_after: Duration) -> (RingProducer, RingConsumer) {
    assert!(capacity > 0, "ring capacity must be positive");
    let slots = |n: usize| (0..n).map(|_| AtomicU32::new(0)).collect::<Vec<_>>();
    let shared = Arc::new(RingShared {
        capacity,
        left: slots(capacity),
        right: slots(capacity),
        write_index: AtomicI64::new(0),
        read_index: AtomicI64::new(0),
        flush_epoch: AtomicI64::new(0),
        flush_target: AtomicI64::new(0),
        underruns: AtomicU64::new(0),
        consumed: AtomicI64::new(0),
        ack_seq: AtomicU64::new(0),
        ack_epoch: AtomicI64::new(0),
        ack_frames: AtomicI64::new(0),
    });
    let fl = fade_frames.max(1);
    (
        RingProducer { shared: Arc::clone(&shared) },
        RingConsumer {
            shared,
            fade_frames,
            stale: stale_after,
            ramp: raised_cosine(fl),
            tail_l: vec![0.0; fl],
            tail_r: vec![0.0; fl],
            tail_count: 0,
            last_pop_end: None,
            tail_usable: 0,
            fade_out_pos: 0,
            fade_in_pos: 0,
            consumer_epoch: 0,
            #[cfg(test)]
            after_epoch_load: None,
        },
    )
}

/// Producer half (mixer thread).
pub struct RingProducer {
    shared: Arc<RingShared>,
}

impl RingProducer {
    /// Shared read-only view (clock, stats).
    pub fn shared(&self) -> Arc<RingShared> {
        Arc::clone(&self.shared)
    }

    /// Copies as many of `l.len().min(r.len())` frames as fit; returns the number accepted.
    pub fn push(&mut self, l: &[f32], r: &[f32]) -> usize {
        let s = &*self.shared;
        let count = l.len().min(r.len());
        let w = s.write_index.load(Relaxed);
        let rd = s.effective_read();
        let free = (s.capacity as i64 - (w - rd)).max(0) as usize;
        let n = count.min(free);
        if n == 0 {
            return 0;
        }
        let pos = (w % s.capacity as i64) as usize;
        for i in 0..n {
            let slot = (pos + i) % s.capacity;
            store(&s.left[slot], l[i]);
            store(&s.right[slot], r[i]);
        }
        s.write_index.store(w + n as i64, Release);
        n
    }

    /// Frames the producer can push right now.
    pub fn available_to_write(&self) -> usize {
        self.shared.available_to_write()
    }

    /// Drops everything pushed so far; the consumer discards it on its next `pop`. Data pushed after this call is kept.
    /// Returns the flush epoch; `consumed_at_epoch().0 >= epoch` once the consumer has applied it (several flushes before
    /// one `pop` are applied together, as the latest).
    pub fn flush(&self) -> i64 {
        let s = &*self.shared;
        s.flush_target.store(s.write_index.load(Relaxed), Release);
        s.flush_epoch.fetch_add(1, Release) + 1
    }
}

/// Consumer half (audio callback).
pub struct RingConsumer {
    shared: Arc<RingShared>,
    fade_frames: usize,
    stale: Duration,
    ramp: Vec<f32>,
    tail_l: Vec<f32>,
    tail_r: Vec<f32>,
    tail_count: usize,
    last_pop_end: Option<Instant>,
    tail_usable: usize,
    fade_out_pos: usize,
    fade_in_pos: usize,
    consumer_epoch: i64,
    /// Test hook: runs between the flush-epoch load and the write-index load of `pop` (the race window).
    #[cfg(test)]
    after_epoch_load: Option<Box<dyn FnMut() + Send>>,
}

impl RingConsumer {
    /// Shared read-only view (clock, stats).
    pub fn shared(&self) -> Arc<RingShared> {
        Arc::clone(&self.shared)
    }

    /// Fills `l.len().min(r.len())` frames; any shortfall is zero-filled and counted as one underrun. Returns the frames
    /// of real data. Never locks or allocates.
    pub fn pop(&mut self, l: &mut [f32], r: &mut [f32]) -> usize {
        // shortcut: one relaxed Arc refcount add per pop lets `self` stay mutably usable; split the fields if a profile shows it.
        let s = Arc::clone(&self.shared);
        let count = l.len().min(r.len());
        let mut rd = s.read_index.load(Relaxed);
        let w;
        loop {
            let epoch = s.flush_epoch.load(Acquire);
            if epoch != self.consumer_epoch {
                rd = rd.max(s.flush_target.load(Acquire));
                self.consumer_epoch = epoch;
                s.publish_ack(epoch, s.consumed.load(Relaxed));
                self.begin_fade();
            }
            #[cfg(test)]
            if let Some(hook) = self.after_epoch_load.as_mut() {
                hook();
            }
            let wi = s.write_index.load(Acquire);
            // A flush (and new pushes) that landed between the two loads: `wi` may then include data pushed after the cut
            // while `rd` still points before it. Apply the flush first, then read `wi` again.
            if s.flush_epoch.load(Acquire) == epoch {
                w = wi;
                break;
            }
        }
        let n = ((w - rd).max(0) as usize).min(count);
        if n > 0 {
            let pos = (rd % s.capacity as i64) as usize;
            for i in 0..n {
                let slot = (pos + i) % s.capacity;
                l[i] = load(&s.left[slot]);
                r[i] = load(&s.right[slot]);
            }
        }
        if n < count {
            l[n..count].fill(0.0);
            r[n..count].fill(0.0);
            s.underruns.fetch_add(1, Relaxed);
        }
        if self.fade_frames > 0 {
            if self.fade_in_pos < self.fade_frames || self.fade_out_pos < self.fade_frames {
                self.apply_fade(l, r, count, n);
            }
            self.snapshot_tail(rd + n as i64);
        }
        s.read_index.store(rd + n as i64, Release);
        if n > 0 {
            s.consumed.fetch_add(n as i64, Release);
        }
        n
    }

    /// A flush was just applied. Fade-in starts on the first real new frame; the old tail (if the consumer was actively
    /// playing) fades out over the first `fade_frames` output frames, cross-faded with the new material.
    fn begin_fade(&mut self) {
        if self.fade_frames == 0 {
            return;
        }
        self.fade_in_pos = 0;
        self.fade_out_pos = 0;
        let active = self.last_pop_end.is_some_and(|t| t.elapsed() <= self.stale);
        self.tail_usable = if active { self.tail_count } else { 0 };
    }

    fn apply_fade(&mut self, l: &mut [f32], r: &mut [f32], count: usize, real: usize) {
        for j in 0..count {
            // With an old tail the two ramps advance together (crossfade stays at unity even on a partial pop);
            // without one, fade-in waits for real data.
            if self.fade_in_pos < self.fade_frames && (j < real || self.tail_usable > 0) {
                if j < real {
                    let g = self.ramp[self.fade_in_pos];
                    l[j] *= g;
                    r[j] *= g;
                }
                self.fade_in_pos += 1;
            }
            if self.fade_out_pos < self.fade_frames {
                if self.fade_out_pos < self.tail_usable {
                    let g = 1.0 - self.ramp[self.fade_out_pos];
                    l[j] += self.tail_l[self.fade_out_pos] * g;
                    r[j] += self.tail_r[self.fade_out_pos] * g;
                }
                self.fade_out_pos += 1;
            }
        }
    }

    /// Copies up to `fade_frames` frames that follow the read position (what would have played next).
    fn snapshot_tail(&mut self, pos: i64) {
        let s = &*self.shared;
        let w = s.write_index.load(Acquire);
        let n = ((w - pos).max(0) as usize).min(self.fade_frames);
        let epoch = self.consumer_epoch;
        if n > 0 {
            let p = (pos % s.capacity as i64) as usize;
            for i in 0..n {
                let slot = (p + i) % s.capacity;
                self.tail_l[i] = load(&s.left[slot]);
                self.tail_r[i] = load(&s.right[slot]);
            }
        }
        fence(AcqRel); // order the copy before the epoch recheck
        // A flush that raced the copy makes the snapshot (possibly overwritten by the producer) unusable.
        self.tail_count = if s.flush_epoch.load(Acquire) == epoch { n } else { 0 };
        self.last_pop_end = Some(Instant::now());
    }
}

#[cfg(test)]
mod tests;

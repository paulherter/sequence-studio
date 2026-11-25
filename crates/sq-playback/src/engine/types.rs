// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: WinProgramEngine.swift (Key, Wanted, WinWantGate), NV12Picture (as `Picture`)
//! Small value types of the engine: cache keys, the wanted-frame record, the want gate the decode jobs read, and the
//! decoded picture.

use sq_core_time::{Id, Time};
use sq_frame::sqframe::SQFrame;
use std::collections::{HashMap, HashSet};
use std::ops::RangeInclusive;
use std::sync::{Mutex, PoisonError};

/// One decoded picture of a file: its presentation index, and how it was made.
/// `proxy`: the picture comes from the media's proxy (always false until the proxy service is ported).
/// `divisor`: the picture is box-reduced by it against the original's size (playback quality, and while playing or
/// scrubbing the layer's drawn size).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Key {
    pub media: Id,
    pub index: i64,
    pub proxy: bool,
    pub divisor: u32,
}

impl Key {
    pub fn new(media: Id, index: i64, divisor: u32) -> Key {
        Key { media, index, proxy: false, divisor }
    }
}

/// The frame to show: its position and the decoded pictures it needs (bottom to top).
#[derive(Clone, Debug, PartialEq)]
pub struct Wanted {
    pub position: Time,
    pub keys: Vec<Key>,
}

/// A decoded picture the cache holds: the frame (CPU planes, or a GPU frame on the Mac) and what it costs in bytes.
#[derive(Clone)]
pub struct Picture {
    pub frame: SQFrame,
    pub bytes: usize,
}

/// A media file of the project: id and path (the host refreshes the list with `Command::SetMedia`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaRef {
    pub id: Id,
    pub path: String,
}

#[derive(Default)]
struct GateState {
    indices: HashMap<Id, HashSet<i64>>,
    playing: bool,
    /// Playing forward with no clip read backwards: a queued decode that fell behind the playhead is skipped (`is_late`).
    forward: bool,
}

/// A queued playback decode is late once every frame the monitor wants of its file lies this many frames past the end of its
/// range. At a healthy pace a job waits milliseconds (under one frame), so only a collapse reaches it.
pub const LATE_SKIP_FRAMES: i64 = 3;

/// The pictures the monitor wants right now, readable from the decode lanes: a paused or scrubbing playhead moves on faster
/// than a long-GOP decode runs, so a queued decode asks (once the decoder is free) whether anything in its range is still
/// wanted and is dropped when not. Playback never drops: its ranges run ahead of the playhead on purpose.
#[derive(Default)]
pub struct WantGate {
    state: Mutex<GateState>,
}

impl WantGate {
    pub fn set(&self, keys: &[Key], playing: bool) {
        let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        s.playing = playing;
        s.indices.clear();
        for k in keys {
            s.indices.entry(k.media).or_default().insert(k.index);
        }
    }

    /// Playback runs forward and no clip reads backwards: only then may `is_late` skip a job (a backward read decodes its
    /// window from behind the playhead on purpose).
    pub fn set_forward(&self, forward: bool) {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).forward = forward;
    }

    /// Playing forward: the whole `range` of an urgent decode lies behind every picture its file now shows. Decoding it
    /// would only seek the decoder back (or run it through frames nobody can show any more) while the backlog grows; the
    /// next job reads on from the decoder's position, forward, so the late frames are skipped, never fetched.
    pub fn is_late(&self, media: Id, range: &RangeInclusive<i64>) -> bool {
        let s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if !s.playing || !s.forward {
            return false;
        }
        s.indices.get(&media).is_some_and(|w| !w.is_empty() && w.iter().all(|i| *i > *range.end() + LATE_SKIP_FRAMES))
    }

    /// Also wanted (not stale): the neighbours a paused playhead fills the cache with.
    pub fn extend(&self, keys: &[Key]) {
        let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        for k in keys {
            s.indices.entry(k.media).or_default().insert(k.index);
        }
    }

    pub fn is_stale(&self, media: Id, range: &RangeInclusive<i64>) -> bool {
        let s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if s.playing {
            return false;
        }
        match s.indices.get(&media) {
            None => true,
            Some(wanted) => !wanted.iter().any(|i| range.contains(i)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    #[test]
    fn playing_forward_skips_a_job_the_playhead_passed_but_never_a_current_or_backward_one() {
        let g = WantGate::default();
        g.set(&[Key::new(id(1), 50, 1)], true);
        g.set_forward(true);
        assert!(g.is_late(id(1), &(32..=40)), "50 is past 40 + margin: late");
        assert!(!g.is_late(id(1), &(45..=53)), "the range holds the wanted frame");
        assert!(!g.is_late(id(1), &(47..=48)), "within the margin");
        assert!(!g.is_late(id(2), &(0..=1)), "a file nothing shows is a prefetch, not late");
        g.set(&[Key::new(id(1), 50, 1), Key::new(id(1), 20, 1)], true);
        assert!(!g.is_late(id(1), &(32..=40)), "another clip of the file still shows frame 20");
        g.set_forward(false);
        g.set(&[Key::new(id(1), 50, 1)], true);
        assert!(!g.is_late(id(1), &(32..=40)), "backward play reads behind the playhead on purpose");
        g.set_forward(true);
        g.set(&[Key::new(id(1), 50, 1)], false);
        assert!(!g.is_late(id(1), &(32..=40)), "paused jobs use is_stale");
    }

    #[test]
    fn paused_gate_drops_ranges_nothing_wants() {
        let g = WantGate::default();
        g.set(&[Key::new(id(1), 10, 1)], false);
        assert!(!g.is_stale(id(1), &(8..=12)));
        assert!(g.is_stale(id(1), &(11..=20)));
        assert!(g.is_stale(id(2), &(0..=100)));
    }

    #[test]
    fn playing_gate_never_drops() {
        let g = WantGate::default();
        g.set(&[], true);
        assert!(!g.is_stale(id(9), &(0..=1)));
    }
}

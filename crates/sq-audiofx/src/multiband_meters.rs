// Swift: MultibandMeters.swift
//! Lock-free meter feed from the audio threads to the Multiband custom setup. The UI names ONE effect to watch
//! (`watch`, the popup's effect); every `MultibandStage` of that effect publishes its block's levels with relaxed atomic
//! stores (no lock, no allocation: realtime-safe) and every other stage only does one atomic load per block. Whatever chain
//! runs the effect (playback, scrub, export) feeds it; nothing is ever published for an effect not watched, and nothing is
//! estimated: no audio = no new sequence.

use sq_core_time::Id;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicU64, Ordering};

/// One meter reading of the watched Multiband Compressor: band input peaks (linear, after the crossover split), band gain
/// reduction (dB, >= 0, 0 for a bypassed band) and the output limiter's reduction (dB, >= 0). `sequence` counts published
/// blocks: an unchanged sequence means no audio ran through the effect since the last reading (stopped, or another clip).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MultibandMeterReading {
    /// Published blocks so far.
    pub sequence: u64,
    /// Band input peaks, linear.
    pub input_peak: [f32; 4],
    /// Band gain reduction in dB.
    pub gain_reduction_db: [f32; 4],
    /// Output limiter reduction in dB.
    pub limiter_reduction_db: f32,
}

/// The meter feed of the watched effect.
#[derive(Debug, Default)]
pub struct MultibandMeterTap {
    watching: AtomicBool,
    id_hi: AtomicU64,
    id_lo: AtomicU64,
    peaks: [AtomicU32; 4],
    reductions: [AtomicU32; 4],
    lim: AtomicU32,
    seq: AtomicU64,
    /// The track Noise Gate: 0 = off / unknown, 1 = closed, 2 = open.
    gate: AtomicU8,
}

static SHARED: MultibandMeterTap = MultibandMeterTap::new();
static TRACKS: MultibandMeterTap = MultibandMeterTap::new();

impl MultibandMeterTap {
    /// An idle tap.
    pub const fn new() -> Self {
        MultibandMeterTap {
            watching: AtomicBool::new(false),
            id_hi: AtomicU64::new(0),
            id_lo: AtomicU64::new(0),
            peaks: [AtomicU32::new(0), AtomicU32::new(0), AtomicU32::new(0), AtomicU32::new(0)],
            reductions: [AtomicU32::new(0), AtomicU32::new(0), AtomicU32::new(0), AtomicU32::new(0)],
            lim: AtomicU32::new(0),
            seq: AtomicU64::new(0),
            gate: AtomicU8::new(0),
        }
    }

    /// The process-wide tap.
    pub fn shared() -> &'static MultibandMeterTap {
        &SHARED
    }

    /// The tap of the track compressors (`RealtimeAudioFX`): the UI watches ONE track id, the other tracks only do one atomic
    /// load per block. Same type as the clip effect tap, a separate instance so the two watchers never clash.
    pub fn tracks() -> &'static MultibandMeterTap {
        &TRACKS
    }

    /// The two halves of an id as the first and second 8 bytes in little-endian order (the Swift `uuid` tuple read natively).
    pub fn split(id: Id) -> (u64, u64) {
        let v = id.as_u128();
        (((v >> 64) as u64).swap_bytes(), (v as u64).swap_bytes())
    }

    /// The effect whose stages publish; `None` stops all publishing.
    pub fn watch(&self, id: Option<Id>) {
        let Some(id) = id else {
            self.watching.store(false, Ordering::Release);
            return;
        };
        let (h, l) = Self::split(id);
        self.watching.store(false, Ordering::Release);
        self.id_hi.store(h, Ordering::Relaxed);
        self.id_lo.store(l, Ordering::Relaxed);
        // Nothing of the previous effect shows (sequence unchanged: no audio yet).
        self.store([0.0; 4], [0.0; 4], 0.0);
        self.watching.store(true, Ordering::Release);
    }

    /// Audio thread: is the stage with this id (pre-split) the watched one? One to three atomic loads.
    #[inline]
    pub fn is_watched(&self, hi: u64, lo: u64) -> bool {
        self.watching.load(Ordering::Acquire)
            && self.id_hi.load(Ordering::Relaxed) == hi
            && self.id_lo.load(Ordering::Relaxed) == lo
    }

    /// Audio thread: one block's levels. Realtime-safe.
    pub fn publish(&self, input_peak: [f64; 4], gain_reduction_db: [f64; 4], limiter_reduction_db: f64) {
        self.store(input_peak, gain_reduction_db, limiter_reduction_db);
        self.seq.fetch_add(1, Ordering::Release);
    }

    /// Audio thread: the watched track's gate state (`None` = the gate is off). Realtime-safe.
    pub fn publish_gate(&self, open: Option<bool>) {
        self.gate.store(open.map_or(0, |o| if o { 2 } else { 1 }), Ordering::Relaxed);
    }

    /// The watched track's Noise Gate: `Some(true)` open, `Some(false)` closed, `None` when `id` is not watched or the
    /// gate is off.
    pub fn gate_open(&self, id: Id) -> Option<bool> {
        let (h, l) = Self::split(id);
        if !self.is_watched(h, l) {
            return None;
        }
        match self.gate.load(Ordering::Relaxed) {
            0 => None,
            n => Some(n == 2),
        }
    }

    fn store(&self, p: [f64; 4], g: [f64; 4], l: f64) {
        for i in 0..4 {
            self.peaks[i].store((p[i] as f32).to_bits(), Ordering::Relaxed);
            self.reductions[i].store((g[i] as f32).to_bits(), Ordering::Relaxed);
        }
        self.lim.store((l as f32).to_bits(), Ordering::Relaxed);
    }

    /// Published blocks so far (all effects).
    pub fn sequence(&self) -> u64 {
        self.seq.load(Ordering::Acquire)
    }

    /// The latest levels when `id` is the watched effect, else `None`. Fields of one reading may come from two neighboring
    /// blocks (no lock); fine for a 30 Hz meter.
    pub fn reading(&self, id: Id) -> Option<MultibandMeterReading> {
        let (h, l) = Self::split(id);
        if !self.is_watched(h, l) {
            return None;
        }
        let sequence = self.seq.load(Ordering::Acquire);
        let f = |a: &AtomicU32| f32::from_bits(a.load(Ordering::Relaxed));
        Some(MultibandMeterReading {
            sequence,
            input_peak: [f(&self.peaks[0]), f(&self.peaks[1]), f(&self.peaks[2]), f(&self.peaks[3])],
            gain_reduction_db: [
                f(&self.reductions[0]),
                f(&self.reductions[1]),
                f(&self.reductions[2]),
                f(&self.reductions[3]),
            ],
            limiter_reduction_db: f(&self.lim),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_gate_state_is_read_only_for_the_watched_track() {
        let tap = MultibandMeterTap::new();
        let id = Id::from_u128(9);
        tap.watch(Some(id));
        assert_eq!(tap.gate_open(id), None, "nothing published yet");
        tap.publish_gate(Some(true));
        assert_eq!(tap.gate_open(id), Some(true));
        tap.publish_gate(Some(false));
        assert_eq!(tap.gate_open(id), Some(false));
        assert_eq!(tap.gate_open(Id::from_u128(10)), None, "another track is not watched");
        tap.publish_gate(None);
        assert_eq!(tap.gate_open(id), None, "a gate that is off shows nothing");
    }

    #[test]
    fn only_the_watched_effect_publishes_and_reads() {
        let tap = MultibandMeterTap::new();
        let (a, b) = (Id::from_u128(1), Id::from_u128(2));
        assert!(tap.reading(a).is_none());
        tap.watch(Some(a));
        let (hi, lo) = MultibandMeterTap::split(a);
        assert!(tap.is_watched(hi, lo));
        let (hi2, lo2) = MultibandMeterTap::split(b);
        assert!(!tap.is_watched(hi2, lo2));
        tap.publish([0.5, 0.25, 0.0, 1.0], [1.0, 2.0, 0.0, 0.0], 3.0);
        let r = tap.reading(a);
        assert_eq!(
            r,
            Some(MultibandMeterReading {
                sequence: 1,
                input_peak: [0.5, 0.25, 0.0, 1.0],
                gain_reduction_db: [1.0, 2.0, 0.0, 0.0],
                limiter_reduction_db: 3.0
            })
        );
        assert!(tap.reading(b).is_none());
        tap.watch(None);
        assert!(tap.reading(a).is_none());
    }

    #[test]
    fn watching_another_effect_clears_the_levels_but_keeps_the_sequence() {
        let tap = MultibandMeterTap::new();
        tap.watch(Some(Id::from_u128(1)));
        tap.publish([1.0; 4], [1.0; 4], 1.0);
        tap.watch(Some(Id::from_u128(2)));
        let r = tap.reading(Id::from_u128(2));
        assert_eq!(r.map(|r| (r.sequence, r.input_peak, r.limiter_reduction_db)), Some((1, [0.0; 4], 0.0)));
    }
}

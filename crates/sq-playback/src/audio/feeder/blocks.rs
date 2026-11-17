// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioFeeder.swift (renderBlock, mix, master level, post fader)
//! One mixed block: per-track mix -> (reverse) -> FX -> delay compensation -> role buses -> Sequence Volume -> channel
//! layout -> master limiter. Also the dry `mix` used by scrubbing.

use super::config::{BusSet, lock};
use super::segments::{AccOpts, Dest, MixCtx};
use super::{AudioFeeder, SAMPLE_RATE};
use crate::audio::track_mix::{AUDIO_TAGS, Sequences, track_fader_gain};
use sq_core_model::{AudioTag, ChannelLayout, Timeline, TrackPan};
use sq_core_time::{Id, Time};
use std::collections::HashMap;

/// Planar stereo block buffer.
#[derive(Default)]
pub(super) struct Stereo {
    pub(super) l: Vec<f32>,
    pub(super) r: Vec<f32>,
}

impl Stereo {
    pub(super) fn new(frames: usize) -> Stereo {
        Stereo { l: vec![0.0; frames], r: vec![0.0; frames] }
    }
}

/// Channels: Mono = (L + R) / 2 on both sides (dual mono). The one fold, shared by `render_block` and the scrub path `mix`.
fn apply_channel_layout(layout: ChannelLayout, left: &mut [f32], right: &mut [f32]) {
    if layout != ChannelLayout::Mono {
        return;
    }
    for (l, r) in left.iter_mut().zip(right.iter_mut()) {
        let m = ChannelLayout::fold(*l, *r);
        *l = m;
        *r = m;
    }
}

/// Keyed Sequence Volume: the gain at absolute 256-frame grid points (sequence time), linear in between, so any split of
/// a range into blocks gives the same samples. `reverse`: the block is already reversed in place. `latency`: samples the
/// mix is behind the timeline (FX delay compensation); the level follows the sound it multiplies, so it is read `latency`
/// earlier going forward and `latency` later in reverse.
pub(crate) fn apply_keyed_master_level(
    timeline: &Timeline,
    start_frame: i64,
    reverse: bool,
    latency: i64,
    left: &mut [f32],
    right: &mut [f32],
) {
    let grid = 256i64;
    let count = left.len().min(right.len());
    let (mut lo, mut g_lo, mut g_hi) = (i64::MIN, 1.0f32, 1.0f32);
    for j in 0..count {
        let frame = start_frame + j as i64 + if reverse { latency } else { -latency };
        let cell = (if frame >= 0 { frame / grid } else { -((-frame + grid - 1) / grid) }) * grid;
        if cell != lo {
            lo = cell;
            g_lo = timeline.master_gain_at(Time::new(cell, SAMPLE_RATE)) as f32;
            g_hi = timeline.master_gain_at(Time::new(cell + grid, SAMPLE_RATE)) as f32;
        }
        let g = g_lo + (g_hi - g_lo) * (frame - cell) as f32 / grid as f32;
        let i = if reverse { count - 1 - j } else { j };
        left[i] *= g;
        right[i] *= g;
    }
}

/// `p[i] *= was + (now - was) * i / n` (or `now` when equal).
fn ramp_gain(p: &mut [f32], was: f32, now: f32) {
    let n = p.len();
    if was == now {
        for s in p.iter_mut() {
            *s *= now;
        }
    } else {
        for (i, s) in p.iter_mut().enumerate() {
            *s *= was + (now - was) * i as f32 / n as f32;
        }
    }
}

/// Non-nil when `role`'s bus must be used: its gain is not 0 dB, or it was not at the start of this block (a ramp back to
/// unity still has to run through the bus).
fn role_gain(role: AudioTag, db: &HashMap<AudioTag, f64>, state: &HashMap<AudioTag, f32>) -> Option<f32> {
    let now = TrackPan::linear(db.get(&role).copied().unwrap_or(0.0)) as f32;
    let was = state.get(&role).copied().unwrap_or(now); // no history (fresh feeder, after a seek): no ramp
    if now == 1.0 && was == 1.0 { None } else { Some(now) }
}

impl AudioFeeder {
    /// Per-track mix -> (reverse) -> FX -> delay compensation -> sum into `self.out`, in play order.
    pub(super) fn render_block(&mut self, ctx: &MixCtx, buses: &BusSet, start: i64, count: usize, reverse: bool) {
        let timeline = ctx.timeline;
        let mut bufs = std::mem::take(&mut self.bus_bufs);
        bufs.resize_with(buses.list.len(), || Stereo::new(self.block_frames));
        for b in &mut bufs {
            b.l[..count].fill(0.0);
            b.r[..count].fill(0.0);
        }
        let mut out = std::mem::take(&mut self.out);
        out.l[..count].fill(0.0);
        out.r[..count].fill(0.0);
        // Clip audio effects also run in reverse play: each block is mixed forward, so the chain sees increasing time
        // inside the block; blocks arrive backwards, so its state is reset and re-primed at every block.
        let opts = AccOpts { clip_effects: true, fader_after_effects: true };
        let mut dest = Dest::Buses { index: &buses.index, bufs: &mut bufs, fallback: &mut out };
        self.accumulate_segments(ctx, start, count, opts, None, &mut dest);
        if reverse {
            out.l[..count].reverse();
            out.r[..count].reverse();
        }
        let mut ids = vec![Id::from_u128(0); buses.list.len()];
        for (&id, &i) in &buses.index {
            ids[i] = id;
        }
        let role_db = lock(&self.shared.role_gains_db).clone();
        let mut bus_active = [false; AUDIO_TAGS.len()];
        for (bi, b) in buses.list.iter().enumerate() {
            let buf = &mut bufs[bi];
            let (l, r) = (&mut buf.l[..count], &mut buf.r[..count]);
            if reverse {
                l.reverse();
                r.reverse();
            }
            b.process(l, r, reverse, start);
            self.apply_post_fader(l, r, ids[bi], timeline);
            let role = timeline.track(ids[bi]).and_then(|t| t.audio_role);
            let ri = role.and_then(|role| AUDIO_TAGS.iter().position(|t| *t == role));
            if let (Some(role), Some(ri)) = (role, ri)
                && role_gain(role, &role_db, &self.role_gain_state).is_some()
            {
                let rb = &mut self.role_buffers[ri];
                if !bus_active[ri] {
                    bus_active[ri] = true;
                    rb.l[..count].fill(0.0);
                    rb.r[..count].fill(0.0);
                }
                for i in 0..count {
                    rb.l[i] += l[i];
                    rb.r[i] += r[i];
                }
            } else {
                for i in 0..count {
                    out.l[i] += l[i];
                    out.r[i] += r[i];
                }
            }
        }
        for (ri, role) in AUDIO_TAGS.iter().enumerate() {
            // Every role's gain is remembered each block (no history = no ramp), active or not, so a later change ramps
            // from the truth.
            let now = TrackPan::linear(role_db.get(role).copied().unwrap_or(0.0)) as f32;
            let was = self.role_gain_state.get(role).copied().unwrap_or(now);
            self.role_gain_state.insert(*role, now);
            if !bus_active[ri] {
                continue;
            }
            let rb = &self.role_buffers[ri];
            for i in 0..count {
                let g = if was == now { now } else { was + (now - was) * i as f32 / count as f32 };
                out.l[i] += rb.l[i] * g;
                out.r[i] += rb.r[i] * g;
            }
        }
        self.apply_master_level(timeline, start, reverse, buses.latency, &mut out.l[..count], &mut out.r[..count]);
        apply_channel_layout(timeline.channel_layout(), &mut out.l[..count], &mut out.r[..count]);
        if let Some(limiter) = &mut self.limiter {
            limiter.process(&mut out.l[..count], &mut out.r[..count]); // master bus, shared by playback and export
        }
        self.out = out;
        self.bus_bufs = bufs;
    }

    /// The top sequence's Sequence Volume on the summed mix, ramped linearly from the previous block's level like a fader.
    fn apply_master_level(
        &mut self,
        timeline: &Timeline,
        start: i64,
        reverse: bool,
        latency: usize,
        l: &mut [f32],
        r: &mut [f32],
    ) {
        if timeline.is_master_volume_keyed() {
            self.master_level_state = None;
            apply_keyed_master_level(timeline, start, reverse, latency as i64, l, r);
            return;
        }
        let now = timeline.master_gain() as f32;
        let was = self.master_level_state.unwrap_or(now);
        self.master_level_state = Some(now);
        if was == 1.0 && now == 1.0 {
            return;
        }
        ramp_gain(l, was, now);
        ramp_gain(r, was, now);
    }

    /// Track fader gain (no pan: pan is applied per segment before the effects) after the bus' effects, ramped linearly
    /// from where the previous block ended (no step, no click). Same path for playback and export.
    fn apply_post_fader(&mut self, l: &mut [f32], r: &mut [f32], track: Id, timeline: &Timeline) {
        let now = track_fader_gain(timeline, track) as f32;
        let was = self.post_fader_state.get(&track).copied().unwrap_or(now);
        self.post_fader_state.insert(track, now);
        if was == 1.0 && now == 1.0 {
            return;
        }
        ramp_gain(l, was, now);
        ramp_gain(r, was, now);
    }

    /// Mixes timeline frames `[start_frame, start_frame + left.len())` in forward order into `left`/`right` (overwritten).
    /// Clip boundaries are sample-exact: a frame belongs to a clip when `start <= frame/rate < end`. Mix of all tracks
    /// without track FX or latency compensation (scrub); the mixer thread itself uses `next_block`.
    /// `clip_effects`: run clip and nest audio effects: consecutive calls continue the chains' state, any jump resets and
    /// re-primes them.
    pub fn mix(
        &mut self,
        timeline: &Timeline,
        sequences: &Sequences,
        start_frame: i64,
        left: &mut [f32],
        right: &mut [f32],
        clip_effects: bool,
    ) {
        let count = left.len().min(right.len());
        left[..count].fill(0.0);
        right[..count].fill(0.0);
        let ctx = MixCtx { timeline, sequences, duck_index: None };
        let opts = AccOpts { clip_effects, fader_after_effects: false };
        let mut done = 0;
        while done < count {
            // Longer than one block: contiguous chunks (chains continue across them).
            let n = self.block_frames.min(count - done);
            let mut dest = Dest::Pair(&mut left[done..done + n], &mut right[done..done + n]);
            self.accumulate_segments(&ctx, start_frame + done as i64, n, opts, None, &mut dest);
            done += n;
        }
        let (l, r) = (&mut left[..count], &mut right[..count]);
        if timeline.is_master_volume_keyed() {
            apply_keyed_master_level(timeline, start_frame, false, 0, l, r);
        } else {
            let g = timeline.master_gain() as f32; // Sequence Volume (scrub: constant, no limiter on this path)
            if g != 1.0 {
                for i in 0..count {
                    l[i] *= g;
                    r[i] *= g;
                }
            }
        }
        apply_channel_layout(timeline.channel_layout(), l, r); // Mono scrub = Mono playback
    }
}

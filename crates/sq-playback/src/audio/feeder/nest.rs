// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioFeeder.swift (renderNest)
//! One effected nest: its inner segments summed, through the nest clip's chain, then the nest clip's Volume, the
//! enclosing nests' gains and the faders from the nest's track outwards.

use super::segments::{AccOpts, Dest, MixCtx, Ramp, accumulate, place};
use super::{AudioFeeder, ClipFx, NestGroup, ceil_frame};
use crate::audio::track_mix::{FaderKey, Gains, nest_fader};
use sq_audiofx::gain::GainMath;
use sq_core_audio::ClipAudioChainExt;
use sq_core_effects::evaluation::AudioSegment;
use sq_core_time::Time;
use std::collections::HashMap;

impl AudioFeeder {
    /// One effected nest over `[start_frame, start_frame + count)`: its inner segments summed (Audio Gain of the nest clip
    /// in, inner volumes and faders applied), through the nest clip's chain (read ahead by its latency, primed after a
    /// jump), then the nest clip's Volume, the enclosing nests' gains and the faders from the nest's track outwards.
    /// `parent`: the effected nest this one plays in. Its output then goes into the parent's sum (the parent's buffers are
    /// `dest`) with the gains and faders between the two only; the rest follows the parent's chain.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn render_nest(
        &mut self,
        ctx: &MixCtx,
        group: NestGroup,
        parent: Option<NestGroup>,
        seg: &AudioSegment,
        start_frame: i64,
        count: usize,
        end_state: &mut HashMap<FaderKey, Gains>,
        fader_after_effects: bool,
        dest: &mut Dest,
    ) {
        let rate = super::SAMPLE_RATE;
        let d = group.depth;
        let nest = &seg.nests[d].clip;
        while self.nest_buffers.len() <= d {
            self.nest_buffers.push(super::Stereo::new(self.block_frames)); // deeper than 4 nests: once
        }
        let mut buf = std::mem::take(&mut self.nest_buffers[d]);
        // The chain is taken out of the pool while it runs: the inner pass may add chains of its own.
        let reuse = self.clip_fx.get(&group.key).is_some_and(|old| nest.audio_fx_layout_matches(&old.chain.layout));
        let fx = if reuse { self.clip_fx.remove(&group.key) } else { None };
        let fx = fx.or_else(|| (self.make_chain)(&nest.audio_fx_layout(), self.block_frames).ok().map(ClipFx::new));
        let Some(mut fx) = fx else {
            self.nest_buffers[d] = buf;
            return;
        };
        fx.serial = self.clip_fx_serial;
        // The nest clip's own time: top time through the nests above it.
        let local = |frame: i64| -> Time {
            let mut t = Time::new(frame, rate);
            for n in &seg.nests[..d] {
                t = n.clip.source_instant(t - n.clip.start);
            }
            t - nest.start
        };
        let scalar = |e: &sq_core_model::ClipEffect, k: &str, at: Time| e.scalar(k, at);
        fx.steps = nest.audio_fx_steps(local(start_frame), &scalar);
        fx.end_steps = nest.audio_fx_steps(local(start_frame + count as i64), &scalar);
        let lat = fx.chain.latency_samples;
        let stream = Time::new(start_frame, rate) - seg.nests[0].clip.start;
        place(&mut fx.end_steps, stream + Time::new(count as i64, rate));
        let opts = AccOpts { clip_effects: true, fader_after_effects };
        if fx.next_frame != start_frame {
            fx.chain.reset();
            let mut primed = 0;
            while primed < lat {
                let k = self.block_frames.min(lat - primed);
                self.read_nest(ctx, group, opts, &mut buf, start_frame + primed as i64, k);
                place(&mut fx.steps, stream + Time::new(primed as i64 - lat as i64, rate));
                fx.chain.process(&mut [&mut buf.l[..k], &mut buf.r[..k]], k, &fx.steps, None);
                primed += k;
            }
        }
        self.read_nest(ctx, group, opts, &mut buf, start_frame + lat as i64, count);
        place(&mut fx.steps, stream);
        fx.chain.process(&mut [&mut buf.l[..count], &mut buf.r[..count]], count, &fx.steps, Some(&fx.end_steps));
        fx.next_frame = start_frame + count as i64;
        self.clip_fx.insert(group.key, fx);
        // After the chain: the nest's Volume and transition curves, the enclosing nests' full gains.
        let above = parent.map(|p| p.depth);
        let post = |frame: i64| -> f64 {
            let mut t = Time::new(frame, rate);
            let mut g = 1.0;
            for (j, n) in seg.nests[..=d].iter().enumerate() {
                if let Some(a) = above
                    && j <= a
                {
                    if j == a {
                        g *= GainMath::linear_from_db(n.clip.audio_gain_db); // the parent's input level
                    }
                } else {
                    for e in &n.envelopes {
                        g *= e.gain(t);
                    }
                    g *= if j == d {
                        n.clip.animation.volume.value_at_local(t - n.clip.start).max(0.0)
                    } else {
                        n.clip.volume(t)
                    };
                }
                t = n.clip.source_instant(t - n.clip.start);
            }
            g
        };
        let top = seg.nests[0].track;
        let at = Time::new(start_frame.max(ceil_frame(seg.timeline.start, rate)), rate);
        let fader = nest_fader(seg, d, above, ctx.timeline, ctx.sequences, fader_after_effects, at);
        let bus_key = FaderKey { track: top, mono: false };
        // Fader ramps belong to the top-level bus: inside a parent the faders are the plain product.
        let previous = if parent.is_none() { self.fader_state.get(&bus_key).copied().unwrap_or(fader) } else { fader };
        if parent.is_none() {
            end_state.insert(bus_key, fader);
        }
        let (dl, dr) = dest.get(top);
        for (ch, dst) in [dl, dr].into_iter().enumerate() {
            let src = if ch == 0 { &buf.l[..count] } else { &buf.r[..count] };
            let (side, was) = if ch == 0 { (fader.0, previous.0) } else { (fader.1, previous.1) };
            let dst = &mut dst[..count];
            if was != side {
                let ramp = Ramp { from: was as f32, to: side as f32, offset: 0, total: count };
                accumulate(src, dst, start_frame, true, &post, Some(ramp));
            } else if side == 1.0 {
                accumulate(src, dst, start_frame, true, &post, None);
            } else {
                accumulate(src, dst, start_frame, true, &|f| post(f) * side, None);
            }
        }
        self.nest_buffers[d] = buf;
    }

    /// The inner pass of a nest group: the nest's segments for `[frame, frame + k)` summed into `buf`.
    fn read_nest(
        &mut self,
        ctx: &MixCtx,
        group: NestGroup,
        opts: AccOpts,
        buf: &mut super::Stereo,
        frame: i64,
        k: usize,
    ) {
        buf.l[..k].fill(0.0);
        buf.r[..k].fill(0.0);
        let (l, r) = (&mut buf.l[..], &mut buf.r[..]);
        self.accumulate_segments(ctx, frame, k, opts, Some(group), &mut Dest::Pair(l, r));
    }
}

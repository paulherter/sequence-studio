// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioFeeder.swift (accumulateSegments and its helpers)
//! Adds every audible segment of a block (clip volume x nest gain applied) into the destination of its top-level track.

use super::config::lock;
use super::{AudioFeeder, ClipFx, ClipFxKey, NestGroup, ceil_frame, round_frame};
use crate::audio::retimer::{AudioRetimer, ConstantRetime, RetimeSpan};
use crate::audio::time_map::AudioTimeMap;
use crate::audio::track_mix::{ChainOptions, FaderKey, Gains, Sequences, fader_chain};
use sq_audiofx::de_click::AudioDeClick;
use sq_audiofx::gain::GainMath;
use sq_core_audio::live_ducking::{DialogueSilenceProvider, LiveDucking};
use sq_core_audio::live_ducking_index::LiveDuckingIndex;
use sq_core_audio::{AudioFXStage, AudioFXStep, ClipAudioChainExt};
use sq_core_effects::evaluation::{AudioNest, AudioSegment, TimelineEvaluation};
use sq_core_model::{Clip, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use sq_media::media_error::MediaError;
use sq_media::memory_audio_source::AudioSource;
use sq_media::tone_audio_source::ToneAudioSource;
use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::Arc;
use std::sync::atomic::Ordering::Relaxed;
use std::time::{Duration, Instant};

/// What a block is mixed from.
pub(super) struct MixCtx<'a> {
    pub(super) timeline: &'a Timeline,
    pub(super) sequences: &'a Sequences,
    pub(super) duck_index: Option<&'a LiveDuckingIndex>,
}

#[derive(Clone, Copy)]
pub(super) struct AccOpts {
    /// Run each clip's audio effects on its sound first, before volume, envelopes and fader.
    pub(super) clip_effects: bool,
    /// The top-level track fader is applied after that track's effects (only its pan here).
    pub(super) fader_after_effects: bool,
}

type Slices<'a> = (&'a mut [f32], &'a mut [f32]);

/// Where the segments of a top-level track are summed.
pub(super) enum Dest<'a> {
    Pair(&'a mut [f32], &'a mut [f32]),
    /// The track buses by track id; a track unknown to the bus set (timeline raced `set_timeline`) goes to `fallback`.
    Buses {
        index: &'a HashMap<Id, usize>,
        bufs: &'a mut [super::Stereo],
        fallback: &'a mut super::Stereo,
    },
}

impl Dest<'_> {
    pub(super) fn get(&mut self, track: Id) -> Slices<'_> {
        match self {
            Dest::Pair(l, r) => (&mut **l, &mut **r),
            Dest::Buses { index, bufs, fallback } => match index.get(&track) {
                Some(&i) => (&mut bufs[i].l[..], &mut bufs[i].r[..]),
                None => (&mut fallback.l[..], &mut fallback.r[..]),
            },
        }
    }
}

const GAIN_CHUNK: i64 = 256;
/// The longest the mix thread waits for a file a worker is opening ahead; the clock is held for the first picture meanwhile.
const PREWARM_WAIT: Duration = Duration::from_millis(1500);

impl ClipFxKey {
    /// `nests`: the enclosing nest clips of `clip`, outermost first.
    pub(super) fn new(path: &[AudioNest], clip: Id) -> ClipFxKey {
        let nests = if path.is_empty() {
            0
        } else {
            let mut h = DefaultHasher::new();
            for n in path {
                n.clip.id.hash(&mut h);
            }
            h.finish()
        };
        ClipFxKey { clip, nests }
    }
}

/// The first nest clip with audio effects at or below `floor`.
fn nest_group_depth(seg: &AudioSegment, floor: usize) -> Option<usize> {
    (floor..seg.nests.len()).find(|&d| seg.nests[d].clip.has_audio_effects())
}

/// The segment's own clip: in the top timeline, or (nested) in the sequence of the innermost nest clip.
pub(super) fn segment_clip<'a>(seg: &AudioSegment, top: &'a Timeline, sequences: &'a Sequences) -> Option<&'a Clip> {
    let owner = seg.nests.last().and_then(|n| n.clip.sequence).and_then(|s| sequences.get(&s)).unwrap_or(top);
    owner.track(seg.track)?.clips().iter().find(|c| c.id == seg.clip)
}

/// Whether live ducking acts on this segment: the role rule on its top-level clip and that clip's top-level track.
fn live_ducked_walk(seg: &AudioSegment, clip: Option<&Clip>, top: &Timeline) -> bool {
    let top_clip = seg.nests.first().map(|n| &n.clip).or(clip);
    let track = top.track(seg.nests.first().map_or(seg.track, |n| n.track));
    match (top_clip, track) {
        (Some(c), Some(t)) => LiveDucking::ducks(c, t),
        _ => false,
    }
}

/// Clip volume (evaluated in the clip's own, inner time) x enclosing nest gains, at top-sequence frame `frame`.
/// `audio_gain` false: the Volume effect without the clip's Audio Gain (that one went in before the clip's effects).
/// `nest_cut`: the segment plays inside the effected nest `nests[nest_cut]`: the gains of that nest and the ones above it
/// are applied after its chain, so only the nest clip's Audio Gain (its input level) is applied here.
fn segment_gain(
    seg: &AudioSegment,
    clip: Option<&Clip>,
    frame: i64,
    rate: i64,
    audio_gain: bool,
    nest_cut: Option<usize>,
) -> f64 {
    let outer = Time::new(frame, rate);
    let mut g = seg.envelope_gain(outer);
    if let Some(cut) = nest_cut {
        let mut t = outer;
        for (j, n) in seg.nests.iter().enumerate() {
            if j == cut {
                g *= GainMath::linear_from_db(n.clip.audio_gain_db);
            } else if j > cut {
                for e in &n.envelopes {
                    g *= e.gain(t);
                }
                g *= n.clip.volume(t);
            }
            t = n.clip.source_instant(t - n.clip.start);
        }
    } else {
        g *= seg.nest_gain(outer);
    }
    if let Some(clip) = clip {
        let mut t = outer;
        for n in &seg.nests {
            t = n.clip.source_instant(t - n.clip.start);
        }
        g *= if audio_gain { clip.volume(t) } else { clip.animation.volume.value_at_local(t - clip.start).max(0.0) };
    }
    g
}

/// Extra linear gain from `from` (block start) to `to` (block end), exact per sample.
#[derive(Clone, Copy)]
pub(super) struct Ramp {
    pub(super) from: f32,
    pub(super) to: f32,
    pub(super) offset: usize,
    pub(super) total: usize,
}

/// Adds `src * gain` into `dst`. The gain is linear between points on an absolute 256-frame grid, so any split of the
/// timeline gives identical samples; `animated == false` evaluates it once.
pub(super) fn accumulate(
    src: &[f32],
    dst: &mut [f32],
    first_frame: i64,
    animated: bool,
    gain: &dyn Fn(i64) -> f64,
    ramp: Option<Ramp>,
) {
    let count = src.len().min(dst.len());
    let r = |i: usize| -> f32 {
        match ramp {
            None => 1.0,
            Some(p) => p.from + (p.to - p.from) * (p.offset + i) as f32 / p.total as f32,
        }
    };
    if !animated {
        let g = gain(first_frame) as f32;
        for i in 0..count {
            dst[i] += src[i] * g;
        }
        return;
    }
    let mut i = 0;
    while i < count {
        let f = first_frame + i as i64;
        let base = f - (f % GAIN_CHUNK + GAIN_CHUNK) % GAIN_CHUNK;
        let n = ((base + GAIN_CHUNK - f) as usize).min(count - i);
        let g0 = gain(base) as f32;
        let g1 = gain(base + GAIN_CHUNK) as f32;
        for k in 0..n {
            let w = (f + k as i64 - base) as f32 / GAIN_CHUNK as f32;
            dst[i + k] += src[i + k] * (g0 + (g1 - g0) * w) * r(i + k);
        }
        i += n;
    }
}

/// Effects that count samples (Disguise Voice runs its curves on an absolute sample grid) get the position of the block
/// in the stream they actually hear. In place.
pub(super) fn place(steps: &mut [AudioFXStep], at: Time) {
    for s in steps {
        if let AudioFXStage::DisguiseVoice { voice, .. } = s.stage {
            s.stage = AudioFXStage::DisguiseVoice { voice, at };
        }
    }
}

/// How the samples of one segment are read: plain, retimed at a constant speed, or through a time map.
pub(super) struct ReadPlan<'a> {
    pub(super) seg: &'a AudioSegment,
    pub(super) source: &'a dyn AudioSource,
    pub(super) time_map: Option<&'a AudioTimeMap>,
    pub(super) retimed: bool,
    pub(super) f0: i64,
    pub(super) rate: i64,
    pub(super) src_start: i64,
}

impl ReadPlan<'_> {
    /// Reads `into.len()` samples of channel `ch`. `ahead` reads the output that many samples later (the retimer renders
    /// are stateless functions of their first output frame); `clamp` zero-fills past the clip's media end. The clip
    /// effects' latency is compensated by reading ahead.
    pub(super) fn read(
        &self,
        retimer: &mut AudioRetimer,
        ch: usize,
        into: &mut [f32],
        ahead: usize,
        clamp: bool,
    ) -> Result<(), MediaError> {
        let (seg, rate, count) = (self.seg, self.rate, into.len());
        let mut read = |from: i64, buf: &mut [f32]| self.source.read(from, buf, ch);
        let span = |grid: i64| RetimeSpan {
            src_start: round_frame(seg.source.start, rate),
            src_end: round_frame(seg.source.end(), rate),
            first_output: self.f0 - grid + ahead as i64,
            lead: (grid - ceil_frame(seg.timeline.start, rate)).max(0),
        };
        if let Some(tm) = self.time_map {
            let rate_d = rate as f64;
            let grid = ceil_frame(seg.clip_start, rate);
            let keeps = seg.keeps_pitch && seg.nests.iter().all(|n| n.clip.keeps_pitch);
            retimer.render_mapped(&mut read, &|o| tm.position((grid + o) as f64, rate_d), keeps, span(grid), into)
        } else if self.retimed {
            let a = seg.timeline.start - seg.clip_start;
            let origin_t = if seg.reversed {
                seg.source_start + seg.speed.scale(a)
            } else {
                seg.source_start - seg.speed.scale(a)
            };
            let origin = origin_t.value() as f64 / origin_t.timescale() as f64 * rate as f64;
            let speed = seg.speed.num() as f64 / seg.speed.den() as f64;
            let retime = ConstantRetime { origin, speed, reversed: seg.reversed, keeps_pitch: seg.keeps_pitch };
            retimer.render(&mut read, retime, span(ceil_frame(seg.clip_start, rate)), into)
        } else {
            let from = self.src_start + ahead as i64;
            let avail = if ahead == 0 && !clamp {
                count
            } else {
                (round_frame(seg.source.end(), rate) - from).clamp(0, count as i64) as usize
            };
            let got = if avail > 0 { self.source.read(from, &mut into[..avail], ch)? } else { 0 };
            into[got.min(count)..].fill(0.0);
            Ok(())
        }
    }
}

impl AudioFeeder {
    /// Drops every cached source and remembered open failure the control side asked for.
    fn apply_stale_media(&mut self) {
        let (all, ids) = {
            let mut c = lock(&self.shared.control);
            (std::mem::take(&mut c.stale_all), std::mem::take(&mut c.stale_media))
        };
        if all {
            self.sources.clear();
            self.time_maps.clear();
            self.failed_opens.clear();
            self.logged_failures.clear();
        } else if !ids.is_empty() {
            for id in ids {
                self.sources.remove(&id);
                self.failed_opens.remove(&id);
                self.logged_failures.remove(&id);
            }
            self.time_maps.clear();
        }
    }

    /// A file a worker is already opening ahead is waited for (at most `PREWARM_WAIT`), not opened a second time here: the
    /// second open ran on the mix thread and held every track's block while a big camera file opened.
    fn wait_for_prewarm(&self, media: Id) {
        let deadline = Instant::now() + PREWARM_WAIT;
        let mut flight = lock(&self.shared.prewarm_in_flight);
        while flight.contains(&media) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            flight = self.shared.prewarm_landed.wait_timeout(flight, left).unwrap_or_else(|e| e.into_inner()).0;
        }
    }

    /// The cached source of `media`, opening it when needed. A failed open is remembered (retried after
    /// `open_retry_interval` or `media_changed`) and logged once, so a missing file does not hit the disk on every block.
    fn source_for(&mut self, media: Id) -> Option<Arc<dyn AudioSource>> {
        if let Some(s) = self.sources.get(&media) {
            return Some(Arc::clone(s));
        }
        if let Some(tone) = ToneAudioSource::source(media, super::SAMPLE_RATE) {
            let s: Arc<dyn AudioSource> = Arc::new(tone);
            self.sources.insert(media, Arc::clone(&s));
            return Some(s);
        }
        if self.failed_opens.get(&media).is_some_and(|t| t.elapsed() < self.open_retry_interval) {
            return None;
        }
        self.wait_for_prewarm(media);
        let parked = lock(&self.shared.prewarmed).remove(&media);
        if let Some(s) = parked {
            self.sources.insert(media, Arc::clone(&s));
            self.failed_opens.remove(&media);
            return Some(s);
        }
        let opened = Instant::now();
        let result = (self.resolver)(media);
        sq_core_time::milestones::note(&format!(
            "play: audio source {media} opened in {:.1} ms (ok {})",
            opened.elapsed().as_secs_f64() * 1e3,
            result.is_ok()
        ));
        match result {
            Ok(s) => {
                self.sources.insert(media, Arc::clone(&s));
                self.failed_opens.remove(&media);
                Some(s)
            }
            Err(e) => {
                self.failed_opens.insert(media, Instant::now());
                if self.logged_failures.insert(media) {
                    sq_os::errln!("AudioFeeder: cannot open audio of media {media}: {e}");
                }
                None
            }
        }
    }

    fn cached_time_map(&mut self, chain: &[&Clip]) -> Arc<AudioTimeMap> {
        let key: Vec<Id> = chain.iter().map(|c| c.id).collect();
        if let Some((stored, map)) = self.time_maps.get(&key)
            && stored.len() == chain.len()
            && stored.iter().zip(chain).all(|(a, b)| a == *b)
        {
            return Arc::clone(map);
        }
        if self.time_maps.len() > 64 {
            self.time_maps.clear();
        }
        let m = Arc::new(AudioTimeMap::new(chain.iter().copied()));
        self.time_maps.insert(key, (chain.iter().map(|c| (*c).clone()).collect(), Arc::clone(&m)));
        m
    }

    /// The effect chain of the segment's clip (built, or rebuilt when its effect list changed); `None` without audio
    /// effects or when it cannot be built (the caller then renders silence).
    fn clip_chain(&mut self, seg: &AudioSegment, clip: &Clip) -> Option<ClipFxKey> {
        if !clip.has_audio_effects() {
            return None;
        }
        let key = ClipFxKey::new(&seg.nests, clip.id);
        if !self.clip_fx.get(&key).is_some_and(|old| clip.audio_fx_layout_matches(&old.chain.layout)) {
            let chain = (self.make_chain)(&clip.audio_fx_layout(), self.block_frames).ok()?;
            self.clip_fx.insert(key, ClipFx::new(chain));
        }
        if let Some(fx) = self.clip_fx.get_mut(&key) {
            fx.serial = self.clip_fx_serial;
        }
        Some(key)
    }

    /// The Preferences/project duck for this block: its parameters and the expanded dialogue ranges, `None` when off or no
    /// dialogue is near. The expanded buffer is taken from the per-level pool and goes back at the end of the pass.
    fn block_duck(
        &mut self,
        ctx: &MixCtx,
        range: TimeRange,
        group: Option<NestGroup>,
    ) -> Option<(LiveDucking, Vec<TimeRange>, usize)> {
        let d = self.shared.effective_live_ducking()?;
        let pad = d.reach();
        let window = TimeRange::new(range.start - pad, range.duration + pad + pad);
        let silences = lock(&self.shared.silences).clone();
        let silences: Option<&dyn DialogueSilenceProvider> =
            silences.as_deref().map(|s| s as &dyn DialogueSilenceProvider);
        if let Some(index) = ctx.duck_index {
            index.dialogue_ranges_silences(ctx.timeline, &window, silences, &mut self.duck_ranges);
            if self.duck_ranges.is_empty() {
                return None;
            }
            let level = group.map_or(0, |g| g.depth + 1); // outer pass 0, a nest pass below it its own
            while self.duck_expanded.len() <= level {
                self.duck_expanded.push(Vec::new());
            }
            let mut out = std::mem::take(&mut self.duck_expanded[level]);
            d.expanded_into(&self.duck_ranges, &mut out);
            Some((d, out, level))
        } else {
            let ranges = LiveDucking::dialogue_ranges(ctx.timeline, Some(&window), silences);
            if ranges.is_empty() {
                return None;
            }
            let expanded = d.expanded(&ranges);
            Some((d, expanded, usize::MAX))
        }
    }

    /// Adds every audible segment of `[start_frame, start_frame + count)` into the destination of its top-level track.
    pub(super) fn accumulate_segments(
        &mut self,
        ctx: &MixCtx,
        start_frame: i64,
        count: usize,
        opts: AccOpts,
        group: Option<NestGroup>,
        dest: &mut Dest,
    ) {
        assert!(count <= self.block_frames);
        let rate = super::SAMPLE_RATE;
        let range = TimeRange::new(Time::new(start_frame, rate), Time::new(count as i64, rate));
        if group.is_none() {
            self.apply_stale_media();
        }
        let mut end_state: HashMap<FaderKey, Gains> = HashMap::new();
        let mut groups: Vec<(NestGroup, AudioSegment)> = Vec::new(); // nests with effects, rendered after the plain segments
        let fade = self.shared.declick.load(Relaxed); // one atomic read per block, not per channel
        // N8 live ducking: Music-role clips follow the dialogue as the timeline is right now; applied to the dry segment
        // gain in timeline order, so it is delay-compensated with its bus and the same for forward, reverse, scrub, export.
        let duck = self.block_duck(ctx, range, group);
        let owner = opts.clip_effects && group.is_none(); // the outer pass owns the chain bookkeeping, a nest pass only reads
        if owner {
            self.clip_fx_serial = self.clip_fx_serial.wrapping_add(1);
        }
        let lookup = |id: Id| ctx.sequences.get(&id);
        for seg in ctx.timeline.audio_segments(range, &lookup) {
            let f0 = start_frame.max(ceil_frame(seg.timeline.start, rate));
            let f1 = (start_frame + count as i64).min(ceil_frame(seg.timeline.end(), rate));
            // A nest pass takes only what plays inside its nest clip; a further effected nest below it is a group again.
            if let Some(g) = group
                && !(seg.nests.len() > g.depth
                    && ClipFxKey::new(&seg.nests[..g.depth], seg.nests[g.depth].clip.id) == g.key)
            {
                continue;
            }
            if opts.clip_effects
                && let Some(d) = nest_group_depth(&seg, group.map_or(0, |g| g.depth + 1))
            {
                let key = ClipFxKey::new(&seg.nests[..d], seg.nests[d].clip.id);
                if !groups.iter().any(|g| g.0.key == key) {
                    groups.push((NestGroup { key, depth: d }, seg));
                }
                continue;
            }
            if f1 <= f0 {
                continue;
            }
            let n = (f1 - f0) as usize;
            let clip = segment_clip(&seg, ctx.timeline, ctx.sequences);
            // A speed track (or any clip inside a retimed nested clip) goes through the time map; constant clips keep their
            // exact path.
            let ducked = duck.is_some()
                && match ctx.duck_index {
                    Some(i) => i.ducks(seg.nests.first().map_or(seg.clip, |n| n.clip.id)),
                    None => live_ducked_walk(&seg, clip, ctx.timeline),
                };
            let mapped = clip.is_some_and(|c| c.speed_keys.is_some())
                || seg
                    .nests
                    .iter()
                    .any(|n| n.clip.speed_keys.is_some() || !n.clip.speed.is_normal() || n.clip.reversed);
            let time_map = if mapped {
                let mut chain: Vec<&Clip> = seg.nests.iter().map(|n| &n.clip).collect();
                chain.extend(clip);
                Some(self.cached_time_map(&chain))
            } else {
                None
            };
            let retimed = mapped || !seg.speed.is_normal() || seg.reversed;
            let src_start = if retimed {
                0
            } else {
                round_frame(seg.source_start + (Time::new(f0, rate) - seg.timeline.start), rate)
            };
            let dst_off = (f0 - start_frame) as usize;
            let animated = ducked
                || clip.is_some_and(|c| c.animation.volume.is_animated())
                || seg.nests.iter().any(|n| n.clip.animation.volume.is_animated())
                || !seg.envelopes.is_empty()
                || seg.nests.iter().any(|n| !n.envelopes.is_empty());
            // AUDIO-FX: a clip running through its effect chain gets its Audio Gain before the chain (input level), so the
            // volume applied here is the Volume effect alone.
            let fx_key = if opts.clip_effects { clip.and_then(|c| self.clip_chain(&seg, c)) } else { None };
            // A chain that could not be built must not let the clip play dry: Disguise Voice protects a speaker.
            if opts.clip_effects && fx_key.is_none() && clip.is_some_and(|c| c.has_audio_effects()) {
                continue;
            }
            let nest_cut = group.map(|g| g.depth);
            let audio_gain = fx_key.is_none();
            let gain = |frame: i64| -> f64 {
                let g = segment_gain(&seg, clip, frame, rate, audio_gain, nest_cut);
                match &duck {
                    Some((d, r, _)) if ducked => g * f64::from(d.gain_expanded(Time::new(frame, rate), r)),
                    _ => g,
                }
            };
            let Some(source) = self.source_for(seg.media) else {
                self.shared.failed_reads.fetch_add(1, Relaxed);
                continue;
            };
            let (dl, dr) = dest.get(seg.nests.first().map_or(seg.track, |n| n.track));
            // Inside an effected nest only the faders below the nest clip apply here (no ramp state).
            let fader = fader_chain(
                &seg,
                ctx.timeline,
                ctx.sequences,
                source.is_mono(),
                ChainOptions { below: nest_cut, skip_top: opts.fader_after_effects },
                Time::new(f0, rate),
            );
            let bus_key = FaderKey { track: seg.nests.first().map_or(seg.track, |n| n.track), mono: source.is_mono() };
            let previous =
                if group.is_none() { self.fader_state.get(&bus_key).copied().unwrap_or(fader) } else { fader };
            if group.is_none() {
                end_state.insert(bus_key, fader);
            }
            let plan =
                ReadPlan { seg: &seg, source: &*source, time_map: time_map.as_deref(), retimed, f0, rate, src_start };
            // AUDIO-FX: both channels through the clip's effect chain first (effects, then Volume).
            let mut processed = false;
            if let (Some(clip), Some(key)) = (clip, fx_key)
                && let Some(fx) = self.clip_fx.get_mut(&key)
            {
                let lat = fx.chain.latency_samples;
                fx_steps(&seg, clip, f0, n, rate, fx);
                // Where this piece's samples lie in the stream the chain hears.
                let stream = Time::new(f0, rate) - seg.nests.first().map_or(clip.start, |n| n.clip.start);
                place(&mut fx.end_steps, stream + Time::new(n as i64, rate));
                let input = GainMath::linear_from_db(clip.audio_gain_db) as f32; // Audio Gain: before the effects
                let (retimer, fx_l, fx_r) = (&mut self.retimer, &mut self.fx_l, &mut self.fx_r);
                let mut read = |ahead: usize, k: usize, fx_l: &mut [f32], fx_r: &mut [f32]| -> Result<(), MediaError> {
                    plan.read(retimer, 0, &mut fx_l[..k], ahead, true)?;
                    plan.read(retimer, 1, &mut fx_r[..k], ahead, true)?;
                    if input != 1.0 {
                        for i in 0..k {
                            fx_l[i] *= input;
                            fx_r[i] *= input;
                        }
                    }
                    Ok(())
                };
                let result = (|| -> Result<(), MediaError> {
                    if fx.next_frame != f0 {
                        fx.chain.reset();
                        let mut primed = 0;
                        while primed < lat {
                            // Feed the denoiser the `lat` samples whose output lands before f0.
                            let k = self.block_frames.min(lat - primed);
                            read(primed, k, fx_l, fx_r)?;
                            place(&mut fx.steps, stream + Time::new(primed as i64 - lat as i64, rate));
                            fx.chain.process(&mut [&mut fx_l[..k], &mut fx_r[..k]], k, &fx.steps, None);
                            primed += k;
                        }
                    }
                    read(lat, n, fx_l, fx_r)?;
                    place(&mut fx.steps, stream);
                    fx.chain.process(&mut [&mut fx_l[..n], &mut fx_r[..n]], n, &fx.steps, Some(&fx.end_steps));
                    fx.next_frame = f0 + n as i64;
                    Ok(())
                })();
                match result {
                    Ok(()) => processed = true,
                    Err(_) => {
                        self.shared.failed_reads.fetch_add(1, Relaxed);
                        fx.next_frame = i64::MIN;
                        continue;
                    }
                }
            }
            for (ch, dst) in [dl, dr].into_iter().enumerate() {
                let src: &mut [f32] = if processed {
                    if ch == 0 { &mut self.fx_l[..n] } else { &mut self.fx_r[..n] }
                } else {
                    if plan.read(&mut self.retimer, ch, &mut self.scratch[..n], 0, false).is_err() {
                        self.shared.failed_reads.fetch_add(1, Relaxed);
                        continue;
                    }
                    &mut self.scratch[..n]
                };
                // Short fade at both edges of the clip's audible extent (not the block piece; after retiming).
                AudioDeClick::apply(
                    src,
                    f0,
                    ceil_frame(seg.extent.start, rate),
                    ceil_frame(seg.extent.end(), rate),
                    fade,
                );
                // Track fader x pan; a change since the last block ramps across this block.
                let (side, was) = if ch == 0 { (fader.0, previous.0) } else { (fader.1, previous.1) };
                let dst = &mut dst[dst_off..dst_off + n];
                if was != side {
                    let ramp = Ramp { from: was as f32, to: side as f32, offset: dst_off, total: count };
                    accumulate(src, dst, f0, true, &gain, Some(ramp));
                } else if side == 1.0 {
                    accumulate(src, dst, f0, animated, &gain, None);
                } else {
                    accumulate(src, dst, f0, animated, &|f| gain(f) * side, None);
                }
            }
        }
        for (g, seg) in &groups {
            self.render_nest(ctx, *g, group, seg, start_frame, count, &mut end_state, opts.fader_after_effects, dest);
        }
        for (k, v) in end_state {
            self.fader_state.insert(k, v);
        }
        if let Some((_, ranges, level)) = duck
            && level != usize::MAX
        {
            self.duck_expanded[level] = ranges; // the buffer goes back to the pool
        }
        if owner && self.clip_fx.values().any(|f| f.serial != self.clip_fx_serial) {
            let serial = self.clip_fx_serial;
            self.clip_fx.retain(|_, f| f.serial == serial); // drop clips that left
        }
    }
}

/// The clip's effect values at the block piece's first frame and one piece later (clip-local time, through enclosing
/// nests), into the chain's step arrays.
fn fx_steps(seg: &AudioSegment, clip: &Clip, f0: i64, count: usize, rate: i64, fx: &mut ClipFx) {
    let local = |frame: i64| -> Time {
        let mut t = Time::new(frame, rate);
        for n in &seg.nests {
            t = n.clip.source_instant(t - n.clip.start);
        }
        t - clip.start
    };
    let scalar = |e: &sq_core_model::ClipEffect, k: &str, at: Time| e.scalar(k, at);
    fx.steps = clip.audio_fx_steps(local(f0), &scalar);
    fx.end_steps = clip.audio_fx_steps(local(f0 + count as i64), &scalar);
}

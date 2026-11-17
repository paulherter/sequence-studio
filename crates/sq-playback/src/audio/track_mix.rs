// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioFeeder+TrackMix.swift
//! Track fader, pan and role helpers of the feeder: the single place the track mix is read, so playback, scrubbing and
//! export cannot differ.

use sq_audiofx::presets::TrackAudioPreset;
use sq_audiofx::track_preset::TrackPresetExt;
use sq_core_effects::evaluation::AudioSegment;
use sq_core_model::{AudioTag, Timeline, Track, TrackKind, TrackPan};
use sq_core_time::{Id, Time};
use std::collections::HashMap;

/// Per-channel linear gain.
pub type Gains = (f64, f64);

/// The nested sequences by id.
pub type Sequences = HashMap<Id, Timeline>;

/// Fader and pan of the top-level track `id` as per-channel linear gain: (1, 1) for an untouched or unknown track.
pub fn track_fader(timeline: &Timeline, id: Id, mono_source: bool) -> Gains {
    match timeline.track(id) {
        Some(t) if t.volume_db != 0.0 || t.pan != 0.0 => TrackPan::channel_gains(t.volume_db, t.pan, !mono_source),
        _ => (1.0, 1.0),
    }
}

/// Pan only (fader at unity) of the top-level track: applied per segment with the source's own law, before the track FX.
pub fn track_pan_only(timeline: &Timeline, id: Id, mono_source: bool) -> Gains {
    match timeline.track(id) {
        Some(t) if t.pan != 0.0 => TrackPan::channel_gains(0.0, t.pan, !mono_source),
        _ => (1.0, 1.0),
    }
}

/// Fader gain only (linear, no pan) of the top-level track: applied after the track FX.
pub fn track_fader_gain(timeline: &Timeline, id: Id) -> f64 {
    match timeline.track(id) {
        Some(t) if t.volume_db != 0.0 => TrackPan::linear(t.volume_db),
        _ => 1.0,
    }
}

/// Which nest tracks `fader_chain` multiplies in.
#[derive(Clone, Copy, Debug, Default)]
pub struct ChainOptions {
    /// Only the tracks inside the nest `seg.nests[below]` (the ones that mix before that nest clip's effects).
    pub below: Option<usize>,
    /// The top-level track contributes its pan only; its fader gain is applied after that track's effects.
    pub skip_top: bool,
}

/// Fader and pan of every track the segment passes through, inner mix first, then the enclosing nest clips' tracks
/// outwards: the product of their per-channel gains. A segment of the top sequence has just its own track.
// Same as Swift (AudioFeeder+TrackMix.swift:47): a keyed nested Sequence Volume is read at the segment start (`at`), not per sample; upgrade when keyed nested
// levels need sample accuracy.
pub fn fader_chain(
    seg: &AudioSegment,
    top: &Timeline,
    sequences: &Sequences,
    mono_source: bool,
    opts: ChainOptions,
    at: Time,
) -> Gains {
    let (mut l, mut r) = (1.0, 1.0);
    let mut t = at;
    let mut owner: Option<&Timeline> = Some(top);
    for (j, n) in seg.nests.iter().enumerate() {
        if let Some(o) = owner
            && opts.below.is_none_or(|b| j > b)
        {
            let f = if opts.skip_top && j == 0 {
                track_pan_only(o, n.track, mono_source)
            } else {
                track_fader(o, n.track, mono_source)
            };
            l *= f.0;
            r *= f.1;
        }
        owner = n.clip.sequence.and_then(|s| sequences.get(&s));
        t = n.clip.source_instant(t - n.clip.start);
        if opts.below.is_none_or(|b| j >= b)
            && let Some(g) = owner.map(|o| o.master_gain_at(t))
            && g != 1.0
        {
            l *= g;
            r *= g;
        }
    }
    if let Some(o) = owner {
        let f = if opts.skip_top && seg.nests.is_empty() {
            track_pan_only(o, seg.track, mono_source)
        } else {
            track_fader(o, seg.track, mono_source)
        };
        l *= f.0;
        r *= f.1;
    }
    (l, r)
}

/// Faders of the tracks holding `seg.nests[0..=depth]` (the effected nest's summed, stereo output passes them).
/// `above`: the nest plays inside the effected nest `seg.nests[above]`: only the tracks and Sequence Volumes between the
/// two (the ones that mix before that outer nest clip's effects).
pub fn nest_fader(
    seg: &AudioSegment,
    depth: usize,
    above: Option<usize>,
    top: &Timeline,
    sequences: &Sequences,
    skip_top: bool,
    at: Time,
) -> Gains {
    let (mut l, mut r) = (1.0, 1.0);
    let mut t = at;
    let mut owner: Option<&Timeline> = Some(top);
    for (j, n) in seg.nests[..=depth].iter().enumerate() {
        if let Some(o) = owner
            && above.is_none_or(|a| j > a)
        {
            let f = if skip_top && j == 0 { track_pan_only(o, n.track, false) } else { track_fader(o, n.track, false) };
            l *= f.0;
            r *= f.1;
        }
        owner = n.clip.sequence.and_then(|s| sequences.get(&s));
        t = n.clip.source_instant(t - n.clip.start);
        // Sequence Volume of the enclosing nested sequences (nest `depth`'s own one ran before its effects).
        if j < depth
            && above.is_none_or(|a| j >= a)
            && let Some(g) = owner.map(|o| o.master_gain_at(t))
            && g != 1.0
        {
            l *= g;
            r *= g;
        }
    }
    (l, r)
}

/// Key of the remembered fader gain of one bus: the top-level track, and whether the segment's media is mono (the pan law
/// differs).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FaderKey {
    pub track: Id,
    pub mono: bool,
}

/// The three roles, in the order of the role buses.
pub const AUDIO_TAGS: [AudioTag; 3] = [AudioTag::Dialogue, AudioTag::Music, AudioTag::Sfx];

/// Track roles of a sequence.
pub fn roles_of(t: &Timeline) -> HashMap<Id, AudioTag> {
    t.tracks
        .iter()
        .filter(|tr: &&Track| tr.kind == TrackKind::Audio)
        .filter_map(|tr| tr.audio_role.map(|r| (tr.id, r)))
        .collect()
}

/// The tweaks every audio track stores in the project. Playback, scrubbing and export all read them here.
pub fn presets_of(t: &Timeline) -> HashMap<Id, TrackAudioPreset> {
    t.tracks
        .iter()
        .filter(|tr: &&Track| tr.kind == TrackKind::Audio)
        .filter_map(|tr| tr.audio_preset().map(|p| (tr.id, p)))
        .collect()
}

/// Master limiter ceiling of a sequence: its delivery target's true-peak ceiling, `None` without a target.
pub fn limiter_ceiling_of(t: &Timeline) -> Option<f64> {
    t.delivery_target.as_ref().map(|d| d.true_peak_db)
}

/// The preset a track's FX runs: the explicit one, else its role's voiced preset, else none.
pub fn effective_preset(
    presets: &HashMap<Id, TrackAudioPreset>,
    roles: &HashMap<Id, AudioTag>,
    id: Id,
) -> Option<TrackAudioPreset> {
    presets.get(&id).cloned().or_else(|| roles.get(&id).map(|r| TrackAudioPreset::for_role(*r)))
}

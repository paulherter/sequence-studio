// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Model.swift (types and the accessors every task uses; the rest of the Clip and Track logic: task M-1)

use crate::CowVec;
use crate::UnknownKeys;
use crate::media_info::lenient;
use crate::serde_defaults::{frame_sampling, normal_blend, normal_speed, yes};
use crate::{
    AngleChoice, AnimationZones, AudioTag, BakedEffect, BlendMode, ClipAnimation, ClipAttachment, ClipEdge, ClipEffect,
    ClipFootageColor, ClipMask, ClipSpeed, EditError, FadeMarks, GraphicsDocument, LabelColor, Marker, SpeedKeys,
    TemplateSlot, TimeInterpolation, Transition, VariantOverrides,
};
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// Kind of a track and of the clips on it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TrackKind {
    /// Picture.
    Video,
    /// Sound.
    Audio,
}

/// What a clip plays: imported media, another sequence of the project (nested sequence), or a generator.
#[derive(Clone, Debug, PartialEq)]
pub enum ClipSource {
    /// Imported media item.
    Media(Id),
    /// A nested sequence (`Timeline` id).
    Sequence(Id),
    /// A generator (text layer, solid, ...).
    Generator(GeneratorRef),
}

/// A clip that renders itself instead of playing media. The core treats `payload` as opaque bytes; the owner of
/// `kind` (e.g. the text crate for "text") encodes and decodes it. Compare payloads by decoded content.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneratorRef {
    /// Which generator renders this clip, e.g. "text".
    pub kind: String,
    /// Opaque, versioned content (base64 in JSON, like Swift `Data`).
    #[serde(with = "sq_core_time::base64")]
    pub payload: Vec<u8>,
    /// Version of the payload's own format, owned by the generator.
    pub payload_version: i64,
}

/// One clip on a track. Times of keys are clip-local (relative to `start`).
///
/// Swift's decoder also folds a legacy corner radius into a Rounded Corners effect (v8 -> v9); reading a `Track` does that
/// (`adopt_legacy_corner_radius`). The v26 -> v27 fold of a grade stored in `color` into Color effects runs as a migration step (sq-core-file `migrate_v26_to_v27`; reading keeps it in `footage_color.legacy_effects`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clip {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Imported media item; a nested clip repeats `sequence`, a generator clip its own id.
    pub media: Id,
    /// Video or audio.
    pub kind: TrackKind,
    /// Portion of the media used.
    pub source: TimeRange,
    /// Position on the track.
    pub start: Time,
    /// Linked A/V partners share a link id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<Id>,
    /// Bundle (v57): clips with the same id select, move, trim and delete together. Independent of `link`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle: Option<Id>,
    /// Length of the whole media, when known; `None` = unbounded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub media_duration: Option<Time>,
    /// Animatable transform, opacity and volume.
    #[serde(default)]
    pub animation: ClipAnimation,
    /// The sequence a nested clip plays.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sequence: Option<Id>,
    /// Set for a generator clip (text layer); video tracks only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generator: Option<GeneratorRef>,
    /// Footage interpretation (source override, embedded LUT toggle); the grade lives in `effects`.
    #[serde(rename = "color", default)]
    pub footage_color: ClipFootageColor,
    /// Label color; `None` = inherit from the media or sequence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<LabelColor>,
    /// A still image: free trims in both directions.
    #[serde(default)]
    pub is_still: bool,
    /// Applied effects (v9), in render order.
    #[serde(default)]
    pub effects: Vec<ClipEffect>,
    /// Audio Gain in dB on top of the Volume level.
    #[serde(rename = "audioGainDB", default)]
    pub audio_gain_db: f64,
    /// Dialogue / Music / SFX (v20); `None` = untagged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_tag: Option<AudioTag>,
    /// Volume keys the last Auto Duck run generated (v20).
    #[serde(rename = "duckKeyIDs", default)]
    pub duck_key_ids: Vec<Id>,
    /// Volume keys the audio fade handles created (v20).
    #[serde(default)]
    pub audio_fades: FadeMarks,
    /// Constant speed (v13).
    #[serde(default = "normal_speed")]
    pub speed: ClipSpeed,
    /// Plays the source range backwards (v13).
    #[serde(default)]
    pub reversed: bool,
    /// Audio keeps its pitch when the speed is not 100 %.
    #[serde(default = "yes")]
    pub keeps_pitch: bool,
    /// Time remapping (v23); when set it is the only time mapping.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed_keys: Option<SpeedKeys>,
    /// How frames between two source frames are made when slowed down (v23).
    #[serde(default = "frame_sampling")]
    pub time_interpolation: TimeInterpolation,
    /// Opacity > Blend Mode (v22).
    #[serde(default = "normal_blend")]
    pub blend_mode: BlendMode,
    /// Frame hold (v22): the one source frame shown for the whole clip.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hold_frame: Option<Time>,
    /// fx toggle of the fixed Motion section (v22).
    #[serde(default = "yes")]
    pub motion_enabled: bool,
    /// fx toggle of the fixed Opacity section (v22).
    #[serde(default = "yes")]
    pub opacity_enabled: bool,
    /// Clip > Enable (v18): a disabled clip is skipped by picture and mix.
    #[serde(default = "yes")]
    pub is_enabled: bool,
    /// Per-variant overrides (v26), `None` when empty.
    #[doc(hidden)]
    #[serde(rename = "variantOverrides", default, skip_serializing_if = "Option::is_none")]
    pub variant_store: Option<VariantOverrides>,
    /// Effects baked by Convert to Keyframes (v29), `None` when empty.
    #[doc(hidden)]
    #[serde(rename = "bakedEffects", default, skip_serializing_if = "Option::is_none")]
    pub baked_store: Option<Vec<BakedEffect>>,
    /// Masks on the picture (v32), `None` when empty.
    #[doc(hidden)]
    #[serde(rename = "masks", default, skip_serializing_if = "Option::is_none")]
    pub mask_store: Option<Vec<ClipMask>>,
    /// v9 -> v10 scale step still owed; `None` when nothing is owed.
    #[doc(hidden)]
    #[serde(rename = "pendingSourcePixelScale", default, skip_serializing_if = "Option::is_none")]
    pub pending_scale_store: Option<bool>,
    /// Layers of a graphics clip (v42), `None` for every other clip.
    #[doc(hidden)]
    #[serde(rename = "graphics", default, skip_serializing_if = "Option::is_none")]
    pub graphics_store: Option<GraphicsDocument>,
    /// Clips with the same id share their base grade (v45).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grade_link: Option<Id>,
    /// "Linked" switched off in the color target bar (v47); `None` = linked.
    #[doc(hidden)]
    #[serde(rename = "gradeIndependent", default, skip_serializing_if = "Option::is_none")]
    pub grade_independent_store: Option<bool>,
    /// Adjustment Layer follows the sequence end (v49); `None` = off.
    #[doc(hidden)]
    #[serde(rename = "extendToEnd", default, skip_serializing_if = "Option::is_none")]
    pub extends_to_end_store: Option<bool>,
    /// Animation zones (v58): intro and outro keep their length on trim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zones: Option<AnimationZones>,
    /// Slots of an applied title template (v58).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub template_slots: Option<Vec<TemplateSlot>>,
    /// Clip markers (v60), at source time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub markers: Option<Vec<Marker>>,
    /// Fast Cut attachment to a main-track clip (v67).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachment: Option<ClipAttachment>,
    /// Angles clip (v71): which angle this piece plays.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub angle: Option<AngleChoice>,
    /// Keys of a newer file that this build does not know; kept and written back.
    #[serde(flatten, default, skip_serializing_if = "UnknownKeys::is_empty")]
    pub unknown: UnknownKeys,
}

/// One track of a timeline.
///
/// Reading repairs what every edit relies on: zero-length clips (and the transitions anchored to them) are dropped, clips
/// are sorted by start, and overlapping clips are an error. `liveDuckingOptOut` reads leniently.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", try_from = "TrackWire")]
pub struct Track {
    /// Identity.
    pub id: Id,
    /// Video or audio.
    pub kind: TrackKind,
    /// Locked tracks refuse edits and never shift.
    pub is_locked: bool,
    /// Sync-locked tracks shift together with ripple edits made on other tracks.
    pub sync_lock: bool,
    /// Sorted by start, never overlapping; read with `clips()`.
    clips: CowVec<Clip>,
    /// Shown name.
    pub name: String,
    /// Eye toggle (video).
    pub is_visible: bool,
    /// Muted audio tracks are silent.
    pub is_muted: bool,
    /// Solo silences every non-solo audio track.
    pub is_solo: bool,
    /// Receives inserts and overwrites from the source monitor.
    pub is_targeted: bool,
    /// Transitions at cuts and clip edges (v17), anchored to clip ids.
    pub transitions: Vec<Transition>,
    /// Row height in points (UI hint).
    pub height: f64,
    /// Audio fader in dB (v20).
    #[serde(rename = "volumeDB")]
    pub volume_db: f64,
    /// Pan -1 (left) ... +1 (right).
    pub pan: f64,
    /// Dialogue / Music / SFX; `None` = none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_role: Option<AudioTag>,
    /// Live ducking opt-out (v43), stored only when set.
    #[doc(hidden)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub live_ducking_opt_out: Option<bool>,
    /// Integrated loudness target (LUFS) the track's Loudness row chose; `None` = the role's default. Stored only when set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub loudness_target_lufs: Option<f64>,
    /// The track's audio chain tweaks (compressor, EQ, gate, noise reduction, warmth) as the `TrackAudioPreset` JSON of
    /// `sq-audiofx`; `None` = the role's voiced preset. Stored only when set. Read and written through
    /// `sq_audiofx::track_preset::TrackPresetExt`.
    // shortcut: opaque JSON because sq-audiofx depends on this crate; upgrade when the preset types move into the model.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_preset: Option<serde_json::Value>,
    /// Keys of a newer file that this build does not know; kept and written back.
    #[serde(flatten, default, skip_serializing_if = "UnknownKeys::is_empty")]
    pub unknown: UnknownKeys,
}

/// `Track` as stored: missing keys take the defaults, then `Track::try_from` repairs the clips.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TrackWire {
    id: Id,
    kind: TrackKind,
    #[serde(default)]
    is_locked: bool,
    #[serde(default = "yes")]
    sync_lock: bool,
    #[serde(default)]
    clips: Vec<Clip>,
    #[serde(default)]
    name: String,
    #[serde(default = "yes")]
    is_visible: bool,
    #[serde(default)]
    is_muted: bool,
    #[serde(default)]
    is_solo: bool,
    #[serde(default)]
    is_targeted: bool,
    #[serde(default)]
    transitions: Vec<Transition>,
    #[serde(default = "Track::default_height")]
    height: f64,
    #[serde(rename = "volumeDB", default)]
    volume_db: f64,
    #[serde(default)]
    pan: f64,
    #[serde(default)]
    audio_role: Option<AudioTag>,
    #[serde(default, deserialize_with = "lenient")]
    live_ducking_opt_out: Option<bool>,
    #[serde(default, deserialize_with = "lenient")]
    loudness_target_lufs: Option<f64>,
    #[serde(default, deserialize_with = "lenient")]
    audio_preset: Option<serde_json::Value>,
    #[serde(flatten)]
    unknown: UnknownKeys,
}

impl TryFrom<TrackWire> for Track {
    type Error = &'static str;

    fn try_from(w: TrackWire) -> Result<Self, Self::Error> {
        let mut clips = w.clips;
        clips.iter_mut().for_each(Clip::adopt_legacy_corner_radius);
        let mut transitions = w.transitions;
        let dropped: BTreeSet<Id> = clips.iter().filter(|c| c.timeline().is_empty()).map(|c| c.id).collect();
        if !dropped.is_empty() {
            clips.retain(|c| !dropped.contains(&c.id));
            let anchored = |id: &Option<Id>| id.is_some_and(|id| dropped.contains(&id));
            transitions.retain(|t| !anchored(&t.outgoing) && !anchored(&t.incoming));
        }
        clips.sort_by_key(|c| c.start);
        if clips.windows(2).any(|p| p[0].timeline().end() > p[1].start) {
            return Err("overlapping clips");
        }
        Ok(Track {
            id: w.id,
            kind: w.kind,
            is_locked: w.is_locked,
            sync_lock: w.sync_lock,
            clips: clips.into(),
            name: w.name,
            is_visible: w.is_visible,
            is_muted: w.is_muted,
            is_solo: w.is_solo,
            is_targeted: w.is_targeted,
            transitions,
            height: w.height,
            volume_db: w.volume_db,
            pan: w.pan,
            audio_role: w.audio_role,
            live_ducking_opt_out: w.live_ducking_opt_out.filter(|b| *b),
            loudness_target_lufs: w.loudness_target_lufs.filter(|l| l.is_finite()),
            audio_preset: w.audio_preset.filter(|v| v.is_object()),
            unknown: w.unknown,
        })
    }
}

impl Clip {
    /// Plays a nested sequence.
    pub fn is_nested(&self) -> bool {
        self.sequence.is_some()
    }

    /// Renders itself (text layer, solid, ...).
    pub fn is_generator(&self) -> bool {
        self.generator.is_some()
    }

    /// Length on the timeline: the source range played at `speed`, or the speed track's length.
    pub fn duration(&self) -> Time {
        if let Some(k) = &self.speed_keys {
            return k.duration();
        }
        if self.speed.is_normal() { self.source.duration } else { self.speed.unscale(self.source.duration) }
    }

    /// `start ..< start + duration`.
    pub fn timeline(&self) -> TimeRange {
        TimeRange::new(self.start, self.duration())
    }
}

impl Track {
    /// Default row height in points.
    pub const DEFAULT_HEIGHT: f64 = 48.0;

    fn default_height() -> f64 {
        Self::DEFAULT_HEIGHT
    }

    /// Clips sorted by start, never overlapping.
    pub fn clips(&self) -> &[Clip] {
        &self.clips
    }

    /// End of the last clip, zero when empty.
    pub fn end(&self) -> Time {
        self.clips.last().map_or(Time::ZERO, |c| c.timeline().end())
    }
}

const ROUNDED_CORNERS_KIND: &str = "roundedCorners";
const RADIUS_KEY: &str = "radius";

impl Clip {
    /// A clip with the Swift initializer's defaults; set the other public fields afterwards.
    pub fn new(id: Id, name: &str, media: Id, kind: TrackKind, source: TimeRange, start: Time) -> Clip {
        Clip {
            id,
            name: name.to_string(),
            media,
            kind,
            source,
            start,
            link: None,
            bundle: None,
            media_duration: None,
            animation: ClipAnimation::default(),
            sequence: None,
            generator: None,
            footage_color: ClipFootageColor::default(),
            label: None,
            is_still: false,
            effects: Vec::new(),
            audio_gain_db: 0.0,
            audio_tag: None,
            duck_key_ids: Vec::new(),
            audio_fades: FadeMarks::default(),
            speed: ClipSpeed::NORMAL,
            reversed: false,
            keeps_pitch: true,
            speed_keys: None,
            time_interpolation: TimeInterpolation::FrameSampling,
            blend_mode: BlendMode::Normal,
            hold_frame: None,
            motion_enabled: true,
            opacity_enabled: true,
            is_enabled: true,
            variant_store: None,
            baked_store: None,
            mask_store: None,
            pending_scale_store: None,
            graphics_store: None,
            grade_link: None,
            grade_independent_store: None,
            extends_to_end_store: None,
            zones: None,
            template_slots: None,
            markers: None,
            attachment: None,
            angle: None,
            unknown: UnknownKeys::default(),
        }
    }

    /// v8 -> v9: a corner radius that was not the default becomes an applied Rounded Corners effect. Reading a `Track`
    /// runs this on every clip (the effect gets `Id::NIL`: ids only have to differ inside one clip).
    pub(crate) fn adopt_legacy_corner_radius(&mut self) {
        let Some(legacy) = self.animation.legacy_corner_radius.take() else { return };
        let has_effect = self.effects.iter().any(|e| e.kind == ROUNDED_CORNERS_KIND);
        if (legacy.value != 0.0 || legacy.is_animated()) && !has_effect {
            self.effects.push(ClipEffect {
                id: Id::NIL,
                kind: ROUNDED_CORNERS_KIND.to_string(),
                enabled: true,
                parameters: BTreeMap::from([(RADIUS_KEY.to_string(), legacy)]),
                colors: BTreeMap::new(),
                points: BTreeMap::new(),
                grade: None,
                color_range: None,
                color_fade_in: None,
                color_fade_out: None,
                mask_input: Vec::new(),
                color_graph: None,
                mask_track: None,
                unknown: UnknownKeys::default(),
            });
        }
    }

    /// True while the v10 Scale conversion waits for probe info.
    pub fn pending_source_pixel_scale(&self) -> bool {
        self.pending_scale_store == Some(true)
    }

    /// Sets or clears the pending v10 Scale conversion.
    pub fn set_pending_source_pixel_scale(&mut self, pending: bool) {
        self.pending_scale_store = pending.then_some(true);
    }

    /// Media, nested sequence or generator.
    pub fn clip_source(&self) -> ClipSource {
        if let Some(g) = &self.generator {
            return ClipSource::Generator(g.clone());
        }
        self.sequence.map_or(ClipSource::Media(self.media), ClipSource::Sequence)
    }

    /// Source the clip plays through, in source time: the range for a constant clip, the path length for a remapped one
    /// (average speed = this / `duration`).
    pub fn retime_span(&self) -> Time {
        self.speed_keys.as_ref().map_or(self.source.duration, SpeedKeys::path_length)
    }

    /// The speed the clip plays at on average: its constant speed, or path length / duration for a remapped clip.
    pub fn average_speed(&self) -> ClipSpeed {
        if self.speed_keys.is_none() {
            return self.speed;
        }
        ClipSpeed::from_source_over(self.retime_span(), self.duration())
    }

    /// Installs a speed track and keeps `source` equal to its hull. `None` goes back to the constant fields.
    pub fn set_speed_keys(&mut self, k: Option<SpeedKeys>) {
        if let Some(k) = &k {
            self.source = k.hull();
        }
        self.speed_keys = k;
    }

    /// How far the head can still grow, in timeline time (the source handle that plays first, divided by `speed`: before
    /// `source.start`, or after `source.end` for a reversed clip); `None` = unbounded.
    pub fn head_handle(&self) -> Option<Time> {
        if self.is_generator() || self.is_still || self.hold_frame.is_some() || self.plays_through_zones() {
            return None;
        }
        if let Some(k) = &self.speed_keys {
            let f = &k.segments[0];
            return if f.reversed {
                self.media_duration.map(|m| f.from.unscale(m - k.origin))
            } else {
                Some(f.from.unscale(k.origin))
            };
        }
        if self.reversed {
            return self.media_duration.map(|m| self.speed.unscale(m - self.source.end()));
        }
        Some(self.speed.unscale(self.source.start))
    }

    /// How far the tail can still grow, in timeline time; `None` = unbounded.
    pub fn tail_room(&self) -> Option<Time> {
        if self.hold_frame.is_some() || self.plays_through_zones() {
            return None;
        }
        if self.is_generator() || self.is_still {
            return self.media_duration.map(|m| self.speed.unscale(m - self.source.end()));
        }
        if let Some(k) = &self.speed_keys {
            let l = &k.segments[k.segments.len() - 1];
            return if l.reversed {
                Some(l.to.unscale(k.end_position()))
            } else {
                self.media_duration.map(|m| l.to.unscale(m - k.end_position()))
            };
        }
        if self.reversed {
            return Some(self.speed.unscale(self.source.start));
        }
        self.media_duration.map(|m| self.speed.unscale(m - self.source.end()))
    }

    /// Source time shown at timeline time `t` (absolute). Forward: `source.start + local * speed`. Reversed: the clip plays
    /// `source` backwards, so the frame shown for the timeline frame [local, local + frame_duration) is the one ending at
    /// `source.end - local * speed`; its start is `source.end - (local + frame_duration) * speed`. Generators have no time
    /// axis: `local`. Clamped into `source` for reversed clips.
    pub fn source_time(&self, t: Time, frame_duration: Time) -> Time {
        if self.is_generator() {
            return t - self.start;
        }
        if let Some(h) = self.hold_frame {
            return h;
        }
        let t = self.held_read_time(t, frame_duration);
        let local = t - self.start;
        let outside_media = |s: Time| match self.media_duration {
            Some(m) => s.max(Time::ZERO).min(Time::ZERO.max(m - frame_duration)),
            None => s.max(Time::ZERO),
        };
        if let Some(k) = &self.speed_keys {
            let s = k.source_time(local, frame_duration);
            // Inside the clip: within its hull. Outside (a transition reading its handle): the track runs on, never below 0.
            if self.timeline().contains(t) {
                return s.max(self.source.start).min(self.source.end());
            }
            return outside_media(s);
        }
        if self.reversed {
            let s = self.source.end() - self.speed.scale(local + frame_duration);
            // Outside the clip (a transition reading its handle) the reversed source runs on below `source.start`; past a
            // media edge (held frame) it stays inside the media.
            if self.timeline().contains(t) {
                return s.max(self.source.start);
            }
            return outside_media(s);
        }
        let s = self.source.start + self.speed.scale(local);
        // Outside the clip (a transition reading past a media edge: held frame) stay inside the media.
        if !self.timeline().contains(t) && !self.is_still && self.media_duration.is_some() {
            return outside_media(s);
        }
        s
    }

    /// Timeline time to read at `t` (repeated frames): outside the clip on a side with no whole frame of media beyond that
    /// edge, the clip's own edge frame: its first frame before `start`, its last frame from `timeline.end` on, whatever
    /// the speed, direction or speed keys. Else `t` unchanged. Video and nested clips read through this, so a held half of a
    /// transition shows the clip's edge picture.
    pub fn held_read_time(&self, t: Time, fd: Time) -> Time {
        if self.is_generator()
            || self.is_still
            || self.hold_frame.is_some()
            || self.duration() <= Time::ZERO
            || self.timeline().contains(t)
        {
            return t;
        }
        let before = t < self.start;
        let room = if before { self.head_handle() } else { self.tail_room() };
        match room {
            Some(r) if r.frame_index(fd) <= 0 => {
                if before {
                    self.start
                } else {
                    self.start.max(self.timeline().end() - fd)
                }
            }
            _ => t,
        }
    }

    /// The source runs backwards at clip-local `local` (reverse, or the reversed speed segment shown there).
    pub fn plays_backward(&self, local: Time) -> bool {
        if self.hold_frame.is_some() {
            return false;
        }
        match &self.speed_keys {
            Some(k) => k.is_reversed(local),
            None => self.reversed,
        }
    }

    /// True when the clip does not play its source at constant 100 % forwards.
    pub fn is_retimed(&self) -> bool {
        self.speed_keys.is_some() || !self.speed.is_normal() || self.reversed
    }

    /// Source time at clip-local `local` as an instant (no frame convention): the inner time of a nested clip, audio
    /// positions. Same arithmetic as `source_time` for forward clips; reversed clips read `source.end - speed * local`.
    pub fn source_instant(&self, local: Time) -> Time {
        if let Some(h) = self.hold_frame {
            return h;
        }
        if let Some(k) = &self.speed_keys {
            return k.position_extended(local);
        }
        if self.reversed {
            self.source.end() - self.speed.scale(local)
        } else {
            self.source.start + self.speed.scale(local)
        }
    }

    /// Start of the source frame the picture shows at clip-local `local` (`source_time`, the time the renderer's decoded
    /// frame carries): what a per-frame lookup (matte, tint, prefetch) must use. A reversed clip shows the frame that ends
    /// at `source_instant`, so this is one (speed-scaled) frame earlier there.
    pub fn shown_source_time(&self, local: Time, fd: Time) -> Time {
        self.source_time(self.start + local, fd)
    }

    /// Playing backwards at clip-local `local` (the clip's direction, or the speed track's at that instant).
    pub fn plays_backwards(&self, local: Time) -> bool {
        self.speed_keys.as_ref().map_or(self.reversed, |k| k.is_reversed(local))
    }

    /// Inner sequence time to show for a nested clip at clip-local `local`: the mapped instant; when playing backwards the
    /// frame that ends there, so one INNER frame earlier (`inner_frame_duration`), which keeps video and audio agreeing
    /// when the inner and outer frame rates differ. Identical to `source.start + local` for an unretimed clip.
    pub fn inner_time(&self, local: Time, inner_frame_duration: Time) -> Time {
        // An applied title template plays its content through the zones, whatever its source range.
        if let (true, Some(z)) = (self.plays_through_zones(), &self.zones) {
            return z.content_time(local, self.duration());
        }
        let t = self.source_instant(local);
        if self.plays_backwards(local) { (t - inner_frame_duration).max(self.source.start) } else { t }
    }

    /// The source range a stretch `[a, b]` of the clip's local time plays (nested clips: the inner time range to query).
    pub fn source_range(&self, a: Time, b: Time) -> TimeRange {
        if let Some(k) = self.speed_keys.as_ref().filter(|_| a < b) {
            return k.sliced(a, b).hull();
        }
        let (x, y) = (self.source_instant(a), self.source_instant(b));
        TimeRange::from_end(x.min(y), x.max(y))
    }

    /// Clip-local time at which the instant source time `s` plays: the inverse of `source_instant` (first visit for tracks).
    pub fn local_time_for_instant(&self, s: Time) -> Time {
        if let Some(k) = &self.speed_keys {
            return k.local_time_for_source(s);
        }
        if self.reversed {
            self.speed.unscale(self.source.end() - s)
        } else {
            self.speed.unscale(s - self.source.start)
        }
    }

    /// Timeline time (absolute) at which source time `s` is shown; the inverse of `source_time`. Pass the sequence frame
    /// duration for reversed clips (the frame shown starts one frame before the mapped end). Used to map decoded frames back
    /// onto the timeline.
    pub fn timeline_time_for_source(&self, s: Time, frame_duration: Time) -> Time {
        if let Some(k) = &self.speed_keys {
            // The frame starting at `s` is shown at a visit `local` (forward) or one frame earlier (reversed: its start is
            // the position one frame later). Take the first visit/candidate that really maps back to `s` (exact for
            // constant segments), so reversed/forward boundaries and revisited source follow the same rule as `source_time`.
            for v in k.local_times_for_source(s) {
                let early = v - frame_duration;
                if frame_duration > Time::ZERO
                    && early >= Time::ZERO
                    && k.is_reversed(early)
                    && k.source_time(early, frame_duration) == s
                {
                    return self.start + early;
                }
                if k.source_time(v, frame_duration) == s {
                    return self.start + v;
                }
            }
            let local = k.local_time_for_source(s);
            return self.start + local - if k.is_reversed(local) { frame_duration } else { Time::ZERO };
        }
        if self.reversed {
            self.start + self.speed.unscale(self.source.end() - s) - frame_duration
        } else {
            self.start + self.speed.unscale(s - self.source.start)
        }
    }

    /// Moves a split-off right half onto a fresh link shared through `map` (old link to new link).
    #[doc(hidden)]
    pub fn relink(&mut self, map: &mut BTreeMap<Id, Id>, ids: &mut dyn IdSource) {
        let Some(l) = self.link else { return };
        let n = *map.entry(l).or_insert_with(|| ids.next_id());
        self.link = Some(n);
    }

    /// Makes the clip `g` longer at its head (negative = shorter) without moving `start` (the caller moves it).
    /// The source side that plays first changes by `g * speed`; keys stay on the same frames, so they shift by `g`
    /// (clip-local keys are timeline time). Keys pushed outside 0...duration are kept, like in `cropped`.
    #[doc(hidden)]
    pub fn extend_head(&mut self, g: Time) {
        if let Some(a) = &mut self.attachment {
            a.point += g; // Fast Cut: the caller moves `start` by -g, so the attach time stays
        }
        // Zones: intro keys stay at the clip start, outro keys keep their distance to the end.
        if let Some(z) = self.zones.clone() {
            let old = self.duration();
            if self.plays_through_zones() {
                self.source.duration += self.speed.scale(g);
            } else {
                self.extend_head_keeping_keys(g);
            }
            self.remap_keys_through_zones(&z, old, old + g, ClipEdge::Head);
            self.rebase_item_ranges(g);
            return;
        }
        self.extend_head_keeping_keys(g);
        self.rebase_item_ranges(g);
        self.animation = self.animation.shifted(g);
        self.effects = self.effects.iter().map(|e| e.shifted(g)).collect();
        self.shift_variant_keys(g);
    }

    /// `extend_head` for the source side only (keys untouched).
    fn extend_head_keeping_keys(&mut self, g: Time) {
        if let Some(k) = &self.speed_keys {
            let longer = k.extended_head(g);
            self.set_speed_keys(Some(longer));
            return;
        }
        let d = self.speed.scale(g);
        if self.reversed {
            self.source.duration += d;
        } else {
            self.source.start -= d;
            self.source.duration += d;
        }
    }

    /// Moves the clip-local key times after a retime from `old` to `new` timeline duration: scaled by new/old so keys stay
    /// on the same content; when the direction flipped (`mirror`), mirrored inside the clip as well.
    #[doc(hidden)]
    pub fn rescale_keys(&mut self, old: Time, new: Time, mirror: bool) {
        if !(old > Time::ZERO && (old != new || mirror)) {
            return;
        }
        let f = |t: Time| {
            let s = Time::scaled(t, new, old);
            if mirror { new - s } else { s }
        };
        self.animation = self.animation.remapped(f);
        self.effects = self.effects.iter().map(|e| e.remapped(f)).collect();
        self.remap_variant_keys(&f);
        if let Some(g) = self.graphics_store.as_mut().filter(|g| g.has_item_ranges()) {
            g.rescale_item_ranges(old, new, mirror);
        }
    }

    /// Makes the clip `g` longer at its tail (negative = shorter). The source side that plays last changes by `g * speed`.
    #[doc(hidden)]
    pub fn extend_tail(&mut self, g: Time) {
        if let Some(z) = self.zones.clone() {
            let old = self.duration();
            if self.plays_through_zones() {
                self.source.duration += self.speed.scale(g);
            } else {
                self.extend_tail_keeping_keys(g);
            }
            self.remap_keys_through_zones(&z, old, old + g, ClipEdge::Tail);
            self.rebase_item_ranges(Time::ZERO);
            return;
        }
        self.extend_tail_keeping_keys(g);
        self.rebase_item_ranges(Time::ZERO);
    }

    fn extend_tail_keeping_keys(&mut self, g: Time) {
        if let Some(k) = &self.speed_keys {
            let longer = k.extended_tail(g);
            self.set_speed_keys(Some(longer));
            return;
        }
        let d = self.speed.scale(g);
        if self.reversed {
            self.source.start -= d;
        }
        self.source.duration += d;
    }

    /// Keeps the part of the clip inside `range` (timeline coordinates); the source range follows through speed and
    /// direction, keys stay on the same frames.
    #[doc(hidden)]
    pub fn cropped(&self, range: TimeRange) -> Option<Clip> {
        let r = self.timeline().intersection(&range)?;
        let mut c = self.clone();
        c.graphics_store =
            self.graphics_store.as_ref().map(|g| g.cropping_item_ranges(r.start - self.start, r.duration));
        let a = r.start - self.start;
        if let Some(k) = &self.speed_keys {
            c.set_speed_keys(Some(k.sliced(a, a + r.duration)));
        } else {
            let len = self.speed.scale(r.duration);
            c.source = if self.reversed {
                TimeRange::new(self.source.end() - self.speed.scale(a) - len, len)
            } else {
                TimeRange::new(self.source.start + self.speed.scale(a), len)
            };
        }
        c.start = r.start;
        let delta = self.start - r.start;
        c.animation = self.animation.shifted(delta); // keep keys on the same frames
        c.effects = self.effects.iter().map(|e| e.shifted(delta)).collect();
        c.shift_variant_keys(delta);
        if let Some(a) = &mut c.attachment {
            a.point -= r.start - self.start; // Fast Cut: same attach time (the point is from the clip's start)
        }
        Some(c)
    }
}

impl Track {
    /// A track with the Swift initializer's defaults (empty, unlocked, sync-locked, visible); set the other public fields
    /// afterwards.
    pub fn new(id: Id, kind: TrackKind) -> Track {
        Track {
            id,
            kind,
            is_locked: false,
            sync_lock: true,
            clips: CowVec::new(),
            name: String::new(),
            is_visible: true,
            is_muted: false,
            is_solo: false,
            is_targeted: false,
            transitions: Vec::new(),
            height: Track::DEFAULT_HEIGHT,
            volume_db: 0.0,
            pan: 0.0,
            audio_role: None,
            live_ducking_opt_out: None,
            loudness_target_lufs: None,
            audio_preset: None,
            unknown: UnknownKeys::default(),
        }
    }

    /// This track takes no part in live ducking (a Music track is not ducked, a Dialogue track does not duck the music).
    pub fn is_excluded_from_live_ducking(&self) -> bool {
        self.live_ducking_opt_out == Some(true)
    }

    /// Sets or clears the live ducking opt-out.
    pub fn set_excluded_from_live_ducking(&mut self, excluded: bool) {
        self.live_ducking_opt_out = excluded.then_some(true);
    }

    /// Every clip through `f` in one pass. `f` must keep each clip's start and duration (nothing is re-sorted or checked for
    /// overlaps); used for value rewrites such as resolving a format variant or giving clips new IDs.
    pub fn map_clips_keeping_timing(&mut self, f: impl FnMut(&Clip) -> Clip) {
        self.clips = self.clips.iter().map(f).collect();
    }

    /// Replaces every clip at once (batch edits). Sorted here; the caller checks `is_consistent`.
    pub fn set_clips(&mut self, mut clips: Vec<Clip>) {
        clips.sort_by_key(|c| c.start);
        self.clips = clips.into();
    }

    /// Takes part in ripple edits made on other tracks.
    pub fn follows_ripple(&self) -> bool {
        self.sync_lock && !self.is_locked
    }

    /// Places `clip`, replacing whatever it covers.
    pub fn overwrite(&mut self, clip: Clip, ids: &mut dyn IdSource) -> Result<(), EditError> {
        self.overwrite_relinking(clip, &mut BTreeMap::new(), ids)
    }

    /// `overwrite` with a shared old-link to new-link map (see `clear_relinking`).
    pub fn overwrite_relinking(
        &mut self,
        clip: Clip,
        relinks: &mut BTreeMap<Id, Id>,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        self.check(&clip)?;
        let mut work = self.clone();
        work.clear_relinking(clip.timeline(), relinks, ids);
        work.clips.push(clip);
        work.clips.sort_by_key(|c| c.start);
        // Cut times off every frame grid can round (see `Time::reducing`): pieces that no longer fit are refused.
        if !work.is_consistent() {
            return Err(EditError::Collision);
        }
        *self = work;
        Ok(())
    }

    /// Removes everything inside `hole` and leaves a gap. Straddling clips are cut; when a clip is cut in two, only the left
    /// half keeps the identity and link; the right half gets a new link.
    pub fn clear(&mut self, hole: TimeRange, ids: &mut dyn IdSource) {
        self.clear_relinking(hole, &mut BTreeMap::new(), ids);
    }

    /// `clear` with a shared old-link to new-link map: right halves cut from one linked group, on this or other tracks, get
    /// the same new link, so each side stays linked with its own partners.
    pub fn clear_relinking(&mut self, hole: TimeRange, relinks: &mut BTreeMap<Id, Id>, ids: &mut dyn IdSource) {
        if hole.is_empty() {
            return;
        }
        let mut out = Vec::new();
        for c in std::mem::take(&mut self.clips) {
            if !c.timeline().overlaps(&hole) {
                out.push(c);
                continue;
            }
            let keeps_left = hole.start > c.start;
            if keeps_left && let Some(left) = c.cropped(TimeRange::from_end(c.start, hole.start)) {
                out.push(left);
            }
            if hole.end() < c.timeline().end()
                && let Some(mut right) = c.cropped(TimeRange::from_end(hole.end(), c.timeline().end()))
            {
                if keeps_left {
                    let old = right.id;
                    right.id = ids.next_id();
                    right.relink(relinks, ids);
                    self.retarget_tail(old, right.id);
                }
                out.push(right);
            }
        }
        out.sort_by_key(|c| c.start);
        self.clips = out.into();
    }

    /// Places `clip` and pushes everything at or after its start later by its duration.
    pub fn insert(&mut self, clip: Clip, ids: &mut dyn IdSource) -> Result<(), EditError> {
        self.check(&clip)?;
        self.split(clip.start, ids)?;
        let d = clip.timeline().duration;
        for c in self.clips.iter_mut().filter(|c| c.start >= clip.start) {
            c.start += d;
        }
        self.clips.push(clip);
        self.clips.sort_by_key(|c| c.start);
        Ok(())
    }

    /// Cuts the clip under `t` in two. No-op on edges and in gaps. The left half keeps the ID and link.
    pub fn split(&mut self, t: Time, ids: &mut dyn IdSource) -> Result<(), EditError> {
        self.split_relinking(t, &mut BTreeMap::new(), ids)
    }

    /// `split` with a shared old-link to new-link map (see `clear_relinking`).
    pub fn split_relinking(
        &mut self,
        t: Time,
        relinks: &mut BTreeMap<Id, Id>,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let Some(i) = self.clips.iter().position(|c| c.timeline().contains(t) && c.start < t) else { return Ok(()) };
        let c = self.clips[i].clone();
        // A cut time off every frame grid can need more than i64 and round: halves that no longer meet are refused.
        let (Some(left), Some(mut right)) =
            (c.cropped(TimeRange::from_end(c.start, t)), c.cropped(TimeRange::from_end(t, c.timeline().end())))
        else {
            return Err(EditError::Collision);
        };
        if !(left.timeline().end() <= right.start && right.timeline().end() <= c.timeline().end()) {
            return Err(EditError::Collision);
        }
        self.clips[i] = left;
        right.id = ids.next_id();
        right.relink(relinks, ids);
        self.retarget_tail(c.id, right.id);
        self.clips.insert(i + 1, right);
        Ok(())
    }

    /// A clip was cut in two: transitions that start from its tail (cut to the next clip, fade out) now belong to the right
    /// half, which holds the old tail; transitions on its head stay on the left half, which keeps the ID.
    fn retarget_tail(&mut self, old: Id, new: Id) {
        for t in &mut self.transitions {
            if t.outgoing == Some(old) {
                t.outgoing = Some(new);
            }
        }
    }

    /// Removes a clip and leaves a gap.
    pub fn remove(&mut self, id: Id) {
        self.clips.retain(|c| c.id != id);
    }

    /// Removes a clip and pulls later clips left by its duration.
    pub fn ripple_delete(&mut self, id: Id) {
        let Some(c) = self.clips.iter().find(|c| c.id == id).cloned() else { return };
        self.remove(id);
        for other in self.clips.iter_mut().filter(|o| o.start >= c.timeline().end()) {
            other.start -= c.timeline().duration;
        }
    }

    /// The clip with `id`.
    pub fn clip(&self, id: Id) -> Option<&Clip> {
        self.clips.iter().find(|c| c.id == id)
    }

    /// Replaces the clip that has the id of `c`.
    pub fn replace(&mut self, c: Clip) {
        if let Some(slot) = self.clips.iter_mut().find(|x| x.id == c.id) {
            *slot = c;
        }
    }

    /// Moves every clip starting at or after `pivot` by `delta`, except `excluding`.
    pub fn shift(&mut self, pivot: Time, delta: Time, excluding: &BTreeSet<Id>) {
        for c in self.clips.iter_mut().filter(|c| c.start >= pivot && !excluding.contains(&c.id)) {
            c.start += delta;
        }
    }

    /// How far clips at or after `pivot` can move left before touching the clip before them. `None` = nothing after
    /// `pivot`, no limit.
    pub fn left_room(&self, pivot: Time, excluding: &BTreeSet<Id>) -> Option<Time> {
        let rest: Vec<&Clip> = self.clips.iter().filter(|c| !excluding.contains(&c.id)).collect();
        let next = rest.iter().find(|c| c.start >= pivot)?;
        let prev_end = rest.iter().filter(|c| c.start < pivot).map(|c| c.timeline().end()).max().unwrap_or(Time::ZERO);
        Some(next.start - prev_end)
    }

    /// Sorted, non-overlapping and not before 0.
    pub fn is_consistent(&self) -> bool {
        self.clips.windows(2).all(|p| p[0].timeline().end() <= p[1].start)
            && self.clips.first().is_none_or(|c| c.start >= Time::ZERO)
    }

    fn check(&self, clip: &Clip) -> Result<(), EditError> {
        if clip.kind != self.kind {
            return Err(EditError::WrongTrackKind);
        }
        if clip.timeline().is_empty() {
            return Err(EditError::EmptyClip);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::AnimatedProperty;
    use sq_core_time::Keyframe;

    fn clip(speed: ClipSpeed) -> Clip {
        Clip {
            id: Id::from_u128(1),
            name: String::new(),
            media: Id::from_u128(2),
            kind: TrackKind::Video,
            source: TimeRange::new(Time::ZERO, Time::new(2, 1)),
            start: Time::new(1, 1),
            link: None,
            bundle: None,
            media_duration: None,
            animation: ClipAnimation::default(),
            sequence: None,
            generator: None,
            footage_color: ClipFootageColor::default(),
            label: None,
            is_still: false,
            effects: Vec::new(),
            audio_gain_db: 0.0,
            audio_tag: None,
            duck_key_ids: Vec::new(),
            audio_fades: FadeMarks::default(),
            speed,
            reversed: false,
            keeps_pitch: true,
            speed_keys: None,
            time_interpolation: TimeInterpolation::FrameSampling,
            blend_mode: BlendMode::Normal,
            hold_frame: None,
            motion_enabled: true,
            opacity_enabled: true,
            is_enabled: true,
            variant_store: None,
            baked_store: None,
            mask_store: None,
            pending_scale_store: None,
            graphics_store: None,
            grade_link: None,
            grade_independent_store: None,
            extends_to_end_store: None,
            zones: None,
            template_slots: None,
            markers: None,
            attachment: None,
            angle: None,
            unknown: UnknownKeys::default(),
        }
    }

    #[test]
    fn duration_follows_speed() {
        assert_eq!(clip(ClipSpeed::NORMAL).timeline().end(), Time::new(3, 1));
        let double = ClipSpeed::from_parts_for_tests(2, 1);
        assert_eq!(clip(double).duration(), Time::new(1, 1));
        assert_eq!(double.scale(Time::new(1, 1)), Time::new(2, 1));
    }

    fn clip_json(n: u128, start: i64, duration: i64) -> serde_json::Value {
        serde_json::json!({"id": Id::from_u128(n), "name": "c", "media": Id::from_u128(100), "kind": "video",
            "source": {"start": {"value": 0, "timescale": 1}, "duration": {"value": duration, "timescale": 1}},
            "start": {"value": start, "timescale": 1}})
    }

    fn track(clips: Vec<serde_json::Value>, transitions: Vec<serde_json::Value>) -> serde_json::Value {
        serde_json::json!({"id": Id::from_u128(9), "kind": "video", "clips": clips, "transitions": transitions})
    }

    fn transition(out: Option<u128>, inc: Option<u128>) -> serde_json::Value {
        serde_json::json!({"id": Id::from_u128(50), "kind": "crossDissolve", "duration": {"value": 1, "timescale": 1},
            "alignment": "center", "customBefore": {"value": 0, "timescale": 1},
            "outgoing": out.map(Id::from_u128), "incoming": inc.map(Id::from_u128)})
    }

    #[test]
    fn track_keys_default_when_missing() {
        let t: Track = serde_json::from_value(serde_json::json!({"id": Id::from_u128(9), "kind": "audio"})).unwrap();
        assert!(t.sync_lock && t.is_visible && !t.is_locked && !t.is_muted && !t.is_solo && !t.is_targeted);
        assert_eq!((t.height, t.volume_db, t.pan, t.audio_role, t.clips().len()), (48.0, 0.0, 0.0, None, 0));
    }

    #[test]
    fn track_drops_zero_length_clips_and_their_transitions() {
        let json = track(
            vec![clip_json(1, 0, 2), clip_json(2, 2, 0), clip_json(3, 2, 1)],
            vec![
                transition(Some(1), Some(2)),
                transition(None, Some(2)),
                transition(Some(2), None),
                transition(Some(1), Some(3)),
            ],
        );
        let t: Track = serde_json::from_value(json).unwrap();
        assert_eq!(t.clips().iter().map(|c| c.id).collect::<Vec<_>>(), vec![Id::from_u128(1), Id::from_u128(3)]);
        assert_eq!(t.transitions.len(), 1);
        assert_eq!(t.transitions[0].incoming, Some(Id::from_u128(3)));
    }

    #[test]
    fn track_sorts_clips_by_start() {
        let t: Track = serde_json::from_value(track(vec![clip_json(2, 5, 1), clip_json(1, 0, 1)], vec![])).unwrap();
        assert_eq!(t.clips().iter().map(|c| c.id).collect::<Vec<_>>(), vec![Id::from_u128(1), Id::from_u128(2)]);
    }

    #[test]
    fn track_rejects_overlapping_clips_but_allows_touching_ones() {
        assert!(serde_json::from_value::<Track>(track(vec![clip_json(1, 0, 3), clip_json(2, 2, 1)], vec![])).is_err());
        assert!(serde_json::from_value::<Track>(track(vec![clip_json(1, 0, 2), clip_json(2, 2, 1)], vec![])).is_ok());
    }

    #[test]
    fn track_reads_live_ducking_opt_out_leniently_and_stores_only_true() {
        let read = |v: serde_json::Value| {
            let mut t = track(vec![], vec![]);
            t["liveDuckingOptOut"] = v;
            serde_json::from_value::<Track>(t).unwrap().live_ducking_opt_out
        };
        assert_eq!((read(true.into()), read(false.into()), read("yes".into())), (Some(true), None, None));
    }

    #[test]
    fn track_reads_the_loudness_override_leniently_and_omits_it_when_unset() {
        let read = |v: Option<serde_json::Value>| {
            let mut t = track(vec![], vec![]);
            if let Some(v) = v {
                t["loudnessTargetLufs"] = v;
            }
            serde_json::from_value::<Track>(t).unwrap()
        };
        assert_eq!(read(None).loudness_target_lufs, None, "an old project has no override");
        assert_eq!(read(Some((-23.0).into())).loudness_target_lufs, Some(-23.0));
        assert_eq!(read(Some("loud".into())).loudness_target_lufs, None);
        let v = serde_json::to_value(read(None)).unwrap();
        assert!(v.get("loudnessTargetLufs").is_none(), "unset is not written");
        let v = serde_json::to_value(read(Some((-16.0).into()))).unwrap();
        assert_eq!(v["loudnessTargetLufs"], -16.0);
    }

    #[test]
    fn track_writes_the_swift_keys() {
        let t: Track = serde_json::from_value(track(vec![clip_json(1, 0, 1)], vec![])).unwrap();
        let v = serde_json::to_value(&t).unwrap();
        assert_eq!((v["volumeDB"].clone(), v["syncLock"].clone(), v.get("audioRole")), (0.0.into(), true.into(), None));
    }

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    /// A clip of `frames` frames of media from frame `from`, starting at frame `start`, with 200 frames of media.
    fn media_clip(n: u128, start: i64, from: i64, frames: i64) -> Clip {
        let mut c = Clip::new(id(n), "c", id(100 + n), TrackKind::Video, TimeRange::new(f(from), f(frames)), f(start));
        c.media_duration = Some(f(200));
        c
    }

    fn ids() -> sq_core_time::SequentialIds {
        sq_core_time::SequentialIds::default()
    }

    fn starts(t: &Track) -> Vec<(u128, i64, i64)> {
        t.clips().iter().map(|c| (c.id.as_u128(), c.start.frame_index(f(1)), c.duration().frame_index(f(1)))).collect()
    }

    #[test]
    fn constant_speed_maps_timeline_to_source_forward_and_reversed() {
        let mut c = media_clip(1, 10, 20, 60);
        c.speed = ClipSpeed::from_percent(200.0);
        assert_eq!(c.duration(), f(30));
        assert_eq!(c.source_time(f(25), f(1)), f(20) + f(30)); // 15 frames in, double speed
        assert_eq!(c.source_instant(f(15)), f(50));
        assert_eq!(c.local_time_for_instant(f(50)), f(15));
        assert_eq!(c.timeline_time_for_source(f(50), Time::ZERO), f(25));
        c.reversed = true;
        // Reversed: the frame shown at local 0 ends at source.end and starts one (speed-scaled) frame earlier.
        assert_eq!(c.source_time(f(10), f(1)), c.source.end() - f(2));
        assert_eq!(c.source_instant(Time::ZERO), c.source.end());
        assert_eq!(c.local_time_for_instant(c.source.end() - f(30)), f(15));
        assert!(c.plays_backward(Time::ZERO) && c.plays_backwards(f(3)));
        assert!(c.is_retimed());
        assert!(!media_clip(2, 0, 0, 10).is_retimed());
    }

    #[test]
    fn source_time_outside_the_clip_stays_inside_the_media() {
        let c = media_clip(1, 100, 190, 10); // the media ends exactly at the clip's source end
        assert_eq!(c.source_time(f(112), f(1)), f(199)); // past the tail: the last media frame
        let head = media_clip(2, 50, 0, 10);
        assert_eq!(head.source_time(f(40), f(1)), Time::ZERO);
        let mut text_clip = media_clip(3, 5, 0, 10);
        text_clip.generator = Some(GeneratorRef { kind: "text".into(), payload: Vec::new(), payload_version: 1 });
        assert_eq!(text_clip.source_time(f(8), f(1)), f(3));
    }

    #[test]
    fn handles_follow_speed_direction_and_media() {
        let mut c = media_clip(1, 0, 20, 60);
        assert_eq!((c.head_handle(), c.tail_room()), (Some(f(20)), Some(f(120))));
        c.speed = ClipSpeed::from_percent(200.0);
        assert_eq!((c.head_handle(), c.tail_room()), (Some(f(10)), Some(f(60))));
        c.reversed = true;
        assert_eq!((c.head_handle(), c.tail_room()), (Some(f(60)), Some(f(10))));
        c.hold_frame = Some(f(5));
        assert_eq!((c.head_handle(), c.tail_room()), (None, None));
        let mut still = media_clip(2, 0, 0, 10);
        still.is_still = true;
        assert_eq!(still.head_handle(), None);
    }

    #[test]
    fn held_read_time_repeats_the_edge_frame_when_no_media_is_left() {
        let c = media_clip(1, 100, 0, 30); // no media before the head
        assert_eq!(c.held_read_time(f(90), f(1)), f(100));
        assert_eq!(c.held_read_time(f(110), f(1)), f(110));
        let tail = media_clip(2, 0, 170, 30); // the media ends at the source end
        assert_eq!(tail.held_read_time(f(35), f(1)), f(29));
    }

    #[test]
    fn extending_the_head_and_tail_moves_the_source_by_speed_and_keeps_keys_on_their_frames() {
        let mut c = media_clip(1, 100, 50, 40);
        c.speed = ClipSpeed::from_percent(200.0);
        c.animation.rotation = AnimatedProperty::new(0.0);
        c.extend_head(f(5));
        assert_eq!((c.source.start, c.source.duration), (f(40), f(50)));
        c.extend_tail(f(-5));
        assert_eq!(c.source.duration, f(40));
        let mut r = media_clip(2, 0, 50, 40);
        r.reversed = true;
        r.extend_head(f(10));
        assert_eq!((r.source.start, r.source.duration), (f(50), f(50)));
        r.extend_tail(f(10));
        assert_eq!((r.source.start, r.source.duration), (f(40), f(60)));
    }

    #[test]
    fn extending_a_keyed_clip_goes_through_its_speed_track() {
        let mut c = media_clip(1, 0, 0, 60);
        c.set_speed_keys(Some(SpeedKeys::constant(ClipSpeed::NORMAL, false, f(60), Time::ZERO)));
        c.extend_tail(f(10));
        assert_eq!(c.duration(), f(70));
        assert_eq!(Some(c.source), c.speed_keys.as_ref().map(SpeedKeys::hull));
        c.extend_head(f(5));
        assert_eq!(c.duration(), f(75));
    }

    #[test]
    fn cropping_follows_speed_and_direction() {
        let mut c = media_clip(1, 100, 20, 60);
        c.speed = ClipSpeed::from_percent(200.0);
        let piece = c.cropped(TimeRange::new(f(110), f(10))).unwrap();
        assert_eq!((piece.start, piece.source), (f(110), TimeRange::new(f(40), f(20))));
        c.reversed = true;
        let piece = c.cropped(TimeRange::new(f(110), f(10))).unwrap();
        assert_eq!(piece.source, TimeRange::new(f(80) - f(20) - f(20), f(20)));
        assert!(c.cropped(TimeRange::new(f(500), f(10))).is_none());
    }

    #[test]
    fn cropping_shifts_keys_so_they_stay_on_their_frames() {
        let mut c = media_clip(1, 100, 0, 60);
        let key = Keyframe::new(id(7), f(40), 90.0);
        c.animation.rotation.track.insert(key);
        let piece = c.cropped(TimeRange::new(f(120), f(30))).unwrap();
        assert_eq!(piece.animation.rotation.track.key(id(7)).map(|k| k.time), Some(f(20)));
    }

    #[test]
    fn split_gives_the_right_half_a_new_id_and_link_and_moves_tail_transitions() {
        let mut t = Track::new(id(9), TrackKind::Video);
        let mut a = media_clip(1, 0, 0, 60);
        a.link = Some(id(50));
        t.overwrite(a, &mut ids()).unwrap();
        let mut b = media_clip(2, 60, 0, 30);
        b.link = Some(id(51));
        t.overwrite(b, &mut ids()).unwrap();
        t.transitions.push(serde_json::from_value(transition(Some(1), Some(2))).unwrap());
        let mut new_ids = sq_core_time::SequentialIds::default();
        (0..1000).for_each(|_| {
            sq_core_time::IdSource::next_id(&mut new_ids);
        }); // fresh ids must not hit test ids
        t.split(f(20), &mut new_ids).unwrap();
        assert_eq!(t.clips().len(), 3);
        let right = &t.clips()[1];
        assert_ne!(right.id, id(1));
        assert_ne!(right.link, Some(id(50)));
        assert_eq!(t.clips()[0].link, Some(id(50)));
        assert_eq!(t.transitions[0].outgoing, Some(right.id));
        assert_eq!(t.transitions[0].incoming, Some(id(2)));
        // A cut on an edge or in a gap does nothing.
        t.split(f(60), &mut new_ids).unwrap();
        t.split(f(500), &mut new_ids).unwrap();
        assert_eq!(t.clips().len(), 3);
    }

    #[test]
    fn clear_cuts_straddlers_and_shares_new_links_between_tracks() {
        let mut t = Track::new(id(9), TrackKind::Video);
        let mut c = media_clip(1, 0, 0, 90);
        c.link = Some(id(50));
        t.overwrite(c, &mut ids()).unwrap();
        let mut relinks = BTreeMap::new();
        let mut new_ids = sq_core_time::SequentialIds::default();
        (0..1000).for_each(|_| {
            sq_core_time::IdSource::next_id(&mut new_ids);
        });
        t.clear_relinking(TimeRange::new(f(30), f(30)), &mut relinks, &mut new_ids);
        assert_eq!(starts(&t).len(), 2);
        assert_eq!((t.clips()[0].duration(), t.clips()[1].start), (f(30), f(60)));
        assert_eq!(relinks.len(), 1);
        assert_eq!(t.clips()[1].link, relinks.get(&id(50)).copied());
        t.clear(TimeRange::new(Time::ZERO, f(1000)), &mut new_ids);
        assert!(t.clips().is_empty());
    }

    #[test]
    fn overwrite_replaces_what_it_covers_and_refuses_wrong_kinds_and_empty_clips() {
        let mut t = Track::new(id(9), TrackKind::Video);
        t.overwrite(media_clip(1, 0, 0, 100), &mut ids()).unwrap();
        t.overwrite(media_clip(2, 40, 0, 20), &mut ids()).unwrap();
        assert_eq!(
            t.clips().iter().map(|c| (c.start, c.duration())).collect::<Vec<_>>(),
            vec![(f(0), f(40)), (f(40), f(20)), (f(60), f(40))]
        );
        let mut audio = media_clip(3, 0, 0, 10);
        audio.kind = TrackKind::Audio;
        assert_eq!(t.overwrite(audio, &mut ids()), Err(EditError::WrongTrackKind));
        assert_eq!(t.overwrite(media_clip(4, 0, 0, 0), &mut ids()), Err(EditError::EmptyClip));
        assert_eq!(t.clips().len(), 3);
    }

    #[test]
    fn insert_splits_and_pushes_later_clips() {
        let mut t = Track::new(id(9), TrackKind::Video);
        t.overwrite(media_clip(1, 0, 0, 60), &mut ids()).unwrap();
        t.insert(media_clip(2, 20, 0, 10), &mut ids()).unwrap();
        assert_eq!(
            t.clips().iter().map(|c| (c.start, c.duration())).collect::<Vec<_>>(),
            vec![(f(0), f(20)), (f(20), f(10)), (f(30), f(40))]
        );
        assert!(t.is_consistent());
    }

    #[test]
    fn remove_ripple_delete_shift_and_room() {
        let mut t = Track::new(id(9), TrackKind::Video);
        for (n, s) in [(1, 0), (2, 40), (3, 100)] {
            t.overwrite(media_clip(n, s, 0, 30), &mut ids()).unwrap();
        }
        assert_eq!(t.left_room(f(100), &BTreeSet::new()), Some(f(30)));
        assert_eq!(t.left_room(f(500), &BTreeSet::new()), None);
        assert_eq!(t.left_room(f(100), &BTreeSet::from([id(2)])), Some(f(70)));
        t.shift(f(40), f(5), &BTreeSet::from([id(3)]));
        assert_eq!(t.clip(id(2)).map(|c| c.start), Some(f(45)));
        assert_eq!(t.clip(id(3)).map(|c| c.start), Some(f(100)));
        t.ripple_delete(id(2));
        assert_eq!(t.clips().iter().map(|c| c.start).collect::<Vec<_>>(), vec![f(0), f(70)]);
        t.remove(id(1));
        assert_eq!(t.clips().len(), 1);
        assert!(t.is_consistent());
        assert_eq!(t.end(), f(100));
    }

    #[test]
    fn replace_and_map_keep_the_order() {
        let mut t = Track::new(id(9), TrackKind::Video);
        t.overwrite(media_clip(1, 0, 0, 30), &mut ids()).unwrap();
        let mut c = media_clip(1, 0, 0, 30);
        c.name = "renamed".into();
        t.replace(c);
        t.map_clips_keeping_timing(|c| Clip { is_enabled: false, ..c.clone() });
        assert_eq!((t.clips()[0].name.as_str(), t.clips()[0].is_enabled), ("renamed", false));
        t.set_clips(vec![media_clip(3, 50, 0, 10), media_clip(2, 0, 0, 10)]);
        assert_eq!(t.clips().iter().map(|c| c.id).collect::<Vec<_>>(), vec![id(2), id(3)]);
        assert!(t.follows_ripple());
        t.is_locked = true;
        assert!(!t.follows_ripple());
        t.set_excluded_from_live_ducking(true);
        assert!(t.is_excluded_from_live_ducking());
    }

    #[test]
    fn a_legacy_corner_radius_becomes_a_rounded_corners_effect_when_a_track_is_read() {
        let mut c = serde_json::to_value(media_clip(1, 0, 0, 30)).unwrap();
        c["animation"]["cornerRadius"] = serde_json::json!({"value": 12.0, "track": {"keys": []}});
        let t: Track = serde_json::from_value(track(vec![c], vec![])).unwrap();
        let clip = &t.clips()[0];
        assert!(clip.animation.legacy_corner_radius.is_none());
        assert_eq!(clip.effects.len(), 1);
        assert_eq!(clip.effects[0].kind, "roundedCorners");
        assert_eq!(clip.effects[0].parameters["radius"].value, 12.0);
        // The default radius adds nothing.
        let mut zero = serde_json::to_value(media_clip(2, 0, 0, 30)).unwrap();
        zero["animation"]["cornerRadius"] = serde_json::json!({"value": 0.0, "track": {"keys": []}});
        let t: Track = serde_json::from_value(track(vec![zero], vec![])).unwrap();
        assert!(t.clips()[0].effects.is_empty());
    }

    #[test]
    fn clip_source_and_retime_helpers() {
        let mut c = media_clip(1, 0, 0, 60);
        assert_eq!(c.clip_source(), ClipSource::Media(id(101)));
        c.sequence = Some(id(5));
        assert_eq!(c.clip_source(), ClipSource::Sequence(id(5)));
        c.sequence = None;
        c.speed = ClipSpeed::from_percent(50.0);
        assert_eq!((c.retime_span(), c.average_speed()), (f(60), ClipSpeed::from_percent(50.0)));
        c.set_speed_keys(Some(SpeedKeys::constant(ClipSpeed::from_percent(200.0), false, f(30), Time::ZERO)));
        assert_eq!((c.retime_span(), c.average_speed()), (f(60), ClipSpeed::from_percent(200.0)));
        c.set_pending_source_pixel_scale(true);
        assert!(c.pending_source_pixel_scale());
        c.set_pending_source_pixel_scale(false);
        assert_eq!(c.pending_scale_store, None);
    }

    #[test]
    fn rescaling_keys_scales_and_mirrors_them() {
        let mut c = media_clip(1, 0, 0, 60);
        c.animation.rotation.track.insert(Keyframe::new(id(7), f(10), 1.0));
        c.rescale_keys(f(60), f(30), false);
        assert_eq!(c.animation.rotation.track.key(id(7)).map(|k| k.time), Some(f(5)));
        c.rescale_keys(f(30), f(30), true);
        assert_eq!(c.animation.rotation.track.key(id(7)).map(|k| k.time), Some(f(25)));
    }
}

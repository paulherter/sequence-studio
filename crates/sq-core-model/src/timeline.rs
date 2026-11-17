// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline.swift (types; logic: task M-1)

use crate::CowVec;
use crate::UnknownKeys;
use crate::media_info::{lenient, lenient_true, positive_int, positive_time};
use crate::{
    AnglesSetup, CaptionTrack, ChannelLayout, Clip, DeliveryTarget, EditError, FormatVariant, LabelColor, Marker,
    PixelAspect, RenderCacheSpan, SequencePreviewQuality, SourcePatch, TimecodeDisplay, TimelineEditMode,
    TimelineGroup, Track, TrackKind, TrackPan,
};
use serde::{Deserialize, Deserializer, Serialize};
use sq_core_time::{Id, IdSource, Keyframe, KeyframeTrack, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

mod picture_masks;
mod ripple;
mod set_speed;
mod three_point;
#[doc(hidden)]
pub use ripple::{RippleClamp, floored_to_frame};
pub use set_speed::media_frames;
pub use three_point::{SourcePlacement, ThreePointMode};

/// Fader range of a track and of the Sequence Volume, in dB (`TrackPan.minVolumeDB`/`maxVolumeDB`).
const MIN_VOLUME_DB: f64 = -60.0;
const MAX_VOLUME_DB: f64 = 15.0;

/// Sequence Volume: clamped to the fader range, NaN reads as 0; 0 dB is stored as nothing.
fn master_level<'de, D: Deserializer<'de>>(d: D) -> Result<Option<f64>, D::Error> {
    let db = Option::<f64>::deserialize(d)?.unwrap_or(0.0);
    let db = if db.is_nan() { 0.0 } else { db.clamp(MIN_VOLUME_DB, MAX_VOLUME_DB) };
    Ok((db != 0.0).then_some(db))
}

/// Sequence Volume keys are stored only when there are some.
fn master_keys<'de, D: Deserializer<'de>>(d: D) -> Result<Option<KeyframeTrack<f64>>, D::Error> {
    Ok(Option::<KeyframeTrack<f64>>::deserialize(d)?.filter(|k| !k.is_empty()))
}

/// Normal edit mode stores nothing; a broken value reads as normal.
fn edit_mode<'de, D: Deserializer<'de>>(d: D) -> Result<Option<TimelineEditMode>, D::Error> {
    Ok(lenient::<D, TimelineEditMode>(d)?.filter(|m| *m != TimelineEditMode::Normal))
}

/// The default source patch stores nothing; a broken value reads as the default.
fn source_patch<'de, D: Deserializer<'de>>(d: D) -> Result<Option<SourcePatch>, D::Error> {
    Ok(lenient::<D, SourcePatch>(d)?.filter(|p| *p != SourcePatch::default()))
}

/// A broken or square pixel aspect opens as square (nothing stored).
fn non_square_aspect<'de, D: Deserializer<'de>>(d: D) -> Result<Option<PixelAspect>, D::Error> {
    Ok(lenient::<D, PixelAspect>(d)?.filter(|a| !a.is_square()))
}

/// Which edge of a clip an edit touches.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ClipEdge {
    /// The start.
    Head,
    /// The end.
    Tail,
}

/// Picture size, frame rate and audio rate of a sequence.
///
/// Reading rejects a non-positive frame duration, size or sample rate and drops a broken or square `pixelAspect`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SequenceFormat {
    /// Width in pixels.
    #[serde(deserialize_with = "positive_int")]
    pub width: i64,
    /// Height in pixels.
    #[serde(deserialize_with = "positive_int")]
    pub height: i64,
    /// Duration of one frame.
    #[serde(deserialize_with = "positive_time")]
    pub frame_duration: Time,
    /// Audio sample rate in Hz.
    #[serde(deserialize_with = "positive_int")]
    pub audio_sample_rate: i64,
    /// Non-square pixels; `None` = square.
    #[doc(hidden)]
    #[serde(
        rename = "pixelAspect",
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "non_square_aspect"
    )]
    pub pixel_aspect_store: Option<PixelAspect>,
    /// Keys of a newer file that this build does not know; kept and written back.
    #[serde(flatten, default, skip_serializing_if = "UnknownKeys::is_empty")]
    pub unknown: UnknownKeys,
}

/// Which of in and out a sequence has set.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InOutKind {
    /// Only an in point.
    InOnly,
    /// Only an out point.
    OutOnly,
    /// Both.
    Both,
}

/// A sequence.
///
/// The `*Store` keys read leniently (a broken value reads as absent); defaults are not kept: Normal edit mode, an
/// empty `masterVolumeKeys`, the default `sourcePatch`, 0 dB and off flags that are not true.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Timeline {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Picture and audio format.
    pub format: SequenceFormat,
    /// Video and audio tracks.
    #[serde(default)]
    pub tracks: CowVec<Track>,
    /// In/out range.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub in_out: Option<TimeRange>,
    /// Sequence markers.
    #[serde(default)]
    pub markers: Vec<Marker>,
    /// Caption tracks.
    #[serde(default)]
    pub caption_tracks: Vec<CaptionTrack>,
    /// Label color.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<LabelColor>,
    /// The format follows the first clip until unlocked.
    #[serde(default = "crate::serde_defaults::yes")]
    pub format_locked: bool,
    /// Which of in and out is set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub in_out_kind: Option<InOutKind>,
    /// Delivery preset of the sequence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delivery_target: Option<DeliveryTarget>,
    /// Format variants (square, vertical, ...).
    #[serde(default)]
    pub variants: Vec<FormatVariant>,
    /// Set when this sequence is a Group.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<TimelineGroup>,
    /// Master fader in dB; `None` = 0.
    #[doc(hidden)]
    #[serde(
        rename = "masterVolumeDB",
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "master_level"
    )]
    pub master_level: Option<f64>,
    /// Master fader keys; `None` = none.
    #[doc(hidden)]
    #[serde(
        rename = "masterVolumeKeys",
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "master_keys"
    )]
    pub master_keys_store: Option<KeyframeTrack<f64>>,
    /// Normal or magnetic; `None` = normal.
    #[doc(hidden)]
    #[serde(rename = "editMode", default, skip_serializing_if = "Option::is_none", deserialize_with = "edit_mode")]
    pub edit_mode_store: Option<TimelineEditMode>,
    /// Timecode of the first frame; `None` = 0.
    #[doc(hidden)]
    #[serde(rename = "timecodeStart", default, skip_serializing_if = "Option::is_none", deserialize_with = "lenient")]
    pub timecode_start_store: Option<Time>,
    /// Timecode or frames; `None` = timecode.
    #[doc(hidden)]
    #[serde(
        rename = "timecodeDisplay",
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient"
    )]
    pub timecode_display_store: Option<TimecodeDisplay>,
    /// Preview quality; `None` = follow the app setting.
    #[doc(hidden)]
    #[serde(rename = "previewQuality", default, skip_serializing_if = "Option::is_none", deserialize_with = "lenient")]
    pub preview_quality_store: Option<SequencePreviewQuality>,
    /// Channel layout; `None` = stereo.
    #[doc(hidden)]
    #[serde(rename = "channelLayout", default, skip_serializing_if = "Option::is_none", deserialize_with = "lenient")]
    pub channel_layout_store: Option<ChannelLayout>,
    /// Source patching; `None` = default.
    #[doc(hidden)]
    #[serde(
        rename = "sourcePatch",
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "source_patch"
    )]
    pub source_patch_store: Option<SourcePatch>,
    /// Snapping switched off; `None` = on.
    #[doc(hidden)]
    #[serde(
        rename = "snappingOff",
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_true"
    )]
    pub snapping_off_store: Option<bool>,
    /// Linked selection switched off; `None` = on.
    #[doc(hidden)]
    #[serde(
        rename = "linkedSelectionOff",
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_true"
    )]
    pub linked_selection_off_store: Option<bool>,
    /// Set when this sequence holds angles.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub angles: Option<AnglesSetup>,
    /// Rendered spans for playback (not saved).
    #[serde(skip)]
    pub render_cache_spans: Vec<RenderCacheSpan>,
    /// Keys of a newer file that this build does not know; kept and written back.
    #[serde(flatten, default, skip_serializing_if = "UnknownKeys::is_empty")]
    pub unknown: UnknownKeys,
}

/// The one place that decides how many tracks a new sequence starts with (new project, new sequence, templates that don't
/// specify tracks). Existing projects and saved templates keep their own counts.
pub struct SequenceDefaults;

impl SequenceDefaults {
    /// Video tracks of a new sequence.
    pub const VIDEO_TRACK_COUNT: usize = 4;
    /// Audio tracks of a new sequence.
    pub const AUDIO_TRACK_COUNT: usize = 4;
}

impl SequenceFormat {
    /// 1920x1080 at 48 kHz with the given frame duration.
    pub fn new(frame_duration: Time) -> SequenceFormat {
        SequenceFormat {
            width: 1920,
            height: 1080,
            frame_duration,
            audio_sample_rate: 48_000,
            pixel_aspect_store: None,
            unknown: UnknownKeys::default(),
        }
    }
}

/// A clip with the index of the track that holds it.
#[doc(hidden)]
#[derive(Clone, Debug)]
pub struct Member {
    /// Index of the track.
    pub track: usize,
    /// The clip.
    pub clip: Clip,
}

/// Sequence Volume as a dB value clamped to the fader range, NaN = 0.
fn clamp_db(db: f64) -> f64 {
    if db.is_nan() { 0.0 } else { db.clamp(MIN_VOLUME_DB, MAX_VOLUME_DB) }
}

impl Timeline {
    /// A sequence with the Swift initializer's defaults (no markers, captions or in/out; format locked); set the other
    /// public fields afterwards.
    pub fn new(id: Id, name: &str, format: SequenceFormat, tracks: Vec<Track>) -> Timeline {
        Timeline {
            id,
            name: name.to_string(),
            format,
            tracks: tracks.into(),
            in_out: None,
            markers: Vec::new(),
            caption_tracks: Vec::new(),
            label: None,
            format_locked: true,
            in_out_kind: None,
            delivery_target: None,
            variants: Vec::new(),
            group: None,
            master_level: None,
            master_keys_store: None,
            edit_mode_store: None,
            timecode_start_store: None,
            timecode_display_store: None,
            preview_quality_store: None,
            channel_layout_store: None,
            source_patch_store: None,
            snapping_off_store: None,
            linked_selection_off_store: None,
            angles: None,
            render_cache_spans: Vec::new(),
            unknown: UnknownKeys::default(),
        }
    }

    /// Premiere-like default track set for a new sequence: `video` video tracks then `audio` audio tracks, the first of
    /// each kind targeted. Empty tracks are allowed.
    pub fn default_tracks(video: usize, audio: usize, ids: &mut dyn IdSource) -> Vec<Track> {
        let mut out = Vec::new();
        for (kind, count) in [(TrackKind::Video, video), (TrackKind::Audio, audio)] {
            for i in 0..count {
                let mut t = Track::new(ids.next_id(), kind);
                t.is_targeted = i == 0;
                out.push(t);
            }
        }
        out
    }

    /// Duration of one frame (`format.frame_duration`).
    pub fn frame_duration(&self) -> Time {
        self.format.frame_duration
    }

    /// End of the last clip; zero when empty.
    pub fn duration(&self) -> Time {
        self.tracks.iter().map(|t| t.end()).max().unwrap_or(Time::ZERO)
    }

    /// Sets the duration of one frame.
    pub fn set_frame_duration(&mut self, d: Time) {
        self.format.frame_duration = d;
    }

    /// The track with `id`.
    pub fn track(&self, id: Id) -> Option<&Track> {
        self.tracks.iter().find(|t| t.id == id)
    }

    /// Sequence Volume in dB: the output level of the whole sequence, after every track fader and before the delivery
    /// limiter. Same range as a track fader; 0 = unity. A nested sequence's level applies to its sound inside the parent too.
    pub fn master_volume_db(&self) -> f64 {
        self.master_level.unwrap_or(0.0)
    }

    /// Sets the Sequence Volume, clamped to the fader range (NaN = 0 dB); 0 dB is stored as nothing.
    pub fn set_master_volume_db(&mut self, db: f64) {
        let db = clamp_db(db);
        self.master_level = (db != 0.0).then_some(db);
    }

    /// Linear gain of `master_volume_db` (1 at 0 dB, 0 at or below the fader floor).
    pub fn master_gain(&self) -> f64 {
        self.master_level.map_or(1.0, TrackPan::linear)
    }

    /// Linear gain at sequence time `t`, the one the audio mix reads (playback, scrub and export).
    pub fn master_gain_at(&self, t: Time) -> f64 {
        if self.is_master_volume_keyed() { TrackPan::linear(self.master_volume_db_at(t)) } else { self.master_gain() }
    }

    /// The Sequence Volume is keyed: its level follows `master_volume_keys`; `master_volume_db` is then only the level
    /// shown while the keys are cleared.
    pub fn is_master_volume_keyed(&self) -> bool {
        self.master_keys_store.as_ref().is_some_and(|k| !k.is_empty())
    }

    /// The Sequence Volume keys (empty when not keyed).
    pub fn master_volume_keys(&self) -> KeyframeTrack<f64> {
        self.master_keys_store.clone().unwrap_or_default()
    }

    /// Sequence Volume in dB at sequence time `t` (the keys' curve, held outside them; the static level when not keyed).
    pub fn master_volume_db_at(&self, t: Time) -> f64 {
        let keyed = self.master_keys_store.as_ref().filter(|k| !k.is_empty()).and_then(|k| k.value(t));
        match keyed {
            Some(v) => clamp_db(v),
            None => self.master_volume_db(),
        }
    }

    /// Adds (or replaces the key at the same time) a level key; clamped to the fader range, NaN = 0 dB. Returns its id.
    pub fn set_master_volume_key(&mut self, t: Time, db: f64, ids: &mut dyn IdSource) -> Id {
        let id = ids.next_id();
        let mut track = self.master_keys_store.take().unwrap_or_default();
        track.insert(Keyframe::new(id, t, clamp_db(db)));
        self.master_keys_store = Some(track);
        id
    }

    /// Removes a level key; the keys are dropped when none is left.
    pub fn remove_master_volume_key(&mut self, id: Id) {
        let Some(mut track) = self.master_keys_store.take() else { return };
        track.remove(id);
        self.master_keys_store = (!track.is_empty()).then_some(track);
    }

    /// Drops every key and keeps `db` as the constant Sequence Volume.
    pub fn clear_master_volume_keys(&mut self, db: f64) {
        self.master_keys_store = None;
        self.set_master_volume_db(db);
    }

    /// The clip with its track index.
    #[doc(hidden)]
    pub fn find(&self, id: Id) -> Option<Member> {
        self.tracks.iter().enumerate().find_map(|(i, t)| t.clip(id).map(|c| Member { track: i, clip: c.clone() }))
    }

    /// The clip first, then every clip sharing its link.
    #[doc(hidden)]
    pub fn linked_group(&self, id: Id) -> Result<Vec<Member>, EditError> {
        let m = self.find(id).ok_or(EditError::ClipNotFound)?;
        let link = m.clip.link;
        let mut out = vec![m];
        if let Some(link) = link {
            for (i, t) in self.tracks.iter().enumerate() {
                for c in t.clips().iter().filter(|c| c.link == Some(link) && c.id != id) {
                    out.push(Member { track: i, clip: c.clone() });
                }
            }
        }
        Ok(out)
    }

    /// Tracks that shift: those following ripple plus the group's own. The group's tracks must be unlocked.
    #[doc(hidden)]
    pub fn involved_tracks(&self, group: &[Member]) -> Result<Vec<usize>, EditError> {
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let mut s: BTreeSet<usize> = group.iter().map(|m| m.track).collect();
        s.extend((0..self.tracks.len()).filter(|i| self.tracks[*i].follows_ripple()));
        Ok(s.into_iter().collect())
    }

    /// Split edits (J/L cuts): a linked clip that straddles its track's pivot while a partner on another shifting track
    /// starts at or after that track's pivot must move with the partner, or the pair desyncs. Its track then shifts from the
    /// straddler's start, so its room limits the ripple like any other clip (a real collision is still a clamp). Repeats
    /// until no pivot moves; pivots only move left to clip starts, so this ends. `pivot`: track index to the time from which
    /// that track shifts. Clips in `ids` (being removed or trimmed) are ignored.
    #[doc(hidden)]
    pub fn following_straddlers(
        tracks: &[Track],
        pivot: &BTreeMap<usize, Time>,
        ids: &BTreeSet<Id>,
    ) -> BTreeMap<usize, Time> {
        let mut p = pivot.clone();
        loop {
            let mut shifting = BTreeSet::new();
            for (i, t) in &p {
                for c in tracks[*i].clips().iter().filter(|c| c.start >= *t && !ids.contains(&c.id)) {
                    shifting.extend(c.link);
                }
            }
            if shifting.is_empty() {
                break;
            }
            let mut moved = false;
            let entries: Vec<(usize, Time)> = p.iter().map(|(i, t)| (*i, *t)).collect();
            for (i, t) in entries {
                let straddler = tracks[i]
                    .clips()
                    .iter()
                    .find(|c| c.start < t && c.timeline().end() > t && !ids.contains(&c.id))
                    .filter(|c| c.link.is_some_and(|l| shifting.contains(&l)));
                if let Some(c) = straddler {
                    p.insert(i, c.start);
                    moved = true;
                }
            }
            if !moved {
                break;
            }
        }
        p
    }

    /// Clips that can be retimed: media clips and nested sequences (their length is the inner sequence's duration).
    /// Generators (text) and stills have no time axis.
    pub fn can_retime(c: &Clip) -> bool {
        !c.is_generator() && !c.is_still
    }

    /// The clip and its linked partners, refusing locked tracks and clips that cannot be retimed.
    #[doc(hidden)]
    pub fn retime_group(&self, id: Id) -> Result<Vec<Member>, EditError> {
        let group = self.linked_group(id)?;
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        if group.iter().any(|m| !Self::can_retime(&m.clip)) {
            return Err(EditError::SpeedUnsupported);
        }
        Ok(group)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    fn format() -> serde_json::Value {
        json!({"width": 1920, "height": 1080, "frameDuration": {"value": 1, "timescale": 30}, "audioSampleRate": 48000})
    }

    fn timeline(extra: serde_json::Value) -> serde_json::Value {
        let mut t = json!({"id": "00000000-0000-0000-0000-000000000001", "name": "S", "format": format()});
        for (k, v) in extra.as_object().into_iter().flatten() {
            t[k] = v.clone();
        }
        t
    }

    fn read(extra: serde_json::Value) -> Timeline {
        serde_json::from_value(timeline(extra)).unwrap()
    }

    #[test]
    fn format_round_trips_and_rejects_non_positive_values() {
        assert_round_trip::<SequenceFormat>(format());
        assert_round_trip::<SequenceFormat>({
            let mut f = format();
            f["pixelAspect"] = json!({"num": 2, "den": 1});
            f
        });
        for (key, bad) in [
            ("width", json!(0)),
            ("height", json!(-1)),
            ("audioSampleRate", json!(0)),
            ("frameDuration", json!({"value": 0, "timescale": 30})),
        ] {
            let mut f = format();
            f[key] = bad;
            assert!(serde_json::from_value::<SequenceFormat>(f).is_err(), "{key}");
        }
    }

    #[test]
    fn format_drops_a_square_or_broken_pixel_aspect() {
        for bad in [json!({"num": 1, "den": 1}), json!({"num": 1, "den": 9}), json!("wide")] {
            let mut f = format();
            f["pixelAspect"] = bad;
            let parsed: SequenceFormat = serde_json::from_value(f).unwrap();
            assert_eq!(parsed.pixel_aspect_store, None);
        }
    }

    #[test]
    fn timeline_defaults_for_missing_keys() {
        let t = read(json!({}));
        assert!(t.format_locked && t.tracks.is_empty() && t.markers.is_empty() && t.variants.is_empty());
        assert!(t.master_level.is_none() && t.edit_mode_store.is_none() && t.source_patch_store.is_none());
    }

    #[test]
    fn timeline_with_all_store_keys_round_trips() {
        assert_round_trip::<Timeline>(timeline(json!({
            "formatLocked": false, "masterVolumeDB": -6.0, "editMode": "magnetic",
            "timecodeStart": {"value": 3600, "timescale": 1}, "timecodeDisplay": "frames",
            "previewQuality": "half", "channelLayout": "mono", "snappingOff": true, "linkedSelectionOff": true,
            "sourcePatch": {"video": {"isConnected": false}, "audio": {"isConnected": true}},
            "inOutKind": "inOnly", "variants": [], "markers": [], "tracks": [], "captionTracks": []})));
    }

    #[test]
    fn master_volume_is_clamped_and_zero_is_not_stored() {
        assert_eq!(read(json!({"masterVolumeDB": 99.0})).master_level, Some(15.0));
        assert_eq!(read(json!({"masterVolumeDB": -99.0})).master_level, Some(-60.0));
        assert_eq!(read(json!({"masterVolumeDB": 0.0})).master_level, None);
        assert!(serde_json::from_value::<Timeline>(timeline(json!({"masterVolumeDB": "loud"}))).is_err());
    }

    #[test]
    fn empty_master_volume_keys_are_not_kept() {
        assert!(read(json!({"masterVolumeKeys": {"keys": []}})).master_keys_store.is_none());
    }

    #[test]
    fn broken_store_keys_read_as_absent() {
        let t = read(json!({"editMode": "sideways", "timecodeStart": "x", "timecodeDisplay": 3, "previewQuality": [],
                            "channelLayout": "surround", "sourcePatch": {"video": 1}, "snappingOff": "no"}));
        assert_eq!(t.edit_mode_store, None);
        assert_eq!((t.timecode_start_store, t.timecode_display_store, t.preview_quality_store), (None, None, None));
        assert_eq!((t.channel_layout_store, t.source_patch_store, t.snapping_off_store), (None, None, None));
    }

    #[test]
    fn default_values_are_not_kept() {
        let t = read(json!({"editMode": "normal", "snappingOff": false, "linkedSelectionOff": false,
            "sourcePatch": {"video": {"isConnected": true}, "audio": {"isConnected": true}}}));
        assert_eq!((t.edit_mode_store, t.snapping_off_store, t.linked_selection_off_store), (None, None, None));
        assert_eq!(t.source_patch_store, None);
    }

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn clip(n: u128, start: i64, frames: i64, link: Option<u128>) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(100 + n),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, f(frames)),
            f(start),
        );
        c.link = link.map(Id::from_u128);
        c
    }

    fn track(n: u128, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(n), TrackKind::Video);
        t.set_clips(clips);
        t
    }

    fn timeline_of(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(f(1)), tracks)
    }

    #[test]
    fn default_tracks_target_the_first_of_each_kind() {
        let mut ids = sq_core_time::SequentialIds::default();
        let tracks = Timeline::default_tracks(2, 3, &mut ids);
        let shape: Vec<(TrackKind, bool)> = tracks.iter().map(|t| (t.kind, t.is_targeted)).collect();
        assert_eq!(
            shape,
            vec![
                (TrackKind::Video, true),
                (TrackKind::Video, false),
                (TrackKind::Audio, true),
                (TrackKind::Audio, false),
                (TrackKind::Audio, false)
            ]
        );
        assert!(Timeline::default_tracks(0, 0, &mut ids).is_empty());
        assert_eq!((SequenceDefaults::VIDEO_TRACK_COUNT, SequenceDefaults::AUDIO_TRACK_COUNT), (4, 4));
    }

    #[test]
    fn sequence_volume_is_clamped_and_unity_is_not_stored() {
        let mut t = timeline_of(vec![]);
        t.set_master_volume_db(99.0);
        assert_eq!(t.master_volume_db(), 15.0);
        t.set_master_volume_db(f64::NAN);
        assert_eq!((t.master_volume_db(), t.master_level), (0.0, None));
        t.set_master_volume_db(-6.0);
        assert_eq!(t.master_volume_db_at(f(10)), -6.0);
    }

    #[test]
    fn sequence_volume_keys_win_where_they_exist_and_clear_back_to_a_constant() {
        let mut ids = sq_core_time::SequentialIds::default();
        let mut t = timeline_of(vec![]);
        assert!(!t.is_master_volume_keyed());
        let a = t.set_master_volume_key(Time::ZERO, -10.0, &mut ids);
        t.set_master_volume_key(f(30), 99.0, &mut ids);
        assert!(t.is_master_volume_keyed());
        assert_eq!(t.master_volume_keys().key(a).map(|k| k.value), Some(-10.0));
        assert_eq!(t.master_volume_db_at(Time::ZERO), -10.0);
        assert_eq!(t.master_volume_db_at(f(30)), 15.0);
        t.remove_master_volume_key(a);
        assert!(t.is_master_volume_keyed());
        t.clear_master_volume_keys(-3.0);
        assert!(!t.is_master_volume_keyed() && t.master_keys_store.is_none());
        assert_eq!(t.master_volume_db_at(f(5)), -3.0);
        t.remove_master_volume_key(a);
    }

    #[test]
    fn master_gain_is_unity_untouched_linear_when_set_and_follows_the_keys() {
        let mut ids = sq_core_time::SequentialIds::default();
        let mut t = timeline_of(vec![]);
        assert_eq!((t.master_gain(), t.master_gain_at(f(7))), (1.0, 1.0));
        t.set_master_volume_db(-20.0);
        assert!((t.master_gain() - 0.1).abs() < 1e-12);
        t.set_master_volume_db(f64::NEG_INFINITY);
        assert_eq!(t.master_gain(), 0.0);
        t.set_master_volume_key(Time::ZERO, 0.0, &mut ids);
        t.set_master_volume_key(f(30), -20.0, &mut ids);
        assert!((t.master_gain_at(f(30)) - 0.1).abs() < 1e-12);
        assert_eq!(t.master_gain_at(Time::ZERO), 1.0);
    }

    #[test]
    fn linked_group_lists_the_clip_first_then_its_partners() {
        let tl = timeline_of(vec![
            track(1, vec![clip(1, 0, 30, Some(7))]),
            track(2, vec![clip(2, 0, 30, Some(7)), clip(3, 40, 10, None)]),
        ]);
        let group = tl.linked_group(Id::from_u128(2)).unwrap();
        assert_eq!(group.iter().map(|m| (m.track, m.clip.id.as_u128())).collect::<Vec<_>>(), vec![(1, 2), (0, 1)]);
        assert_eq!(tl.linked_group(Id::from_u128(9)).unwrap_err(), EditError::ClipNotFound);
        assert_eq!(tl.find(Id::from_u128(3)).map(|m| m.track), Some(1));
    }

    #[test]
    fn involved_tracks_are_the_group_plus_ripple_followers_and_locked_ones_refuse() {
        let mut tl = timeline_of(vec![track(1, vec![clip(1, 0, 30, None)]), track(2, vec![]), track(3, vec![])]);
        tl.tracks[1].sync_lock = false;
        tl.tracks[2].is_locked = true;
        let group = tl.linked_group(Id::from_u128(1)).unwrap();
        assert_eq!(tl.involved_tracks(&group).unwrap(), vec![0]);
        tl.tracks[0].is_locked = true;
        assert_eq!(tl.involved_tracks(&group), Err(EditError::TrackLocked));
        assert_eq!(tl.retime_group(Id::from_u128(1)).unwrap_err(), EditError::TrackLocked);
    }

    #[test]
    fn a_straddling_split_edit_partner_pulls_the_pivot_left() {
        // V: one long clip across the pivot, linked to an A clip that starts after the pivot.
        let tl = timeline_of(vec![track(1, vec![clip(1, 0, 100, Some(7))]), track(2, vec![clip(2, 60, 30, Some(7))])]);
        let pivot = BTreeMap::from([(0, f(50)), (1, f(50))]);
        let moved = Timeline::following_straddlers(&tl.tracks, &pivot, &BTreeSet::new());
        assert_eq!(moved, BTreeMap::from([(0, f(0)), (1, f(50))]));
        // The clips being edited are ignored.
        let ignored = Timeline::following_straddlers(&tl.tracks, &pivot, &BTreeSet::from([Id::from_u128(1)]));
        assert_eq!(ignored, pivot);
    }

    #[test]
    fn only_media_clips_and_nested_sequences_can_be_retimed() {
        let mut c = clip(1, 0, 30, None);
        assert!(Timeline::can_retime(&c));
        c.sequence = Some(Id::from_u128(5));
        assert!(Timeline::can_retime(&c));
        c.is_still = true;
        assert!(!Timeline::can_retime(&c));
        let tl = timeline_of(vec![track(1, vec![c])]);
        assert_eq!(tl.retime_group(Id::from_u128(1)).unwrap_err(), EditError::SpeedUnsupported);
    }

    #[test]
    fn frame_duration_reads_and_writes_the_format() {
        let mut t = timeline_of(vec![]);
        t.set_frame_duration(Time::new(1, 25));
        assert_eq!(t.frame_duration(), Time::new(1, 25));
        assert_eq!(t.format.frame_duration, Time::new(1, 25));
    }
}

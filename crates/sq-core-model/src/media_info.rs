// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MediaInfo.swift (saved types, moved down; filled by task S-2; derived properties: task M-4). AudioChannelMap (AudioChannelMap.swift) lives
// here too because only AudioTrackInfo uses it. The `lenient` helpers are the one home of Swift's `try?` decoding.

use crate::labels::path_extension;
use crate::{ColorSpaceID, PixelAspect};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize};
use sq_core_time::{Time, Timestamp};

/// Swift `try? decodeIfPresent(T)`: a value of the wrong shape (or `null`) reads as absent. Pair with `default`.
pub(crate) fn lenient<'de, D, T>(d: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned,
{
    Ok(T::deserialize(serde_json::Value::deserialize(d)?).ok())
}

/// `lenient` for a field that is not optional: the type's default replaces a broken value.
pub(crate) fn lenient_or_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned + Default,
{
    lenient(d).map(Option::unwrap_or_default)
}

/// Swift `(try? decodeIfPresent(Bool)) == true ? true : nil`: stored only when set.
pub(crate) fn lenient_true<'de, D: Deserializer<'de>>(d: D) -> Result<Option<bool>, D::Error> {
    Ok(lenient::<D, bool>(d)?.filter(|b| *b))
}

/// A strictly positive integer (frame size, sample rate).
pub(crate) fn positive_int<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    let v = i64::deserialize(d)?;
    if v > 0 { Ok(v) } else { Err(serde::de::Error::custom(format!("must be positive, got {v}"))) }
}

/// A frame duration: greater than zero.
pub(crate) fn positive_time<'de, D: Deserializer<'de>>(d: D) -> Result<Time, D::Error> {
    let t = Time::deserialize(d)?;
    if t > Time::ZERO {
        Ok(t)
    } else {
        Err(serde::de::Error::custom(format!("frame duration must be positive, got {}/{}", t.value(), t.timescale())))
    }
}

/// An ISO 8601 date that reads as absent when malformed.
fn lenient_date<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Timestamp>, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    Ok(sq_core_time::timestamp::iso8601::deserialize(v).ok())
}

fn is_false(b: &bool) -> bool {
    !*b
}

/// Probed properties of a media file. Stored on `MediaRef.info`; filled by the media readers.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaInfo {
    /// Length of the file.
    pub duration: Time,
    /// Picture stream, when there is one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video: Option<VideoTrackInfo>,
    /// Sound stream, when there is one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio: Option<AudioTrackInfo>,
    /// Source color space detected once at import; `None` = not detected (treated as Rec.709).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detected_color_space: Option<ColorSpaceID>,
    /// Name of the camera look LUT embedded in the file, if any.
    #[serde(rename = "embeddedLUTName", default, skip_serializing_if = "Option::is_none")]
    pub embedded_lut_name: Option<String>,
    /// Still image: `video` carries its size, there is no audio, and clips may be trimmed to any length.
    #[serde(default)]
    pub is_still: bool,
    /// True once the file's sound was probed with the multi-track channel count; `None` = not yet.
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "lenient")]
    pub sound_probed: Option<bool>,
    /// When the file was shot (container creation date); `None` = unknown.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "sq_core_time::timestamp::iso8601::option::serialize",
        deserialize_with = "lenient_date"
    )]
    pub created: Option<Timestamp>,
    /// Camera model from the file's metadata; `None` = none found.
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "lenient")]
    pub camera_model: Option<String>,
    /// True once date and camera were looked up (found or not).
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "lenient")]
    pub shoot_probed: Option<bool>,
}

/// Which field of an interlaced picture comes first in time.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FieldOrder {
    /// The top field is earlier.
    TopFirst,
    /// The bottom field is earlier.
    BottomFirst,
}

fn rotation_degrees<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    Ok(i64::deserialize(d)?.rem_euclid(360))
}

/// The picture stream of a media file.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoTrackInfo {
    /// Stored width.
    pub width: i64,
    /// Stored height.
    pub height: i64,
    /// FourCC, e.g. "avc1".
    pub codec: String,
    /// Bits per channel.
    pub bit_depth: i64,
    /// "4:2:0", "4:2:2" or "4:4:4".
    pub chroma: String,
    /// Duration of one frame (positive).
    #[serde(deserialize_with = "positive_time")]
    pub nominal_frame_duration: Time,
    /// Frame times are not on a regular grid.
    pub is_variable_frame_rate: bool,
    /// `None` = untagged in the file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_primaries: Option<String>,
    /// `None` = untagged in the file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transfer: Option<String>,
    /// `None` = untagged in the file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub matrix: Option<String>,
    /// Clockwise degrees (0, 90, 180, 270) the decoded picture is turned to be upright.
    #[serde(default, deserialize_with = "rotation_degrees")]
    pub rotation: i64,
    /// Shape of a stored pixel as the file tags it; written only when not square. A malformed ratio reads as square.
    #[serde(
        default = "PixelAspect::square",
        skip_serializing_if = "PixelAspect::is_square",
        deserialize_with = "lenient_square"
    )]
    pub pixel_aspect: PixelAspect,
    /// The pixel aspect chosen for the media item; `None` = the file's.
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "lenient")]
    pub pixel_aspect_override: Option<PixelAspect>,
    /// Interlaced material: the earlier field. `None` = progressive; an unknown value reads as progressive.
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "lenient")]
    pub field_order: Option<FieldOrder>,
    /// Deinterlace switched off for the media item; written only when true.
    #[serde(default, skip_serializing_if = "is_false", deserialize_with = "lenient_or_default")]
    pub deinterlace_off: bool,
}

fn lenient_square<'de, D: Deserializer<'de>>(d: D) -> Result<PixelAspect, D::Error> {
    Ok(lenient(d)?.unwrap_or_else(PixelAspect::square))
}

/// Which channels of a media file feed a clip's two sides. Channels are numbered from 0 in file order.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct AudioChannelMap {
    left: Vec<i64>,
    right: Vec<i64>,
}

impl AudioChannelMap {
    /// Most channels one side takes.
    pub const MAX_CHANNELS_PER_SIDE: usize = 16;

    /// Sorted, duplicate-free map; `None` when a channel is negative, both sides are empty or a side lists more than
    /// `MAX_CHANNELS_PER_SIDE` channels.
    pub fn new(left: &[i64], right: &[i64]) -> Option<AudioChannelMap> {
        let sorted = |c: &[i64]| {
            let mut v = c.to_vec();
            v.sort_unstable();
            v.dedup();
            v
        };
        let (l, r) = (sorted(left), sorted(right));
        let ok = !(l.is_empty() && r.is_empty())
            && l.len() <= Self::MAX_CHANNELS_PER_SIDE
            && r.len() <= Self::MAX_CHANNELS_PER_SIDE
            && l.iter().chain(&r).all(|c| *c >= 0);
        ok.then_some(AudioChannelMap { left: l, right: r })
    }

    /// Source channels heard on the left side, ascending.
    pub fn left(&self) -> &[i64] {
        &self.left
    }

    /// Source channels heard on the right side, ascending.
    pub fn right(&self) -> &[i64] {
        &self.right
    }

    /// The map for a file with `channels` channels: channels the file lacks are dropped. `None` when a side that was
    /// in use loses all its channels.
    pub fn fitting(&self, channels: i64) -> Option<AudioChannelMap> {
        let l: Vec<i64> = self.left.iter().copied().filter(|c| *c < channels).collect();
        let r: Vec<i64> = self.right.iter().copied().filter(|c| *c < channels).collect();
        if l.is_empty() != self.left.is_empty() || r.is_empty() != self.right.is_empty() {
            return None;
        }
        AudioChannelMap::new(&l, &r)
    }
}

impl AudioChannelMap {
    /// One channel in the center.
    pub fn mono(channel: i64) -> Option<AudioChannelMap> {
        AudioChannelMap::new(&[channel], &[channel])
    }

    /// One channel per side.
    pub fn stereo(l: i64, r: i64) -> Option<AudioChannelMap> {
        if l == r { None } else { AudioChannelMap::new(&[l], &[r]) }
    }

    /// Two channels, both in the center (two microphones on one clip).
    pub fn dual_mono(a: i64, b: i64) -> Option<AudioChannelMap> {
        if a == b { None } else { AudioChannelMap::new(&[a, b], &[a, b]) }
    }

    /// What the file's own layout plays, as a map; `None` when that is not known from the probe info. An MXF's channels
    /// 1 + 2 sit in the center (its mono tracks are microphones); any other file with one or two channels plays them as
    /// they are. More channels are the reader's own mix, which no map names.
    pub fn file_layout(audio: &AudioTrackInfo, path: &str) -> Option<AudioChannelMap> {
        let ext = path_extension(path).to_lowercase();
        let mut audio = audio.clone();
        audio.channels = audio.first_track_channels.unwrap_or(audio.channels); // the file's own layout is its first track
        audio.channels = audio.mappable_channels(path);
        if ext == "mxf" {
            if audio.codec != "PCM" {
                return None; // probed by another reader: layout unknown
            }
            return match audio.channels {
                c if c > 1 => AudioChannelMap::dual_mono(0, 1),
                1 => AudioChannelMap::mono(0),
                _ => None,
            };
        }
        // "PCM" is how the MXF and the WebM reader name their sound: outside a WebM it may be an MXF under another name.
        if audio.codec == "PCM" && !["webm", "mkv", "mka"].contains(&ext.as_str()) {
            return None;
        }
        match audio.channels {
            2 => AudioChannelMap::stereo(0, 1),
            1 => AudioChannelMap::mono(0),
            _ => None,
        }
    }

    /// What is stored when `self` is chosen for a file: the fitted map, or `None` when it does not fit (see `fitting`) or
    /// names exactly what the file's layout plays anyway (a choice that changes nothing is no choice: the label says File
    /// Layout and the project needs no newer file version).
    pub fn stored(&self, audio: &AudioTrackInfo, path: &str) -> Option<AudioChannelMap> {
        let fitted = self.fitting(audio.mappable_channels(path))?;
        (Some(&fitted) != Self::file_layout(audio, path).as_ref()).then_some(fitted)
    }
}

impl AudioTrackInfo {
    /// Channels a map may address: the file's, but a WebM / Matroska file is read by our own decoder that delivers two (a
    /// 5.1 mix is not offered, so no map names a channel the reader cannot deliver).
    pub fn mappable_channels(&self, path: &str) -> i64 {
        if ["webm", "mkv", "mka"].contains(&path_extension(path).to_lowercase().as_str()) {
            self.channels.min(2)
        } else {
            self.channels
        }
    }
}

/// The sound stream of a media file.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "AudioTrackInfoFields")]
pub struct AudioTrackInfo {
    /// Samples per second.
    pub sample_rate: i64,
    /// Channels across all tracks.
    pub channels: i64,
    /// Codec name.
    pub codec: String,
    /// The channels chosen for the media item; `None` = the file's own layout.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel_map: Option<AudioChannelMap>,
    /// Channels of the first track when the file has several; `None` = one track or probed before this existed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_track_channels: Option<i64>,
}

/// `AudioTrackInfo` as stored: the map is fitted to `channels` and dropped when malformed.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AudioTrackInfoFields {
    sample_rate: i64,
    channels: i64,
    codec: String,
    #[serde(default, deserialize_with = "lenient")]
    channel_map: Option<AudioChannelMap>,
    #[serde(default, deserialize_with = "lenient")]
    first_track_channels: Option<i64>,
}

impl From<AudioTrackInfoFields> for AudioTrackInfo {
    fn from(f: AudioTrackInfoFields) -> Self {
        AudioTrackInfo {
            sample_rate: f.sample_rate,
            channels: f.channels,
            codec: f.codec,
            channel_map: f.channel_map.and_then(|m| m.fitting(f.channels)),
            first_track_channels: f.first_track_channels,
        }
    }
}

/// Test helper: parses `json` as `T`, writes it back and compares both as JSON values.
impl MediaInfo {
    /// True for media imported before color detection existed (v6 files): the app should run color detection on
    /// open/relink and store the result.
    pub fn needs_color_detection(&self) -> bool {
        self.detected_color_space.is_none()
    }

    /// Effective color space of the media when a clip does not override it.
    pub fn color_space(&self) -> ColorSpaceID {
        self.detected_color_space.unwrap_or(ColorSpaceID::Rec709)
    }
}

impl VideoTrackInfo {
    /// Whether the picture is interlaced.
    pub fn is_interlaced(&self) -> bool {
        self.field_order.is_some()
    }

    /// The field order the decoder deinterlaces with: `None` for progressive media and when the item's switch is off.
    pub fn deinterlace_field_order(&self) -> Option<FieldOrder> {
        if self.deinterlace_off { None } else { self.field_order }
    }

    /// Width as shown (upright): stored width desqueezed by the pixel aspect, swapped for 90/270.
    pub fn display_width(&self) -> i64 {
        if self.rotation == 90 || self.rotation == 270 { self.height } else { self.desqueezed_width() }
    }

    /// Height as shown (upright).
    pub fn display_height(&self) -> i64 {
        if self.rotation == 90 || self.rotation == 270 { self.desqueezed_width() } else { self.height }
    }
}

#[cfg(test)]
pub(crate) fn assert_round_trip<T: Serialize + DeserializeOwned>(json: serde_json::Value) {
    let parsed: T = serde_json::from_value(json.clone()).unwrap();
    assert_eq!(serde_json::to_value(&parsed).unwrap(), json);
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn video() -> serde_json::Value {
        json!({"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
               "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false, "rotation": 0})
    }

    #[test]
    fn media_info_round_trips_with_optional_keys() {
        assert_round_trip::<MediaInfo>(json!({"duration": {"value": 5, "timescale": 1}, "isStill": false}));
        assert_round_trip::<MediaInfo>(json!({
            "duration": {"value": 5, "timescale": 1}, "video": video(), "isStill": true, "soundProbed": true,
            "created": "2026-01-02T03:04:05Z", "cameraModel": "FX3", "shootProbed": true, "embeddedLUTName": "SLog"}));
    }

    #[test]
    fn media_info_drops_malformed_lenient_keys() {
        let info: MediaInfo = serde_json::from_value(json!({
            "duration": {"value": 5, "timescale": 1}, "soundProbed": "yes", "created": "yesterday",
            "cameraModel": 7, "shootProbed": {}}))
        .unwrap();
        assert_eq!((info.sound_probed, info.created, info.camera_model, info.shoot_probed), (None, None, None, None));
        assert!(!info.is_still);
    }

    #[test]
    fn video_info_rejects_non_positive_frame_duration() {
        let mut v = video();
        v["nominalFrameDuration"] = json!({"value": 0, "timescale": 30});
        assert!(serde_json::from_value::<VideoTrackInfo>(v).is_err());
    }

    #[test]
    fn video_info_normalizes_rotation_and_drops_bad_pixel_aspect() {
        let mut v = video();
        v["rotation"] = json!(-90);
        v["pixelAspect"] = json!({"num": 1, "den": 9});
        v["pixelAspectOverride"] = json!({"num": 0, "den": 1});
        v["fieldOrder"] = json!("diagonal");
        v["deinterlaceOff"] = json!("maybe");
        let info: VideoTrackInfo = serde_json::from_value(v).unwrap();
        assert_eq!(info.rotation, 270);
        assert!(info.pixel_aspect.is_square());
        assert_eq!((info.pixel_aspect_override, info.field_order, info.deinterlace_off), (None, None, false));
    }

    #[test]
    fn video_info_writes_pixel_aspect_keys_only_when_they_say_something() {
        let mut v = video();
        assert_round_trip::<VideoTrackInfo>(v.clone());
        v["pixelAspect"] = json!({"num": 2, "den": 1});
        v["pixelAspectOverride"] = json!({"num": 1, "den": 1});
        v["fieldOrder"] = json!("topFirst");
        v["deinterlaceOff"] = json!(true);
        assert_round_trip::<VideoTrackInfo>(v);
    }

    #[test]
    fn audio_info_fits_or_drops_the_channel_map() {
        let audio = |map: serde_json::Value| -> AudioTrackInfo {
            serde_json::from_value(json!({"sampleRate": 48000, "channels": 2, "codec": "aac", "channelMap": map}))
                .unwrap()
        };
        let kept = audio(json!({"left": [0], "right": [1]}));
        assert_eq!(kept.channel_map.as_ref().map(|m| (m.left(), m.right())), Some((&[0][..], &[1][..])));
        assert_eq!(audio(json!({"left": [0], "right": [5]})).channel_map, None);
        assert_eq!(audio(json!({"left": "x"})).channel_map, None);
        let wide = audio(json!({"left": [0, 1, 7], "right": [0, 1, 7]}));
        assert_eq!(wide.channel_map.map(|m| m.left().to_vec()), Some(vec![0, 1]));
    }

    #[test]
    fn audio_info_round_trips() {
        assert_round_trip::<AudioTrackInfo>(json!({"sampleRate": 48000, "channels": 2, "codec": "aac"}));
        assert_round_trip::<AudioTrackInfo>(json!({"sampleRate": 48000, "channels": 4, "codec": "PCM",
            "channelMap": {"left": [0, 1], "right": [0, 1]}, "firstTrackChannels": 2}));
    }

    #[test]
    fn channel_map_rules() {
        assert!(AudioChannelMap::new(&[], &[]).is_none());
        assert!(AudioChannelMap::new(&[-1], &[]).is_none());
        assert!(AudioChannelMap::new(&(0..17).collect::<Vec<_>>(), &[]).is_none());
        assert_eq!(AudioChannelMap::new(&[2, 0, 2], &[1]).map(|m| m.left().to_vec()), Some(vec![0, 2]));
    }

    #[test]
    fn the_file_layout_is_not_stored_as_a_choice_and_a_map_is_fitted_to_the_file() {
        let audio = |channels: i64, codec: &str| -> AudioTrackInfo {
            serde_json::from_value(json!({"sampleRate": 48000, "channels": channels, "codec": codec})).unwrap()
        };
        let stereo = audio(2, "aac");
        assert_eq!(AudioChannelMap::file_layout(&stereo, "/a.mov"), AudioChannelMap::stereo(0, 1));
        assert_eq!(AudioChannelMap::file_layout(&audio(1, "aac"), "/a.mov"), AudioChannelMap::mono(0));
        assert_eq!(
            AudioChannelMap::file_layout(&audio(6, "aac"), "/a.mov"),
            None,
            "more channels: the reader's own mix"
        );
        assert_eq!(AudioChannelMap::file_layout(&audio(2, "PCM"), "/a.mxf"), AudioChannelMap::dual_mono(0, 1));
        assert_eq!(AudioChannelMap::file_layout(&audio(2, "PCM"), "/a.mov"), None, "PCM outside MXF and WebM: unknown");
        let same = AudioChannelMap::stereo(0, 1).unwrap();
        let swapped = AudioChannelMap::stereo(1, 0).unwrap();
        assert_eq!(same.stored(&stereo, "/a.mov"), None, "names what the file plays anyway");
        assert_eq!(swapped.stored(&stereo, "/a.mov"), Some(swapped.clone()));
        assert_eq!(AudioChannelMap::mono(3).unwrap().stored(&stereo, "/a.mov"), None, "a side loses all its channels");
        assert_eq!(audio(6, "opus").mappable_channels("/a.webm"), 2);
        assert_eq!(audio(6, "opus").mappable_channels("/a.mov"), 6);
    }
}

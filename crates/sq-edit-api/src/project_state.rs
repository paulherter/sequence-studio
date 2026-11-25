// Swift: ProjectState.swift
//! Read model of a project for agents: compact, ids and rational times only.

use serde::{Deserialize, Serialize};
use sq_core_model::{Clip, ClipSpeed, Project, Timeline, Track, TrackKind, Transition};
use sq_core_time::{Id, Time, TimeRange};

/// Read model of a project for agents: compact, ids and rational times only. Ids are the model's own persisted UUIDs, so
/// they stay valid across undo/redo and save + reopen. Bookmarks are left out; media file paths are in.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectState {
    /// Project id.
    pub id: Id,
    /// Project name.
    pub name: String,
    /// The sequence shown in the timeline panel.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_sequence: Option<Id>,
    /// Media items.
    pub media: Vec<MediaState>,
    /// Sequences.
    pub sequences: Vec<SequenceState>,
    /// The playhead of the open sequence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub playhead: Option<Time>,
    /// The project file, when saved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    /// Unsaved changes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dirty: Option<bool>,
}

impl ProjectState {
    /// The read model of `p`.
    pub fn new(p: &Project) -> ProjectState {
        ProjectState {
            id: p.id,
            name: p.name.clone(),
            active_sequence: p.active_timeline,
            media: p
                .media
                .iter()
                .map(|m| {
                    let video = m.info.as_ref().and_then(|i| i.video.as_ref());
                    MediaState {
                        id: m.id,
                        name: m.name.clone(),
                        duration: m.info.as_ref().map(|i| i.duration).or(m.duration),
                        path: m.path.clone(),
                        size: m.fingerprint.size,
                        width: video.map(|v| v.display_width()),
                        height: video.map(|v| v.display_height()),
                        fps: video.map(|v| FpsState::of(v.nominal_frame_duration)),
                        has_audio: m.info.as_ref().map(|i| i.audio.is_some()),
                    }
                })
                .collect(),
            sequences: p.timelines.iter().map(SequenceState::new).collect(),
            playhead: None,
            file: None,
            dirty: None,
        }
    }
}

/// A frame rate as the ratio of frames per second (`30000/1001`) and its decimal value.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct FpsState {
    /// Frames ...
    pub num: i64,
    /// ... per this many seconds.
    pub den: i64,
    /// `num / den`.
    pub value: f64,
}

impl FpsState {
    /// The rate of a frame of `frame_duration`.
    pub fn of(frame_duration: Time) -> FpsState {
        let (num, den) = (frame_duration.timescale(), frame_duration.value());
        FpsState { num, den, value: if den == 0 { 0.0 } else { num as f64 / den as f64 } }
    }
}

/// A media item.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaState {
    /// Media id.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Length, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<Time>,
    /// The file the item reads.
    pub path: String,
    /// File size in bytes.
    pub size: i64,
    /// Picture width as shown (upright); absent for sound.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<i64>,
    /// Picture height as shown (upright); absent for sound.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<i64>,
    /// Frame rate of the picture; absent for sound and stills' absence of info.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fps: Option<FpsState>,
    /// Whether the file has a sound track; absent while not probed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_audio: Option<bool>,
}

/// A sequence with its tracks and markers.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SequenceState {
    /// Sequence id.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Picture width.
    pub width: i64,
    /// Picture height.
    pub height: i64,
    /// Duration of one frame.
    pub frame_duration: Time,
    /// Frame rate.
    pub fps: FpsState,
    /// Audio sample rate in Hz.
    pub sample_rate: i64,
    /// End of the last clip.
    pub duration: Time,
    /// In/out range.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub in_out: Option<TimeRange>,
    /// Tracks, bottom to top as stored.
    pub tracks: Vec<TrackState>,
    /// Sequence markers.
    pub markers: Vec<MarkerState>,
    /// Transitions of all tracks (what `addTransition` made); absent when none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub transitions: Vec<TransitionState>,
}

/// A transition as agents read it: the kind names match `GET /v1/transitions`, `outgoing` / `incoming` are the clips of
/// `addTransition between`; only `incoming` = fade in at that clip's head, only `outgoing` = fade out at its tail.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransitionState {
    /// Transition id (`removeTransition`).
    pub id: Id,
    /// The track holding it.
    pub track: Id,
    /// Kind wire name.
    pub kind: String,
    /// Requested length.
    pub duration: Time,
    /// "center", "startAtCut" or "endAtCut" as stored.
    pub alignment: String,
    /// Clip before the cut.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outgoing: Option<Id>,
    /// Clip after the cut.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub incoming: Option<Id>,
}

impl TransitionState {
    /// The read model of `x` on `track`.
    pub fn new(x: &Transition, track: Id) -> TransitionState {
        let name = |v: Option<serde_json::Value>| v.and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default();
        TransitionState {
            id: x.id,
            track,
            kind: name(serde_json::to_value(x.kind).ok()),
            duration: x.duration,
            alignment: name(serde_json::to_value(x.alignment).ok()),
            outgoing: x.outgoing,
            incoming: x.incoming,
        }
    }

    /// Every transition of `t`, track by track.
    pub fn all(t: &Timeline) -> Vec<TransitionState> {
        t.tracks.iter().flat_map(|tr| tr.transitions.iter().map(|x| TransitionState::new(x, tr.id))).collect()
    }
}

impl SequenceState {
    /// The read model of `t`.
    pub fn new(t: &Timeline) -> SequenceState {
        SequenceState {
            id: t.id,
            name: t.name.clone(),
            width: t.format.width,
            height: t.format.height,
            frame_duration: t.frame_duration(),
            fps: FpsState::of(t.frame_duration()),
            sample_rate: t.format.audio_sample_rate,
            duration: t.duration(),
            in_out: t.in_out,
            tracks: t.tracks.iter().map(TrackState::new).collect(),
            markers: t
                .markers
                .iter()
                .map(|m| MarkerState { id: m.id, time: m.time, duration: m.duration, name: m.name.clone() })
                .collect(),
            transitions: TransitionState::all(t),
        }
    }
}

/// A track with its clips.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackState {
    /// Track id.
    pub id: Id,
    /// "video" or "audio".
    pub kind: String,
    /// Shown name.
    pub name: String,
    /// Whether edits are refused.
    pub locked: bool,
    /// Whether the track's sound is off.
    pub muted: bool,
    /// Whether only soloed tracks play.
    pub solo: bool,
    /// Whether the track's picture shows.
    pub visible: bool,
    /// Clips in track order.
    pub clips: Vec<ClipState>,
}

impl TrackState {
    /// The read model of `t`.
    pub fn new(t: &Track) -> TrackState {
        TrackState {
            id: t.id,
            kind: match t.kind {
                TrackKind::Video => "video",
                TrackKind::Audio => "audio",
            }
            .to_string(),
            name: t.name.clone(),
            locked: t.is_locked,
            muted: t.is_muted,
            solo: t.is_solo,
            visible: t.is_visible,
            clips: t.clips().iter().map(|c| ClipState::new(c, t.id)).collect(),
        }
    }
}

/// A sequence marker.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkerState {
    /// Marker id.
    pub id: Id,
    /// Position.
    pub time: Time,
    /// Length.
    pub duration: Time,
    /// Shown name.
    pub name: String,
}

/// An effect on a clip.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EffectState {
    /// Effect id.
    pub id: Id,
    /// Effect kind.
    pub kind: String,
    /// Whether the effect is on.
    pub enabled: bool,
}

/// A clip on a track.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipState {
    /// Clip id.
    pub id: Id,
    /// The track holding the clip.
    pub track: Id,
    /// Shown name.
    pub name: String,
    /// Media item, nested sequence or (generator) the clip's own id.
    pub media: Id,
    /// "media", "sequence", "generator:<kind>".
    pub r#type: String,
    /// Position on the track.
    pub start: Time,
    /// Length on the track.
    pub duration: Time,
    /// Portion of the source used.
    pub source: TimeRange,
    /// Linked partner group.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<Id>,
    /// Whether the clip plays.
    pub enabled: bool,
    /// Constant speed as a ratio (`num/den`, 1/1 = 100 %); absent when time-remapped.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed: Option<ClipSpeed>,
    /// Effects in order.
    pub effects: Vec<EffectState>,
}

impl ClipState {
    /// The read model of `c` on `track`.
    pub fn new(c: &Clip, track: Id) -> ClipState {
        let r#type = if c.sequence.is_some() {
            "sequence".to_string()
        } else if let Some(g) = &c.generator {
            format!("generator:{}", g.kind)
        } else {
            "media".to_string()
        };
        ClipState {
            id: c.id,
            track,
            name: c.name.clone(),
            media: c.media,
            r#type,
            start: c.start,
            duration: c.duration(),
            source: c.source,
            link: c.link,
            enabled: c.is_enabled,
            speed: if c.speed_keys.is_none() { Some(c.speed) } else { None },
            effects: c
                .effects
                .iter()
                .map(|e| EffectState { id: e.id, kind: e.kind.clone(), enabled: e.enabled })
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit_transaction::fixture::{Fixture, s};

    #[test]
    fn state_carries_rational_times_and_effects() {
        let f = Fixture::new();
        let st = ProjectState::new(&f.project);
        assert_eq!(st.active_sequence, f.project.active_timeline);
        let clip = &st.sequences[0].tracks[0].clips[0];
        assert!(clip.id == f.a && clip.start == Time::ZERO && clip.duration == s(4) && clip.source.start == s(2));
        assert!(clip.link.is_some() && Some(clip.media) == f.project.media.first().map(|m| m.id));
        assert_eq!(clip.r#type, "media");
        assert_eq!(clip.speed, Some(f.project.timelines[0].tracks[0].clips()[0].speed));
        let json = serde_json::to_string(&st).unwrap_or_default();
        assert!(json.contains("\"timescale\"") && json.contains("\"type\":\"media\""));
        assert!(json.contains("/x/m.mov")); // the media path is read model
        assert!(json.contains("\"muted\":false") && json.contains("\"sampleRate\":48000"));
        assert_eq!(serde_json::from_str::<ProjectState>(&json).ok(), Some(st));
    }
}

//! Where a default transition goes, and the default lengths.

use std::collections::BTreeSet;

use crate::EdgeSelection;
use sq_core_effects::transition::{TimelineTransitions, TransitionPoint};
use sq_core_model::{ClipEdge, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time};
use sq_library::library_folder_store::SettingsStore;

/// Resolves the transition points a command works on.
pub enum TransitionTargets {}

/// One place for a transition.
// Swift: TransitionTargets.swift:6
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TransitionTarget {
    // Swift: TransitionTargets.swift:7
    pub track: Id,
    // Swift: TransitionTargets.swift:8
    pub point: TransitionPoint,
}

impl TransitionTargets {
    /// The edit points for `kinds` from the edge selection, else the selection, else the targeted tracks at the playhead.
    // Swift: TransitionTargets.swift:14
    pub fn resolve(
        t: &Timeline,
        kinds: &[TrackKind],
        edges: Option<&EdgeSelection>,
        selection: &BTreeSet<Id>,
        playhead: Time,
        clip_edges_only: bool,
    ) -> Vec<TransitionTarget> {
        let mut out: Vec<TransitionTarget> = Vec::new();
        let mut add = |target: TransitionTarget| {
            if !out.contains(&target) {
                out.push(target);
            }
        };
        let usable = |track: &Track| kinds.contains(&track.kind) && !track.is_locked;
        // The point an edge of `clip` stands at: a cut when a clip touches it, else the clip's own edge.
        let point = |clip: Id, edge: ClipEdge, track: &Track| -> Option<TransitionPoint> {
            let cs = track.clips();
            let i = cs.iter().position(|c| c.id == clip)?;
            if clip_edges_only {
                return Some(if edge == ClipEdge::Head {
                    TransitionPoint::Head(clip)
                } else {
                    TransitionPoint::Tail(clip)
                });
            }
            Some(match edge {
                ClipEdge::Head if i > 0 && cs[i - 1].timeline().end() == cs[i].start => {
                    TransitionPoint::Cut { outgoing: cs[i - 1].id, incoming: clip }
                }
                ClipEdge::Head => TransitionPoint::Head(clip),
                ClipEdge::Tail if i + 1 < cs.len() && cs[i].timeline().end() == cs[i + 1].start => {
                    TransitionPoint::Cut { outgoing: clip, incoming: cs[i + 1].id }
                }
                ClipEdge::Tail => TransitionPoint::Tail(clip),
            })
        };
        if let Some(edges) = edges.filter(|e| !e.edges.is_empty()) {
            for r in &edges.edges {
                let Some(track) = t.tracks.iter().find(|tr| tr.clip(r.clip).is_some()) else { continue };
                if !usable(track) {
                    continue;
                }
                if let Some(p) = point(r.clip, r.edge, track) {
                    add(TransitionTarget { track: track.id, point: p });
                }
            }
            return out;
        }
        if !selection.is_empty() {
            for track in t.tracks.iter().filter(|tr| usable(tr)) {
                for c in track.clips().iter().filter(|c| selection.contains(&c.id)) {
                    for edge in [ClipEdge::Head, ClipEdge::Tail] {
                        if let Some(p) = point(c.id, edge, track) {
                            add(TransitionTarget { track: track.id, point: p });
                        }
                    }
                }
            }
            return out;
        }
        for track in t.tracks.iter().filter(|tr| usable(tr) && tr.is_targeted) {
            let Some(mut p) = t.transition_point_near(playhead, track.id) else { continue };
            if let (true, TransitionPoint::Cut { incoming, .. }) = (clip_edges_only, p) {
                p = TransitionPoint::Head(incoming);
            }
            add(TransitionTarget { track: track.id, point: p });
        }
        out
    }
}

/// The user's default transition lengths from Settings.
// Swift: TransitionTargets.swift:63
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransitionDefaults {
    // Swift: TransitionTargets.swift:65
    pub video_frames: i64,
    // Swift: TransitionTargets.swift:67
    pub audio_seconds: f64,
}

impl TransitionDefaults {
    // Swift: TransitionTargets.swift:68
    pub const STANDARD: TransitionDefaults = TransitionDefaults { video_frames: 0, audio_seconds: 1.0 };
    // Swift: TransitionTargets.swift:74
    pub const VIDEO_KEY: &'static str = "settings.videoTransitionFrames";
    // Swift: TransitionTargets.swift:75
    pub const AUDIO_KEY: &'static str = "settings.audioTransitionSeconds";

    // Swift: TransitionTargets.swift:70
    pub fn new(video_frames: i64, audio_seconds: f64) -> TransitionDefaults {
        TransitionDefaults { video_frames, audio_seconds }
    }
    // Swift: TransitionTargets.swift:77
    pub fn load(settings: &dyn SettingsStore) -> TransitionDefaults {
        let mut s = TransitionDefaults::STANDARD;
        let text = |key: &str| settings.data(key).and_then(|b| String::from_utf8(b).ok());
        if let Some(v) = text(Self::VIDEO_KEY).and_then(|t| t.trim().parse::<i64>().ok())
            && (0..=10_000).contains(&v)
        {
            s.video_frames = v;
        }
        if let Some(v) = text(Self::AUDIO_KEY).and_then(|t| t.trim().parse::<f64>().ok())
            && v.is_finite()
            && v > 0.0
            && v <= 600.0
        {
            s.audio_seconds = v;
        }
        s
    }
    // Swift: TransitionTargets.swift:87
    pub fn save(&self, settings: &mut dyn SettingsStore) {
        settings.set_data(Self::VIDEO_KEY, self.video_frames.to_string().into_bytes());
        settings.set_data(Self::AUDIO_KEY, self.audio_seconds.to_string().into_bytes());
    }
    // Swift: TransitionTargets.swift:94
    pub fn duration(&self, kind: TrackKind, frame_duration: Time) -> Time {
        match kind {
            TrackKind::Video if self.video_frames > 0 => frame_duration * self.video_frames,
            TrackKind::Video => <Timeline as TimelineTransitions>::default_transition_duration(frame_duration),
            TrackKind::Audio => {
                let frames = (self.audio_seconds * frame_duration.timescale() as f64 / frame_duration.value() as f64)
                    .round() as i64;
                frame_duration * frames.max(1)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_library::library_folder_store::MemorySettings;

    #[test]
    fn defaults_round_trip_and_reject_out_of_range_values() {
        let mut m = MemorySettings::default();
        assert_eq!(TransitionDefaults::load(&m), TransitionDefaults::STANDARD);
        TransitionDefaults::new(12, 2.5).save(&mut m);
        assert_eq!(TransitionDefaults::load(&m), TransitionDefaults::new(12, 2.5));
        m.set_data(TransitionDefaults::VIDEO_KEY, b"-3".to_vec());
        m.set_data(TransitionDefaults::AUDIO_KEY, b"0".to_vec());
        assert_eq!(TransitionDefaults::load(&m), TransitionDefaults::STANDARD);
    }

    #[test]
    fn durations_are_whole_frames() {
        let fd = Time::new(1, 30);
        assert_eq!(TransitionDefaults::new(12, 1.0).duration(TrackKind::Video, fd), Time::new(12, 30));
        assert_eq!(TransitionDefaults::new(0, 1.0).duration(TrackKind::Video, fd), Time::new(30, 30));
        assert_eq!(TransitionDefaults::new(0, 0.5).duration(TrackKind::Audio, fd), Time::new(15, 30));
        assert_eq!(TransitionDefaults::new(0, 0.001).duration(TrackKind::Audio, fd), fd);
    }
}

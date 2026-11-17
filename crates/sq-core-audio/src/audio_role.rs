// Swift: AudioRole.swift
//! One audio role (audit C18). A clip's role is its own tag (`Clip::audio_tag`), else the role of the track it sits on
//! (`Track::audio_role`). Live Ducking, Bake Live Duck to Keys (Auto Duck) and Match Loudness read this; nothing is
//! stored. Voice Chain stays on the track role: it is the track bus's effect chain, which a single clip cannot pick.

use sq_core_model::{AudioTag, Clip, Timeline, Track};

/// `Track.role(of:)`.
pub trait TrackRoleExt {
    /// `clip.audio_tag ?? audio_role` (the clip is assumed to sit on this track).
    fn role_of(&self, clip: &Clip) -> Option<AudioTag>;
}

impl TrackRoleExt for Track {
    fn role_of(&self, clip: &Clip) -> Option<AudioTag> {
        clip.audio_tag.or(self.audio_role)
    }
}

/// `Timeline.role(of:)`.
pub trait TimelineRoleExt {
    /// The clip's tag, else the role of the track holding it (by id); a clip not in this sequence has only its tag.
    fn role_of(&self, clip: &Clip) -> Option<AudioTag>;
}

impl TimelineRoleExt for Timeline {
    fn role_of(&self, clip: &Clip) -> Option<AudioTag> {
        if let Some(tag) = clip.audio_tag {
            return Some(tag);
        }
        self.tracks.iter().find(|t| t.clips().iter().any(|c| c.id == clip.id)).and_then(|t| t.audio_role)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, TrackKind};
    use sq_core_time::{Id, Time, TimeRange};

    /// A fresh id for tests (Swift `UUID()`); unique per process.
    pub(crate) fn fresh_id() -> Id {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        Id::from_u128(u128::from(NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)) | 1 << 100)
    }

    /// A 1-second-timescale audio clip `start`..`start + len` with fresh ids.
    pub(crate) fn clip(start: i64, len: i64, tag: Option<AudioTag>) -> Clip {
        let (id, media) = (fresh_id(), fresh_id());
        let mut c = Clip::new(
            id,
            "c",
            media,
            TrackKind::Audio,
            TimeRange::new(Time::ZERO, Time::new(len, 1)),
            Time::new(start, 1),
        );
        c.audio_tag = tag;
        c
    }

    pub(crate) fn track(n: u128, role: Option<AudioTag>, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(n), TrackKind::Audio);
        t.set_clips(clips);
        t.audio_role = role;
        t
    }

    pub(crate) fn timeline(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(9999), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    /// Every combination of clip tag and track role resolves to tag ?? role.
    #[test]
    fn resolution_table() {
        let options = [None, Some(AudioTag::Dialogue), Some(AudioTag::Music), Some(AudioTag::Sfx)];
        for tag in options {
            for role in options {
                let c = clip(0, 5, tag);
                let tr = track(1, role, vec![c.clone()]);
                let t = timeline(vec![tr.clone()]);
                let expected = tag.or(role);
                assert_eq!(TrackRoleExt::role_of(&tr, &c), expected, "tag {tag:?} role {role:?}");
                assert_eq!(TimelineRoleExt::role_of(&t, &c), expected, "tag {tag:?} role {role:?}");
            }
        }
    }

    #[test]
    fn clip_not_in_the_timeline_falls_back_to_its_tag() {
        let t = timeline(vec![track(1, Some(AudioTag::Music), vec![clip(0, 5, None)])]);
        assert_eq!(t.role_of(&clip(1, 5, Some(AudioTag::Sfx))), Some(AudioTag::Sfx));
        assert_eq!(t.role_of(&clip(1, 5, None)), None);
    }
}

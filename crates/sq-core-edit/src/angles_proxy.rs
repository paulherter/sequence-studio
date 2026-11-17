//! What the timeline draws for a piece of an Angles clip, and the multi-angle view's frames.
// Swift: Angles+Proxy.swift

use sq_core_model::{Clip, Timeline, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

/// Swift `Clip.isAnglesClip` and `Clip.angleView(of:)` (Angles.swift; their file has no other home in the edit groups).
pub trait AnglesClipExt {
    /// True for a piece of an Angles clip.
    fn is_angles_clip(&self) -> bool;
    /// The Angles sequence as this piece plays it: of the tracks of the clip's kind only the active angle's stays
    /// (an index past the last angle plays the last). Not an Angles clip: `inner` unchanged.
    fn angle_view(&self, inner: &Timeline) -> Timeline;
}

impl AnglesClipExt for Clip {
    fn is_angles_clip(&self) -> bool {
        self.angle.is_some() && self.sequence.is_some()
    }

    fn angle_view(&self, inner: &Timeline) -> Timeline {
        let Some(angle) = &self.angle else { return inner.clone() };
        let count = inner.tracks.iter().filter(|t| t.kind == self.kind).count();
        if count <= 1 {
            return inner.clone();
        }
        let wanted = usize::try_from(angle.index.max(0)).unwrap_or(usize::MAX).min(count - 1);
        let mut out = inner.clone();
        let mut n = 0;
        out.tracks = inner
            .tracks
            .iter()
            .filter(|t| {
                if t.kind != self.kind {
                    return true;
                }
                n += 1;
                n - 1 == wanted
            })
            .cloned()
            .collect();
        out
    }
}

/// Swift `Clip.angleProxy(inner:)`, `Timeline.angleFrames(at:frameDuration:)` and `Clip.angleInnerTime(at:)`.
pub trait AnglesProxyExt {
    /// What the timeline draws for a piece of an Angles clip: the piece as if it were a plain media clip of the active
    /// angle (that angle's media, and the stretch of its file the piece plays), so thumbnails and waveforms show the angle
    /// that plays. `inner` is the Angles sequence. None = not an Angles piece, or the active angle has no single plain
    /// clip under the whole piece (the caller draws it flat).
    // shortcut: one clip of the active angle must cover the piece at normal speed; a piece over a cut or retimed angle
    // clip draws flat. Upgrade when angle tracks are edited after creation.
    fn angle_proxy(&self, inner: &Timeline) -> Option<Clip>;
    /// The time in the Angles sequence that the piece shows at timeline time `t` (pieces play at normal speed).
    fn angle_inner_time(&self, t: Time) -> Time;
}

impl AnglesProxyExt for Clip {
    fn angle_proxy(&self, inner: &Timeline) -> Option<Clip> {
        if !self.is_angles_clip()
            || !self.speed.is_normal()
            || self.reversed
            || self.speed_keys.is_some()
            || self.hold_frame.is_some()
        {
            return None;
        }
        let shown = self.angle_view(inner);
        let last = self.source.start.max(self.source.end() - Time::new(1, self.source.start.timescale()));
        for track in shown.tracks.iter().filter(|t| t.kind == self.kind) {
            let Some(ic) = track.clips().iter().find(|c| c.timeline().contains(self.source.start)) else { continue };
            if !ic.timeline().contains(last)
                || ic.sequence.is_some()
                || ic.generator.is_some()
                || ic.is_still
                || !ic.speed.is_normal()
                || ic.reversed
                || ic.speed_keys.is_some()
                || ic.hold_frame.is_some()
            {
                return None;
            }
            let mut p = self.clone();
            p.media = ic.media;
            p.sequence = None;
            p.angle = None;
            p.source = TimeRange::new(ic.source.start + (self.source.start - ic.start), self.source.duration);
            p.media_duration = ic.media_duration;
            return Some(p);
        }
        None
    }

    fn angle_inner_time(&self, t: Time) -> Time {
        self.source.start + (t - self.start)
    }
}

/// The picture of one angle at a time: its media and the time in that file.
pub type AngleFrame = (Id, Time);

/// Swift `Timeline.angleFrames`.
pub trait AngleFramesExt {
    /// For the multi-angle view: what each angle (video track, bottom first) shows at `t` of this Angles sequence, as its
    /// media and the time in that file. None = the angle has no picture there.
    fn angle_frames(&self, t: Time, frame_duration: Time) -> Vec<Option<AngleFrame>>;
}

impl AngleFramesExt for Timeline {
    fn angle_frames(&self, t: Time, frame_duration: Time) -> Vec<Option<AngleFrame>> {
        self.tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .map(|track| {
                let c = track.clips().iter().find(|c| {
                    c.is_enabled && c.timeline().contains(t) && c.sequence.is_none() && c.generator.is_none()
                })?;
                Some((c.media, c.source_time(t, frame_duration)))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{AngleChoice, SequenceFormat, Track};
    use sq_core_time::{IdSource, SequentialIds};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    /// An Angles sequence of three 10 s cameras (picture and sound each) and a 10 s piece of it.
    fn fixture(ids: &mut SequentialIds) -> (Timeline, Vec<Id>, Clip, Clip) {
        let media: Vec<Id> = (0..3).map(|_| ids.next_id()).collect();
        let mut tracks = Vec::new();
        for kind in [TrackKind::Video, TrackKind::Audio] {
            for m in &media {
                let mut t = Track::new(ids.next_id(), kind);
                let mut c = Clip::new(ids.next_id(), "cam", *m, kind, TimeRange::new(Time::ZERO, s(10)), Time::ZERO);
                c.media_duration = Some(s(10));
                t.overwrite(c, ids).unwrap();
                tracks.push(t);
            }
        }
        let inner = Timeline::new(ids.next_id(), "Angles", SequenceFormat::new(Time::new(1, 25)), tracks);
        let piece = |ids: &mut SequentialIds, kind| {
            let mut c =
                Clip::new(ids.next_id(), "Angles", inner.id, kind, TimeRange::new(Time::ZERO, s(10)), Time::ZERO);
            c.sequence = Some(inner.id);
            c.angle = Some(AngleChoice { index: 0, follows_video: false });
            c
        };
        let (v, a) = (piece(ids, TrackKind::Video), piece(ids, TrackKind::Audio));
        (inner, media, v, a)
    }

    #[test]
    fn piece_draws_as_media_of_the_active_angle() {
        let mut ids = SequentialIds::default();
        let (inner, media, mut piece, mut sound) = fixture(&mut ids);
        piece.angle = Some(AngleChoice { index: 1, follows_video: false });
        piece.source = TimeRange::new(s(2), s(5));
        let proxy = piece.angle_proxy(&inner).unwrap();
        assert_eq!(proxy.media, media[1]);
        assert!(proxy.sequence.is_none() && proxy.id == piece.id);
        assert!(proxy.source.start == s(2) && proxy.source.duration == s(5));
        sound.angle = Some(AngleChoice { index: 2, follows_video: false });
        assert_eq!(sound.angle_proxy(&inner).map(|c| c.media), Some(media[2]));
    }

    #[test]
    fn angle_frames_list_every_angle_at_a_time() {
        let mut ids = SequentialIds::default();
        let (inner, media, piece, _) = fixture(&mut ids);
        let frames = inner.angle_frames(s(3), Time::new(1, 25));
        assert_eq!(
            frames.iter().map(|f| f.map(|f| f.0)).collect::<Vec<_>>(),
            media.iter().map(|m| Some(*m)).collect::<Vec<_>>()
        );
        assert_eq!(frames[1].map(|f| f.1), Some(s(3)));
        assert!(inner.angle_frames(s(11), Time::new(1, 25)).iter().all(Option::is_none));
        assert_eq!(piece.angle_inner_time(s(4)), piece.source.start + s(4));
    }

    #[test]
    fn plain_clip_and_piece_outside_the_angle_clip_give_none() {
        let mut ids = SequentialIds::default();
        let (inner, _, mut plain, _) = fixture(&mut ids);
        let mut piece = plain.clone();
        plain.sequence = None;
        assert!(plain.angle_proxy(&inner).is_none());
        piece.source = TimeRange::new(s(8), s(5));
        assert!(piece.angle_proxy(&inner).is_none());
    }
}

//! The Color page's solo pictures: one clip as the raw file with only its grade on it.
// Swift: TimelineSolo.swift

use sq_core_color::ClipEffectColorExt;
use sq_core_model::{AnimatedProperty, Clip, ClipEffect, Timeline, Track, TrackKind, VideoTrackInfo};
use sq_core_time::{Id, IdSource, Time, TimeRange, Vec2};

/// Swift `Clip.colorSoloPicture`.
pub trait ColorSoloClipExt {
    /// The Color page's solo picture of this clip (DECISIONS: "Color solo = raw source + grade"): the same id, media,
    /// footage interpretation and Color effects (base and range grades), and nothing else. Transform, opacity, keys of
    /// Motion, blend mode, crop, masks, stabilization, every other effect, baked effects and variant overrides are left
    /// out, so the picture is the file as it is with only the grade on it. `scale` is the (static) Scale that fits the
    /// picture into the viewer. Timing (start, source, speed) is the caller's.
    fn color_solo_picture(&self, scale: f64) -> Clip;
}

impl ColorSoloClipExt for Clip {
    fn color_solo_picture(&self, scale: f64) -> Clip {
        let mut c = Clip::new(self.id, &self.name, self.media, TrackKind::Video, self.source, self.start);
        c.media_duration = self.media_duration;
        c.is_still = self.is_still;
        c.footage_color = self.footage_color.clone();
        c.grade_link = self.grade_link;
        c.grade_independent_store = if self.grade_independent_store == Some(true) { Some(true) } else { None };
        c.effects = self.effects.iter().filter(|e| e.is_color()).cloned().collect();
        c.animation.scale = AnimatedProperty::new(Vec2::new(scale, scale));
        c
    }
}

/// What the Program monitor plays on the Color page while a source clip is picked in the Clips strip: the clip's whole
/// media file at normal speed, on its own time axis (file time) and in its own frame size and rate, with only the clip's
/// grade on it (`color_solo_picture`). `position` is the file frame to open on.
#[derive(Clone, Debug, PartialEq)]
pub struct ColorSourceFileView {
    pub clip_id: Id,
    pub timeline: Timeline,
    pub position: Time,
}

/// Swift `Timeline.soloingVideoClip` and `Timeline.colorSourceFileView`.
pub trait TimelineSoloExt {
    /// The sequence as the Color page's Clips mode shows one source clip that has no file axis to scrub (a still):
    /// every video track that does not hold the clip is hidden, the clip's own track keeps no transitions and the clip
    /// itself is reduced to its raw picture plus its grade (`color_solo_picture`), fitted into the frame when its
    /// upright pixel size `picture` is known. Generators and nested clips stay as they are (their picture is what they
    /// render). Audio tracks are untouched. An unknown id returns the timeline unchanged.
    fn soloing_video_clip(&self, id: Id, picture: Option<(i64, i64)>) -> Timeline;

    /// The source-file view of video clip `id` (`ColorSourceFileView`), opened on the source frame shown at sequence time
    /// `playhead` (the clip's first frame when the playhead is outside it). One video track holds the clip's raw picture
    /// with its grade (same id, so compare / bypass by clip id applies) over the whole file from 0, at 100 % and identity
    /// geometry. Grade keys move from clip-local time to the start of the source frame the clip shows there
    /// (`solo_mapped`), so every file frame the clip uses gets the values the timeline shows on it; outside the
    /// used part the first / last values hold. A frame hold has no source axis: its grade is frozen at the playhead.
    /// `position` is the file frame containing the shown source time (floor, as the decoder picks it).
    /// `picture`: the file's probe info; the view then has the file's upright size and nominal frame rate (Scale 100 % =
    /// the file's own pixels = the whole frame), else the sequence's format. A linked audio clip of the same media adds
    /// the file's audio. None for generators, nested sequences, stills and clips without a known media length: nothing to
    /// scrub (the caller solos the clip in place with `soloing_video_clip`). `ids` names the view's tracks and sequence.
    fn color_source_file_view(
        &self,
        id: Id,
        playhead: Time,
        picture: Option<&VideoTrackInfo>,
        ids: &mut dyn IdSource,
    ) -> Option<ColorSourceFileView>;
}

impl TimelineSoloExt for Timeline {
    fn soloing_video_clip(&self, id: Id, picture: Option<(i64, i64)>) -> Timeline {
        let holds = |t: &Track| t.kind == TrackKind::Video && t.clips().iter().any(|c| c.id == id);
        if !self.tracks.iter().any(holds) {
            return self.clone();
        }
        let mut t = self.clone();
        for track in t.tracks.iter_mut().filter(|t| t.kind == TrackKind::Video) {
            if let Some(c) = track.clips().iter().find(|c| c.id == id).cloned() {
                track.transitions = Vec::new();
                if !c.is_generator() && !c.is_nested() {
                    let fit = picture.map_or(1.0, |(w, h)| self.format.fit_scale(w, h));
                    let mut raw = c.color_solo_picture(fit);
                    raw.speed = c.speed;
                    raw.reversed = c.reversed;
                    raw.speed_keys = c.speed_keys.clone();
                    raw.hold_frame = c.hold_frame;
                    raw.is_enabled = true;
                    track.replace(raw);
                }
            } else {
                track.is_visible = false;
            }
        }
        t
    }

    fn color_source_file_view(
        &self,
        id: Id,
        playhead: Time,
        picture: Option<&VideoTrackInfo>,
        ids: &mut dyn IdSource,
    ) -> Option<ColorSourceFileView> {
        let clip = self
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .find_map(|t| t.clips().iter().find(|c| c.id == id))?;
        let length = clip.media_duration?;
        if clip.is_generator() || clip.sequence.is_some() || clip.is_still || length <= Time::ZERO {
            return None;
        }
        let frame_duration = self.frame_duration();
        let inside = clip.timeline().contains(playhead);
        let at = if inside {
            clip.source_time(playhead, frame_duration)
        } else if clip.reversed {
            clip.source.end() - frame_duration
        } else {
            clip.source.start
        };
        let mut view_format = self.format.clone();
        if let Some(p) = picture.filter(|p| p.display_width() > 0 && p.display_height() > 0) {
            view_format.width = p.display_width();
            view_format.height = p.display_height();
            if p.nominal_frame_duration > Time::ZERO {
                view_format.frame_duration = p.nominal_frame_duration;
            }
        }
        let mut c = clip.color_solo_picture(1.0);
        c.start = Time::ZERO;
        c.source = TimeRange::new(Time::ZERO, length);
        c.is_enabled = true;
        if clip.hold_frame.is_some() {
            // No source axis: the grade frozen at the playhead; a range grade shows over the whole view exactly when it
            // graded the held frame there (as `Clip.freezeFrame`), else not at all.
            let local = if inside { playhead - clip.start } else { Time::ZERO };
            c.effects = c
                .effects
                .iter()
                .filter_map(|e| {
                    let mut f = e.frozen_at_local(local);
                    let Some(r) = e.color_range else { return Some(f) };
                    if !r.contains(local) {
                        return None;
                    }
                    f.color_range = Some(TimeRange::new(Time::ZERO, length));
                    f.color_fade_in = None;
                    f.color_fade_out = None;
                    Some(f)
                })
                .collect();
        } else {
            c.effects = c.effects.iter().map(|e| solo_mapped(e, clip, frame_duration)).collect();
        }
        let mut v = Track::new(ids.next_id(), TrackKind::Video);
        // shortcut: a failed overwrite of the first clip into an empty track cannot happen; Swift's `try?` ignores it too.
        let _ = v.overwrite(c, ids);
        let mut out = vec![v];
        if let Some(link) = clip.link {
            let partner = self
                .tracks
                .iter()
                .filter(|t| t.kind == TrackKind::Audio)
                .find_map(|t| t.clips().iter().find(|a| a.link == Some(link) && a.media == clip.media));
            if let Some(a) = partner {
                let mut t = Track::new(ids.next_id(), TrackKind::Audio);
                let mut audio =
                    Clip::new(a.id, &a.name, a.media, TrackKind::Audio, TimeRange::new(Time::ZERO, length), Time::ZERO);
                audio.media_duration = Some(length);
                let _ = t.overwrite(audio, ids);
                out.push(t);
            }
        }
        let fd = view_format.frame_duration;
        let last = Time::ZERO.max(length - fd);
        let timeline = Timeline::new(ids.next_id(), &clip.name, view_format, out);
        Some(ColorSourceFileView { clip_id: id, timeline, position: at.max(Time::ZERO).min(last) })
    }
}

/// This effect of `clip` on the solo view's file axis. Keys: clip-local time L -> start of the source frame the
/// timeline shows at L (`Clip.source_time` convention, so a reversed frame is the one ending at the mapped instant).
/// A map that runs backwards (reverse) mirrors each track: handles and spatial tangents swap sides, each segment
/// keeps its own interpolation (the left key's), and a hold segment, which must hold its timeline-left key's value
/// on the right, gets a hold key just after its file-left key. A map that is neither (time remapping that changes
/// direction) is only sorted. Range grades map through the instants (the frames they cover); a reversed range swaps
/// its fades.
fn solo_mapped(effect: &ClipEffect, clip: &Clip, fd: Time) -> ClipEffect {
    let key = |l: Time| -> Time {
        if let Some(k) = &clip.speed_keys {
            return k.source_time(l, fd);
        }
        if clip.reversed { clip.source_instant(l) - clip.speed.scale(fd) } else { clip.source_instant(l) }
    };
    let mut e = effect.clone();
    e.parameters = effect.parameters.iter().map(|(k, p)| (k.clone(), p.remapped(key))).collect();
    e.colors = effect.colors.iter().map(|(k, p)| (k.clone(), p.remapped(key))).collect();
    e.points = effect.points.iter().map(|(k, p)| (k.clone(), p.remapped(key))).collect();
    if let Some(r) = effect.color_range {
        let a = clip.source_instant(r.start);
        let b = clip.source_instant(r.end());
        e.color_range = Some(TimeRange::from_end(a.min(b), a.max(b)));
        let dist = |x: Time, y: Time| if x < y { y - x } else { x - y };
        let fin = effect.color_fade_in.map(|f| dist(clip.source_instant(r.start + f), a));
        let fout = effect.color_fade_out.map(|f| dist(clip.source_instant(r.end() - f), b));
        if b < a {
            e.color_fade_in = fout;
            e.color_fade_out = fin;
        } else {
            e.color_fade_in = fin;
            e.color_fade_out = fout;
        }
    }
    e
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::SequenceFormat;
    use sq_core_model::floored_to_frame;
    use sq_core_time::{Keyframe, SequentialIds};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    #[test]
    fn floored_to_frame_rounds_down_and_ignores_a_zero_duration() {
        let fd = Time::new(1, 25);
        assert_eq!(floored_to_frame(Time::new(5, 100), fd), Time::new(1, 25));
        assert_eq!(floored_to_frame(Time::new(7, 100), fd), Time::new(1, 25));
        assert_eq!(floored_to_frame(Time::new(-1, 100), fd), Time::new(-1, 25));
        assert_eq!(floored_to_frame(Time::new(7, 100), Time::ZERO), Time::new(7, 100));
    }

    fn graded_clip(ids: &mut SequentialIds, start: i64) -> Clip {
        let mut c = Clip::new(
            ids.next_id(),
            "graded",
            Id::from_u128(99),
            TrackKind::Video,
            TimeRange::new(s(10), s(4)),
            s(start),
        );
        c.media_duration = Some(s(30));
        let mut fx = ClipEffect::new(ids.next_id(), sq_core_model::COLOR_KIND);
        let mut prop = AnimatedProperty::new(0.0);
        prop.track.insert(Keyframe::new(ids.next_id(), Time::ZERO, 0.0));
        prop.track.insert(Keyframe::new(ids.next_id(), s(1), 2.0));
        fx.parameters.insert("exposure".to_string(), prop);
        c.effects = vec![fx];
        c.animation.opacity = AnimatedProperty::new(0.5);
        c
    }

    #[test]
    fn the_file_view_keys_sit_on_their_source_frames_and_opens_on_the_shown_frame() {
        let mut ids = SequentialIds::default();
        let mut c = graded_clip(&mut ids, 2);
        c.speed = sq_core_model::ClipSpeed::new(2, 1);
        let mut v1 = Track::new(ids.next_id(), TrackKind::Video);
        v1.overwrite(c.clone(), &mut ids).unwrap();
        let tl = Timeline::new(ids.next_id(), "seq", SequenceFormat::new(Time::new(1, 25)), vec![v1]);
        let Some(view) = tl.color_source_file_view(c.id, s(3), None, &mut ids) else { panic!("no view") };
        let solo = &view.timeline.tracks[0].clips()[0];
        assert_eq!(solo.id, c.id);
        assert_eq!(solo.source, TimeRange::new(Time::ZERO, s(30)));
        assert!(solo.speed.is_normal() && solo.animation.opacity.track.keys.is_empty());
        assert_eq!(solo.animation.opacity.value, 1.0);
        // Local 0 / 1 s at 200 % show source 10 / 12 s; the playhead 1 s in shows source 12 s.
        let keys: Vec<Time> = solo.effects[0].parameters["exposure"].track.keys.iter().map(|k| k.time).collect();
        assert_eq!(keys, [s(10), s(12)]);
        assert_eq!(view.position, s(12));
        // Outside the clip the view opens on the clip's first frame.
        let outside = tl.color_source_file_view(c.id, s(0), None, &mut ids).map(|v| v.position);
        assert_eq!(outside, Some(s(10)));
    }

    #[test]
    fn soloing_hides_other_video_tracks_and_unknown_ids_change_nothing() {
        let mut ids = SequentialIds::default();
        let c = graded_clip(&mut ids, 0);
        let mut v1 = Track::new(ids.next_id(), TrackKind::Video);
        v1.overwrite(c.clone(), &mut ids).unwrap();
        let v2 = Track::new(ids.next_id(), TrackKind::Video);
        let tl = Timeline::new(ids.next_id(), "seq", SequenceFormat::new(Time::new(1, 25)), vec![v1, v2]);
        let solo = tl.soloing_video_clip(c.id, Some((3840, 2160)));
        assert!(solo.tracks[0].is_visible && !solo.tracks[1].is_visible);
        assert_eq!(solo.tracks[0].clips()[0].animation.scale.value, Vec2::new(0.5, 0.5));
        assert_eq!(tl.soloing_video_clip(Id::from_u128(1000), None), tl);
    }
}

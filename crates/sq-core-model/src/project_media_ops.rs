// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Project+MediaOps.swift

mod frame_scale;
mod generator_clips;

pub use generator_clips::GeneratorPlacement;

use crate::labels::path_extension;
use crate::{MediaRef, Project, SequenceFormat, SourcePlacement, ThreePointMode, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};

/// Folder that holds the path of media made offline on purpose (`make_offline`). Nothing is ever created there.
pub const OFFLINE_FOLDER_NAME: &str = ".sq-offline";

/// The last component of a POSIX or Windows path.
fn file_name_of(path: &str) -> &str {
    path.rsplit(['/', '\\']).find(|c| !c.is_empty()).unwrap_or(path)
}

/// `NSString.deletingPathExtension`: the name without its last extension (none for ".png" or "name.").
fn deleting_path_extension(name: &str) -> &str {
    let ext = path_extension(name);
    if ext.is_empty() { name } else { &name[..name.len() - ext.len() - 1] }
}

impl Project {
    /// After media was pointed at other files (relink, probe): a chosen channel map is fitted to the probed sound of
    /// the new file and cleared when it does not fit; media without a chosen map takes the new file's sound info.
    /// Media without info are left alone. True when anything changed. Swift: `Project.fitAudioChannelMaps(to:)`.
    pub fn fit_audio_channel_maps(&mut self, probed: &std::collections::BTreeMap<Id, crate::MediaInfo>) -> bool {
        let mut changed = false;
        for m in self.media.iter_mut() {
            let Some(info) = probed.get(&m.id) else { continue };
            let path = m.path.clone();
            let Some(mi) = m.info.as_mut() else { continue };
            let before = mi.audio.clone();
            match before.as_ref().and_then(|a| a.channel_map.clone()) {
                None => mi.audio = info.audio.clone(),
                Some(map) => match info.audio.clone() {
                    Some(mut a) => {
                        a.channel_map = map.stored(&a, &path);
                        mi.audio = Some(a);
                    }
                    None => {
                        if let Some(a) = mi.audio.as_mut() {
                            a.channel_map = None;
                        }
                    }
                },
            }
            changed |= mi.audio != before;
        }
        changed
    }

    /// New Sequence From Clip: an empty-format-locked sequence in the clip's own size and frame rate holding the whole clip
    /// (linked video and audio) at 0, named after the clip. Added to the project and the root bin by the caller
    /// (`normalize_bins`). `None` for media without a known duration.
    pub fn sequence_from_media(&self, id: Id, name: Option<&str>, ids: &mut dyn IdSource) -> Option<Timeline> {
        let r = self.media(id)?;
        let still = r.info.as_ref().is_some_and(|i| i.is_still);
        let total = if still { Some(Time::new(5, 1)) } else { r.info.as_ref().map(|i| i.duration).or(r.duration) }?;
        let v = r.info.as_ref().and_then(|i| i.video.as_ref());
        let audio = r.info.as_ref().and_then(|i| i.audio.as_ref());
        let fd = if still { Time::new(1, 30) } else { v.map_or(Time::new(1001, 30000), |v| v.nominal_frame_duration) };
        let format = SequenceFormat {
            width: v.map_or(1920, |v| v.display_width()),
            height: v.map_or(1080, |v| v.display_height()),
            frame_duration: fd,
            audio_sample_rate: audio.map_or(48_000, |a| a.sample_rate),
            ..SequenceFormat::new(fd)
        }
        .sanitized(&SequenceFormat::PROBE_FALLBACK);
        let mut t = Timeline::new(
            ids.next_id(),
            name.unwrap_or_else(|| deleting_path_extension(&r.name)),
            format,
            Timeline::default_tracks(
                crate::SequenceDefaults::VIDEO_TRACK_COUNT,
                crate::SequenceDefaults::AUDIO_TRACK_COUNT,
                ids,
            ),
        );
        // A fresh sequence's first video and audio tracks are targeted, so the targeted-track rule of Swift's
        // `sourceEditTargets` applies (the drop rule for sequences without a targeted track is never reached here).
        let wants_video = v.is_some() || r.info.is_none();
        let first_targeted =
            |t: &Timeline, kind| t.tracks.iter().find(|x| x.kind == kind && x.is_targeted).map(|x| x.id);
        let mut targets: Vec<Id> = Vec::new();
        if wants_video {
            targets.extend(first_targeted(&t, TrackKind::Video));
        }
        if audio.is_some() {
            targets.extend(first_targeted(&t, TrackKind::Audio));
        }
        if targets.is_empty() {
            targets.extend(t.tracks.first().map(|x| x.id));
        }
        let mut src = SourcePlacement::new(TimeRange::new(Time::ZERO, total), id, &r.name);
        src.media_duration = (!still).then_some(total);
        src.is_still = still;
        // A failed placement leaves the sequence empty, as the Swift `try?` does.
        let _ = t.three_point_edit(&src, &targets, Time::ZERO, ThreePointMode::Overwrite, ids);
        Some(t)
    }

    /// Replace Footage / Link Media: the item keeps its identity (clips, bin position, label, marks) and points at the new
    /// file. Name and label stay; path, bookmark, fingerprint, duration and probe info come from `replacement`.
    pub fn replace_media(&mut self, id: Id, replacement: &MediaRef) -> bool {
        let Some(i) = self.media.iter().position(|m| m.id == id) else { return false };
        let m = &mut self.media[i];
        m.path = replacement.path.clone();
        m.bookmark = replacement.bookmark.clone();
        m.fingerprint = replacement.fingerprint.clone();
        m.duration = replacement.duration;
        // A pixel aspect chosen for the item is how the item is read: it survives the new file. A replacement that is not
        // probed yet keeps the item's old info while a choice exists (the choice lives in it).
        let chosen = m.info.as_ref().and_then(|i| i.video.as_ref()).and_then(|v| v.pixel_aspect_override);
        let channels = m.info.as_ref().and_then(|i| i.audio.as_ref()).and_then(|a| a.channel_map.clone()); // likewise, when the new file has the channels
        let deinterlace_off = m.info.as_ref().and_then(|i| i.video.as_ref()).is_some_and(|v| v.deinterlace_off);
        if replacement.info.is_some() || (chosen.is_none() && channels.is_none() && !deinterlace_off) {
            m.info = replacement.info.clone();
        }
        if let (Some(a), Some(channels)) = (m.info.as_mut().and_then(|i| i.audio.as_mut()), channels) {
            let snapshot = a.clone();
            a.channel_map = channels.stored(&snapshot, &replacement.path); // None: it does not fit
        }
        if let Some(v) = m.info.as_mut().and_then(|i| i.video.as_mut()) {
            if deinterlace_off {
                v.deinterlace_off = true;
            }
            if let Some(chosen) = chosen
                && chosen != v.pixel_aspect
            {
                v.pixel_aspect_override = Some(chosen);
            }
        }
        self.fit_usage(id);
        self.apply_pending_scale_migration(); // a v9 clip that waited for probe info gets its v10 Scale now
        true
    }

    /// After a replace: clips of `id` learn the new media length; a clip that reaches past it is trimmed at the tail, one
    /// that starts past it is removed (linked partners follow, they use the same media); source marks are clamped to the new
    /// length and re-snapped to the new frame rate (a mark that no longer fits is dropped).
    fn fit_usage(&mut self, id: Id) {
        let Some(r) = self.media(id) else { return };
        let still = r.info.as_ref().is_some_and(|i| i.is_still);
        let total: Option<Time> = if still { None } else { r.info.as_ref().map(|i| i.duration).or(r.duration) };
        let nominal = r.info.as_ref().and_then(|i| i.video.as_ref()).map(|v| v.nominal_frame_duration);
        for t in &mut self.timelines {
            let fd = t.frame_duration();
            for track in &mut t.tracks {
                for c in track.clips().to_vec().iter().filter(|c| c.media == id && !c.is_nested() && !c.is_generator())
                {
                    let mut n = c.clone();
                    n.media_duration = total;
                    if let Some(total) = total.filter(|_| !c.is_still) {
                        if c.source.start >= total {
                            track.remove(c.id);
                            continue;
                        }
                        if c.source.end() > total {
                            if let Some(keys) = &c.speed_keys {
                                // Remapped: cut the tail until the whole speed track lies inside the shortened media.
                                let Some(fit) = keys.fitting(Some(total), fd) else {
                                    track.remove(c.id);
                                    continue;
                                };
                                n.set_speed_keys(Some(fit));
                            } else if c.speed.is_normal() && !c.reversed {
                                n.source = TimeRange::from_end(c.source.start, total);
                            } else {
                                // Retimed: keep the length a whole number of timeline frames at the clip's speed. The end
                                // that plays last is cut (tail); a reversed clip plays its source end first, so its head is
                                // cut and the clip starts later (the remaining picture stays where it was).
                                let excess = c.source.end() - total;
                                if c.reversed {
                                    let cut = c.speed.unscale(excess).frame_index(fd);
                                    let frames = cut + i64::from(c.speed.unscale(excess) > fd * cut);
                                    let removed = fd * frames;
                                    if removed >= c.duration() {
                                        track.remove(c.id);
                                        continue;
                                    }
                                    n.extend_head(-removed);
                                    n.start = c.start + removed;
                                } else {
                                    let keep = c.speed.unscale(total - c.source.start).frame_index(fd);
                                    if keep < 1 {
                                        track.remove(c.id);
                                        continue;
                                    }
                                    n.extend_tail(fd * keep - c.duration());
                                }
                            }
                        }
                    }
                    track.replace(n);
                }
            }
        }
        let Some(mut m) = self.source_marks.get(&id).cloned() else { return };
        if let Some(total) = total {
            let fd = nominal.unwrap_or(Time::new(1, 30));
            let last = (total - fd).max(Time::ZERO);
            if let Some(i) = m.mark_in {
                m.mark_in = if i >= total { None } else { Some(i.snapped(fd).min(last)) };
            }
            if let Some(o) = m.mark_out {
                m.mark_out = Some(if o.snapped(fd) > total { total } else { o.snapped(fd).max(fd) });
            }
            if let (Some(i), Some(o)) = (m.mark_in, m.mark_out)
                && o <= i
            {
                m.mark_out = None;
            }
        }
        if m.is_empty() {
            self.source_marks.remove(&id);
        } else {
            self.source_marks.insert(id, m);
        }
    }

    /// Names of the sequences that hold clips of `media`, in project order (empty = unused).
    pub fn sequence_names_using(&self, media: Id) -> Vec<String> {
        let uses = |t: &&crate::Timeline| {
            t.tracks.iter().any(|tr| tr.clips().iter().any(|c| c.media == media && !c.is_nested() && !c.is_generator()))
        };
        self.timelines.iter().filter(uses).map(|t| t.name.clone()).collect()
    }

    /// Names of the other sequences that nest sequence `id` as a clip.
    pub fn sequence_names_nesting(&self, id: Id) -> Vec<String> {
        let nests = |t: &&crate::Timeline| {
            t.id != id && t.tracks.iter().any(|tr| tr.clips().iter().any(|c| c.sequence == Some(id)))
        };
        self.timelines.iter().filter(nests).map(|t| t.name.clone()).collect()
    }

    /// Deletes a sequence. Refused (false) for the last sequence, for an unknown id and for a sequence another sequence
    /// nests (`sequence_names_nesting` names those). `active_timeline` moves to the neighbor when the active one goes.
    /// The caller wraps this in one undo step.
    pub fn delete_sequence(&mut self, id: Id) -> bool {
        let Some(i) = self.timelines.iter().position(|t| t.id == id) else { return false };
        if self.timelines.len() <= 1 || !self.sequence_names_nesting(id).is_empty() {
            return false;
        }
        self.timelines.remove(i);
        let active_exists = self.timelines.iter().any(|t| Some(t.id) == self.active_timeline);
        if self.active_timeline == Some(id) || !active_exists {
            self.active_timeline = self.timelines.get(i.min(self.timelines.len() - 1)).map(|t| t.id);
        }
        self.normalize_bins();
        true
    }

    /// Clear used media: the item stays in the project and its clips stay on the timelines, but its file is no longer
    /// referenced, so it is offline until Relink attaches a file again. The name, fingerprint (size) and probe info are
    /// kept, so Relink matches by file name and size as for any missing file. Returns false for an unknown id or an item
    /// that is already offline-by-clear.
    /// shortcut: offline is derived from "nothing at the stored path" (no persisted flag, no ProjectFile bump); the path
    /// is moved to a folder that does not exist. Upgrade to a real flag when a version bump is free.
    pub fn make_offline(&mut self, id: Id) -> bool {
        let Some(item) = self.media.iter_mut().find(|m| m.id == id) else { return false };
        let path = item.path.clone();
        let name = file_name_of(&path);
        if name.is_empty() || path.contains(&format!("/{OFFLINE_FOLDER_NAME}/")) {
            return false;
        }
        let dir = path.strip_suffix(name).unwrap_or("/");
        item.path = format!("{dir}{OFFLINE_FOLDER_NAME}/{name}");
        item.bookmark = None;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nesting::test_util::*;
    use crate::{Clip, MediaFingerprint, MediaRef, MediaStatus};

    #[test]
    fn fit_channel_maps_follows_the_new_file() {
        use crate::{AudioChannelMap, AudioTrackInfo, MediaInfo};
        use std::collections::BTreeMap;
        let audio = |channels, map: Option<AudioChannelMap>| AudioTrackInfo {
            sample_rate: 48000,
            channels,
            codec: "aac".into(),
            channel_map: map,
            first_track_channels: None,
        };
        let info = |a: Option<AudioTrackInfo>| -> MediaInfo {
            serde_json::from_value(serde_json::json!({"duration": {"value": 1, "timescale": 1}}))
                .map(|mut i: MediaInfo| {
                    i.audio = a;
                    i
                })
                .unwrap()
        };
        let mut p = project_json(vec![], vec![timeline_json(1, vec![])]);
        let mut m = MediaRef::new(id(7), "a", "/a.mov", MediaFingerprint::new(1));
        m.info = Some(info(Some(audio(4, AudioChannelMap::new(&[2], &[3])))));
        p.media.push(m);
        let mut probed = BTreeMap::new();
        probed.insert(id(7), info(None));
        assert!(p.fit_audio_channel_maps(&probed));
        assert_eq!(p.media[0].info.as_ref().and_then(|i| i.audio.as_ref()).and_then(|a| a.channel_map.clone()), None);
        probed.insert(id(7), info(Some(audio(2, None))));
        assert!(p.fit_audio_channel_maps(&probed));
        assert_eq!(p.media[0].info.as_ref().and_then(|i| i.audio.as_ref()).map(|a| a.channels), Some(2));
        assert!(!p.fit_audio_channel_maps(&probed));
    }

    #[test]
    fn delete_refuses_the_last_sequence() {
        let mut p = project_json(vec![], vec![timeline_json(1, vec![])]);
        assert!(!p.delete_sequence(id(1)));
        assert_eq!(p.timelines.len(), 1);
    }

    #[test]
    fn delete_fixes_the_active_timeline_and_bins() {
        let mut p = project_json(vec![], (1..=3).map(|n| timeline_json(n, vec![])).collect());
        p.active_timeline = Some(id(2));
        assert!(p.delete_sequence(id(2)));
        assert_eq!(p.timelines.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["T1", "T3"]);
        assert_eq!(p.active_timeline, Some(id(3)));
        assert_eq!(p.root_bin.parent_of(crate::BinItemRef::Sequence(id(2))), None);
        assert!(p.delete_sequence(id(3)));
        assert_eq!(p.active_timeline, Some(id(1)));
    }

    #[test]
    fn delete_keeps_the_active_one_when_another_goes() {
        let mut p = project_json(vec![], (1..=2).map(|n| timeline_json(n, vec![])).collect());
        p.active_timeline = Some(id(1));
        assert!(p.delete_sequence(id(2)));
        assert_eq!(p.active_timeline, Some(id(1)));
        assert!(!p.delete_sequence(id(99)), "unknown id");
    }

    #[test]
    fn delete_refuses_a_nested_sequence() {
        let outer = timeline_json(1, vec![track_json(50, "video", vec![clip_json(900, 2, "video", 0, Some(2))])]);
        let mut p = project_json(vec![], vec![outer, timeline_json(2, vec![])]);
        assert_eq!(p.sequence_names_nesting(id(2)), ["T1"]);
        assert!(!p.delete_sequence(id(2)));
        assert!(p.delete_sequence(id(1)));
    }

    #[test]
    fn names_the_sequences_using_a_clip() {
        let used =
            |n| timeline_json(n, vec![track_json(50 + n, "video", vec![clip_json(900 + n, 7, "video", 0, None)])]);
        let nested = timeline_json(3, vec![track_json(53, "video", vec![clip_json(903, 7, "video", 0, Some(1))])]);
        let p = project_json(vec![], vec![used(1), timeline_json(2, vec![]), nested]);
        assert_eq!(p.sequence_names_using(id(7)), ["T1"], "a nested clip does not use the media");
        assert!(p.sequence_names_using(id(8)).is_empty());
    }

    #[test]
    fn make_offline_keeps_name_size_and_moves_the_path() {
        let mut p = Project::new(id(9), "p", vec![], vec![]);
        let mut m = MediaRef::new(id(1), "clip.mov", "/v/clip.mov", MediaFingerprint::new(1));
        m.bookmark = Some(vec![1]);
        p.add(m);
        assert!(p.make_offline(id(1)));
        let o = &p.media[0];
        assert_eq!((o.bookmark.as_ref(), o.name.as_str(), o.fingerprint.size), (None, "clip.mov", 1));
        assert_eq!(o.path, "/v/.sq-offline/clip.mov");
        assert_eq!(o.status(), MediaStatus::Missing);
        assert!(!p.make_offline(id(1)), "already offline");
        assert!(!p.make_offline(id(2)), "unknown id");
    }

    #[test]
    fn file_name_handles_both_separators() {
        assert_eq!(
            (file_name_of("/a/b.mov"), file_name_of("C:\\a\\b.mov"), file_name_of("b.mov")),
            ("b.mov", "b.mov", "b.mov")
        );
        assert_eq!(file_name_of("/a/b/"), "b");
    }

    use crate::SourceMarks;
    use crate::nesting::test_util::TestIds;
    use serde_json::json;

    /// An 8 s 1080x1920 clip with stereo sound.
    fn clip_media(path: &str, seconds: i64) -> MediaRef {
        let mut m = MediaRef::new(id(40), "clip.mov", path, MediaFingerprint::new(1));
        m.duration = Some(Time::new(seconds, 1));
        m.info = serde_json::from_value(json!({"duration": {"value": seconds, "timescale": 1},
            "video": {"width": 1080, "height": 1920, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                      "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false},
            "audio": {"sampleRate": 48000, "channels": 2, "codec": "aac"}}))
        .ok();
        m
    }

    fn project_with(m: MediaRef) -> Project {
        let mut p = project_json(vec![], vec![]);
        p.media.push(m);
        p
    }

    #[test]
    fn a_sequence_from_a_clip_uses_its_format_and_holds_it_linked() {
        let p = project_with(clip_media("/x/clip.mov", 8));
        let t = p.sequence_from_media(id(40), None, &mut TestIds(700)).unwrap_or_else(|| panic!("no sequence"));
        assert_eq!(t.name, "clip");
        assert_eq!((t.format.width, t.format.height, t.format.frame_duration), (1080, 1920, Time::new(1, 30)));
        assert_eq!(t.duration(), Time::new(8, 1));
        let clips: Vec<_> = t.tracks.iter().flat_map(|x| x.clips()).collect();
        assert!(clips.len() == 2 && clips.iter().all(|c| c.media == id(40) && c.start == Time::ZERO));
        assert!(clips[0].link.is_some() && clips[0].link == clips[1].link);
        assert!(t.format_locked);
        assert_eq!(
            p.sequence_from_media(id(40), Some("Mine"), &mut TestIds(700)).map(|t| t.name),
            Some("Mine".to_string())
        );
        assert!(p.sequence_from_media(id(404), None, &mut TestIds(700)).is_none());
    }

    #[test]
    fn a_probe_with_zero_values_still_gives_a_valid_format_and_a_still_five_seconds() {
        let mut m = clip_media("/x/bad.mov", 8);
        m.info = serde_json::from_value(json!({"duration": {"value": 8, "timescale": 1},
            "video": {"width": 0, "height": 0, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                      "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false},
            "audio": {"sampleRate": 0, "channels": 2, "codec": "aac"}}))
        .ok();
        let p = project_with(m);
        let t = p.sequence_from_media(id(40), None, &mut TestIds(700)).unwrap_or_else(|| panic!("no sequence"));
        assert!(t.format.is_valid());
        assert_eq!((t.format.audio_sample_rate, t.format.width, t.format.height), (48_000, 1920, 1080));
        let mut still = clip_media("/x/pic.png", 1);
        still.info = serde_json::from_value(json!({"duration": {"value": 1, "timescale": 1}, "isStill": true,
            "video": {"width": 100, "height": 100, "codec": "png", "bitDepth": 8, "chroma": "4:4:4",
                      "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false}}))
        .ok();
        let p = project_with(still);
        let t = p.sequence_from_media(id(40), None, &mut TestIds(700)).unwrap_or_else(|| panic!("no sequence"));
        assert_eq!(t.duration(), Time::new(5, 1));
        assert!(t.tracks.iter().flat_map(|x| x.clips()).all(|c| c.is_still && c.media_duration.is_none()));
        let mut unknown = clip_media("/x/u.mov", 8);
        unknown.duration = None;
        unknown.info = None;
        assert!(project_with(unknown).sequence_from_media(id(40), None, &mut TestIds(700)).is_none());
    }

    #[test]
    fn replacing_keeps_the_identity_and_takes_path_and_duration() {
        let mut p = project_with(clip_media("/x/clip.mov", 8));
        let other = clip_media("/y/new.mov", 9);
        assert!(p.replace_media(id(40), &other));
        let r = p.media(id(40)).cloned().unwrap_or_else(|| other.clone());
        assert_eq!((r.name.as_str(), r.path.as_str(), r.duration), ("clip.mov", "/y/new.mov", Some(Time::new(9, 1))));
        assert!(!p.replace_media(id(404), &other));
    }

    #[test]
    fn a_shorter_replacement_trims_clips_and_clamps_the_source_marks() {
        let mut p = project_with(clip_media("/x/clip.mov", 8));
        let t = p.sequence_from_media(id(40), None, &mut TestIds(700)).unwrap_or_else(|| panic!("no sequence"));
        p.timelines.push(t);
        p.source_marks.insert(
            id(40),
            SourceMarks { mark_in: Some(Time::new(6, 1)), mark_out: Some(Time::new(8, 1)), ..SourceMarks::default() },
        );
        assert!(p.replace_media(id(40), &clip_media("/x/clip.mov", 5)));
        let five = Time::new(5, 1);
        assert!(
            p.timelines[0]
                .tracks
                .iter()
                .flat_map(|x| x.clips())
                .all(|c| c.media_duration == Some(five) && c.source.end() == five)
        );
        let m = p.source_marks.get(&id(40)).cloned().unwrap_or_default();
        assert_eq!((m.mark_in, m.mark_out), (None, Some(five)), "In past the end dropped, Out clamped");
    }

    #[test]
    fn a_replacement_drops_clips_starting_past_the_new_end_and_trims_retimed_ones_by_frames() {
        let mut p = project_with(clip_media("/x/clip.mov", 8));
        let mut past = Clip::new(
            id(1),
            "c",
            id(40),
            TrackKind::Video,
            TimeRange::from_end(Time::new(6, 1), Time::new(8, 1)),
            Time::ZERO,
        );
        past.media_duration = Some(Time::new(8, 1));
        let mut fast = Clip::new(
            id(2),
            "f",
            id(40),
            TrackKind::Video,
            TimeRange::from_end(Time::new(1, 1), Time::new(8, 1)),
            Time::new(20, 1),
        );
        fast.speed = crate::ClipSpeed::from_percent(200.0);
        let mut track = crate::Track::new(id(60), TrackKind::Video);
        track.set_clips(vec![past, fast]);
        p.timelines.push(Timeline::new(id(61), "t", crate::SequenceFormat::new(Time::new(1, 30)), vec![track]));
        assert!(p.replace_media(id(40), &clip_media("/x/clip.mov", 5)));
        let clips = p.timelines[0].tracks[0].clips();
        assert_eq!(clips.len(), 1, "the clip that started past the new end is removed");
        // Source 1..5 at double speed: 2 s on the timeline.
        assert_eq!((clips[0].id, clips[0].duration()), (id(2), Time::new(2, 1)));
    }

    #[test]
    fn a_replacement_keeps_the_chosen_pixel_aspect_and_the_deinterlace_switch() {
        let mut p = project_with(clip_media("/x/clip.mov", 8));
        if let Some(v) = p.media[0].info.as_mut().and_then(|i| i.video.as_mut()) {
            v.pixel_aspect_override = Some(crate::PixelAspect::new(2, 1).unwrap_or(crate::PixelAspect::square()));
            v.deinterlace_off = true;
        }
        let mut probed = clip_media("/y/new.mov", 8);
        if let Some(v) = probed.info.as_mut().and_then(|i| i.video.as_mut()) {
            v.width = 720;
        }
        assert!(p.replace_media(id(40), &probed));
        let v = p.media[0].info.as_ref().and_then(|i| i.video.clone()).unwrap_or_else(|| panic!("no video"));
        assert_eq!(v.width, 720);
        assert!(v.deinterlace_off && v.pixel_aspect_override.is_some());
        // An unprobed replacement keeps the old info while a choice exists.
        let mut unprobed = clip_media("/z/newer.mov", 8);
        unprobed.info = None;
        assert!(p.replace_media(id(40), &unprobed));
        assert_eq!(p.media[0].info.as_ref().and_then(|i| i.video.as_ref()).map(|v| v.width), Some(720));
    }
}

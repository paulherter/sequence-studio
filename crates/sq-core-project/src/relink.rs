// Swift: Relink.swift
//! Relinking offline media: candidates found in a folder, and the project edits that follow a relink.

use std::collections::{BTreeMap, BTreeSet};

use crate::media_path_resolver::MediaPathResolver;
use sq_core_edit::project_merge_media::ProjectMergeMediaExt;
use sq_core_model::{MediaFingerprint, MediaInfo, MediaRef, MediaStatus, Project};
use sq_core_time::{Id, Time, Timestamp};

/// A file found while searching a folder for offline media.
#[derive(Clone, Debug, PartialEq)]
pub struct RelinkCandidate {
    pub path: String,
    pub size: i64,
    /// Content modification date when the scan knows it: breaks ties between several same-size files.
    pub modified: Option<Timestamp>,
    /// Probed length when known (only `RelinkScorer` uses it; the name scan leaves it `None`).
    pub duration: Option<Time>,
}

impl RelinkCandidate {
    /// A candidate with no date and no probed length.
    pub fn new(path: &str, size: i64) -> RelinkCandidate {
        RelinkCandidate { path: path.to_string(), size, modified: None, duration: None }
    }
}

/// Result of [`RelinkPlanner::match_`] (Swift `RelinkPlanner.Result`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RelinkPlannerResult {
    pub plan: BTreeMap<Id, String>,
    /// Media for which files of that name exist, but none with the recorded size.
    pub size_mismatch: Vec<Id>,
}

/// Matches offline media to files found in a folder: same file name (case-insensitive) AND the recorded size (a recorded
/// size of 0 means unknown: an unambiguous name match is taken, see `MediaPathResolver::pick`). A candidate whose size
/// differs (or is unknown, -1) is never attached: it is a different file.
pub struct RelinkPlanner;

impl RelinkPlanner {
    /// Media id -> found path.
    pub fn plan(missing: &[MediaRef], candidates: &[RelinkCandidate]) -> BTreeMap<Id, String> {
        Self::match_(missing, candidates).plan
    }

    /// Swift `match(missing:candidates:)`.
    pub fn match_(missing: &[MediaRef], candidates: &[RelinkCandidate]) -> RelinkPlannerResult {
        let mut by_name: BTreeMap<String, Vec<RelinkCandidate>> = BTreeMap::new();
        for c in candidates {
            by_name.entry(MediaPathResolver::file_name_of(&c.path).to_lowercase()).or_default().push(c.clone());
        }
        let mut out = RelinkPlannerResult::default();
        for m in missing {
            // Windows paths from Premiere too.
            let name = MediaPathResolver::file_name_of(&m.path).to_lowercase();
            let Some(list) = by_name.get(&name).filter(|l| !l.is_empty()) else { continue };
            if m.fingerprint.size == 0 {
                // Size unknown (Premiere import): the name decides, ties by the stored folders.
                match MediaPathResolver::pick(list, &m.path, None) {
                    Some(p) => {
                        out.plan.insert(m.id, p);
                    }
                    None => out.size_mismatch.push(m.id),
                }
            } else {
                let same: Vec<&RelinkCandidate> =
                    list.iter().filter(|c| c.size >= 0 && c.size == m.fingerprint.size).collect();
                match Self::best(&same, m) {
                    Some(hit) => {
                        out.plan.insert(m.id, hit.path.clone());
                    }
                    None => out.size_mismatch.push(m.id),
                }
            }
        }
        out
    }

    /// The best of several same-name, same-size files, always the same one whatever order the scan met them in: same
    /// modification date as recorded, then the most matching trailing folder names, then the most shared leading folders
    /// (the closest path to where the file was), then the path itself.
    fn best<'a>(list: &[&'a RelinkCandidate], m: &MediaRef) -> Option<&'a RelinkCandidate> {
        if list.len() <= 1 {
            return list.first().copied();
        }
        let lower =
            |p: &str| -> Vec<String> { MediaPathResolver::folders_of(p).iter().map(|f| f.to_lowercase()).collect() };
        let want = lower(&m.path);
        let key = |c: &RelinkCandidate| -> (i64, usize, usize) {
            let date = match (c.modified, m.fingerprint.modified) {
                (Some(a), Some(b)) if (a.unix_seconds() - b.unix_seconds()).abs() < 1.0 => 1,
                _ => 0,
            };
            let have = lower(&c.path);
            let tail = have.iter().rev().zip(want.iter().rev()).take_while(|(a, b)| a == b).count();
            let head = have.iter().zip(want.iter()).take_while(|(a, b)| a == b).count();
            (date, tail, head)
        };
        list.iter().copied().min_by(|a, b| key(b).cmp(&key(a)).then_with(|| a.path.cmp(&b.path)))
    }
}

/// `extension Project` of Relink.swift.
pub trait ProjectRelinkExt {
    /// Media whose file is not at its path.
    fn missing_media(&self) -> Vec<MediaRef>;
    /// Media among `paths` that a pending v10 Scale step waits on (H6) and that has no probe info: the caller probes the
    /// new files (off the main thread) and passes the results to `relink`.
    fn media_awaiting_probe_for_pending_scale(&self, paths: &BTreeMap<Id, String>) -> Vec<Id>;
    /// Media among `paths` without probe info (Premiere-import placeholders for files missing at import, very old
    /// projects): the caller probes the new files off the main thread and folds the results in with `adopt_probed_info`.
    fn media_awaiting_probe(&self, paths: &BTreeMap<Id, String>) -> Vec<Id>;
    /// Makes unprobed media usable like a fresh import: info, length and (when given) the fingerprint of the new file;
    /// its clips learn their media length, and a still's clips become still clips (source from 0: a Premiere still's
    /// in point is a huge number). The owed v10 Scale step follows. Media that already has info is left alone.
    /// Returns whether anything changed.
    fn adopt_probed_info(
        &mut self,
        found: &BTreeMap<Id, MediaInfo>,
        fingerprints: &BTreeMap<Id, MediaFingerprint>,
    ) -> bool;
    /// Points media at new files (unknown IDs ignored). The stale bookmark is dropped; clips are untouched except for
    /// the owed v10 Scale step (H6): `probed` fills in missing probe info of the new files, then every pending clip
    /// whose picture size is now known is converted. A chosen audio channel map is fitted to the probed file.
    fn relink(&mut self, paths: &BTreeMap<Id, String>, probed: &BTreeMap<Id, MediaInfo>);
}

impl ProjectRelinkExt for Project {
    fn missing_media(&self) -> Vec<MediaRef> {
        self.media.iter().filter(|m| m.status() == MediaStatus::Missing).cloned().collect()
    }

    fn media_awaiting_probe_for_pending_scale(&self, paths: &BTreeMap<Id, String>) -> Vec<Id> {
        let waiting: BTreeSet<Id> = self
            .timelines
            .iter()
            .flat_map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter().filter(|c| c.pending_source_pixel_scale())))
            .map(|c| c.media)
            .collect();
        self.media
            .iter()
            .filter(|m| paths.contains_key(&m.id) && m.info.is_none() && waiting.contains(&m.id))
            .map(|m| m.id)
            .collect()
    }

    fn media_awaiting_probe(&self, paths: &BTreeMap<Id, String>) -> Vec<Id> {
        self.media.iter().filter(|m| paths.contains_key(&m.id) && m.info.is_none()).map(|m| m.id).collect()
    }

    fn adopt_probed_info(
        &mut self,
        found: &BTreeMap<Id, MediaInfo>,
        fingerprints: &BTreeMap<Id, MediaFingerprint>,
    ) -> bool {
        let mut adopted: BTreeMap<Id, MediaInfo> = BTreeMap::new();
        for m in self.media.iter_mut().filter(|m| m.info.is_none()) {
            let Some(info) = found.get(&m.id) else { continue };
            m.info = Some(info.clone());
            if m.duration.is_none() {
                m.duration = Some(info.duration);
            }
            if let Some(fp) = fingerprints.get(&m.id) {
                m.fingerprint = fp.clone();
            }
            adopted.insert(m.id, info.clone());
        }
        if adopted.is_empty() {
            return false;
        }
        for timeline in self.timelines.iter_mut() {
            for track in timeline.tracks.iter_mut() {
                for c in track.clips().to_vec() {
                    if c.is_generator() || c.sequence.is_some() {
                        continue;
                    }
                    let Some(info) = adopted.get(&c.media) else { continue };
                    let mut n = c.clone();
                    if n.media_duration.is_none() {
                        n.media_duration = Some(info.duration);
                    }
                    if info.is_still && !n.is_still {
                        // Clip markers are source time: they move with the source offset the still loses.
                        let offset = n.source.start;
                        n.markers = n.markers.map(|ms| {
                            ms.into_iter()
                                .map(|mut m| {
                                    m.time -= offset;
                                    m
                                })
                                .collect()
                        });
                        n.is_still = true;
                        n.source.start = Time::ZERO;
                    }
                    if n != c {
                        track.replace(n);
                    }
                }
            }
        }
        self.apply_pending_scale_migration();
        true
    }

    fn relink(&mut self, paths: &BTreeMap<Id, String>, probed: &BTreeMap<Id, MediaInfo>) {
        for m in self.media.iter_mut() {
            let Some(p) = paths.get(&m.id) else { continue };
            m.path = p.clone();
            m.bookmark = None;
            if m.info.is_none()
                && let Some(info) = probed.get(&m.id)
            {
                m.info = Some(info.clone());
            }
        }
        self.merge_shared_paths(&paths.keys().copied().collect()); // a path another item holds: one file is one asset
        let moved: BTreeMap<Id, MediaInfo> =
            probed.iter().filter(|(id, _)| paths.contains_key(id)).map(|(id, i)| (*id, i.clone())).collect();
        self.fit_audio_channel_maps(&moved); // F7.10: a map the new file cannot play is cleared
        self.apply_pending_scale_migration();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::TimeRange;

    fn ref_(n: u128, name: &str, size: i64, path: &str) -> MediaRef {
        MediaRef::new(Id::from_u128(n), name, &format!("{path}/{name}"), MediaFingerprint::new(size))
    }

    #[test]
    fn matches_by_file_name_and_size() {
        let (a, b) = (ref_(1, "A.mov", 100, "/gone"), ref_(2, "B.mov", 200, "/gone"));
        let found = [RelinkCandidate::new("/new/sub/a.MOV", 100), RelinkCandidate::new("/new/B.mov", 999)];
        let plan = RelinkPlanner::plan(&[a.clone(), b.clone()], &found);
        assert_eq!(plan.get(&a.id).map(String::as_str), Some("/new/sub/a.MOV"));
        assert_eq!(plan.get(&b.id), None);
        let r = RelinkPlanner::match_(std::slice::from_ref(&b), &[RelinkCandidate::new("/new/B.mov", -1)]);
        assert!(r.plan.is_empty() && r.size_mismatch == vec![b.id]);
    }

    #[test]
    fn prefers_the_same_size_among_several_with_the_same_name() {
        let a = ref_(1, "A.mov", 100, "/gone");
        let plan = RelinkPlanner::plan(
            std::slice::from_ref(&a),
            &[RelinkCandidate::new("/x/A.mov", 5), RelinkCandidate::new("/y/A.mov", 100)],
        );
        assert_eq!(plan.get(&a.id).map(String::as_str), Some("/y/A.mov"));
    }

    #[test]
    fn unknown_recorded_size_matches_by_name_when_unambiguous() {
        let a = ref_(1, "A.mov", 0, "/gone");
        let one = RelinkPlanner::match_(std::slice::from_ref(&a), &[RelinkCandidate::new("/x/a.mov", 123)]);
        assert!(one.plan.get(&a.id).map(String::as_str) == Some("/x/a.mov") && one.size_mismatch.is_empty());
        let two = RelinkPlanner::match_(
            std::slice::from_ref(&a),
            &[RelinkCandidate::new("/x/A.mov", 1), RelinkCandidate::new("/y/A.mov", 2)],
        );
        assert!(two.plan.is_empty() && two.size_mismatch == vec![a.id]);
    }

    #[test]
    fn several_same_size_candidates_pick_the_same_file_whatever_the_scan_order() {
        let a = ref_(1, "A.mov", 100, "/Volumes/Old/Day1");
        let x = RelinkCandidate::new("/zzz/Other/A.mov", 100);
        let y = RelinkCandidate::new("/Volumes/New/Day1/A.mov", 100);
        let z = RelinkCandidate::new("/Volumes/Old/Day2/A.mov", 100);
        let pick =
            |m: &MediaRef, c: &[RelinkCandidate]| RelinkPlanner::plan(std::slice::from_ref(m), c).get(&m.id).cloned();
        assert_eq!(pick(&a, &[x.clone(), y.clone(), z.clone()]).as_deref(), Some("/Volumes/New/Day1/A.mov"));
        assert_eq!(pick(&a, &[z, y, x]).as_deref(), Some("/Volumes/New/Day1/A.mov"));
        let b = ref_(2, "B.mov", 50, "/Volumes/Old/Day1");
        let near = RelinkCandidate::new("/Volumes/Old/Day2/B.mov", 50);
        let far = RelinkCandidate::new("/a/B.mov", 50);
        assert_eq!(pick(&b, &[far, near.clone()]), Some(near.path));
        let tie_a = RelinkCandidate::new("/q/1/B.mov", 50);
        let tie_b = RelinkCandidate::new("/q/2/B.mov", 50);
        assert_eq!(pick(&b, &[tie_b, tie_a.clone()]), Some(tie_a.path));
    }

    #[test]
    fn modification_date_breaks_ties_before_folders() {
        let when = Timestamp::from_unix_seconds(1_700_000_000.0);
        let mut m = ref_(1, "A.mov", 100, "/Volumes/Old/Day1");
        m.fingerprint.modified = Some(when);
        let mut other_date = RelinkCandidate::new("/Volumes/New/Day1/A.mov", 100);
        other_date.modified = Some(Timestamp::from_unix_seconds(1_700_000_500.0));
        let mut same_date = RelinkCandidate::new("/elsewhere/A.mov", 100);
        same_date.modified = Some(when);
        let plan = RelinkPlanner::plan(std::slice::from_ref(&m), &[other_date, same_date]);
        assert_eq!(plan.get(&m.id).map(String::as_str), Some("/elsewhere/A.mov"));
    }

    #[test]
    fn unmatched_stay_offline() {
        let a = ref_(1, "A.mov", 100, "/gone");
        assert!(RelinkPlanner::plan(&[a], &[RelinkCandidate::new("/x/Z.mov", 100)]).is_empty());
    }

    #[test]
    fn planner_matches_windows_stored_paths() {
        let m = MediaRef::new(Id::from_u128(1), "C2116", "D:\\Footage\\C2116.MP4", MediaFingerprint::new(0));
        let plan = RelinkPlanner::plan(std::slice::from_ref(&m), &[RelinkCandidate::new("/new/C2116.mp4", 3)]);
        assert_eq!(plan.get(&m.id).map(String::as_str), Some("/new/C2116.mp4"));
    }

    #[test]
    fn planner_breaks_name_ties_by_folder() {
        let m = MediaRef::new(Id::from_u128(1), "C0001.MP4", "/Volumes/X/Card2/C0001.MP4", MediaFingerprint::new(0));
        let r = RelinkPlanner::match_(
            std::slice::from_ref(&m),
            &[RelinkCandidate::new("/n/Card1/C0001.MP4", 1), RelinkCandidate::new("/n/Card2/C0001.MP4", 2)],
        );
        assert_eq!(r.plan.get(&m.id).map(String::as_str), Some("/n/Card2/C0001.MP4"));
    }

    fn info(duration: Time, is_still: bool) -> MediaInfo {
        let j = serde_json::json!({"duration": duration, "isStill": is_still});
        serde_json::from_value(j).expect("media info")
    }

    fn project(media: MediaRef, clip: Clip) -> Project {
        let mut track = Track::new(Id::from_u128(50), TrackKind::Video);
        track.set_clips(vec![clip]);
        let fd = Time::new(1, 30);
        let tl = Timeline::new(Id::from_u128(60), "T", SequenceFormat::new(fd), vec![track]);
        Project::new(Id::from_u128(70), "t", vec![media], vec![tl])
    }

    fn clip_of(media: &MediaRef, start: Time, duration: Time) -> Clip {
        Clip::new(
            Id::from_u128(11),
            &media.name,
            media.id,
            TrackKind::Video,
            TimeRange::new(start, duration),
            Time::ZERO,
        )
    }

    fn first_clip(p: &Project) -> Clip {
        p.timelines[0].tracks[0].clips()[0].clone()
    }

    #[test]
    fn project_relink_updates_path_and_drops_stale_bookmark() {
        let mut m = ref_(1, "A.mov", 100, "/gone");
        m.bookmark = Some(vec![1]);
        let mut p = Project::new(Id::from_u128(70), "P", vec![m.clone()], vec![]);
        let paths = BTreeMap::from([(m.id, "/new/A.mov".to_string()), (Id::from_u128(99), "/ignored.mov".to_string())]);
        p.relink(&paths, &BTreeMap::new());
        assert_eq!(p.media[0].path, "/new/A.mov");
        assert_eq!(p.media[0].bookmark, None);
        assert_eq!(p.media[0].name, "A.mov");
    }

    #[test]
    fn missing_media_lists_only_missing_files() {
        let dir = std::env::temp_dir().join(format!("sq-relink-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let file = dir.join("here.mov");
        std::fs::write(&file, [0u8; 10]).expect("write");
        let here = MediaRef::new(Id::from_u128(1), "here.mov", &file.to_string_lossy(), MediaFingerprint::new(10));
        let gone = ref_(2, "gone.mov", 100, "/gone");
        let p = Project::new(Id::from_u128(70), "P", vec![here, gone.clone()], vec![]);
        let missing: Vec<Id> = p.missing_media().iter().map(|m| m.id).collect();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(missing, vec![gone.id]);
    }

    #[test]
    fn every_relinked_unprobed_media_awaits_a_probe() {
        let placeholder = MediaRef::new(Id::from_u128(1), "a.png", "/gone/a.png", MediaFingerprint::new(0));
        let mut probed = MediaRef::new(Id::from_u128(2), "b.mov", "/gone/b.mov", MediaFingerprint::new(9));
        probed.info = Some(info(Time::new(2, 1), false));
        let p = Project::new(Id::from_u128(70), "t", vec![placeholder.clone(), probed.clone()], vec![]);
        let paths = BTreeMap::from([(placeholder.id, "/new/a.png".to_string()), (probed.id, "/new/b.mov".to_string())]);
        assert_eq!(p.media_awaiting_probe(&paths), vec![placeholder.id]);
        assert!(p.media_awaiting_probe(&BTreeMap::new()).is_empty());
    }

    #[test]
    fn probed_still_fixes_the_imported_clip() {
        let m = MediaRef::new(Id::from_u128(1), "a.png", "/new/a.png", MediaFingerprint::new(0));
        // As mapped from Premiere without probe info: a huge in point (Premiere's still convention), not a still.
        let mut p = project(m.clone(), clip_of(&m, Time::new(3600, 1), Time::new(5, 1)));
        let i = info(Time::new(5, 1), true);
        let changed = p.adopt_probed_info(
            &BTreeMap::from([(m.id, i.clone())]),
            &BTreeMap::from([(m.id, MediaFingerprint::new(1234))]),
        );
        assert!(changed);
        let got = &p.media[0];
        assert!(got.info.as_ref() == Some(&i) && got.duration == Some(Time::new(5, 1)) && got.fingerprint.size == 1234);
        let c = first_clip(&p);
        assert!(c.is_still && c.source.start == Time::ZERO && c.source.duration == Time::new(5, 1));
        assert_eq!(c.media_duration, Some(Time::new(5, 1)));
    }

    #[test]
    fn probed_video_keeps_the_source_range_and_learns_its_length() {
        let m = MediaRef::new(Id::from_u128(1), "a.mov", "/new/a.mov", MediaFingerprint::new(0));
        let mut p = project(m.clone(), clip_of(&m, Time::new(3, 1), Time::new(2, 1)));
        let changed = p.adopt_probed_info(&BTreeMap::from([(m.id, info(Time::new(10, 1), false))]), &BTreeMap::new());
        assert!(changed);
        let c = first_clip(&p);
        assert!(!c.is_still && c.source.start == Time::new(3, 1) && c.media_duration == Some(Time::new(10, 1)));
        assert_eq!(p.media[0].fingerprint.size, 0, "no fingerprint passed: unchanged");
    }

    #[test]
    fn media_with_info_is_left_alone() {
        let i = info(Time::new(4, 1), false);
        let mut m = MediaRef::new(Id::from_u128(1), "a.mov", "/a.mov", MediaFingerprint::new(5));
        m.duration = Some(Time::new(4, 1));
        m.info = Some(i);
        let mut p = project(m.clone(), clip_of(&m, Time::ZERO, Time::new(1, 1)));
        let before = p.clone();
        let changed = p.adopt_probed_info(&BTreeMap::from([(m.id, info(Time::new(9, 1), true))]), &BTreeMap::new());
        assert!(!changed);
        assert_eq!(p, before);
    }
}

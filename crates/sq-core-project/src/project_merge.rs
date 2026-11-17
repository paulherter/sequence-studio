// Swift: ProjectMerge.swift (`remap_ids` rewrites the UUID text of the encoded project file, like Swift's regex pass;
// the fresh ids come from the caller's `IdSource`)
//! Importing another Sequence Studio project into the current one (File > Import Project, drop a .sqproj on the Project
//! panel): everything of the other project lands in one new bin, the current sequence is untouched.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use sq_core_file::ProjectFileError;
use sq_core_model::{Bin, BinItem, BinItemRef, MediaRef, Project};
use sq_core_time::{Id, IdSource};

use crate::file_walk::LocalPath;

/// Importing another project.
pub struct ProjectMerge;

impl ProjectMerge {
    /// Ids that are part of the app, not of a project (built-in easing curves, keystone presets, anchored-animation keys).
    /// They are written into project files and must keep their value when a project's ids are replaced.
    pub fn is_fixed_id(s: &str) -> bool {
        let u = s.to_uppercase();
        u.starts_with("00000000-0000-0000-0000-") || u.starts_with("6B657973-746F-6E65-")
    }

    /// Reads the project package at `path` through the normal path (migrations included).
    pub fn load(path: &Path) -> Result<Project, ProjectFileError> {
        crate::project_file::project_file().read(path)
    }

    /// `project` with every identifier replaced by a fresh one (media, sequences, clips, bins, links, groups, effects,
    /// keyframes, marks), consistently, so references between the parts still hold. `keeping` maps an old id to the id it
    /// must become instead (media that already exists in the destination).
    pub fn remap_ids(project: &Project, keeping: &BTreeMap<Id, Id>, ids: &mut dyn IdSource) -> Option<Project> {
        let file = crate::project_file::project_file();
        let data = file.encode(project).ok()?;
        let text = String::from_utf8(data).ok()?;
        let mut table: BTreeMap<String, String> = keeping.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        let bytes = text.as_bytes();
        let mut out = String::with_capacity(text.len());
        let (mut last, mut i) = (0, 0);
        while i + UUID_LEN <= bytes.len() {
            if !matches_uuid(&bytes[i..i + UUID_LEN]) {
                i += 1;
                continue;
            }
            out.push_str(&text[last..i]);
            let id = &text[i..i + UUID_LEN];
            if Self::is_fixed_id(id) {
                out.push_str(id);
            } else {
                let key = id.to_uppercase();
                let n = table.entry(key).or_insert_with(|| ids.next_id().to_string());
                out.push_str(n);
            }
            i += UUID_LEN;
            last = i;
        }
        out.push_str(&text[last..]);
        file.decode(out.as_bytes(), None).ok()
    }

    /// Plain-language text for a failed project import: (title, detail). `None` is an error that is not a
    /// `ProjectFileError`; the Rust-only `Encode` and `Io` variants read like Swift's Foundation errors.
    pub fn message(error: Option<&ProjectFileError>, file_name: &str) -> (String, String) {
        let title = format!("Could not import \u{201C}{file_name}\u{201D}");
        let detail = match error {
            Some(ProjectFileError::Missing) => format!(
                "There is no project inside \u{201C}{file_name}\u{201D}. Choose a .{} project made by Sequence Studio.",
                sq_core_file::FILE_EXTENSION
            ),
            Some(ProjectFileError::Corrupt) => format!("\u{201C}{file_name}\u{201D} is damaged and cannot be read."),
            Some(ProjectFileError::NewerVersion { .. }) => format!(
                "\u{201C}{file_name}\u{201D} was saved by a newer version of Sequence Studio. Update the app to import it."
            ),
            _ => format!(
                "\u{201C}{file_name}\u{201D} could not be read. Check that the file is there and that you have permission to read it."
            ),
        };
        (title, detail)
    }
}

const UUID_LEN: usize = 36;

/// `[0-9A-Fa-f]{8}-{4}-{4}-{4}-{12}` on exactly 36 bytes.
fn matches_uuid(b: &[u8]) -> bool {
    b.iter().enumerate().all(|(n, c)| if matches!(n, 8 | 13 | 18 | 23) { *c == b'-' } else { c.is_ascii_hexdigit() })
}

/// `extension Project` of ProjectMerge.swift.
pub trait ProjectMergeExt {
    /// Adds everything of `other` (media, sequences with their clips, nested sequences, bins, marks) under one new bin
    /// named `bin_name` (default: the other project's name) inside `dest` (default: the root bin) and returns that bin.
    /// All ids are replaced so nothing collides, also when the same project is imported twice. Media whose path is
    /// already in this project reuses the existing item. Relative media paths are resolved against `source_folder`
    /// (the other project's folder). The active sequence, the format and every other setting stay as they are.
    fn merge(
        &mut self,
        other: &Project,
        bin_name: Option<&str>,
        dest: Option<Id>,
        source_folder: Option<&Path>,
        ids: &mut dyn IdSource,
    ) -> Option<Id>;
}

impl ProjectMergeExt for Project {
    fn merge(
        &mut self,
        other: &Project,
        bin_name: Option<&str>,
        dest: Option<Id>,
        source_folder: Option<&Path>,
        ids: &mut dyn IdSource,
    ) -> Option<Id> {
        let target = dest.unwrap_or(self.root_bin.id);
        self.root_bin.bin(target)?;
        let mut src = other.clone();
        if let Some(folder) = source_folder {
            for m in src.media.iter_mut() {
                if !LocalPath::is_absolute(&m.path) && !m.path.contains('\\') {
                    m.path = standardized(&format!("{}/{}", folder.to_string_lossy(), m.path));
                }
            }
        }
        let mut existing: BTreeMap<Id, Id> = BTreeMap::new(); // old id of a media item -> the id already here
        let mut by_path: BTreeMap<&str, Id> = BTreeMap::new();
        for m in &self.media {
            by_path.entry(m.path.as_str()).or_insert(m.id);
        }
        for m in &src.media {
            if let Some(id) = by_path.get(m.path.as_str()) {
                existing.insert(m.id, *id);
            }
        }

        // A project that cannot be re-encoded is not merged: reusing its ids would collide with ours.
        let mut fresh = ProjectMerge::remap_ids(&src, &existing, ids)?;
        let reused: BTreeSet<Id> = existing.values().copied().collect();
        let have: BTreeSet<Id> = self.media.iter().map(|m| m.id).collect();
        let new_media: Vec<MediaRef> = fresh.media.iter().filter(|m| !have.contains(&m.id)).cloned().collect();
        prune(&mut fresh.root_bin, &|r| if let BinItemRef::Media(id) = r { !reused.contains(&id) } else { true });
        for m in &new_media {
            if let Some(marks) = fresh.source_marks.get(&m.id) {
                self.source_marks.insert(m.id, marks.clone());
            }
        }
        self.media.extend(new_media);
        self.timelines.append(&mut fresh.timelines);
        let mut bin = Bin::new(ids.next_id(), bin_name.unwrap_or(&other.name), fresh.root_bin.children);
        if bin.name.chars().all(|c| c != '\n' && c != '\r' && c.is_whitespace()) {
            bin.name = "Imported Project".to_string();
        }
        let bin_id = bin.id;
        if let Some(t) = find_bin_mut(&mut self.root_bin, target) {
            t.children.push(BinItem::Bin(bin));
        }
        self.normalize_bins();
        Some(bin_id)
    }
}

/// Drops media and sequence references that fail `keep`, everywhere in the subtree (the model keeps its own copy private).
fn prune(bin: &mut Bin, keep: &impl Fn(BinItemRef) -> bool) {
    bin.children.retain_mut(|item| match item {
        BinItem::Bin(b) => {
            prune(b, keep);
            true
        }
        other => keep(other.item_ref()),
    });
}

pub(crate) fn find_bin_mut(bin: &mut Bin, id: Id) -> Option<&mut Bin> {
    if bin.id == id {
        return Some(bin);
    }
    bin.children.iter_mut().find_map(|c| if let BinItem::Bin(b) = c { find_bin_mut(b, id) } else { None })
}

/// `standardizedFileURL.path` without symlink resolution: `.` and `..` parts and repeated slashes fold away.
// shortcut: no symlink resolution (/tmp stays /tmp); upgrade when a path from a symlinked folder must compare equal.
pub(crate) fn standardized(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for p in path.split('/') {
        match p {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            _ => parts.push(p),
        }
    }
    format!("/{}", parts.join("/"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, MediaFingerprint, SequenceFormat, SourceMarks, Timeline, Track, TrackKind};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    /// Ids of the test fixtures start high so they never meet the ids a merge mints from 1.
    fn fixed(n: u128) -> Id {
        Id::from_u128(0xAAAA_0000_0000_0000_0000_0000_0000_0000 + n)
    }

    fn media(n: u128, path: &str, name: &str) -> MediaRef {
        let mut m = MediaRef::new(fixed(n), name, path, MediaFingerprint::new(10));
        m.duration = Some(s(100));
        m
    }

    fn clip(n: u128, start: i64, dur: i64, kind: TrackKind, link: Option<Id>, media: Id, sequence: Option<Id>) -> Clip {
        let mut c = Clip::new(fixed(n), "c", media, kind, TimeRange::new(s(0), s(dur)), s(start));
        c.link = link;
        c.media_duration = Some(s(100));
        c.sequence = sequence;
        c
    }

    /// Other project: media a (video) + b (audio), an inner sequence using both (linked), an outer sequence nesting the
    /// inner one, a sub-bin holding the inner sequence and media a.
    fn other(path_a: &str) -> Project {
        let (a, b) = (media(1, path_a, "a"), media(2, "/v/b.wav", "b"));
        let link = Some(fixed(20));
        let mut ids = SequentialIds::default();
        let (mut iv, mut ia) = (Track::new(fixed(30), TrackKind::Video), Track::new(fixed(31), TrackKind::Audio));
        assert!(iv.overwrite(clip(40, 0, 10, TrackKind::Video, link, a.id, None), &mut ids).is_ok());
        assert!(ia.overwrite(clip(41, 0, 10, TrackKind::Audio, link, b.id, None), &mut ids).is_ok());
        let fd = SequenceFormat::new(Time::new(1, 30));
        let inner = Timeline::new(fixed(50), "Inner", fd.clone(), vec![iv, ia]);
        let mut ov = Track::new(fixed(32), TrackKind::Video);
        assert!(ov.overwrite(clip(42, 0, 10, TrackKind::Video, None, inner.id, Some(inner.id)), &mut ids).is_ok());
        let outer = Timeline::new(fixed(51), "Outer", fd, vec![ov]);
        let mut p = Project::new(fixed(60), "Other", vec![a.clone(), b], vec![outer, inner.clone()]);
        let bin = p.new_bin("Sub", None, &mut ids).unwrap_or(Id::NIL);
        assert!(p.move_items(&[BinItemRef::Sequence(inner.id), BinItemRef::Media(a.id)], bin, None));
        p.source_marks
            .insert(a.id, SourceMarks { mark_in: Some(s(1)), mark_out: Some(s(5)), ..SourceMarks::default() });
        p
    }

    fn current() -> Project {
        let m = media(70, "/v/own.mov", "own");
        let t = Timeline::new(
            fixed(71),
            "Main",
            SequenceFormat::new(Time::new(1, 30)),
            vec![Track::new(fixed(72), TrackKind::Video)],
        );
        let mut p = Project::new(fixed(73), "Current", vec![m], vec![t]);
        p.normalize_bins();
        p
    }

    fn all_ids(p: &Project) -> Vec<Id> {
        let clips = p.timelines.iter().flat_map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.id)));
        p.media.iter().map(|m| m.id).chain(p.timelines.iter().map(|t| t.id)).chain(clips).collect()
    }

    fn timeline<'a>(p: &'a Project, name: &str) -> Option<&'a Timeline> {
        p.timelines.iter().find(|t| t.name == name)
    }

    #[test]
    fn imports_everything_under_one_named_bin() {
        let (mut p, mut ids) = (current(), SequentialIds::default());
        let active = p.active_timeline;
        let bin = p.merge(&other("/v/a.mov"), None, None, None, &mut ids);
        let bin = bin.expect("merged");
        assert_eq!(p.active_timeline, active);
        assert!(p.timelines.len() == 3 && p.media.len() == 3);
        let b = p.bin(bin).expect("bin");
        assert_eq!(b.name, "Other");
        assert_eq!(p.root_bin.parent_of(BinItemRef::Bin(bin)), Some(p.root_bin.id));
        let refs = b.all_refs();
        assert_eq!(refs.iter().filter(|r| matches!(r, BinItemRef::Sequence(_))).count(), 2);
        assert_eq!(refs.iter().filter(|r| matches!(r, BinItemRef::Media(_))).count(), 2);
        let sub =
            b.children.iter().find_map(|c| if let BinItem::Bin(x) = c { Some(x) } else { None }).expect("sub bin");
        assert!(sub.name == "Sub" && sub.children.len() == 2);
        assert!(!b.contains(BinItemRef::Sequence(p.timelines[0].id)));
    }

    #[test]
    fn ids_never_collide_even_when_merged_twice() {
        let (mut p, mut ids) = (current(), SequentialIds::default());
        let o = other("/v/a.mov");
        p.merge(&o, None, None, None, &mut ids);
        p.merge(&o, None, None, None, &mut ids);
        let all = all_ids(&p);
        let set: BTreeSet<Id> = all.iter().copied().collect();
        assert_eq!(set.len(), all.len());
        assert_eq!(p.timelines.len(), 5);
        let refs = p.root_bin.all_refs();
        assert_eq!(refs.iter().collect::<Vec<_>>().len(), refs.iter().copied().collect::<BTreeSet<_>>().len());
        assert!(set.is_disjoint(&all_ids(&o).into_iter().collect()));
    }

    #[test]
    fn nested_sequence_references_are_remapped() {
        let (mut p, mut ids) = (current(), SequentialIds::default());
        p.merge(&other("/v/a.mov"), None, None, None, &mut ids);
        let (outer, inner) = (timeline(&p, "Outer").expect("outer"), timeline(&p, "Inner").expect("inner"));
        let nested = &outer.tracks[0].clips()[0];
        assert!(nested.sequence == Some(inner.id) && nested.media == inner.id);
        assert!(p.is_nesting_acyclic());
        assert!(p.would_create_cycle(outer.id, inner.id));
        assert!(!p.would_create_cycle(inner.id, p.timelines[0].id));
    }

    #[test]
    fn links_stay_paired_and_media_refs_resolve() {
        let (mut p, mut ids) = (current(), SequentialIds::default());
        let o = other("/v/a.mov");
        p.merge(&o, None, None, None, &mut ids);
        let inner = timeline(&p, "Inner").expect("inner");
        let clips: Vec<&Clip> = inner.tracks.iter().flat_map(|t| t.clips().iter()).collect();
        assert!(clips.len() == 2 && clips[0].link.is_some() && clips[0].link == clips[1].link);
        assert!(clips.iter().all(|c| p.media.iter().any(|m| m.id == c.media)));
        let old = timeline(&o, "Inner").and_then(|t| t.tracks[0].clips()[0].link);
        assert_ne!(clips[0].link, old);
    }

    #[test]
    fn existing_media_with_same_path_is_reused() {
        let (mut p, mut ids) = (current(), SequentialIds::default());
        let own = p.media[0].clone();
        let bin = p.merge(&other(&own.path), None, None, None, &mut ids).expect("merged");
        assert_eq!(p.media.len(), 2);
        let inner = timeline(&p, "Inner").expect("inner");
        assert_eq!(inner.tracks[0].clips()[0].media, own.id);
        assert!(!p.bin(bin).is_some_and(|b| b.contains(BinItemRef::Media(own.id))));
        assert_eq!(p.root_bin.all_refs().iter().filter(|r| **r == BinItemRef::Media(own.id)).count(), 1);
    }

    #[test]
    fn source_marks_travel_with_media() {
        let (mut p, mut ids) = (current(), SequentialIds::default());
        let o = other("/v/a.mov");
        p.merge(&o, None, None, None, &mut ids);
        let a = p.media.iter().find(|m| m.name == "a").expect("a");
        assert_eq!(p.source_marks.get(&a.id), o.source_marks.values().next());
    }

    #[test]
    fn relative_paths_resolve_against_the_source_folder() {
        let (mut p, mut ids) = (current(), SequentialIds::default());
        let mut o = other("Footage/a.mov");
        o.media[1].path = "/abs/b.wav".to_string();
        p.merge(&o, None, None, Some(Path::new("/Users/x/Proj")), &mut ids);
        let path = |name: &str| p.media.iter().find(|m| m.name == name).map(|m| m.path.clone());
        assert_eq!(path("a").as_deref(), Some("/Users/x/Proj/Footage/a.mov"));
        assert_eq!(path("b").as_deref(), Some("/abs/b.wav"));
    }

    #[test]
    fn into_given_bin_and_custom_name() {
        let (mut p, mut ids) = (current(), SequentialIds::default());
        let folder = p.new_bin("Archive", None, &mut ids).expect("archive");
        let bin = p.merge(&other("/v/a.mov"), Some("Old cut"), Some(folder), None, &mut ids).expect("merged");
        assert_eq!(p.root_bin.parent_of(BinItemRef::Bin(bin)), Some(folder));
        assert_eq!(p.bin(bin).map(|b| b.name.clone()).as_deref(), Some("Old cut"));
        assert_eq!(p.merge(&other("/v/a.mov"), None, Some(fixed(999)), None, &mut ids), None);
    }

    #[test]
    fn built_in_fixed_ids_keep_their_value() {
        assert!(ProjectMerge::is_fixed_id("00000000-0000-0000-0000-000000000008"));
        assert!(ProjectMerge::is_fixed_id("6b657973-746f-6e65-0000-000000000001"));
        assert!(!ProjectMerge::is_fixed_id(&fixed(1).to_string()));
    }

    #[test]
    fn loads_from_package_and_merges_from_disk() {
        let dir = std::env::temp_dir().join(format!("merge-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("Other.sqproj");
        assert!(crate::project_file::project_file().write(&other("/v/a.mov"), &path).is_ok());
        let loaded = ProjectMerge::load(&path);
        let _ = std::fs::remove_dir_all(&dir);
        let loaded = loaded.expect("loaded");
        assert!(loaded.name == "Other" && loaded.timelines.len() == 2);
        let (mut p, mut ids) = (current(), SequentialIds::default());
        assert!(p.merge(&loaded, None, None, None, &mut ids).is_some());
    }

    #[test]
    fn errors_are_human_readable() {
        let cases = [
            (ProjectFileError::Missing, "no project"),
            (ProjectFileError::Corrupt, "damaged"),
            (ProjectFileError::NewerVersion { found: 9, supported: 1 }, "newer"),
        ];
        for (e, word) in cases {
            let (title, detail) = ProjectMerge::message(Some(&e), "X.sqproj");
            assert!(detail.contains(word));
            assert!(!title.contains("project.json") && !detail.contains("project.json"));
        }
        assert!(ProjectMerge::message(None, "X.sqproj").1.contains("permission"));
    }

    #[test]
    fn bin_tree_stays_consistent() {
        let (mut p, mut ids) = (current(), SequentialIds::default());
        p.merge(&other("/v/a.mov"), None, None, None, &mut ids);
        let mut q = p.clone();
        q.normalize_bins();
        assert_eq!(q, p);
    }

    #[test]
    fn standardized_folds_dots() {
        assert_eq!(standardized("/a/./b/../c//d"), "/a/c/d");
    }
}

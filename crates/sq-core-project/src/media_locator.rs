// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Relink.swift (`MediaLocator`, `RelinkCandidate.Score`, `LocateResult`, `RelinkReport`); the security-scoped bookmark
// is macOS-only: a resolver is passed in, and a relinked ref gets no bookmark (`MediaBookmark.make` has no counterpart)
//! Finds offline media (Link Media): by bookmark, by original path, by the file next to the project, by fingerprint
//! (size + SHA-256 of the first 64 KB, the scheme of the importer), or by name. No UI; returns value types.

use crate::file_walk::{Step, Values, walk};
use sq_core_model::{MediaFingerprint, MediaRef};
use sq_core_time::{Id, Time, Timestamp, sha256_digest};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

/// How well a file matches a media item; higher is better.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Score {
    NameOnly = 1,
    NameSize = 2,
    Fingerprint = 3,
}

/// A file that may be the offline media.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocatedCandidate {
    pub path: PathBuf,
    pub score: Score,
}

/// How a certain answer was found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LocateMethod {
    Bookmark,
    OriginalPath,
    ProjectNeighbour,
    Fingerprint,
}

/// The file `locate` is sure about.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Resolved {
    pub path: PathBuf,
    pub method: LocateMethod,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LocateResult {
    /// Set only when the answer is certain (bookmark, original path, or a unique fingerprint match).
    pub resolved: Option<Resolved>,
    /// Ranked best first; empty when `resolved` came from bookmark/original path.
    pub candidates: Vec<LocatedCandidate>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RelinkReport {
    pub relinked: BTreeMap<Id, PathBuf>,
    /// Mapped file exists but its fingerprint differs.
    pub fingerprint_mismatch: Vec<Id>,
    /// Nothing at the mapped path (or ref outside the moved folder).
    pub missing: Vec<Id>,
}

/// Resolves stored bookmark data to a path (platform code); `None` = cannot.
pub type BookmarkResolver = Box<dyn Fn(&[u8]) -> Option<PathBuf> + Send + Sync>;
/// Optional duration probe, used to demote name matches whose duration differs.
pub type DurationProbe = Box<dyn Fn(&Path) -> Option<Time> + Send + Sync>;

pub struct MediaLocator {
    pub project_folder: Option<PathBuf>,
    pub search_folders: Vec<PathBuf>,
    pub max_depth: usize,
    pub duration_probe: Option<DurationProbe>,
    pub bookmark_resolver: Option<BookmarkResolver>,
}

impl Default for MediaLocator {
    fn default() -> Self {
        MediaLocator {
            project_folder: None,
            search_folders: Vec::new(),
            max_depth: 6,
            duration_probe: None,
            bookmark_resolver: None,
        }
    }
}

fn file_name(p: &Path) -> String {
    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

fn same_name(a: &str, b: &str) -> bool {
    a.to_lowercase() == b.to_lowercase()
}

fn dir_components(p: &Path) -> Vec<String> {
    p.parent().map(components).unwrap_or_default()
}

fn components(p: &Path) -> Vec<String> {
    p.components()
        .filter(|c| !matches!(c, Component::CurDir))
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect()
}

fn common_prefix(a: &Path, b: &Path) -> usize {
    let skip_root = |p: &Path| components(p).into_iter().filter(|c| c != "/" && c != "\\").collect::<Vec<_>>();
    skip_root(a).iter().zip(skip_root(b).iter()).take_while(|(x, y)| x == y).count()
}

impl MediaLocator {
    /// Size, modification date and SHA-256 of the first 64 KB (same scheme as the importer).
    pub fn fingerprint(path: &Path) -> Option<MediaFingerprint> {
        let meta = std::fs::metadata(path).ok()?;
        let modified = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| Timestamp::from_unix_seconds(d.as_secs_f64()));
        Some(MediaFingerprint { size: i64::try_from(meta.len()).ok()?, modified, head_hash: Self::head_hash(path) })
    }

    pub fn head_hash(path: &Path) -> Option<String> {
        let mut buf = Vec::new();
        File::open(path).ok()?.take(64 * 1024).read_to_end(&mut buf).ok()?;
        Some(sha256_digest::hex(&buf))
    }

    /// The file has the stored size and head hash (a fingerprint without a head hash never matches).
    pub fn matches(fp: &MediaFingerprint, path: &Path) -> bool {
        let Some(n) = Self::fingerprint(path) else { return false };
        match &fp.head_hash {
            Some(h) => n.size == fp.size && n.head_hash.as_deref() == Some(h.as_str()),
            None => false,
        }
    }

    /// Synchronous and I/O heavy: hashes the head of every plausible file it meets and walks the search folders. Run it from
    /// a background task.
    ///
    /// A bookmark or original-path hit is only `resolved` when it still matches the stored fingerprint (if one with a head
    /// hash is stored); a file that exists but differs is demoted to a candidate.
    pub fn locate(&self, media: &MediaRef) -> LocateResult {
        let verifies = media.fingerprint.head_hash.is_some();
        let mut demoted: Vec<PathBuf> = Vec::new();
        if let (Some(data), Some(resolve)) = (&media.bookmark, &self.bookmark_resolver)
            && let Some(u) = resolve(data)
            && u.exists()
        {
            if !verifies || Self::matches(&media.fingerprint, &u) {
                return LocateResult {
                    resolved: Some(Resolved { path: u, method: LocateMethod::Bookmark }),
                    candidates: Vec::new(),
                };
            }
            demoted.push(u);
        }
        let original = PathBuf::from(&media.path);
        if original.exists() {
            if !verifies || Self::matches(&media.fingerprint, &original) {
                return LocateResult {
                    resolved: Some(Resolved { path: original, method: LocateMethod::OriginalPath }),
                    candidates: Vec::new(),
                };
            }
            demoted.push(original.clone());
        }

        let original_dir = original.parent().map(Path::to_path_buf).unwrap_or_default();
        let mut seen = BTreeSet::new();
        let mut found: Vec<LocatedCandidate> = Vec::new();
        let mut neighbour_hits = BTreeSet::new();
        let mut consider = |path: &Path, neighbour: bool, force: bool| {
            let key = sq_os::paths::canonical(path).unwrap_or_else(|_| path.to_path_buf());
            if !seen.insert(key.clone()) {
                return;
            }
            let Some(c) = self
                .score(path, media)
                .or_else(|| force.then(|| LocatedCandidate { path: path.to_path_buf(), score: Score::NameOnly }))
            else {
                return;
            };
            found.push(c);
            if neighbour {
                neighbour_hits.insert(key);
            }
        };
        for u in &demoted {
            consider(u, false, true);
        }
        if let Some(pf) = &self.project_folder {
            let parent = pf.parent().map(Path::to_path_buf).unwrap_or_else(|| pf.clone());
            for (root, depth) in [(pf.clone(), 3), (parent, 2)] {
                Self::walk_files(&root, depth.min(self.max_depth), &mut |p| consider(p, true, false));
            }
        }
        for f in &self.search_folders {
            Self::walk_files(f, self.max_depth, &mut |p| consider(p, false, false));
        }

        found.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| {
                    let pa = common_prefix(a.path.parent().unwrap_or(Path::new("")), &original_dir);
                    let pb = common_prefix(b.path.parent().unwrap_or(Path::new("")), &original_dir);
                    pb.cmp(&pa)
                })
                .then_with(|| a.path.cmp(&b.path))
        });
        let exact: Vec<&LocatedCandidate> = found.iter().filter(|c| c.score == Score::Fingerprint).collect();
        if let [e] = exact.as_slice() {
            let same = same_name(&file_name(&e.path), &media.name);
            let key = sq_os::paths::canonical(&e.path).unwrap_or_else(|_| e.path.clone());
            let method = if same && neighbour_hits.contains(&key) {
                LocateMethod::ProjectNeighbour
            } else {
                LocateMethod::Fingerprint
            };
            let resolved = Some(Resolved { path: e.path.clone(), method });
            return LocateResult { resolved, candidates: found };
        }
        LocateResult { resolved: None, candidates: found }
    }

    fn score(&self, path: &Path, media: &MediaRef) -> Option<LocatedCandidate> {
        let fp = &media.fingerprint;
        let size = std::fs::metadata(path).ok().and_then(|m| i64::try_from(m.len()).ok());
        let same_name = same_name(&file_name(path), &media.name);
        let same_size = size == Some(fp.size);
        let c = |score| Some(LocatedCandidate { path: path.to_path_buf(), score });
        if same_size && Self::matches(fp, path) {
            return c(Score::Fingerprint);
        }
        if !same_name {
            return None;
        }
        let duration_equal = match (media.duration, &self.duration_probe) {
            (Some(want), Some(probe)) => probe(path).map(|got| got == want),
            _ => None,
        };
        if duration_equal == Some(false) {
            return c(Score::NameOnly);
        }
        if same_size || duration_equal == Some(true) {
            return c(Score::NameSize);
        }
        c(Score::NameOnly)
    }

    /// Visits regular files below `root`, at most `depth` directory levels deep; skips hidden files and packages.
    /// Directories at the depth limit are not descended into. Symlinks to regular files are visited by their resolved path,
    /// only when the target lies inside `root`.
    fn walk_files(root: &Path, depth: usize, visit: &mut impl FnMut(&Path)) {
        let root_real = sq_os::paths::canonical(root).unwrap_or_else(|_| root.to_path_buf());
        walk(root, &mut |p: &Path, v: Option<&Values>, level: usize| {
            if v.and_then(|v| v.is_directory) == Some(true) {
                return if level > depth { Step::Skip } else { Step::Descend };
            }
            if v.and_then(|v| v.is_symbolic_link) == Some(true) {
                if let Ok(target) = sq_os::paths::canonical(p)
                    && target.starts_with(&root_real)
                    && target.is_file()
                {
                    visit(&target);
                }
            } else if v.and_then(|v| v.is_regular_file) == Some(true) {
                visit(p);
            }
            Step::Descend
        });
    }

    /// `media` pointing at `path` (name, path, refreshed fingerprint); id and duration are kept. The bookmark is cleared:
    /// a fresh one is platform code.
    pub fn applying(path: &Path, media: &MediaRef) -> MediaRef {
        let mut r = media.clone();
        r.name = file_name(path);
        r.path = path.to_string_lossy().into_owned();
        r.bookmark = None;
        if let Some(fp) = Self::fingerprint(path) {
            r.fingerprint = fp;
        }
        r
    }

    /// After the user picked `new_path` for `chosen`, applies the same directory move to `others`. The move is the old/new
    /// directory with their common trailing components removed; each mapped file is verified by fingerprint before its ref
    /// is updated. Returns chosen + others, in that order. `case_sensitive`: the volume tells apart "Footage" and "footage".
    pub fn relink_others(
        chosen: &MediaRef,
        new_path: &Path,
        others: &[MediaRef],
        case_sensitive: bool,
    ) -> (Vec<MediaRef>, RelinkReport) {
        let mut report = RelinkReport::default();
        let mut out = vec![Self::applying(new_path, chosen)];
        report.relinked.insert(chosen.id, new_path.to_path_buf());
        let same = |a: &str, b: &str| if case_sensitive { a == b } else { a.to_lowercase() == b.to_lowercase() };
        let old = dir_components(Path::new(&chosen.path));
        let new = dir_components(new_path);
        let mut k = 0;
        while k < old.len() && k < new.len() && same(&old[old.len() - 1 - k], &new[new.len() - 1 - k]) {
            k += 1;
        }
        let old_prefix = &old[..old.len() - k];
        let new_prefix = &new[..new.len() - k];
        for m in others {
            let comps = components(Path::new(&m.path));
            if comps.len() <= old_prefix.len() || !comps.iter().zip(old_prefix).all(|(a, b)| same(a, b)) {
                report.missing.push(m.id);
                out.push(m.clone());
                continue;
            }
            let mapped: PathBuf = new_prefix.iter().chain(comps[old_prefix.len()..].iter()).collect();
            if !mapped.exists() {
                report.missing.push(m.id);
                out.push(m.clone());
                continue;
            }
            if !Self::matches(&m.fingerprint, &mapped) {
                report.fingerprint_mismatch.push(m.id);
                out.push(m.clone());
                continue;
            }
            report.relinked.insert(m.id, mapped.clone());
            out.push(Self::applying(&mapped, m));
        }
        (out, report)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct Dir(PathBuf);
    impl Dir {
        fn new(tag: &str) -> Dir {
            let p = std::env::temp_dir().join(format!("sq-locator-{tag}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&p);
            fs::create_dir_all(&p).unwrap();
            Dir(fs::canonicalize(&p).unwrap())
        }
        fn file(&self, rel: &str, bytes: &[u8]) -> PathBuf {
            let p = self.0.join(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(&p, bytes).unwrap();
            p
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn media_for(id: u128, original: &str, real: &Path) -> MediaRef {
        let mut m = MediaRef::new(
            Id::from_u128(id),
            &file_name(Path::new(original)),
            original,
            MediaLocator::fingerprint(real).unwrap(),
        );
        m.path = original.to_string();
        m
    }

    #[test]
    fn the_original_path_wins_when_it_still_matches_and_is_demoted_when_it_differs() {
        let d = Dir::new("orig");
        let f = d.file("a/clip.mov", b"hello footage");
        let m = media_for(1, f.to_str().unwrap(), &f);
        let r = MediaLocator::default().locate(&m);
        assert_eq!(r.resolved, Some(Resolved { path: f.clone(), method: LocateMethod::OriginalPath }));
        fs::write(&f, b"another take").unwrap();
        let r = MediaLocator::default().locate(&m);
        assert!(r.resolved.is_none());
        assert_eq!(r.candidates, vec![LocatedCandidate { path: f, score: Score::NameOnly }]);
    }

    #[test]
    fn a_unique_fingerprint_match_resolves_even_under_another_name() {
        let d = Dir::new("fp");
        let real = d.file("card/C0001.MP4", b"the pixels");
        d.file("card/other.mov", b"not the pixels");
        let m = media_for(2, "/gone/volume/renamed.mov", &real);
        let loc = MediaLocator { search_folders: vec![d.0.clone()], ..MediaLocator::default() };
        let r = loc.locate(&m);
        assert_eq!(r.resolved, Some(Resolved { path: real.clone(), method: LocateMethod::Fingerprint }));
        assert_eq!(r.candidates[0], LocatedCandidate { path: real, score: Score::Fingerprint });
    }

    #[test]
    fn same_name_next_to_the_project_is_a_neighbour_and_same_name_alone_is_only_a_candidate() {
        let d = Dir::new("nb");
        let real = d.file("proj/media/clip.mov", b"abcdef");
        let m = media_for(3, "/old/clip.mov", &real);
        let loc = MediaLocator { project_folder: Some(d.0.join("proj")), ..MediaLocator::default() };
        assert_eq!(loc.locate(&m).resolved.map(|r| r.method), Some(LocateMethod::ProjectNeighbour));
        // A different file with the same name and size: a candidate, never certain.
        let d2 = Dir::new("nb2");
        let other = d2.file("x/clip.mov", b"ABCDEF");
        let loc = MediaLocator { search_folders: vec![d2.0.clone()], ..MediaLocator::default() };
        let r = loc.locate(&m);
        assert!(r.resolved.is_none());
        assert_eq!(r.candidates, vec![LocatedCandidate { path: other, score: Score::NameSize }]);
    }

    #[test]
    fn search_depth_and_hidden_files_are_respected() {
        let d = Dir::new("depth");
        let real = d.file("a/b/c/clip.mov", b"deep");
        d.file(".hidden/clip.mov", b"deep");
        let m = media_for(4, "/old/clip.mov", &real);
        let shallow = MediaLocator { search_folders: vec![d.0.clone()], max_depth: 2, ..MediaLocator::default() };
        assert!(shallow.locate(&m).candidates.is_empty());
        let deep = MediaLocator { search_folders: vec![d.0.clone()], max_depth: 4, ..MediaLocator::default() };
        assert_eq!(deep.locate(&m).candidates.len(), 1);
    }

    #[test]
    fn relinking_one_file_moves_the_others_by_the_same_folder_change() {
        let d = Dir::new("others");
        let a = d.file("new/Footage/a.mov", b"aaaa");
        let b = d.file("new/Footage/sub/b.mov", b"bbbb");
        let c = d.file("new/Footage/c.mov", b"cccc-changed");
        let ma = media_for(10, "/old/Footage/a.mov", &a);
        let mb = media_for(11, "/old/Footage/sub/b.mov", &b);
        let mut mc = media_for(12, "/old/Footage/c.mov", &c);
        mc.fingerprint.head_hash = Some("00".into());
        let md = media_for(13, "/elsewhere/d.mov", &a);
        let me = media_for(14, "/old/Footage/gone.mov", &a);
        let (refs, report) = MediaLocator::relink_others(&ma, &a, &[mb.clone(), mc.clone(), md, me], true);
        assert_eq!(refs.len(), 5);
        assert_eq!(refs[0].path, a.to_string_lossy());
        assert_eq!(refs[1].path, b.to_string_lossy());
        assert_eq!(report.relinked.keys().copied().collect::<Vec<_>>(), vec![Id::from_u128(10), Id::from_u128(11)]);
        assert_eq!(report.fingerprint_mismatch, vec![Id::from_u128(12)]);
        assert_eq!(report.missing, vec![Id::from_u128(13), Id::from_u128(14)]);
        assert_eq!(refs[2].path, mc.path);
    }
}

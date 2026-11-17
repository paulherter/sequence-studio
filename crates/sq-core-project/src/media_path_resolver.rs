// SPDX-License-Identifier: GPL-3.0-or-later
//! Finds media files whose recorded path is stale.
// Swift: MediaPathResolver.swift

use crate::file_walk::{LocalPath, Step, walk};
use crate::relink::RelinkCandidate;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

/// Finds media files whose recorded path is stale (imported projects: Premiere stores absolute paths from another
/// machine or volume, Windows drive paths, sometimes a relative path). Order: the path as stored; the relative path
/// against the project folder; the same file name in the project folder (and subfolders) and its parent; then the
/// same name in folders the user chose with Locate. Names compare case-insensitively; a known size must match; when
/// several files share the name, the one whose folders match the stored path's trailing folders wins, else none
/// (camera names like C0001.MP4 repeat across cards: never guess). File system only, no media probing.
#[derive(Clone, Debug, PartialEq)]
pub struct MediaPathResolver {
    /// Folder of the project file.
    pub project_folder: Option<PathBuf>,
    /// Folders the user chose with Locate.
    pub search_folders: Vec<PathBuf>,
    /// Folder levels searched below the project folder.
    pub project_depth: usize,
    /// Folder levels searched below its parent.
    pub parent_depth: usize,
    /// Folder levels searched below a Locate folder.
    pub search_depth: usize,
}

/// Where a hit was found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    /// The path as stored.
    StoredPath,
    /// The relative path against the project folder.
    RelativePath,
    /// The file name near the project folder.
    ProjectFolder,
    /// The file name in a Locate folder.
    SearchFolder,
}

/// A resolved file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hit {
    /// Where the file is.
    pub path: String,
    /// How it was found.
    pub method: Method,
}

/// One stale path to resolve.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    /// The recorded path.
    pub stored_path: String,
    /// The recorded relative path, if any.
    pub relative_path: Option<String>,
    /// Recorded file size; `None` or 0 = unknown.
    pub size: Option<i64>,
}

impl Request {
    /// A request with a stored path only.
    pub fn new(stored_path: &str) -> Request {
        Request { stored_path: stored_path.to_string(), relative_path: None, size: None }
    }
}

impl MediaPathResolver {
    /// A resolver with the default search depths.
    pub fn new(project_folder: Option<PathBuf>, search_folders: Vec<PathBuf>) -> MediaPathResolver {
        MediaPathResolver { project_folder, search_folders, project_depth: 5, parent_depth: 1, search_depth: 12 }
    }

    /// The last component of a POSIX or Windows path.
    pub fn file_name_of(path: &str) -> String {
        path.split(['/', '\\']).rfind(|s| !s.is_empty()).unwrap_or(path).to_string()
    }

    /// Folder components of a POSIX or Windows path (without the file name and drive letter).
    pub fn folders_of(path: &str) -> Vec<String> {
        let mut parts: Vec<&str> = path.split(['/', '\\']).filter(|s| !s.is_empty()).collect();
        parts.pop();
        parts.into_iter().map(str::to_string).collect()
    }

    /// Hits keyed by `stored_path`; unresolved requests are absent. Synchronous file I/O: call off the UI thread.
    pub fn resolve(&self, requests: &[Request]) -> BTreeMap<String, Hit> {
        let mut hits: BTreeMap<String, Hit> = BTreeMap::new();
        let mut open: Vec<&Request> = Vec::new();
        for r in requests {
            if hits.contains_key(&r.stored_path) {
                continue;
            }
            if LocalPath::is_absolute(&r.stored_path) && Self::is_file(&r.stored_path, r.size) {
                hits.insert(r.stored_path.clone(), Hit { path: r.stored_path.clone(), method: Method::StoredPath });
            } else if let (Some(rel), Some(pf)) =
                (r.relative_path.as_deref().filter(|r| !r.is_empty()), &self.project_folder)
            {
                let p = standardized(&pf.join(rel.replace('\\', "/")));
                if Self::is_file(&p, r.size) {
                    hits.insert(r.stored_path.clone(), Hit { path: p, method: Method::RelativePath });
                } else {
                    open.push(r);
                }
            } else {
                open.push(r);
            }
        }
        if open.is_empty() {
            return hits;
        }

        let wanted: BTreeSet<String> = open.iter().map(|r| Self::file_name_of(&r.stored_path).to_lowercase()).collect();
        let mut roots: Vec<(PathBuf, usize)> = Vec::new();
        if let Some(pf) = &self.project_folder {
            roots =
                vec![(pf.clone(), self.project_depth), (pf.parent().unwrap_or(pf).to_path_buf(), self.parent_depth)];
        }
        let near = RelinkScanner::scan_roots(&roots, &wanted);
        for r in &open {
            if let Some(p) = Self::pick(&near, &r.stored_path, r.size) {
                hits.insert(r.stored_path.clone(), Hit { path: p, method: Method::ProjectFolder });
            }
        }
        let rest: Vec<&Request> = open.into_iter().filter(|r| !hits.contains_key(&r.stored_path)).collect();
        if rest.is_empty() || self.search_folders.is_empty() {
            return hits;
        }
        let far_roots: Vec<(PathBuf, usize)> =
            self.search_folders.iter().map(|f| (f.clone(), self.search_depth)).collect();
        let far_named: BTreeSet<String> =
            rest.iter().map(|r| Self::file_name_of(&r.stored_path).to_lowercase()).collect();
        let far = RelinkScanner::scan_roots(&far_roots, &far_named);
        for r in rest {
            if let Some(p) = Self::pick(&far, &r.stored_path, r.size) {
                hits.insert(r.stored_path.clone(), Hit { path: p, method: Method::SearchFolder });
            }
        }
        hits
    }

    /// The one candidate for `stored_path`: same name (case-insensitive), same size when `size` is known; among several,
    /// the strictly best match of trailing folder names; `None` when none or a tie.
    pub fn pick(candidates: &[RelinkCandidate], stored_path: &str, size: Option<i64>) -> Option<String> {
        let name = Self::file_name_of(stored_path).to_lowercase();
        let mut list: Vec<&RelinkCandidate> =
            candidates.iter().filter(|c| Self::file_name_of(&c.path).to_lowercase() == name).collect();
        if let Some(s) = size.filter(|s| *s > 0) {
            list.retain(|c| c.size == s);
        }
        if list.len() <= 1 {
            return list.first().map(|c| c.path.clone());
        }
        let want: Vec<String> = Self::folders_of(stored_path).iter().map(|f| f.to_lowercase()).collect();
        let mut scored: Vec<(&str, usize)> = list
            .iter()
            .map(|c| {
                let have: Vec<String> = Self::folders_of(&c.path).iter().map(|f| f.to_lowercase()).collect();
                let matched = have.iter().rev().zip(want.iter().rev()).take_while(|(a, b)| a == b).count();
                (c.path.as_str(), matched)
            })
            .collect();
        scored.sort_by_key(|s| std::cmp::Reverse(s.1));
        (scored[0].1 > scored[1].1).then(|| scored[0].0.to_string())
    }

    fn is_file(path: &str, size: Option<i64>) -> bool {
        let Ok(m) = fs::metadata(path) else { return false };
        if m.is_dir() {
            return false;
        }
        match size.filter(|s| *s > 0) {
            None => true,
            Some(s) => i64::try_from(m.len()).ok() == Some(s),
        }
    }
}

/// Walks folders for files with wanted names (Locate and the import resolver).
pub struct RelinkScanner;

impl RelinkScanner {
    /// Files below each folder (any depth) whose lower-cased name is in `named`.
    pub fn scan(folders: &[PathBuf], named: &BTreeSet<String>) -> Vec<RelinkCandidate> {
        let roots: Vec<(PathBuf, usize)> = folders.iter().map(|f| (f.clone(), usize::MAX)).collect();
        Self::scan_roots(&roots, named)
    }

    /// `roots`: folder and the number of folder levels to descend (0 = only its own files). Hidden files and package
    /// contents are skipped; a file met twice (overlapping roots) is listed once.
    pub fn scan_roots(roots: &[(PathBuf, usize)], named: &BTreeSet<String>) -> Vec<RelinkCandidate> {
        if named.is_empty() {
            return Vec::new();
        }
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut out: Vec<RelinkCandidate> = Vec::new();
        for (root, depth) in roots {
            walk(root, &mut |path, v, level| {
                if v.is_some_and(|v| v.is_directory == Some(true)) {
                    return if level > *depth { Step::Skip } else { Step::Descend };
                }
                let file_name = path.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
                let Some(v) = v.filter(|v| v.is_regular_file == Some(true) && named.contains(&file_name)) else {
                    return Step::Descend;
                };
                let std_path = standardized(path);
                if seen.insert(std_path.clone()) {
                    out.push(RelinkCandidate {
                        path: std_path,
                        size: v.file_size.unwrap_or(-1),
                        modified: v.content_modification_date,
                        duration: None,
                    });
                }
                Step::Descend
            });
        }
        out
    }
}

/// The path with `.` and `..` resolved lexically (Swift `standardizedFileURL.path`), as `/` text.
pub(crate) fn standardized(path: &Path) -> String {
    let mut parts: Vec<Component> = Vec::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir if matches!(parts.last(), Some(Component::Normal(_))) => {
                parts.pop();
            }
            Component::ParentDir if matches!(parts.last(), Some(Component::RootDir)) => {}
            c => parts.push(c),
        }
    }
    // Swift media paths are POSIX-style text, so the result always uses `/` (also on Windows) and no verbatim prefix.
    sq_os::paths::stored(&parts.iter().collect::<PathBuf>())
}

#[cfg(test)]
mod tests;

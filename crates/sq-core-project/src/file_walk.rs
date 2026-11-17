// SPDX-License-Identifier: GPL-3.0-or-later
//! Depth-first walk below a folder, the same on every system.
// Swift: FileWalk.swift
//
// The Swift walk exists to avoid Foundation enumerator and `URL.resourceValues` bugs on Windows; `std::fs` has neither.
// shortcut: `is_package` is always false (macOS bundles are folders here), upgrade when a platform backend reports bundles.

use crate::recovery::{last_component, list_dir};
use sq_core_time::Timestamp;
use std::fs;
use std::path::Path;

/// What the walk knows of an item.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Values {
    /// A folder (a symbolic link to one is not).
    pub is_directory: Option<bool>,
    /// A regular file.
    pub is_regular_file: Option<bool>,
    /// A macOS bundle shown as one item.
    pub is_package: Option<bool>,
    /// A symbolic link.
    pub is_symbolic_link: Option<bool>,
    /// Size in bytes of a regular file.
    pub file_size: Option<i64>,
    /// Last change of the content.
    pub content_modification_date: Option<Timestamp>,
}

impl Values {
    /// The item's values; `None` when it cannot be read (links are not followed).
    pub fn read(path: &Path) -> Option<Values> {
        let m = fs::symlink_metadata(path).ok()?;
        let regular = m.is_file();
        Some(Values {
            is_directory: Some(m.is_dir()),
            is_regular_file: Some(regular),
            is_package: Some(false),
            is_symbolic_link: Some(m.file_type().is_symlink()),
            file_size: if regular { i64::try_from(m.len()).ok() } else { None },
            content_modification_date: crate::recovery::modified(path),
        })
    }
}

/// What the visitor wants next.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// Walk into this folder (ignored for files).
    Descend,
    /// Do not walk into this folder.
    Skip,
    /// End the whole walk.
    Stop,
}

/// Calls `visit(path, values, level)` for every item below `root` (level 1 = a direct child), a folder before its
/// contents, in file name order. Hidden items (dot names) are left out; the contents of packages are never visited.
/// Returns false when `visit` stopped the walk.
pub fn walk(root: &Path, visit: &mut impl FnMut(&Path, Option<&Values>, usize) -> Step) -> bool {
    walk_level(root, 1, visit)
}

fn walk_level(folder: &Path, level: usize, visit: &mut impl FnMut(&Path, Option<&Values>, usize) -> Step) -> bool {
    for path in list_dir(folder) {
        if last_component(&path).starts_with('.') {
            continue;
        }
        let values = Values::read(&path);
        let step = visit(&path, values.as_ref(), level);
        if step == Step::Stop {
            return false;
        }
        let into =
            step == Step::Descend && values.is_some_and(|v| v.is_directory == Some(true) && v.is_package != Some(true));
        if into && !walk_level(&path, level + 1, visit) {
            return false;
        }
    }
    true
}

/// Path spelling checks that hold on macOS, Linux and Windows.
pub struct LocalPath;

impl LocalPath {
    /// An absolute path of this system: `/...` everywhere; on Windows also `C:/`, `C:\` and UNC `\\server\share`.
    /// A Windows-style path read on the Mac (from a Premiere project) is not absolute here: it cannot name a local file.
    pub fn is_absolute(path: &str) -> bool {
        if path.starts_with('/') {
            return true;
        }
        #[cfg(windows)]
        {
            if path.starts_with("\\\\") {
                return true;
            }
            let c = path.as_bytes();
            if c.len() >= 3 && c[0].is_ascii_alphabetic() && c[1] == b':' && (c[2] == b'/' || c[2] == b'\\') {
                return true;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recovery::tests::TempDir;
    use std::collections::BTreeMap;

    fn tree(dirs: &[&str], files: &[&str]) -> TempDir {
        let root = TempDir::new();
        for d in dirs {
            fs::create_dir_all(root.path().join(d)).unwrap();
        }
        for f in files {
            fs::write(root.path().join(f), [1u8]).unwrap();
        }
        root
    }

    /// Windows bug this walk replaces: after one skipped folder the enumerator listed no file of any later folder.
    #[test]
    fn skipping_one_folder_still_walks_its_siblings() {
        let root = tree(&["A", "B.sqproj", "C"], &["A/a.mov", "B.sqproj/b.mov", "C/c.mov", "C/d.mov"]);
        let mut files: Vec<String> = Vec::new();
        walk(&root.path(), &mut |p, v, _| {
            if v.and_then(|v| v.is_directory) != Some(true) {
                files.push(last_component(p));
            }
            if p.extension().is_some_and(|e| e == "sqproj") { Step::Skip } else { Step::Descend }
        });
        files.sort();
        assert_eq!(files, ["a.mov", "c.mov", "d.mov"]);
    }

    #[test]
    fn dot_files_are_hidden_everywhere_and_levels_count_from_one() {
        let root = tree(&["X/Y", ".cache"], &["X/Y/z.mov", "X/.hidden.mov", ".cache/c.mov", "top.mov"]);
        let mut seen: BTreeMap<String, usize> = BTreeMap::new();
        walk(&root.path(), &mut |p, _, level| {
            seen.insert(last_component(p), level);
            Step::Descend
        });
        let want: BTreeMap<String, usize> =
            [("X", 1), ("top.mov", 1), ("Y", 2), ("z.mov", 3)].into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        assert_eq!(seen, want);
    }

    #[test]
    fn stop_ends_the_whole_walk() {
        let root = tree(&["A", "B"], &["A/1.mov", "A/2.mov", "B/3.mov"]);
        let mut files = 0;
        let finished = walk(&root.path(), &mut |_, v, _| {
            if v.and_then(|v| v.is_directory) == Some(true) {
                return Step::Descend;
            }
            files += 1;
            if files == 2 { Step::Stop } else { Step::Descend }
        });
        assert!(!finished && files == 2);
    }

    /// Camera clips of 2-4 GiB and above gave a crash on Windows in the Swift walk; sizes here must come out right.
    #[test]
    fn files_of_every_size_give_their_size_and_date() {
        let root = tree(&["Imported"], &["Imported/small.wav"]);
        let sizes: [(&str, i64); 3] =
            [("C2171.MP4", 3_288_967_572), ("C2170.MP4", 2_349_427_350), ("long.mov", 6_500_000_000)];
        for (name, size) in sizes {
            let path = root.path().join("Imported").join(name);
            let f = fs::File::create(&path).unwrap();
            // NTFS allocates the whole length unless the file is flagged sparse first (12 GB here otherwise).
            #[cfg(windows)]
            {
                let flagged = std::process::Command::new("fsutil").args(["sparse", "setflag"]).arg(&path).status();
                assert!(flagged.is_ok_and(|s| s.success()), "fsutil sparse setflag");
            }
            f.set_len(size.unsigned_abs()).unwrap(); // sparse where the file system allows it
        }
        let mut seen: BTreeMap<String, i64> = BTreeMap::new();
        let mut dated = 0;
        walk(&root.path(), &mut |p, v, _| {
            if let Some(v) = v {
                if v.is_regular_file == Some(true) {
                    seen.insert(last_component(p), v.file_size.unwrap_or(-1));
                }
                dated += i32::from(v.content_modification_date.is_some());
            }
            Step::Descend
        });
        let mut want: BTreeMap<String, i64> = sizes.iter().map(|(k, v)| (k.to_string(), *v)).collect();
        want.insert("small.wav".into(), 1);
        assert_eq!(seen, want);
        assert!(dated >= 4);
        assert_eq!(Values::read(&root.path().join("Imported")).map(|v| v.is_directory), Some(Some(true)));
        assert_eq!(Values::read(&root.path().join("gone")), None);
    }

    #[test]
    fn absolute_paths_of_this_system() {
        assert!(LocalPath::is_absolute("/Volumes/SSD/a.mov"));
        assert!(!LocalPath::is_absolute("Files/a.mov"));
        assert!(!LocalPath::is_absolute(""));
        #[cfg(windows)]
        {
            assert!(LocalPath::is_absolute("C:/Users/p/a.mov") && LocalPath::is_absolute("d:\\Footage\\a.mov"));
            assert!(LocalPath::is_absolute("\\\\nas\\share\\a.mov"));
            assert!(!LocalPath::is_absolute("C:a.mov"));
        }
        #[cfg(not(windows))]
        assert!(!LocalPath::is_absolute("C:/Users/p/a.mov") && !LocalPath::is_absolute("D:\\Footage\\a.mov"));
    }
}

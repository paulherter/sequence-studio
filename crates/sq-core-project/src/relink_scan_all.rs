// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: RelinkScanAll.swift

//! `RelinkScanner` beyond the name scan: every media file below the roots, and where a Reconnect looks.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use crate::file_walk::{Step, walk};
use crate::media_path_resolver::{RelinkScanner, standardized};
use crate::relink::RelinkCandidate;

impl RelinkScanner {
    /// Every media file (`is_media(lowercased extension)`) below each root, for scoring by more than the name. Same walk
    /// rules as `scan_roots`; stops after `limit` files so a huge drive cannot stall the dialog.
    pub fn scan_media(
        roots: &[(PathBuf, usize)],
        is_media: &dyn Fn(&str) -> bool,
        limit: usize,
    ) -> Vec<RelinkCandidate> {
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut out: Vec<RelinkCandidate> = Vec::new();
        for (root, depth) in roots {
            let finished = walk(root, &mut |path, v, level| {
                if v.is_some_and(|v| v.is_directory == Some(true)) {
                    return if level > *depth { Step::Skip } else { Step::Descend };
                }
                let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
                let Some(v) = v.filter(|v| v.is_regular_file == Some(true) && is_media(&ext)) else {
                    return Step::Descend;
                };
                let text = standardized(path);
                if !seen.insert(text.clone()) {
                    return Step::Descend;
                }
                out.push(RelinkCandidate {
                    path: text,
                    size: v.file_size.unwrap_or(-1),
                    modified: v.content_modification_date,
                    duration: None,
                });
                if out.len() >= limit { Step::Stop } else { Step::Descend }
            });
            if !finished {
                return out;
            }
        }
        out
    }

    /// Where a Reconnect from one found file or folder looks: that folder (deep), its parent two levels down (siblings),
    /// and a folder of the same name on every other mounted volume.
    pub fn reconnect_roots(picked: &Path, volumes: &[PathBuf]) -> Vec<(PathBuf, usize)> {
        let folder = if picked.is_file() {
            picked.parent().map_or_else(|| picked.to_path_buf(), Path::to_path_buf)
        } else {
            picked.to_path_buf()
        };
        let mut roots = vec![(folder.clone(), 8)];
        if let Some(parent) = folder.parent()
            && parent != Path::new("/")
            && !parent.as_os_str().is_empty()
        {
            roots.push((parent.to_path_buf(), 2));
        }
        let comps = clean_components(&folder);
        let name_of = |v: &Path| v.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if comps.len() >= 2 && comps[0] == "Volumes" {
            let rest = comps[2..].join("/");
            for v in volumes.iter().filter(|v| name_of(v) != comps[1]) {
                let twin = if rest.is_empty() { v.clone() } else { v.join(&rest) };
                if twin.exists() {
                    roots.push((twin, 8));
                }
            }
        } else {
            let name = folder.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            for v in volumes {
                let twin = v.join(&name);
                if twin.exists() {
                    roots.push((twin, 8));
                }
            }
        }
        roots
    }
}

/// The normal components of a path, lexically cleaned (`.` dropped, `..` resolved).
fn clean_components(path: &Path) -> Vec<String> {
    let mut parts: Vec<String> = Vec::new();
    for c in path.components() {
        match c {
            Component::Normal(n) => parts.push(n.to_string_lossy().into_owned()),
            Component::ParentDir => {
                parts.pop();
            }
            _ => {}
        }
    }
    parts
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recovery::tests::TempDir;
    use std::fs;

    fn file(dir: &Path, rel: &str, size: usize) -> PathBuf {
        let u = rel.split('/').fold(dir.to_path_buf(), |p, c| p.join(c));
        fs::create_dir_all(u.parent().unwrap()).unwrap();
        fs::write(&u, vec![0u8; size]).unwrap();
        u
    }

    #[test]
    fn reconnect_roots_cover_the_folder_its_parent_and_the_twin_on_other_volumes() {
        let d = TempDir::new();
        let vol = d.path().join("vols").join("NEWDISK");
        let twin = vol.join("Day1");
        fs::create_dir_all(&twin).unwrap();
        let f = file(&d.path(), "Shoot/Day1/a.mov", 1);
        let roots = RelinkScanner::reconnect_roots(&f, &[vol]);
        assert_eq!(roots[0], (d.path().join("Shoot/Day1"), 8));
        assert_eq!(roots[1], (d.path().join("Shoot"), 2));
        assert_eq!(roots[2], (twin, 8));
    }

    #[test]
    fn scan_media_lists_media_below_the_roots_and_stops_at_the_limit() {
        let d = TempDir::new();
        file(&d.path(), "a.mov", 1);
        file(&d.path(), "sub/b.mov", 2);
        file(&d.path(), "sub/c.txt", 3);
        file(&d.path(), "sub/deep/d.mov", 4);
        let is_media = |ext: &str| ext == "mov";
        let all = RelinkScanner::scan_media(&[(d.path(), 1)], &is_media, 100);
        assert_eq!(all.len(), 2, "depth 1 does not reach deep/");
        assert_eq!(RelinkScanner::scan_media(&[(d.path(), 5)], &is_media, 100).len(), 3);
        assert_eq!(RelinkScanner::scan_media(&[(d.path(), 5)], &is_media, 1).len(), 1);
    }
}

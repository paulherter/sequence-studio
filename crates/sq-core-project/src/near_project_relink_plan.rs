// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: NearProjectRelink.swift (`plan`; `trailing_match` lives in sq-core-edit, the scan needs `RelinkScanner`)

//! Media of a copied project that sits next to the project file.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use crate::media_path_resolver::{MediaPathResolver, RelinkScanner};
use crate::relink::RelinkPlanner;
use sq_core_edit::near_project_relink::NearProjectRelink;
use sq_core_model::MediaRef;
use sq_core_time::Id;

/// `NearProjectRelink.plan`.
pub trait NearProjectRelinkPlanExt {
    /// Media id -> found path for the `missing` items that have a file near `folder` (the project file's folder): the
    /// stored path's trailing part first, else the same file name below the folder with the recorded size.
    fn plan(missing: &[MediaRef], folder: &Path, max_trailing: usize) -> BTreeMap<Id, String>;
}

impl NearProjectRelinkPlanExt for NearProjectRelink {
    fn plan(missing: &[MediaRef], folder: &Path, max_trailing: usize) -> BTreeMap<Id, String> {
        let mut plan = BTreeMap::new();
        if missing.is_empty() {
            return plan;
        }
        let mut rest: Vec<MediaRef> = Vec::new();
        for m in missing {
            match NearProjectRelink::trailing_match(&m.path, folder, m.fingerprint.size, max_trailing) {
                Some(p) => {
                    plan.insert(m.id, p);
                }
                None => rest.push(m.clone()),
            }
        }
        if rest.is_empty() {
            return plan;
        }
        let wanted: BTreeSet<String> =
            rest.iter().map(|m| MediaPathResolver::file_name_of(&m.path).to_lowercase()).collect();
        let found = RelinkScanner::scan_roots(&[(folder.to_path_buf(), NearProjectRelink::DEPTH)], &wanted);
        for (id, p) in RelinkPlanner::match_(&rest, &found).plan {
            plan.entry(id).or_insert(p);
        }
        plan
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recovery::tests::TempDir;
    use sq_core_model::MediaFingerprint;
    use std::fs;
    use std::path::PathBuf;

    fn file(dir: &Path, rel: &str, size: usize) -> PathBuf {
        let u = rel.split('/').fold(dir.to_path_buf(), |p, c| p.join(c));
        fs::create_dir_all(u.parent().unwrap()).unwrap();
        fs::write(&u, vec![0u8; size]).unwrap();
        u
    }

    fn media(n: u128, path: &str, size: i64) -> MediaRef {
        MediaRef::new(Id::from_u128(n), &MediaPathResolver::file_name_of(path), path, MediaFingerprint::new(size))
    }

    fn text(p: &Path) -> String {
        p.to_string_lossy().replace('\\', "/")
    }

    #[test]
    fn stored_mac_paths_resolve_by_their_trailing_folders_below_the_project_folder() {
        let dir = TempDir::new();
        let d = dir.path();
        let imported = file(&d, "Files/Imported/C2171.MP4", 10);
        file(&d, "Media/C2171.MP4", 10);
        let m = file(&d, "Media/C2174.MP4", 20);
        let a = media(1, "/Users/me/Documents/Projects/Client Film/Files/Imported/C2171.MP4", 10);
        let b = media(2, "/Users/me/Documents/Projects/Client/Media/C2174.MP4", 20);
        let plan = NearProjectRelink::plan(&[a, b], &d, 8);
        assert_eq!(plan.get(&Id::from_u128(1)).map(|p| text(Path::new(p))), Some(text(&imported)));
        assert_eq!(plan.get(&Id::from_u128(2)).map(|p| text(Path::new(p))), Some(text(&m)));
    }

    #[test]
    fn windows_stored_paths_and_name_search_with_the_recorded_size() {
        let dir = TempDir::new();
        let d = dir.path();
        let deep = file(&d, "Shoot/Day 2/clip.mov", 30);
        file(&d, "Other/b.wav", 7);
        let a = media(1, r"D:\Footage\Card 1\clip.mov", 30);
        let b = media(2, "/Volumes/SSD/b.wav", 8);
        let plan = NearProjectRelink::plan(&[a, b], &d, 8);
        assert_eq!(plan.get(&Id::from_u128(1)).map(|p| text(Path::new(p))), Some(text(&deep)));
        assert_eq!(plan.get(&Id::from_u128(2)), None);
    }

    #[test]
    fn nothing_near_the_project_gives_an_empty_plan() {
        let dir = TempDir::new();
        assert!(NearProjectRelink::plan(&[media(1, "/Users/a/gone.mov", 1)], &dir.path(), 8).is_empty());
        assert!(NearProjectRelink::plan(&[], &dir.path(), 8).is_empty());
    }
}

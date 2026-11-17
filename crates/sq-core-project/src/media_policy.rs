// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MediaPolicy.swift (`MediaManagement.relativePath`, `FolderSyncAdd`, the `Project` folder-sync verbs)

//! Folder sync bookkeeping of a project: the files the user removed from the bin although they stay in the project folder,
//! and the bins that mirror the folders of newly found files.

use crate::project_merge::{find_bin_mut, standardized};
use sq_core_model::{Bin, BinItem, BinItemRef, MediaPolicy, MediaRef, Project};
use sq_core_time::{Id, IdSource};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path};
use std::time::{Duration, SystemTime};

/// One new file found in the project folder, with the bin path that mirrors its folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FolderSyncAdd {
    /// The file.
    pub path: String,
    /// Bin names from the root down.
    pub bin: Vec<String>,
}

/// `path` below `folder` as a "/"-joined relative path; `None` when it is not below.
pub fn relative_path(path: &str, folder: &str) -> Option<String> {
    let root = standardized(folder);
    let full = standardized(path);
    let root_parts: Vec<&str> = root.split('/').filter(|p| !p.is_empty()).collect();
    let parts: Vec<&str> = full.split('/').filter(|p| !p.is_empty()).collect();
    let below = parts.len() > root_parts.len()
        && parts.iter().zip(&root_parts).all(|(a, b)| a.to_lowercase() == b.to_lowercase());
    below.then(|| parts[root_parts.len()..].join("/"))
}

/// Key of a bin path in the `new_ids` of `bin_id` and `add_synced`.
pub fn bin_key(path: &[String]) -> String {
    path.iter().map(|p| p.to_lowercase()).collect::<Vec<_>>().join("/")
}

fn is_blank(policy: &MediaPolicy) -> bool {
    policy.outside.is_none()
        && policy.copy_library_items.is_none()
        && policy.watch_folder.is_none()
        && policy.ignored.is_none()
}

/// `extension Project` of MediaPolicy.swift.
pub trait ProjectFolderSyncExt {
    /// Remembers that the user removed this file from the bin although it stays in the project folder.
    fn ignore_folder_file(&mut self, path: &str, project_folder: &str);
    /// The file is wanted again (imported by hand): it leaves the ignored list.
    fn unignore_folder_file(&mut self, path: &str, project_folder: &str);
    /// The bin reached by `path` below the root (`["Day 1", "A-cam"]`), created when missing. `[]` is the root bin.
    /// `new_ids` fixes the ids of bins this call creates (see `new_bin_ids`).
    fn bin_id(
        &mut self,
        path: &[String],
        create: bool,
        new_ids: &BTreeMap<String, Id>,
        ids: &mut dyn IdSource,
    ) -> Option<Id>;
    /// Files probed items into the bins that mirror their folders. Items already in the project (same path) are skipped.
    /// Returns how many were added.
    fn add_synced(
        &mut self,
        items: &[(MediaRef, Vec<String>)],
        new_ids: &BTreeMap<String, Id>,
        ids: &mut dyn IdSource,
    ) -> usize;
}

/// One fresh id per bin path (and each of its parents) that `items` may need. Make it once, outside an `amend` closure, so
/// the bins keep their ids in every history state.
pub fn new_bin_ids(items: &[(MediaRef, Vec<String>)], ids: &mut dyn IdSource) -> BTreeMap<String, Id> {
    let mut out = BTreeMap::new();
    for (_, bin) in items {
        for depth in 0..bin.len() {
            out.entry(bin_key(&bin[..=depth])).or_insert_with(|| ids.next_id());
        }
    }
    out
}

impl ProjectFolderSyncExt for Project {
    fn ignore_folder_file(&mut self, path: &str, project_folder: &str) {
        let Some(rel) = relative_path(path, project_folder) else { return };
        let mut policy = self.media_policy.clone().unwrap_or_default();
        let mut list = policy.ignored.clone().unwrap_or_default();
        if list.iter().any(|e| e.to_lowercase() == rel.to_lowercase()) {
            return;
        }
        list.push(rel);
        policy.ignored = Some(list);
        self.media_policy = Some(policy);
    }

    fn unignore_folder_file(&mut self, path: &str, project_folder: &str) {
        let Some(rel) = relative_path(path, project_folder) else { return };
        let Some(mut policy) = self.media_policy.clone() else { return };
        let Some(mut list) = policy.ignored.clone() else { return };
        list.retain(|e| e.to_lowercase() != rel.to_lowercase());
        policy.ignored = (!list.is_empty()).then_some(list);
        self.media_policy = (!is_blank(&policy)).then_some(policy);
    }

    fn bin_id(
        &mut self,
        path: &[String],
        create: bool,
        new_ids: &BTreeMap<String, Id>,
        ids: &mut dyn IdSource,
    ) -> Option<Id> {
        let mut current = self.root_bin.id;
        for (depth, name) in path.iter().enumerate() {
            let existing = self.root_bin.bin(current).and_then(|b| {
                b.children.iter().find_map(|item| match item {
                    BinItem::Bin(c) if c.name.to_lowercase() == name.to_lowercase() => Some(c.id),
                    _ => None,
                })
            });
            if let Some(id) = existing {
                current = id;
                continue;
            }
            if !create {
                return None;
            }
            if let Some(fixed) = new_ids.get(&bin_key(&path[..=depth])) {
                // The same id in every history state.
                let made = Bin::new(*fixed, name.clone(), Vec::new());
                find_bin_mut(&mut self.root_bin, current)?.children.push(BinItem::Bin(made));
                current = *fixed;
            } else {
                current = self.new_bin(name, Some(current), ids)?;
            }
        }
        Some(current)
    }

    fn add_synced(
        &mut self,
        items: &[(MediaRef, Vec<String>)],
        new_ids: &BTreeMap<String, Id>,
        ids: &mut dyn IdSource,
    ) -> usize {
        let mut known: std::collections::BTreeSet<String> = self.media.iter().map(|m| m.path.clone()).collect();
        let mut added = 0;
        for (item, bin) in items {
            if !known.insert(item.path.clone()) {
                continue;
            }
            self.add(item.clone());
            if !bin.is_empty()
                && let Some(dest) = self.bin_id(bin, true, new_ids, ids)
            {
                self.move_items(&[BinItemRef::Media(item.id)], dest, None);
            }
            added += 1;
        }
        added
    }
}

// MARK: Watching the project folder

/// Top-level folders of the project folder that hold our own output (exports, proxies, caches), not footage.
const SKIPPED_TOP_LEVEL: [&str; 5] = ["exports", "proxies", "proxy", "cache", "caches"];

/// A top-level folder the watcher never reads (Swift `skippedTopLevelFolders`).
pub fn skipped_top_level(name: &str) -> bool {
    SKIPPED_TOP_LEVEL.contains(&name.to_lowercase().as_str())
}

/// A hidden item or one of our project packages: never footage (Linux and Windows have no package bit).
pub fn is_hidden_or_package(name: &str) -> bool {
    let lower = name.to_lowercase();
    lower.starts_with('.') || lower.ends_with(".sqproj") || lower.ends_with(".ssproj")
}

fn path_key(path: &str) -> String {
    path.to_lowercase()
}

/// New files in the project folder: `files` (absolute paths found by a scan) that the project does not know yet. Skips
/// hidden items, project packages, `Exports/` and the other output folders, and the files the user removed from the bin
/// (`ignored_relative`). The bin path mirrors the folder below the project folder; files directly in the project folder
/// land in the root bin. Sorted by path.
// Swift: MediaPolicy.swift:167 (`folderSyncPlan`)
pub fn folder_sync_plan(
    files: &[String],
    project_folder: &Path,
    known: &BTreeSet<String>,
    ignored_relative: &[String],
) -> Vec<FolderSyncAdd> {
    let skip: BTreeSet<String> = known.iter().map(|p| path_key(p)).collect();
    let ignored: BTreeSet<String> = ignored_relative.iter().map(|r| r.to_lowercase()).collect();
    let mut out = Vec::new();
    for file in files {
        let Ok(rel) = Path::new(file).strip_prefix(project_folder) else { continue };
        let parts: Vec<String> = rel
            .components()
            .filter_map(|c| if let Component::Normal(n) = c { Some(n.to_string_lossy().into_owned()) } else { None })
            .collect();
        let Some((_, dirs)) = parts.split_last() else { continue };
        let own_output = dirs.first().is_some_and(|d| skipped_top_level(d));
        if own_output || parts.iter().any(|p| is_hidden_or_package(p)) {
            continue;
        }
        if skip.contains(&path_key(file)) || ignored.contains(&parts.join("/").to_lowercase()) {
            continue;
        }
        out.push(FolderSyncAdd { path: file.clone(), bin: dirs.to_vec() });
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

/// A file seen by a scan: where it is, how big and when it was last written.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeenFile {
    /// The file.
    pub path: String,
    /// Bytes.
    pub size: u64,
    /// Last write.
    pub modified: SystemTime,
}

/// The files that are not being written: unchanged for `quiet` and the same size and date as at the previous scan
/// (`previous`). The flag says some file was held back, so another scan is due soon.
// Swift: MediaPolicy.swift:198 (`settled`)
pub fn settled(
    seen: &[SeenFile],
    previous: &BTreeMap<String, SeenFile>,
    now: SystemTime,
    quiet: Duration,
) -> (Vec<String>, bool) {
    let (mut stable, mut unsettled) = (Vec::new(), false);
    for f in seen {
        let idle = now.duration_since(f.modified).unwrap_or(Duration::ZERO);
        if idle < quiet || previous.get(&f.path) != Some(f) {
            unsettled = true;
        } else {
            stable.push(f.path.clone());
        }
    }
    (stable, unsettled)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MediaFingerprint;

    /// Ids that cannot meet the fixtures' (nor the root bin's).
    struct Counter(u128);

    impl IdSource for Counter {
        fn next_id(&mut self) -> Id {
            self.0 += 1;
            Id::from_u128(self.0)
        }
    }

    fn media(n: u128, path: &str) -> MediaRef {
        MediaRef::new(Id::from_u128(0xBBBB_0000 + n), path, path, MediaFingerprint::new(10))
    }

    fn names(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|p| p.to_string()).collect()
    }

    fn project() -> Project {
        Project::new(Id::from_u128(1), "Film", Vec::new(), Vec::new())
    }

    #[test]
    fn relative_path_is_below_the_folder_ignoring_case() {
        assert_eq!(relative_path("/p/Film/Footage/A.mov", "/p/film"), Some("Footage/A.mov".to_string()));
        assert_eq!(relative_path("/p/Film", "/p/Film"), None);
        assert_eq!(relative_path("/q/a.mov", "/p/Film"), None);
    }

    #[test]
    fn ignored_files_stay_out_of_the_sync_until_imported_again() {
        let folder = "/tmp/sqmp-x/Film";
        let mut p = project();
        p.ignore_folder_file("/tmp/sqmp-x/Film/Footage/A.mov", folder);
        assert_eq!(p.media_policy.as_ref().and_then(|m| m.ignored.clone()), Some(vec!["Footage/A.mov".to_string()]));
        p.ignore_folder_file("/tmp/sqmp-x/Film/footage/a.mov", folder); // same file, other case
        assert_eq!(p.media_policy.as_ref().and_then(|m| m.ignored.as_ref().map(Vec::len)), Some(1));
        p.unignore_folder_file("/tmp/sqmp-x/Film/Footage/a.mov", folder);
        assert_eq!(p.media_policy, None);
    }

    #[test]
    fn synced_bins_keep_their_ids_in_every_history_state() {
        let items = vec![
            (media(1, "/p/Day 1/a.mov"), names(&["Day 1"])),
            (media(2, "/p/Day 1/A-cam/b.mov"), names(&["Day 1", "A-cam"])),
        ];
        let fixed = new_bin_ids(&items, &mut Counter(0xCCCC_0000));
        let (mut one, mut two) = (project(), project());
        one.add_synced(&items, &fixed, &mut Counter(0xCCCC_0000));
        two.add_synced(&items, &fixed, &mut Counter(0xCCCC_0000));
        let path = names(&["Day 1", "A-cam"]);
        let (a, b) = (
            one.bin_id(&path, false, &BTreeMap::new(), &mut Counter(0xCCCC_0000)),
            two.bin_id(&path, false, &BTreeMap::new(), &mut Counter(0xCCCC_0000)),
        );
        assert!(a.is_some() && a == b);
    }

    #[test]
    fn synced_items_land_in_mirrored_bins_without_duplicates() {
        let mut p = project();
        let mut ids = Counter(0xCCCC_0000);
        let (a, b, c) =
            (media(1, "/p/Film/Day 1/A/a.mov"), media(2, "/p/Film/b.wav"), media(3, "/p/Film/Day 1/A/c.mov"));
        let items = vec![(a.clone(), names(&["Day 1", "A"])), (b.clone(), vec![]), (c.clone(), names(&["day 1", "A"]))];
        assert_eq!(p.add_synced(&items, &BTreeMap::new(), &mut ids), 3);
        let bins: Vec<&Bin> =
            p.root_bin.children.iter().filter_map(|i| if let BinItem::Bin(x) = i { Some(x) } else { None }).collect();
        assert!(bins.len() == 1 && bins[0].name == "Day 1"); // case-insensitive reuse, one folder
        assert!(p.root_bin.children.contains(&BinItem::Media(b.id)));
        let a2 = p.bin_id(&names(&["Day 1", "A"]), false, &BTreeMap::new(), &mut ids).unwrap();
        let in_a: Vec<Id> = p
            .root_bin
            .bin(a2)
            .unwrap()
            .children
            .iter()
            .filter_map(|i| if let BinItem::Media(m) = i { Some(*m) } else { None })
            .collect();
        assert_eq!(in_a, [a.id, c.id]);
        let again = vec![(media(9, &a.path), names(&["Day 1", "A"]))];
        assert_eq!(p.add_synced(&again, &BTreeMap::new(), &mut ids), 0); // same path again: skipped
        assert_eq!(p.bin_id(&names(&["Nope"]), false, &BTreeMap::new(), &mut ids), None);
    }

    fn seen(path: &str, size: u64, at: u64) -> SeenFile {
        SeenFile { path: path.to_string(), size, modified: SystemTime::UNIX_EPOCH + Duration::from_secs(at) }
    }

    #[test]
    fn the_plan_mirrors_folders_and_skips_noise_exports_known_and_ignored() {
        let files: Vec<String> = [
            "/p/Film/b.wav",
            "/p/Film/Day 1/A/a.mov",
            "/p/Film/Exports/out.mov",
            "/p/Film/.hidden/x.mov",
            "/p/Film/Day 1/.x.mov",
            "/p/Film/Cut.sqproj/media.mov",
            "/p/Film/known.mov",
            "/p/Film/Gone.mov",
            "/p/Other/z.mov",
        ]
        .iter()
        .map(|s| (*s).to_string())
        .collect();
        let known = BTreeSet::from(["/p/film/KNOWN.mov".to_string()]);
        let plan = folder_sync_plan(&files, Path::new("/p/Film"), &known, &["gone.MOV".to_string()]);
        let got: Vec<(&str, Vec<String>)> = plan.iter().map(|a| (a.path.as_str(), a.bin.clone())).collect();
        assert_eq!(got, vec![("/p/Film/Day 1/A/a.mov", names(&["Day 1", "A"])), ("/p/Film/b.wav", vec![])]);
    }

    #[test]
    fn a_file_settles_when_untouched_and_unchanged_since_the_last_scan() {
        let f = seen("/p/a.mov", 10, 100);
        let quiet = Duration::from_secs(2);
        let at = |s: u64| SystemTime::UNIX_EPOCH + Duration::from_secs(s);
        let first = BTreeMap::new();
        assert_eq!(settled(std::slice::from_ref(&f), &first, at(200), quiet), (vec![], true)); // first sight
        let prev = BTreeMap::from([(f.path.clone(), f.clone())]);
        assert_eq!(settled(std::slice::from_ref(&f), &prev, at(101), quiet), (vec![], true)); // written a second ago
        assert_eq!(settled(std::slice::from_ref(&f), &prev, at(200), quiet), (vec![f.path.clone()], false));
        let grown = seen("/p/a.mov", 20, 100);
        assert_eq!(settled(&[grown], &prev, at(200), quiet), (vec![], true)); // still growing
    }
}

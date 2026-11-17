// Swift: LibraryGrouping.swift
//! Sections of a library folder: "All" plus one per subfolder.

use crate::library_search::numeric_compare;
use crate::watched_folder::LibraryEntry;
use std::cmp::Ordering;
use std::collections::HashMap;

/// One section of a Library folder: "All" (every item, recursive) or one subfolder (its own items; nested subfolders
/// are further groups with a greater depth).
#[derive(Clone, Debug, PartialEq)]
pub struct LibraryGroup {
    /// "*" for All, else the subfolder path relative to the library folder.
    pub id: String,
    /// Shown name.
    pub title: String,
    /// Nesting level (All is 0).
    pub depth: usize,
    /// Id of the enclosing group.
    pub parent_id: Option<String>,
    /// Items directly in this folder (All: every item). Empty while collapsed in `visible`.
    pub entries: Vec<LibraryEntry>,
    /// Items in this folder and below (shown as the count in the header).
    pub total_count: usize,
    /// Set by `visible` for a collapsed group.
    pub is_collapsed: bool,
}

impl LibraryGroup {
    /// Id of the All group.
    pub const ALL_ID: &'static str = "*";

    /// This is the All group.
    pub fn is_all(&self) -> bool {
        self.id == Self::ALL_ID
    }
}

fn path_order(a: &str, b: &str) -> Ordering {
    let (ca, cb): (Vec<&str>, Vec<&str>) = (a.split('/').collect(), b.split('/').collect());
    for (x, y) in ca.iter().zip(&cb) {
        if x != y {
            return match numeric_compare(&x.to_lowercase(), &y.to_lowercase()) {
                Ordering::Equal => x.cmp(y),
                o => o,
            };
        }
    }
    ca.len().cmp(&cb.len())
}

/// Sections for one folder's entries (already filtered and sorted; order is kept). Empty when no entry sits in a
/// subfolder: the panel then shows a plain flat list.
pub fn groups(entries: &[LibraryEntry]) -> Vec<LibraryGroup> {
    let mut direct: HashMap<String, Vec<LibraryEntry>> = HashMap::new();
    let mut total: HashMap<String, usize> = HashMap::new();
    let mut any_sub = false;
    for entry in entries {
        let parts: Vec<&str> = entry.relative_path.split('/').filter(|p| !p.is_empty()).collect();
        let Some((_, dirs)) = parts.split_last() else { continue };
        if dirs.is_empty() {
            continue;
        }
        any_sub = true;
        let mut path = String::new();
        for (i, p) in dirs.iter().enumerate() {
            if i == 0 {
                path = (*p).to_string();
            } else {
                path = format!("{path}/{p}");
            }
            *total.entry(path.clone()).or_insert(0) += 1;
        }
        direct.entry(path).or_default().push(entry.clone());
    }
    if !any_sub {
        return vec![];
    }
    let mut paths: Vec<&String> = total.keys().collect();
    paths.sort_by(|a, b| path_order(a, b));
    let mut out = vec![LibraryGroup {
        id: LibraryGroup::ALL_ID.to_string(),
        title: "All".to_string(),
        depth: 0,
        parent_id: None,
        entries: entries.to_vec(),
        total_count: entries.len(),
        is_collapsed: false,
    }];
    for p in paths {
        let comps: Vec<&str> = p.split('/').collect();
        out.push(LibraryGroup {
            id: p.clone(),
            title: (*comps.last().unwrap_or(&"")).to_string(),
            depth: comps.len() - 1,
            parent_id: (comps.len() > 1).then(|| comps[..comps.len() - 1].join("/")),
            entries: direct.get(p).cloned().unwrap_or_default(),
            total_count: total.get(p).copied().unwrap_or(0),
            is_collapsed: false,
        });
    }
    out
}

/// Applies collapsed state: a collapsed group keeps its header but shows no items; its descendants disappear.
pub fn visible(groups: &[LibraryGroup], collapsed: &[&str]) -> Vec<LibraryGroup> {
    let mut result: Vec<LibraryGroup> = Vec::new();
    for g in groups {
        if g.parent_id.as_deref().is_some_and(|p| !is_shown(p, &result)) {
            continue;
        }
        let mut g = g.clone();
        if collapsed.contains(&g.id.as_str()) {
            g.is_collapsed = true;
            g.entries = vec![];
        }
        result.push(g);
    }
    result
}

/// A child is shown when every ancestor header is present and not collapsed.
fn is_shown(parent: &str, result: &[LibraryGroup]) -> bool {
    result.iter().rev().find(|g| g.id == parent).is_some_and(|g| !g.is_collapsed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library_item_kind::LibraryItemKind;
    use crate::watched_folder::DISTANT_PAST;
    use sq_core_time::Id;

    fn e(p: &str) -> LibraryEntry {
        LibraryEntry {
            folder_id: Id::fixed(1),
            relative_path: p.into(),
            kind: LibraryItemKind::Audio,
            size: 1,
            modified: DISTANT_PAST,
        }
    }

    fn ids(g: &[LibraryGroup]) -> Vec<&str> {
        g.iter().map(|x| x.id.as_str()).collect()
    }

    #[test]
    fn flat_folder_has_no_groups() {
        assert!(groups(&[e("a.wav"), e("b.wav")]).is_empty());
        assert!(groups(&[]).is_empty());
    }

    #[test]
    fn all_section_then_categories() {
        let g = groups(&[e("root.wav"), e("Calm/a.wav"), e("Calm/b.wav"), e("Epic/c.wav")]);
        assert_eq!(g.iter().map(|x| x.title.as_str()).collect::<Vec<_>>(), ["All", "Calm", "Epic"]);
        assert!(g[0].entries.len() == 4 && g[0].total_count == 4 && g[0].is_all());
        assert_eq!(g[1].entries.iter().map(LibraryEntry::name).collect::<Vec<_>>(), ["a.wav", "b.wav"]);
        assert_eq!(g[1].total_count, 2);
        assert_eq!(g.iter().map(|x| x.depth).collect::<Vec<_>>(), [0, 0, 0]);
    }

    #[test]
    fn nested_folders_count_recursively_and_keep_own_items() {
        let g = groups(&[e("Calm/a.wav"), e("Calm/Piano/p.wav"), e("Calm/Piano/Slow/s.wav"), e("Epic/c.wav")]);
        assert_eq!(ids(&g), ["*", "Calm", "Calm/Piano", "Calm/Piano/Slow", "Epic"]);
        assert_eq!(g.iter().map(|x| x.depth).collect::<Vec<_>>(), [0, 0, 1, 2, 0]);
        assert!(g[1].entries.len() == 1 && g[1].total_count == 3);
        assert!(g[2].entries.len() == 1 && g[2].total_count == 2);
        assert_eq!(g[3].parent_id.as_deref(), Some("Calm/Piano"));
        assert_eq!(g[1].parent_id, None);
    }

    #[test]
    fn directory_with_only_subfolders_still_gets_header() {
        let g = groups(&[e("Cat/Sub/x.wav")]);
        assert_eq!(ids(&g), ["*", "Cat", "Cat/Sub"]);
        assert!(g[1].entries.is_empty() && g[1].total_count == 1);
    }

    #[test]
    fn collapsed_hides_descendants() {
        let g = groups(&[e("A/x.wav"), e("A/B/y.wav"), e("C/z.wav")]);
        let vis = visible(&g, &["A"]);
        assert_eq!(ids(&vis), ["*", "A", "C"]);
        assert!(vis.iter().find(|x| x.id == "A").is_some_and(|x| x.is_collapsed));
        let all_collapsed = visible(&g, &["*"]);
        assert_eq!(ids(&all_collapsed), ["*", "A", "A/B", "C"]);
        assert!(all_collapsed[0].is_collapsed && all_collapsed[0].entries.is_empty());
    }

    #[test]
    fn many_files_group_correctly() {
        let entries: Vec<LibraryEntry> =
            (0..5000).map(|i| e(&format!("cat{}/sub{}/f{i}.wav", i % 40, i % 7))).collect();
        let g = groups(&entries);
        assert_eq!(g[0].entries.len(), 5000);
        let pairs: std::collections::HashSet<(i32, i32)> = (0..5000).map(|i| (i % 40, i % 7)).collect();
        assert_eq!(g.len(), 1 + 40 + pairs.len());
    }
}

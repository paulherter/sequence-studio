// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Bin.swift (saved types, moved down; queries and Project bin edits: task M-4)

use crate::project::trim_spaces;
use crate::{Project, UnknownKeys};
use serde::{Deserialize, Serialize};
use sq_core_time::text::standard_compare;
use sq_core_time::{Id, IdSource};
use std::cmp::Ordering;
use std::collections::BTreeSet;

/// The payload of a Swift enum case with one unlabeled value: `{"case": {"_0": value}}`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub(crate) struct Underscore0<T> {
    #[serde(rename = "_0")]
    pub(crate) value: T,
}

/// A reference to something that lives in a bin: a nested bin, a media item or a sequence.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "BinItemWire", into = "BinItemWire")]
pub enum BinItem {
    /// A nested bin.
    Bin(Bin),
    /// A media item (`MediaRef` id).
    Media(Id),
    /// A sequence (`Timeline` id).
    Sequence(Id),
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum BinItemWire {
    Bin(Underscore0<Bin>),
    Media(Underscore0<Id>),
    Sequence(Underscore0<Id>),
}

impl From<BinItemWire> for BinItem {
    fn from(w: BinItemWire) -> Self {
        match w {
            BinItemWire::Bin(b) => BinItem::Bin(b.value),
            BinItemWire::Media(id) => BinItem::Media(id.value),
            BinItemWire::Sequence(id) => BinItem::Sequence(id.value),
        }
    }
}

impl From<BinItem> for BinItemWire {
    fn from(i: BinItem) -> Self {
        match i {
            BinItem::Bin(b) => BinItemWire::Bin(Underscore0 { value: b }),
            BinItem::Media(id) => BinItemWire::Media(Underscore0 { value: id }),
            BinItem::Sequence(id) => BinItemWire::Sequence(Underscore0 { value: id }),
        }
    }
}

/// Identity of a bin item without payload, used to address items in move operations.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(from = "BinItemRefWire", into = "BinItemRefWire")]
pub enum BinItemRef {
    /// A nested bin.
    Bin(Id),
    /// A media item.
    Media(Id),
    /// A sequence.
    Sequence(Id),
}

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum BinItemRefWire {
    Bin(Underscore0<Id>),
    Media(Underscore0<Id>),
    Sequence(Underscore0<Id>),
}

impl From<BinItemRefWire> for BinItemRef {
    fn from(w: BinItemRefWire) -> Self {
        match w {
            BinItemRefWire::Bin(i) => BinItemRef::Bin(i.value),
            BinItemRefWire::Media(i) => BinItemRef::Media(i.value),
            BinItemRefWire::Sequence(i) => BinItemRef::Sequence(i.value),
        }
    }
}

impl From<BinItemRef> for BinItemRefWire {
    fn from(r: BinItemRef) -> Self {
        match r {
            BinItemRef::Bin(id) => BinItemRefWire::Bin(Underscore0 { value: id }),
            BinItemRef::Media(id) => BinItemRefWire::Media(Underscore0 { value: id }),
            BinItemRef::Sequence(id) => BinItemRefWire::Sequence(Underscore0 { value: id }),
        }
    }
}

/// A folder of the project panel. Children keep their stored order (user order).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Bin {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Contents in user order.
    pub children: Vec<BinItem>,
    /// Keys of a newer file that this build does not know; kept and written back.
    #[serde(flatten, default, skip_serializing_if = "UnknownKeys::is_empty")]
    pub unknown: UnknownKeys,
}

impl BinItem {
    /// Identity without payload, used to address items in move operations.
    pub fn item_ref(&self) -> BinItemRef {
        match self {
            BinItem::Bin(b) => BinItemRef::Bin(b.id),
            BinItem::Media(id) => BinItemRef::Media(*id),
            BinItem::Sequence(id) => BinItemRef::Sequence(*id),
        }
    }
}

impl Bin {
    /// A bin with the given children.
    pub fn new(id: Id, name: impl Into<String>, children: Vec<BinItem>) -> Bin {
        Bin { id, name: name.into(), children, unknown: UnknownKeys::default() }
    }

    /// The bin with `id` anywhere in this subtree (including self).
    pub fn bin(&self, id: Id) -> Option<&Bin> {
        if self.id == id {
            return Some(self);
        }
        self.children.iter().find_map(|c| match c {
            BinItem::Bin(b) => b.bin(id),
            _ => None,
        })
    }

    /// All items in this subtree, depth first (not including self).
    pub fn all_refs(&self) -> Vec<BinItemRef> {
        let mut out = Vec::new();
        for item in &self.children {
            out.push(item.item_ref());
            if let BinItem::Bin(b) = item {
                out.extend(b.all_refs());
            }
        }
        out
    }

    /// Whether `item` is in this subtree.
    pub fn contains(&self, item: BinItemRef) -> bool {
        self.all_refs().contains(&item)
    }

    /// ID of the bin directly containing `item`, or `None` if it is not in this subtree.
    pub fn parent_of(&self, item: BinItemRef) -> Option<Id> {
        if self.children.iter().any(|c| c.item_ref() == item) {
            return Some(self.id);
        }
        self.children.iter().find_map(|c| match c {
            BinItem::Bin(b) => b.parent_of(item),
            _ => None,
        })
    }

    /// Media IDs in this subtree, depth first.
    pub fn media_ids(&self) -> Vec<Id> {
        self.all_refs()
            .into_iter()
            .filter_map(|r| match r {
                BinItemRef::Media(id) => Some(id),
                _ => None,
            })
            .collect()
    }

    /// The bin with `id` anywhere in this subtree (including self), for editing.
    #[doc(hidden)]
    pub fn bin_mut(&mut self, id: Id) -> Option<&mut Bin> {
        if self.id == id {
            return Some(self);
        }
        self.children.iter_mut().find_map(|c| match c {
            BinItem::Bin(b) => b.bin_mut(id),
            _ => None,
        })
    }

    /// Removes the first occurrence of `item` in this subtree and returns it.
    fn extract(&mut self, item: BinItemRef) -> Option<BinItem> {
        if let Some(i) = self.children.iter().position(|c| c.item_ref() == item) {
            return Some(self.children.remove(i));
        }
        self.children.iter_mut().find_map(|c| match c {
            BinItem::Bin(b) => b.extract(item),
            _ => None,
        })
    }

    /// Drops media and sequence references that fail `keep`, everywhere in the subtree.
    pub fn prune(&mut self, keep: &impl Fn(BinItemRef) -> bool) {
        self.children.retain_mut(|item| match item {
            BinItem::Bin(b) => {
                b.prune(keep);
                true
            }
            other => keep(other.item_ref()),
        });
    }
}

/// How `Project::sort_bin` orders the children of a bin.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BinSortKey {
    /// By display name, Finder-style.
    Name,
    /// Bins first, then sequences, then media.
    Kind,
}

/// Bins first, then sequences, then media.
fn kind_rank(r: BinItemRef) -> i32 {
    match r {
        BinItemRef::Bin(_) => 0,
        BinItemRef::Sequence(_) => 1,
        BinItemRef::Media(_) => 2,
    }
}

impl Project {
    /// The bin with `id` anywhere in the project panel tree.
    pub fn bin(&self, id: Id) -> Option<&Bin> {
        self.root_bin.bin(id)
    }

    /// Name of a bin item (empty for an unknown one).
    pub fn display_name(&self, item: BinItemRef) -> String {
        match item {
            BinItemRef::Bin(id) => self.root_bin.bin(id).map(|b| b.name.clone()),
            BinItemRef::Media(id) => self.media(id).map(|m| m.name.clone()),
            BinItemRef::Sequence(id) => self.timeline(id).map(|t| t.name.clone()),
        }
        .unwrap_or_default()
    }

    /// Makes the bin tree consistent with `media` and `timelines`: unknown references are dropped,
    /// duplicates removed (first wins), items not in any bin are appended to the root bin.
    pub fn normalize_bins(&mut self) {
        let media_ids: BTreeSet<Id> = self.media.iter().map(|m| m.id).collect();
        let seq_ids: BTreeSet<Id> = self.timelines.iter().map(|t| t.id).collect();
        self.root_bin.prune(&|r| match r {
            BinItemRef::Media(id) => media_ids.contains(&id),
            BinItemRef::Sequence(id) => seq_ids.contains(&id),
            BinItemRef::Bin(_) => true,
        });
        fn dedupe(b: &mut Bin, seen: &mut BTreeSet<BinItemRef>) {
            b.children.retain_mut(|item| {
                if !seen.insert(item.item_ref()) {
                    return false;
                }
                if let BinItem::Bin(sub) = item {
                    dedupe(sub, seen);
                }
                true
            });
        }
        dedupe(&mut self.root_bin, &mut BTreeSet::new());
        let filed: BTreeSet<BinItemRef> = self.root_bin.all_refs().into_iter().collect();
        for m in &self.media {
            if !filed.contains(&BinItemRef::Media(m.id)) {
                self.root_bin.children.push(BinItem::Media(m.id));
            }
        }
        // The inside of an applied title template is not a sequence of its own (TitleTemplate.swift): not filed.
        let insides = self.title_template_insides();
        for t in &self.timelines {
            if t.group.is_none() && !filed.contains(&BinItemRef::Sequence(t.id)) && !insides.contains(&t.id) {
                self.root_bin.children.push(BinItem::Sequence(t.id));
            }
        }
    }

    /// Inner sequences of applied title template clips. They are not filed in bins (`normalize_bins`).
    pub fn title_template_insides(&self) -> BTreeSet<Id> {
        let clips = self.timelines.iter().flat_map(|t| &t.tracks).flat_map(|tr| tr.clips());
        clips.filter(|c| c.template_slots.is_some()).filter_map(|c| c.sequence).collect()
    }

    /// Creates an empty bin inside `parent` (default: root) and returns its ID; `None` if `parent` does not exist.
    /// The new id comes from `ids`.
    pub fn new_bin(&mut self, name: &str, parent: Option<Id>, ids: &mut dyn IdSource) -> Option<Id> {
        let new = Bin::new(ids.next_id(), name, Vec::new());
        let new_id = new.id;
        let target = parent.unwrap_or(self.root_bin.id);
        self.root_bin.bin_mut(target)?.children.push(BinItem::Bin(new));
        Some(new_id)
    }

    /// Renames a bin; false for an unknown bin or an empty name.
    pub fn rename_bin(&mut self, id: Id, name: &str) -> bool {
        if trim_spaces(name, false).is_empty() {
            return false;
        }
        match self.root_bin.bin_mut(id) {
            Some(b) => {
                b.name = name.to_string();
                true
            }
            None => false,
        }
    }

    /// Moves `items` into bin `dest`, preserving their given order. `index` is the insertion position among
    /// `dest`'s children after the moved items were removed (`None` = append). Refused (returns false, nothing
    /// changes) if `dest` is unknown, an item is unknown or the root bin, or a bin would land in itself or a descendant.
    pub fn move_items(&mut self, items: &[BinItemRef], dest: Id, index: Option<i64>) -> bool {
        if self.root_bin.bin(dest).is_none() {
            return false;
        }
        let mut unique: Vec<BinItemRef> = Vec::new();
        for r in items {
            if !unique.contains(r) {
                unique.push(*r);
            }
        }
        for r in &unique {
            if !self.root_bin.contains(*r) {
                return false;
            }
            if let BinItemRef::Bin(id) = r
                && self.root_bin.bin(*id).is_some_and(|moving| moving.bin(dest).is_some())
            {
                return false;
            }
        }
        let mut copy = self.root_bin.clone();
        let extracted: Vec<BinItem> = unique.iter().filter_map(|r| copy.extract(*r)).collect();
        if let Some(d) = copy.bin_mut(dest) {
            let count = d.children.len() as i64;
            let at = index.unwrap_or(count).clamp(0, count) as usize;
            d.children.splice(at..at, extracted);
        }
        self.root_bin = copy;
        true
    }

    /// Deletes a bin; its children move into the parent at the bin's position. The root bin cannot be deleted.
    pub fn delete_bin(&mut self, id: Id) -> bool {
        if id == self.root_bin.id {
            return false;
        }
        let Some(parent_id) = self.root_bin.parent_of(BinItemRef::Bin(id)) else { return false };
        let Some(parent) = self.root_bin.bin_mut(parent_id) else { return false };
        if let Some(i) = parent.children.iter().position(|c| c.item_ref() == BinItemRef::Bin(id))
            && let BinItem::Bin(doomed) = parent.children[i].clone()
        {
            parent.children.splice(i..=i, doomed.children);
        }
        true
    }

    /// Sorts the direct children of a bin. Stable: equal keys keep their current relative order.
    pub fn sort_bin(&mut self, id: Id, by: BinSortKey, ascending: bool) -> bool {
        let Some(current) = self.root_bin.bin(id).map(|b| b.children.clone()) else { return false };
        let names: Vec<String> = current.iter().map(|c| self.display_name(c.item_ref())).collect();
        let ranks: Vec<i32> = current.iter().map(|c| kind_rank(c.item_ref())).collect();
        let mut order: Vec<usize> = (0..current.len()).collect();
        order.sort_by(|&l, &r| {
            let cmp = match by {
                BinSortKey::Name => standard_compare(&names[l], &names[r]),
                BinSortKey::Kind => ranks[l].cmp(&ranks[r]),
            };
            match cmp {
                Ordering::Equal => l.cmp(&r),
                c if ascending => c,
                c => c.reverse(),
            }
        });
        if let Some(b) = self.root_bin.bin_mut(id) {
            b.children = order.into_iter().map(|i| current[i].clone()).collect();
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn bin_tree_round_trips_in_the_swift_enum_shape() {
        assert_round_trip::<Bin>(json!({
            "id": "00000000-0000-0000-0000-000000000001", "name": "Root", "children": [
                {"sequence": {"_0": "00000000-0000-0000-0000-000000000002"}},
                {"media": {"_0": "00000000-0000-0000-0000-000000000003"}},
                {"bin": {"_0": {"id": "00000000-0000-0000-0000-000000000004", "name": "B", "children": []}}}]}));
    }

    #[test]
    fn bin_item_ref_round_trips() {
        assert_round_trip::<BinItemRef>(json!({"media": {"_0": "00000000-0000-0000-0000-000000000003"}}));
        assert_round_trip::<BinItemRef>(json!({"bin": {"_0": "00000000-0000-0000-0000-000000000003"}}));
    }

    use crate::nesting::test_util::*;
    use crate::{MediaFingerprint, MediaRef};

    fn media(n: u32, name: &str) -> MediaRef {
        let mut m = MediaRef::new(id(n), name, &format!("/x/{name}"), MediaFingerprint::new(1));
        m.duration = Some(sq_core_time::Time::new(10, 1));
        m
    }

    /// Media b.mov, a.mov, c.mov (ids 1..3) and the sequence "Seq" (id 10), all in the root bin.
    fn project() -> Project {
        let mut p = project_json(vec![], vec![timeline_json(10, vec![])]);
        for (n, name) in [(1, "b.mov"), (2, "a.mov"), (3, "c.mov")] {
            p.add(media(n, name));
        }
        p
    }

    fn m(n: u32) -> BinItemRef {
        BinItemRef::Media(id(n))
    }

    /// Ids for new bins start at 500 so they never meet the fixed test ids.
    fn ids() -> TestIds {
        TestIds(500)
    }

    #[test]
    fn new_project_files_everything_in_root() {
        let p = project();
        assert_eq!(p.root_bin.children.len(), 4);
        assert_eq!(p.root_bin.media_ids(), [id(1), id(2), id(3)]);
        assert!(p.root_bin.contains(BinItemRef::Sequence(id(10))));
    }

    #[test]
    fn add_media_twice_keeps_one_entry() {
        let mut p = project();
        p.add(media(1, "b.mov"));
        assert_eq!(p.root_bin.all_refs().len(), 4);
    }

    #[test]
    fn new_bin_and_rename() {
        let (mut p, mut ids) = (project(), ids());
        let b = p.new_bin("Day 1", None, &mut ids).unwrap_or(Id::NIL);
        let inner = p.new_bin("Inner", Some(b), &mut ids).unwrap_or(Id::NIL);
        assert_eq!(p.bin(inner).map(|x| x.name.as_str()), Some("Inner"));
        assert_eq!(p.root_bin.parent_of(BinItemRef::Bin(inner)), Some(b));
        assert!(p.rename_bin(b, "Day 2"));
        assert_eq!(p.bin(b).map(|x| x.name.as_str()), Some("Day 2"));
        assert!(!p.rename_bin(b, "  "));
        assert!(!p.rename_bin(id(77), "x"));
        assert_eq!(p.new_bin("Folder", Some(id(77)), &mut ids), None);
    }

    #[test]
    fn move_items_between_bins() {
        let (mut p, mut ids) = (project(), ids());
        let b = p.new_bin("Folder", None, &mut ids).unwrap_or(Id::NIL);
        assert!(p.move_items(&[m(1), m(3)], b, None));
        assert_eq!(p.bin(b).map(Bin::media_ids), Some(vec![id(1), id(3)]));
        assert_eq!(p.root_bin.parent_of(m(1)), Some(b));
        assert_eq!(p.root_bin.all_refs().len(), 5);
        // reorder inside the destination, index counts after removal
        assert!(p.move_items(&[m(3)], b, Some(0)));
        assert_eq!(p.bin(b).map(Bin::media_ids), Some(vec![id(3), id(1)]));
        assert!(p.move_items(&[m(3)], b, Some(99)));
        assert_eq!(p.bin(b).map(Bin::media_ids), Some(vec![id(1), id(3)]));
        assert!(p.move_items(&[m(3)], b, Some(-4)));
        assert_eq!(p.bin(b).map(Bin::media_ids), Some(vec![id(3), id(1)]));
        // duplicates in the request move once
        assert!(p.move_items(&[m(2), m(2)], b, None));
        assert_eq!(p.bin(b).map(Bin::media_ids), Some(vec![id(3), id(1), id(2)]));
    }

    #[test]
    fn move_refuses_unknown_things_and_changes_nothing() {
        let (mut p, mut ids) = (project(), ids());
        let b = p.new_bin("Folder", None, &mut ids).unwrap_or(Id::NIL);
        let before = p.clone();
        assert!(!p.move_items(&[m(1), m(77)], b, None));
        assert!(!p.move_items(&[m(1)], id(78), None));
        assert_eq!(p, before);
    }

    #[test]
    fn move_cannot_create_cycles() {
        let (mut p, mut ids) = (project(), ids());
        let a = p.new_bin("A", None, &mut ids).unwrap_or(Id::NIL);
        let b = p.new_bin("B", Some(a), &mut ids).unwrap_or(Id::NIL);
        let c = p.new_bin("C", Some(b), &mut ids).unwrap_or(Id::NIL);
        let before = p.clone();
        let root = p.root_bin.id;
        assert!(!p.move_items(&[BinItemRef::Bin(a)], a, None));
        assert!(!p.move_items(&[BinItemRef::Bin(a)], c, None));
        assert!(!p.move_items(&[BinItemRef::Bin(b)], c, None));
        assert!(!p.move_items(&[BinItemRef::Bin(root)], a, None));
        assert_eq!(p, before);
        assert!(p.move_items(&[BinItemRef::Bin(c)], a, None));
        assert_eq!(p.root_bin.parent_of(BinItemRef::Bin(c)), Some(a));
    }

    #[test]
    fn delete_bin_moves_children_to_the_parent_in_place() {
        let (mut p, mut ids) = (project(), ids());
        let a = p.new_bin("A", None, &mut ids).unwrap_or(Id::NIL);
        let b = p.new_bin("B", Some(a), &mut ids).unwrap_or(Id::NIL);
        assert!(p.move_items(&[m(1)], a, None));
        assert!(p.move_items(&[m(2)], b, None));
        let i = p.root_bin.children.iter().position(|c| c.item_ref() == BinItemRef::Bin(a)).unwrap_or(usize::MAX);
        assert!(p.delete_bin(a));
        assert!(p.bin(a).is_none());
        assert_eq!(p.root_bin.children[i].item_ref(), BinItemRef::Bin(b));
        assert_eq!(p.root_bin.children[i + 1].item_ref(), m(1));
        assert_eq!(p.bin(b).map(Bin::media_ids), Some(vec![id(2)]));
        let mut all = p.root_bin.media_ids();
        all.sort();
        assert_eq!(all, [id(1), id(2), id(3)]);
        let root = p.root_bin.id;
        assert!(!p.delete_bin(root));
        assert!(!p.delete_bin(id(77)));
    }

    #[test]
    fn sort_by_name_is_stable_and_reversible() {
        let (mut p, mut ids) = (project(), ids());
        let bin = p.new_bin("x", None, &mut ids).unwrap_or(Id::NIL);
        p.add(media(4, "a.mov"));
        p.add(media(5, "a.mov"));
        assert!(p.move_items(&[m(5), m(4), m(1)], bin, None)); // b, then the two "a.mov"
        p.sort_bin(bin, BinSortKey::Name, true);
        assert_eq!(p.bin(bin).map(Bin::media_ids), Some(vec![id(5), id(4), id(1)]), "equal names keep order");
        p.sort_bin(bin, BinSortKey::Name, false);
        assert_eq!(p.bin(bin).map(Bin::media_ids), Some(vec![id(1), id(5), id(4)]));
        assert!(!p.sort_bin(id(77), BinSortKey::Name, true));
    }

    #[test]
    fn sort_by_name_is_numeric_aware() {
        let (mut p, mut ids) = (project(), ids());
        p.add(media(4, "clip10.mov"));
        p.add(media(5, "clip2.mov"));
        let root = p.root_bin.id;
        let bin = p.new_bin("x", None, &mut ids).unwrap_or(Id::NIL);
        assert!(p.move_items(&[m(4), m(5)], bin, None));
        p.sort_bin(bin, BinSortKey::Name, true);
        assert_eq!(p.bin(bin).map(Bin::media_ids), Some(vec![id(5), id(4)]));
        assert!(p.root_bin.id == root);
    }

    #[test]
    fn sort_by_kind_puts_bins_then_sequences_then_media() {
        let (mut p, mut ids) = (project(), ids());
        let b = p.new_bin("Z", None, &mut ids).unwrap_or(Id::NIL);
        let root = p.root_bin.id;
        p.sort_bin(root, BinSortKey::Kind, true);
        let refs: Vec<_> = p.root_bin.children.iter().map(BinItem::item_ref).collect();
        assert_eq!(refs, [BinItemRef::Bin(b), BinItemRef::Sequence(id(10)), m(1), m(2), m(3)]);
    }

    #[test]
    fn normalize_drops_stale_and_duplicates_and_files_orphans() {
        let mut p = project();
        p.root_bin.children.push(BinItem::Media(id(77)));
        p.root_bin.children.push(BinItem::Media(id(1)));
        p.root_bin.children.retain(|c| c.item_ref() != m(3));
        p.normalize_bins();
        assert_eq!(p.root_bin.all_refs().len(), 4);
        assert_eq!(p.root_bin.children.last().map(BinItem::item_ref), Some(m(3)));
    }

    #[test]
    fn normalize_keeps_title_template_insides_and_group_members_out_of_the_bin() {
        let inside = timeline_json(11, vec![]);
        let mut host_clip = clip_json(900, 11, "video", 0, Some(11));
        host_clip["templateSlots"] = json!([]);
        let host = timeline_json(10, vec![track_json(50, "video", vec![host_clip])]);
        let p = project_json(vec![], vec![host, inside]);
        assert_eq!(p.title_template_insides().into_iter().collect::<Vec<_>>(), [id(11)]);
        assert_eq!(p.root_bin.all_refs(), [BinItemRef::Sequence(id(10))]);
    }
}

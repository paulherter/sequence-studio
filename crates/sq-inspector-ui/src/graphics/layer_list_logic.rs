// Swift: LayerListLogic.swift (SQTimelineUI)
//! Pure layer list logic of the Graphics panel: rows from the document, drop targets and shift-range selection.

use std::collections::BTreeSet;

use sq_core_graphics::graphics_editing::GraphicsDocumentEditingExt;
use sq_core_model::{GraphicsContent, GraphicsDocument, GraphicsLayer, LabelColor, ShapeKind};
use sq_core_time::{Id, Time};
use sq_uikit::sqicon::SQIcon;

use crate::graphics::editor::LayerDrop;

/// What a row stands for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RowKind {
    Group(Id),
    Layer(Id),
}

/// One row of the Graphics layer list (front first): a group header or a layer.
#[derive(Clone, Debug, PartialEq)]
pub struct LayerListRow {
    pub kind: RowKind,
    pub name: String,
    /// Icon of the layer kind (groups: none, they draw the disclosure chevron).
    pub symbol: Option<SQIcon>,
    /// Group of a layer row (indented under its header); a group row's own id.
    pub group: Option<Id>,
    /// Group rows: every member visible / locked. Layer rows: the layer's flags.
    pub is_visible: bool,
    pub is_locked: bool,
    /// Group rows: open (members shown).
    pub is_open: bool,
    /// Color label: a layer's own; a group row's when every member has the same one.
    pub label: Option<LabelColor>,
}

impl LayerListRow {
    pub fn layer_id(&self) -> Option<Id> {
        match self.kind {
            RowKind::Layer(id) => Some(id),
            RowKind::Group(_) => None,
        }
    }

    pub fn group_id(&self) -> Option<Id> {
        match self.kind {
            RowKind::Group(id) => Some(id),
            RowKind::Layer(_) => None,
        }
    }

    pub fn is_indented(&self) -> bool {
        self.layer_id().is_some() && self.group.is_some()
    }
}

/// What a drag in the layer list carries: selected layers, or one group (its header was dragged).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LayerDrag {
    Layers(Vec<Id>),
    Group(Id),
}

pub enum LayerListLogic {}

impl LayerListLogic {
    /// Rows front first. A group header stands where its front-most member is; its members follow, indented, unless the
    /// group is collapsed.
    pub fn rows(d: &GraphicsDocument, collapsed: &BTreeSet<Id>) -> Vec<LayerListRow> {
        let mut out = Vec::new();
        let mut seen = BTreeSet::new();
        for l in d.layers.iter().rev() {
            let group = l.group.and_then(|g| d.group(g).map(|x| (g, x)));
            if let Some((g, group)) = group {
                if seen.insert(g) {
                    let members: Vec<&GraphicsLayer> = d.layers.iter().filter(|m| m.group == Some(g)).collect();
                    let same_label = members.iter().all(|m| m.label == members[0].label);
                    out.push(LayerListRow {
                        kind: RowKind::Group(g),
                        name: group.name.clone(),
                        symbol: None,
                        group: Some(g),
                        is_visible: members.iter().all(|m| m.is_visible),
                        is_locked: members.iter().all(|m| m.is_locked),
                        is_open: !collapsed.contains(&g),
                        label: if same_label { members[0].label } else { None },
                    });
                }
                if collapsed.contains(&g) {
                    continue;
                }
                out.push(Self::row(l, Some(g)));
            } else {
                out.push(Self::row(l, None));
            }
        }
        out
    }

    fn row(l: &GraphicsLayer, group: Option<Id>) -> LayerListRow {
        LayerListRow {
            kind: RowKind::Layer(l.id),
            name: l.name.clone(),
            symbol: Some(Self::symbol(l)),
            group,
            is_visible: l.is_visible,
            is_locked: l.is_locked,
            is_open: false,
            label: l.label,
        }
    }

    /// Clip-local times of every key of the layer (Motion, Opacity and every effect parameter), sorted, without duplicates.
    pub fn key_times(l: &GraphicsLayer) -> Vec<Time> {
        let a = &l.animation;
        let mut t: Vec<Time> = Vec::new();
        t.extend(a.position.track.keys.iter().map(|k| k.time));
        t.extend(a.anchor.track.keys.iter().map(|k| k.time));
        t.extend(a.scale.track.keys.iter().map(|k| k.time));
        t.extend(a.rotation.track.keys.iter().map(|k| k.time));
        t.extend(a.opacity.track.keys.iter().map(|k| k.time));
        for e in &l.effects {
            t.extend(e.key_times());
        }
        t.sort();
        t.dedup();
        t
    }

    /// The kind of a layer as the list names it next to the name: Text, Shape or Path.
    pub fn kind_label(l: &GraphicsLayer) -> &'static str {
        match l.content {
            GraphicsContent::Text { .. } => "Text",
            GraphicsContent::Shape { .. } => "Shape",
            GraphicsContent::Path { .. } => "Path",
        }
    }

    /// A ranged item is outside its range at the clip-local playhead: its row is dimmed (it draws nothing there).
    /// Never with the playhead outside the clip (`local` None), and never for an item that shows over the whole clip.
    pub fn is_outside_range(l: &GraphicsLayer, local: Option<Time>) -> bool {
        match local {
            Some(t) if l.range.is_some() => !l.is_shown(t),
            _ => false,
        }
    }

    pub fn symbol(l: &GraphicsLayer) -> SQIcon {
        match &l.content {
            GraphicsContent::Shape { kind: ShapeKind::Rectangle } => SQIcon::ShapeRectangle,
            GraphicsContent::Shape { kind: ShapeKind::Ellipse } => SQIcon::ShapeEllipse,
            GraphicsContent::Shape { kind: ShapeKind::Line } => SQIcon::ShapeLine,
            GraphicsContent::Shape { kind: ShapeKind::Arrow } => SQIcon::ArrowUpRight,
            GraphicsContent::Path { .. } => SQIcon::Draw,
            GraphicsContent::Text { .. } => SQIcon::Text,
        }
    }

    /// The layers a drag moves.
    pub fn ids(drag: &LayerDrag, d: &GraphicsDocument) -> Vec<Id> {
        match drag {
            LayerDrag::Layers(ids) => {
                let s: BTreeSet<Id> = ids.iter().copied().collect();
                d.layers.iter().map(|l| l.id).filter(|id| s.contains(id)).collect()
            }
            LayerDrag::Group(g) => d.layers.iter().filter(|l| l.group == Some(*g)).map(|l| l.id).collect(),
        }
    }

    /// Drop of `drag` into the gap before `rows[gap]` (`rows.len()` = after the last row), or onto the group row `onto`
    /// (layers join that group at its top). A layer dropped between two members of a group joins it, anywhere else it
    /// leaves its group; a dragged group never lands inside another one (it goes above it). `None` when nothing changes
    /// (`for_copy`: never, a copy always adds layers).
    pub fn drop(
        drag: &LayerDrag,
        rows: &[LayerListRow],
        d: &GraphicsDocument,
        gap: i64,
        onto: Option<usize>,
        for_copy: bool,
    ) -> Option<LayerDrop> {
        let ids = Self::ids(drag, d);
        if ids.is_empty() {
            return None;
        }
        let moving: BTreeSet<Id> = ids.iter().copied().collect();
        let rest: Vec<&GraphicsLayer> = d.layers.iter().filter(|l| !moving.contains(&l.id)).collect();
        let is_dragged = |r: &LayerListRow| match r.layer_id() {
            Some(id) => moving.contains(&id),
            None => matches!(drag, LayerDrag::Group(g) if r.group_id() == Some(*g)),
        };
        // Index in `rest` right above the front-most member of `g`.
        let above_group = |g: Id| rest.iter().rposition(|l| l.group == Some(g)).map_or(rest.len(), |i| i + 1) as i64;

        let (mut to_index, mut group): (i64, Option<Id>);
        if let Some(g) = onto.and_then(|o| rows.get(o)).and_then(LayerListRow::group_id) {
            to_index = above_group(g); // the top of the group, right above its front-most remaining member
            group = Some(g); // a dragged group goes above it instead (below)
        } else {
            let g = gap.clamp(0, rows.len() as i64) as usize;
            match rows[g..].iter().find(|r| !is_dragged(r)) {
                None => {
                    to_index = 0;
                    group = None;
                }
                Some(r) => {
                    if let Some(gid) = r.group_id() {
                        to_index = above_group(gid);
                        group = None;
                    } else {
                        let i = r.layer_id().and_then(|id| rest.iter().position(|l| l.id == id))?;
                        to_index = i as i64 + 1;
                        group = r.group;
                    }
                }
            }
        }
        if let LayerDrag::Group(own) = drag {
            if let Some(inside) = group.filter(|g| g != own) {
                to_index = above_group(inside);
            }
            group = Some(*own);
        }
        let mut after = d.clone();
        after.move_to_index_in_group(&moving, to_index, group);
        if !for_copy && after == *d {
            return None;
        }
        Some(LayerDrop { ids, to_index, group })
    }

    /// Click selection on `rows[index]`: plain = only it, `toggle` (Cmd) = add / remove it, `range` (Shift) = every row
    /// from `anchor` to it. A group row stands for all its members.
    pub fn select(
        rows: &[LayerListRow],
        d: &GraphicsDocument,
        current: &BTreeSet<Id>,
        index: usize,
        anchor: Option<usize>,
        toggle: bool,
        range: bool,
    ) -> BTreeSet<Id> {
        if index >= rows.len() {
            return current.clone();
        }
        let members = |r: &LayerListRow| -> BTreeSet<Id> {
            if let Some(id) = r.layer_id() {
                return BTreeSet::from([id]);
            }
            r.group_id()
                .map(|g| d.layers.iter().filter(|l| l.group == Some(g)).map(|l| l.id).collect())
                .unwrap_or_default()
        };
        let hit = members(&rows[index]);
        if let Some(anchor) = anchor.filter(|a| range && *a < rows.len()) {
            let (lo, hi) = (anchor.min(index), anchor.max(index));
            return rows[lo..=hi].iter().flat_map(members).collect();
        }
        if toggle {
            return if hit.is_subset(current) {
                current.difference(&hit).copied().collect()
            } else {
                current.union(&hit).copied().collect()
            };
        }
        hit
    }

    /// A row shows selected: a layer in the selection, a group whose members all are.
    pub fn is_selected(r: &LayerListRow, d: &GraphicsDocument, selection: &BTreeSet<Id>) -> bool {
        if let Some(id) = r.layer_id() {
            return selection.contains(&id);
        }
        let Some(g) = r.group_id() else { return false };
        let m: Vec<Id> = d.layers.iter().filter(|l| l.group == Some(g)).map(|l| l.id).collect();
        !m.is_empty() && m.iter().all(|id| selection.contains(id))
    }
}

#[cfg(test)]
mod tests {
    use sq_core_model::GraphicsGroup;

    use super::*;

    #[test]
    fn the_list_names_the_kind_of_each_layer() {
        assert_eq!(LayerListLogic::kind_label(&layer(1, None)), "Shape");
        let path = GraphicsLayer::new(Id::fixed(2), "p", GraphicsContent::Path { points: Vec::new(), closed: true });
        assert_eq!(LayerListLogic::kind_label(&path), "Path");
    }

    fn layer(n: u64, group: Option<Id>) -> GraphicsLayer {
        let mut l =
            GraphicsLayer::new(Id::fixed(n), &format!("L{n}"), GraphicsContent::Shape { kind: ShapeKind::Rectangle });
        l.group = group;
        l
    }

    /// Bottom to top: L1, L2 (both in group G), L3.
    fn doc() -> GraphicsDocument {
        let g = Id::fixed(100);
        GraphicsDocument {
            layers: vec![layer(1, Some(g)), layer(2, Some(g)), layer(3, None)],
            groups: vec![GraphicsGroup::new(g, "G")],
        }
    }

    fn names(rows: &[LayerListRow]) -> Vec<&str> {
        rows.iter().map(|r| r.name.as_str()).collect()
    }

    #[test]
    fn rows_are_front_first_with_the_group_header_at_its_front_member() {
        let d = doc();
        let rows = LayerListLogic::rows(&d, &BTreeSet::new());
        assert_eq!(names(&rows), ["L3", "G", "L2", "L1"]);
        assert!(rows[2].is_indented() && !rows[0].is_indented());
        let collapsed = LayerListLogic::rows(&d, &BTreeSet::from([Id::fixed(100)]));
        assert_eq!(names(&collapsed), ["L3", "G"]);
        assert!(!collapsed[1].is_open);
    }

    #[test]
    fn plain_toggle_and_range_selection() {
        let d = doc();
        let rows = LayerListLogic::rows(&d, &BTreeSet::new());
        let none = BTreeSet::new();
        let one = LayerListLogic::select(&rows, &d, &none, 2, None, false, false);
        assert_eq!(one, BTreeSet::from([Id::fixed(2)]));
        let both = LayerListLogic::select(&rows, &d, &one, 3, None, true, false);
        assert_eq!(both, BTreeSet::from([Id::fixed(1), Id::fixed(2)]));
        let off = LayerListLogic::select(&rows, &d, &both, 3, None, true, false);
        assert_eq!(off, BTreeSet::from([Id::fixed(2)]));
        let group = LayerListLogic::select(&rows, &d, &none, 1, None, false, false);
        assert_eq!(group, BTreeSet::from([Id::fixed(1), Id::fixed(2)]));
        let range = LayerListLogic::select(&rows, &d, &none, 3, Some(0), false, true);
        assert_eq!(range.len(), 3);
        assert!(LayerListLogic::is_selected(&rows[1], &d, &group));
        assert!(!LayerListLogic::is_selected(&rows[1], &d, &one));
    }

    #[test]
    fn dropping_in_place_changes_nothing_but_a_copy_always_lands() {
        let d = doc();
        let rows = LayerListLogic::rows(&d, &BTreeSet::new());
        let drag = LayerDrag::Layers(vec![Id::fixed(3)]);
        assert_eq!(LayerListLogic::drop(&drag, &rows, &d, 0, None, false), None);
        assert!(LayerListLogic::drop(&drag, &rows, &d, 0, None, true).is_some());
    }

    #[test]
    fn a_layer_dropped_between_group_members_joins_the_group_and_below_all_it_leaves() {
        let d = doc();
        let rows = LayerListLogic::rows(&d, &BTreeSet::new());
        let drag = LayerDrag::Layers(vec![Id::fixed(3)]);
        let into = LayerListLogic::drop(&drag, &rows, &d, 3, None, false);
        assert_eq!(into.as_ref().map(|x| x.group), Some(Some(Id::fixed(100))));
        let onto = LayerListLogic::drop(&drag, &rows, &d, 0, Some(1), false);
        assert_eq!(onto.as_ref().map(|x| (x.to_index, x.group)), Some((2, Some(Id::fixed(100)))));
        let leave = LayerListLogic::drop(&LayerDrag::Layers(vec![Id::fixed(2)]), &rows, &d, 0, None, false);
        assert_eq!(leave.map(|x| (x.to_index, x.group)), Some((2, None)));
    }

    #[test]
    fn a_dragged_group_keeps_its_own_group_and_the_ids_follow_document_order() {
        let d = doc();
        let rows = LayerListLogic::rows(&d, &BTreeSet::new());
        let drop = LayerListLogic::drop(&LayerDrag::Group(Id::fixed(100)), &rows, &d, 0, None, false);
        assert_eq!(drop.map(|x| (x.ids, x.group)), Some((vec![Id::fixed(1), Id::fixed(2)], Some(Id::fixed(100)))));
        assert_eq!(
            LayerListLogic::ids(&LayerDrag::Layers(vec![Id::fixed(3), Id::fixed(1)]), &d),
            vec![Id::fixed(1), Id::fixed(3)]
        );
    }

    #[test]
    fn outside_range_needs_a_range_and_a_playhead() {
        let mut l = layer(1, None);
        assert!(!LayerListLogic::is_outside_range(&l, Some(Time::new(5, 1))));
        l.range = Some(sq_core_time::TimeRange::new(Time::new(1, 1), Time::new(2, 1)));
        assert!(!LayerListLogic::is_outside_range(&l, None));
        assert!(LayerListLogic::is_outside_range(&l, Some(Time::new(9, 1))));
        assert!(!LayerListLogic::is_outside_range(&l, Some(Time::new(2, 1))));
        assert!(LayerListLogic::key_times(&l).is_empty());
    }
}

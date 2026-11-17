use sq_uikit::keyframe_graph_geometry::{Point, Rect};
use sq_uikit::panel_id::PanelID;

use crate::es10_workspace::layout::tabs;
use crate::es10_workspace::{
    DropZone, LayoutNode, SplitAxis, TabReorder, Workspace, WorkspaceLibrary, WorkspaceLoadError,
};

fn group_node(w: &Workspace, p: PanelID) -> Option<LayoutNode> {
    fn find(n: &LayoutNode, p: PanelID) -> Option<LayoutNode> {
        match n {
            LayoutNode::Tabs { panels, .. } => panels.contains(&p).then(|| n.clone()),
            LayoutNode::Split { children, .. } => children.iter().find_map(|c| find(c, p)),
        }
    }
    find(&w.root, p)
}

fn group(w: &Workspace, p: PanelID) -> Option<Vec<PanelID>> {
    match group_node(w, p) {
        Some(LayoutNode::Tabs { panels, .. }) => Some(panels),
        _ => None,
    }
}

fn check_valid(w: &Workspace) {
    assert_eq!(w.validation_problems(), Vec::<String>::new());
    let all = w.all_panels();
    assert_eq!(
        all.iter().copied().collect::<std::collections::HashSet<_>>(),
        PanelID::dockable().into_iter().collect()
    );
    assert_eq!(all.len(), PanelID::dockable().len());
}

const R: Rect = Rect { x: 100.0, y: 50.0, width: 400.0, height: 200.0 };

fn zone(x: f64, y: f64) -> Option<DropZone> {
    DropZone::zone(Point::new(x, y), R)
}

#[test]
fn zones() {
    assert_eq!(zone(300.0, 150.0), Some(DropZone::Center));
    assert_eq!(zone(110.0, 150.0), Some(DropZone::Left));
    assert_eq!(zone(490.0, 150.0), Some(DropZone::Right));
    assert_eq!(zone(300.0, 55.0), Some(DropZone::Top));
    assert_eq!(zone(300.0, 245.0), Some(DropZone::Bottom));
    assert_eq!(zone(99.0, 150.0), None);
    assert_eq!(zone(300.0, 251.0), None);
    assert_eq!(DropZone::zone(Point::new(300.0, 150.0), Rect::new(0.0, 0.0, 0.0, 10.0)), None);
    assert_eq!(zone(105.0, 80.0), Some(DropZone::Left)); // u=.0125, v=.15
    assert_eq!(zone(150.0, 52.0), Some(DropZone::Top)); // u=.125, v=.01
    assert_eq!(zone(200.0, 100.0), Some(DropZone::Center)); // boundary belongs to center
    assert_eq!(Workspace::drop_zone(Point::new(300.0, 150.0), R), Some(DropZone::Center));
}

#[test]
fn center_appends_and_selects() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    assert!(w.dock(Timeline, Library, DropZone::Center));
    assert_eq!(group(&w, Library), Some(vec![Library, Effects, Timeline]));
    let Some(LayoutNode::Tabs { selected, .. }) = group_node(&w, Library) else { panic!("group") };
    assert_eq!(selected, Timeline);
    check_valid(&w);
}

#[test]
fn center_within_same_group_moves_to_end() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    assert!(w.dock(EffectControls, Text, DropZone::Center));
    assert_eq!(group(&w, Text), Some(vec![Text, Graphics, ColorInspector, EffectControls]));
    check_valid(&w);
}

#[test]
fn edge_splits() {
    use PanelID::*;
    for zone in [DropZone::Left, DropZone::Right, DropZone::Top, DropZone::Bottom] {
        let mut w = Workspace::editing_pc();
        assert!(w.dock(Project, Timeline, zone));
        assert_eq!(group(&w, Project), Some(vec![Project]));
        assert_eq!(group(&w, Effects), Some(vec![Library, Effects]));
        check_valid(&w);
    }
}

/// The timeline sits beside the audio meter: left column of the PC layout is [upper, [timeline | meter]].
fn timeline_row(w: &Workspace) -> (Vec<f64>, Vec<LayoutNode>, Vec<f64>) {
    let LayoutNode::Split { children: c, .. } = &w.root else { panic!("shape") };
    let LayoutNode::Split { axis: SplitAxis::Vertical, children: left, fractions: f } = &c[0] else { panic!("shape") };
    let LayoutNode::Split { axis: SplitAxis::Horizontal, children: row, fractions: rf } = &left[1] else {
        panic!("shape")
    };
    (f.clone(), row.clone(), rf.clone())
}

#[test]
fn edge_split_below_the_timeline_leaves_the_meter_full_height() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    assert!(w.dock(Library, Timeline, DropZone::Bottom));
    let (f, row, _) = timeline_row(&w);
    let LayoutNode::Split { axis: SplitAxis::Vertical, children: stack, fractions: sf } = &row[1] else {
        panic!("shape")
    };
    assert_eq!(f, [0.5133, 0.4867]);
    assert_eq!(*stack, vec![tabs(&[Timeline], Timeline), tabs(&[Library], Library)]);
    assert_eq!(*sf, [0.5, 0.5]);
    assert_eq!(row[0], tabs(&[Tools], Tools));
    assert_eq!(row[2], tabs(&[AudioMeter], AudioMeter));
    check_valid(&w);
}

#[test]
fn edge_split_above_the_timeline_inserts_first() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    assert!(w.dock(Library, Timeline, DropZone::Top));
    let (_, row, _) = timeline_row(&w);
    let LayoutNode::Split { axis: SplitAxis::Vertical, children: stack, .. } = &row[1] else { panic!("shape") };
    assert_eq!(*stack, vec![tabs(&[Library], Library), tabs(&[Timeline], Timeline)]);
}

#[test]
fn edge_split_left_of_the_timeline_shares_the_row_with_the_meter() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    assert!(w.dock(Library, Timeline, DropZone::Left));
    let (_, row, rf) = timeline_row(&w);
    assert_eq!(
        row,
        vec![
            tabs(&[Tools], Tools),
            tabs(&[Library], Library),
            tabs(&[Timeline], Timeline),
            tabs(&[AudioMeter], AudioMeter)
        ]
    );
    assert!((rf.iter().sum::<f64>() - 1.0).abs() < 1e-9);
    check_valid(&w);
}

#[test]
fn split_own_group_with_sibling_tab() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    assert!(w.dock(SourceMonitor, ProgramMonitor, DropZone::Right));
    assert_eq!(group(&w, ProgramMonitor), Some(vec![ProgramMonitor]));
    assert_eq!(group(&w, SourceMonitor), Some(vec![SourceMonitor]));
    check_valid(&w);
}

#[test]
fn drag_last_tab_out_collapses_group() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    assert!(w.dock(Library, ProgramMonitor, DropZone::Center));
    let LayoutNode::Split { axis: SplitAxis::Horizontal, children: c, fractions: f } = &w.root else { panic!("root") };
    // right column (Library | Effects over Project): Library leaves, Effects stays with its group
    let LayoutNode::Split { axis: SplitAxis::Vertical, children: right, .. } = &c[1] else { panic!("right") };
    assert_eq!(right[0], tabs(&[Effects], Effects));
    assert_eq!(*f, [0.762, 0.238]);
    check_valid(&w);
}

#[test]
fn selected_tab_after_removal() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    assert!(w.dock(EffectControls, Timeline, DropZone::Center));
    assert_eq!(group_node(&w, Text), Some(tabs(&[Text, Graphics, ColorInspector], Text)));
}

#[test]
fn same_axis_flatten() {
    use crate::es10_workspace::layout::horizontal;
    use PanelID::*;
    let w0 = Workspace::new(
        "t",
        horizontal(
            vec![
                tabs(&[Library], Library),
                horizontal(vec![tabs(&[Effects], Effects), tabs(&[Project], Project)], &[0.5, 0.5]),
            ],
            &[0.5, 0.5],
        ),
    );
    let mut w = w0.clone();
    assert!(w.dock(Library, Effects, DropZone::Center));
    let LayoutNode::Split { axis: SplitAxis::Horizontal, children: c, fractions: f } = &w.root else { panic!("root") };
    assert!(c.len() == 2 && *f == [0.5, 0.5]);
    assert!(w.validation_problems().is_empty());

    let mut w2 = w0;
    assert!(w2.dock(Library, Project, DropZone::Right));
    let LayoutNode::Split { axis: SplitAxis::Horizontal, children: c2, fractions: f2 } = &w2.root else {
        panic!("root")
    };
    assert_eq!(c2.len(), 3);
    assert!((f2[0] - 0.5).abs() < 1e-9 && (f2[1] - 0.25).abs() < 1e-9 && (f2[2] - 0.25).abs() < 1e-9);
    assert!(w2.validation_problems().is_empty());
}

#[test]
fn dock_shows_hidden_and_clears_maximize() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    w.hide(Library);
    w.toggle_maximize(Timeline);
    assert!(w.dock(Library, Timeline, DropZone::Center));
    assert!(w.is_visible(Library));
    assert_eq!(w.maximized, None);
}

#[test]
fn rejects_bad_input() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    let before = w.clone();
    assert!(!w.dock(Library, Library, DropZone::Center));
    assert_eq!(w, before);
    let mut small = Workspace::new("s", tabs(&[Timeline], Timeline));
    assert!(!small.dock(Library, Timeline, DropZone::Center));
    assert!(!small.move_tab(Library, 0));
}

#[test]
fn move_tab() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    assert!(w.move_tab(ColorInspector, 0));
    assert_eq!(group(&w, Text), Some(vec![ColorInspector, EffectControls, Text, Graphics]));
    assert!(w.move_tab(ColorInspector, 99));
    assert_eq!(group(&w, Text), Some(vec![EffectControls, Text, Graphics, ColorInspector]));
    assert!(w.move_tab(Text, -5));
    assert_eq!(group(&w, Text), Some(vec![Text, EffectControls, Graphics, ColorInspector]));
    let Some(LayoutNode::Tabs { selected, .. }) = group_node(&w, Text) else { panic!("group") };
    assert_eq!(selected, EffectControls);
    check_valid(&w);
}

struct SplitMix(u64);

impl SplitMix {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

#[test]
fn random_drops_keep_invariants() {
    let mut rng = SplitMix(42);
    let all = PanelID::dockable();
    for start in Workspace::built_ins() {
        let mut w = start;
        for _ in 0..300 {
            let p = all[(rng.next() % all.len() as u64) as usize];
            let t = all[(rng.next() % all.len() as u64) as usize];
            let z = DropZone::ALL[(rng.next() % 5) as usize];
            w.dock(p, t, z);
            if rng.next().is_multiple_of(4) {
                w.move_tab(p, (rng.next() % 4) as i64);
            }
            let same =
                w.all_panels().into_iter().collect::<std::collections::HashSet<_>>() == all.iter().copied().collect();
            assert!(
                w.validation_problems().is_empty() && same && w.all_panels().len() == all.len(),
                "invariant broken after {p:?} -> {t:?} {z:?}"
            );
        }
    }
}

#[test]
fn library_basics() {
    let built_in_names: Vec<String> = Workspace::built_ins().into_iter().map(|w| w.name).collect();
    let mut lib = WorkspaceLibrary::default();
    assert_eq!(lib.names(), built_in_names);
    let mut w = Workspace::editing_pc();
    w.dock(PanelID::Library, PanelID::Timeline, DropZone::Center);
    assert!(lib.save_as("  Color  ", &w));
    assert_eq!(lib.names().last().map(String::as_str), Some("Color"));
    assert_eq!(lib.workspace_named("color").map(|x| x.root), Some(w.root.clone()));
    assert!(!lib.save_as("", &w));
    assert!(!lib.save_as("editing \u{2013} pc", &w));
    assert!(lib.save_as("Color", &Workspace::editing_mac_book())); // overwrite
    assert_eq!(lib.user_workspaces().len(), 1);
    assert!(lib.rename("Color", "Audio"));
    assert!(lib.workspace_named("Color").is_none() && lib.workspace_named("Audio").is_some());
    assert!(lib.save_as("Other", &w));
    assert!(!lib.rename("Audio", "other"));
    assert!(!lib.rename("Editing \u{2013} PC", "X"));
    assert!(!lib.rename("Audio", "Editing \u{2013} MacBook"));
    assert!(!lib.delete("Editing \u{2013} PC"));
    assert!(lib.delete("Audio"));
    assert!(!lib.delete("Audio"));
    let mut expected = built_in_names;
    expected.push("Other".to_string());
    assert_eq!(lib.names(), expected);
}

#[test]
fn built_in_override_and_reset() {
    use PanelID::*;
    let pc = "Editing \u{2013} PC";
    let mut lib = WorkspaceLibrary::default();
    let mut w = Workspace::editing_pc();
    w.hide(Effects);
    assert!(lib.update(&w));
    assert!(lib.is_modified_built_in(pc));
    assert_eq!(
        lib.workspace_named(pc).map(|x| x.hidden),
        Some([Effects, ColorInspector, Scopes].into_iter().collect())
    );
    assert_eq!(lib.names().len(), Workspace::built_ins().len());
    assert!(lib.reset_built_in(pc));
    assert_eq!(lib.workspace_named(pc), Some(Workspace::editing_pc()));
    assert!(!lib.reset_built_in(pc));
    assert!(!lib.update(&Workspace::new("nope", tabs(&[Timeline], Timeline))));
}

#[test]
fn json_round_trip_and_version() {
    let mut lib = WorkspaceLibrary::default();
    lib.save_as("Mine", &Workspace::editing_mac_book());
    let mut w = Workspace::editing_pc();
    w.hide(PanelID::Text);
    lib.update(&w);
    let data = lib.encoded().unwrap();
    assert_eq!(WorkspaceLibrary::decoded(&data).unwrap(), lib);
    let text = String::from_utf8(data).unwrap();
    assert!(text.contains("\"version\": 1"));
    let future = text.replace("\"version\": 1", "\"version\": 99");
    assert_eq!(WorkspaceLibrary::decoded(future.as_bytes()), Err(WorkspaceLoadError::UnsupportedVersion(99)));
    assert!(WorkspaceLibrary::decoded(b"{}").is_err());
}

#[test]
fn healed_renames_collisions_and_drops_unknown_overrides() {
    let one = |name: &str| Workspace::new(name, tabs(&[PanelID::Timeline], PanelID::Timeline));
    let mut lib = WorkspaceLibrary::new(vec![one("Editing \u{2013} PC"), one("Mine"), one("mine")], Default::default());
    lib.built_in_overrides.insert("Gone".to_string(), Workspace::editing_pc());
    let h = lib.healed();
    let names: Vec<&str> = h.user_workspaces().iter().map(|w| w.name.as_str()).collect();
    assert_eq!(names, ["Editing \u{2013} PC (saved)", "Mine", "mine (saved)"]);
    assert!(h.built_in_overrides().is_empty());
}

#[test]
fn tab_reorder_and_helpers() {
    use PanelID::*;
    let mids = [10.0, 30.0, 50.0];
    assert_eq!(TabReorder::final_index(0, 60.0, &mids), 2);
    assert_eq!(TabReorder::final_index(2, 0.0, &mids), 0);
    assert_eq!(TabReorder::final_index(1, 31.0, &mids), 1);
    assert_eq!(TabReorder::final_index(0, 5.0, &[]), 0);
    assert_eq!(Workspace::dock_anchor(&[Text, Library], Text, Library), Some(Text));
    assert_eq!(Workspace::dock_anchor(&[Text, Library], Text, Text), Some(Library));
    assert_eq!(Workspace::dock_anchor(&[Text], Text, Text), None);
    let hl = DropZone::highlight_rect(DropZone::Left, R);
    assert_eq!((hl.x, hl.width, hl.height), (100.0, 100.0, 200.0));
    let c = DropZone::highlight_rect(DropZone::Center, R);
    assert_eq!((c.x, c.y, c.width, c.height), (200.0, 100.0, 200.0, 100.0));
}

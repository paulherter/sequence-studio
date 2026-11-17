use sq_uikit::panel_id::PanelID;

use crate::es10_workspace::layout::{horizontal, tabs, vertical};
use crate::es10_workspace::{LayoutNode, SplitAxis, Workspace};

fn split_of(n: &LayoutNode, axis: SplitAxis) -> (&Vec<LayoutNode>, &Vec<f64>) {
    match n {
        LayoutNode::Split { axis: a, children, fractions } if *a == axis => (children, fractions),
        other => panic!("expected {axis:?} split, got {other:?}"),
    }
}

fn dockable_set() -> std::collections::HashSet<PanelID> {
    PanelID::dockable().into_iter().collect()
}

fn roundtrip(w: &Workspace) -> Workspace {
    serde_json::from_slice(&serde_json::to_vec(w).unwrap()).unwrap()
}

/// Encodes a workspace carrying the malformed tree, then decodes it the way a saved file would be read.
fn decode(root: LayoutNode) -> Workspace {
    roundtrip(&Workspace::new("Bad", root))
}

#[test]
fn reveal_shows_the_tab_without_selecting_it() {
    let mut w = Workspace::color_mac_book();
    w.hide(PanelID::Steps);
    w.select_tab(PanelID::ColorClips);
    w.reveal(PanelID::Steps);
    assert!(w.is_visible(PanelID::Steps));
    assert_eq!(w.selected_tab_in_group_of(PanelID::Steps), Some(PanelID::ColorClips));
}

#[test]
fn selected_tab_survives_pro_simple_pro_on_sources() {
    let mut w = Workspace::color_mac_book();
    w.select_tab(PanelID::ColorClips);
    w.reveal(PanelID::Steps); // Pro
    let mut simple = w.clone();
    simple.hide(PanelID::Steps); // Simple (what the shell lays out)
    assert!(simple.visible_root().is_some());
    w.reveal(PanelID::Steps); // Pro again
    assert_eq!(w.selected_tab_in_group_of(PanelID::Steps), Some(PanelID::ColorClips));
    assert!(w.shows_tab(PanelID::ColorClips) && !w.shows_tab(PanelID::Steps));
}

#[test]
fn pc_structure() {
    let w = Workspace::editing_pc();
    assert_eq!(w.name, "Editing \u{2013} PC");
    let (top, f) = split_of(&w.root, SplitAxis::Horizontal);
    assert!(top.len() == 2 && *f == [0.762, 0.238]);
    let (left, _) = split_of(&top[0], SplitAxis::Vertical);
    let (upper, _) = split_of(&left[0], SplitAxis::Horizontal);
    use PanelID::*;
    assert_eq!(upper[0], tabs(&[EffectControls, Text, Graphics, ColorInspector], EffectControls));
    assert_eq!(upper[1], tabs(&[ProgramMonitor, SourceMonitor], ProgramMonitor));
    assert_eq!(left[1], Workspace::timeline_with_meter()); // meter docked right of the timeline
    let (right, _) = split_of(&top[1], SplitAxis::Vertical);
    assert_eq!(right[0], tabs(&[Library, Effects], Library));
    assert_eq!(right[1], tabs(&[Project, MarkerList, Scopes], Project));
    assert_eq!(w.all_panels().into_iter().collect::<std::collections::HashSet<_>>(), dockable_set());
    assert!(w.is_visible(AudioMeter));
}

#[test]
fn saved_workspace_with_source_selected_opens_on_program() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    w.root = tabs(&[ProgramMonitor, SourceMonitor], SourceMonitor);
    assert_eq!(roundtrip(&w).root, tabs(&[ProgramMonitor, SourceMonitor], ProgramMonitor));
    // A group without Program keeps its selection.
    let only = tabs(&[SourceMonitor, Text], SourceMonitor);
    assert_eq!(only.program_preferred(), only);
}

#[test]
fn old_saved_layout_gets_the_meter_beside_the_timeline() {
    use PanelID::*;
    // A workspace saved before the meter existed: timeline group and a monitor group.
    let old = vertical(
        vec![tabs(&[ProgramMonitor, SourceMonitor], ProgramMonitor), tabs(&[Timeline], Timeline)],
        &[0.5, 0.5],
    );
    let back = decode(old);
    let (c, _) = split_of(&back.root, SplitAxis::Vertical);
    assert_eq!(c[1], Workspace::timeline_with_meter());
    // Decoding again (or a layout that already has the meter) changes nothing.
    assert_eq!(roundtrip(&back).root, back.root);
}

#[test]
fn old_saved_color_layout_gets_the_meter_hidden() {
    use PanelID::*;
    let old = vertical(vec![tabs(&[ProgramMonitor], ProgramMonitor), tabs(&[Timeline], Timeline)], &[0.5, 0.5]);
    let back = roundtrip(&Workspace::new(&Workspace::color().name, old));
    assert!(back.all_panels().contains(&AudioMeter) && back.hidden.contains(&AudioMeter));
    assert!(back.is_visible(Tools), "a layout saved without Tools gets it next to the timeline");
    let LayoutNode::Split { children, .. } = &back.root else { panic!("shape") };
    let LayoutNode::Split { children: row, .. } = &children[1] else { panic!("shape") };
    assert_eq!(row[0], tabs(&[Tools], Tools));
    assert!(!back.is_visible(AudioMeter));
}

#[test]
fn mac_book_structure() {
    use PanelID::*;
    let w = Workspace::editing_mac_book();
    let (c, _) = split_of(&w.root, SplitAxis::Horizontal);
    assert_eq!(c[1], tabs(&[ProgramMonitor, SourceMonitor], ProgramMonitor)); // full height, right
    let (left, _) = split_of(&c[0], SplitAxis::Vertical);
    let (upper, _) = split_of(&left[0], SplitAxis::Horizontal);
    let (lower, _) = split_of(&left[1], SplitAxis::Horizontal);
    assert_eq!(upper[0], tabs(&[Library, Effects, MarkerList, Scopes], Library));
    assert_eq!(upper[1], tabs(&[EffectControls, Text, Graphics, ColorInspector], EffectControls));
    assert_eq!(lower[0], tabs(&[Project], Project));
    assert_eq!(lower[1], Workspace::timeline_with_meter());
    assert_eq!(w.all_panels().into_iter().collect::<std::collections::HashSet<_>>(), dockable_set());
}

#[test]
fn fractions_sum_to_one() {
    fn check(n: &LayoutNode) {
        if let LayoutNode::Split { children, fractions, .. } = n {
            assert_eq!(children.len(), fractions.len());
            assert!((fractions.iter().sum::<f64>() - 1.0).abs() < 1e-9);
            children.iter().for_each(check);
        }
    }
    for w in Workspace::built_ins() {
        check(&w.root);
    }
}

#[test]
fn hide_show_round_trip() {
    let mut w = Workspace::editing_pc();
    let original = w.clone();
    w.hide(PanelID::Library);
    assert!(!w.is_visible(PanelID::Library));
    assert!(!w.visible_root().is_some_and(|r| r.panels().contains(&PanelID::Library)));
    w.hide(PanelID::Timeline);
    w.show(PanelID::Timeline);
    w.show(PanelID::Library);
    assert_eq!(w.visible_root(), original.visible_root());
    assert_eq!(w, original);
}

fn hide_right_column(w: &mut Workspace) {
    use PanelID::*;
    for p in [Library, Effects, MarkerList, Project, Scopes] {
        w.hide(p);
    }
}

#[test]
fn hiding_collapses_and_renormalises() {
    let mut w = Workspace::editing_pc();
    hide_right_column(&mut w); // whole right column gone
    assert!(!w.visible_root().unwrap().panels().contains(&PanelID::Project));
    assert!(
        matches!(w.visible_root(), Some(LayoutNode::Split { axis: SplitAxis::Vertical, .. })),
        "root should collapse to the left column"
    );
    let mut all = Workspace::editing_pc();
    for p in PanelID::dockable() {
        all.hide(p);
    }
    assert_eq!(all.visible_root(), None);
}

#[test]
fn hidden_tab_falls_back_and_show_selects() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    w.hide(EffectControls);
    let Some(LayoutNode::Split { children: c, .. }) = w.visible_root() else { panic!("shape") };
    let LayoutNode::Split { children: l, .. } = &c[0] else { panic!("shape") };
    let LayoutNode::Split { children: u, .. } = &l[0] else { panic!("shape") };
    assert_eq!(u[0], tabs(&[Text, Graphics], Text));
    w.show(EffectControls);
    w.select_tab(ColorInspector);
    assert_eq!(w.root.panels().len(), PanelID::dockable().len());
    let LayoutNode::Split { children: c, .. } = &w.root else { panic!("shape") };
    let LayoutNode::Split { children: l, .. } = &c[0] else { panic!("shape") };
    let LayoutNode::Split { children: u, .. } = &l[0] else { panic!("shape") };
    assert_eq!(u[0], tabs(&[EffectControls, Text, Graphics, ColorInspector], ColorInspector));
}

fn root_fractions(w: &Workspace) -> Vec<f64> {
    match &w.root {
        LayoutNode::Split { fractions, .. } => fractions.clone(),
        _ => panic!("split"),
    }
}

#[test]
fn set_fractions_normalises_and_clamps() {
    let mut w = Workspace::editing_pc();
    assert!(w.set_fractions(&[], &[3.0, 1.0]));
    assert_eq!(root_fractions(&w), [0.75, 0.25]);
    assert!(w.set_fractions(&[], &[1.0, 0.0]));
    let g = root_fractions(&w);
    assert!((g.iter().sum::<f64>() - 1.0).abs() < 1e-12);
    assert!(g[1] >= Workspace::MIN_FRACTION - 1e-12 && (g[1] - 0.05).abs() < 1e-12);
    assert!(!w.set_fractions(&[], &[1.0, 1.0, 1.0])); // wrong count
    assert!(!w.set_fractions(&[1, 0], &[1.0, 1.0])); // tabs, not a split
    assert!(w.set_fractions(&[0, 0], &[1.0, 1.0])); // nested
}

#[test]
fn normalized_edge_cases() {
    assert_eq!(Workspace::normalized(&[]), Vec::<f64>::new());
    assert_eq!(Workspace::normalized(&[0.0, 0.0]), [0.5, 0.5]);
    assert!(Workspace::normalized(&[f64::NAN, 1.0]).iter().sum::<f64>() > 0.999);
    let n = Workspace::normalized(&[10.0, 0.001, 0.001]);
    assert!((n.iter().sum::<f64>() - 1.0).abs() < 1e-12 && n.iter().copied().fold(f64::MAX, f64::min) >= 0.05 - 1e-12);
    assert!(Workspace::normalized(&[1.0; 30]).iter().all(|v| (v - 1.0 / 30.0).abs() < 1e-12));
}

#[test]
fn set_fractions_with_hidden_sibling_keeps_hidden_share() {
    let mut w = Workspace::editing_pc();
    hide_right_column(&mut w); // root collapses: path [] is the left vertical split
    assert!(w.set_fractions(&[], &[1.0, 1.0])); // passes through the collapsed root
    let LayoutNode::Split { children: c, fractions: f, .. } = &w.root else { panic!("root") };
    let LayoutNode::Split { fractions: inner, .. } = &c[0] else { panic!("inner") };
    assert_eq!(*f, [0.762, 0.238]); // hidden right column keeps its share
    assert_eq!(*inner, [0.5, 0.5]);
}

#[test]
fn maximize_restore() {
    use PanelID::*;
    let mut w = Workspace::editing_pc();
    let before = w.clone();
    w.toggle_maximize(ProgramMonitor);
    assert_eq!(w.visible_root(), Some(tabs(&[ProgramMonitor], ProgramMonitor)));
    w.toggle_maximize(ProgramMonitor);
    assert_eq!(w, before);
    w.toggle_maximize(Timeline);
    w.hide(Timeline);
    assert_eq!(w.maximized, None);
    w.hide(Library);
    w.toggle_maximize(Library);
    assert_eq!(w.maximized, None); // hidden panels cannot be maximized
}

#[test]
fn json_round_trip() {
    let mut w = Workspace::editing_mac_book();
    w.hide(PanelID::Project);
    w.toggle_maximize(PanelID::Timeline);
    assert_eq!(roundtrip(&w), w);
    for b in Workspace::built_ins() {
        assert_eq!(roundtrip(&b), b);
    }
}

#[test]
fn json_matches_the_swift_shape() {
    let w = Workspace::new("W", tabs(&[PanelID::Timeline], PanelID::Timeline));
    let v = serde_json::to_value(&w).unwrap();
    assert_eq!(v["root"]["tabs"]["panels"][0], "timeline");
    assert_eq!(v["root"]["tabs"]["selected"], "timeline");
    let split = serde_json::to_value(horizontal(vec![w.root.clone(), w.root], &[0.5, 0.5])).unwrap();
    assert_eq!(split["split"]["axis"], "horizontal");
}

// MARK: Decode validation

#[test]
fn decode_fixes_fraction_count_mismatch() {
    use PanelID::*;
    let bad = horizontal(
        vec![tabs(&[Library], Library), tabs(&[Timeline], Timeline), tabs(&[Project], Project)],
        &[0.5, 0.5],
    );
    let mut w = decode(bad);
    let LayoutNode::Split { children: c, fractions: f, .. } = &w.root else { panic!("root") };
    assert!(c.len() == 3 && f.len() == 3);
    assert!((f.iter().sum::<f64>() - 1.0).abs() < 1e-9);
    w.hide(Project);
    assert!(w.visible_root().is_some()); // prune does not trap
    assert!(w.set_fractions(&[], &[0.3, 0.7]));
}

#[test]
fn decode_fixes_fractions_not_summing_to_one() {
    use PanelID::*;
    let w = decode(vertical(vec![tabs(&[Library], Library), tabs(&[Timeline], Timeline)], &[3.0, 9.0]));
    assert_eq!(root_fractions(&w), [0.5, 0.5]);
}

#[test]
fn decode_removes_empty_groups_and_drops_their_fraction() {
    use PanelID::*;
    let bad = horizontal(
        vec![tabs(&[], Library), tabs(&[Timeline], Library), vertical(vec![], &[])], // selected not in panels
        &[0.2, 0.5, 0.3],
    );
    // Repaired to one group, then the meter is docked beside it.
    assert_eq!(decode(bad).root, Workspace::timeline_with_meter());
}

#[test]
fn decode_of_fully_empty_layout_falls_back_to_default() {
    assert_eq!(decode(tabs(&[], PanelID::Library)).root, Workspace::editing_pc().root);
}

#[test]
fn valid_layout_is_untouched_by_decode() {
    for b in Workspace::built_ins() {
        assert_eq!(decode(b.root.clone()), Workspace::new("Bad", b.root));
    }
}

#[test]
fn drop_unknown_panels_repairs_old_files() {
    use crate::es10_workspace::WorkspaceMigration;
    let raw = br#"{"hidden":["properties","text"],"maximized":"properties","root":{"tabs":{"panels":["properties","timeline"],"selected":"properties"}}}"#;
    let v: serde_json::Value = serde_json::from_slice(&WorkspaceMigration::drop_unknown_panels(raw)).unwrap();
    assert_eq!(v["hidden"], serde_json::json!(["text"]));
    assert!(v.get("maximized").is_none());
    assert_eq!(v["root"]["tabs"]["panels"], serde_json::json!(["timeline"]));
    assert_eq!(v["root"]["tabs"]["selected"], "timeline");
    assert_eq!(WorkspaceMigration::drop_unknown_panels(b"not json"), b"not json");
}

#[test]
fn a_saved_keystones_tab_disappears_cleanly() {
    use crate::es10_workspace::WorkspaceMigration;
    let raw = br#"{"hidden":["keystones"],"maximized":"keystones","root":{"tabs":{"panels":["project","keystones","markerList"],"selected":"keystones"}}}"#;
    let fixed = WorkspaceMigration::drop_unknown_panels(raw);
    let v: serde_json::Value = serde_json::from_slice(&fixed).unwrap();
    assert_eq!(v["hidden"], serde_json::json!([]));
    assert!(v.get("maximized").is_none());
    assert_eq!(v["root"]["tabs"]["panels"], serde_json::json!(["project", "markerList"]));
    assert_eq!(v["root"]["tabs"]["selected"], "project");
}

// MARK: Layout metrics (LayoutMetricsTests)

mod metrics {
    use super::*;
    use crate::es10_workspace::LayoutMetrics;

    #[test]
    fn fractions_above_minimums_are_kept() {
        let f = LayoutMetrics::clamped_fractions(&[0.5, 0.5], 1000.0, &[100.0, 100.0]);
        assert!((f[0] - 0.5).abs() < 1e-9 && (f[1] - 0.5).abs() < 1e-9);
    }

    #[test]
    fn small_pane_is_raised_and_others_give_way() {
        let f = LayoutMetrics::clamped_fractions(&[0.02, 0.48, 0.5], 1000.0, &[200.0, 100.0, 100.0]);
        assert!((f.iter().sum::<f64>() - 1.0).abs() < 1e-9);
        assert!(f[0] * 1000.0 >= 200.0 - 1e-6);
        assert!(f[1] * 1000.0 >= 100.0 && f[2] * 1000.0 >= 100.0);
        // The two big panes keep their ratio.
        assert!((f[1] / f[2] - 0.48 / 0.5).abs() < 1e-9);
    }

    #[test]
    fn cascading_minimums() {
        // Shrinking the window: every pane ends at its minimum or above, total stays the window.
        let mins = [300.0, 240.0, 200.0];
        let mut length = 740.0;
        while length <= 2000.0 {
            let f = LayoutMetrics::clamped_fractions(&[0.6, 0.25, 0.15], length, &mins);
            assert!((f.iter().sum::<f64>() - 1.0).abs() < 1e-9);
            for (i, m) in mins.iter().enumerate() {
                assert!(f[i] * length >= m - 1e-6, "pane {i} at {length}");
            }
            length += 37.0;
        }
    }

    #[test]
    fn minimums_that_do_not_fit_share_proportionally() {
        let f = LayoutMetrics::clamped_fractions(&[0.5, 0.5], 100.0, &[300.0, 100.0]);
        assert!((f[0] - 0.75).abs() < 1e-9 && (f[1] - 0.25).abs() < 1e-9);
    }

    #[test]
    fn degenerate_inputs() {
        assert!(LayoutMetrics::clamped_fractions(&[], 100.0, &[]).is_empty());
        assert_eq!(LayoutMetrics::clamped_fractions(&[0.5, 0.5], 0.0, &[10.0, 10.0]), [0.5, 0.5]);
        let nan = LayoutMetrics::clamped_fractions(&[f64::NAN, 1.0], 400.0, &[50.0, 50.0]);
        assert!((nan.iter().sum::<f64>() - 1.0).abs() < 1e-9 && nan[0] * 400.0 >= 50.0 - 1e-6);
    }

    #[test]
    fn divider_clamp() {
        assert_eq!(LayoutMetrics::clamped_divider(10.0, 0.0, 500.0, 100.0, 100.0), 100.0);
        assert_eq!(LayoutMetrics::clamped_divider(450.0, 0.0, 500.0, 100.0, 100.0), 400.0);
        assert_eq!(LayoutMetrics::clamped_divider(250.0, 0.0, 500.0, 100.0, 100.0), 250.0);
        assert_eq!(LayoutMetrics::clamped_divider(0.0, 0.0, 150.0, 100.0, 100.0), 75.0);
    }

    #[test]
    fn min_size_rolls_up_the_tree() {
        let group = tabs(&[PanelID::Timeline], PanelID::Timeline);
        let s = LayoutMetrics::min_size_of(&group);
        assert_eq!(s.width, PanelID::Timeline.min_size().0);
        assert_eq!(s.height, PanelID::Timeline.min_size().1 + PanelID::HEADER_HEIGHT);
        let row = horizontal(vec![group.clone(), group.clone()], &[0.5, 0.5]);
        assert_eq!(LayoutMetrics::min_size_of(&row).width, 2.0 * s.width + LayoutMetrics::DIVIDER_THICKNESS);
        assert_eq!(LayoutMetrics::min_size_of(&row).height, s.height);
        let col = vertical(vec![group.clone(), group], &[0.5, 0.5]);
        assert_eq!(LayoutMetrics::min_size_of(&col).height, 2.0 * s.height + LayoutMetrics::DIVIDER_THICKNESS);
    }

    #[test]
    fn minimum_content_size_adds_the_outer_margin() {
        let w = Workspace::editing_pc();
        let s = LayoutMetrics::min_size_of(&w.visible_root().unwrap());
        assert_eq!(w.minimum_content_size().width, s.width + 2.0 * LayoutMetrics::OUTER_MARGIN);
        assert_eq!(w.minimum_content_size().height, s.height + 2.0 * LayoutMetrics::OUTER_MARGIN);
    }

    #[test]
    fn built_in_layouts_fit_the_window_minimum() {
        let mut all = Workspace::built_ins();
        all.push(Workspace::color());
        for w in all {
            let m = w.minimum_content_size();
            assert!(
                m.width > 0.0 && m.width <= if w.name == Workspace::editing27().name { 1400.0 } else { 1140.0 },
                "{} width {}",
                w.name,
                m.width
            );
            assert!(m.height > 0.0 && m.height <= 600.0, "{} height {}", w.name, m.height);
        }
    }

    #[test]
    fn maximized_panel_needs_only_itself() {
        let mut w = Workspace::editing_pc();
        w.toggle_maximize(PanelID::Timeline);
        assert_eq!(w.minimum_content_size().width, PanelID::Timeline.min_size().0 + 2.0 * LayoutMetrics::OUTER_MARGIN);
    }
}

// MARK: Migration (WorkspaceMigrationTests)

#[test]
fn properties_is_dropped_everywhere() {
    use crate::es10_workspace::WorkspaceMigration;
    let legacy = br#"{"name":"Old","hidden":["properties","effects"],"maximized":"properties",
        "root":{"tabs":{"panels":["effectControls","text","properties"],"selected":"properties"}}}"#;
    let w: Workspace = serde_json::from_slice(&WorkspaceMigration::drop_unknown_panels(legacy)).unwrap();
    assert_eq!(w.root, tabs(&[PanelID::EffectControls, PanelID::Text], PanelID::EffectControls));
    assert_eq!(w.hidden, [PanelID::Effects].into_iter().collect());
    assert_eq!(w.maximized, None);
}

#[test]
fn current_layouts_pass_through_unchanged() {
    use crate::es10_workspace::WorkspaceMigration;
    let data = serde_json::to_vec(&Workspace::editing_pc()).unwrap();
    let back: Workspace = serde_json::from_slice(&WorkspaceMigration::drop_unknown_panels(&data)).unwrap();
    assert_eq!(back, Workspace::editing_pc());
}

#[test]
fn window_menu_can_show_a_panel_the_layout_lacks() {
    use PanelID::*;
    let mut w = Workspace::new(
        "Mine",
        horizontal(vec![tabs(&[EffectControls], EffectControls), tabs(&[Timeline], Timeline)], &[0.5, 0.5]),
    );
    assert!(!w.is_visible(ColorInspector));
    w.toggle(ColorInspector);
    assert!(w.is_visible(ColorInspector));
    assert!(w.validation_problems().is_empty());
    w.toggle(ColorInspector);
    assert!(!w.is_visible(ColorInspector));
}

// MARK: Menu flow (WorkspaceMenuFlowTests)

#[test]
fn save_as_new_workspace_lists_and_selects_it() {
    use crate::es10_workspace::WorkspaceStore;
    let mut s = WorkspaceStore::default();
    let mut w = s.current();
    w.hide(PanelID::Effects);
    s.update_current(&w);
    let mut named = s.current();
    named.name = "Vertical".to_string();
    assert!(s.library.save_as("Vertical", &named));
    assert!(s.select_edit("Vertical"));
    assert!(s.library.names().contains(&"Vertical".to_string()));
    assert_eq!(s.edit_name, "Vertical");
    assert!(!s.current().is_visible(PanelID::Effects));
    // The built-in this was derived from keeps its own (modified) state and stays listed.
    assert!(s.library.names().contains(&Workspace::editing_pc().name));
    // Saving under the same name again replaces it instead of adding a second entry; built-in names are refused.
    let count = s.library.names().len();
    assert!(s.library.save_as("vertical", &named) && s.library.names().len() == count);
    assert!(!s.library.save_as(&Workspace::editing_pc().name, &named));
}

#[test]
fn closing_a_panel_and_resetting_restores_the_saved_layout() {
    use crate::es10_workspace::WorkspaceStore;
    let mut s = WorkspaceStore::default();
    assert!(s.current().is_visible(PanelID::Effects));
    let mut w = s.current();
    w.hide(PanelID::Effects); // Close Panel in the tab context menu / Window menu
    s.update_current(&w);
    assert!(!s.current().is_visible(PanelID::Effects));
    assert!(s.can_reset_current());
    assert!(s.library.reset_built_in(&s.edit_name.clone()));
    assert!(s.current().is_visible(PanelID::Effects));
    assert!(!s.can_reset_current());
}

#[test]
fn store_rename_delete() {
    use crate::es10_workspace::WorkspaceStore;
    let mut s = WorkspaceStore::default();
    assert!(!s.can_rename_or_delete_current());
    assert!(!s.rename_current("X") && !s.delete_current());
    let cur = s.current();
    s.library.save_as("Mine", &cur);
    s.select_edit("Mine");
    assert!(s.can_rename_or_delete_current());
    assert!(s.rename_current("Yours"));
    assert!(s.edit_name == "Yours" && s.current().name == "Yours");
    assert!(s.delete_current());
    assert_eq!(s.edit_name, Workspace::editing_pc().name);
    assert!(!s.can_reset_current());
}

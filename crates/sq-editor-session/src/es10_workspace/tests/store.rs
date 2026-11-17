use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

use sq_uikit::keyframe_graph_geometry::{Point, Rect};
use sq_uikit::panel_id::PanelID;

use crate::es10_workspace::layout::{horizontal, tabs};
use crate::es10_workspace::{
    FloatingPanelFrame, FloatingPanelState, LayoutNode, SplitAxis, Workspace, WorkspaceAutoPick, WorkspaceChoices,
    WorkspacePage, WorkspaceStore,
};

static COUNTER: AtomicU32 = AtomicU32::new(0);

fn tmp() -> PathBuf {
    std::env::temp_dir()
        .join(format!("sq-ws-{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed)))
        .join("workspaces.json")
}

fn set(v: Vec<PanelID>) -> HashSet<PanelID> {
    v.into_iter().collect()
}

fn with_color_pages() -> HashSet<PanelID> {
    let mut all = set(PanelID::dockable());
    all.extend([PanelID::ColorClips, PanelID::Steps]);
    all
}

fn root_fractions(w: &Workspace) -> Vec<f64> {
    match &w.root {
        LayoutNode::Split { fractions, .. } => fractions.clone(),
        _ => panic!("not a split"),
    }
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

fn write_json(path: &PathBuf, v: &serde_json::Value) {
    std::fs::write(path, serde_json::to_vec(v).unwrap()).unwrap();
}

#[test]
fn color_workspace_holds_every_panel_once() {
    let panels = Workspace::color().all_panels();
    assert_eq!(panels.len(), with_color_pages().len());
    assert_eq!(set(panels), with_color_pages());
    assert!(Workspace::color().is_visible(PanelID::ProgramMonitor) && Workspace::color().is_visible(PanelID::Timeline));
    assert!(!Workspace::built_ins().iter().any(|b| b.name == Workspace::color().name));
}

#[test]
fn defaults_show_editing_pc() {
    assert_eq!(WorkspaceStore::default().current(), Workspace::editing_pc());
}

#[test]
fn fractions_are_persisted_per_workspace() {
    let mut s = WorkspaceStore::default();
    let mut w = s.current();
    assert!(w.set_fractions(&[], &[0.6, 0.4]));
    s.update_current(&w);
    s.select_edit(&Workspace::editing_mac_book().name);
    assert_eq!(s.current(), Workspace::editing_mac_book()); // other workspace untouched
    s.set_page(WorkspacePage::Color); // the Color layout paired with MacBook
    let mut c = s.current();
    assert!(c.set_fractions(&[], &[0.7, 0.3]));
    s.update_current(&c);

    let url = tmp();
    s.save(&url).unwrap();
    let mut loaded = WorkspaceStore::load(&url);
    assert_eq!(loaded, s);
    loaded.set_page(WorkspacePage::Edit);
    loaded.select_edit(&Workspace::editing_pc().name);
    assert_eq!(root_fractions(&loaded.current()), [0.6, 0.4]);
    loaded.select_edit(&Workspace::editing_mac_book().name);
    loaded.set_page(WorkspacePage::Color);
    assert_eq!(root_fractions(&loaded.current()), [0.7, 0.3]);
}

#[test]
fn hide_panel_is_stored_and_maximize_is_not() {
    let mut s = WorkspaceStore::default();
    let mut w = s.current();
    w.hide(PanelID::Library);
    w.toggle_maximize(PanelID::Timeline);
    s.update_current(&w);
    assert!(s.current().hidden.contains(&PanelID::Library));
    assert_eq!(s.current().maximized, None);
}

#[test]
fn unknown_workspace_name_is_refused() {
    let mut s = WorkspaceStore::default();
    assert!(!s.select_edit("Nope"));
    assert_eq!(s.page, WorkspacePage::Edit);
}

#[test]
fn garbage_file_gives_defaults() {
    let url = tmp();
    std::fs::create_dir_all(url.parent().unwrap()).unwrap();
    std::fs::write(&url, b"not json").unwrap();
    assert_eq!(WorkspaceStore::load(&url), WorkspaceStore::default());
    assert_eq!(WorkspaceStore::load(&tmp()), WorkspaceStore::default());
    // The unreadable file is kept next to it, so the next save does not destroy it.
    assert_eq!(std::fs::read(url.with_file_name("workspaces.json.corrupt")).unwrap(), b"not json");
}

// After switching Editing - PC to Editing - MacBook, PC was gone from the list.
#[test]
fn switching_back_and_forth_keeps_every_workspace_listed() {
    let mut s = WorkspaceStore::default();
    s.library.save_as("Mine", &Workspace::editing_pc());
    let mut expected: Vec<String> = Workspace::built_ins().into_iter().map(|w| w.name).collect();
    expected.push("Mine".to_string());
    assert_eq!(s.library.names(), expected);
    for name in [
        Workspace::editing_mac_book().name,
        Workspace::editing_pc().name,
        "Mine".to_string(),
        Workspace::editing_mac_book().name,
    ] {
        assert!(s.select_edit(&name));
        let mut w = s.current();
        w.hide(PanelID::Effects); // an edit while the workspace is showing (stored as override)
        s.update_current(&w);
        assert_eq!(s.library.names(), expected);
        assert_eq!(s.edit_name, name);
    }
    let url = tmp();
    s.save(&url).unwrap();
    assert_eq!(WorkspaceStore::load(&url).library.names(), expected);
}

#[test]
fn persisted_state_missing_built_ins_still_lists_them() {
    let url = tmp();
    let s = WorkspaceStore { edit_name: "Gone".to_string(), ..WorkspaceStore::default() };
    s.save(&url).unwrap();
    let loaded = WorkspaceStore::load(&url);
    assert!(loaded.library.names().starts_with(&[Workspace::editing_pc().name, Workspace::editing_mac_book().name]));
    assert_eq!(loaded.current().name, Workspace::editing_pc().name);
}

#[test]
fn older_layout_version_resets_built_ins_once_and_keeps_user_workspaces() {
    let mut old = WorkspaceStore::default();
    let mut w = Workspace::editing_pc();
    w.hide(PanelID::Effects);
    old.library.update(&w);
    old.library.save_as("Mine", &Workspace::editing_mac_book());
    let mut c = Workspace::color();
    c.hide(PanelID::Scopes);
    old.layout_version = 0;
    let url = tmp();
    old.save(&url).unwrap();
    let loaded = WorkspaceStore::load(&url);
    assert_eq!(loaded.layout_version, WorkspaceStore::CURRENT_LAYOUT_VERSION);
    assert_eq!(loaded.color_workspace(), Workspace::color());
    assert!(!loaded.library.is_modified_built_in(&Workspace::editing_pc().name));
    assert!(loaded.library.names().contains(&"Mine".to_string()));
    // Second load: an edit made after the reset survives.
    let mut again = loaded;
    again.set_color_workspace(c.clone());
    again.save(&url).unwrap();
    assert_eq!(WorkspaceStore::load(&url).color_workspace(), c);
}

#[test]
fn default_layouts_match_the_boards() {
    use PanelID::*;
    let edit = Workspace::editing_pc();
    assert_eq!(edit.root.panels()[..3], [EffectControls, Text, Graphics]);
    let LayoutNode::Split { axis: SplitAxis::Horizontal, fractions: f, .. } = &edit.root else { panic!("edit root") };
    assert!((f[1] - 340.0 / 1440.0).abs() < 0.01);
    let color = Workspace::color();
    assert!(color.is_visible(Scopes) && color.is_visible(ColorInspector) && !color.is_visible(AudioMeter));
    // Version 5: viewer and Scopes over the lower tab group | Color settings (340), no clip column.
    let root = color.visible_root().unwrap_or_else(|| color.root.clone());
    let LayoutNode::Split { axis: SplitAxis::Horizontal, children: cols, fractions: f } = &root else {
        panic!("color columns")
    };
    assert_eq!(cols.len(), 2);
    let LayoutNode::Split { axis: SplitAxis::Vertical, children: rows, .. } = &cols[0] else { panic!("color columns") };
    let LayoutNode::Tabs { panels: right, .. } = &cols[1] else { panic!("color columns") };
    assert!(*right == [ColorInspector] && (f[1] - 340.0 / 1440.0).abs() < 0.01);
    assert_eq!(rows[0].panels(), [ProgramMonitor, SourceMonitor, Scopes], "Program | Source, Scopes beside them");
    assert_eq!(rows[1].panels()[..4], [Tools, Steps, Timeline, ColorClips]);
}

/// Version 5: the Color page docks Sources and Steps as tabs of its lower group; Edit layouts never hold them.
#[test]
fn color_page_is_one_layout_and_old_stores_migrate() {
    use PanelID::*;
    assert!(Workspace::color().is_visible(ColorClips));
    assert_eq!(set(Workspace::color().all_panels()), with_color_pages());
    let mut w = Workspace::color();
    w.hide(ColorClips);
    w.show(ColorClips); // the Window menu shows it again where it was
    assert!(w.is_visible(ColorClips) && w.hidden == Workspace::color().hidden);
    let mut e = Workspace::editing_pc();
    e.show(ColorClips); // an Edit layout can not dock it
    assert_eq!(e, Workspace::editing_pc());
    // A store of layout version 1: shaped Color pages, the Clips panel docked, an Edit layout holding it too.
    let clips = Workspace::new(
        "Color",
        horizontal(
            vec![tabs(&[ColorClips], ColorClips), tabs(&[ColorInspector, ProgramMonitor, Timeline], ColorInspector)],
            &[0.3, 0.7],
        ),
    );
    let mut s = WorkspaceStore::default();
    s.set_page(WorkspacePage::Color);
    s.set_color_workspace(clips); // (a version 1 store holds one Color page)
    let user = s.library.suggested_new_name("Mine");
    s.library.save_as(&user, &Workspace::new(&user, tabs(&[Timeline, ColorClips, Project], ColorClips)));
    let url = tmp();
    s.save(&url).unwrap();
    let mut json = read_json(&url);
    json["layoutVersion"] = 1.into();
    let first_color = json["colorLayouts"].as_object().and_then(|o| o.values().next().cloned()).unwrap();
    json["colorWorkspace"] = first_color.clone();
    json.as_object_mut().unwrap().remove("colorLayouts");
    json["colorPortraitWorkspace"] = first_color;
    json["colorFormat"] = "portrait".into();
    write_json(&url, &json);
    let back = WorkspaceStore::load(&url);
    assert!(back.page == WorkspacePage::Color && back.layout_version == WorkspaceStore::CURRENT_LAYOUT_VERSION);
    assert!(back.color_workspace() == Workspace::color() && back.current() == Workspace::color());
    let mine = back.library.workspace_named(&user).unwrap();
    assert!(
        !mine.all_panels().contains(&ColorClips) && mine.is_visible(Timeline) && mine.is_visible(Project),
        "a user layout stays, without the retired panel"
    );
}

#[test]
fn color_page_without_the_color_inspector_is_repaired() {
    let mut s = WorkspaceStore::default();
    s.set_color_workspace(Workspace::new("Color", tabs(&[PanelID::ProgramMonitor], PanelID::ProgramMonitor)));
    let url = tmp();
    s.save(&url).unwrap();
    assert_eq!(WorkspaceStore::load(&url).color_workspace(), Workspace::color());
}

// MARK: Color pair (WorkspaceColorPairTests)

/// Index of the horizontal column holding `panel` in the root split (`None` when the root is not a horizontal split).
fn column_index(panel: PanelID, w: &Workspace) -> Option<(usize, usize)> {
    let root = w.visible_root().unwrap_or_else(|| w.root.clone());
    let LayoutNode::Split { axis: SplitAxis::Horizontal, children, .. } = root else { return None };
    let i = children.iter().position(|k| k.panels().contains(&panel) && !w.hidden.contains(&panel))?;
    Some((i, children.len()))
}

#[test]
fn every_built_in_has_an_automatic_color_layout() {
    use PanelID::*;
    for b in Workspace::built_ins() {
        let c = WorkspaceStore::automatic_color_for_edit(&b.name);
        assert_eq!(c.name, Workspace::color().name);
        assert_eq!(set(c.all_panels()), with_color_pages());
        assert!(
            c.is_visible(ProgramMonitor)
                && c.is_visible(ColorInspector)
                && c.is_visible(Scopes)
                && c.is_visible(Timeline)
        );
    }
    assert_eq!(WorkspaceStore::automatic_color_for_edit("Whatever").root, Workspace::color().root);
}

/// Portrait and MacBook put the viewer far right in Editing; the Color layout keeps it there.
#[test]
fn portrait_and_mac_book_color_keep_the_viewer_far_right() {
    for edit in [Workspace::editing_portrait(), Workspace::editing_mac_book()] {
        let e = column_index(PanelID::ProgramMonitor, &edit).unwrap();
        assert_eq!(e.0, e.1 - 1);
        let c = column_index(PanelID::ProgramMonitor, &WorkspaceStore::automatic_color_for_edit(&edit.name)).unwrap();
        assert_eq!(c.0, c.1 - 1, "{}: viewer far right in Color too", edit.name);
    }
    // Landscape keeps the viewer in the left column, the Color settings full height on the right.
    assert_eq!(column_index(PanelID::ProgramMonitor, &Workspace::color()), Some((0, 2)));
}

#[test]
fn switching_the_edit_workspace_switches_the_color_layout() {
    let mut s = WorkspaceStore::default();
    s.set_page(WorkspacePage::Color);
    assert_eq!(s.current().root, Workspace::color().root);
    s.select_edit(&Workspace::editing_portrait().name);
    assert_eq!(s.page, WorkspacePage::Color, "the page stays");
    assert_eq!(s.current().root, WorkspaceStore::automatic_color_for_edit(&Workspace::editing_portrait().name).root);
    assert_ne!(s.current().root, Workspace::color().root);
}

#[test]
fn color_edits_belong_to_the_edit_workspace_only() {
    let mut s = WorkspaceStore::default();
    s.set_page(WorkspacePage::Color);
    let mut c = s.current();
    c.hide(PanelID::Scopes);
    s.update_current(&c);
    assert!(!s.current().is_visible(PanelID::Scopes));
    s.select_edit(&Workspace::editing_mac_book().name);
    assert!(s.current().is_visible(PanelID::Scopes));
    s.select_edit(&Workspace::editing_pc().name);
    assert!(!s.current().is_visible(PanelID::Scopes));
    s.set_page(WorkspacePage::Edit);
    assert_eq!(s.current(), Workspace::editing_pc(), "the Edit layout is untouched");
}

#[test]
fn save_as_new_stores_both_layouts_under_one_name() {
    let mut s = WorkspaceStore::default();
    s.select_edit(&Workspace::editing_portrait().name);
    s.set_page(WorkspacePage::Color);
    let mut c = s.current();
    c.hide(PanelID::Scopes);
    s.update_current(&c);
    s.set_page(WorkspacePage::Edit);
    let mut e = s.current();
    e.hide(PanelID::Effects);
    s.update_current(&e);
    let name = s.save_current_as_new("Portrait TikTok");
    assert!(name == "Portrait TikTok" && s.edit_name == name);
    assert!(s.current().hidden.contains(&PanelID::Effects));
    s.set_page(WorkspacePage::Color);
    assert!(!s.current().is_visible(PanelID::Scopes), "the color half was saved too");
    // The source preset keeps its own color layout (edited above, so scopes hidden there as well).
    s.select_edit(&Workspace::editing_portrait().name);
    assert!(!s.current().is_visible(PanelID::Scopes));
    // Both halves survive a save and load.
    s.select_edit(&name);
    let url = tmp();
    s.save(&url).unwrap();
    let back = WorkspaceStore::load(&url);
    assert_eq!(back, s);
    assert!(back.page == WorkspacePage::Color && !back.current().is_visible(PanelID::Scopes));
}

#[test]
fn save_as_new_from_the_color_page_keeps_the_edit_half_as_edit_layout() {
    let mut s = WorkspaceStore::default();
    s.select_edit(&Workspace::editing_mac_book().name);
    s.set_page(WorkspacePage::Color);
    let name = s.save_current_as_new("Mine");
    assert_eq!(
        s.library.workspace_named(&name).map(|w| w.root),
        Some(Workspace::editing_mac_book().root),
        "the Edit half is the Edit layout, not the Color one"
    );
    assert_eq!(s.page, WorkspacePage::Color, "stays on the page it was saved from");
    assert_eq!(s.current().root, WorkspaceStore::automatic_color_for_edit(&Workspace::editing_mac_book().name).root);
}

#[test]
fn rename_and_delete_carry_the_color_half() {
    let mut s = WorkspaceStore::default();
    s.select_edit(&Workspace::editing_portrait().name);
    let name = s.save_current_as_new("Mine");
    s.set_page(WorkspacePage::Color);
    assert!(s.can_rename_or_delete_current(), "also on the Color page");
    let mut c = s.current();
    c.hide(PanelID::Scopes);
    s.update_current(&c);
    assert!(s.rename_current("Yours"));
    assert!(s.edit_name == "Yours" && !s.current().is_visible(PanelID::Scopes));
    assert!(!s.color_layouts.contains_key(&name));
    assert!(s.delete_current());
    assert!(!s.color_layouts.contains_key("Yours"));
    assert_eq!(s.edit_name, Workspace::editing_pc().name);
}

#[test]
fn reset_on_the_color_page_restores_the_automatic_layout() {
    let mut s = WorkspaceStore::default();
    s.select_edit(&Workspace::editing_portrait().name);
    s.set_page(WorkspacePage::Color);
    let mut c = s.current();
    c.hide(PanelID::Scopes);
    s.update_current(&c);
    assert!(s.can_reset_current());
    s.reset_current_color();
    assert!(
        s.current().root == WorkspaceStore::automatic_color_for_edit(&Workspace::editing_portrait().name).root
            && s.current().is_visible(PanelID::Scopes)
    );
    let mut all = s;
    let mut c2 = all.current();
    c2.hide(PanelID::Scopes);
    all.update_current(&c2);
    all.reset_all_color();
    assert!(all.color_layouts.is_empty());
}

#[test]
fn legacy_single_color_layout_is_dropped_for_the_automatic_pair() {
    let mut s = WorkspaceStore::default();
    s.library.save_as("Mine", &Workspace::editing_pc());
    let url = tmp();
    s.save(&url).unwrap();
    let mut json = read_json(&url);
    json.as_object_mut().unwrap().remove("colorLayouts");
    json["colorWorkspace"] = serde_json::to_value(Workspace::color()).unwrap();
    json["layoutVersion"] = 2.into();
    write_json(&url, &json);
    let mut back = WorkspaceStore::load(&url);
    assert!(back.color_layouts.is_empty());
    back.select_edit(&Workspace::editing_portrait().name);
    back.set_page(WorkspacePage::Color);
    assert_eq!(back.current().root, WorkspaceStore::automatic_color_for_edit(&Workspace::editing_portrait().name).root);
}

#[test]
fn orphaned_or_broken_color_layouts_are_healed_on_load() {
    let mut s = WorkspaceStore::default();
    s.color_layouts.insert("Gone".to_string(), Workspace::color());
    s.color_layouts.insert(
        Workspace::editing_mac_book().name,
        Workspace::new("Color", tabs(&[PanelID::ProgramMonitor], PanelID::ProgramMonitor)),
    );
    let url = tmp();
    s.save(&url).unwrap();
    assert!(WorkspaceStore::load(&url).color_layouts.is_empty());
}

fn group_of(root: &LayoutNode, p: PanelID) -> (Vec<PanelID>, PanelID) {
    Workspace::tab_groups(root).into_iter().find(|g| g.0.contains(&p)).unwrap()
}

#[test]
fn color_lower_group_holds_steps_timeline_sources_as_tabs() {
    use PanelID::*;
    for edit in Workspace::built_ins() {
        let c = WorkspaceStore::automatic_color_for_edit(&edit.name);
        assert_eq!(group_of(&c.root, Timeline), (vec![Steps, Timeline, ColorClips], Timeline));
        assert_eq!(group_of(&c.root, Scopes).0, [Scopes], "Scopes is its own docked tab, beside the viewer");
    }
}

#[test]
fn simple_hiding_steps_keeps_timeline_selected_and_scopes_visible() {
    use PanelID::*;
    let mut w = Workspace::color();
    w.hide(Steps);
    assert!(w.is_visible(Scopes) && w.is_visible(Timeline) && w.is_visible(ColorClips) && !w.is_visible(Steps));
    assert_eq!(group_of(&w.visible_root().unwrap(), Timeline), (vec![Timeline, ColorClips], Timeline));
    w.show(Steps);
    assert_eq!(
        group_of(&w.visible_root().unwrap(), Timeline),
        (vec![Steps, Timeline, ColorClips], Steps),
        "showing a tab selects it"
    );
}

#[test]
fn tab_switch_keeps_the_group_and_the_other_selections() {
    use PanelID::*;
    let mut w = Workspace::color();
    w.show(ColorClips);
    w.show(Scopes);
    assert_eq!(group_of(&w.root, Timeline).1, ColorClips);
    assert_eq!(group_of(&w.root, ColorInspector).1, ColorInspector);
    assert_eq!(group_of(&w.root, ProgramMonitor).1, ProgramMonitor);
    assert_eq!(set(w.root.panels()), set(Workspace::color().root.panels()));
}

#[test]
fn version4_store_drops_its_color_layouts_on_load() {
    use PanelID::*;
    let mut s = WorkspaceStore::default();
    let mut old = Workspace::color();
    old.root = tabs(&[ColorClips, ProgramMonitor], ColorClips);
    s.color_layouts.insert(Workspace::editing_pc().name, old);
    let url = tmp();
    s.save(&url).unwrap();
    let mut json = read_json(&url);
    json["layoutVersion"] = 4.into();
    write_json(&url, &json);
    let mut back = WorkspaceStore::load(&url);
    assert!(
        back.layout_version == WorkspaceStore::CURRENT_LAYOUT_VERSION && WorkspaceStore::CURRENT_LAYOUT_VERSION == 5
    );
    assert!(back.color_layouts.is_empty());
    back.set_page(WorkspacePage::Color);
    assert_eq!(back.current().root, Workspace::color().root);
}

// MARK: Project choices (WorkspaceProjectChoiceTests)

fn all_names() -> Vec<String> {
    Workspace::built_ins().into_iter().map(|w| w.name).collect()
}

#[test]
fn project_without_choice_opens_in_editing_pc() {
    let c = WorkspaceChoices::new();
    assert_eq!(c.name(Some("/a/One.sqproj"), &all_names()), Workspace::editing_pc().name);
    assert_eq!(c.name(None, &all_names()), Workspace::editing_pc().name);
}

#[test]
fn choice_is_remembered_per_project() {
    let mut c = WorkspaceChoices::new();
    c.choose(&Workspace::editing_mac_book().name, Some("/a/One.sqproj"));
    assert_eq!(c.name(Some("/a/One.sqproj"), &all_names()), Workspace::editing_mac_book().name);
    assert_eq!(c.name(Some("/a/Two.sqproj"), &all_names()), Workspace::editing_pc().name);
    assert_eq!(c.name(None, &all_names()), Workspace::editing_pc().name);
}

#[test]
fn untitled_project_keeps_its_choice_until_the_next_new_project() {
    let mut c = WorkspaceChoices::new();
    c.choose(&Workspace::editing_portrait().name, None);
    assert_eq!(c.name(None, &all_names()), Workspace::editing_portrait().name);
    c.forget_untitled();
    assert_eq!(c.name(None, &all_names()), Workspace::editing_pc().name);
}

#[test]
fn deleted_workspace_falls_back_to_editing_pc() {
    let mut c = WorkspaceChoices::new();
    c.choose("Mine", Some("/a/One.sqproj"));
    assert_eq!(c.name(Some("/a/One.sqproj"), &all_names()), Workspace::editing_pc().name);
    let mut with_mine = all_names();
    with_mine.push("Mine".to_string());
    assert_eq!(c.name(Some("/a/One.sqproj"), &with_mine), "Mine");
}

#[test]
fn choosing_editing_pc_again_clears_the_entry() {
    let mut c = WorkspaceChoices::new();
    c.choose(&Workspace::editing_mac_book().name, Some("/a/One.sqproj"));
    c.choose(&Workspace::editing_pc().name, Some("/a/One.sqproj"));
    assert!(c.by_project().is_empty());
}

#[test]
fn stored_dictionary_round_trips() {
    let mut c = WorkspaceChoices::new();
    c.choose(&Workspace::editing27().name, Some("/a/One.sqproj"));
    assert_eq!(WorkspaceChoices::from_stored(Some(c.by_project().clone())), c);
    assert_eq!(WorkspaceChoices::from_stored(None), WorkspaceChoices::new());
}

/// The store keeps one global name (the last workspace on screen); a stale "Editing - MacBook" from an earlier
/// session must not survive a project open.
#[test]
fn stale_global_name_is_replaced_on_open() {
    let mut s = WorkspaceStore::default();
    s.select_edit(&Workspace::editing_mac_book().name);
    let names = s.library.all().into_iter().map(|w| w.name).collect::<Vec<_>>();
    let name = WorkspaceChoices::new().name(Some("/a/One.sqproj"), &names);
    s.select_edit(&name);
    assert_eq!(s.edit_name, Workspace::editing_pc().name);
}

/// The redesign frame at 1440 x 900: Controls 614 | Program 476 over the timeline (426 / 404 high), right column
/// 342 of 1436 px with Library 442 over Project 388.
#[test]
fn editing_pc_follows_the_board_proportions() {
    let LayoutNode::Split { axis: SplitAxis::Horizontal, children: cols, fractions: cf } = Workspace::editing_pc().root
    else {
        panic!("shape")
    };
    let LayoutNode::Split { axis: SplitAxis::Vertical, children: left, fractions: lf } = &cols[0] else {
        panic!("shape")
    };
    let LayoutNode::Split { axis: SplitAxis::Horizontal, fractions: uf, .. } = &left[0] else { panic!("shape") };
    let LayoutNode::Split { axis: SplitAxis::Vertical, fractions: rf, .. } = &cols[1] else { panic!("shape") };
    assert!((cf[1] * 1422.0 - 339.0).abs() < 1.5);
    assert!((uf[0] / uf[1] - 614.0 / 476.0).abs() < 0.01);
    assert!((lf[0] / lf[1] - 426.0 / 404.0).abs() < 0.01);
    assert!((rf[0] / rf[1] - 442.0 / 388.0).abs() < 0.01);
}

#[test]
fn store_older_than_the_board_layout_gets_the_new_proportions() {
    let mut old = WorkspaceStore::default();
    let mut w = Workspace::editing_pc();
    w.hide(PanelID::Effects);
    old.library.update(&w);
    old.library.save_as("Mine", &Workspace::editing_mac_book());
    let url = tmp();
    old.save(&url).unwrap();
    let mut json = read_json(&url);
    json["layoutVersion"] = 3.into();
    write_json(&url, &json);
    let loaded = WorkspaceStore::load(&url);
    assert_eq!(loaded.layout_version, WorkspaceStore::CURRENT_LAYOUT_VERSION);
    assert_eq!(loaded.library.workspace_named(&Workspace::editing_pc().name), Some(Workspace::editing_pc()));
    assert!(loaded.library.names().contains(&"Mine".to_string()));
}

// MARK: Layout pick (WorkspaceLayoutPickTests)

#[test]
fn every_format_and_screen_picks_editing_pc() {
    let pc = Workspace::editing_pc().name;
    assert_eq!(WorkspaceAutoPick::name(2560.0, 1440.0, 1080.0, 1920.0), pc);
    assert_eq!(WorkspaceAutoPick::name(1512.0, 982.0, 1080.0, 1350.0), pc);
    assert_eq!(WorkspaceAutoPick::name(1512.0, 982.0, 1920.0, 1080.0), pc);
    assert_eq!(WorkspaceAutoPick::name(2560.0, 1440.0, 1920.0, 1080.0), pc);
    assert_eq!(WorkspaceAutoPick::name(0.0, 0.0, 0.0, 0.0), pc);
}

#[test]
fn new_built_ins_are_valid_and_unique() {
    for w in [Workspace::editing_portrait(), Workspace::editing27()] {
        assert!(Workspace::built_ins().contains(&w));
        assert!(w.is_visible(PanelID::ProgramMonitor) && w.is_visible(PanelID::Timeline));
        assert_eq!(w.root.sanitized(), Some(w.root.clone()));
    }
    let names: HashSet<String> = all_names().into_iter().collect();
    assert_eq!(names.len(), Workspace::built_ins().len());
}

#[test]
fn portrait_program_is_far_right_and_full_height() {
    let LayoutNode::Split { axis: SplitAxis::Horizontal, children: kids, .. } = Workspace::editing_portrait().root
    else {
        panic!("shape")
    };
    let last = kids.last().unwrap().panels();
    assert!(last.contains(&PanelID::ProgramMonitor) && !last.contains(&PanelID::Timeline));
}

#[test]
fn suggested_name_is_unique() {
    let mut lib = crate::es10_workspace::WorkspaceLibrary::default();
    assert_eq!(lib.suggested_new_name("My Layout"), "My Layout");
    lib.save_as("My Layout", &Workspace::editing_pc());
    assert_eq!(lib.suggested_new_name("My Layout"), "My Layout 2");
    lib.save_as("My Layout 2", &Workspace::editing_pc());
    assert_eq!(lib.suggested_new_name("My Layout"), "My Layout 3");
    assert_eq!(lib.suggested_new_name(&Workspace::editing_pc().name), format!("{} 2", Workspace::editing_pc().name));
}

#[test]
fn save_current_as_new_selects_copy() {
    let mut s = WorkspaceStore::default();
    s.select_edit(&Workspace::editing_portrait().name);
    let name = s.save_current_as_new("Mine");
    assert_eq!(name, "Mine");
    assert!(s.edit_name == "Mine" && s.page == WorkspacePage::Edit);
    assert_eq!(s.current().root, Workspace::editing_portrait().root);
    s.set_page(WorkspacePage::Color);
    assert_eq!(s.save_current_as_new("Mine"), "Mine 2");
    assert_eq!(s.current().root, WorkspaceStore::automatic_color_for_edit(&Workspace::editing_portrait().name).root);
}

// MARK: Floating panels (FloatingPanelStateTests)

const SCREEN: Rect = Rect { x: 0.0, y: 0.0, width: 1440.0, height: 900.0 };

fn frame() -> FloatingPanelFrame {
    FloatingPanelFrame::new(100.0, 200.0, 500.0, 300.0)
}

fn edit_key() -> String {
    FloatingPanelState::key(WorkspacePage::Edit, "Editing \u{2013} PC")
}

fn color_key() -> String {
    FloatingPanelState::key(WorkspacePage::Color, "Editing \u{2013} PC")
}

#[test]
fn keys_separate_workspaces_and_pages() {
    assert_ne!(edit_key(), color_key());
    assert_ne!(edit_key(), FloatingPanelState::key(WorkspacePage::Edit, "Editing \u{2013} MacBook"));
}

#[test]
fn float_and_dock_per_workspace() {
    let mut s = FloatingPanelState::new();
    s.float(PanelID::Scopes, &edit_key(), frame());
    assert_eq!(s.panels(&edit_key()), set(vec![PanelID::Scopes]));
    assert!(s.panels(&color_key()).is_empty());
    assert_eq!(s.frame(PanelID::Scopes, &edit_key()), Some(frame()));
    s.dock(PanelID::Scopes, &edit_key());
    assert!(s.panels(&edit_key()).is_empty());
    assert_eq!(s.frame(PanelID::Scopes, &edit_key()), None);
}

#[test]
fn set_frame_only_for_floating_panels() {
    let mut s = FloatingPanelState::new();
    s.set_frame(frame(), PanelID::Library, &edit_key());
    assert!(s.panels(&edit_key()).is_empty());
    s.float(PanelID::Library, &edit_key(), frame());
    let moved = FloatingPanelFrame::new(1.0, 2.0, 300.0, 200.0);
    s.set_frame(moved, PanelID::Library, &edit_key());
    assert_eq!(s.frame(PanelID::Library, &edit_key()), Some(moved));
}

#[test]
fn non_dockable_panels_do_not_float() {
    let mut s = FloatingPanelState::new();
    s.float(PanelID::Steps, &edit_key(), frame());
    assert!(s.panels(&edit_key()).is_empty());
}

#[test]
fn round_trip_and_unknown_panels_dropped() {
    let mut s = FloatingPanelState::new();
    s.float(PanelID::Graphics, &edit_key(), frame());
    let back: FloatingPanelState = serde_json::from_slice(&serde_json::to_vec(&s).unwrap()).unwrap();
    assert_eq!(back, s);
    let raw = br#"{"layouts":{"k":{"graphics":{"x":1,"y":2,"width":3,"height":4},"gone":{"x":1,"y":2,"width":3,"height":4},"colorClips":{"x":1,"y":2,"width":3,"height":4}}}}"#;
    let d: FloatingPanelState = serde_json::from_slice(raw).unwrap();
    assert_eq!(d.panels("k"), set(vec![PanelID::Graphics])); // unknown ids and non-dockable panels are dropped
}

#[test]
fn save_and_load() {
    let url = tmp().with_file_name("floating-panels.json");
    let mut s = FloatingPanelState::new();
    s.float(PanelID::Scopes, &edit_key(), frame());
    s.save(&url).unwrap();
    assert_eq!(FloatingPanelState::load(&url), s);
    assert_eq!(FloatingPanelState::load(&url.with_extension("json.missing")), FloatingPanelState::new());
}

#[test]
fn clamp_keeps_title_bar_reachable() {
    let bar = FloatingPanelState::TITLE_BAR;
    let screens = [SCREEN];
    let inside = Rect::new(100.0, 100.0, 500.0, 300.0);
    assert_eq!(FloatingPanelState::clamp(inside, &screens, bar), inside);
    // Saved on a second display that is gone: moved onto the first one, size kept.
    let gone = Rect::new(3000.0, 100.0, 500.0, 300.0);
    let c = FloatingPanelState::clamp(gone, &screens, bar);
    assert_eq!((c.width, c.height), (gone.width, gone.height));
    assert!(SCREEN.contains_rect(&c));
    // Present second display keeps the frame.
    let two = [SCREEN, Rect::new(1440.0, 0.0, 1920.0, 1080.0)];
    let on_second = Rect::new(2000.0, 100.0, 500.0, 300.0);
    assert_eq!(FloatingPanelState::clamp(on_second, &two, bar), on_second);
    // Larger than the display: shrunk to fit.
    let big = FloatingPanelState::clamp(Rect::new(0.0, 0.0, 5000.0, 4000.0), &screens, bar);
    assert!(SCREEN.contains_rect(&big));
}

#[test]
fn default_frame_fits_panel_minimum() {
    let f = FloatingPanelState::default_frame(
        PanelID::Timeline,
        Rect::new(0.0, 0.0, 100.0, 100.0),
        FloatingPanelState::DEFAULT_OFFSET,
    );
    assert!(f.width >= PanelID::Timeline.min_size().0);
    assert!(f.height >= PanelID::Timeline.min_size().1);
}

#[test]
fn tab_released_outside_window_tears_off() {
    let win = Rect::new(0.0, 0.0, 1000.0, 700.0);
    let m = FloatingPanelState::TEAR_OFF_MARGIN;
    assert!(!FloatingPanelState::is_torn_off(Point::new(500.0, 300.0), win, m));
    assert!(!FloatingPanelState::is_torn_off(Point::new(1005.0, 300.0), win, m)); // inside the margin: still a dock drop
    assert!(FloatingPanelState::is_torn_off(Point::new(1100.0, 300.0), win, m));
    assert!(FloatingPanelState::is_torn_off(Point::new(-200.0, -50.0), win, m));
}

#[test]
fn tear_off_frame_hangs_under_pointer_and_fits_minimum() {
    let f = FloatingPanelState::tear_off_frame(PanelID::Timeline, Point::new(2000.0, 500.0), 28.0);
    assert!(f.width >= PanelID::Timeline.min_size().0);
    assert!(f.height >= PanelID::Timeline.min_size().1 + 28.0);
    // The title bar (top edge) sits under the pointer, horizontally centered.
    assert!((f.rect().mid_x() - 2000.0).abs() < 0.5);
    assert_eq!(f.rect().max_y() - 14.0, 500.0);
}

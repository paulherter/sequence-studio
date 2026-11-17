//! Tests that cross modules: imported key tables, command ids, the shortcuts window and the menu catalog
//! (Swift `ImportedCommandSupportTests`, `MenuCatalogParityTests`, `MonitorViewCommandTests`, `ShortcutTableTests`,
//! `WindowsKeyMapTests`).

use sq_core_project::fcpcommand_table::FCPCommandTable;
use sq_core_project::foreign_keymap::Target;
use sq_core_project::premiere_command_table::PremiereCommandTable;
use sq_core_project::resolve_command_table;
use sq_os::Platform;
use sq_uikit::command_catalog::CommandCatalog;
use sq_uikit::command_map::CommandMap;
use sq_uikit::command_support::CommandSupport;
use sq_uikit::editor_command::{EditorCommand as C, ThumbnailModeChoice, ViewGammaChoice};
use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
use sq_uikit::keyboard_listing::KeyboardListing;
use sq_uikit::localization::SQL10n;
use sq_uikit::menu_spec::EditorMenus;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqmenu_model::SQMenuShortcut;
use std::collections::HashSet;

const IMPORT_EXPORT: [C; 10] = [
    C::ImportTimeline,
    C::ExportEDL,
    C::ExportFCPXML,
    C::ExportFinalCutXML,
    C::ExportOpenTimelineIO,
    C::ImportLottie,
    C::ImportMotionGraphicsTemplate,
    C::ImportPremiereProject,
    C::ImportPremierePresets,
    C::ImportProject,
];

fn maps() -> [CommandMap; 2] {
    [CommandMap::premiere_default(), CommandMap::sq_default()]
}

#[test]
fn every_import_table_command_is_supported() {
    let mut tables: Vec<(&str, Vec<(String, Target)>)> = vec![
        ("FCP", FCPCommandTable::rows().into_iter().collect()),
        ("Premiere", PremiereCommandTable::rows().into_iter().collect()),
        ("Resolve", resolve_command_table::rows().map(|(n, t)| (n.to_string(), t)).collect()),
    ];
    for (table, rows) in tables.drain(..) {
        for (name, target) in rows {
            let Target::Command(id) = target else { continue };
            let Some(c) = C::from_id(&id) else { continue };
            assert!(CommandSupport::is_supported(&c), "{table} {name} -> {id} is not supported");
        }
    }
}

#[test]
fn view_command_ids_round_trip() {
    for v in sq_uikit::editor_command::DisplayViewChoice::ALL {
        let c = C::DisplayView(v);
        assert_eq!(c.id(), format!("displayView.{}", v.raw_value()));
        assert_eq!(C::from_id(&c.id()), Some(c));
    }
    for g in ViewGammaChoice::ALL {
        let c = C::ViewGamma(g);
        assert_eq!(c.id(), format!("viewGamma.{}", g.raw_value()));
        assert_eq!(C::from_id(&c.id()), Some(c));
    }
    for m in ThumbnailModeChoice::ALL {
        let c = C::ThumbnailMode(m);
        assert_eq!(c.id(), format!("thumbnailMode.{}", m.raw_value()));
        assert_eq!(C::from_id(&c.id()), Some(c));
    }
    assert_eq!(C::from_id(&C::ToggleOverlays.id()), Some(C::ToggleOverlays));
}

#[test]
fn shortcuts_window_search() {
    let map = CommandMap::premiere_default();
    let rows = KeyboardListing::window_rows(&map);
    assert!(rows.len() >= map.entries.len());
    assert_eq!(KeyboardListing::filter(&rows, "").len(), rows.len());
    let razor: Vec<_> = KeyboardListing::filter(&rows, "blade").into_iter().map(|r| r.shortcut).collect();
    assert_eq!(razor, ["C"]);
    // Modifier names and symbols both match; every word must hit.
    let redo = |q: &str| KeyboardListing::filter(&rows, q).into_iter().map(|r| r.command).collect::<Vec<_>>();
    assert_eq!(redo("shift cmd z"), ["Redo"]);
    assert_eq!(
        redo(&KeyboardListing::text_for(&KeyBinding::new(Key::Char('z'), KeyModifiers::COMMAND | KeyModifiers::SHIFT))),
        ["Redo"]
    );
    assert!(redo("nonsense words").is_empty());
    assert_eq!(rows.iter().find(|r| r.command == "Add Edit").map(|r| r.scope.as_str()), Some("Timeline"));
}

#[test]
fn portable_menu_glyphs_match_the_modifier_order() {
    let cs = KeyModifiers::COMMAND | KeyModifiers::SHIFT;
    let text = |p| SQMenuShortcut::glyphs_for(p, "k", cs);
    assert_eq!(text(Platform::Mac), "⇧⌘K");
    assert_eq!(text(Platform::Windows), "Ctrl+Shift+K");
    assert_eq!(text(Platform::Linux), "Ctrl+Shift+K");
    assert_eq!(SQMenuShortcut::glyphs("k", cs), text(Platform::current()));
}

#[test]
fn every_menu_command_is_in_the_catalog() {
    let catalog: HashSet<C> = CommandCatalog::all().into_iter().collect();
    for m in EditorMenus::all() {
        for c in m.commands() {
            // Parametrised families are generated; plain commands must be listed by hand.
            if matches!(c, C::SpeedRampPreset(..) | C::SplitScreen(..)) {
                continue;
            }
            assert!(catalog.contains(&c), "{} > {c:?} is missing from CommandCatalog::plain", m.title);
        }
    }
}

#[test]
fn import_export_items_are_file_menu_commands() {
    let file = EditorMenus::file().commands();
    let plain = CommandCatalog::plain();
    for c in IMPORT_EXPORT {
        assert!(file.contains(&c), "{c:?} is not in the File menu");
        assert!(CommandSupport::is_supported(&c), "{c:?} is not wired");
        assert!(EditorMenus::menu_only().contains(&c), "{c:?} has no key, so it is menu only");
        assert!(plain.contains(&c), "{c:?}");
        assert_eq!(C::from_id(&c.id()), Some(c));
    }
}

#[test]
fn audited_commands_have_keys() {
    let keyed = [C::NextKeyframe, C::PreviousKeyframe, C::ToggleLinkedSelection, C::AddVideoTrack, C::AddAudioTrack];
    for m in maps() {
        for c in keyed {
            let b = m.binding_for(&c);
            assert!(b.is_some(), "{c:?} has no key");
            assert!(!EditorMenus::menu_only().contains(&c), "{c:?} has a key and is no longer menu only");
            if let Some(b) = b {
                assert_eq!(m.command_for(&b, Some(PanelID::Timeline)), Some(c));
            }
        }
        let dups: Vec<_> = m.duplicates().iter().map(|e| format!("{:?} {:?}", e.scope, e.command)).collect();
        assert!(dups.is_empty(), "{dups:?}");
    }
}

#[test]
fn track_commands_have_menu_doors() {
    let seq = EditorMenus::sequence().commands();
    assert!(seq.contains(&C::AddVideoTrack) && seq.contains(&C::AddAudioTrack));
    assert!(CommandSupport::is_timeline_op(&C::AddVideoTrack) && CommandSupport::is_timeline_op(&C::AddAudioTrack));
    assert!(seq.contains(&C::PlaceOnTop));
    assert!(CommandMap::premiere_default().binding_for(&C::PlaceOnTop).is_some());
}

#[test]
fn new_commands_have_german_titles() {
    let mut new: Vec<C> = IMPORT_EXPORT.to_vec();
    new.extend([C::AddVideoTrack, C::AddAudioTrack]);
    for c in new {
        let title = c.title();
        assert_ne!(SQL10n::string_in(&title, "de"), title, "{title}");
    }
}

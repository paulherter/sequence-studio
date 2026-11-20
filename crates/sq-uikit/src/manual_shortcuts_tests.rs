//! docs/wiki/shortcuts.md against the default key map (`CommandMap::sq_default`): every row of the manual's tables
//! (Mac key, Windows key, command, panel) must be a binding of the map and the other way round.

use crate::command_map::CommandMap;
use crate::editor_command::CommandScope;
use crate::key_binding_text::KeyBindingText;
use std::collections::BTreeSet;

fn manual() -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/wiki/shortcuts.md");
    std::fs::read_to_string(path).expect("manual")
}

fn scope_of(heading: &str) -> Option<CommandScope> {
    Some(match heading {
        "Everywhere" => CommandScope::Global,
        "Timeline" => CommandScope::Timeline,
        "Program monitor" => CommandScope::Program,
        "Source monitor" => CommandScope::Source,
        "Project panel" => CommandScope::Project,
        _ => return None,
    })
}

/// (scope, mac, windows, command) of every table row of the manual.
fn manual_rows() -> BTreeSet<(String, String, String, String)> {
    let mut rows = BTreeSet::new();
    let mut scope = None;
    for line in manual().lines() {
        if let Some(h) = line.strip_prefix("### ").or_else(|| line.strip_prefix("## ")) {
            scope = scope_of(h.trim());
            continue;
        }
        let (Some(scope), true) = (scope, line.starts_with("| ")) else { continue };
        let cells: Vec<&str> = line.trim_matches('|').split(" | ").map(str::trim).collect();
        if cells.len() != 3 || cells[0] == "Mac" || cells[0].starts_with("---") {
            continue;
        }
        let mac = cells[0].replace(" (Delete)", "");
        rows.insert((format!("{scope:?}"), mac, cells[1].to_string(), cells[2].to_string()));
    }
    rows
}

fn map_rows() -> BTreeSet<(String, String, String, String)> {
    let mut rows = BTreeSet::new();
    // The manual's Mac column is the Mac map, its Windows and Linux column is the Windows map (Quick Apply is Option+Space
    // on the Mac and Ctrl+Space elsewhere).
    let windows_map = CommandMap::sq_default_for(sq_os::Platform::Windows);
    for e in &CommandMap::sq_default_for(sq_os::Platform::Mac).entries {
        // Effect Controls repeats the Timeline's Add Keyframe key; the manual lists it once, under Timeline.
        if e.scope == CommandScope::EffectControls {
            continue;
        }
        let same =
            windows_map.entries.iter().any(|w| w.scope == e.scope && w.binding == e.binding && w.command == e.command);
        let twin = if same {
            e
        } else {
            windows_map
                .entries
                .iter()
                .find(|w| w.scope == e.scope && w.command == e.command && w.binding.key == e.binding.key)
                .unwrap_or(e)
        };
        let windows = KeyBindingText::windows(&twin.binding);
        let mac = KeyBindingText::mac(&e.binding);
        rows.insert((format!("{:?}", e.scope), mac, windows, e.command.title()));
    }
    rows
}

#[test]
fn manual_and_default_map_list_the_same_keys() {
    let (manual, map) = (manual_rows(), map_rows());
    let normalize = |r: &(String, String, String, String)| {
        // "Menu only" stands for a Windows key a Command shortcut already uses.
        let win = if r.2 == "Menu only" { String::new() } else { r.2.clone() };
        (r.0.clone(), r.1.clone(), win, r.3.clone())
    };
    let m: BTreeSet<_> = manual.iter().map(normalize).collect();
    let d: BTreeSet<_> = map.iter().map(|r| (r.0.clone(), r.1.clone(), String::new(), r.3.clone())).collect();
    let m_keys: BTreeSet<_> = m.iter().map(|r| (r.0.clone(), r.1.clone(), r.3.clone())).collect();
    let d_keys: BTreeSet<_> = d.iter().map(|r| (r.0.clone(), r.1.clone(), r.3.clone())).collect();
    let only_manual: Vec<_> = m_keys.difference(&d_keys).collect();
    let only_map: Vec<_> = d_keys.difference(&m_keys).collect();
    // Windows column: wherever the manual gives one it must be the map's text.
    let bad_windows: Vec<_> = manual
        .iter()
        .filter(|r| r.2 != "Menu only")
        .filter(|r| !map.iter().any(|x| x.0 == r.0 && x.1 == r.1 && x.3 == r.3 && x.2 == r.2))
        .collect();
    assert!(
        only_manual.is_empty() && only_map.is_empty() && bad_windows.is_empty(),
        "only in manual: {only_manual:#?}\nonly in map: {only_map:#?}\nwindows differs: {bad_windows:#?}"
    );
}

/// (command title, menu path) of every command in the menu bar that has no key in the default map.
fn unbound_in_menus(menus: &[crate::menu_spec::MenuSpec]) -> BTreeSet<(String, String)> {
    use crate::menu_spec::Item;
    fn walk(path: &str, items: &[Item], bound: &BTreeSet<String>, out: &mut BTreeSet<(String, String)>) {
        for item in items {
            match item {
                Item::Command(c) => {
                    let title = c.title();
                    if !bound.contains(&title) {
                        out.insert((title, path.to_string()));
                    }
                }
                Item::Submenu(name, sub) => walk(&format!("{path} > {name}"), sub, bound, out),
                Item::Separator => {}
            }
        }
    }
    let bound: BTreeSet<String> = CommandMap::sq_default().entries.iter().map(|e| e.command.title()).collect();
    let mut out = BTreeSet::new();
    for menu in menus {
        walk(&menu.title, &menu.items, &bound, &mut out);
    }
    out
}

#[test]
fn manual_lists_the_menu_commands_without_a_key() {
    let mut rows = BTreeSet::new();
    let mut inside = false;
    for line in manual().lines() {
        if let Some(h) = line.strip_prefix("### ").or_else(|| line.strip_prefix("## ")) {
            inside = h.trim() == "Commands without a key by default";
            continue;
        }
        if !inside || !line.starts_with("| ") {
            continue;
        }
        let cells: Vec<&str> = line.trim_matches('|').split(" | ").map(str::trim).collect();
        if cells.len() == 2 && cells[0] != "Command" && !cells[0].starts_with("---") {
            rows.insert((cells[0].to_string(), cells[1].to_string()));
        }
    }
    // The manual names a command by its path in the real menu bar (`visible`, nested); only commands the bar leaves out
    // keep the path of the full catalog (`all`).
    let catalog = unbound_in_menus(crate::menu_spec::EditorMenus::all());
    let shown = unbound_in_menus(crate::menu_spec::EditorMenus::visible());
    let shown_titles: BTreeSet<&str> = shown.iter().map(|r| r.0.as_str()).collect();
    let menus: BTreeSet<_> =
        shown.iter().cloned().chain(catalog.iter().filter(|r| !shown_titles.contains(r.0.as_str())).cloned()).collect();
    // "-" = in no menu (key only); "Window" rows are the panel commands the shell builds, not part of the spec.
    let only_manual: Vec<_> = rows.difference(&menus).filter(|r| r.1 != "-" && !r.1.starts_with("Window")).collect();
    let named: BTreeSet<&str> = rows.iter().map(|r| r.0.as_str()).collect();
    let only_menus: Vec<_> = catalog.iter().filter(|r| !named.contains(r.0.as_str())).collect();
    assert!(
        only_manual.is_empty() && only_menus.is_empty(),
        "only in manual: {only_manual:#?}\nonly in menus: {only_menus:#?}"
    );
}

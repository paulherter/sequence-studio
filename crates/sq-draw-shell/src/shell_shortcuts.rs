// Swift: ShellShortcuts.swift
//! Keyboard Shortcuts, translated from the Mac `KeyboardShortcutsWindowController` (+Sets): the keyboard picture colored by
//! command group, the modifier layer, every command with its shortcut, Set Shortcut (press the keys), Assign to a picked
//! key, Remove, Reset to Defaults, and the template switcher (presets, own sets, import, save, export, rename, delete).
//! Same models: `KeymapConfig` / `KeymapStore` (`sq.keymap`), `KeymapRow`, `Keymap::conflicts` / `assign` / `unbind`,
//! `KeyboardLayout` / `KeyboardLayoutModel`, `KeymapImport` / `ForeignKeymapFile`. Shortcut text and conflict messages name
//! the platform's keys (`KeyBindingText`: Ctrl+Shift+K on Windows).
//!
//! Mapping: the editor is plain state in `ShellHost::shortcuts`; Swift `host.spawn { await ... }` is a [`ShortcutsFlow`]
//! the host starts as [`ShellFlow::Shortcuts`]. The store is `ShellHost::defaults`, `onKeymapChanged` is
//! [`ShellHost::take_keymap_change`]. Final Cut command sets (property lists) need a plist reader that does not exist yet.

use crate::menu_controller::MenuController;
use crate::shell_dialog::ShellDialog;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{ShellCx, ShellFlow, ShellHost};
use sq_core_project::foreign_keymap_formats::ForeignKeymapFile;
use sq_draw::TextFieldControl;
use sq_draw::scroll::ScrollBody;
use sq_editor_session::{KeyboardLayoutModel, KeyboardStyle};
use sq_os::Platform;
use sq_runtime::UiRef;
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::CGRect;
use sq_uikit::editor_command::CommandScope;
use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::key_character_resolver::KeyCharacterResolver;
use sq_uikit::keymap_import::KeymapImport;
use sq_uikit::keymap_store::{ConflictKind, Keymap, KeymapConfig, KeymapPreset, KeymapRow, KeymapSet, KeymapStore};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;

/// A template picked in the switcher.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TemplateChoice {
    /// A built-in key set.
    Preset(KeymapPreset),
    /// One of the user's own sets (its id).
    Custom(String),
}

/// A step of the editor that waits for a dialog or a file chooser (Swift `host.spawn { await self.attempt(...) }`).
#[derive(Clone, Debug, PartialEq)]
pub enum ShortcutsFlow {
    /// Binds the row's command to the binding.
    Attempt(KeymapRow, KeyBinding),
    /// Assign to Key: the selected row to the picked key.
    AssignToKey,
    /// Reset to Defaults.
    ResetAll,
    /// A template from the switcher.
    ChooseTemplate(TemplateChoice),
    /// Import Shortcuts….
    ImportShortcuts,
    /// Save Current as My Set….
    SaveCurrentAsSet,
    /// Export Current Set….
    ExportCurrentSet,
    /// Rename the own set with this id.
    RenameSet(String),
    /// Delete the own set with this id.
    DeleteSet(String),
    /// The layout popup picked a style (sync: the host stores it).
    SetStyle(KeyboardStyle),
}

/// The Keyboard Shortcuts window's state (Swift `ShellShortcutsEditor`).
pub struct ShellShortcutsEditor {
    pub(crate) platform: Platform,
    pub(crate) config: KeymapConfig,
    pub(crate) all_rows: Vec<KeymapRow>,
    /// The rows the search keeps (`listing.shortcut` in the platform's key names).
    pub(crate) rows: Vec<KeymapRow>,
    pub(crate) selected_index: Option<usize>,
    /// The key picked on the picture.
    pub(crate) selected_key: Option<Key>,
    /// The modifier layer the picture shows.
    pub(crate) modifiers: KeyModifiers,
    pub(crate) style: KeyboardStyle,
    /// Set Shortcut waits for a key press.
    pub(crate) capturing: bool,
    pub(crate) info: String,
    pub(crate) search: TextFieldControl,
    pub(crate) scroll_body: ScrollBody,
    /// Popup lists (templates, layout).
    pub(crate) menu: MenuController,
    /// The window, points.
    pub frame: CGRect,
    pub(crate) hover: Option<crate::shell_shortcuts_draw::Hit>,
    pub(crate) pressed: Option<crate::shell_shortcuts_draw::Hit>,
    /// Steps the menu rows and buttons asked for; the host starts them.
    pub(crate) queue: Rc<RefCell<Vec<ShortcutsFlow>>>,
    /// Done, Esc or Return: the host closes the window.
    pub(crate) wants_close: bool,
    /// The config changed: the host saves it and hands the map to the shell.
    pub(crate) commit_pending: bool,
    /// R4e: the Settings pages the sidebar lists (the Shortcuts page is the picked one).
    pub(crate) pages: Vec<crate::shell_preferences::Page>,
    /// R4e: a sidebar page or the search was picked: the host closes the editor and opens Settings there (`true`: search).
    pub(crate) open_page: Option<(crate::shell_preferences::Page, bool)>,
    /// The areas whose list shows every command ("+ N more" was clicked), as indices of `KeyGroup::ALL`.
    pub(crate) expanded: HashSet<usize>,
}

impl ShellShortcutsEditor {
    pub(crate) const IDLE_INFO: &'static str = "Click a key to see what it does.";

    /// An editor over the stored key map and layout style.
    pub fn new(defaults: &dyn sq_uikit::appearance_palette::UiDefaults, platform: Platform) -> ShellShortcutsEditor {
        let mut search = TextFieldControl::new("");
        search.bare = true;
        search.alignment = sq_draw::inspector::text_field_control::Alignment::Left;
        search.font_size = crate::shell_shortcuts_draw::M::F_BODY;
        let mut e = ShellShortcutsEditor {
            platform,
            config: KeymapStore::load(defaults),
            all_rows: Vec::new(),
            rows: Vec::new(),
            selected_index: None,
            selected_key: None,
            modifiers: KeyModifiers::EMPTY,
            style: KeyboardStyle::saved(defaults),
            capturing: false,
            info: Self::IDLE_INFO.to_string(),
            search,
            scroll_body: ScrollBody::new(0.0),
            menu: MenuController::new(),
            frame: CGRect::default(),
            hover: None,
            pressed: None,
            queue: Rc::new(RefCell::new(Vec::new())),
            wants_close: false,
            commit_pending: false,
            pages: crate::shell_preferences::Page::ALL
                .iter()
                .copied()
                .filter(|p| *p != crate::shell_preferences::Page::Advanced)
                .collect(),
            open_page: None,
            expanded: HashSet::new(),
        };
        e.refilter();
        e
    }

    // MARK: Model

    /// The search text, typed or committed.
    pub fn query(&self) -> String {
        self.search.editor().map_or_else(|| self.search.text.clone(), |e| e.string())
    }

    /// The rows the search keeps.
    pub fn rows(&self) -> &[KeymapRow] {
        &self.rows
    }

    /// Every row.
    pub fn all_rows(&self) -> &[KeymapRow] {
        &self.all_rows
    }

    /// The edited key configuration.
    pub fn config(&self) -> &KeymapConfig {
        &self.config
    }

    /// The selected row.
    pub fn selected_row(&self) -> Option<&KeymapRow> {
        self.selected_index.and_then(|i| self.rows.get(i))
    }

    /// The keyboard picture's model.
    pub fn layout_model(&self) -> KeyboardLayoutModel {
        KeyboardLayoutModel::new(self.config.map(), self.modifiers)
    }

    /// How many bindings differ from the key set they started from (what the Shortcuts page counts as changed).
    pub fn changed_bindings(defaults: &dyn sq_uikit::appearance_palette::UiDefaults) -> usize {
        Self::changed_in(&KeymapStore::load(defaults))
    }

    fn changed_in(config: &KeymapConfig) -> usize {
        Keymap::diff(&config.base_map(), &config.map()).len()
    }

    /// The keys of the rows the search keeps; they light up on the keyboard picture. Empty without a search.
    pub(crate) fn found_keys(&self) -> HashSet<Key> {
        if self.query().is_empty() {
            return HashSet::new();
        }
        self.rows.iter().filter_map(|r| r.entry.as_ref().map(|e| e.binding.key)).collect()
    }

    /// "12 shortcuts" or "3 of 12", then "· 2 changed" when bindings differ from the key set.
    pub fn count_text(&self) -> String {
        let base = if self.rows.len() == self.all_rows.len() {
            format!("{} shortcuts", self.rows.len())
        } else {
            format!("{} of {}", self.rows.len(), self.all_rows.len())
        };
        match Self::changed_in(&self.config) {
            0 => base,
            n => format!("{base} · {n} changed"),
        }
    }

    /// Reset to Defaults is available.
    pub fn can_reset(&self) -> bool {
        self.config.is_modified()
    }

    /// The info line under the picture.
    pub fn info(&self) -> &str {
        &self.info
    }

    /// Set Shortcut waits for a key.
    pub fn capturing(&self) -> bool {
        self.capturing
    }

    /// The layout style of the picture.
    pub fn style(&self) -> KeyboardStyle {
        self.style
    }

    pub(crate) fn key_text(&self, b: &KeyBinding) -> String {
        KeyBindingText::text(b, self.platform)
    }

    /// The modifier toggles (`modifierControl`): the Mac's four, on Windows Ctrl / Alt / Shift (Ctrl stands for Command,
    /// which also reaches the Mac Control bindings, `WindowsKeyRoute`).
    pub(crate) fn modifier_choices(&self) -> Vec<(&'static str, KeyModifiers)> {
        if self.platform == Platform::Mac {
            vec![
                ("⌃", KeyModifiers::CONTROL),
                ("⌥", KeyModifiers::OPTION),
                ("⇧", KeyModifiers::SHIFT),
                ("⌘", KeyModifiers::COMMAND),
            ]
        } else {
            vec![("Ctrl", KeyModifiers::COMMAND), ("Alt", KeyModifiers::OPTION), ("Shift", KeyModifiers::SHIFT)]
        }
    }

    /// "Assign to Key" / "Assign to Ctrl+K" (`updateButtons`).
    pub fn assign_title(&self) -> String {
        self.selected_key.map_or_else(
            || "Assign to Key".to_string(),
            |k| format!("Assign to {}", self.key_text(&KeyBinding::new(k, self.modifiers))),
        )
    }

    pub(crate) fn refilter(&mut self) {
        let keep = self.selected_row().cloned();
        let platform = self.platform;
        self.all_rows = KeymapRow::build(&self.config.map())
            .into_iter()
            .map(|mut r| {
                if let Some(e) = &r.entry {
                    r.listing.shortcut = KeyBindingText::text(&e.binding, platform);
                }
                r
            })
            .collect();
        self.rows = KeymapRow::filter(&self.all_rows, &self.query());
        self.selected_index = keep.and_then(|k| {
            self.rows
                .iter()
                .position(|r| r.command == k.command && r.entry == k.entry)
                .or_else(|| self.rows.iter().position(|r| r.command == k.command))
        });
    }

    /// Sets the search text.
    pub fn set_query(&mut self, s: &str) {
        self.search.cancel();
        self.search.text = s.to_string();
        self.query_changed();
    }

    /// `controlTextDidChange`: the list follows the search, the selection goes.
    pub(crate) fn query_changed(&mut self) {
        self.rows = KeymapRow::filter(&self.all_rows, &self.query());
        self.selected_index = None;
        self.scroll_body.assign(0.0);
    }

    /// Selects row `index` of the filtered list.
    pub fn select(&mut self, index: Option<usize>) {
        self.selected_index = index.filter(|i| *i < self.rows.len());
        if let Some(i) = self.selected_index {
            self.scroll_to_row(i);
        }
    }

    /// A key on the picture: its commands in the info line.
    pub fn select_key(&mut self, k: Option<Key>) {
        self.selected_key = k;
        self.info = k.map_or_else(|| Self::IDLE_INFO.to_string(), |k| self.layout_model().summary(k, self.platform));
    }

    /// Toggles a modifier layer of the picture.
    pub fn toggle_modifier(&mut self, m: KeyModifiers) {
        self.modifiers = KeyModifiers(self.modifiers.0 ^ m.0);
        self.select_key(self.selected_key);
    }

    /// `layoutChanged`: saved under `sq.shortcuts.keyboardLayout`, the picked key goes.
    pub fn set_style(&mut self, s: KeyboardStyle, defaults: &mut dyn sq_uikit::appearance_palette::UiDefaults) {
        self.style = s;
        defaults.set_string(KeyboardStyle::DEFAULTS_KEY, s.raw_value());
        self.select_key(None);
    }

    // MARK: Actions

    /// Set Shortcut…: the next key press becomes the row's shortcut; Esc cancels.
    pub fn begin_capture(&mut self) {
        if self.selected_row().is_none() || self.capturing {
            return;
        }
        if self.search.is_editing() {
            let _ = self.search.commit();
        }
        self.capturing = true;
        self.info = "Press the new shortcut (Esc cancels).".to_string();
    }

    pub(crate) fn end_capture(&mut self) {
        self.capturing = false;
        self.select_key(self.selected_key);
    }

    /// The press while capturing (`KeyMapping.keyEvent(from:capture:)` on the Mac).
    pub fn capture(&mut self, k: sq_draw::InputKey, m: sq_draw::InputModifiers) {
        if !self.capturing {
            return;
        }
        if k == sq_draw::InputKey::Escape {
            self.end_capture();
            return;
        }
        let Some(key) = crate::keys::ShellKeys::key(k) else { return };
        let mut mods = KeyModifiers::EMPTY;
        if m.contains(sq_draw::InputModifiers::COMMAND) {
            mods |= KeyModifiers::COMMAND;
        }
        if m.contains(sq_draw::InputModifiers::OPTION) {
            mods |= KeyModifiers::OPTION;
        }
        if m.contains(sq_draw::InputModifiers::SHIFT) {
            mods |= KeyModifiers::SHIFT;
        }
        let row = self.selected_row().cloned();
        self.end_capture();
        if let Some(row) = row {
            self.queue.borrow_mut().push(ShortcutsFlow::Attempt(row, KeyBinding::new(key, mods)));
        }
    }

    /// Remove: the selected binding goes.
    pub fn remove_shortcut(&mut self) {
        let Some(e) = self.selected_row().and_then(|r| r.entry) else { return };
        let map = Keymap::unbind(&e, &self.config.map());
        self.config.set_map(&map);
        self.commit_pending = true;
    }

    // MARK: Templates and own sets (KeyboardShortcutsWindow+Sets)

    /// The rows of the template switcher.
    pub fn template_menu_items(&self) -> Vec<sq_uikit::sqmenu_model::SQMenuItem> {
        use sq_uikit::sqmenu_model::SQMenuItem;
        let row = |title: &str, checked: bool, f: ShortcutsFlow| {
            let mut i = SQMenuItem::new(title);
            i.is_checked = checked;
            let queue = Rc::clone(&self.queue);
            i.action = Some(Rc::new(move || queue.borrow_mut().push(f.clone())));
            i
        };
        let mut items = vec![SQMenuItem::header("Templates")];
        for p in KeymapPreset::ALL {
            items.push(row(
                p.title(),
                self.config.active_set().is_none() && self.config.preset == p,
                ShortcutsFlow::ChooseTemplate(TemplateChoice::Preset(p)),
            ));
        }
        if !self.config.custom_sets.is_empty() {
            items.push(SQMenuItem::separator());
            items.push(SQMenuItem::header("My Sets"));
            for s in &self.config.custom_sets {
                items.push(row(
                    &s.name,
                    self.config.active_set_id.as_deref() == Some(s.id.as_str()),
                    ShortcutsFlow::ChooseTemplate(TemplateChoice::Custom(s.id.clone())),
                ));
            }
        }
        items.push(SQMenuItem::separator());
        items.push(row("Import Shortcuts…", false, ShortcutsFlow::ImportShortcuts));
        items.push(row("Save Current as My Set…", false, ShortcutsFlow::SaveCurrentAsSet));
        items.push(row("Export Current Set…", false, ShortcutsFlow::ExportCurrentSet));
        if let Some(id) = self.config.active_set_id.clone()
            && self.config.active_set().is_some()
        {
            items.push(SQMenuItem::separator());
            let base = self.config.base_title();
            items.push(row(&SQL10n::format("Rename “%@”…", &[&base]), false, ShortcutsFlow::RenameSet(id.clone())));
            items.push(row(&SQL10n::format("Delete “%@”…", &[&base]), false, ShortcutsFlow::DeleteSet(id)));
        }
        items
    }

    /// The rows of the layout popup.
    pub(crate) fn layout_menu_items(&self) -> Vec<sq_uikit::sqmenu_model::SQMenuItem> {
        use sq_uikit::sqmenu_model::SQMenuItem;
        KeyboardStyle::ALL
            .iter()
            .map(|s| {
                let mut i = SQMenuItem::new(&s.title());
                i.is_checked = *s == self.style;
                let (queue, s) = (Rc::clone(&self.queue), *s);
                // The style is applied by the host, which owns the store: the step asks through the queue.
                i.action = Some(Rc::new(move || queue.borrow_mut().push(ShortcutsFlow::SetStyle(s))));
                i
            })
            .collect()
    }
}

impl ShellHost {
    /// Keyboard Shortcuts is up.
    pub fn is_shortcuts_shown(&self) -> bool {
        self.shortcuts.is_some()
    }

    /// The editor, while it is up.
    pub fn shortcuts(&self) -> Option<&ShellShortcutsEditor> {
        self.shortcuts.as_ref()
    }

    /// The editor, mutably.
    pub fn shortcuts_mut(&mut self) -> Option<&mut ShellShortcutsEditor> {
        self.shortcuts.as_mut()
    }

    /// Keyboard Shortcuts (Ctrl+Alt+K): modal over the window; a second call while it shows does nothing.
    pub(crate) fn show_shortcuts(&mut self, _cx: &mut ShellCx) {
        // Modal: another dialog on top keeps the keyboard; a second modal would stack under it. Settings itself jumps to
        // its Shortcuts page (D3): the open Settings dialog is answered Done and the page takes its place, no second window.
        if let Some(d) = self.dialog() {
            if !(d.message_text == "Settings" && d.form.as_ref().is_some_and(|f| f.has_sidebar())) {
                return;
            }
            self.preferences.search.clear();
            self.close_dialog(SQDialogResponse::FIRST);
        }
        self.show_shortcuts_page();
    }

    /// The Shortcuts page of Settings (R4e): the editor in the Settings window's frame, the page list at its left.
    pub fn show_shortcuts_page(&mut self) {
        if self.shortcuts.is_some() {
            return;
        }
        self.settings_card_instant = false;
        self.menu_bar.dismiss();
        let mut e = ShellShortcutsEditor::new(&*self.defaults, Platform::current());
        if self.preferences.edit_api.is_some() || self.flow_env.edit_api.is_some() {
            e.pages = crate::shell_preferences::Page::ALL.to_vec();
        }
        e.frame = CGRect::new(0.0, 0.0, self.size().width, self.size().height);
        self.shortcuts = Some(e);
        self.request_frame();
    }

    /// Closes Keyboard Shortcuts.
    pub fn hide_shortcuts(&mut self) {
        self.shortcuts = None;
        self.request_frame();
    }

    /// A new key map from the Keyboard Shortcuts editor: the menus and the key route use it at once (the bar rebuilds its
    /// menus when one opens), the host's panels through [`ShellHost::take_keymap_change`].
    pub fn apply_keymap(&mut self, m: CommandMap) {
        CommandMap::set_current(m.clone()); // Swift `onKeymapChanged = { CommandMap.current = $0 }`
        self.map = m.clone();
        self.keymap_change = Some(m);
    }

    /// The key map the editor changed since the last call (Swift `onKeymapChanged`).
    pub fn take_keymap_change(&mut self) -> Option<CommandMap> {
        self.keymap_change.take()
    }

    /// Saves to `sq.keymap` and hands the map to the shell (menus, key route) and the host's panels.
    pub(crate) fn shortcuts_commit(&mut self) {
        let Some(mut e) = self.shortcuts.take() else { return };
        KeymapStore::save(&e.config, &mut *self.defaults);
        self.apply_keymap(e.config.map());
        e.commit_pending = false;
        e.refilter();
        e.select_key(e.selected_key);
        self.shortcuts = Some(e);
    }

    /// One event while the editor is up (it is modal).
    pub(crate) fn handle_shortcuts(&mut self, cx: &mut ShellCx, ev: &sq_draw::InputEvent, scale: f32) {
        let now = self.now_seconds();
        let Some(e) = self.shortcuts.as_mut() else { return };
        e.handle(ev, scale, &cx.measure, cx.ui, now);
        let (queued, close, commit) = (e.queue.take(), e.wants_close, e.commit_pending);
        let open = e.open_page.take();
        if commit {
            self.shortcuts_commit();
        }
        for f in queued {
            match f {
                ShortcutsFlow::SetStyle(s) => {
                    if let Some(e) = self.shortcuts.as_mut() {
                        e.set_style(s, &mut *self.defaults);
                    }
                }
                f => self.start_flow(ShellFlow::Shortcuts(f)),
            }
        }
        if close {
            self.hide_shortcuts();
        }
        if let Some((page, search)) = open {
            // The editor stays drawn until the flow presents the Settings card, which then replaces it in the same frame
            // (`ShellHost::present`): no frame shows neither.
            self.settings_card_instant = true;
            self.start_flow(ShellFlow::ShowPreferencesAt(page, search));
        }
    }

    /// Runs a step of the editor.
    pub async fn shortcuts_flow<R: ShellRoot + ?Sized>(h: UiRef<R>, f: ShortcutsFlow) {
        match f {
            ShortcutsFlow::Attempt(row, binding) => Self::shortcut_attempt(&h, &row, binding).await,
            ShortcutsFlow::AssignToKey => {
                let Some(Some((row, binding))) = h.with(|r| {
                    let e = r.shell_parts().shell.shortcuts.as_ref()?;
                    Some((e.selected_row()?.clone(), KeyBinding::new(e.selected_key?, e.modifiers)))
                }) else {
                    return;
                };
                Self::shortcut_attempt(&h, &row, binding).await;
            }
            ShortcutsFlow::ResetAll => Self::shortcuts_reset_all(&h).await,
            ShortcutsFlow::ChooseTemplate(c) => Self::shortcuts_choose_template(&h, c).await,
            ShortcutsFlow::ImportShortcuts => Self::shortcuts_import(h).await,
            ShortcutsFlow::SaveCurrentAsSet => {
                let Some(Some((initial, _))) = h.with(|r| {
                    let e = r.shell_parts().shell.shortcuts.as_ref()?;
                    let initial = if e.config.active_set().is_none() {
                        "My Shortcuts".to_string()
                    } else {
                        format!("{} copy", e.config.base_title())
                    };
                    Some((initial, ()))
                }) else {
                    return;
                };
                let Some(name) = Self::shortcuts_ask_name(&h, "Save Current as My Set", &initial, "Save").await else {
                    return;
                };
                let _ = h.with(|r| {
                    let sh = &mut *r.shell_parts().shell;
                    if let Some(mut e) = sh.shortcuts.take() {
                        let map = e.config.map();
                        e.config.add_set(&name, &map, &mut *sh.ids);
                        sh.shortcuts = Some(e);
                        sh.shortcuts_commit();
                    }
                });
            }
            ShortcutsFlow::RenameSet(id) => {
                let Some(Some(old)) = h.with(|r| {
                    let e = r.shell_parts().shell.shortcuts.as_ref()?;
                    Some(e.config.custom_sets.iter().find(|s| s.id == id)?.name.clone())
                }) else {
                    return;
                };
                let Some(name) = Self::shortcuts_ask_name(&h, "Rename Set", &old, "Rename").await else { return };
                let _ = h.with(|r| {
                    let sh = &mut *r.shell_parts().shell;
                    if let Some(e) = sh.shortcuts.as_mut() {
                        e.config.rename_set(&id, &name);
                    }
                    sh.shortcuts_commit();
                });
            }
            ShortcutsFlow::DeleteSet(id) => {
                let Some(Some(name)) = h.with(|r| {
                    let e = r.shell_parts().shell.shortcuts.as_ref()?;
                    Some(e.config.custom_sets.iter().find(|s| s.id == id)?.name.clone())
                }) else {
                    return;
                };
                if !Self::shortcuts_confirm(
                    &h,
                    &SQL10n::format("Delete “%@”?", &[&name]),
                    "The set is removed. Sequence Studio's own shortcuts come back.",
                    "Delete",
                )
                .await
                {
                    return;
                }
                let _ = h.with(|r| {
                    let sh = &mut *r.shell_parts().shell;
                    if let Some(e) = sh.shortcuts.as_mut() {
                        e.config.delete_set(&id);
                    }
                    sh.shortcuts_commit();
                });
            }
            ShortcutsFlow::ExportCurrentSet => Self::shortcuts_export(h).await,
            ShortcutsFlow::SetStyle(s) => {
                let _ = h.with(|r| {
                    let sh = &mut *r.shell_parts().shell;
                    if let Some(mut e) = sh.shortcuts.take() {
                        e.set_style(s, &mut *sh.defaults);
                        sh.shortcuts = Some(e);
                    }
                });
            }
        }
    }

    /// Binds the row's command to `binding`, in the row's own scope (Everywhere for a command without a key). Same-scope
    /// conflicts and shadowing are shown first; a reserved key is refused.
    pub async fn shortcut_attempt<R: ShellRoot + ?Sized>(h: &UiRef<R>, row: &KeymapRow, binding: KeyBinding) {
        let scope = row.entry.map_or(CommandScope::Global, |e| e.scope);
        let Some(Some((map, platform))) =
            h.with(|r| r.shell_parts().shell.shortcuts.as_ref().map(|e| (e.config.map(), e.platform)))
        else {
            return;
        };
        let conflicts = Keymap::conflicts(&row.command, &binding, scope, &map);
        if conflicts.iter().any(|c| c.kind == ConflictKind::Reserved) {
            let d = ShellDialog::new("That shortcut is not available", &conflicts[0].message(&binding, platform));
            let _ = Self::ask(h, d).await;
            return;
        }
        if !conflicts.is_empty() {
            let hard = conflicts.iter().any(|c| c.kind == ConflictKind::SameScope);
            let lines: Vec<String> = conflicts.iter().map(|c| c.message(&binding, platform)).collect();
            let mut d = ShellDialog::new(
                if hard { "Replace the existing shortcut?" } else { "This shortcut overlaps another one" },
                &(lines.join("\n")
                    + &if hard {
                        format!("\n\n{}", SQL10n::string("The other command loses this key."))
                    } else {
                        String::new()
                    }),
            );
            d.add_button(if hard { "Replace" } else { "Assign Anyway" }, SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            if Self::ask(h, d).await != Some(SQDialogResponse::FIRST) {
                return;
            }
        }
        let Some(new) = Keymap::assign(&row.command, binding, scope, &map, row.entry.as_ref()) else { return };
        let _ = h.with(|r| {
            let sh = &mut *r.shell_parts().shell;
            if let Some(e) = sh.shortcuts.as_mut() {
                e.config.set_map(&new);
            }
            sh.shortcuts_commit();
        });
    }

    async fn shortcuts_reset_all<R: ShellRoot + ?Sized>(h: &UiRef<R>) {
        let Some(Some(title)) = h.with(|r| {
            let e = r.shell_parts().shell.shortcuts.as_ref()?;
            e.config.is_modified().then(|| e.config.base_title())
        }) else {
            return;
        };
        let mut d = ShellDialog::new(
            &SQL10n::format("Reset all shortcuts to the %@ defaults?", &[&title]),
            &SQL10n::format("Every shortcut you changed on top of “%@” goes back.", &[&title]),
        );
        d.add_button("Reset", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        if Self::ask(h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let sh = &mut *r.shell_parts().shell;
            if let Some(e) = sh.shortcuts.as_mut() {
                e.config.reset_overrides();
            }
            sh.shortcuts_commit();
        });
    }

    async fn shortcuts_choose_template<R: ShellRoot + ?Sized>(h: &UiRef<R>, choice: TemplateChoice) {
        let Some(Some((title, modified, base))) = h.with(|r| {
            let c = &r.shell_parts().shell.shortcuts.as_ref()?.config;
            let title = match &choice {
                TemplateChoice::Preset(p) => {
                    if c.active_set().is_none() && c.preset == *p {
                        return None;
                    }
                    p.title().to_string()
                }
                TemplateChoice::Custom(id) => {
                    if c.active_set_id.as_deref() == Some(id.as_str()) {
                        return None;
                    }
                    c.custom_sets.iter().find(|s| &s.id == id).map_or_else(|| "this".to_string(), |s| s.name.clone())
                }
            };
            Some((title, c.is_modified(), c.base_title()))
        }) else {
            return;
        };
        // Own shortcuts on top of the current template are lost on a switch: ask first.
        if modified
            && !Self::shortcuts_confirm(
                h,
                &SQL10n::format("Switch to “%@”?", &[&title]),
                &SQL10n::format(
                    "Your own changes on top of “%@” are removed. Use Save Current as My Set first to keep them.",
                    &[&base],
                ),
                "Switch",
            )
            .await
        {
            return;
        }
        let _ = h.with(|r| {
            let sh = &mut *r.shell_parts().shell;
            if let Some(e) = sh.shortcuts.as_mut() {
                match &choice {
                    TemplateChoice::Preset(p) => e.config.switch_preset(*p),
                    TemplateChoice::Custom(id) => e.config.switch_to_set(id),
                }
            }
            sh.shortcuts_commit();
        });
    }

    async fn shortcuts_import<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(ask) = h.with(|r| r.shell_parts().files.choose_shortcut_file()) else { return };
        let Some(url) = ask.await else { return };
        Self::shortcuts_import_from(h, url).await;
    }

    /// Imports the key set in `url`: our own `.sqkeys`, or a Premiere, Resolve or Final Cut file.
    pub async fn shortcuts_import_from<R: ShellRoot + ?Sized>(h: UiRef<R>, url: std::path::PathBuf) {
        let Ok(data) = std::fs::read(&url) else {
            Self::shortcuts_notify(
                &h,
                "Could not read that file",
                "Check that the file still exists and that you may open it.",
            )
            .await;
            return;
        };
        let name = url.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let Some(exported) = h.with(|r| KeymapSet::from_exported(&data, &mut *r.shell_parts().shell.ids)) else {
            return;
        };
        if let Some(set) = exported {
            let count = set.map().entries.iter().map(|e| e.command).collect::<HashSet<_>>().len();
            if !Self::shortcuts_confirm(
                &h,
                &format!("Import “{}”?", set.name),
                &format!("{count} commands with shortcuts. It is added to My Sets."),
                "Add Set",
            )
            .await
            {
                return;
            }
            let _ = h.with(|r| {
                let sh = &mut *r.shell_parts().shell;
                if let Some(e) = sh.shortcuts.as_mut() {
                    e.config.add_loaded_set(&set);
                }
                sh.shortcuts_commit();
            });
            return;
        }
        let plist = sq_core_project::plist_reader::parse_plist(&data);
        let Ok(file) = ForeignKeymapFile::read(&data, plist.as_ref()) else {
            Self::shortcuts_notify(
                &h,
                "That is not a shortcut file we know",
                "Premiere Pro keyboard layouts (.kys), DaVinci Resolve keyboard layouts, Final Cut Pro command sets \
                 (.commandset) and Sequence Studio sets (.sqkeys) can be imported.",
            )
            .await;
            return;
        };
        let result = KeymapImport::build(
            &file.commands,
            &CommandMap::sq_default(),
            &file.format.table(),
            &KeyCharacterResolver::current_layout(),
        );
        if result.imported_commands == 0 {
            Self::shortcuts_notify(
                &h,
                "Nothing to import",
                &format!("None of the commands in this file exist in Sequence Studio. {}.", result.summary()),
            )
            .await;
            return;
        }
        if !Self::shortcuts_show_import_result(&h, &result, &name).await {
            return;
        }
        let _ = h.with(|r| {
            let sh = &mut *r.shell_parts().shell;
            if let Some(e) = sh.shortcuts.as_mut() {
                e.config.add_set(&name, &result.map, &mut *sh.ids);
            }
            sh.shortcuts_commit();
        });
    }

    /// "N imported, M have no equivalent", then the names (`KeymapImportResultDialog`). True when the user keeps the set.
    async fn shortcuts_show_import_result<R: ShellRoot + ?Sized>(h: &UiRef<R>, r: &KeymapImport, name: &str) -> bool {
        let mut d = ShellDialog::new(
            &r.summary(),
            &format!(
                "“{name}” is saved as one of your own sets. Commands it does not mention keep their Sequence Studio keys."
            ),
        );
        d.width = 480.0;
        let mut rows: Vec<Row> = Vec::new();
        let mut section = |title: String, lines: Vec<String>| {
            if lines.is_empty() {
                return;
            }
            // The first 8 lines of each section, as in Swift `ShellShortcuts` (no scrolling text block on the canvas).
            let mut shown = lines.iter().take(8).cloned().collect::<Vec<_>>().join("\n");
            if lines.len() > 8 {
                shown += &format!("\n… {} more", lines.len() - 8);
            }
            rows.extend([Row::Text(title), Row::Text(shown), Row::Gap(6.0)]);
        };
        section(
            format!("No equivalent in Sequence Studio ({})", r.unmapped.len()),
            r.unmapped.iter().map(KeymapImport::title_of).collect(),
        );
        section("Changed keys".to_string(), r.conflicts().iter().map(|n| n.message.clone()).collect());
        section("Not imported".to_string(), r.skipped_keys().iter().map(|n| n.message.clone()).collect());
        if !rows.is_empty() {
            d.form = Some(Box::new(ShellForm::new(rows)));
        }
        d.add_button("Save as Set", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        Self::ask(h, d).await == Some(SQDialogResponse::FIRST)
    }

    async fn shortcuts_export<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((set, ask))) = h.with(|r| {
            let p = r.shell_parts();
            let set = p.shell.shortcuts.as_ref()?.config.current_as_set(None, &mut *p.shell.ids);
            let suggested = format!("{}.{}", set.name, KeymapSet::FILE_EXTENSION);
            Some((set, p.files.choose_shortcut_export_location(&suggested)))
        }) else {
            return;
        };
        let Some(url) = ask.await else { return };
        if let Err(e) = std::fs::write(&url, set.export_data()) {
            Self::shortcuts_notify(&h, "Could not save the file", &SQL10n::error_text(&e)).await;
        }
    }

    async fn shortcuts_ask_name<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        title: &str,
        initial: &str,
        button: &str,
    ) -> Option<String> {
        let mut d = ShellDialog::new(title, "");
        d.form = Some(Box::new(ShellForm::new(vec![Row::field("name", "Name", initial)])));
        d.add_button(button, SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        if Self::ask(h, d).await? != SQDialogResponse::FIRST {
            return None;
        }
        let mut form = h.with(|r| r.shell_parts().shell.take_answered_form())??;
        form.commit_editing();
        form.text("name")
    }

    async fn shortcuts_notify<R: ShellRoot + ?Sized>(h: &UiRef<R>, title: &str, text: &str) {
        let _ = Self::ask(h, ShellDialog::new(title, text)).await;
    }

    async fn shortcuts_confirm<R: ShellRoot + ?Sized>(h: &UiRef<R>, title: &str, text: &str, button: &str) -> bool {
        let mut d = ShellDialog::new(title, text);
        d.add_button(button, SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        Self::ask(h, d).await == Some(SQDialogResponse::FIRST)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell_live::test_rig::answer_swept;
    use crate::tests::Rig;
    use sq_draw::{InputEvent, InputKey, InputModifiers};
    use sq_uikit::controls_grid::CGPoint;
    use sq_uikit::editor_command::EditorCommand;

    /// The keyboard picture names the logo key by platform: Super on Linux, Win on Windows, a symbol on the Mac.
    #[test]
    fn leaving_the_shortcuts_page_for_another_page_never_shows_neither_card() {
        let rig = rig(Platform::Mac);
        with_editor(&rig, |e| e.open_page = Some((crate::shell_preferences::Page::General, false)));
        rig.cx(|h, cx| h.handle(cx, &sq_draw::InputEvent::MouseMoved { x: 0.0, y: 0.0 }, 1.0));
        // Between the click and the card the editor still shows: no frame has neither.
        assert!(rig.with(|r| r.shell.shortcuts.is_some() && r.shell.dialog().is_none()));
        assert!(rig.with(|r| r.shell.settings_card_instant), "the card of the next page appears at once");
        rig.run_flows();
        rig.with(|r| {
            assert!(r.shell.dialog().is_some_and(|d| d.message_text == "Settings"), "the Settings card is up");
            assert!(r.shell.shortcuts.is_none(), "the editor went in the same step the card came");
        });
    }

    #[test]
    fn the_keyboard_picture_names_the_logo_key_by_platform() {
        let labels = |p| editor(p).caps().into_iter().map(|c| c.label).collect::<Vec<_>>();
        let (linux, windows, mac) = (labels(Platform::Linux), labels(Platform::Windows), labels(Platform::Mac));
        assert!(linux.contains(&"Super".to_string()) && !linux.contains(&"Win".to_string()));
        assert!(windows.contains(&"Win".to_string()) && !windows.contains(&"Super".to_string()));
        assert!(mac.contains(&"⌃".to_string()));
    }

    fn editor(platform: Platform) -> ShellShortcutsEditor {
        let mut e = ShellShortcutsEditor::new(&crate::ShellDefaults::default(), platform);
        e.frame = CGRect::new(0.0, 0.0, 1280.0, 800.0);
        e
    }

    /// A rig whose shell shows Keyboard Shortcuts as `platform`.
    fn rig(platform: Platform) -> Rig {
        let rig = Rig::new();
        rig.with(|r| {
            r.shell.set_size(sq_uikit::controls_grid::CGSize::new(1280.0, 800.0));
            r.shell.shortcuts = Some(editor(platform));
        });
        rig
    }

    fn with_editor<T>(rig: &Rig, f: impl FnOnce(&mut ShellShortcutsEditor) -> T) -> T {
        rig.with(|r| f(r.shell.shortcuts_mut().expect("editor")))
    }

    fn row(e: &mut ShellShortcutsEditor, c: EditorCommand) -> Option<usize> {
        e.set_query(&c.title());
        e.rows.iter().position(|r| r.command == c && r.entry.is_some())
    }

    fn bindings(m: &CommandMap, c: EditorCommand) -> Vec<KeyBinding> {
        m.entries.iter().filter(|e| e.command == c).map(|e| e.binding).collect()
    }

    fn all_mods() -> KeyModifiers {
        KeyModifiers::COMMAND | KeyModifiers::OPTION | KeyModifiers::SHIFT
    }

    /// A Ctrl+Alt+Shift letter no command uses in the default map.
    fn free_letter(e: &ShellShortcutsEditor) -> char {
        "jqyubnmpgh"
            .chars()
            .find(|ch| {
                Keymap::conflicts(
                    &EditorCommand::Undo,
                    &KeyBinding::new(Key::Char(*ch), all_mods()),
                    CommandScope::Global,
                    &e.config.map(),
                )
                .is_empty()
            })
            .expect("a free letter")
    }

    fn key_down(rig: &Rig, key: InputKey, modifiers: InputModifiers) {
        rig.cx(|h, cx| h.handle(cx, &InputEvent::KeyDown { key, modifiers }, 1.0));
    }

    #[test]
    fn the_editor_sits_in_the_settings_frame_with_the_page_list_and_the_pages_open_settings() {
        let rig = rig(Platform::Mac);
        let m = sq_draw::TextMeasure::new(None, 1.0);
        let (side, search, card) = with_editor(&rig, |e| {
            let p = e.parts(&m);
            (p.side.clone(), p.side_search, p.card)
        });
        assert_eq!((card.width, card.height), (900.0, 640.0), "the Settings window's size on every page");
        assert_eq!(side.len(), 6, "General to Shortcuts");
        assert!(search.max_y() <= side[0].min_y());
        // the Shortcuts entry itself stays; General asks for Settings on that page, the search for its search field
        with_editor(&rig, |e| {
            e.press(crate::shell_shortcuts_draw::Hit::Side(5), &m);
            assert!(e.open_page.is_none());
            e.press(crate::shell_shortcuts_draw::Hit::Side(0), &m);
            assert_eq!(e.open_page.take(), Some((crate::shell_preferences::Page::General, false)));
            e.press(crate::shell_shortcuts_draw::Hit::SideSearch, &m);
            assert_eq!(e.open_page.take(), Some((crate::shell_preferences::Page::General, true)));
        });
    }

    /// Windows: the search showed "Ide" for "blade". Each letter arrives as a key press with the layout's text.
    #[test]
    fn typing_in_the_search_keeps_every_letter_in_order() {
        let rig = rig(Platform::Windows);
        for ch in "blade".chars() {
            rig.cx(|h, cx| {
                cx.ui.typed_text = Some(ch.to_string());
                h.handle(
                    cx,
                    &InputEvent::KeyDown { key: InputKey::Character(ch), modifiers: InputModifiers::NONE },
                    1.0,
                );
                cx.ui.typed_text = None;
            });
        }
        assert_eq!(with_editor(&rig, |e| e.query()), "blade");
    }

    #[test]
    fn the_shortcuts_page_keeps_the_settings_size_in_a_tall_window() {
        let m = sq_draw::TextMeasure::new(None, 1.0);
        let mut e = editor(Platform::Mac);
        e.frame = CGRect::new(0.0, 0.0, 1440.0, 1400.0);
        assert_eq!((e.parts(&m).card.width, e.parts(&m).card.height), (900.0, 640.0));
    }

    /// Review: at 640 x 400 the page keeps its section sidebar (search and every page row) inside the card and the window,
    /// and the main column keeps room beside it.
    #[test]
    fn the_shortcuts_page_keeps_its_sidebar_at_640_by_400() {
        let m = sq_draw::TextMeasure::new(None, 1.0);
        let mut e = editor(Platform::Mac);
        e.frame = CGRect::new(0.0, 0.0, 640.0, 400.0);
        let p = e.parts(&m);
        let window = e.frame;
        assert!(
            p.card.min_x() >= 0.0 && p.card.max_x() <= window.max_x() && p.card.max_y() <= window.max_y(),
            "{:?}",
            p.card
        );
        assert!(!p.side.is_empty());
        for r in p.side.iter().chain(std::iter::once(&p.side_search)) {
            assert!(r.width > 100.0 && r.min_x() >= p.card.min_x() && r.max_x() <= p.main.min_x(), "{r:?}");
            assert!(r.min_y() >= p.card.min_y() && r.max_y() <= p.card.max_y(), "{r:?} leaves the card");
        }
        assert!(p.main.width >= 370.0 && p.width >= 300.0, "main {:?} content {}", p.main, p.width);
    }

    #[test]
    fn a_search_lights_the_keys_of_its_hits_and_the_count_names_changed_bindings() {
        let mut e = editor(Platform::Mac);
        assert!(e.found_keys().is_empty(), "no search, nothing lit");
        e.set_query("undo");
        let lit = e.found_keys();
        assert!(!lit.is_empty() && lit.contains(&Key::Char('z')), "{lit:?}");
        assert_eq!(e.count_text().split(" · ").count(), 1);
        e.set_query("");
        let i = row(&mut e, EditorCommand::Undo).expect("undo row");
        e.select(Some(i));
        e.remove_shortcut();
        assert!(e.count_text().ends_with("· 1 changed"), "{}", e.count_text());
        let mut d = crate::shell_settings::MemoryDefaults::default();
        assert_eq!(ShellShortcutsEditor::changed_bindings(&d), 0);
        KeymapStore::save(&e.config, &mut d);
        assert_eq!(ShellShortcutsEditor::changed_bindings(&d), 1);
    }

    #[test]
    fn windows_list_names_ctrl_keys_and_filters() {
        let mut e = editor(Platform::Windows);
        let all = e.all_rows.len();
        assert_eq!(e.count_text(), format!("{all} shortcuts"));
        let i = row(&mut e, EditorCommand::Undo).expect("undo row");
        assert_eq!(e.rows[i].listing.shortcut, "Ctrl+Z");
        assert_eq!(e.count_text(), format!("{} of {all}", e.rows.len()));
        e.set_query("zzzz-no-command");
        assert!(e.rows.is_empty());
        let mut mac = editor(Platform::Mac);
        let j = row(&mut mac, EditorCommand::Undo).expect("undo row");
        assert_eq!(mac.rows[j].listing.shortcut, "⌘Z");
    }

    #[test]
    fn picked_key_shows_its_commands_and_the_assign_title() {
        let mut e = editor(Platform::Windows);
        e.toggle_modifier(KeyModifiers::COMMAND);
        e.select_key(Some(Key::Char('z')));
        assert_eq!(e.assign_title(), "Assign to Ctrl+Z");
        assert!(e.info.contains("Undo"));
        e.select_key(None);
        assert_eq!(e.info, ShellShortcutsEditor::IDLE_INFO);
    }

    #[test]
    fn captured_key_is_saved_and_reaches_the_menus() {
        let rig = rig(Platform::Windows);
        let (ch, undo) = with_editor(&rig, |e| {
            let i = row(e, EditorCommand::Undo).expect("undo row");
            e.select(Some(i));
            e.begin_capture();
            (free_letter(e), i)
        });
        let _ = undo;
        assert!(with_editor(&rig, |e| e.capturing));
        key_down(
            &rig,
            InputKey::Character(ch),
            InputModifiers::COMMAND | InputModifiers::OPTION | InputModifiers::SHIFT,
        );
        assert!(!with_editor(&rig, |e| e.capturing));
        rig.run_flows();
        let b = KeyBinding::new(Key::Char(ch), all_mods());
        assert!(bindings(&rig.with(|r| r.shell.map.clone()), EditorCommand::Undo).contains(&b));
        let told = rig.with(|r| r.shell.take_keymap_change()).expect("told the panels");
        assert_eq!(told.entries, rig.with(|r| r.shell.map.entries.clone()));
        assert!(with_editor(&rig, |e| e.can_reset()));
        // Saved under sq.keymap: a new editor reads it back.
        let again = rig.with(|r| ShellShortcutsEditor::new(&*r.shell.defaults, Platform::Windows));
        assert!(bindings(&again.config.map(), EditorCommand::Undo).contains(&b));
    }

    #[test]
    fn esc_cancels_capture_without_a_change() {
        let rig = rig(Platform::Windows);
        with_editor(&rig, |e| {
            let i = row(e, EditorCommand::Undo);
            e.select(i);
            e.begin_capture();
        });
        let before = rig.with(|r| r.shell.map.entries.clone());
        key_down(&rig, InputKey::Escape, InputModifiers::NONE);
        assert!(!with_editor(&rig, |e| e.capturing));
        assert_eq!(rig.with(|r| r.shell.map.entries.clone()), before);
        assert!(rig.with(|r| r.shell.is_shortcuts_shown()));
        key_down(&rig, InputKey::Escape, InputModifiers::NONE);
        assert!(!rig.with(|r| r.shell.is_shortcuts_shown()));
    }

    fn undo_row(rig: &Rig) -> KeymapRow {
        with_editor(rig, |e| {
            let i = row(e, EditorCommand::Undo).expect("undo row");
            e.rows[i].clone()
        })
    }

    #[test]
    fn a_taken_key_asks_before_replacing() {
        let rig = rig(Platform::Windows);
        let redo = KeyBinding::new(Key::Char('z'), KeyModifiers::COMMAND | KeyModifiers::SHIFT);
        let undo = undo_row(&rig);
        rig.with(|r| r.shell.start_flow(ShellFlow::Shortcuts(ShortcutsFlow::Attempt(undo, redo))));
        rig.run_flows();
        let (title, detail) = rig.with(|r| {
            let d = r.shell.dialog().expect("dialog");
            (d.message_text.clone(), d.informative_text.clone())
        });
        assert_eq!(title, "Replace the existing shortcut?");
        assert!(detail.contains("Ctrl+Shift+Z"));
        answer_swept(&rig, SQDialogResponse::FIRST);
        let map = rig.with(|r| r.shell.map.clone());
        assert!(bindings(&map, EditorCommand::Undo).contains(&redo));
        assert!(!bindings(&map, EditorCommand::Redo).contains(&redo));
    }

    #[test]
    fn a_canceled_conflict_changes_nothing() {
        let rig = rig(Platform::Windows);
        let before = rig.with(|r| r.shell.map.entries.clone());
        let undo = undo_row(&rig);
        let redo = KeyBinding::new(Key::Char('z'), KeyModifiers::COMMAND | KeyModifiers::SHIFT);
        rig.with(|r| r.shell.start_flow(ShellFlow::Shortcuts(ShortcutsFlow::Attempt(undo, redo))));
        rig.run_flows();
        answer_swept(&rig, SQDialogResponse::SECOND);
        assert_eq!(rig.with(|r| r.shell.map.entries.clone()), before);
        assert!(!with_editor(&rig, |e| e.can_reset()));
    }

    #[test]
    fn remove_then_reset_brings_the_default_back() {
        let rig = rig(Platform::Windows);
        let handled = with_editor(&rig, |e| {
            let i = row(e, EditorCommand::Undo);
            e.select(i);
            e.remove_shortcut();
            e.commit_pending
        });
        assert!(handled);
        rig.cx(|h, _| h.shortcuts_commit());
        assert!(bindings(&rig.with(|r| r.shell.map.clone()), EditorCommand::Undo).is_empty());
        assert!(with_editor(&rig, |e| e.can_reset()));
        rig.with(|r| r.shell.start_flow(ShellFlow::Shortcuts(ShortcutsFlow::ResetAll)));
        rig.run_flows();
        answer_swept(&rig, SQDialogResponse::FIRST);
        assert_eq!(
            bindings(&rig.with(|r| r.shell.map.clone()), EditorCommand::Undo),
            [KeyBinding::new(Key::Char('z'), KeyModifiers::COMMAND)]
        );
        assert!(!with_editor(&rig, |e| e.can_reset()));
    }

    #[test]
    fn the_layout_style_is_remembered() {
        let mut d = crate::ShellDefaults::default();
        let mut e = ShellShortcutsEditor::new(&d, Platform::Windows);
        let other = KeyboardStyle::ALL.into_iter().find(|s| *s != e.style).expect("another style");
        e.set_style(other, &mut d);
        assert_eq!(ShellShortcutsEditor::new(&d, Platform::Windows).style, other);
    }

    fn start(rig: &Rig, f: ShortcutsFlow) {
        rig.with(|r| r.shell.start_flow(ShellFlow::Shortcuts(f)));
        rig.run_flows();
    }

    fn dialog_title(rig: &Rig) -> String {
        rig.with(|r| r.shell.dialog().expect("dialog").message_text.clone())
    }

    fn map_of(rig: &Rig) -> Vec<sq_uikit::command_map::Entry> {
        rig.with(|r| r.shell.map.entries.clone())
    }

    #[test]
    fn reserved_keys_cannot_be_assigned() {
        // Swift KeymapStore.swift `Keymap.reserved`: Cmd-H, Opt-Cmd-H, Shift-Cmd-H, Cmd-Q, Cmd-W.
        let c = KeyModifiers::COMMAND;
        let expected = [
            KeyBinding::new(Key::Char('h'), c),
            KeyBinding::new(Key::Char('h'), c | KeyModifiers::OPTION),
            KeyBinding::new(Key::Char('h'), c | KeyModifiers::SHIFT),
            KeyBinding::new(Key::Char('q'), c),
            KeyBinding::new(Key::Char('w'), c),
        ];
        for b in expected {
            assert!(Keymap::is_reserved(&b), "{b:?}");
            let rig = rig(Platform::Mac);
            let before = map_of(&rig);
            let undo = undo_row(&rig);
            start(&rig, ShortcutsFlow::Attempt(undo, b));
            assert_eq!(dialog_title(&rig), "That shortcut is not available");
            let detail = rig.with(|r| r.shell.dialog().expect("dialog").informative_text.clone());
            assert!(detail.contains("reserved"), "{detail}");
            answer_swept(&rig, SQDialogResponse::FIRST);
            assert_eq!(map_of(&rig), before, "{b:?} stays unassigned");
            assert!(!with_editor(&rig, |e| e.can_reset()));
        }
    }

    #[test]
    fn an_overlap_in_another_scope_asks_assign_anyway() {
        // A key that only shadows (no same-scope owner) offers "Assign Anyway", not "Replace".
        let rig = rig(Platform::Mac);
        let map = rig.with(|r| r.shell.map.clone());
        let b = map
            .entries
            .iter()
            .find(|e| e.scope != CommandScope::Global && !bindings(&map, EditorCommand::Undo).contains(&e.binding))
            .map(|e| e.binding)
            .expect("a panel-scoped key");
        let conflicts = Keymap::conflicts(&EditorCommand::Undo, &b, CommandScope::Global, &map);
        assert!(conflicts.iter().all(|c| c.kind != ConflictKind::SameScope && c.kind != ConflictKind::Reserved));
        start(&rig, ShortcutsFlow::Attempt(undo_row(&rig), b));
        assert_eq!(dialog_title(&rig), "This shortcut overlaps another one");
        let labels = rig.with(|r| {
            r.shell.dialog().expect("dialog").model.buttons.iter().map(|b| b.title.clone()).collect::<Vec<_>>()
        });
        assert_eq!(labels, ["Assign Anyway", "Cancel"]);
        answer_swept(&rig, SQDialogResponse::FIRST);
        assert!(bindings(&rig.with(|r| r.shell.map.clone()), EditorCommand::Undo).contains(&b), "assigned anyway");
    }

    #[test]
    fn the_templates_switch_the_whole_map_and_are_saved() {
        // Swift KeymapPreset: sq "Sequence Studio", premiere "Classic NLE", finalCut "Final Cut style".
        assert_eq!(KeymapPreset::Premiere.title(), "Classic NLE");
        assert_eq!(KeymapPreset::FinalCut.title(), "Final Cut style");
        let rig = rig(Platform::Mac);
        let sq = CommandMap::sq_default().entries;
        for (p, want) in [
            (KeymapPreset::Premiere, CommandMap::premiere_default()),
            (KeymapPreset::FinalCut, CommandMap::final_cut_default()),
        ] {
            start(&rig, ShortcutsFlow::ChooseTemplate(TemplateChoice::Preset(p)));
            assert_eq!(map_of(&rig), want.entries, "{p:?}");
            assert_ne!(map_of(&rig), sq, "{p:?} differs from the default set");
            let again = rig.with(|r| ShellShortcutsEditor::new(&*r.shell.defaults, Platform::Mac));
            assert_eq!(again.config.preset, p, "saved under sq.keymap");
        }
    }

    fn temp_file(name: &str, data: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-keys-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let p = dir.join(name);
        std::fs::write(&p, data).expect("write");
        p
    }

    /// Imports `file` through Import Shortcuts, answers the result dialog with `FIRST`, returns the set's PlayPause keys.
    fn import_play_pause(file: std::path::PathBuf, set_name: &str) -> Vec<Key> {
        let rig = rig(Platform::Mac);
        rig.with(|r| r.files.shortcut_file = Some(file));
        start(&rig, ShortcutsFlow::ImportShortcuts);
        answer_swept(&rig, SQDialogResponse::FIRST);
        let (name, active, keys) = with_editor(&rig, |e| {
            let c = &e.config;
            (c.base_title(), c.active_set().is_some(), bindings(&c.map(), EditorCommand::PlayPause))
        });
        assert_eq!(name, set_name);
        assert!(active, "the imported set is the template in use");
        assert!(rig.with(|r| r.shell.dialog().is_none()), "no dialog left");
        assert_eq!(rig.with(|r| r.shell.map.entries.clone()), with_editor(&rig, |e| e.config.map().entries));
        let again = rig.with(|r| ShellShortcutsEditor::new(&*r.shell.defaults, Platform::Mac));
        assert_eq!(again.config.base_title(), set_name, "saved under sq.keymap");
        keys.into_iter().map(|b| b.key).collect()
    }

    #[test]
    fn importing_a_premiere_kys_through_the_window() {
        let kys = "<?xml version=\"1.0\"?><PremiereData Version=\"3\"><shortcuts Version=\"5\"><context.global>\
            <item.0><virtualkey>2147483705</virtualkey><commandname>cmd.transport.toggleplay</commandname></item.0>\
            </context.global></shortcuts></PremiereData>";
        let f = temp_file("Studio Layout.kys", kys.as_bytes());
        assert_eq!(import_play_pause(f, "Studio Layout"), [Key::Char('9')]);
    }

    #[test]
    fn importing_a_resolve_layout_through_the_window() {
        let f = temp_file("Edit Page.preset", b"controlPlayToggle := Ctrl+Alt+9\n");
        assert_eq!(import_play_pause(f, "Edit Page"), [Key::Char('9')]);
    }

    #[test]
    fn importing_a_final_cut_commandset_through_the_window() {
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>PlayPause</key><dict>\
            <key>character</key><string>9</string><key>characterString</key><string>9</string>\
            <key>modifiers</key><string>command</string></dict></dict></plist>";
        let f = temp_file("My Commands.commandset", plist.as_bytes());
        assert_eq!(import_play_pause(f, "My Commands"), [Key::Char('9')]);
    }

    #[test]
    fn importing_an_sqkeys_file_through_the_window() {
        // Export the default map as a set, then import the file: "Import “…”?" with Add Set.
        let rig0 = rig(Platform::Mac);
        let data = rig0.with(|r| {
            let e = ShellShortcutsEditor::new(&*r.shell.defaults, Platform::Mac);
            e.config.current_as_set(Some("Mine"), &mut *r.shell.ids).export_data()
        });
        let f = temp_file("Mine.sqkeys", &data);
        let rig = rig(Platform::Mac);
        rig.with(|r| r.files.shortcut_file = Some(f));
        start(&rig, ShortcutsFlow::ImportShortcuts);
        assert_eq!(dialog_title(&rig), "Import “Mine”?");
        answer_swept(&rig, SQDialogResponse::FIRST);
        assert_eq!(with_editor(&rig, |e| e.config.base_title()), "Mine");
        assert_eq!(with_editor(&rig, |e| e.config.custom_sets.len()), 1);
    }

    #[test]
    fn a_file_that_is_no_key_set_is_refused_and_changes_nothing() {
        let rig = rig(Platform::Mac);
        rig.with(|r| r.files.shortcut_file = Some(temp_file("notes.txt", b"hello world")));
        let before = map_of(&rig);
        start(&rig, ShortcutsFlow::ImportShortcuts);
        assert_eq!(dialog_title(&rig), "That is not a shortcut file we know");
        answer_swept(&rig, SQDialogResponse::FIRST);
        assert_eq!(map_of(&rig), before);
        assert!(with_editor(&rig, |e| e.config.custom_sets.is_empty()));
    }

    #[test]
    fn the_list_groups_by_area_and_folds_the_rest_into_a_more_row() {
        use sq_uikit::key_group::KeyGroup;
        let m = sq_draw::TextMeasure::new(None, 1.0);
        let mut e = editor(Platform::Mac);
        let secs = e.sections();
        assert!(secs.len() > 3, "several areas");
        let order: Vec<usize> = secs.iter().filter_map(|s| s.group).collect();
        assert!(order.windows(2).all(|w| w[0] < w[1]), "areas keep the legend order");
        for s in &secs {
            assert!(s.rows.len() <= 8, "{} shows at most 8", s.title);
            let g = KeyGroup::ALL[s.group.expect("a plain list has groups")];
            assert!(s.rows.iter().all(|i| KeyGroup::of(&e.rows[*i].command) == g), "rows sit in their own area");
        }
        let big = secs.iter().find(|s| s.more > 0).expect("an area with more than 8 commands");
        let (gi, total) = (big.group.unwrap(), big.rows.len() + big.more);
        e.press(crate::shell_shortcuts_draw::Hit::Expand(gi), &m);
        let open = e.sections().into_iter().find(|s| s.group == Some(gi)).unwrap();
        assert_eq!((open.rows.len(), open.more, open.collapsible), (total, 0, true), "+ N more opens the whole area");
        e.press(crate::shell_shortcuts_draw::Hit::Expand(gi), &m);
        assert!(e.sections().into_iter().find(|s| s.group == Some(gi)).unwrap().more > 0, "Show fewer folds it again");
    }

    #[test]
    fn a_picked_key_lists_only_its_commands_for_the_modifier_layer() {
        let m = sq_draw::TextMeasure::new(None, 1.0);
        let mut e = editor(Platform::Mac);
        e.select_key(Some(Key::Char('c')));
        let secs = e.sections();
        assert_eq!(secs.len(), 1);
        assert!(secs[0].link, "show all is offered");
        assert!(!secs[0].rows.is_empty(), "C is bound");
        for i in &secs[0].rows {
            let b = e.rows[*i].entry.expect("bound").binding;
            assert_eq!((b.key, b.modifiers), (Key::Char('c'), KeyModifiers::EMPTY));
        }
        e.toggle_modifier(KeyModifiers::COMMAND);
        let cmd = e.sections();
        assert!(cmd[0].rows.iter().all(|i| e.rows[*i].entry.unwrap().binding.modifiers == KeyModifiers::COMMAND));
        e.press(crate::shell_shortcuts_draw::Hit::ShowAll, &m);
        assert!(e.selected_key.is_none() && e.sections().len() > 1, "show all brings the areas back");
    }

    #[test]
    fn the_modifier_keys_of_the_picture_toggle_their_layer_and_plain_keys_pick() {
        use crate::shell_shortcuts_draw::Hit;
        let m = sq_draw::TextMeasure::new(None, 1.0);
        let mut e = editor(Platform::Mac);
        let p = e.parts(&m);
        let laid = e.laid_caps(&p);
        let center = |label: &str| {
            let (_, r) = laid.iter().find(|(c, _)| c.label == label).expect(label);
            CGPoint::new(r.mid_x(), r.mid_y())
        };
        assert_eq!(e.hit(center("⌘"), &m), Some(Hit::Modifier(3)));
        assert_eq!(e.hit(center("⇧"), &m), Some(Hit::Modifier(2)));
        assert!(matches!(e.hit(center("C"), &m), Some(Hit::Key(Key::Char('c')))));
        e.press(Hit::Modifier(3), &m);
        assert_eq!(e.modifiers, KeyModifiers::COMMAND);
        e.press(Hit::Key(Key::Char('c')), &m);
        assert_eq!(e.selected_key, Some(Key::Char('c')));
        e.press(Hit::Key(Key::Char('c')), &m);
        assert_eq!(e.selected_key, None, "a second click lets go of the key");
    }

    #[test]
    fn the_row_links_set_assign_and_remove_act_on_their_row() {
        use crate::shell_shortcuts_draw::Hit;
        let m = sq_draw::TextMeasure::new(None, 1.0);
        let mut e = editor(Platform::Mac);
        let i = row(&mut e, EditorCommand::Undo).expect("Undo row");
        e.press(Hit::RowSet(i), &m);
        assert!(e.capturing && e.selected_index == Some(i), "Set Shortcut selects the row and waits for the keys");
        e.end_capture();
        e.press(Hit::RowRemove(i), &m);
        assert!(e.commit_pending, "Remove unbinds the row's key");
        e.select_key(Some(Key::Char('j')));
        e.press(Hit::RowAssign(i), &m);
        assert_eq!(e.queue.borrow().last(), Some(&ShortcutsFlow::AssignToKey));
    }

    #[test]
    fn the_key_set_tabs_pick_a_preset_and_the_label_opens_the_menu_with_the_layouts() {
        use crate::shell_shortcuts_draw::Hit;
        let m = sq_draw::TextMeasure::new(None, 1.0);
        let mut e = editor(Platform::Mac);
        e.press(Hit::KeySet(0), &m);
        assert!(e.queue.borrow().is_empty(), "the active set needs no step");
        e.press(Hit::KeySet(1), &m);
        assert_eq!(
            e.queue.borrow().last(),
            Some(&ShortcutsFlow::ChooseTemplate(TemplateChoice::Preset(KeymapPreset::Premiere)))
        );
        e.press(Hit::KeySetMenu, &m);
        assert!(e.menu.is_open(), "the Key set label opens the template and layout list");
        e.press(Hit::Import, &m);
        assert_eq!(e.queue.borrow().last(), Some(&ShortcutsFlow::ImportShortcuts));
    }

    /// PRUEF-LIN-3 D3: every keycap label fits its cap (at the size `draw_keyboard` picks) on every platform and layout, also
    /// with a wide font (0.64 em per character, wider than the semibold caps measure) and a narrower 800 pt dialog.
    #[test]
    fn a_cap_too_narrow_for_its_word_keeps_a_cut_label() {
        let wide = |t: &str, sz: f64| t.chars().count() as f64 * sz * 0.6;
        for label in ["Ctrl", "Super", "Option", "Esc", "Alt"] {
            let (text, _) = ShellShortcutsEditor::cap_label(label, 6.0, wide);
            assert!(!text.is_empty(), "{label}");
        }
    }

    #[test]
    fn every_keycap_label_fits_its_cap() {
        use crate::shell_shortcuts_draw::M;
        let m = sq_draw::TextMeasure::new(None, 1.0);
        for platform in [Platform::Mac, Platform::Windows, Platform::Linux] {
            for style in KeyboardStyle::ALL {
                for card in [900.0, 800.0] {
                    let mut e = editor(platform);
                    e.style = style;
                    e.frame = CGRect::new(0.0, 0.0, card, 800.0);
                    let p = e.parts(&m);
                    for (cap, r) in e.laid_caps(&p) {
                        let wide = |t: &str, s: f64| t.chars().count() as f64 * 0.64 * s;
                        let (text, size) = ShellShortcutsEditor::cap_label(&cap.label, r.width - 8.0, wide);
                        assert!(
                            wide(&text, size) <= r.width - 8.0 && size >= M::F_CAP_MIN,
                            "{platform:?} {style:?} card {card}: '{text}' needs {:.1} pt at {size} pt, the cap gives {:.1}",
                            wide(&text, size),
                            r.width - 8.0
                        );
                    }
                }
            }
        }
    }

    /// PRUEF-WIN-4 P2-4: the command name under a key is whole, or whole words with an ellipsis, or absent; never a word cut
    /// in the middle ("Swit…"). On every platform and layout, with a wide font as well as the real measure.
    #[test]
    fn keycap_command_names_never_break_inside_a_word() {
        use crate::shell_shortcuts_draw::M;
        let real = sq_draw::TextMeasure::new(None, 1.0);
        type Width = Box<dyn Fn(&str, f64) -> f64>;
        let fonts: [(&str, Width); 2] = [
            ("wide", Box::new(|t: &str, s: f64| t.chars().count() as f64 * 0.64 * s)),
            ("real", Box::new(move |t: &str, s: f64| real.width(t, s, 0))),
        ];
        let mut named = 0;
        for platform in [Platform::Mac, Platform::Windows, Platform::Linux] {
            for style in KeyboardStyle::ALL {
                let mut e = editor(platform);
                e.style = style;
                let m = sq_draw::TextMeasure::new(None, 1.0);
                let p = e.parts(&m);
                let model = e.layout_model();
                for (cap, r) in e.laid_caps(&p) {
                    let Some(entry) = cap.key.and_then(|k| model.entries(k).first().copied()) else { continue };
                    let title = entry.command.title();
                    for (name, width) in &fonts {
                        let Some((shown, size)) = ShellShortcutsEditor::cap_command(&title, r.width - 9.0, width)
                        else {
                            continue;
                        };
                        named += 1;
                        assert!(
                            width(&shown, size) <= r.width - 9.0 && size >= M::F_CAP_COMMAND_MIN,
                            "{name}: '{shown}' too wide"
                        );
                        if shown != title {
                            let head = shown.trim_end_matches('\u{2026}');
                            assert!(
                                shown.ends_with('\u{2026}') && title.starts_with(head),
                                "{name}: '{shown}' of '{title}'"
                            );
                            assert!(
                                title[head.len()..].starts_with(' '),
                                "{platform:?} {style:?} {name}: '{shown}' cuts '{title}' inside a word"
                            );
                        }
                    }
                }
            }
        }
        assert!(named > 100, "the keyboards name their commands ({named})");
    }

    #[test]
    fn the_menu_command_opens_the_editor_modally() {
        let rig = Rig::new();
        rig.with(|r| r.shell.set_size(sq_uikit::controls_grid::CGSize::new(1280.0, 800.0)));
        assert!(rig.execute(EditorCommand::KeyboardShortcuts));
        assert!(rig.with(|r| r.shell.is_shortcuts_shown()));
        assert!(rig.cx(|h, cx| h.menu_state(cx.session, &*cx.hooks).modal_shown));
        let mut c = sq_draw::Canvas::with_size(1280.0, 800.0, None, 1.0);
        rig.with(|r| r.shell.draw_overlays(&mut c, &sq_draw::DrawTheme::default(), &mut sq_draw::UiCx::new()));
        assert!(c.list.quads().len() > 100);
        rig.with(|r| r.shell.hide_shortcuts());
        assert!(!rig.with(|r| r.shell.is_shortcuts_shown()));
    }
}

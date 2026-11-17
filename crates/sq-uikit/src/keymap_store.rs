// Swift: KeymapStore.swift
//! The saved keymap: a template (built-in or the user's own set) plus the user's changes over it, and the rules for
//! applying, diffing, assigning and listing key bindings.

use crate::appearance_palette::UiDefaults;
use crate::command_catalog::CommandCatalog;
use crate::command_map::{CommandMap, Entry};
use crate::command_support::CommandSupport;
use crate::editor_command::{CommandScope, EditorCommand};
use crate::key_binding::{Key, KeyBinding, KeyModifiers};
use crate::key_binding_text::KeyBindingText;
use crate::keyboard_listing::{KeyboardListing, Row};
use serde::{Deserialize, Serialize};
use sq_core_model::TrackKind;
use sq_core_time::IdSource;
use sq_os::Platform;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

// MARK: Stable names (what `sq.keymap` stores)

fn track_kind_raw(k: TrackKind) -> &'static str {
    match k {
        TrackKind::Video => "video",
        TrackKind::Audio => "audio",
    }
}

impl EditorCommand {
    /// Stable identifier of a command in saved keymaps ("razor" tool = "tool.razor", panels = "focusPanel.timeline").
    pub fn id(&self) -> String {
        match self {
            EditorCommand::Tool(t) => format!("tool.{}", t.raw_value()),
            EditorCommand::FocusPanel(p) => format!("focusPanel.{}", p.raw_value()),
            EditorCommand::SwitchAngle(n) => format!("switchAngle.{n}"),
            EditorCommand::ToggleTrackTarget(k, n) => format!("toggleTrackTarget.{}.{n}", track_kind_raw(*k)),
            EditorCommand::ThumbnailMode(m) => format!("thumbnailMode.{}", m.raw_value()),
            EditorCommand::ReplaceMode(m) => format!("replaceMode.{}", m.raw_value()),
            EditorCommand::ViewGamma(g) => format!("viewGamma.{}", g.raw_value()),
            EditorCommand::DisplayView(v) => format!("displayView.{}", v.raw_value()),
            // Swift prints the case name (lower camel case) for the rest.
            other => {
                let dbg = format!("{other:?}");
                let mut cs = dbg.chars();
                cs.next().map_or_else(String::new, |f| f.to_lowercase().chain(cs).collect())
            }
        }
    }

    /// `None` for ids this build does not know (a keymap saved by a newer build): such overrides are skipped.
    pub fn from_id(id: &str) -> Option<EditorCommand> {
        static COMMANDS: OnceLock<HashMap<String, EditorCommand>> = OnceLock::new();
        COMMANDS
            .get_or_init(|| {
                let mut d = HashMap::new();
                let extra = [
                    EditorCommand::RemoveSilences,
                    EditorCommand::RemoveFillerWords,
                    EditorCommand::Voiceover,
                    EditorCommand::RecordVoiceOver,
                ];
                for c in CommandCatalog::audited(&CommandMap::premiere_default()).into_iter().chain(extra) {
                    d.insert(c.id(), c);
                }
                d
            })
            .get(id)
            .cloned()
    }
}

impl Key {
    /// "c", "space", "left", "f9": one character is a key cap, longer names are the special keys.
    pub fn code(&self) -> String {
        match self {
            Key::Char(c) => c.to_string(),
            Key::Space => "space".to_string(),
            Key::Left => "left".to_string(),
            Key::Right => "right".to_string(),
            Key::Up => "up".to_string(),
            Key::Down => "down".to_string(),
            Key::Home => "home".to_string(),
            Key::End => "end".to_string(),
            Key::PageUp => "pageup".to_string(),
            Key::PageDown => "pagedown".to_string(),
            Key::Delete => "delete".to_string(),
            Key::ReturnKey => "return".to_string(),
            Key::ForwardDelete => "fdelete".to_string(),
            Key::Function(n) => format!("f{n}"),
        }
    }

    /// The key a saved `code` names.
    pub fn from_code(code: &str) -> Option<Key> {
        let mut chars = code.chars();
        if let (Some(c), None) = (chars.next(), chars.next()) {
            return Some(Key::Char(c));
        }
        Some(match code {
            "space" => Key::Space,
            "left" => Key::Left,
            "right" => Key::Right,
            "up" => Key::Up,
            "down" => Key::Down,
            "home" => Key::Home,
            "end" => Key::End,
            "pageup" => Key::PageUp,
            "pagedown" => Key::PageDown,
            "delete" => Key::Delete,
            "return" => Key::ReturnKey,
            "fdelete" => Key::ForwardDelete,
            _ => {
                let n: i64 = code.strip_prefix('f')?.parse().ok().filter(|n| *n > 0)?;
                Key::Function(n)
            }
        })
    }
}

impl CommandScope {
    /// The stored name.
    pub fn name(self) -> &'static str {
        match self {
            CommandScope::Global => "global",
            CommandScope::Timeline => "timeline",
            CommandScope::Program => "program",
            CommandScope::Source => "source",
            CommandScope::Project => "project",
            CommandScope::EffectControls => "effectControls",
        }
    }

    /// The scope a stored name names.
    pub fn from_name(name: &str) -> Option<CommandScope> {
        CommandScope::ALL.into_iter().find(|s| s.name() == name)
    }
}

// MARK: Diff model

/// One difference from the preset: in `scope`, `key` + `modifiers` now runs `command`, or nothing when `command` is `None`.
/// Fields are declared in key-sorted order: Swift writes `.sortedKeys`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct KeymapOverride {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    pub key: String,
    pub modifiers: i64,
    pub scope: String,
}

impl KeymapOverride {
    pub fn new(scope: CommandScope, binding: &KeyBinding, command: Option<&EditorCommand>) -> Self {
        KeymapOverride {
            scope: scope.name().to_string(),
            key: binding.key.code(),
            modifiers: binding.modifiers.0,
            command: command.map(EditorCommand::id),
        }
    }

    fn slot(&self) -> Option<Slot> {
        let s = CommandScope::from_name(&self.scope)?;
        let k = Key::from_code(&self.key)?;
        Some(Slot { scope: s, binding: KeyBinding::new(k, KeyModifiers(self.modifiers)) })
    }
}

/// A built-in key set.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum KeymapPreset {
    #[serde(rename = "sq")]
    Sq,
    #[serde(rename = "premiere")]
    Premiere,
    #[serde(rename = "finalCut")]
    FinalCut,
}

impl KeymapPreset {
    pub const ALL: [KeymapPreset; 3] = [KeymapPreset::Sq, KeymapPreset::Premiere, KeymapPreset::FinalCut];

    pub fn title(self) -> &'static str {
        match self {
            KeymapPreset::Sq => "Sequence Studio",
            KeymapPreset::Premiere => "Classic NLE",
            KeymapPreset::FinalCut => "Final Cut style",
        }
    }

    pub fn map(self) -> CommandMap {
        match self {
            KeymapPreset::Sq => CommandMap::sq_default(),
            KeymapPreset::Premiere => CommandMap::premiere_default(),
            KeymapPreset::FinalCut => CommandMap::final_cut_default(),
        }
    }
}

/// A key set the user saved or imported: every binding, by name. Lives in `KeymapConfig::custom_sets`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeymapSet {
    /// Every binding of the set (all `command` values are set).
    pub entries: Vec<KeymapOverride>,
    pub id: String,
    pub name: String,
}

/// Our own exchange format (`.sqkeys`): JSON with a format tag so other files are refused.
#[derive(Serialize, Deserialize)]
struct Exchange {
    entries: Vec<KeymapOverride>,
    format: String,
    name: String,
    version: i64,
}

impl KeymapSet {
    pub const FILE_EXTENSION: &'static str = "sqkeys";

    /// A set holding every binding of `map`; `id` is the caller's (a fresh UUID for a new set).
    pub fn new(id: String, name: &str, map: &CommandMap) -> KeymapSet {
        KeymapSet {
            id,
            name: name.to_string(),
            entries: map.entries.iter().map(|e| KeymapOverride::new(e.scope, &e.binding, Some(&e.command))).collect(),
        }
    }

    pub fn map(&self) -> CommandMap {
        Keymap::apply(&self.entries, &CommandMap::new(vec![]))
    }

    /// Our exchange file as pretty JSON with sorted keys.
    pub fn export_data(&self) -> Vec<u8> {
        let x = Exchange {
            entries: self.entries.clone(),
            format: "sq.keymapset".to_string(),
            name: self.name.clone(),
            version: 1,
        };
        serde_json::to_vec_pretty(&x).unwrap_or_default()
    }

    /// `None` when the data is not a key set of ours. Unknown commands inside are dropped when the set is used (`Keymap::apply`).
    pub fn from_exported(data: &[u8], ids: &mut dyn IdSource) -> Option<KeymapSet> {
        let x: Exchange = serde_json::from_slice(data).ok()?;
        if x.format != "sq.keymapset" || x.version != 1 {
            return None;
        }
        Some(KeymapSet { id: ids.next_id().to_string(), name: x.name, entries: x.entries })
    }
}

/// What `sq.keymap` holds: the chosen template (built-in set, or one of the user's own sets) plus the user's changes over it.
/// Decoding is lenient (missing keys take defaults); encoding leaves empty `customSets` out. Fields are in key-sorted order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeymapConfig {
    #[serde(rename = "activeSetID", default, skip_serializing_if = "Option::is_none")]
    pub active_set_id: Option<String>,
    /// The user's own sets (imported or saved). When `active_set_id` names one, it replaces `preset` as the base.
    #[serde(rename = "customSets", default, skip_serializing_if = "Vec::is_empty")]
    pub custom_sets: Vec<KeymapSet>,
    #[serde(default)]
    pub overrides: Vec<KeymapOverride>,
    #[serde(default = "default_preset")]
    pub preset: KeymapPreset,
}

fn default_preset() -> KeymapPreset {
    KeymapPreset::Sq
}

impl Default for KeymapConfig {
    fn default() -> Self {
        KeymapConfig { active_set_id: None, custom_sets: vec![], overrides: vec![], preset: KeymapPreset::Sq }
    }
}

impl KeymapConfig {
    /// Something differs from the plain default set (own changes, another template, or saved sets that must not be lost).
    pub fn is_modified(&self) -> bool {
        !self.overrides.is_empty()
    }

    /// The own set in use, if any (an id of a deleted set counts as none).
    pub fn active_set(&self) -> Option<&KeymapSet> {
        let id = self.active_set_id.as_ref()?;
        self.custom_sets.iter().find(|s| &s.id == id)
    }

    /// Name of the template in use, for the switcher.
    pub fn base_title(&self) -> String {
        self.active_set().map_or_else(|| self.preset.title().to_string(), |s| s.name.clone())
    }

    /// The template the overrides sit on.
    pub fn base_map(&self) -> CommandMap {
        self.active_set().map_or_else(|| self.preset.map(), KeymapSet::map)
    }

    /// Template with the overrides applied.
    pub fn map(&self) -> CommandMap {
        Keymap::apply(&self.overrides, &self.base_map())
    }

    /// Stores `edited` as the diff over the current template.
    pub fn set_map(&mut self, edited: &CommandMap) {
        self.overrides = Keymap::diff(&self.base_map(), edited);
    }

    /// A different template starts clean: overrides made against another base would not mean the same.
    pub fn switch_preset(&mut self, p: KeymapPreset) {
        self.preset = p;
        self.active_set_id = None;
        self.overrides = vec![];
    }

    pub fn switch_to_set(&mut self, id: &str) {
        if !self.custom_sets.iter().any(|s| s.id == id) {
            return;
        }
        self.active_set_id = Some(id.to_string());
        self.overrides = vec![];
    }

    pub fn reset_overrides(&mut self) {
        self.overrides = vec![];
    }

    // MARK: Own sets

    /// Names stay unique ("Name 2"), so the switcher never shows two equal rows.
    pub fn unique_name(&self, wanted: &str, ignoring: Option<&str>) -> String {
        let trimmed = wanted.trim_matches(|c: char| c.is_whitespace());
        let base = if trimmed.is_empty() { "My Shortcuts" } else { trimmed };
        let taken: HashSet<&str> = self
            .custom_sets
            .iter()
            .filter(|s| Some(s.id.as_str()) != ignoring)
            .map(|s| s.name.as_str())
            .chain(KeymapPreset::ALL.iter().map(|p| p.title()))
            .collect();
        if !taken.contains(base) {
            return base.to_string();
        }
        let mut n = 2;
        while taken.contains(format!("{base} {n}").as_str()) {
            n += 1;
        }
        format!("{base} {n}")
    }

    /// Adds the set and makes it the template in use (no overrides).
    pub fn add_set(&mut self, name: &str, map: &CommandMap, ids: &mut dyn IdSource) -> KeymapSet {
        let set = KeymapSet::new(ids.next_id().to_string(), &self.unique_name(name, None), map);
        self.custom_sets.push(set.clone());
        self.active_set_id = Some(set.id.clone());
        self.overrides = vec![];
        set
    }

    /// Adds a set read from a file (name made unique) and makes it the template in use.
    pub fn add_loaded_set(&mut self, set: &KeymapSet) {
        let mut s = set.clone();
        s.name = self.unique_name(&set.name, None);
        self.active_set_id = Some(s.id.clone());
        self.custom_sets.push(s);
        self.overrides = vec![];
    }

    pub fn rename_set(&mut self, id: &str, name: &str) {
        let Some(i) = self.custom_sets.iter().position(|s| s.id == id) else { return };
        self.custom_sets[i].name = self.unique_name(name, Some(id));
    }

    /// Deleting the set in use goes back to our default set.
    pub fn delete_set(&mut self, id: &str) {
        self.custom_sets.retain(|s| s.id != id);
        if self.active_set_id.as_deref() == Some(id) {
            self.switch_preset(KeymapPreset::Sq);
        }
    }

    /// The template in use as a set (overrides included), for "Export…" and "Save as My Set".
    pub fn current_as_set(&self, name: Option<&str>, ids: &mut dyn IdSource) -> KeymapSet {
        let id = self.active_set_id.clone().unwrap_or_else(|| ids.next_id().to_string());
        KeymapSet::new(id, &name.map_or_else(|| self.base_title(), str::to_string), &self.map())
    }
}

/// Reads and writes the config in the defaults under `sq.keymap`.
pub struct KeymapStore;

impl KeymapStore {
    pub const DEFAULTS_KEY: &'static str = "sq.keymap";

    /// The saved config; a missing or unreadable value gives the standard set.
    pub fn load(defaults: &dyn UiDefaults) -> KeymapConfig {
        defaults.data(Self::DEFAULTS_KEY).and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    pub fn save(config: &KeymapConfig, defaults: &mut dyn UiDefaults) {
        if *config == KeymapConfig::default() {
            defaults.remove(Self::DEFAULTS_KEY);
            return;
        }
        if let Ok(data) = serde_json::to_vec(config) {
            defaults.set_data(Self::DEFAULTS_KEY, &data);
        }
    }

    pub fn reset(defaults: &mut dyn UiDefaults) {
        defaults.remove(Self::DEFAULTS_KEY);
    }
}

// MARK: Apply, diff, conflicts, edits

/// A binding position: what a key press resolves in one scope.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) struct Slot {
    pub scope: CommandScope,
    pub binding: KeyBinding,
}

fn slot(e: &Entry) -> Slot {
    Slot { scope: e.scope, binding: e.binding }
}

fn table(m: &CommandMap) -> HashMap<Slot, EditorCommand> {
    let mut t = HashMap::new();
    for e in &m.entries {
        t.entry(slot(e)).or_insert_with(|| e.command);
    }
    t
}

/// Rules for the user's changes over a template.
pub struct Keymap;

/// How a binding disagrees with another.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConflictKind {
    /// The key already runs another command in this scope: assigning replaces it.
    SameScope,
    /// A panel scope binds the key to another command, so a global binding does not work in that panel.
    ShadowedInPanel,
    /// A global binding of another command exists, which the panel scope hides while that panel has focus.
    ShadowsGlobal,
    /// macOS or the app menu owns the key.
    Reserved,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Conflict {
    pub kind: ConflictKind,
    /// The other binding (`None` for `Reserved`).
    pub entry: Option<Entry>,
}

impl Conflict {
    /// Plain-words warning for the assign alert; `platform` names the keys and the system (Ctrl+K, Windows).
    pub fn message(&self, binding: &KeyBinding, platform: Platform) -> String {
        let key = KeyBindingText::text(binding, platform);
        let system = platform.feedback_os_name();
        let Some(e) = &self.entry else { return format!("{key} is reserved by {system} or the app menu.") };
        let other = e.command.title().to_string();
        let scope = KeyboardListing::scope_name(e.scope);
        match self.kind {
            ConflictKind::SameScope => format!("{key} already runs {other} ({scope})."),
            ConflictKind::ShadowedInPanel => {
                format!("{key} runs {other} in the {scope}, so the new shortcut does not work there.")
            }
            ConflictKind::ShadowsGlobal => format!(
                "{key} also runs {other} everywhere, which this panel shortcut hides while the panel has focus."
            ),
            ConflictKind::Reserved => format!("{key} is reserved by {system} or the app menu."),
        }
    }
}

impl Keymap {
    /// Keys macOS or the app menu owns; a shortcut may not take them.
    pub fn reserved() -> [KeyBinding; 5] {
        [
            KeyBinding::new(Key::Char('h'), KeyModifiers::COMMAND),
            KeyBinding::new(Key::Char('h'), KeyModifiers::COMMAND | KeyModifiers::OPTION),
            KeyBinding::new(Key::Char('q'), KeyModifiers::COMMAND),
            KeyBinding::new(Key::Char('w'), KeyModifiers::COMMAND),
            KeyBinding::new(Key::Char('h'), KeyModifiers::COMMAND | KeyModifiers::SHIFT),
        ]
    }

    /// True for a reserved key.
    pub fn is_reserved(b: &KeyBinding) -> bool {
        Self::reserved().contains(b)
    }

    /// Base entries with the overrides applied in place; overrides for slots the base lacks are appended.
    /// Overrides that name an unknown scope, key or command are skipped (a newer build wrote them).
    pub fn apply(overrides: &[KeymapOverride], base: &CommandMap) -> CommandMap {
        // `Some(None)`: the slot is cleared by the override.
        let mut ov: HashMap<Slot, Option<EditorCommand>> = HashMap::new();
        let mut order: Vec<Slot> = Vec::new();
        for o in overrides {
            let Some(s) = o.slot() else { continue };
            if let Some(id) = &o.command {
                let Some(c) = EditorCommand::from_id(id) else { continue };
                ov.insert(s, Some(c));
            } else {
                ov.insert(s, None);
            }
            order.push(s);
        }
        let mut out: Vec<Entry> = Vec::new();
        let mut used: HashSet<Slot> = HashSet::new();
        for e in &base.entries {
            let s = slot(e);
            if let Some(o) = ov.get(&s) {
                if let Some(c) = o
                    && used.insert(s)
                {
                    out.push(Entry { scope: s.scope, binding: s.binding, command: *c });
                }
                used.insert(s);
            } else {
                out.push(*e);
            }
        }
        for s in order {
            if used.contains(&s) {
                continue;
            }
            used.insert(s);
            if let Some(Some(c)) = ov.get(&s) {
                out.push(Entry { scope: s.scope, binding: s.binding, command: *c });
            }
        }
        CommandMap::new(out)
    }

    /// The overrides that turn `base` into `edited`. `apply(diff(base, edited), base)` binds the same keys as `edited`.
    pub fn diff(base: &CommandMap, edited: &CommandMap) -> Vec<KeymapOverride> {
        let b = table(base);
        let e = table(edited);
        let mut out = Vec::new();
        let mut seen: HashSet<Slot> = HashSet::new();
        for entry in base.entries.iter().chain(edited.entries.iter()) {
            let s = slot(entry);
            if !seen.insert(s) || b.get(&s) == e.get(&s) {
                continue;
            }
            out.push(KeymapOverride::new(s.scope, &s.binding, e.get(&s)));
        }
        out
    }

    // MARK: Conflicts

    /// Everything that disagrees with binding `command` to `binding` in `scope`. Empty means free.
    pub fn conflicts(
        command: &EditorCommand,
        binding: &KeyBinding,
        scope: CommandScope,
        map: &CommandMap,
    ) -> Vec<Conflict> {
        if Self::is_reserved(binding) {
            return vec![Conflict { kind: ConflictKind::Reserved, entry: None }];
        }
        let mut out = Vec::new();
        for e in map.entries.iter().filter(|e| e.binding == *binding && e.command != *command) {
            if e.scope == scope {
                out.push(Conflict { kind: ConflictKind::SameScope, entry: Some(*e) });
            } else if scope == CommandScope::Global {
                out.push(Conflict { kind: ConflictKind::ShadowedInPanel, entry: Some(*e) });
            } else if e.scope == CommandScope::Global {
                out.push(Conflict { kind: ConflictKind::ShadowsGlobal, entry: Some(*e) });
            }
        }
        out
    }

    /// Binds `command` to `binding` in `scope`. `moving` is the entry being moved (removed, the new one takes its place).
    /// The command it displaced in the same scope loses the key. Returns `None` for a reserved key.
    pub fn assign(
        command: &EditorCommand,
        binding: KeyBinding,
        scope: CommandScope,
        map: &CommandMap,
        moving: Option<&Entry>,
    ) -> Option<CommandMap> {
        if Self::is_reserved(&binding) {
            return None;
        }
        let mut out: Vec<Entry> = Vec::new();
        let mut placed = false;
        let new = Entry { scope, binding, command: *command };
        for e in &map.entries {
            if Some(e) == moving {
                if !placed {
                    out.push(new);
                    placed = true;
                }
                continue;
            }
            if e.scope == scope && e.binding == binding {
                if e.command == *command && !placed {
                    out.push(*e);
                    placed = true;
                }
                continue; // another command in the same slot: displaced
            }
            out.push(*e);
        }
        if !placed {
            out.push(new);
        }
        Some(CommandMap::new(out))
    }

    /// Removes one binding.
    pub fn unbind(entry: &Entry, map: &CommandMap) -> CommandMap {
        CommandMap::new(map.entries.iter().filter(|e| *e != entry).cloned().collect())
    }
}

// MARK: List rows (Keyboard Shortcuts window)

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeymapRow {
    pub command: EditorCommand,
    /// `None` for a command without a key (menu only).
    pub entry: Option<Entry>,
    pub listing: Row,
}

impl KeymapRow {
    /// Every binding, then every wired command without a key, sorted by command name.
    pub fn build(map: &CommandMap) -> Vec<KeymapRow> {
        let keyed: HashSet<EditorCommand> = map.entries.iter().map(|e| e.command).collect();
        let mut rows: Vec<KeymapRow> = map
            .entries
            .iter()
            .map(|e| KeymapRow {
                command: e.command,
                entry: Some(*e),
                listing: Row {
                    command: e.command.title().to_string(),
                    shortcut: KeyboardListing::text_for(&e.binding),
                    scope: KeyboardListing::scope_name(e.scope).to_string(),
                },
            })
            .collect();
        rows.extend(
            CommandCatalog::audited(map)
                .into_iter()
                .filter(|c| !keyed.contains(c) && CommandSupport::is_supported(c))
                .map(|c| KeymapRow {
                    listing: Row {
                        command: c.title().to_string(),
                        shortcut: String::new(),
                        scope: "Menu only".to_string(),
                    },
                    command: c,
                    entry: None,
                }),
        );
        rows.sort_by(|a, b| (&a.listing.command, &a.listing.shortcut).cmp(&(&b.listing.command, &b.listing.shortcut)));
        rows
    }

    pub fn filter(rows: &[KeymapRow], query: &str) -> Vec<KeymapRow> {
        rows.iter()
            .filter(|r| !KeyboardListing::filter(std::slice::from_ref(&r.listing), query).is_empty())
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::appearance_palette::MemoryDefaults;
    use crate::editor_command::EditorTool;
    use sq_core_time::SequentialIds;

    fn b(k: char) -> KeyBinding {
        KeyBinding::new(Key::Char(k), KeyModifiers(0))
    }

    #[test]
    fn reserved_message_names_the_system() {
        let c = Conflict { kind: ConflictKind::Reserved, entry: None };
        let msg = |p| c.message(&KeyBinding::new(Key::Char('q'), KeyModifiers::COMMAND), p);
        assert_eq!(msg(Platform::Mac), "\u{2318}Q is reserved by macOS or the app menu.");
        assert_eq!(msg(Platform::Windows), "Ctrl+Q is reserved by Windows or the app menu.");
        assert_eq!(msg(Platform::Linux), "Ctrl+Q is reserved by Linux or the app menu.");
    }

    fn razor_map() -> CommandMap {
        CommandMap::new(vec![Entry {
            scope: CommandScope::Global,
            binding: b('b'),
            command: EditorCommand::Tool(EditorTool::Razor),
        }])
    }

    #[test]
    fn custom_set_lifecycle() {
        let mut ids = SequentialIds::default();
        let mut c = KeymapConfig::default();
        let set = c.add_set("Tester", &razor_map(), &mut ids);
        assert_eq!(c.active_set_id.as_deref(), Some(set.id.as_str()));
        assert_eq!(c.map().command_for(&b('b'), None), Some(EditorCommand::Tool(EditorTool::Razor)));
        assert_eq!(c.base_title(), "Tester");
        // An edit on top of the set is a diff over it, and switching away drops it.
        let entry =
            Entry { scope: CommandScope::Global, binding: b('b'), command: EditorCommand::Tool(EditorTool::Razor) };
        let edited = Keymap::unbind(&entry, &c.map());
        c.set_map(&edited);
        assert!(c.is_modified());
        assert_eq!(c.map().command_for(&b('b'), None), None);
        c.reset_overrides();
        assert_eq!(c.map().command_for(&b('b'), None), Some(EditorCommand::Tool(EditorTool::Razor)));
        c.switch_preset(KeymapPreset::FinalCut);
        assert!(c.active_set().is_none() && c.custom_sets.len() == 1, "switching keeps the saved set");
        c.switch_to_set(&set.id);
        assert_eq!(c.active_set().map(|s| s.name.as_str()), Some("Tester"));
        c.rename_set(&set.id, "Optimum");
        assert_eq!(c.base_title(), "Optimum");
        c.delete_set(&set.id);
        assert!(c.custom_sets.is_empty() && c.active_set().is_none() && c.preset == KeymapPreset::Sq);
    }

    #[test]
    fn names_stay_unique() {
        let mut ids = SequentialIds::default();
        let mut c = KeymapConfig::default();
        let m = CommandMap::sq_default();
        for name in ["Mine", "Mine", "Final Cut style", "  "] {
            c.add_set(name, &m, &mut ids);
        }
        let names: Vec<&str> = c.custom_sets.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, ["Mine", "Mine 2", "Final Cut style 2", "My Shortcuts"]);
    }

    #[test]
    fn set_survives_the_store_and_old_configs_still_load() {
        let mut ids = SequentialIds::default();
        let mut d = MemoryDefaults::default();
        let mut c = KeymapConfig::default();
        c.add_set("Tester", &CommandMap::final_cut_default(), &mut ids);
        KeymapStore::save(&c, &mut d);
        let back = KeymapStore::load(&d);
        assert_eq!(back, c);
        assert_eq!(back.map().entries, CommandMap::final_cut_default().entries);
        // A config written before sets existed.
        d.set_data(KeymapStore::DEFAULTS_KEY, br#"{"preset":"premiere","overrides":[]}"#);
        let old = KeymapStore::load(&d);
        assert!(old.preset == KeymapPreset::Premiere && old.custom_sets.is_empty() && old.active_set_id.is_none());
        // An unknown preset from a newer build falls back to the standard set instead of losing the sets.
        d.set_data(KeymapStore::DEFAULTS_KEY, br#"{"preset":"future","overrides":[]}"#);
        assert_eq!(KeymapStore::load(&d), KeymapConfig::default());
        // The standard config is not stored at all.
        KeymapStore::save(&KeymapConfig::default(), &mut d);
        assert!(d.data(KeymapStore::DEFAULTS_KEY).is_none());
    }

    #[test]
    fn export_format_round_trips() {
        let mut ids = SequentialIds::default();
        let set = KeymapSet::new("A".to_string(), "Tester", &CommandMap::final_cut_default());
        let back = KeymapSet::from_exported(&set.export_data(), &mut ids);
        let Some(back) = back else { panic!("export must read back") };
        assert_eq!(back.name, "Tester");
        assert_eq!(back.map().entries, set.map().entries);
        assert_ne!(back.id, set.id, "an imported file is a new set");
        assert!(KeymapSet::from_exported(br#"{"format":"other"}"#, &mut ids).is_none());
        assert!(KeymapSet::from_exported(b"nope", &mut ids).is_none());
    }

    #[test]
    fn key_codes_round_trip() {
        for k in [Key::Char('c'), Key::Space, Key::PageUp, Key::ReturnKey, Key::ForwardDelete, Key::Function(9)] {
            assert_eq!(Key::from_code(&k.code()), Some(k));
        }
        assert_eq!(Key::from_code("f0"), None);
        assert_eq!(Key::from_code("nope"), None);
    }

    #[test]
    fn diff_then_apply_binds_the_same_keys() {
        let base = CommandMap::sq_default();
        let edited = Keymap::unbind(&base.entries[0], &base);
        let ov = Keymap::diff(&base, &edited);
        assert_eq!(Keymap::apply(&ov, &base).entries, edited.entries);
    }
}

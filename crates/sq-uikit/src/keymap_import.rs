// Swift: KeymapImport.swift
//! Turns a foreign key set (`ForeignCommand`s, e.g. from a Final Cut `.commandset`) into one of our key maps.
//!
//! Rules (docs/KEYMAP.md "Templates and import"):
//! - The result starts from `base` (our default) so commands the other program does not know keep their keys.
//! - Every command the import binds loses its base keys first: the file defines it.
//! - The imported binding wins: a base command that held the key in the same scope loses it, and a global import also takes
//!   the key from base commands bound to it in a panel scope (otherwise the panel would hide the import there).
//! - Two imported commands that claim the same key in the same scope: the first in file order (sorted by Final Cut id) keeps it.
//! - A command is bound in the scopes it has in our default set (Timeline for edit commands), else everywhere.

use crate::command_map::{CommandMap, Entry};
use crate::editor_command::{CommandScope, EditorCommand};
use crate::key_binding::{Key, KeyBinding, KeyModifiers};
use crate::key_character_resolver::KeyCharacterResolver;
use crate::keyboard_listing::KeyboardListing;
use crate::keymap_store::Keymap;
use crate::localization::SQL10n;
use sq_core_project::fcpcommand_table::{FCPCommandTable, FCPDefaultSet};
use sq_core_project::foreign_keymap::{
    Binding, ForeignChord, ForeignCommand, ForeignKey, ForeignKeymap, ForeignModifiers, Reason, Target, Unmapped,
};
use std::collections::{BTreeMap, HashSet};
use std::sync::OnceLock;

/// What kind of remark an import note is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoteKind {
    /// A base command lost a key the import took.
    Displaced,
    /// Two imported commands wanted the same key in the same scope; the later one lost it.
    SharedKey,
    /// An imported panel binding hides an imported Everywhere binding of the same key inside that panel.
    Overlap,
    /// A key we cannot bind (Return, Tab, Esc, forward delete, a reserved key).
    SkippedKey,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Note {
    pub kind: NoteKind,
    pub message: String,
}

/// The result of an import.
#[derive(Clone, Debug)]
pub struct KeymapImport {
    pub map: CommandMap,
    /// Distinct commands of ours that received at least one key.
    pub imported_commands: usize,
    pub imported_bindings: usize,
    /// Commands with a key in the file and no counterpart here (includes system and not-yet-built ones, see `reason`).
    pub unmapped: Vec<Unmapped>,
    pub notes: Vec<Note>,
    /// Commands in the file that have no key at all.
    pub unassigned: usize,
}

/// Swift prints a case as its lower camel case name.
fn case_name(debug: &str) -> String {
    let mut cs = debug.chars();
    cs.next().map_or_else(String::new, |f| f.to_lowercase().chain(cs).collect())
}

fn has(m: ForeignModifiers, flag: ForeignModifiers) -> bool {
    m.0 & flag.0 != 0
}

impl KeymapImport {
    pub fn skipped_keys(&self) -> Vec<&Note> {
        self.notes.iter().filter(|n| n.kind == NoteKind::SkippedKey).collect()
    }

    pub fn conflicts(&self) -> Vec<&Note> {
        self.notes.iter().filter(|n| n.kind != NoteKind::SkippedKey).collect()
    }

    /// "42 imported, 17 have no equivalent in Sequence Studio, 13 unassigned in the file".
    pub fn summary(&self) -> String {
        format!(
            "{} imported, {} have no equivalent in Sequence Studio, {} unassigned in the file",
            self.imported_commands,
            self.unmapped.len(),
            self.unassigned
        )
    }

    /// Plain-words name of an unmapped row for the result list.
    pub fn title_of(u: &Unmapped) -> String {
        match u.reason {
            Reason::NoEquivalent => u.title.clone(),
            Reason::System => format!("{} (macOS handles it)", u.title),
            Reason::PlannedFeature => format!("{} (comes with Fast Cut mode)", u.title),
        }
    }

    /// `build` over our default set with the Final Cut table and the US layout (the Swift default arguments).
    pub fn build_default(commands: &[ForeignCommand]) -> KeymapImport {
        Self::build(commands, &CommandMap::sq_default(), &FCPCommandTable::rows(), &KeyCharacterResolver::us())
    }

    pub fn build(
        commands: &[ForeignCommand],
        base: &CommandMap,
        table: &BTreeMap<String, Target>,
        resolver: &KeyCharacterResolver,
    ) -> KeymapImport {
        let translated = ForeignKeymap::translate(commands, table);
        let mut unmapped = translated.unmapped.clone();
        let mut notes: Vec<Note> = Vec::new();

        struct Claim {
            command: EditorCommand,
            scope: CommandScope,
            binding: KeyBinding,
        }
        let mut claims: Vec<Claim> = Vec::new();
        for b in &translated.mapped {
            let Binding { source_id, command_id, planned, chords, unreadable } = b;
            let Some(command) = EditorCommand::from_id(command_id) else {
                unmapped.push(Unmapped {
                    source_id: source_id.clone(),
                    title: ForeignKeymap::humanize(source_id),
                    reason: if *planned { Reason::PlannedFeature } else { Reason::NoEquivalent },
                    chords: chords.clone(),
                });
                continue;
            };
            let scopes = Self::scopes_of(&command);
            for text in unreadable {
                notes.push(Note {
                    kind: NoteKind::SkippedKey,
                    message: SQL10n::format(
                        "%@: the key %@ in the file could not be read.",
                        &[&ForeignKeymap::humanize(source_id), text],
                    ),
                });
            }
            for chord in chords {
                let Some(binding) = KeyBinding::from_chord(chord, resolver) else {
                    notes.push(Note {
                        kind: NoteKind::SkippedKey,
                        message: SQL10n::format(
                            "%@: %@ cannot be used as a shortcut here.",
                            &[&ForeignKeymap::humanize(source_id), &Self::describe(chord)],
                        ),
                    });
                    continue;
                };
                if Keymap::is_reserved(&binding) {
                    notes.push(Note {
                        kind: NoteKind::SkippedKey,
                        message: SQL10n::format(
                            "%@: %@ is reserved by macOS or the app menu.",
                            &[&ForeignKeymap::humanize(source_id), &KeyboardListing::text_for(&binding)],
                        ),
                    });
                    continue;
                }
                for s in &scopes {
                    claims.push(Claim { command, scope: *s, binding });
                }
            }
        }

        let imported: HashSet<&EditorCommand> = claims.iter().map(|c| &c.command).collect();
        let mut entries: Vec<Entry> = base.entries.iter().filter(|e| !imported.contains(&e.command)).cloned().collect();
        let mut bound: HashSet<Entry> = HashSet::new();
        for c in &claims {
            let e = Entry { scope: c.scope, binding: c.binding, command: c.command };
            if bound.contains(&e) {
                continue; // same command, same slot, two source ids (Up and Previous Edit)
            }
            if let Some(other) =
                entries.iter().find(|x| bound.contains(*x) && x.scope == c.scope && x.binding == c.binding)
            {
                notes.push(Note {
                    kind: NoteKind::SharedKey,
                    message: SQL10n::format(
                        "%@ goes to %@; %@ did not get it.",
                        &[
                            &KeyboardListing::text_for(&c.binding),
                            &other.command.title().to_string(),
                            &c.command.title().to_string(),
                        ],
                    ),
                });
                continue;
            }
            for old in entries.iter().filter(|o| {
                o.binding == c.binding && !bound.contains(*o) && (o.scope == c.scope || c.scope == CommandScope::Global)
            }) {
                notes.push(Note {
                    kind: NoteKind::Displaced,
                    message: SQL10n::format(
                        "%@ moved from %@ to %@.",
                        &[
                            &KeyboardListing::text_for(&c.binding),
                            &old.command.title().to_string(),
                            &c.command.title().to_string(),
                        ],
                    ),
                });
            }
            entries.retain(|x| {
                !(x.binding == c.binding
                    && !bound.contains(x)
                    && (x.scope == c.scope || c.scope == CommandScope::Global))
            });
            entries.push(e);
            bound.insert(e);
        }
        // Imported panel binding over an imported Everywhere binding of the same key.
        for e in bound.iter().filter(|e| e.scope != CommandScope::Global) {
            if let Some(g) = bound
                .iter()
                .find(|g| g.scope == CommandScope::Global && g.binding == e.binding && g.command != e.command)
            {
                notes.push(Note {
                    kind: NoteKind::Overlap,
                    message: SQL10n::format(
                        "%@ runs %@ in the %@ and %@ everywhere else.",
                        &[
                            &KeyboardListing::text_for(&e.binding),
                            &e.command.title().to_string(),
                            KeyboardListing::scope_name(e.scope),
                            &g.command.title().to_string(),
                        ],
                    ),
                });
            }
        }
        let mut seen_notes: HashSet<String> = HashSet::new();
        notes.retain(|n| seen_notes.insert(n.message.clone())); // one row per scope pair says the same
        notes.sort_by(|a, b| {
            let ka = (u8::from(a.kind == NoteKind::SkippedKey), &a.message);
            let kb = (u8::from(b.kind == NoteKind::SkippedKey), &b.message);
            ka.cmp(&kb)
        });
        unmapped.sort_by(|a, b| a.title.cmp(&b.title));
        let imported_commands = bound.iter().map(|e| &e.command).collect::<HashSet<_>>().len();
        KeymapImport {
            map: CommandMap::new(entries),
            imported_commands,
            imported_bindings: bound.len(),
            unmapped,
            notes,
            unassigned: translated.unassigned,
        }
    }

    /// Scopes a command is bound in by our default set; everywhere when it has no key there.
    pub(crate) fn scopes_of(command: &EditorCommand) -> Vec<CommandScope> {
        let mut out: Vec<CommandScope> = Vec::new();
        for e in &CommandMap::sq_default().entries {
            if e.command == *command && !out.contains(&e.scope) {
                out.push(e.scope);
            }
        }
        if out.is_empty() { vec![CommandScope::Global] } else { out }
    }

    pub(crate) fn describe(c: &ForeignChord) -> String {
        match c.key {
            ForeignKey::ReturnKey => "Return".to_string(),
            ForeignKey::Tab => "Tab".to_string(),
            ForeignKey::Escape => "Esc".to_string(),
            ForeignKey::ForwardDelete => "Forward Delete".to_string(),
            ForeignKey::Char(ch) => ch.to_uppercase().collect(),
            other => case_name(&format!("{other:?}")),
        }
    }
}

impl KeyBinding {
    /// `None` for a key our key model does not have (Tab, Escape).
    pub fn from_chord(chord: &ForeignChord, resolver: &KeyCharacterResolver) -> Option<KeyBinding> {
        let mut needs_shift = false;
        let key = match chord.key {
            ForeignKey::Char(c) => {
                let r = resolver.resolve(c)?;
                needs_shift = r.needs_shift;
                r.key
            }
            ForeignKey::Space => Key::Space,
            ForeignKey::Left => Key::Left,
            ForeignKey::Right => Key::Right,
            ForeignKey::Up => Key::Up,
            ForeignKey::Down => Key::Down,
            ForeignKey::Home => Key::Home,
            ForeignKey::End => Key::End,
            ForeignKey::PageUp => Key::PageUp,
            ForeignKey::PageDown => Key::PageDown,
            ForeignKey::Backspace => Key::Delete,
            ForeignKey::ReturnKey => Key::ReturnKey,
            ForeignKey::ForwardDelete => Key::ForwardDelete,
            ForeignKey::Function(n) => Key::Function(n),
            ForeignKey::Tab | ForeignKey::Escape => return None,
        };
        let mut m = KeyModifiers(0);
        if has(chord.modifiers, ForeignModifiers::COMMAND) {
            m |= KeyModifiers::COMMAND;
        }
        if has(chord.modifiers, ForeignModifiers::SHIFT) || needs_shift {
            m |= KeyModifiers::SHIFT;
        }
        if has(chord.modifiers, ForeignModifiers::OPTION) {
            m |= KeyModifiers::OPTION;
        }
        if has(chord.modifiers, ForeignModifiers::CONTROL) {
            m |= KeyModifiers::CONTROL;
        }
        Some(KeyBinding::new(key, m))
    }
}

impl CommandMap {
    /// Final Cut style: Final Cut Pro's default key set (approximate, docs/KEYMAP.md) laid over our default set.
    pub fn final_cut_default() -> CommandMap {
        static MAP: OnceLock<CommandMap> = OnceLock::new();
        MAP.get_or_init(|| KeymapImport::build_default(&FCPDefaultSet::commands()).map).clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::editor_command::EditorTool;
    use crate::key_character_resolver::KeyCharacterResolution;
    use crate::panel_id::PanelID;

    fn b(k: char, m: KeyModifiers) -> KeyBinding {
        KeyBinding::new(Key::Char(k), m)
    }

    fn plain(k: char) -> KeyBinding {
        b(k, KeyModifiers(0))
    }

    fn cmd(id: &str, specs: &[&str]) -> ForeignCommand {
        ForeignCommand::new(id, specs.iter().filter_map(|s| ForeignChord::from_spec(s)).collect())
    }

    fn chord(spec: &str) -> Option<KeyBinding> {
        KeyBinding::from_chord(&ForeignChord::from_spec(spec)?, &KeyCharacterResolver::us())
    }

    #[test]
    fn chords_become_our_key_bindings() {
        assert_eq!(chord("cmd+shift+b"), Some(b('b', KeyModifiers::COMMAND | KeyModifiers::SHIFT)));
        assert_eq!(chord("option+left"), Some(KeyBinding::new(Key::Left, KeyModifiers::OPTION)));
        assert_eq!(chord("shift+delete"), Some(KeyBinding::new(Key::Delete, KeyModifiers::SHIFT)));
        assert_eq!(chord("home"), Some(KeyBinding::new(Key::Home, KeyModifiers(0))));
        assert_eq!(chord("f9"), Some(KeyBinding::new(Key::Function(9), KeyModifiers(0))));
        assert_eq!(chord("control+="), Some(b('=', KeyModifiers::CONTROL)));
        assert_eq!(chord("return"), Some(KeyBinding::new(Key::ReturnKey, KeyModifiers(0))));
        assert_eq!(chord("shift+fdelete"), Some(KeyBinding::new(Key::ForwardDelete, KeyModifiers::SHIFT)));
        for unsupported in ["tab", "esc"] {
            assert!(ForeignChord::from_spec(unsupported).is_some() && chord(unsupported).is_none(), "{unsupported}");
        }
    }

    #[test]
    fn shifted_symbols_on_the_us_layout_add_shift() {
        let c = ForeignChord::new(ForeignKey::Char('+'), ForeignModifiers::EMPTY);
        assert_eq!(KeyBinding::from_chord(&c, &KeyCharacterResolver::us()), Some(b('=', KeyModifiers::SHIFT)));
    }

    #[test]
    fn unsupported_and_reserved_keys_are_reported_not_bound() {
        let r = KeymapImport::build_default(&[cmd("InsertMedia", &["w", "tab"]), cmd("Cut", &["cmd+q"])]);
        assert_eq!(r.map.binding_for(&EditorCommand::Insert), Some(plain('w')));
        assert_eq!(r.skipped_keys().len(), 2);
        assert!(r.skipped_keys().iter().any(|n| n.message.contains("Tab")));
        assert!(r.skipped_keys().iter().any(|n| n.message.contains("reserved")));
        assert_eq!(r.map.command_for(&b('q', KeyModifiers::COMMAND), None), None);
    }

    #[test]
    fn imported_binding_wins_and_displaced_command_loses_the_key() {
        // sqDefault: B = Ripple tool (global). Final Cut: B = Blade tool.
        assert_eq!(
            CommandMap::sq_default().command_for(&plain('b'), None),
            Some(EditorCommand::Tool(EditorTool::Ripple))
        );
        let r = KeymapImport::build_default(&[cmd("SelectToolBlade", &["b"])]);
        assert_eq!(r.map.command_for(&plain('b'), None), Some(EditorCommand::Tool(EditorTool::Razor)));
        assert_eq!(
            r.map.binding_for(&EditorCommand::Tool(EditorTool::Ripple)),
            None,
            "the displaced tool has no key now"
        );
        assert_eq!(r.map.binding_for(&EditorCommand::Tool(EditorTool::Razor)), Some(plain('b')));
        assert!(r.conflicts().iter().any(|n| n.kind == NoteKind::Displaced && n.message.contains("Ripple Tool")));
        assert!(r.map.duplicates().is_empty());
    }

    #[test]
    fn two_imported_commands_on_one_key_keep_the_first() {
        let r = KeymapImport::build_default(&[cmd("SelectToolBlade", &["x"]), cmd("SelectToolHand", &["x"])]);
        assert_eq!(r.map.command_for(&plain('x'), None), Some(EditorCommand::Tool(EditorTool::Razor)));
        assert!(r.conflicts().iter().any(|n| n.kind == NoteKind::SharedKey));
        assert!(r.map.duplicates().is_empty());
    }

    #[test]
    fn global_import_takes_the_key_from_panel_bindings() {
        // Timeline: S may be bound to a panel command; a global import on S must not hide behind it.
        let r = KeymapImport::build_default(&[cmd("SelectToolHand", &["s"])]);
        assert_eq!(
            r.map.command_for(&plain('s'), Some(PanelID::Timeline)),
            Some(EditorCommand::Tool(EditorTool::Hand))
        );
        assert_eq!(r.map.command_for(&plain('s'), None), Some(EditorCommand::Tool(EditorTool::Hand)));
    }

    #[test]
    fn panel_binding_overlapping_global_import_is_noted() {
        // Blade at Playhead (Timeline) and the Blade tool both on B.
        let r = KeymapImport::build_default(&[cmd("BladeAtPlayhead", &["b"]), cmd("SelectToolBlade", &["b"])]);
        assert_eq!(r.map.command_for(&plain('b'), Some(PanelID::Timeline)), Some(EditorCommand::AddEdit));
        assert_eq!(
            r.map.command_for(&plain('b'), Some(PanelID::ProgramMonitor)),
            Some(EditorCommand::Tool(EditorTool::Razor))
        );
        assert!(r.conflicts().iter().any(|n| n.kind == NoteKind::Overlap));
    }

    #[test]
    fn nudge_edit_keys_do_not_shadow_trim_keys_and_defaults_have_no_duplicates() {
        for m in [CommandMap::premiere_default(), CommandMap::sq_default()] {
            let cmd = |k: Key, mods: KeyModifiers| m.command_for(&KeyBinding::new(k, mods), Some(PanelID::Timeline));
            let co = KeyModifiers::CONTROL | KeyModifiers::OPTION;
            assert_eq!(cmd(Key::Left, co), Some(EditorCommand::NudgeAudioEditLeft));
            assert_eq!(cmd(Key::Right, co), Some(EditorCommand::NudgeAudioEditRight));
            assert_eq!(cmd(Key::Left, co | KeyModifiers::SHIFT), Some(EditorCommand::NudgeVideoEditLeft));
            assert_eq!(cmd(Key::Right, co | KeyModifiers::SHIFT), Some(EditorCommand::NudgeVideoEditRight));
            assert_eq!(cmd(Key::Left, KeyModifiers::OPTION), Some(EditorCommand::TrimBackward));
            assert_eq!(cmd(Key::Left, KeyModifiers::OPTION | KeyModifiers::SHIFT), Some(EditorCommand::TrimBackward5));
            assert!(m.duplicates().is_empty());
        }
    }

    #[test]
    fn same_command_on_two_source_ids_is_not_a_conflict() {
        let r = KeymapImport::build_default(&[cmd("Up", &["up"]), cmd("PreviousEdit", &["up"])]);
        assert!(r.conflicts().is_empty());
        assert!(r.imported_bindings >= 1);
    }

    fn german() -> KeyCharacterResolver {
        let one = |c: char| KeyCharacterResolution { key: Key::Char(c), needs_shift: false };
        KeyCharacterResolver::table(
            [('ß', one('-')), ('ü', one('[')), ('+', one(']')), ('z', one('y')), ('y', one('z'))].into_iter().collect(),
        )
    }

    #[test]
    fn typed_characters_resolve_through_the_layout() {
        let base = CommandMap::sq_default();
        let table = FCPCommandTable::rows();
        let cmds = [cmd("TrimStart", &["ß"]), cmd("TrimEnd", &["ü"])];
        let r = KeymapImport::build(&cmds, &base, &table, &german());
        assert_eq!(r.map.command_for(&plain('-'), Some(PanelID::Timeline)), Some(EditorCommand::RippleTrimPrevious));
        assert_eq!(r.map.command_for(&plain('['), Some(PanelID::Timeline)), Some(EditorCommand::RippleTrimNext));
        assert!(r.skipped_keys().is_empty());
        // A character neither the layout nor the US fallback knows is reported, not bound.
        let bad = KeymapImport::build(&cmds[..1], &base, &table, &KeyCharacterResolver::us());
        assert_eq!(bad.skipped_keys().len(), 1);
    }

    #[test]
    fn final_cut_preset_is_consistent() {
        let m = CommandMap::final_cut_default();
        assert!(m.duplicates().is_empty());
        assert_eq!(m.command_for(&plain('b'), None), Some(EditorCommand::Tool(EditorTool::Razor)));
        assert_eq!(
            m.command_for(&b('b', KeyModifiers::COMMAND), Some(PanelID::Timeline)),
            Some(EditorCommand::AddEdit)
        );
        assert_eq!(m.command_for(&plain('w'), None), Some(EditorCommand::Insert));
        assert_eq!(m.command_for(&plain('d'), None), Some(EditorCommand::Overwrite));
        assert_eq!(m.command_for(&plain('n'), Some(PanelID::Timeline)), Some(EditorCommand::ToggleSnapping));
        assert_eq!(m.command_for(&b('z', KeyModifiers::COMMAND), None), Some(EditorCommand::Undo));
        assert_eq!(m.command_for(&KeyBinding::new(Key::Space, KeyModifiers(0)), None), Some(EditorCommand::PlayPause));
        assert_eq!(m.command_for(&b('s', KeyModifiers::COMMAND), None), Some(EditorCommand::Save));
    }
}

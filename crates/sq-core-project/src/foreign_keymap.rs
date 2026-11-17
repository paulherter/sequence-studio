// Swift: ForeignKeymap.swift (`FCPCommandSetReader.read(Data)` waits for a property-list parser: this port reads the
// parsed `PlistValue` tree instead)
//! Foreign keyboard sets (docs/KEYMAP.md "Templates and import"). Pure: no editor types. A foreign file is read into
//! neutral chords (`ForeignChord`) plus the other program's command ids; `ForeignKeymap::translate` maps those ids to our
//! stable command ids (`EditorCommand.id` strings) with a table.

use std::collections::BTreeMap;
use std::ops::BitOr;

/// A key as another program names it. Wider than ours: Return, Tab, Escape and forward delete exist here, and the
/// importer reports a chord with such a key as skipped when our key model has no such key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ForeignKey {
    /// A character key, lowercase.
    // shortcut: one Unicode scalar; Swift's `Character` is a grapheme, so a key with combining marks reads as unreadable.
    Char(char),
    Space,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    /// The Mac "delete" key (backspace).
    Backspace,
    ForwardDelete,
    ReturnKey,
    Tab,
    Escape,
    Function(i64),
}

/// A set of modifier keys (an `OptionSet` in Swift).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct ForeignModifiers(pub u8);

impl ForeignModifiers {
    pub const COMMAND: ForeignModifiers = ForeignModifiers(1);
    pub const SHIFT: ForeignModifiers = ForeignModifiers(2);
    pub const OPTION: ForeignModifiers = ForeignModifiers(4);
    pub const CONTROL: ForeignModifiers = ForeignModifiers(8);
    /// No modifier.
    pub const EMPTY: ForeignModifiers = ForeignModifiers(0);

    fn insert(&mut self, other: ForeignModifiers) {
        self.0 |= other.0;
    }
}

impl BitOr for ForeignModifiers {
    type Output = ForeignModifiers;
    fn bitor(self, rhs: ForeignModifiers) -> ForeignModifiers {
        ForeignModifiers(self.0 | rhs.0)
    }
}

/// One key press. The keypad and fn flags of the source are dropped: a keypad twin of a chord is the same chord here.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ForeignChord {
    pub key: ForeignKey,
    pub modifiers: ForeignModifiers,
}

impl ForeignChord {
    pub fn new(key: ForeignKey, modifiers: ForeignModifiers) -> ForeignChord {
        ForeignChord { key, modifiers }
    }

    /// Compact spelling used by the built-in tables: "cmd+shift+b", "option+left", "control+=", "delete", "space".
    /// The key is the last `+`-separated part; a literal plus is not spellable (use "=").
    pub fn from_spec(spec: &str) -> Option<ForeignChord> {
        let mut parts: Vec<&str> = spec.split('+').collect();
        let last = parts.pop().filter(|l| !l.is_empty())?;
        let mut m = ForeignModifiers::EMPTY;
        for p in parts {
            match p {
                "cmd" | "command" => m.insert(ForeignModifiers::COMMAND),
                "shift" => m.insert(ForeignModifiers::SHIFT),
                "option" | "opt" => m.insert(ForeignModifiers::OPTION),
                "control" | "ctrl" => m.insert(ForeignModifiers::CONTROL),
                _ => return None,
            }
        }
        let key = match last {
            "space" => ForeignKey::Space,
            "left" => ForeignKey::Left,
            "right" => ForeignKey::Right,
            "up" => ForeignKey::Up,
            "down" => ForeignKey::Down,
            "home" => ForeignKey::Home,
            "end" => ForeignKey::End,
            "pageup" => ForeignKey::PageUp,
            "pagedown" => ForeignKey::PageDown,
            "delete" => ForeignKey::Backspace,
            "fdelete" => ForeignKey::ForwardDelete,
            "return" => ForeignKey::ReturnKey,
            "tab" => ForeignKey::Tab,
            "esc" => ForeignKey::Escape,
            _ => {
                let mut chars = last.chars();
                match (chars.next(), chars.next()) {
                    (Some(c), None) => ForeignKey::Char(c),
                    _ => {
                        let n = last.strip_prefix('f').and_then(|n| n.parse::<i64>().ok()).filter(|n| *n > 0)?;
                        ForeignKey::Function(n)
                    }
                }
            }
        };
        Some(ForeignChord::new(key, m))
    }
}

/// One command of the foreign file with every chord that triggers it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ForeignCommand {
    pub source_id: String,
    pub chords: Vec<ForeignChord>,
    /// Key descriptions that name no key we understand (kept for the report).
    pub unreadable: Vec<String>,
}

impl ForeignCommand {
    /// A command without unreadable key descriptions.
    pub fn new(source_id: &str, chords: Vec<ForeignChord>) -> ForeignCommand {
        ForeignCommand { source_id: source_id.to_string(), chords, unreadable: Vec::new() }
    }
}

/// A parsed property-list value, as far as the `.commandset` reader looks at it.
#[derive(Clone, Debug, PartialEq)]
pub enum PlistValue {
    String(String),
    Int(i64),
    Dict(BTreeMap<String, PlistValue>),
    Array(Vec<PlistValue>),
    /// Any other plist type (real, bool, date, data).
    Other,
}

/// Why a file is not a `.commandset`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReadError {
    NotAPropertyList,
    NotACommandSet,
}

/// Outcome of reading one key description.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChordResult {
    Chord(ForeignChord),
    None,
    Unreadable(String),
}

/// Reads Final Cut Pro's `.commandset` (a property list). Shape: a dictionary from command identifier ("BladeAtPlayhead")
/// to one key description or an array of them. A key description has `characterString` (the key: a character or a Cocoa name
/// such as `NSLeftArrowFunctionKey`), `modifiers` (words: command, option, control, shift, keypad, function) and
/// `modifierMask` (the same as NSEvent flag bits; read only when the words are missing). An empty `characterString` means
/// the command has no key.
pub struct FCPCommandSetReader;

impl FCPCommandSetReader {
    /// Reads a parsed property list; anything but a dictionary with a key description inside is not a command set.
    pub fn read(plist: &PlistValue) -> Result<Vec<ForeignCommand>, ReadError> {
        match plist {
            PlistValue::Dict(dict) if dict.values().any(Self::describes) => Ok(Self::read_dictionary(dict)),
            _ => Err(ReadError::NotACommandSet),
        }
    }

    fn describes(v: &PlistValue) -> bool {
        match v {
            PlistValue::Dict(d) => d.contains_key("characterString"),
            PlistValue::Array(a) => a.iter().any(Self::describes),
            _ => false,
        }
    }

    /// Sorted by identifier so results are stable. Commands without any key are returned with no chords.
    pub fn read_dictionary(dictionary: &BTreeMap<String, PlistValue>) -> Vec<ForeignCommand> {
        dictionary
            .iter()
            .map(|(id, raw)| {
                let descriptions: Vec<&BTreeMap<String, PlistValue>> = match raw {
                    PlistValue::Array(a) => a
                        .iter()
                        .map(|v| if let PlistValue::Dict(d) = v { Some(d) } else { None })
                        .collect::<Option<Vec<_>>>()
                        .unwrap_or_default(),
                    PlistValue::Dict(d) => vec![d],
                    _ => Vec::new(),
                };
                let mut chords: Vec<ForeignChord> = Vec::new();
                let mut unreadable: Vec<String> = Vec::new();
                for d in descriptions {
                    match Self::chord(d) {
                        ChordResult::Chord(c) => {
                            if !chords.contains(&c) {
                                chords.push(c); // keypad twins collapse here
                            }
                        }
                        ChordResult::None => {}
                        ChordResult::Unreadable(s) => unreadable.push(s),
                    }
                }
                ForeignCommand { source_id: id.clone(), chords, unreadable }
            })
            .collect()
    }

    fn string<'a>(d: &'a BTreeMap<String, PlistValue>, key: &str) -> Option<&'a str> {
        if let Some(PlistValue::String(s)) = d.get(key) { Some(s) } else { None }
    }

    pub(crate) fn chord(d: &BTreeMap<String, PlistValue>) -> ChordResult {
        let Some(raw) =
            Self::string(d, "characterString").or_else(|| Self::string(d, "character")).filter(|s| !s.is_empty())
        else {
            return ChordResult::None;
        };
        let Some(key) = Self::key(raw) else { return ChordResult::Unreadable(raw.to_string()) };
        let mask = if let Some(PlistValue::Int(m)) = d.get("modifierMask") { Some(*m) } else { None };
        ChordResult::Chord(ForeignChord::new(key, Self::modifiers(Self::string(d, "modifiers"), mask)))
    }

    pub(crate) fn modifiers(words: Option<&str>, mask: Option<i64>) -> ForeignModifiers {
        let mut m = ForeignModifiers::EMPTY;
        // The words win when they name something; an empty or missing list falls back to the flag bits (some entries only carry those).
        if let Some(words) = words {
            let blank = words.chars().all(|c| c != '\n' && c != '\r' && c.is_whitespace());
            if !blank || mask.unwrap_or(0) == 0 {
                for w in words.split(' ').filter(|w| !w.is_empty()) {
                    match w {
                        "command" => m.insert(ForeignModifiers::COMMAND),
                        "shift" => m.insert(ForeignModifiers::SHIFT),
                        "option" => m.insert(ForeignModifiers::OPTION),
                        "control" => m.insert(ForeignModifiers::CONTROL),
                        _ => {} // keypad, function: not part of the chord
                    }
                }
                return m;
            }
        }
        if let Some(mask) = mask {
            if mask & (1 << 17) != 0 {
                m.insert(ForeignModifiers::SHIFT);
            }
            if mask & (1 << 18) != 0 {
                m.insert(ForeignModifiers::CONTROL);
            }
            if mask & (1 << 19) != 0 {
                m.insert(ForeignModifiers::OPTION);
            }
            if mask & (1 << 20) != 0 {
                m.insert(ForeignModifiers::COMMAND);
            }
        }
        m
    }

    pub(crate) fn key(s: &str) -> Option<ForeignKey> {
        match s {
            "NSLeftArrowFunctionKey" => return Some(ForeignKey::Left),
            "NSRightArrowFunctionKey" => return Some(ForeignKey::Right),
            "NSUpArrowFunctionKey" => return Some(ForeignKey::Up),
            "NSDownArrowFunctionKey" => return Some(ForeignKey::Down),
            "NSHomeFunctionKey" => return Some(ForeignKey::Home),
            "NSEndFunctionKey" => return Some(ForeignKey::End),
            "NSPageUpFunctionKey" => return Some(ForeignKey::PageUp),
            "NSPageDownFunctionKey" => return Some(ForeignKey::PageDown),
            "NSDeleteCharacter" | "NSBackspaceCharacter" => return Some(ForeignKey::Backspace),
            "NSDeleteFunctionKey" => return Some(ForeignKey::ForwardDelete),
            "NSCarriageReturnCharacter" | "NSNewlineCharacter" | "NSEnterCharacter" => {
                return Some(ForeignKey::ReturnKey);
            }
            "NSTabCharacter" | "NSBackTabCharacter" => return Some(ForeignKey::Tab),
            "NSProEscapeCharacter" | "NSEscapeCharacter" => return Some(ForeignKey::Escape),
            _ => {}
        }
        if let Some(n) =
            s.strip_prefix("NSF").and_then(|r| r.strip_suffix("FunctionKey")).and_then(|n| n.parse::<i64>().ok())
        {
            return Some(ForeignKey::Function(n));
        }
        let count = s.chars().count();
        if s.starts_with("NS") && count > 4 {
            return None; // another Cocoa name we do not know
        }
        let mut chars = s.chars();
        let (Some(c), None) = (chars.next(), chars.next()) else { return None };
        let u = u32::from(c);
        match u {
            0x20 => Some(ForeignKey::Space),
            0x7F => Some(ForeignKey::Backspace),
            0x0D | 0x03 => Some(ForeignKey::ReturnKey),
            0x09 => Some(ForeignKey::Tab),
            0x1B => Some(ForeignKey::Escape),
            0xF700 => Some(ForeignKey::Up),
            0xF701 => Some(ForeignKey::Down),
            0xF702 => Some(ForeignKey::Left),
            0xF703 => Some(ForeignKey::Right),
            0xF728 => Some(ForeignKey::ForwardDelete),
            0xF729 => Some(ForeignKey::Home),
            0xF72B => Some(ForeignKey::End),
            0xF72C => Some(ForeignKey::PageUp),
            0xF72D => Some(ForeignKey::PageDown),
            0xF704..=0xF726 => Some(ForeignKey::Function(i64::from(u - 0xF704) + 1)),
            _ if (0xF700..=0xF8FF).contains(&u) => None,
            _ => {
                let lower: String = c.to_lowercase().collect();
                let mut l = lower.chars();
                // Lowercasing that grows to several scalars (a grapheme in Swift) keeps the first scalar.
                Some(ForeignKey::Char(l.next().unwrap_or(c)))
            }
        }
    }
}

/// Why a foreign command has no binding.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    /// We have nothing like it.
    NoEquivalent,
    /// macOS or the app menu owns it (Quit, Hide, Minimize).
    System,
    /// We will have it (the Fast Cut commands) but this build does not yet: binds by itself once the command exists.
    PlannedFeature,
}

/// What a foreign command id maps to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    Command(String),
    /// A command of ours that is being built (Fast Cut mode): the id is reserved, the importer binds it as soon as it exists.
    Planned(String),
    System,
    None,
}

/// A foreign command bound to one of our command ids.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    pub source_id: String,
    pub command_id: String,
    /// True for a `planned` row: the importer reports it as unmapped when this build has no such command.
    pub planned: bool,
    pub chords: Vec<ForeignChord>,
    /// Key descriptions of this command that name no key we understand.
    pub unreadable: Vec<String>,
}

/// A foreign command with a key and no equivalent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Unmapped {
    pub source_id: String,
    /// "Blade At Playhead" for "BladeAtPlayhead".
    pub title: String,
    pub reason: Reason,
    pub chords: Vec<ForeignChord>,
}

/// The split of a foreign command list (Swift `ForeignKeymap.Result`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TranslateResult {
    /// Commands with a known equivalent (the id may still be unknown to this build when `planned`).
    pub mapped: Vec<Binding>,
    /// Commands with a key in the file and no equivalent.
    pub unmapped: Vec<Unmapped>,
    /// Commands in the file without any key.
    pub unassigned: usize,
}

/// Translation of foreign commands to ours.
pub struct ForeignKeymap;

impl ForeignKeymap {
    /// Splits the foreign commands into those we have an equivalent for and the rest. Commands without a key are only counted.
    pub fn translate(commands: &[ForeignCommand], table: &BTreeMap<String, Target>) -> TranslateResult {
        let mut r = TranslateResult::default();
        for c in commands {
            if c.chords.is_empty() && c.unreadable.is_empty() {
                r.unassigned += 1;
                continue;
            }
            let binding = |id: &String, planned| Binding {
                source_id: c.source_id.clone(),
                command_id: id.clone(),
                planned,
                chords: c.chords.clone(),
                unreadable: c.unreadable.clone(),
            };
            let unmapped = |reason| Unmapped {
                source_id: c.source_id.clone(),
                title: Self::humanize(&c.source_id),
                reason,
                chords: c.chords.clone(),
            };
            match table.get(&c.source_id).unwrap_or(&Target::None) {
                Target::Command(id) => r.mapped.push(binding(id, false)),
                Target::Planned(id) => r.mapped.push(binding(id, true)),
                Target::System => r.unmapped.push(unmapped(Reason::System)),
                Target::None => r.unmapped.push(unmapped(Reason::NoEquivalent)),
            }
        }
        r
    }

    /// "BladeAtPlayhead" -> "Blade At Playhead", "ColorBoard-NudgePuckUp" -> "Color Board: Nudge Puck Up",
    /// "cmd.sequence.lift" -> "Sequence Lift", "MediaPool.Context_setPosterFrame" -> "Media Pool: Context Set Poster Frame".
    pub fn humanize(id: &str) -> String {
        let dots_are_spaces = id.starts_with("cmd.");
        let source = if dots_are_spaces { &id[4..] } else { id };
        let mut out = String::new();
        let mut prev: Option<char> = None;
        for ch in source.chars() {
            if ch == '-' || (ch == '.' && !dots_are_spaces) {
                out.push_str(": ");
                prev = None;
                continue;
            }
            if ch == '.' || ch == '_' {
                if prev.is_some() {
                    out.push(' ');
                }
                prev = None;
                continue;
            }
            if let Some(p) = prev
                && ch.is_uppercase()
                && (p.is_lowercase() || p.is_numeric())
            {
                out.push(' ');
            }
            out.push(ch);
            prev = Some(ch);
        }
        out.split(' ')
            .filter(|w| !w.is_empty())
            .map(|w| {
                let mut cs = w.chars();
                cs.next().map(|f| f.to_uppercase().chain(cs).collect::<String>()).unwrap_or_default()
            })
            .collect::<Vec<_>>()
            .join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fcpcommand_table::{FCPCommandTable, FCPDefaultSet};

    fn s(v: &str) -> PlistValue {
        PlistValue::String(v.to_string())
    }

    /// One key description: `character`, `characterString`, `modifiers` and an optional `modifierMask`.
    fn k(ch: &str, words: &str, mask: Option<i64>) -> PlistValue {
        let mut d = BTreeMap::new();
        d.insert("character".to_string(), s(ch));
        d.insert("characterString".to_string(), s(ch));
        d.insert("modifiers".to_string(), s(words));
        if let Some(m) = mask {
            d.insert("modifierMask".to_string(), PlistValue::Int(m));
        }
        PlistValue::Dict(d)
    }

    /// Synthetic command set with the structure of a real `.commandset` (dict or array per command).
    fn fixture() -> PlistValue {
        let mut only_mask = BTreeMap::new();
        only_mask.insert("character".to_string(), s("m"));
        only_mask.insert("characterString".to_string(), s("m"));
        only_mask.insert("modifierMask".to_string(), PlistValue::Int(1_835_008));
        let entries = [
            ("BladeAtPlayhead", PlistValue::Array(vec![k("b", "command", None), k("b", "", None)])),
            ("Cut", k("x", "command", None)),
            ("ZoomIn", PlistValue::Array(vec![k("+", "command", None), k("+", "command keypad", None)])),
            ("JumpToStart", k("NSHomeFunctionKey", "function", None)),
            ("NudgeLeftMany", k("NSLeftArrowFunctionKey", "option shift", None)),
            (
                "ReplaceWithGap",
                PlistValue::Array(vec![k("NSDeleteCharacter", "shift", None), k("NSDeleteFunctionKey", "", None)]),
            ),
            ("InsertGap", PlistValue::Array(vec![k("w", "option", None), k("NSCarriageReturnCharacter", "", None)])),
            ("AppendWithSelectedMedia", k("e", "", None)),
            ("Quit", k("q", "command", None)),
            ("ColorBoard-SelectNextPuck", k("", "", None)),
            ("360Difference", k("6", "control option command", None)),
            ("OnlyMask", PlistValue::Dict(only_mask)),
        ];
        PlistValue::Dict(entries.into_iter().map(|(n, v)| (n.to_string(), v)).collect())
    }

    fn read_fixture() -> Vec<ForeignCommand> {
        FCPCommandSetReader::read(&fixture()).unwrap_or_default()
    }

    fn ch(c: char, m: ForeignModifiers) -> ForeignChord {
        ForeignChord::new(ForeignKey::Char(c), m)
    }

    fn bare(k: ForeignKey) -> ForeignChord {
        ForeignChord::new(k, ForeignModifiers::EMPTY)
    }

    #[test]
    fn reads_key_descriptions_into_chords() {
        let cmds = read_fixture();
        let chords = |id: &str| cmds.iter().find(|c| c.source_id == id).map(|c| c.chords.clone()).unwrap_or_default();
        let (cmd, none) = (ForeignModifiers::COMMAND, ForeignModifiers::EMPTY);
        assert_eq!(chords("BladeAtPlayhead"), [ch('b', cmd), ch('b', none)]);
        assert_eq!(chords("Cut"), [ch('x', cmd)]);
        assert_eq!(chords("ZoomIn"), [ch('+', cmd)], "keypad twin is the same chord");
        assert_eq!(chords("JumpToStart"), [bare(ForeignKey::Home)], "function flag is not a modifier");
        assert_eq!(
            chords("NudgeLeftMany"),
            [ForeignChord::new(ForeignKey::Left, ForeignModifiers::OPTION | ForeignModifiers::SHIFT)]
        );
        assert_eq!(
            chords("ReplaceWithGap"),
            [ForeignChord::new(ForeignKey::Backspace, ForeignModifiers::SHIFT), bare(ForeignKey::ForwardDelete)]
        );
        assert_eq!(chords("InsertGap"), [ch('w', ForeignModifiers::OPTION), bare(ForeignKey::ReturnKey)]);
        assert_eq!(
            chords("OnlyMask"),
            [ch('m', ForeignModifiers::CONTROL | ForeignModifiers::OPTION | ForeignModifiers::COMMAND)],
            "mask used when words are missing"
        );
        assert!(chords("ColorBoard-SelectNextPuck").is_empty());
        let ids: Vec<&String> = cmds.iter().map(|c| &c.source_id).collect();
        let mut sorted = ids.clone();
        sorted.sort();
        assert_eq!(ids, sorted, "stable order");
    }

    #[test]
    fn special_key_names() {
        let names = [
            ("NSLeftArrowFunctionKey", ForeignKey::Left),
            ("NSRightArrowFunctionKey", ForeignKey::Right),
            ("NSUpArrowFunctionKey", ForeignKey::Up),
            ("NSDownArrowFunctionKey", ForeignKey::Down),
            ("NSEndFunctionKey", ForeignKey::End),
            ("NSPageUpFunctionKey", ForeignKey::PageUp),
            ("NSCarriageReturnCharacter", ForeignKey::ReturnKey),
            ("NSTabCharacter", ForeignKey::Tab),
            ("NSDeleteCharacter", ForeignKey::Backspace),
            ("NSProEscapeCharacter", ForeignKey::Escape),
            ("NSF9FunctionKey", ForeignKey::Function(9)),
            (" ", ForeignKey::Space),
            ("F", ForeignKey::Char('f')),
            ("ß", ForeignKey::Char('ß')),
        ];
        for (name, key) in names {
            assert_eq!(FCPCommandSetReader::key(name), Some(key), "{name}");
        }
        assert_eq!(FCPCommandSetReader::key("NSSomethingNewFunctionKey"), None);
        assert_eq!(FCPCommandSetReader::key("ab"), None);
    }

    #[test]
    fn modifier_mask_bits() {
        let m = FCPCommandSetReader::modifiers;
        assert_eq!(m(None, Some(131_072)), ForeignModifiers::SHIFT);
        assert_eq!(m(None, Some(262_144)), ForeignModifiers::CONTROL);
        assert_eq!(m(None, Some(524_288)), ForeignModifiers::OPTION);
        assert_eq!(m(None, Some(1_048_576)), ForeignModifiers::COMMAND);
        assert_eq!(m(Some(""), Some(1_048_576)), ForeignModifiers::COMMAND, "empty words fall back to the mask");
        assert_eq!(m(Some("shift"), Some(1_048_576)), ForeignModifiers::SHIFT, "non-empty words win");
        assert_eq!(m(Some(""), Some(0)), ForeignModifiers::EMPTY);
        assert_eq!(m(None, Some(131_072 | 1_048_576)), ForeignModifiers::SHIFT | ForeignModifiers::COMMAND);
        assert_eq!(m(Some("shift keypad function"), None), ForeignModifiers::SHIFT);
    }

    #[test]
    fn rejects_files_that_are_not_command_sets() {
        let plain = PlistValue::Dict(
            [("Name".to_string(), s("x")), ("Count".to_string(), PlistValue::Int(3))].into_iter().collect(),
        );
        assert_eq!(FCPCommandSetReader::read(&plain), Err(ReadError::NotACommandSet));
        assert_eq!(FCPCommandSetReader::read(&s("hello")), Err(ReadError::NotACommandSet));
        let array = PlistValue::Array(vec![PlistValue::Int(1), PlistValue::Int(2)]);
        assert_eq!(FCPCommandSetReader::read(&array), Err(ReadError::NotACommandSet));
    }

    #[test]
    fn translate_splits_mapped_planned_system_and_unmapped() {
        let r = ForeignKeymap::translate(&read_fixture(), &FCPCommandTable::rows());
        let mapped: BTreeMap<&str, &Binding> = r.mapped.iter().map(|b| (b.source_id.as_str(), b)).collect();
        assert_eq!(mapped["BladeAtPlayhead"].command_id, "addEdit");
        assert_eq!(mapped["Cut"].command_id, "cut");
        assert_eq!(mapped["JumpToStart"].command_id, "goToStart");
        assert_eq!(mapped["ReplaceWithGap"].command_id, "delete");
        assert!(mapped["AppendWithSelectedMedia"].planned);
        assert!(!mapped["Cut"].planned);
        let unmapped: BTreeMap<&str, &Unmapped> = r.unmapped.iter().map(|u| (u.source_id.as_str(), u)).collect();
        assert_eq!(unmapped["360Difference"].reason, Reason::NoEquivalent);
        assert_eq!(unmapped["360Difference"].title, "360 Difference");
        assert_eq!(unmapped["Quit"].reason, Reason::System);
        assert!(!unmapped.contains_key("ColorBoard-SelectNextPuck"), "no key: only counted");
        assert_eq!(r.unassigned, 1);
    }

    #[test]
    fn humanize_splits_camel_case() {
        assert_eq!(ForeignKeymap::humanize("BladeAtPlayhead"), "Blade At Playhead");
        assert_eq!(ForeignKeymap::humanize("ColorBoard-NudgePuckUp"), "Color Board: Nudge Puck Up");
        assert_eq!(ForeignKeymap::humanize("Cut"), "Cut");
        assert_eq!(ForeignKeymap::humanize("cmd.sequence.lift"), "Sequence Lift");
        assert_eq!(ForeignKeymap::humanize("MediaPool.Context_setPosterFrame"), "Media Pool: Context Set Poster Frame");
    }

    #[test]
    fn chord_specs() {
        let spec = ForeignChord::from_spec;
        assert_eq!(spec("cmd+shift+b"), Some(ch('b', ForeignModifiers::COMMAND | ForeignModifiers::SHIFT)));
        assert_eq!(spec("option+left"), Some(ForeignChord::new(ForeignKey::Left, ForeignModifiers::OPTION)));
        assert_eq!(spec("control+="), Some(ch('=', ForeignModifiers::CONTROL)));
        assert_eq!(spec("shift+delete"), Some(ForeignChord::new(ForeignKey::Backspace, ForeignModifiers::SHIFT)));
        assert_eq!(spec("f9"), Some(bare(ForeignKey::Function(9))));
        assert_eq!(spec("hyper+b"), None);
        assert_eq!(spec(""), None);
    }

    #[test]
    fn built_in_default_set_is_well_formed() {
        let table = FCPCommandTable::rows();
        let commands = FCPDefaultSet::commands();
        for c in &commands {
            assert!(!c.chords.is_empty(), "{} has an unreadable spec", c.source_id);
            assert!(table.contains_key(&c.source_id), "{} is not in the table", c.source_id);
        }
        assert!(ForeignKeymap::translate(&commands, &table).unmapped.is_empty());
        // No two Final Cut commands share a chord in the default set.
        let mut seen: BTreeMap<String, String> = BTreeMap::new();
        for c in &commands {
            for chord in &c.chords {
                let key = format!("{chord:?}");
                let prev = seen.insert(key, c.source_id.clone());
                assert!(prev.is_none(), "{} and {} share a key", c.source_id, prev.unwrap_or_default());
            }
        }
    }
}

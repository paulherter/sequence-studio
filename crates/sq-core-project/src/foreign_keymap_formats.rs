// SPDX-License-Identifier: GPL-3.0-or-later
//! Premiere Pro `.kys` and DaVinci Resolve keyboard layout readers (docs/KEYMAP.md "Premiere and Resolve import").
//! Both produce `ForeignCommand`s for the same translate / import pipeline as the Final Cut `.commandset`.
// Swift: ForeignKeymapFormats.swift
//
// UNVERIFIED: written from published descriptions of the formats, never run against a real file of either app.
// Premiere: XML, `<PremiereData><shortcuts>` with context elements holding `item.N` (virtualkey, modifier.*, commandname).
// Resolve: plain text, one `commandId := chord | chord` per line (a gist of a real export was the source).
//
// The XML is read with `sq_prproj_reader::fastxml` (UTF-8 only; the Swift reader used Foundation's `XMLParser`).
// `ForeignKeymapFile::read` takes the already parsed property list instead of the bytes: the caller parses it with
// `plist_reader::parse_plist` and passes `None` when the bytes are no property list.

use crate::fcpcommand_table::FCPCommandTable;
use crate::foreign_keymap::{
    FCPCommandSetReader, ForeignChord, ForeignCommand, ForeignKey, ForeignModifiers, PlistValue, Target,
};
use crate::media_filter_tokens::trim_blanks;
use crate::premiere_command_table::PremiereCommandTable;
use crate::resolve_command_table;
use sq_prproj_reader::Node;
use std::collections::BTreeMap;

// MARK: Premiere Pro .kys

/// The file is no keyboard layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PremiereReadError {
    /// No XML, or XML without `shortcuts` and without commands.
    NotAKeyboardLayout,
}

/// Reads Premiere Pro's `.kys`.
pub struct PremiereKysReader;

/// Commands in first-seen order with their chords.
#[derive(Default)]
struct Collected {
    order: Vec<String>,
    chords: BTreeMap<String, Vec<ForeignChord>>,
    unreadable: BTreeMap<String, Vec<String>>,
    saw_shortcuts: bool,
}

impl PremiereKysReader {
    /// Sorted by command name so results are stable. A command bound in several contexts keeps each distinct chord once.
    pub fn read(data: &[u8]) -> Result<Vec<ForeignCommand>, PremiereReadError> {
        let parsed = sq_prproj_reader::fastxml::parse(data).ok_or(PremiereReadError::NotAKeyboardLayout)?;
        let mut c = Collected::default();
        Self::walk(&parsed.root, &mut c);
        if !c.saw_shortcuts && c.order.is_empty() {
            return Err(PremiereReadError::NotAKeyboardLayout);
        }
        let mut names = c.order.clone();
        names.sort();
        Ok(names
            .into_iter()
            .map(|name| ForeignCommand {
                chords: c.chords.remove(&name).unwrap_or_default(),
                unreadable: c.unreadable.remove(&name).unwrap_or_default(),
                source_id: name,
            })
            .collect())
    }

    fn walk(n: &Node, c: &mut Collected) {
        if n.name == "shortcuts" {
            c.saw_shortcuts = true;
        }
        if n.name.starts_with("item.")
            && let Some(cmd) = n.child("commandname").map(|t| trim_all(&t.text)).filter(|t| !t.is_empty())
        {
            if !c.chords.contains_key(&cmd) {
                c.order.push(cmd.clone());
                c.chords.insert(cmd.clone(), Vec::new());
            }
            let code = n.child("virtualkey").and_then(|k| trim_all(&k.text).parse::<i64>().ok());
            if let Some(code) = code {
                if let Some(key) = Self::key(code) {
                    let chord = ForeignChord::new(key, Self::modifiers(n));
                    let list = c.chords.entry(cmd).or_default();
                    if !list.contains(&chord) {
                        list.push(chord);
                    }
                } else {
                    let u = format!("key code {code}");
                    let list = c.unreadable.entry(cmd).or_default();
                    if !list.contains(&u) {
                        list.push(u);
                    }
                }
            }
        }
        for child in &n.children {
            Self::walk(child, c);
        }
    }

    /// Modifier child elements: `modifier.ctrl` is Command on a Mac, `modifier.alt` Option. The control-key tag name on
    /// a Mac is unverified (control / macctrl accepted). A modifier element counts unless its text says false.
    fn modifiers(item: &Node) -> ForeignModifiers {
        let mut m = ForeignModifiers::EMPTY;
        for c in item.children.iter().filter(|c| c.name.starts_with("modifier.")) {
            let t = trim_all(&c.text).to_lowercase();
            if t == "false" || t == "0" {
                continue;
            }
            match c.name["modifier.".len()..].to_lowercase().as_str() {
                "ctrl" | "cmd" | "command" => m = m | ForeignModifiers::COMMAND,
                "alt" | "option" => m = m | ForeignModifiers::OPTION,
                "shift" => m = m | ForeignModifiers::SHIFT,
                "control" | "macctrl" | "macctl" => m = m | ForeignModifiers::CONTROL,
                _ => {}
            }
        }
        m
    }

    /// Printable keys are `0x80000000 | ASCII` (G = 2147483719; verified for letters). Small numbers are special keys:
    /// F5 = 11 and F6 = 12 are verified, F1..F12 = 7..18 is extrapolated; arrows, Home, End and the rest are NOT
    /// decoded because no source for their numbers was found: they are reported as unreadable.
    fn key(v: i64) -> Option<ForeignKey> {
        if v & 0x8000_0000 != 0 {
            let a = v & 0x7FFF_FFFF;
            return match a {
                32 => Some(ForeignKey::Space),
                9 => Some(ForeignKey::Tab),
                13 => Some(ForeignKey::ReturnKey),
                27 => Some(ForeignKey::Escape),
                8 => Some(ForeignKey::Backspace),
                127 => Some(ForeignKey::ForwardDelete),
                33..=126 => u8::try_from(a).ok().map(|b| ForeignKey::Char(char::from(b).to_ascii_lowercase())),
                _ => None,
            };
        }
        (7..=18).contains(&v).then(|| ForeignKey::Function(v - 6))
    }
}

/// Swift `trimmingCharacters(in: .whitespacesAndNewlines)`.
fn trim_all(s: &str) -> String {
    s.trim().to_string()
}

// MARK: DaVinci Resolve keyboard layout

/// The file is no keyboard layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResolveReadError {
    /// Not UTF-8 text, or no `id := keys` line.
    NotAKeyboardLayout,
}

/// Reads a DaVinci Resolve keyboard layout export.
pub struct ResolveKeymapReader;

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

impl ResolveKeymapReader {
    /// Commands sorted by id; a repeated id adds its chords to the first.
    pub fn read(data: &[u8]) -> Result<Vec<ForeignCommand>, ResolveReadError> {
        let text = std::str::from_utf8(data).map_err(|_| ResolveReadError::NotAKeyboardLayout)?;
        let mut out: Vec<ForeignCommand> = Vec::new();
        let mut seen: BTreeMap<String, usize> = BTreeMap::new();
        for line in text.split(is_newline) {
            let Some((head, tail)) = line.split_once(":=") else { continue };
            let id = trim_blanks(head);
            if !Self::is_identifier(id) {
                continue;
            }
            let mut chords: Vec<ForeignChord> = Vec::new();
            let mut unreadable: Vec<String> = Vec::new();
            for part in tail.split('|') {
                let spec = trim_blanks(part);
                if spec.is_empty() {
                    continue;
                }
                match Self::chord(spec) {
                    Some(c) => {
                        if !chords.contains(&c) {
                            chords.push(c);
                        }
                    }
                    None => unreadable.push(spec.to_string()),
                }
            }
            if let Some(&i) = seen.get(id) {
                // a repeated id adds to the first
                for c in chords {
                    if !out[i].chords.contains(&c) {
                        out[i].chords.push(c);
                    }
                }
                out[i].unreadable.extend(unreadable);
            } else {
                seen.insert(id.to_string(), out.len());
                out.push(ForeignCommand { source_id: id.to_string(), chords, unreadable });
            }
        }
        if out.is_empty() {
            return Err(ResolveReadError::NotAKeyboardLayout);
        }
        out.sort_by(|a, b| a.source_id.cmp(&b.source_id));
        Ok(out)
    }

    fn is_identifier(s: &str) -> bool {
        !s.is_empty() && s.chars().all(|c| c.is_alphabetic() || c.is_numeric() || c == '_' || c == '.')
    }

    /// "Ctrl+Shift+Z", "Alt+Backspace", "Num+6", "Ctrl++". Qt-style names; Ctrl is Command on a Mac, Meta is Control
    /// (unverified), Num is the keypad (dropped: a keypad twin is the same chord).
    fn chord(spec: &str) -> Option<ForeignChord> {
        let (key_name, mod_part) = if spec == "+" {
            ("+", "")
        } else if let Some(mods) = spec.strip_suffix("++") {
            ("+", mods)
        } else if let Some(i) = spec.rfind('+') {
            (&spec[i + 1..], &spec[..i])
        } else {
            (spec, "")
        };
        let mut m = ForeignModifiers::EMPTY;
        for tok in mod_part.split('+').filter(|t| !t.is_empty()) {
            match tok.to_lowercase().as_str() {
                "ctrl" | "cmd" => m = m | ForeignModifiers::COMMAND,
                "alt" | "opt" => m = m | ForeignModifiers::OPTION,
                "shift" => m = m | ForeignModifiers::SHIFT,
                "meta" => m = m | ForeignModifiers::CONTROL,
                "num" => {}
                _ => return None,
            }
        }
        Self::key(key_name).map(|k| ForeignChord::new(k, m))
    }

    // shortcut: a one-key name is one Unicode scalar (Swift counts Characters), like `ForeignKey::Char`.
    fn key(name: &str) -> Option<ForeignKey> {
        let n = name.to_lowercase();
        match n.as_str() {
            "space" => Some(ForeignKey::Space),
            "left" => Some(ForeignKey::Left),
            "right" => Some(ForeignKey::Right),
            "up" => Some(ForeignKey::Up),
            "down" => Some(ForeignKey::Down),
            "home" => Some(ForeignKey::Home),
            "end" => Some(ForeignKey::End),
            "pgup" | "pageup" => Some(ForeignKey::PageUp),
            "pgdown" | "pagedown" | "pgdn" => Some(ForeignKey::PageDown),
            "backspace" => Some(ForeignKey::Backspace),
            "del" | "delete" => Some(ForeignKey::ForwardDelete),
            "return" | "enter" => Some(ForeignKey::ReturnKey),
            "tab" => Some(ForeignKey::Tab),
            "esc" | "escape" => Some(ForeignKey::Escape),
            _ => {
                let mut chars = n.chars();
                let first = chars.next()?;
                if chars.clone().next().is_none() {
                    return Some(ForeignKey::Char(first));
                }
                if first == 'f'
                    && let Ok(f) = chars.as_str().parse::<i64>()
                    && f > 0
                {
                    return Some(ForeignKey::Function(f));
                }
                None
            }
        }
    }
}

// MARK: Detection

/// Which program a keyboard layout file comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ForeignKeymapFormat {
    /// Final Cut Pro `.commandset`.
    FinalCut,
    /// Premiere Pro `.kys`.
    Premiere,
    /// DaVinci Resolve layout.
    Resolve,
}

impl ForeignKeymapFormat {
    /// The command table of that program.
    pub fn table(self) -> BTreeMap<String, Target> {
        match self {
            ForeignKeymapFormat::FinalCut => FCPCommandTable::rows(),
            ForeignKeymapFormat::Premiere => PremiereCommandTable::rows(),
            ForeignKeymapFormat::Resolve => {
                resolve_command_table::rows().map(|(name, target)| (name.to_string(), target)).collect()
            }
        }
    }
}

/// A layout file read by `ForeignKeymapFile::read`.
#[derive(Clone, Debug, PartialEq)]
pub struct Contents {
    /// Which program wrote it.
    pub format: ForeignKeymapFormat,
    /// Its commands.
    pub commands: Vec<ForeignCommand>,
}

/// No reader accepts the file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ForeignKeymapFileError {
    /// Not a property list, not Premiere XML, not Resolve text.
    UnknownFormat,
}

/// Picks the reader by content.
pub struct ForeignKeymapFile;

impl ForeignKeymapFile {
    /// A property list is Final Cut (`plist` is the parsed bytes, `None` if they are no property list), XML with
    /// `PremiereData` / `shortcuts` is Premiere, text with `id := keys` lines is Resolve.
    pub fn read(data: &[u8], plist: Option<&PlistValue>) -> Result<Contents, ForeignKeymapFileError> {
        if let Some(commands) = plist.and_then(|p| FCPCommandSetReader::read(p).ok()) {
            return Ok(Contents { format: ForeignKeymapFormat::FinalCut, commands });
        }
        let head = String::from_utf8_lossy(&data[..data.len().min(4096)]);
        if (head.contains("<PremiereData") || head.contains("<shortcuts"))
            && let Ok(commands) = PremiereKysReader::read(data)
        {
            return Ok(Contents { format: ForeignKeymapFormat::Premiere, commands });
        }
        if let Ok(commands) = ResolveKeymapReader::read(data) {
            return Ok(Contents { format: ForeignKeymapFormat::Resolve, commands });
        }
        Err(ForeignKeymapFileError::UnknownFormat)
    }
}

#[cfg(test)]
mod tests;

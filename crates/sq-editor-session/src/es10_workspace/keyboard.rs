//! Keyboard geometry of the Keyboard Shortcuts window and what the picture shows for a modifier layer.

use sq_os::Platform;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::command_map::{CommandMap, Entry};
use sq_uikit::editor_command::CommandScope;
use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::key_group::KeyGroup;
use sq_uikit::keyboard_listing::KeyboardListing;

use super::storage::env_var;

/// One key cap on the picture, in points.
// Swift: KeyboardLayout.swift:5
#[derive(Clone, Debug, PartialEq)]
pub struct KeyCap {
    // Swift: KeyboardLayout.swift:7
    pub label: String,
    /// `None` for caps the key map cannot bind (Tab, Caps Lock, Return, modifiers): drawn plain, not selectable.
    // Swift: KeyboardLayout.swift:9
    pub key: Option<Key>,
    // Swift: KeyboardLayout.swift:10
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    /// An empty cap (the upper half of the ISO Return key): not drawn, not selectable.
    // Swift: KeyboardLayout.swift:12
    pub is_ghost: bool,
}

/// The keyboard layout the picture follows.
// Swift: KeyboardLayout.swift:18
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum KeyboardStyle {
    /// ANSI.
    Us,
    /// ISO, German.
    German,
}

impl KeyboardStyle {
    /// Every style, in order.
    pub const ALL: [KeyboardStyle; 2] = [KeyboardStyle::Us, KeyboardStyle::German];

    // Swift: KeyboardLayout.swift:23
    pub const DEFAULTS_KEY: &'static str = "sq.shortcuts.keyboardLayout";

    /// The stored name.
    pub fn raw_value(self) -> &'static str {
        match self {
            KeyboardStyle::Us => "us",
            KeyboardStyle::German => "german",
        }
    }

    /// Popup title ("Layout: German").
    // Swift: KeyboardLayout.swift:22
    pub fn title(self) -> String {
        format!("Layout: {}", if self == KeyboardStyle::Us { "US" } else { "German" })
    }

    /// Saved choice (`sq.shortcuts.keyboardLayout`), else the system's.
    // Swift: KeyboardLayout.swift:28
    pub fn saved(d: &dyn UiDefaults) -> KeyboardStyle {
        d.string(Self::DEFAULTS_KEY)
            .and_then(|s| Self::ALL.into_iter().find(|k| k.raw_value() == s))
            .unwrap_or_else(Self::system)
    }

    /// The layout of the system: the region of the user's locale (German, Austrian, Swiss: German), else US.
    /// The active keyboard layout from the platform backend; without one (tests, headless) the locale environment.
    // Swift: KeyboardLayout.swift:127
    // Swift: KeyboardLayout.swift:138
    pub fn system() -> KeyboardStyle {
        if let Some(k) = sq_os::keyboard::active() {
            return if k.is_german() { KeyboardStyle::German } else { KeyboardStyle::Us };
        }
        let locale = ["LC_ALL", "LC_MESSAGES", "LANG"]
            .iter()
            .filter_map(|k| env_var(k))
            .find(|v| !v.is_empty())
            .unwrap_or_default();
        Self::for_locale(&locale)
    }

    /// The layout for a locale name such as `de_AT.UTF-8`.
    pub fn for_locale(locale: &str) -> KeyboardStyle {
        let id = locale.split(['.', '@']).next().unwrap_or("");
        let region = id.split(['_', '-']).nth(1).unwrap_or("");
        if ["DE", "AT", "CH"].contains(&region) { KeyboardStyle::German } else { KeyboardStyle::Us }
    }
}

/// Keyboard geometry of the Keyboard Shortcuts window (design board "Windows": 50 x 42 keys, 6 pt gaps, every row
/// centered). The picture follows the chosen layout: the labels (and so the characters a binding is looked up by)
/// move with it.
// Swift: KeyboardLayout.swift:20
pub enum KeyboardLayout {}

/// A cap in a row spec: label, key, width.
type Cap = (&'static str, Option<Key>, f64);

/// One letter row: optional lead cap, the character keys, tail cap; `ghost_tail` = invisible (ISO Return, upper half).
struct Spec {
    lead: Option<Cap>,
    keys: Vec<String>,
    tail: Cap,
    ghost_tail: bool,
}

fn letters(s: &str) -> Vec<String> {
    s.chars().map(String::from).collect()
}

fn keys(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| s.to_string()).collect()
}

impl KeyboardLayout {
    // Swift: KeyboardLayout.swift:32
    pub const KEY_WIDTH: f64 = 50.0;
    // Swift: KeyboardLayout.swift:34
    pub const KEY_HEIGHT: f64 = 42.0;
    // Swift: KeyboardLayout.swift:35
    pub const GAP: f64 = 6.0;
    // Swift: KeyboardLayout.swift:36
    pub const WIDTH: f64 = 840.0;
    // Swift: KeyboardLayout.swift:37
    pub const HEIGHT: f64 = 5.0 * Self::KEY_HEIGHT + 4.0 * Self::GAP;

    fn rows(style: KeyboardStyle) -> Vec<Spec> {
        let join =
            |a: Vec<String>, b: &[&str]| a.into_iter().chain(b.iter().map(|s| s.to_string())).collect::<Vec<_>>();
        match style {
            KeyboardStyle::German => vec![
                Spec {
                    lead: None,
                    keys: keys(&["^", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "\u{df}", "\u{b4}"]),
                    tail: ("\u{232b}", Some(Key::Delete), 78.0),
                    ghost_tail: false,
                },
                Spec {
                    lead: Some(("\u{21e5}", None, 62.0)),
                    keys: join(letters("QWERTZUIOP"), &["\u{dc}", "+"]),
                    tail: ("", None, 72.0),
                    ghost_tail: true,
                },
                Spec {
                    lead: Some(("\u{21ea}", None, 74.0)),
                    keys: join(letters("ASDFGHJKL"), &["\u{d6}", "\u{c4}", "#"]),
                    tail: ("\u{21a9}", None, 60.0),
                    ghost_tail: false,
                },
                Spec {
                    lead: Some(("\u{21e7}", None, 70.0)),
                    keys: join(keys(&["<"]).into_iter().chain(letters("YXCVBNM")).collect(), &[",", ".", "-"]),
                    tail: ("\u{21e7}", None, 64.0),
                    ghost_tail: false,
                },
            ],
            KeyboardStyle::Us => vec![
                Spec {
                    lead: None,
                    keys: keys(&["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="]),
                    tail: ("\u{232b}", Some(Key::Delete), 78.0),
                    ghost_tail: false,
                },
                Spec {
                    lead: Some(("\u{21e5}", None, 62.0)),
                    keys: join(letters("QWERTYUIOP"), &["[", "]"]),
                    tail: ("\\", Some(Key::Char('\\')), 72.0),
                    ghost_tail: false,
                },
                Spec {
                    lead: Some(("\u{21ea}", None, 74.0)),
                    keys: join(letters("ASDFGHJKL"), &[";", "'"]),
                    tail: ("\u{21a9}", None, 84.0),
                    ghost_tail: false,
                },
                Spec {
                    lead: Some(("\u{21e7}", None, 112.0)),
                    keys: join(letters("ZXCVBNM"), &[",", ".", "/"]),
                    tail: ("\u{21e7}", None, 112.0),
                    ghost_tail: false,
                },
            ],
        }
    }

    // Swift: KeyboardLayout.swift:69
    pub fn caps(style: KeyboardStyle) -> Vec<KeyCap> {
        let mut out = Vec::new();
        let mut place = |r: usize, items: Vec<(Cap, String, bool)>| {
            let total = items.iter().map(|i| i.0.2).sum::<f64>() + Self::GAP * (items.len() as f64 - 1.0);
            let mut x = (Self::WIDTH - total) / 2.0;
            let y = r as f64 * (Self::KEY_HEIGHT + Self::GAP);
            for (cap, label, ghost) in items {
                out.push(KeyCap { label, key: cap.1, x, y, w: cap.2, h: Self::KEY_HEIGHT, is_ghost: ghost });
                x += cap.2 + Self::GAP;
            }
        };
        for (r, spec) in Self::rows(style).into_iter().enumerate() {
            let mut items: Vec<(Cap, String, bool)> = Vec::new();
            if let Some(l) = spec.lead {
                items.push((l, l.0.to_string(), false));
            }
            for k in &spec.keys {
                let lower = k.to_lowercase().chars().next();
                items.push((("", lower.map(Key::Char), Self::KEY_WIDTH), k.clone(), false));
            }
            items.push((spec.tail, spec.tail.0.to_string(), spec.ghost_tail));
            place(r, items);
        }
        let bottom: [Cap; 11] = [
            ("fn", None, 56.0),
            ("\u{2303}", None, 56.0),
            ("\u{2325}", None, 56.0),
            ("\u{2318}", None, 70.0),
            ("Space", Some(Key::Space), 232.0),
            ("\u{2318}", None, 60.0),
            ("\u{2325}", None, 50.0),
            ("\u{2190}", Some(Key::Left), 50.0),
            ("\u{2191}", Some(Key::Up), 50.0),
            ("\u{2193}", Some(Key::Down), 50.0),
            ("\u{2192}", Some(Key::Right), 50.0),
        ];
        place(4, bottom.iter().map(|c| (*c, c.0.to_string(), false)).collect());
        out
    }
}

/// What the picture shows for a modifier layer: which commands each key runs.
// Swift: KeyboardLayout.swift:97
#[derive(Clone, Debug)]
pub struct KeyboardLayoutModel {
    // Swift: KeyboardLayout.swift:99
    pub map: CommandMap,
    // Swift: KeyboardLayout.swift:100
    pub modifiers: KeyModifiers,
}

impl KeyboardLayoutModel {
    // Swift: KeyboardLayout.swift:101
    pub fn new(map: CommandMap, modifiers: KeyModifiers) -> KeyboardLayoutModel {
        KeyboardLayoutModel { map, modifiers }
    }

    /// Bindings of `key` with the current modifiers, any scope; global first.
    // Swift: KeyboardLayout.swift:105
    pub fn entries(&self, key: Key) -> Vec<Entry> {
        let b = KeyBinding::new(key, self.modifiers);
        let mut found: Vec<Entry> = self.map.entries.iter().filter(|e| e.binding == b).copied().collect();
        found.sort_by_key(|e| if e.scope == CommandScope::Global { 0 } else { 1 });
        found
    }

    /// Color group of a key (the first binding wins); `None` when the key is free in this layer.
    // Swift: KeyboardLayout.swift:111
    pub fn group(&self, key: Key) -> Option<KeyGroup> {
        self.entries(key).first().map(|e| KeyGroup::of(&e.command))
    }

    /// One-line description for the info label, e.g. "C: Blade Tool (Everywhere)".
    // Swift: KeyboardLayout.swift:114
    pub fn summary(&self, key: Key, platform: Platform) -> String {
        let text = KeyBindingText::text(&KeyBinding::new(key, self.modifiers), platform);
        let es = self.entries(key);
        if es.is_empty() {
            return format!("{text}: free");
        }
        let rows: Vec<String> =
            es.iter().map(|e| format!("{} ({})", e.command.title(), KeyboardListing::scope_name(e.scope))).collect();
        format!("{text}: {}", rows.join(", "))
    }
}

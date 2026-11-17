// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: FontResolver.swift
//! Resolves a `TextStyle` (font name + weight) to a concrete font.
//!
//! An explicit face name (PostScript or full name that differs from the family name, e.g. "Helvetica-Bold")
//! wins: the style's weight is ignored. Only a bare family name ("Helvetica", ".AppleSystemUIFont") lets
//! `weight` pick the face. Order (family mode): variable-font weight axis / weight trait first, then the nearest
//! available face of the family.
//!
//! The scoped cache of the Swift resolver only holds Core Text fonts, so `with_scoped_cache` has nothing to keep here.

use crate::text_backend_portable::PlatformFont;
use crate::text_style::{FontWeight, TextStyle};
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, PoisonError};

/// One variation axis of a font.
#[derive(Clone, Debug, PartialEq)]
pub struct Axis {
    /// Four-letter axis tag.
    pub tag: String,
    /// Shown name.
    pub name: String,
    /// Smallest user value.
    pub minimum: f64,
    /// Largest user value.
    pub maximum: f64,
    /// Default user value.
    pub default_value: f64,
}

/// Namespace of the font resolver functions.
pub enum FontResolver {}

impl FontResolver {
    /// Core Text weight trait (`kCTFontWeightTrait`, about -1...1) for a `FontWeight`.
    pub fn trait_value(weight: FontWeight) -> f64 {
        match weight {
            FontWeight::Thin => -0.6,
            FontWeight::Light => -0.4,
            FontWeight::Regular => 0.0,
            FontWeight::Medium => 0.23,
            FontWeight::Semibold => 0.3,
            FontWeight::Bold => 0.4,
            FontWeight::Heavy => 0.56,
            FontWeight::Black => 0.62,
        }
    }

    /// Weight trait of the font the style resolves to.
    pub fn resolved_weight_trait(style: &TextStyle) -> f64 {
        Self::weight_trait_of(&Self::font_for(style))
    }

    /// The font a style resolves to, remembered by name, size, weight, italic and axes.
    pub fn font_for(style: &TextStyle) -> PlatformFont {
        let key = FontKey {
            name: style.font_name.clone(),
            size: style.size.to_bits(),
            weight: style.weight,
            italic: style.italic,
            axes: style.font_axes.as_ref().map(|a| a.iter().map(|(k, v)| (k.clone(), v.to_bits())).collect()),
        };
        Self::memo().font(key, || Self::resolve_font(style))
    }

    /// The four-letter tag of a big-endian tag number.
    pub fn tag_of(id: u32) -> String {
        String::from_utf8_lossy(&id.to_be_bytes()).into_owned()
    }

    /// The tag number of a four-byte tag.
    pub fn identifier_of(tag: &str) -> Option<u32> {
        let b = tag.as_bytes();
        if b.len() != 4 {
            return None;
        }
        Some(b.iter().fold(0u32, |a, x| a << 8 | u32::from(*x)))
    }

    /// The process-wide memo of resolved fonts and caption fitting sizes.
    pub fn memo() -> &'static Memo {
        static MEMO: LazyLock<Memo> = LazyLock::new(Memo::default);
        &MEMO
    }

    /// The registered fonts changed (a font was installed or registered): every remembered font is resolved again.
    pub fn fonts_changed() {
        Self::memo().clear();
    }

    /// Runs `body` with font resolution memoised (output is identical to resolving every time).
    pub fn with_scoped_cache<T>(body: impl FnOnce() -> T) -> T {
        body()
    }
}

/// Key of a resolved font.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct FontKey {
    name: String,
    size: u64,
    weight: FontWeight,
    italic: bool,
    axes: Option<Vec<(String, u64)>>,
}

/// Key of a fitting size: the text, the style (as its JSON) and the box width.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct FitKey {
    text: String,
    style: String,
    box_width: u64,
}

impl FitKey {
    /// A key for `text` in `style` over `box_width`. `TextStyle` has no `Hash`, so its JSON stands in.
    pub fn new(text: &str, style: &TextStyle, box_width: f64) -> FitKey {
        FitKey {
            text: text.to_string(),
            style: serde_json::to_string(style).unwrap_or_default(),
            box_width: box_width.to_bits(),
        }
    }
}

#[derive(Default)]
struct MemoState {
    fonts: HashMap<FontKey, PlatformFont>,
    fits: HashMap<FitKey, f64>,
    generation: u64,
}

/// Resolved fonts and caption fitting sizes of the whole process: resolving a family and weight walks the family's
/// descriptors, and playback asked for the same few fonts on every frame. Dropped whenever the registered fonts change
/// (`fonts_changed`), so a font installed later resolves fresh.
#[derive(Default)]
pub struct Memo {
    state: Mutex<MemoState>,
}

impl Memo {
    /// Most entries per table before it is emptied.
    pub const LIMIT: usize = 512;

    fn lock(&self) -> std::sync::MutexGuard<'_, MemoState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The remembered font under `key`, or the one `make` builds.
    pub fn font(&self, key: FontKey, make: impl FnOnce() -> PlatformFont) -> PlatformFont {
        let generation = {
            let s = self.lock();
            if let Some(hit) = s.fonts.get(&key) {
                return hit.clone();
            }
            s.generation
        };
        let f = make();
        let mut s = self.lock();
        if s.generation == generation {
            if s.fonts.len() >= Self::LIMIT {
                s.fonts.clear();
            }
            s.fonts.insert(key, f.clone());
        }
        f
    }

    /// The remembered fitting size under `key`, or the one `make` measures.
    pub fn fit(&self, key: FitKey, make: impl FnOnce() -> f64) -> f64 {
        let generation = {
            let s = self.lock();
            if let Some(hit) = s.fits.get(&key) {
                return *hit;
            }
            s.generation
        };
        let v = make();
        let mut s = self.lock();
        if s.generation == generation {
            if s.fits.len() >= Self::LIMIT {
                s.fits.clear();
            }
            s.fits.insert(key, v);
        }
        v
    }

    /// Forgets everything; a value made across the change is not kept.
    pub fn clear(&self) {
        let mut s = self.lock();
        s.fonts.clear();
        s.fits.clear();
        s.generation = s.generation.wrapping_add(1);
    }

    /// Entries held.
    pub fn count(&self) -> usize {
        let s = self.lock();
        s.fonts.len() + s.fits.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_round_trip() {
        let id = FontResolver::identifier_of("wght");
        assert_eq!(id, Some(0x7767_6874));
        assert_eq!(FontResolver::tag_of(0x7767_6874), "wght");
        assert_eq!(FontResolver::identifier_of("wg"), None);
    }

    #[test]
    fn weight_traits_follow_core_text() {
        assert_eq!(FontResolver::trait_value(FontWeight::Regular), 0.0);
        assert_eq!(FontResolver::trait_value(FontWeight::Black), 0.62);
    }

    #[test]
    fn memo_keeps_a_fit_until_cleared() {
        let memo = Memo::default();
        let key = FitKey::new("hello", &TextStyle::default(), 100.0);
        assert_eq!(memo.fit(key.clone(), || 42.0), 42.0);
        assert_eq!(memo.fit(key.clone(), || 7.0), 42.0);
        memo.clear();
        assert_eq!(memo.fit(key, || 7.0), 7.0);
    }
}

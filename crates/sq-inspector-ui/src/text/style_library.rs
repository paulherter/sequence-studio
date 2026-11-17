// Swift: TextStyleLibrary.swift
//! The styles of the Text panel: the Look library seen as styles, and its store.

use sq_core_time::IdSource;
use sq_editor_session::{LookStore, StoreError};
use sq_text::look::{Look, LookLibrary, LookValues};
use sq_text::text_style::TextStyle;

/// One text style in the Text panel: a name and a look. A view of a `Look` that shows only its style.
#[derive(Clone, Debug, PartialEq)]
pub struct TextStyleEntry {
    pub id: String,
    pub name: String,
    pub style: TextStyle,
    pub is_built_in: bool,
}

impl TextStyleEntry {
    pub fn new(id: &str, name: &str, style: TextStyle, is_built_in: bool) -> TextStyleEntry {
        TextStyleEntry { id: id.to_string(), name: name.to_string(), style, is_built_in }
    }

    fn from_look(look: &Look) -> TextStyleEntry {
        TextStyleEntry {
            id: look.id.clone(),
            name: look.name.clone(),
            style: look.style.clone(),
            is_built_in: look.is_built_in,
        }
    }
}

/// The styles of the Text panel: the Look library seen as styles. Built-in Looks are read-only, the saved ones follow in
/// creation order. Editing a style changes only the style of its Look; what else the Look holds stays.
#[derive(Clone, Debug, Default)]
pub struct TextStyleLibrary {
    looks: LookLibrary,
    /// The Look library as this copy was read from the store (empty for one made in memory): saving applies only what
    /// the copy changed against it, so an old copy never removes a Look it has not seen. Not part of equality.
    base: LookLibrary,
}

impl PartialEq for TextStyleLibrary {
    fn eq(&self, other: &Self) -> bool {
        self.looks == other.looks
    }
}

impl TextStyleLibrary {
    pub fn new(looks: LookLibrary, base: LookLibrary) -> TextStyleLibrary {
        TextStyleLibrary { looks, base }
    }

    /// A library of the given saved styles (no base).
    pub fn with_user(user: Vec<TextStyleEntry>) -> TextStyleLibrary {
        let looks = user.into_iter().map(|e| Look::new(&e.id, &e.name, e.style)).collect();
        TextStyleLibrary::new(LookLibrary::new(looks, Default::default()), LookLibrary::default())
    }

    pub fn looks(&self) -> &LookLibrary {
        &self.looks
    }

    pub fn base(&self) -> &LookLibrary {
        &self.base
    }

    pub fn user(&self) -> Vec<TextStyleEntry> {
        self.looks.user().iter().map(TextStyleEntry::from_look).collect()
    }

    pub fn entries(&self) -> Vec<TextStyleEntry> {
        self.looks.looks().iter().map(TextStyleEntry::from_look).collect()
    }

    pub fn entry(&self, id: &str) -> Option<TextStyleEntry> {
        self.looks.look(id).map(|l| TextStyleEntry::from_look(&l))
    }

    /// The id of the first style whose look equals `style` exactly (user styles first, so a saved copy wins).
    pub fn match_style(&self, style: &TextStyle) -> Option<String> {
        self.looks.match_style(style)
    }

    /// Saves `style` under a trimmed `name`; `None` for an empty name.
    pub fn add(&mut self, name: &str, style: TextStyle, ids: &mut dyn IdSource) -> Option<String> {
        self.looks.add(name, LookValues::new(style), None, ids)
    }

    pub fn rename(&mut self, id: &str, name: &str) -> bool {
        self.looks.rename(id, name)
    }

    pub fn update(&mut self, id: &str, style: TextStyle) -> bool {
        self.looks.update_style(id, style)
    }

    pub fn delete(&mut self, id: &str) -> bool {
        self.looks.delete(id)
    }

    /// An editable copy ("Name Copy", "Name Copy 2", ...) of any style, built-in or not.
    pub fn duplicate(&mut self, id: &str, ids: &mut dyn IdSource) -> Option<String> {
        self.looks.duplicate(id, ids)
    }

    pub fn built_ins() -> Vec<TextStyleEntry> {
        LookLibrary::built_ins().iter().map(TextStyleEntry::from_look).collect()
    }
}

/// Reads and writes the Text panel's styles: a view of the Look store. Unreadable or missing file = no user styles.
// shortcut: the Swift default-URL / own-URL switch (`store(url)`) belongs to the app that owns the `LookStore` values;
// these functions take the store, upgrade when the app shell exists.
pub enum TextStyleStore {}

impl TextStyleStore {
    pub fn load(store: &LookStore) -> TextStyleLibrary {
        let looks = store.library();
        TextStyleLibrary::new(looks.clone(), looks)
    }

    /// Applies what `library` changed since it was loaded; Looks changed elsewhere in the meantime are kept.
    pub fn save(library: &TextStyleLibrary, store: &LookStore) -> Result<(), StoreError> {
        store.replace(library.looks.clone(), &library.base)
    }
}

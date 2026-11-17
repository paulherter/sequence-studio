// Swift: PresetOrganizer.swift
//! Categories, tags, favorites and usage of presets and built-in templates; filtering and sorting of the preset list.

use crate::favorites::{LibraryStoreError, json_file_io};
use crate::library_search::{fold, numeric_compare};
use crate::preset_store::{PresetKind, PresetStore};
use crate::watched_folder::DISTANT_PAST;
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, Timestamp};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};

/// Shelf a preset or template is listed under. Display names are our own words.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PresetCategory {
    /// Titles.
    Titles,
    /// Lower thirds.
    LowerThirds,
    /// Captions.
    Captions,
    /// Social.
    Social,
    /// Effects.
    Effects,
    /// Transitions.
    Transitions,
    /// Motion.
    Motion,
    /// Everything else.
    Other,
}

impl PresetCategory {
    /// Every case, in declaration order.
    pub const ALL: [PresetCategory; 8] = [
        PresetCategory::Titles,
        PresetCategory::LowerThirds,
        PresetCategory::Captions,
        PresetCategory::Social,
        PresetCategory::Effects,
        PresetCategory::Transitions,
        PresetCategory::Motion,
        PresetCategory::Other,
    ];

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            PresetCategory::Titles => "Titles",
            PresetCategory::LowerThirds => "Lower Thirds",
            PresetCategory::Captions => "Captions",
            PresetCategory::Social => "Social",
            PresetCategory::Effects => "Effects",
            PresetCategory::Transitions => "Transitions",
            PresetCategory::Motion => "Motion",
            PresetCategory::Other => "Other",
        }
    }

    /// Category a preset of this kind starts in until the user moves it.
    pub fn default_for(kind: PresetKind) -> PresetCategory {
        match kind {
            PresetKind::TextTemplate
            | PresetKind::AnimatedTextTemplate
            | PresetKind::TitleBlock
            | PresetKind::TitleTemplate => PresetCategory::Titles,
            PresetKind::Caption => PresetCategory::Captions,
            PresetKind::Effect => PresetCategory::Effects,
            PresetKind::Transition => PresetCategory::Transitions,
            PresetKind::Easing | PresetKind::Keystone => PresetCategory::Motion,
        }
    }

    /// Category of a built-in text template, guessed from its name.
    pub fn inferred(name: &str) -> PresetCategory {
        let n = fold(name);
        if n.contains("lower third") || n.contains("lower-third") {
            PresetCategory::LowerThirds
        } else if ["cta", "end card", "subscribe", "follow"].iter().any(|w| n.contains(w)) {
            PresetCategory::Social
        } else if n.contains("caption") || n.contains("subtitle") {
            PresetCategory::Captions
        } else {
            PresetCategory::Titles
        }
    }
}

/// What the user attached to a preset or built-in template. Stored beside the presets, never inside a project.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PresetMeta {
    /// Moved to this shelf by the user.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<PresetCategory>,
    /// Tags, at most `PresetMetaTable::MAX_TAGS`.
    pub tags: Vec<String>,
    /// Marked as favorite.
    pub is_favorite: bool,
    /// When it was last used.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "sq_core_time::timestamp::iso8601::option")]
    pub last_used: Option<Timestamp>,
    /// How often it was used.
    pub use_count: i64,
}

impl PresetMeta {
    /// Nothing worth saving.
    fn is_default(&self) -> bool {
        *self == PresetMeta::default()
    }
}

/// Stable key of one list entry: `user:<uuid>` for a saved preset, `builtin:<id>` for a shipped template.
pub struct PresetKey;

impl PresetKey {
    /// Key of a saved preset.
    pub fn user(id: Id) -> String {
        format!("user:{id}")
    }

    /// Key of a shipped template.
    pub fn built_in(id: &str) -> String {
        format!("builtin:{id}")
    }
}

/// Metadata of all presets, by `PresetKey`. Value type; the owner persists it with `PresetMetaStore`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PresetMetaTable {
    entries: BTreeMap<String, PresetMeta>,
}

impl PresetMetaTable {
    /// Most tags per preset.
    pub const MAX_TAGS: usize = 8;
    /// Longest tag in characters.
    pub const MAX_TAG_LENGTH: usize = 24;
    /// Tags offered in menus (other tags from files are kept and shown).
    pub const SUGGESTED_TAGS: [&'static str; 10] =
        ["bold", "clean", "minimal", "retro", "glow", "outline", "box", "news", "gaming", "cinematic"];

    /// An empty table.
    pub fn new() -> PresetMetaTable {
        PresetMetaTable::default()
    }

    /// The stored metadata, keyed by `PresetKey`.
    pub fn entries(&self) -> &BTreeMap<String, PresetMeta> {
        &self.entries
    }

    /// The metadata of `key` (the default when none is stored).
    pub fn get(&self, key: &str) -> PresetMeta {
        self.entries.get(key).cloned().unwrap_or_default()
    }

    fn edit(&mut self, key: &str, change: impl FnOnce(&mut PresetMeta)) {
        let mut m = self.get(key);
        change(&mut m);
        if m.is_default() {
            self.entries.remove(key);
        } else {
            self.entries.insert(key.to_string(), m);
        }
    }

    /// Returns the new state (true = now a favorite).
    pub fn toggle_favorite(&mut self, key: &str) -> bool {
        let mut now = false;
        self.edit(key, |m| {
            m.is_favorite = !m.is_favorite;
            now = m.is_favorite;
        });
        now
    }

    /// Moves a preset to a shelf (`None` = its default shelf).
    pub fn set_category(&mut self, key: &str, category: Option<PresetCategory>) {
        self.edit(key, |m| m.category = category);
    }

    /// Lower-cased, trimmed, at most 24 characters; `None` when empty.
    pub fn normalized_tag(raw: &str) -> Option<String> {
        let t = raw.trim().to_lowercase();
        (!t.is_empty()).then(|| t.chars().take(Self::MAX_TAG_LENGTH).collect())
    }

    /// Ignored when empty, a duplicate, or the preset already has 8 tags.
    pub fn add_tag(&mut self, key: &str, raw: &str) {
        let Some(tag) = Self::normalized_tag(raw) else { return };
        self.edit(key, |m| {
            if !m.tags.contains(&tag) && m.tags.len() < Self::MAX_TAGS {
                m.tags.push(tag);
            }
        });
    }

    /// Removes a tag.
    pub fn remove_tag(&mut self, key: &str, raw: &str) {
        let Some(tag) = Self::normalized_tag(raw) else { return };
        self.edit(key, |m| m.tags.retain(|t| *t != tag));
    }

    /// Adds the tag, or removes it when the preset has it.
    pub fn toggle_tag(&mut self, key: &str, raw: &str) {
        let Some(tag) = Self::normalized_tag(raw) else { return };
        if self.get(key).tags.contains(&tag) {
            self.remove_tag(key, &tag);
        } else {
            self.add_tag(key, &tag);
        }
    }

    /// Counts a use at `at`.
    pub fn record_use(&mut self, key: &str, at: Timestamp) {
        self.edit(key, |m| {
            m.last_used = Some(at);
            m.use_count += 1;
        });
    }

    /// Drops metadata of user presets that no longer exist. Built-in keys always stay.
    pub fn prune(&mut self, keeping_user_keys: &BTreeSet<String>) {
        self.entries.retain(|k, _| k.starts_with("builtin:") || keeping_user_keys.contains(k));
    }

    fn restore(&mut self, key: String, meta: PresetMeta) {
        if !meta.is_default() {
            self.entries.insert(key, meta);
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MetaFile {
    format_version: i64,
    entries: BTreeMap<String, PresetMeta>,
}

/// Versioned JSON persistence for `PresetMetaTable` (`<Application Support>/Sequence Studio/Library/preset-meta.json`).
pub struct PresetMetaStore;

impl PresetMetaStore {
    /// Version of the file format.
    pub const FORMAT_VERSION: i64 = 1;

    /// Where the table lives.
    pub fn file_url_in(application_support: &Path) -> PathBuf {
        let presets = PresetStore::file_url_in(application_support);
        presets.with_file_name("preset-meta.json")
    }

    /// A newer file version fails (file untouched); a damaged file is moved aside (stamped `now`) and the table starts empty.
    pub fn load(path: &Path, now: Timestamp) -> Result<PresetMetaTable, LibraryStoreError> {
        let mut table = PresetMetaTable::new();
        if let json_file_io::Loaded::Value(file) =
            json_file_io::load_versioned::<MetaFile>(path, Self::FORMAT_VERSION, now)?
        {
            for (k, v) in file.entries {
                table.restore(k, v);
            }
        }
        Ok(table)
    }

    /// Writes the table.
    pub fn save(table: &PresetMetaTable, path: &Path) -> Result<(), LibraryStoreError> {
        json_file_io::write_atomically(
            &MetaFile { format_version: Self::FORMAT_VERSION, entries: table.entries.clone() },
            path,
        )
    }
}

// MARK: - Listing

/// One row of the preset list, built-in or user.
#[derive(Clone, Debug, PartialEq)]
pub struct PresetListEntry {
    /// `PresetKey`.
    pub key: String,
    /// Shown name.
    pub name: String,
    /// Ships with the app.
    pub is_built_in: bool,
    /// When it was saved.
    pub created_at: Timestamp,
    /// The shelf: the user's choice or the default.
    pub category: PresetCategory,
    /// What the user attached.
    pub meta: PresetMeta,
}

impl PresetListEntry {
    /// An entry; the shelf is the user's (`meta`) or `default_category`.
    pub fn new(
        key: &str,
        name: &str,
        is_built_in: bool,
        created_at: Option<Timestamp>,
        default_category: PresetCategory,
        meta: PresetMeta,
    ) -> PresetListEntry {
        PresetListEntry {
            key: key.to_string(),
            name: name.to_string(),
            is_built_in,
            created_at: created_at.unwrap_or(DISTANT_PAST),
            category: meta.category.unwrap_or(default_category),
            meta,
        }
    }

    /// The tags of the entry.
    pub fn tags(&self) -> &[String] {
        &self.meta.tags
    }
}

/// What the list is sorted by.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PresetSortKey {
    /// Name A-Z.
    Name,
    /// Newest first.
    Newest,
    /// Most used first.
    MostUsed,
    /// Last used first.
    RecentlyUsed,
}

impl PresetSortKey {
    /// Every case.
    pub const ALL: [PresetSortKey; 4] =
        [PresetSortKey::Name, PresetSortKey::Newest, PresetSortKey::MostUsed, PresetSortKey::RecentlyUsed];

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            PresetSortKey::Name => "Name",
            PresetSortKey::Newest => "Newest",
            PresetSortKey::MostUsed => "Most Used",
            PresetSortKey::RecentlyUsed => "Recently Used",
        }
    }
}

/// Which part of the list is shown.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PresetScope {
    /// Everything.
    All,
    /// Favorites.
    Favorites,
    /// Recently used.
    Recent,
    /// Shipped with the app.
    BuiltIn,
    /// Made by the user.
    Yours,
}

impl PresetScope {
    /// Every case.
    pub const ALL: [PresetScope; 5] =
        [PresetScope::All, PresetScope::Favorites, PresetScope::Recent, PresetScope::BuiltIn, PresetScope::Yours];

    /// Shown name.
    pub fn title(self) -> &'static str {
        match self {
            PresetScope::All => "All",
            PresetScope::Favorites => "Favorites",
            PresetScope::Recent => "Recent",
            PresetScope::BuiltIn => "Built-in",
            PresetScope::Yours => "Yours",
        }
    }
}

/// What the list shows.
#[derive(Clone, Debug, PartialEq)]
pub struct PresetFilter {
    /// Search words.
    pub query: String,
    /// Only this shelf.
    pub category: Option<PresetCategory>,
    /// Which part.
    pub scope: PresetScope,
    /// Only entries with this tag.
    pub tag: Option<String>,
}

impl Default for PresetFilter {
    fn default() -> Self {
        PresetFilter { query: String::new(), category: None, scope: PresetScope::All, tag: None }
    }
}

impl PresetFilter {
    /// Anything but the query narrows the list.
    pub fn is_active(&self) -> bool {
        *self != PresetFilter { query: self.query.clone(), ..PresetFilter::default() }
    }
}

/// Filtering, sorting and counting of the preset list.
pub struct PresetOrganizer;

fn by_name(a: &PresetListEntry, b: &PresetListEntry) -> Ordering {
    numeric_compare(&fold(&a.name), &fold(&b.name)).then_with(|| a.key.cmp(&b.key))
}

fn time_order(a: Timestamp, b: Timestamp) -> Ordering {
    a.partial_cmp(&b).unwrap_or(Ordering::Equal)
}

impl PresetOrganizer {
    /// Entries shown in the Recent scope.
    pub const RECENT_LIMIT: usize = 12;

    /// Filter, then sort. Search matches name, tags and category title (all words must match).
    /// Natural order: name A-Z, newest first, most used first, last used first; `ascending: false` reverses it.
    /// Ties fall back to name.
    pub fn visible(
        entries: &[PresetListEntry],
        filter: &PresetFilter,
        sort: PresetSortKey,
        ascending: bool,
    ) -> Vec<PresetListEntry> {
        let folded = fold(&filter.query);
        let tokens: Vec<&str> = folded.split_whitespace().collect();
        let tag = filter.tag.as_deref().and_then(PresetMetaTable::normalized_tag);
        let mut list: Vec<PresetListEntry> = entries
            .iter()
            .filter(|e| {
                if filter.category.is_some_and(|c| e.category != c) {
                    return false;
                }
                if tag.as_ref().is_some_and(|t| !e.tags().contains(t)) {
                    return false;
                }
                let in_scope = match filter.scope {
                    PresetScope::All => true,
                    PresetScope::Favorites => e.meta.is_favorite,
                    PresetScope::Recent => e.meta.last_used.is_some(),
                    PresetScope::BuiltIn => e.is_built_in,
                    PresetScope::Yours => !e.is_built_in,
                };
                if !in_scope {
                    return false;
                }
                let mut parts = vec![e.name.as_str(), e.category.title()];
                parts.extend(e.tags().iter().map(String::as_str));
                let hay = fold(&parts.join(" "));
                tokens.iter().all(|t| hay.contains(t))
            })
            .cloned()
            .collect();
        let last_used = |e: &PresetListEntry| e.meta.last_used.unwrap_or(DISTANT_PAST);
        list.sort_by(|a, b| match sort {
            PresetSortKey::Name => by_name(a, b),
            PresetSortKey::Newest => time_order(b.created_at, a.created_at).then_with(|| by_name(a, b)),
            PresetSortKey::MostUsed => b.meta.use_count.cmp(&a.meta.use_count).then_with(|| by_name(a, b)),
            PresetSortKey::RecentlyUsed => time_order(last_used(b), last_used(a)).then_with(|| by_name(a, b)),
        });
        if filter.scope == PresetScope::Recent {
            list.sort_by(|a, b| time_order(last_used(b), last_used(a)));
            list.truncate(Self::RECENT_LIMIT);
        }
        if !ascending {
            list.reverse();
        }
        list
    }

    /// Tags in use with their counts, most used first.
    pub fn tag_counts(entries: &[PresetListEntry]) -> Vec<(String, usize)> {
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for e in entries {
            for t in e.tags() {
                *counts.entry(t).or_insert(0) += 1;
            }
        }
        let mut out: Vec<(String, usize)> = counts.into_iter().map(|(t, c)| (t.to_string(), c)).collect();
        out.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        out
    }

    /// Entries per shelf.
    pub fn category_counts(entries: &[PresetListEntry]) -> HashMap<PresetCategory, usize> {
        let mut out = HashMap::new();
        for e in entries {
            *out.entry(e.category).or_insert(0) += 1;
        }
        out
    }
}

// MARK: - Hover card text

/// Text lines of the hover card of a preset or template. Pure so it can be tested.
pub struct PresetHoverInfo;

impl PresetHoverInfo {
    /// The lines to show.
    pub fn lines(e: &PresetListEntry) -> Vec<String> {
        let mut out = vec![format!("{} · {}", if e.is_built_in { "Built-in" } else { "Yours" }, e.category.title())];
        if !e.tags().is_empty() {
            out.push(e.tags().iter().map(|t| format!("#{t}")).collect::<Vec<_>>().join(" "));
        }
        if e.meta.use_count > 0 {
            out.push(format!("Used {} {}", e.meta.use_count, if e.meta.use_count == 1 { "time" } else { "times" }));
        }
        if e.meta.is_favorite {
            out.push("Favorite".to_string());
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;

    const NOW: Timestamp = Timestamp::from_reference_seconds(800_000_000.0);

    fn entry(name: &str, built_in: bool, created: f64, cat: PresetCategory, meta: PresetMeta) -> PresetListEntry {
        let key = if built_in { PresetKey::built_in(name) } else { format!("user:{name}") };
        PresetListEntry::new(&key, name, built_in, Some(Timestamp::from_unix_seconds(created)), cat, meta)
    }

    fn used(at: f64, count: i64) -> PresetMeta {
        PresetMeta { last_used: Some(Timestamp::from_unix_seconds(at)), use_count: count, ..PresetMeta::default() }
    }

    fn names(list: &[PresetListEntry]) -> Vec<&str> {
        list.iter().map(|e| e.name.as_str()).collect()
    }

    #[test]
    fn default_categories_follow_kind() {
        assert_eq!(PresetCategory::default_for(PresetKind::TitleBlock), PresetCategory::Titles);
        assert_eq!(PresetCategory::default_for(PresetKind::TitleTemplate), PresetCategory::Titles);
        assert_eq!(PresetCategory::default_for(PresetKind::Caption), PresetCategory::Captions);
        assert_eq!(PresetCategory::default_for(PresetKind::Keystone), PresetCategory::Motion);
        assert_eq!(PresetCategory::inferred("Lower Third Bar"), PresetCategory::LowerThirds);
        assert_eq!(PresetCategory::inferred("CTA End Card"), PresetCategory::Social);
        assert_eq!(PresetCategory::inferred("Bold Box"), PresetCategory::Titles);
    }

    #[test]
    fn tags_are_normalised_deduped_and_capped() {
        let mut t = PresetMetaTable::new();
        t.add_tag("k", "  Bold ");
        t.add_tag("k", "bold");
        t.add_tag("k", "  ");
        assert_eq!(t.get("k").tags, ["bold"]);
        for i in 0..20 {
            t.add_tag("k", &format!("tag{i}"));
        }
        assert_eq!(t.get("k").tags.len(), PresetMetaTable::MAX_TAGS);
        t.add_tag("long", &"x".repeat(60));
        assert_eq!(t.get("long").tags[0].chars().count(), PresetMetaTable::MAX_TAG_LENGTH);
        t.toggle_tag("k", "BOLD");
        assert!(!t.get("k").tags.contains(&"bold".to_string()));
    }

    #[test]
    fn default_meta_is_not_stored() {
        let mut t = PresetMetaTable::new();
        t.toggle_favorite("a");
        assert_eq!(t.entries().len(), 1);
        t.toggle_favorite("a");
        assert!(t.entries().is_empty());
    }

    #[test]
    fn record_use_counts_and_stamps() {
        let mut t = PresetMetaTable::new();
        let d = Timestamp::from_unix_seconds(500.0);
        t.record_use("a", d);
        t.record_use("a", Timestamp::from_unix_seconds(510.0));
        assert_eq!(t.get("a").use_count, 2);
        assert_eq!(t.get("a").last_used, Some(Timestamp::from_unix_seconds(510.0)));
    }

    #[test]
    fn prune_keeps_built_ins_and_live_user_keys() {
        let mut t = PresetMetaTable::new();
        for k in ["builtin:x", "user:gone", "user:live"] {
            t.toggle_favorite(k);
        }
        t.prune(&BTreeSet::from(["user:live".to_string()]));
        assert_eq!(t.entries().keys().map(String::as_str).collect::<Vec<_>>(), ["builtin:x", "user:live"]);
    }

    #[test]
    fn sort_keys() {
        let t = PresetCategory::Titles;
        let a = entry("Alpha", false, 10.0, t, used(5.0, 1));
        let b = entry("Beta", false, 30.0, t, used(9.0, 7));
        let c = entry("Gamma", false, 20.0, t, PresetMeta::default());
        let all = [c, a, b];
        let sorted = |s, asc| {
            names(&PresetOrganizer::visible(&all, &PresetFilter::default(), s, asc))
                .iter()
                .map(|n| (*n).to_string())
                .collect::<Vec<_>>()
        };
        assert_eq!(sorted(PresetSortKey::Name, true), ["Alpha", "Beta", "Gamma"]);
        assert_eq!(sorted(PresetSortKey::Name, false), ["Gamma", "Beta", "Alpha"]);
        assert_eq!(sorted(PresetSortKey::Newest, true), ["Beta", "Gamma", "Alpha"]);
        assert_eq!(sorted(PresetSortKey::MostUsed, true), ["Beta", "Alpha", "Gamma"]);
        assert_eq!(sorted(PresetSortKey::RecentlyUsed, true), ["Beta", "Alpha", "Gamma"]);
    }

    #[test]
    fn filters_by_scope_category_tag_and_query() {
        let t = PresetCategory::Titles;
        let fav = entry(
            "Pop",
            false,
            0.0,
            t,
            PresetMeta { tags: vec!["bold".into()], is_favorite: true, ..PresetMeta::default() },
        );
        let built = entry("Classic", true, 0.0, PresetCategory::Captions, PresetMeta::default());
        let slide = entry("Slide", false, 0.0, t, PresetMeta { tags: vec!["clean".into()], ..used(1.0, 1) });
        let all = [fav, built, slide];
        let shown = |f: PresetFilter| {
            names(&PresetOrganizer::visible(&all, &f, PresetSortKey::Name, true))
                .iter()
                .map(|n| (*n).to_string())
                .collect::<Vec<_>>()
        };
        let base = PresetFilter::default;
        assert_eq!(shown(PresetFilter { scope: PresetScope::Favorites, ..base() }), ["Pop"]);
        assert_eq!(shown(PresetFilter { scope: PresetScope::Recent, ..base() }), ["Slide"]);
        assert_eq!(shown(PresetFilter { scope: PresetScope::BuiltIn, ..base() }), ["Classic"]);
        assert_eq!(shown(PresetFilter { scope: PresetScope::Yours, ..base() }), ["Pop", "Slide"]);
        assert_eq!(shown(PresetFilter { category: Some(PresetCategory::Captions), ..base() }), ["Classic"]);
        assert_eq!(shown(PresetFilter { tag: Some(" Bold ".into()), ..base() }), ["Pop"]);
        assert_eq!(shown(PresetFilter { query: "clean".into(), ..base() }), ["Slide"]); // tag match
        assert_eq!(shown(PresetFilter { query: "captions".into(), ..base() }), ["Classic"]); // category title match
        assert_eq!(shown(PresetFilter { query: "pop bold".into(), ..base() }), ["Pop"]);
        assert!(shown(PresetFilter { query: "pop clean".into(), ..base() }).is_empty());
        assert!(!PresetFilter { query: "x".into(), ..base() }.is_active());
        assert!(PresetFilter { scope: PresetScope::Yours, ..base() }.is_active());
    }

    #[test]
    fn recent_scope_is_capped_newest_first() {
        let list: Vec<PresetListEntry> = (0..20)
            .map(|i| entry(&format!("P{i}"), false, 0.0, PresetCategory::Titles, used(f64::from(i), 1)))
            .collect();
        let f = PresetFilter { scope: PresetScope::Recent, ..PresetFilter::default() };
        let r = PresetOrganizer::visible(&list, &f, PresetSortKey::Name, true);
        assert_eq!((r.len(), r[0].name.as_str()), (PresetOrganizer::RECENT_LIMIT, "P19"));
    }

    #[test]
    fn meta_overrides_category() {
        let e = entry(
            "X",
            false,
            0.0,
            PresetCategory::Titles,
            PresetMeta { category: Some(PresetCategory::Social), ..PresetMeta::default() },
        );
        assert_eq!(e.category, PresetCategory::Social);
    }

    #[test]
    fn counts_and_hover_lines() {
        let a = entry(
            "A",
            false,
            0.0,
            PresetCategory::Titles,
            PresetMeta { tags: vec!["x".into(), "y".into()], use_count: 2, ..PresetMeta::default() },
        );
        let b = entry(
            "B",
            false,
            0.0,
            PresetCategory::Effects,
            PresetMeta { tags: vec!["x".into()], ..PresetMeta::default() },
        );
        let all = [a.clone(), b];
        assert_eq!(PresetOrganizer::tag_counts(&all).first().map(|t| t.0.as_str()), Some("x"));
        assert_eq!(PresetOrganizer::category_counts(&all).get(&PresetCategory::Effects), Some(&1));
        assert_eq!(PresetHoverInfo::lines(&a), ["Yours · Titles", "#x #y", "Used 2 times"]);
    }

    #[test]
    fn store_round_trips_and_rejects_newer_version() {
        let dir = TempDir::new();
        let url = PresetMetaStore::file_url_in(dir.path());
        let mut t = PresetMetaTable::new();
        t.toggle_favorite("user:1");
        t.add_tag("user:1", "bold");
        t.set_category("builtin:z", Some(PresetCategory::Social));
        t.record_use("user:1", Timestamp::from_unix_seconds(100.0));
        assert!(PresetMetaStore::save(&t, &url).is_ok());
        assert_eq!(PresetMetaStore::load(&url, NOW), Ok(t));
        let _ = std::fs::write(&url, br#"{"formatVersion":99,"entries":{}}"#);
        assert_eq!(PresetMetaStore::load(&url, NOW), Err(LibraryStoreError::NewerFormat { found: 99, supported: 1 }));
    }

    #[test]
    fn corrupt_file_starts_empty_and_is_moved_aside() {
        let dir = TempDir::new();
        let url = PresetMetaStore::file_url_in(dir.path());
        let _ = std::fs::create_dir_all(url.parent().unwrap_or(Path::new(".")));
        let _ = std::fs::write(&url, b"nonsense");
        assert_eq!(PresetMetaStore::load(&url, NOW), Ok(PresetMetaTable::new()));
        assert!(!url.exists());
    }
}

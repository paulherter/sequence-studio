// Swift: EffectFolderModel.swift
//! The user's Effects panel folders and the folder outline the panel shows.

use crate::effects::effects_catalog::{EffectsEntry, EffectsRow};
use serde::{Deserialize, Serialize};
use sq_core_model::ClipEffect;
use sq_core_time::{Id, IdSource};
use sq_editor_session::EffectDragPayload;
use sq_text::text_presets::TextPresetCatalog;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::sqicon::SQIcon;
use std::collections::{BTreeSet, HashMap};

/// A folder the user made in the Effects panel. Items are effect / transition / preset row ids (`EffectsEntry.id`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct UserEffectFolder {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Row ids, in the order added.
    pub items: Vec<String>,
}

/// The user's own Effects panel folders. Lives in the settings store (not in the project file): it is a personal library
/// layout.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EffectFolderStore {
    folders: Vec<UserEffectFolder>,
}

impl EffectFolderStore {
    /// The settings key.
    pub const KEY: &'static str = "sq.effects.userFolders";

    /// An empty store.
    pub fn new() -> EffectFolderStore {
        EffectFolderStore::default()
    }

    /// The folders, in panel order.
    pub fn folders(&self) -> &[UserEffectFolder] {
        &self.folders
    }

    /// The folder with this id.
    pub fn folder(&self, id: Id) -> Option<&UserEffectFolder> {
        self.folders.iter().find(|f| f.id == id)
    }

    /// Empty names become "New Folder"; taken names get " 2", " 3", ...
    fn unique_name(&self, raw: &str, excluding: Option<Id>) -> String {
        let base = raw.trim();
        let name = if base.is_empty() { "New Folder" } else { base };
        let taken: BTreeSet<String> =
            self.folders.iter().filter(|f| Some(f.id) != excluding).map(|f| f.name.to_lowercase()).collect();
        if !taken.contains(&name.to_lowercase()) {
            return name.to_string();
        }
        let mut n = 2;
        while taken.contains(&format!("{name} {n}").to_lowercase()) {
            n += 1;
        }
        format!("{name} {n}")
    }

    /// Makes a folder at the end and returns its id.
    pub fn create_folder(&mut self, name: &str, ids: &mut dyn IdSource) -> Id {
        let f = UserEffectFolder { id: ids.next_id(), name: self.unique_name(name, None), items: Vec::new() };
        let id = f.id;
        self.folders.push(f);
        id
    }

    /// Renames a folder (an empty name is ignored).
    pub fn rename(&mut self, id: Id, name: &str) {
        let Some(i) = self.folders.iter().position(|f| f.id == id) else { return };
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return;
        }
        self.folders[i].name = self.unique_name(trimmed, Some(id));
    }

    /// Deletes a folder.
    pub fn delete(&mut self, id: Id) {
        self.folders.retain(|f| f.id != id);
    }

    /// Puts an item in a folder (once).
    pub fn add(&mut self, item: &str, id: Id) {
        let Some(i) = self.folders.iter().position(|f| f.id == id) else { return };
        if self.folders[i].items.iter().any(|x| x == item) {
            return;
        }
        self.folders[i].items.push(item.to_string());
    }

    /// Takes an item out of a folder.
    pub fn remove(&mut self, item: &str, id: Id) {
        let Some(i) = self.folders.iter().position(|f| f.id == id) else { return };
        self.folders[i].items.retain(|x| x != item);
    }

    /// Drag-reorder of user folders: `id` goes in front of `target` (None = last).
    pub fn move_folder(&mut self, id: Id, target: Option<Id>) {
        if Some(id) == target {
            return;
        }
        let Some(from) = self.folders.iter().position(|f| f.id == id) else { return };
        let f = self.folders.remove(from);
        let to = target.and_then(|t| self.folders.iter().position(|x| x.id == t)).unwrap_or(self.folders.len());
        self.folders.insert(to, f);
    }

    /// The saved folders; unreadable data reads as none.
    pub fn load(defaults: &dyn UiDefaults) -> EffectFolderStore {
        defaults.data(Self::KEY).and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    /// Saves the folders.
    pub fn save(&self, defaults: &mut dyn UiDefaults) {
        if let Ok(data) = serde_json::to_vec(self) {
            defaults.set_data(Self::KEY, &data);
        }
    }
}

/// Outline keys on the selected row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutlineKey {
    /// Left arrow.
    Left,
    /// Right arrow.
    Right,
}

/// What an outline key does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Navigation {
    /// Nothing.
    None,
    /// Open or close this folder row (by row id).
    Toggle(String),
    /// Select the row at this index.
    Select(usize),
}

/// Builds the Effects panel rows: folders (Presets, Video > category, Transitions / Crossfades) plus the
/// user's folders on top. Pure, so ordering, expansion and search are tested without a view.
pub enum EffectFolderOutline {}

impl EffectFolderOutline {
    /// The settings key of the open folders.
    pub const EXPANDED_KEY: &'static str = "sq.effects.expandedFolders";
    /// Saved presets and the built-in presets.
    pub const PRESETS_FOLDER: &'static str = "Presets";
    /// Video effects.
    pub const EFFECTS_FOLDER: &'static str = "Video Effects";
    /// Video transitions.
    pub const VIDEO_TRANSITIONS: &'static str = "Video Transitions";
    /// Audio transitions.
    pub const AUDIO_TRANSITIONS: &'static str = "Audio Transitions";
    /// Audio effects.
    pub const AUDIO_EFFECTS_FOLDER: &'static str = "Audio Effects";
    /// The top-level folders, in panel order.
    pub const BUILTIN_ORDER: [&'static str; 5] = [
        Self::PRESETS_FOLDER,
        Self::EFFECTS_FOLDER,
        Self::VIDEO_TRANSITIONS,
        Self::AUDIO_EFFECTS_FOLDER,
        Self::AUDIO_TRANSITIONS,
    ];

    /// The kit's video groups in panel order (Sequence Studio pack first, Transitions and Audio after them).
    pub const KIT_GROUPS: [&'static str; 7] =
        ["Color & Basics", "Blur & Sharpen", "Distort", "Stylize", "Film & Retro", "Stabilize", "Time"];

    /// The kit group of a catalog category: the older categories fold into the seven groups (nothing is dropped, the
    /// search still finds an effect by its old category name).
    pub fn kit_group(category: &str) -> &str {
        match category {
            "Cutout" => "Color & Basics",
            "Transform" => "Distort",
            "Motion" => "Time",
            "Repair" => "Blur & Sharpen",
            other => other,
        }
    }

    /// Shown names of the top-level bins (docs/VOCABULARY.md). Folder ids, saved expansion state and entry categories keep
    /// the stored names; only the display changes.
    pub fn display_name(name: &str) -> String {
        match name {
            Self::PRESETS_FOLDER => "Sequence Studio pack",
            Self::EFFECTS_FOLDER => "Video",
            Self::VIDEO_TRANSITIONS => "Transitions",
            Self::AUDIO_EFFECTS_FOLDER => "Audio",
            Self::AUDIO_TRANSITIONS => "Crossfades",
            other => other,
        }
        .to_string()
    }

    /// The row id of a built-in folder (`sub` = a sub-folder).
    pub fn builtin_id(folder: &str, sub: Option<&str>) -> String {
        format!("folder.builtin.{folder}{}", sub.map(|s| format!("/{s}")).unwrap_or_default())
    }

    /// The row id of a user folder.
    pub fn user_id(id: Id) -> String {
        format!("folder.user.{id}")
    }

    /// The saved open folders.
    pub fn load_expanded(d: &dyn UiDefaults) -> BTreeSet<String> {
        d.string_array(Self::EXPANDED_KEY).unwrap_or_default().into_iter().collect()
    }

    /// Saves the open folders (sorted).
    pub fn save_expanded(ids: &BTreeSet<String>, d: &mut dyn UiDefaults) {
        let sorted: Vec<String> = ids.iter().cloned().collect();
        d.set_string_array(Self::EXPANDED_KEY, &sorted);
    }

    /// Where an entry sits: (top-level folder, sub-folder or none).
    pub fn location(e: &EffectsEntry) -> (String, Option<String>) {
        if e.id.starts_with("preset.") {
            return (Self::PRESETS_FOLDER.to_string(), None);
        }
        if e.category == Self::VIDEO_TRANSITIONS || e.category == Self::AUDIO_TRANSITIONS {
            return (e.category.clone(), None);
        }
        if ClipEffect::is_audio_kind(&e.id) {
            return (Self::AUDIO_EFFECTS_FOLDER.to_string(), Some(e.category.clone()));
        }
        (Self::EFFECTS_FOLDER.to_string(), Some(Self::kit_group(&e.category).to_string()))
    }

    /// The effects a folder row carries when it is dragged onto a clip or Effect Controls: every applicable effect inside
    /// it, in order. Transitions and presets are skipped (they apply elsewhere), so the Presets and transition folders
    /// carry nothing and cannot be dragged.
    pub fn effect_ids(folder_id: &str, entries: &[EffectsEntry], store: &EffectFolderStore) -> Vec<String> {
        fn applicable(id: &str) -> bool {
            !id.starts_with("preset.")
                && !id.starts_with("transition.")
                && !EffectDragPayload::is_adjustment_layer(id)
                && !TextPresetCatalog::is_text_preset_id(id)
        }
        if let Some(rest) = folder_id.strip_prefix("folder.user.") {
            let Some(f) = Id::parse(rest).and_then(|u| store.folder(u)) else { return Vec::new() };
            let known: BTreeSet<&str> = entries.iter().map(|e| e.id.as_str()).collect();
            return f.items.iter().filter(|i| known.contains(i.as_str()) && applicable(i)).cloned().collect();
        }
        let Some(rest) = folder_id.strip_prefix("folder.builtin.") else { return Vec::new() };
        let parts: Vec<&str> = rest.splitn(2, '/').collect();
        let Some(top) = parts.first() else { return Vec::new() };
        entries
            .iter()
            .filter(|e| {
                let loc = Self::location(e);
                loc.0 == *top && (parts.len() < 2 || loc.1.as_deref() == Some(parts[1])) && applicable(&e.id)
            })
            .map(|e| e.id.clone())
            .collect()
    }

    /// Effect-id pasteboard string (`EffectDragPayload`).
    pub fn encode_drag(ids: &[String]) -> String {
        EffectDragPayload::encode_drag(ids)
    }

    /// The ids in an effect-id pasteboard string.
    pub fn decode_drag(s: &str) -> Vec<String> {
        EffectDragPayload::decode_drag(s)
    }

    /// Outline keys on the selected row: right opens a closed folder, then steps into it; left closes an open folder,
    /// then steps out to the parent folder (also from an item).
    pub fn key_navigation(rows: &[EffectsRow], selected: i64, key: OutlineKey) -> Navigation {
        let Some(selected) = usize::try_from(selected).ok().filter(|s| *s < rows.len()) else {
            return Navigation::None;
        };
        let r = &rows[selected];
        match key {
            OutlineKey::Right => {
                if !r.is_folder {
                    return Navigation::None;
                }
                if !r.is_expanded {
                    return Navigation::Toggle(r.id.clone());
                }
                let next = selected + 1;
                if rows.get(next).is_some_and(|n| n.depth > r.depth) {
                    Navigation::Select(next)
                } else {
                    Navigation::None
                }
            }
            OutlineKey::Left => {
                if r.is_folder && r.is_expanded {
                    return Navigation::Toggle(r.id.clone());
                }
                match rows[..selected].iter().rposition(|p| p.is_folder && p.depth < r.depth) {
                    Some(parent) => Navigation::Select(parent),
                    None => Navigation::None,
                }
            }
        }
    }

    /// The panel's rows for the user's folders, then the built-in ones; a search opens every folder with a hit except the
    /// ones in `collapsed_in_search`.
    pub fn rows(
        entries: &[EffectsEntry],
        store: &EffectFolderStore,
        expanded: &BTreeSet<String>,
        query: &str,
        collapsed_in_search: &BTreeSet<String>,
    ) -> Vec<EffectsRow> {
        let q = query.trim_matches([' ', '\t']).to_lowercase();
        let searching = !q.is_empty();
        let matches = |e: &EffectsEntry| !searching || e.matches(&q);
        let item = |e: &EffectsEntry, depth: i64, id: String, folder: Option<Id>| {
            let mut r = EffectsRow::new(&id, &e.title, e.symbol, false);
            r.depth = depth;
            r.payload = Some(e.id.clone());
            r.user_folder = folder;
            r
        };
        let folder_row = |id: &str, title: &str, depth: i64, open: bool, user: Option<Id>, symbol: SQIcon| {
            let mut r = EffectsRow::new(id, title, symbol, false);
            r.is_folder = true;
            r.depth = depth;
            r.is_expanded = open;
            r.user_folder = user;
            r
        };
        let mut by_id: HashMap<&str, &EffectsEntry> = HashMap::new();
        for e in entries {
            by_id.entry(e.id.as_str()).or_insert(e);
        }
        let mut out: Vec<EffectsRow> = Vec::new();

        for f in &store.folders {
            let contents: Vec<&EffectsEntry> =
                f.items.iter().filter_map(|i| by_id.get(i.as_str()).copied()).filter(|e| matches(e)).collect();
            if searching && contents.is_empty() {
                continue;
            }
            let fid = Self::user_id(f.id);
            let open = if searching { !collapsed_in_search.contains(&fid) } else { expanded.contains(&fid) };
            let mut fr = folder_row(&fid, &f.name, 0, open, Some(f.id), SQIcon::FolderFilled);
            fr.count = Some(contents.len() as i64);
            out.push(fr);
            if open {
                out.extend(contents.iter().map(|e| item(e, 1, format!("{fid}|{}", e.id), Some(f.id))));
            }
        }

        let hits: Vec<&EffectsEntry> = entries.iter().filter(|e| matches(e)).collect();
        for top in Self::BUILTIN_ORDER {
            let in_top: Vec<&EffectsEntry> = hits.iter().copied().filter(|e| Self::location(e).0 == top).collect();
            if in_top.is_empty() {
                continue;
            }
            // The kit's flat groups: the Video bin has no folder of its own (its categories are the groups) and the
            // Audio bin lists its effects directly, so nothing nests deeper than one level.
            let group_depth: i64 = if top == Self::EFFECTS_FOLDER { 0 } else { 1 };
            if top != Self::EFFECTS_FOLDER {
                let tid = Self::builtin_id(top, None);
                let top_open = if searching { !collapsed_in_search.contains(&tid) } else { expanded.contains(&tid) };
                let mut tr = folder_row(&tid, &Self::display_name(top), 0, top_open, None, SQIcon::Folder);
                tr.count = Some(in_top.len() as i64);
                out.push(tr);
                if !top_open {
                    continue;
                }
            }
            if top == Self::AUDIO_EFFECTS_FOLDER {
                out.extend(in_top.iter().map(|e| item(e, 1, e.id.clone(), None)));
                continue;
            }
            let mut subs: Vec<String> = Vec::new();
            for e in &in_top {
                if let Some(s) = Self::location(e).1
                    && !subs.contains(&s)
                {
                    subs.push(s);
                }
            }
            for e in &in_top {
                if Self::location(e).1.is_none() {
                    out.push(item(e, 1, e.id.clone(), None));
                }
            }
            // The kit's group order (the audio sub-folders keep the catalog order).
            subs.sort_by_key(|s| Self::KIT_GROUPS.iter().position(|g| g == s).unwrap_or(Self::KIT_GROUPS.len()));
            for s in subs {
                let sid = Self::builtin_id(top, Some(&s));
                let s_open = if searching { !collapsed_in_search.contains(&sid) } else { expanded.contains(&sid) };
                let mut sr = folder_row(&sid, &Self::display_name(&s), group_depth, s_open, None, SQIcon::Folder);
                sr.count =
                    Some(in_top.iter().filter(|e| Self::location(e).1.as_deref() == Some(s.as_str())).count() as i64);
                out.push(sr);
                if s_open {
                    out.extend(
                        in_top
                            .iter()
                            .filter(|e| Self::location(e).1.as_deref() == Some(s.as_str()))
                            .map(|e| item(e, group_depth + 1, e.id.clone(), None)),
                    );
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::MemoryDefaults;
    use sq_core_time::SequentialIds;

    #[test]
    fn folders_get_unique_names_and_move_in_front_of_a_target() {
        let mut ids = SequentialIds::default();
        let mut s = EffectFolderStore::new();
        let a = s.create_folder("", &mut ids);
        let b = s.create_folder("new folder", &mut ids);
        let c = s.create_folder("Mine", &mut ids);
        let names: Vec<&str> = s.folders().iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, ["New Folder", "new folder 2", "Mine"]);
        s.move_folder(c, Some(a));
        assert_eq!(s.folders().iter().map(|f| f.id).collect::<Vec<_>>(), vec![c, a, b]);
        s.move_folder(c, None);
        assert_eq!(s.folders().last().map(|f| f.id), Some(c));
        s.rename(a, "Mine");
        assert_eq!(s.folder(a).map(|f| f.name.as_str()), Some("Mine 2"));
        s.add("blur", a);
        s.add("blur", a);
        assert_eq!(s.folder(a).map(|f| f.items.len()), Some(1));
    }

    #[test]
    fn the_store_round_trips_through_the_settings() {
        let mut d = MemoryDefaults::default();
        let mut s = EffectFolderStore::new();
        let id = s.create_folder("Looks", &mut SequentialIds::default());
        s.add("blur", id);
        s.save(&mut d);
        assert_eq!(EffectFolderStore::load(&d), s);
    }

    #[test]
    fn arrow_keys_open_close_and_step_through_the_outline() {
        let entries = crate::effects::effects_catalog::EffectsCatalog::catalog();
        let open: BTreeSet<String> = BTreeSet::from([
            EffectFolderOutline::builtin_id(EffectFolderOutline::EFFECTS_FOLDER, None),
            EffectFolderOutline::builtin_id(EffectFolderOutline::EFFECTS_FOLDER, Some("Blur & Sharpen")),
        ]);
        let rows = EffectFolderOutline::rows(&entries, &EffectFolderStore::new(), &open, "", &BTreeSet::new());
        let blur = rows.iter().position(|r| r.title == "Blur & Sharpen" && r.is_folder).expect("blur folder");
        assert_eq!(
            EffectFolderOutline::key_navigation(&rows, blur as i64, OutlineKey::Right),
            Navigation::Select(blur + 1)
        );
        assert_eq!(
            EffectFolderOutline::key_navigation(&rows, blur as i64, OutlineKey::Left),
            Navigation::Toggle(rows[blur].id.clone())
        );
        assert_eq!(
            EffectFolderOutline::key_navigation(&rows, blur as i64 + 1, OutlineKey::Left),
            Navigation::Select(blur)
        );
        assert_eq!(EffectFolderOutline::key_navigation(&rows, -1, OutlineKey::Left), Navigation::None);
    }
}

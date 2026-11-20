// Swift: LibraryPanelModel.swift
//! State and logic of the Library panel. No UI; the panel reads it every frame.
//!
//! Mapping (docs/rust/session-ui-design.md section 2): the Swift model is an `@Observable` class whose `async` methods talk
//! to the `LibraryIndex` actor and the preview coordinator. Here every call is synchronous on the UI thread; `version`
//! counts each change (the panel's cache key) and the owner calls `pump` once per frame instead of awaiting the index's
//! update stream. The hooks (`onFoldersChanged`, `onInsertTitleBlock`, `onImportWorkspaces`, `onApplyPreset`) are
//! [`LibraryModelEvent`]s the owner drains with `take_events`.
//! shortcut: previews are made inline on the UI thread when an item appears (Swift: a `Task` per item); the provider is
//! the unavailable one off the Mac, so nothing blocks there. Upgrade when `sq-runtime` offers background jobs. Because of
//! it `itemDidDisappear` and `pendingPreviewCount` have nothing to cancel or count and are not ported.

use crate::library::library_panel_logic::{LibraryError, LibraryLabels, PresetKindTitleExt};
use crate::library::text_templates::{NoTextTemplates, TextTemplateEntry, TextTemplates};
use sq_core_effects::effect_preset::ApplyMode;
use sq_core_time::{Id, IdSource, Time, Timestamp};
use sq_editor_session::{CaptionLookPayload, LookStore, Workspace};
use sq_library::favorites::{Favorites, FavoritesStore, LibraryStoreError};
use sq_library::library_grouping::{self, LibraryGroup};
use sq_library::library_index::{FolderState, LibraryIndex, LibraryUpdate};
use sq_library::library_item_kind::LibraryItemKind;
use sq_library::library_preview_math;
use sq_library::library_preview_player_portable::LibraryPreviewPlayer;
use sq_library::library_search::{self, LibrarySortKey};
use sq_library::preset_organizer::{
    PresetCategory, PresetFilter, PresetKey, PresetListEntry, PresetMetaStore, PresetMetaTable, PresetOrganizer,
    PresetScope, PresetSortKey,
};
use sq_library::preset_store::{PresetFile, PresetItem, PresetKind, PresetStore, PresetStoreOrigin};
use sq_library::preview_requests::{
    PreviewCoordinator, PreviewError, PreviewKind, PreviewProvider, PreviewRequest, PreviewStart,
};
use sq_library::watched_folder::{LibraryEntry, LibraryEntryID, WatchedFolder};
use sq_uikit::appearance_palette::UiDefaults;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::Receiver;

/// Sidebar selection of the Library panel.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum LibrarySection {
    /// The "Library" group row: every item of every online folder.
    All,
    /// One watched folder.
    Folder(Id),
    /// The favorite files.
    Favorites,
    /// Presets of one kind; none = all kinds.
    Presets(Option<PresetKind>),
    /// The built-in audio effect stacks (`AudioPresets`).
    AudioStacks,
    /// The LUT files of the LUT library.
    Luts,
    /// The presets imported from one `.sqpack`, shown as a folder named after the pack.
    Pack(String),
}

/// A watched folder and whether its drive is there.
#[derive(Clone, Debug, PartialEq)]
pub struct LibraryFolderRow {
    /// The folder.
    pub folder: WatchedFolder,
    /// Online or offline.
    pub state: FolderState,
}

/// One item shown in the grid/list.
#[derive(Clone, Debug, PartialEq)]
pub struct LibraryItem {
    /// The indexed file.
    pub entry: LibraryEntry,
    /// Its path.
    pub url: PathBuf,
    /// Marked favorite.
    pub is_favorite: bool,
}

impl LibraryItem {
    /// The entry's stable id.
    pub fn id(&self) -> LibraryEntryID {
        self.entry.id()
    }
}

/// One section of the grid/list: header (title, count, collapse) and the items shown under it.
#[derive(Clone, Debug, PartialEq)]
pub struct LibrarySectionData {
    /// The header's group.
    pub group: LibraryGroup,
    /// The items under it.
    pub items: Vec<LibraryItem>,
}

/// Grid or list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LibraryViewMode {
    /// Tiles.
    Grid,
    /// Rows.
    List,
}

/// What the model asks of its owner (the Swift hooks).
#[derive(Clone, Debug, PartialEq)]
pub enum LibraryModelEvent {
    /// `onFoldersChanged`: folders were added or removed, so the host can persist them.
    FoldersChanged(Vec<WatchedFolder>),
    /// `onInsertTitleBlock`: double-click / drag of a title block: the host places it at the playhead / drop time.
    InsertTitleBlock(PresetItem, Option<Time>),
    /// `onImportWorkspaces`: a pack carried workspace layouts: the host stores them as user workspaces.
    ImportWorkspaces(Vec<Workspace>),
    /// `onApplyPreset`: double-click / "Apply to Selected Clips" on a preset; none mode = the remembered default.
    ApplyPreset(PresetItem, Option<ApplyMode>),
}

/// State and logic of the Library panel.
pub struct LibraryPanelModel {
    pub(crate) index: LibraryIndex,
    /// The one preset store of the app.
    pub preset_store: PresetStore,
    coordinator: PreviewCoordinator,
    provider: Box<dyn PreviewProvider>,
    favorites_url: PathBuf,
    /// The app's Application Support folder of Sequence Studio (`LibraryStores.supportDirectory`).
    pub support_directory: PathBuf,
    /// Where imported LUTs go and exported packs read them from (`LUTLibrary.defaultDirectory`).
    pub lut_directory: PathBuf,
    pub(crate) ids: Box<dyn IdSource>,
    pub(crate) clock: Box<dyn Fn() -> Timestamp>,
    templates: Box<dyn TextTemplates>,
    /// The Look store the Captions group reads (none = none, e.g. tests of the panel alone): its Looks are listed as
    /// `.caption` items, a `.caption` preset itself never is, and the store follows the preset store (`reload_presets`).
    look_store: Option<Arc<LookStore>>,
    look_seen_version: u64,
    stored_presets: Vec<PresetItem>,
    /// Packs switched off: their presets stay out of the lists (nothing is deleted).
    hidden_packs: BTreeSet<String>,
    /// The LUT library's files, set by the host (the Luts chip lists them).
    lut_entries: Vec<sq_library::lutlibrary::LUTEntry>,
    events: Vec<LibraryModelEvent>,
    /// Where the SFX bin lives on disk; none = no SFX bin support.
    pub sfx_directory: Option<PathBuf>,
    /// Remembers the last whoosh sound the user chose from the SFX bin (its file path).
    pub whoosh_defaults: Box<dyn UiDefaults>,
    version: u64,

    folders: Vec<LibraryFolderRow>,
    presets: Vec<PresetItem>,
    favorites: Favorites,
    thumbnails: HashMap<LibraryEntryID, PathBuf>,
    failed_previews: HashSet<LibraryEntryID>,
    entries_by_folder: HashMap<Id, Vec<LibraryEntry>>,
    selection: LibrarySection,
    /// Own player of the Library (never the timeline engine); starts on selecting an audio or video item.
    pub preview: LibraryPreviewPlayer,
    preview_item: Option<LibraryItem>,
    collapsed_groups: BTreeSet<String>,
    query: String,
    sort_key: LibrarySortKey,
    ascending: bool,
    favorites_writable: bool,
    preset_meta: PresetMetaTable,
    preset_sort: PresetSortKey,
    preset_ascending: bool,
    preset_scope: PresetScope,
    preset_category: Option<PresetCategory>,
    preset_tag: Option<String>,
    preset_meta_writable: bool,
    view_mode: LibraryViewMode,
    /// Pixel size used for preview requests.
    pub preview_pixel_size: (i64, i64),
    updates: Option<Receiver<LibraryUpdate>>,
}

/// What a model is made of.
pub struct LibraryPanelDeps {
    /// The folder index (scanner and watcher).
    pub index: LibraryIndex,
    /// The app's preset store.
    pub preset_store: PresetStore,
    /// Serves previews from the cache.
    pub coordinator: PreviewCoordinator,
    /// Makes missing previews.
    pub provider: Box<dyn PreviewProvider>,
    /// `favorites.json`; the preset meta file sits next to it.
    pub favorites_url: PathBuf,
    /// Ids for new folders and imports (Swift calls `UUID()`).
    pub ids: Box<dyn IdSource>,
    /// The wall clock (Swift calls `Date()`).
    pub clock: Box<dyn Fn() -> Timestamp>,
    /// The settings store of the last whoosh sound.
    pub whoosh_defaults: Box<dyn UiDefaults>,
}

impl LibraryPanelModel {
    /// The settings key of the last whoosh sound.
    pub const LAST_WHOOSH_KEY: &'static str = "sq.sfx.lastWhoosh";

    /// A model that is not running yet: call `start`.
    pub fn new(d: LibraryPanelDeps) -> LibraryPanelModel {
        let support_directory = d.favorites_url.parent().map(Path::to_path_buf).unwrap_or_default();
        LibraryPanelModel {
            index: d.index,
            preset_store: d.preset_store,
            coordinator: d.coordinator,
            provider: d.provider,
            favorites_url: d.favorites_url,
            lut_directory: support_directory.join("LUTs"),
            support_directory,
            ids: d.ids,
            clock: d.clock,
            templates: Box::new(NoTextTemplates),
            look_store: None,
            look_seen_version: 0,
            stored_presets: Vec::new(),
            hidden_packs: BTreeSet::new(),
            lut_entries: Vec::new(),
            events: Vec::new(),
            sfx_directory: None,
            whoosh_defaults: d.whoosh_defaults,
            version: 0,
            folders: Vec::new(),
            presets: Vec::new(),
            favorites: Favorites::default(),
            thumbnails: HashMap::new(),
            failed_previews: HashSet::new(),
            entries_by_folder: HashMap::new(),
            selection: LibrarySection::All,
            preview: LibraryPreviewPlayer::new(),
            preview_item: None,
            collapsed_groups: BTreeSet::new(),
            query: String::new(),
            sort_key: LibrarySortKey::Name,
            ascending: true,
            favorites_writable: true,
            preset_meta: PresetMetaTable::new(),
            preset_sort: PresetSortKey::Name,
            preset_ascending: true,
            preset_scope: PresetScope::All,
            preset_category: None,
            preset_tag: None,
            preset_meta_writable: true,
            view_mode: LibraryViewMode::Grid,
            preview_pixel_size: (256, 144),
            updates: None,
        }
    }

    /// Counts every change; the panel rebuilds its cells when it moved.
    pub fn version(&self) -> u64 {
        self.version
            + self.index.version()
            + self.preset_store.version()
            + self.preview.version()
            + self.look_store.as_ref().map_or(0, |l| l.version())
    }

    fn changed(&mut self) {
        self.version += 1;
    }

    /// The hooks that fired since the last call, in order.
    pub fn take_events(&mut self) -> Vec<LibraryModelEvent> {
        std::mem::take(&mut self.events)
    }

    /// The built-in text templates (see `text_templates`).
    pub fn set_templates(&mut self, templates: Box<dyn TextTemplates>) {
        self.templates = templates;
        self.changed();
    }

    /// The built-in templates, read each time.
    pub fn template_entries(&self) -> Vec<TextTemplateEntry> {
        self.templates.entries()
    }

    pub(crate) fn push_event(&mut self, e: LibraryModelEvent) {
        self.events.push(e);
    }

    pub(crate) fn template_tiles(&self) -> Vec<crate::library::text_templates::TextTemplateTile> {
        self.templates.tiles(&self.presets)
    }

    // MARK: Lifecycle

    /// Sets the Look store and lists its Looks as `.caption` items.
    pub fn set_look_store(&mut self, store: Option<Arc<LookStore>>) {
        self.look_seen_version = store.as_ref().map_or(0, |s| s.version());
        self.look_store = store;
        self.recompose_presets();
    }

    /// Loads favorites, presets and the index state, then follows watcher updates.
    pub fn start(&mut self) {
        let now = (self.clock)();
        match FavoritesStore::load(&self.favorites_url, now) {
            Ok(f) => {
                self.favorites = f;
                self.favorites_writable = true;
            }
            Err(_) => {
                self.favorites = Favorites::default();
                self.favorites_writable = false; // e.g. a newer app version's file: never overwrite it
            }
        }
        match PresetMetaStore::load(&self.preset_meta_url(), now) {
            Ok(t) => {
                self.preset_meta = t;
                self.preset_meta_writable = true;
            }
            Err(_) => {
                self.preset_meta = PresetMetaTable::new();
                self.preset_meta_writable = false;
            }
        }
        self.reload_presets();
        self.reload_folders();
        if self.updates.is_none() {
            self.updates = Some(self.index.updates());
        }
        self.changed();
    }

    /// Once per frame: rescans the folders the watcher reported, applies the updates and follows the Look store.
    pub fn pump(&mut self) {
        self.index.process_changes();
        let updates: Vec<LibraryUpdate> = self.updates.as_ref().map(|rx| rx.try_iter().collect()).unwrap_or_default();
        for u in updates {
            self.apply(&u);
        }
        let v = self.look_store.as_ref().map_or(0, |l| l.version());
        if v != self.look_seen_version {
            self.look_seen_version = v;
            self.recompose_presets();
        }
    }

    fn apply(&mut self, update: &LibraryUpdate) {
        self.reload_folders();
        for e in update.diff.removed.iter().chain(update.diff.changed.iter()) {
            let id = e.id();
            self.thumbnails.remove(&id);
            self.failed_previews.remove(&id);
        }
        if let Some(current) = &self.preview_item {
            let cid = current.id();
            if update.diff.removed.iter().any(|e| e.id() == cid) {
                self.select_item_for_preview(None);
            }
        }
        self.changed();
    }

    fn reload_folders(&mut self) {
        let mut rows = Vec::new();
        let mut entries = HashMap::new();
        for f in self.index.folders() {
            rows.push(LibraryFolderRow {
                folder: f.clone(),
                state: self.index.state(f.id).unwrap_or(FolderState::Offline),
            });
            entries.insert(f.id, self.index.entries(f.id).to_vec());
        }
        self.folders = rows;
        self.entries_by_folder = entries;
        self.changed();
    }

    /// Reads the preset store again and recomposes the list.
    pub fn reload_presets(&mut self) {
        // The shell's import flows write the file through a handle of their own (`ShellServices::preset_store`).
        let now = (self.clock)();
        let _ = self.preset_store.reload_from_disk(now);
        self.stored_presets = self.preset_store.all().to_vec();
        // One Look system: a `.caption` preset added, changed, renamed, deleted or imported here changes its Look.
        if let Some(ls) = &self.look_store {
            ls.import_caption_presets(Some(&self.preset_store));
        }
        self.recompose_presets();
        // Presets that are only hidden (no Look list to compare with) keep their favorites and meta.
        let kept: Vec<&PresetItem> = if self.presets_are_authoritative() {
            self.presets.iter().collect()
        } else {
            self.stored_presets.iter().chain(self.presets.iter()).collect()
        };
        let keys: BTreeSet<String> = kept.iter().map(|p| PresetKey::user(p.id)).collect();
        self.preset_meta.prune(&keys);
        self.changed();
    }

    /// The list the panel shows: the preset store's presets, with every `.caption` one replaced by the Look under its
    /// id. A `.caption` preset without a Look is a stale copy (its Look was deleted) and is not listed, except one this
    /// build cannot read (it keeps its Look-less place). Looks of the Text panel (no preset) are listed too.
    fn recompose_presets(&mut self) {
        let Some(look_store) = self.look_store.clone() else {
            let mut out = self.stored_presets.clone();
            Self::add_built_in_motion(&mut out);
            self.presets = out;
            return;
        };
        let lib = look_store.library();
        let looks = lib.user();
        let by_id: HashMap<&str, &sq_text::look::Look> = looks.iter().map(|l| (l.id.as_str(), l)).collect();
        let authoritative = self.presets_are_authoritative();
        let mut out: Vec<PresetItem> = Vec::new();
        let mut placed: BTreeSet<String> = BTreeSet::new();
        for p in &self.stored_presets {
            if p.kind != PresetKind::Caption {
                out.push(p.clone());
                continue;
            }
            let key = p.id.to_string();
            if let Some(look) = by_id.get(key.as_str())
                && let Some(mut item) = Self::item_for(look, Some(p))
            {
                item.pack = p.pack.clone();
                out.push(item);
                placed.insert(look.id.clone());
                continue;
            }
            if !by_id.contains_key(key.as_str()) && (!authoritative || !Self::is_readable(p)) {
                out.push(p.clone());
            }
        }
        for look in looks {
            if !placed.contains(&look.id)
                && let Some(item) = Self::item_for(look, None)
            {
                out.push(item);
            }
        }
        Self::add_built_in_motion(&mut out);
        if out != self.presets {
            self.presets = out;
            self.changed();
        }
    }

    /// The shown built-in motion presets (keystones) that no saved preset replaces, listed under Motion like the
    /// Looks above: virtual items with the built-in's id (a saved copy with that id wins, as in `keystone_library`).
    fn add_built_in_motion(out: &mut Vec<PresetItem>) {
        let made = sq_core_time::Timestamp::from_unix_seconds(0.0);
        let saved: BTreeSet<sq_core_time::Id> =
            out.iter().filter(|p| p.kind == PresetKind::Keystone).map(|p| p.id).collect();
        let items = sq_library::keystone_library::keystones(out)
            .into_iter()
            .filter(|k| !saved.contains(&k.id))
            .filter_map(|k| sq_library::keystone_library::preset_item(&k, made).ok())
            .collect::<Vec<_>>();
        out.extend(items);
    }

    /// False while the Look list cannot say which Looks exist (its file was not loaded, or the preset store is a
    /// stand-in that the follow skips): a `.caption` preset without a Look is then kept, not dropped.
    fn presets_are_authoritative(&self) -> bool {
        self.look_store.as_ref().is_none_or(|l| l.is_loaded())
            && self.preset_store.origin() != PresetStoreOrigin::StandIn
    }

    fn is_readable(p: &PresetItem) -> bool {
        p.payload_version <= CaptionLookPayload::VERSION
            && serde_json::from_slice::<CaptionLookPayload>(&p.payload).is_ok()
    }

    /// A Look as a `.caption` item (same payload a caption preset has). None for an id that is not a UUID.
    fn item_for(look: &sq_text::look::Look, like: Option<&PresetItem>) -> Option<PresetItem> {
        let id = Id::parse(&look.id)?;
        let payload = serde_json::to_vec(&CaptionLookPayload::new(
            look.caption_look(),
            LookStore::segmentation(look),
            look.category.clone(),
        ))
        .ok()?;
        Some(PresetItem::new(
            id,
            PresetKind::Caption,
            &look.name,
            like.map_or_else(|| Timestamp::from_unix_seconds(0.0), |p| p.created_at),
            payload,
            CaptionLookPayload::VERSION,
        ))
    }

    // MARK: State

    /// The watched folders and whether they are online.
    pub fn folders(&self) -> &[LibraryFolderRow] {
        &self.folders
    }
    /// The presets the panel lists (saved, with the Looks).
    pub fn presets(&self) -> &[PresetItem] {
        &self.presets
    }
    /// The favorite files.
    pub fn favorites(&self) -> &Favorites {
        &self.favorites
    }
    /// The thumbnail files made so far.
    pub fn thumbnails(&self) -> &HashMap<LibraryEntryID, PathBuf> {
        &self.thumbnails
    }
    /// Entries whose preview failed for good.
    pub fn failed_previews(&self) -> &HashSet<LibraryEntryID> {
        &self.failed_previews
    }
    /// The sidebar selection.
    pub fn selection(&self) -> &LibrarySection {
        &self.selection
    }
    /// Changes the sidebar selection; a new selection ends the preview.
    pub fn set_selection(&mut self, s: LibrarySection) {
        if self.selection != s {
            self.selection = s;
            self.select_item_for_preview(None);
            self.changed();
        }
    }
    /// The item the preview bar shows (selected in the grid or list); none = no preview bar.
    pub fn preview_item(&self) -> Option<&LibraryItem> {
        self.preview_item.as_ref()
    }
    /// Sections (group ids, `LibraryGroup::ALL_ID` for All) the user collapsed. Not persisted.
    pub fn collapsed_groups(&self) -> &BTreeSet<String> {
        &self.collapsed_groups
    }
    /// The search text.
    pub fn query(&self) -> &str {
        &self.query
    }
    /// Sets the search text.
    pub fn set_query(&mut self, q: &str) {
        if self.query != q {
            self.query = q.to_string();
            self.changed();
        }
    }
    /// The file sort key.
    pub fn sort_key(&self) -> LibrarySortKey {
        self.sort_key
    }
    /// Sets the file sort key.
    pub fn set_sort_key(&mut self, k: LibrarySortKey) {
        self.sort_key = k;
        self.changed();
    }
    /// The file sort direction.
    pub fn ascending(&self) -> bool {
        self.ascending
    }
    /// Sets the file sort direction.
    pub fn set_ascending(&mut self, a: bool) {
        self.ascending = a;
        self.changed();
    }
    /// The preset sort key.
    pub fn preset_sort(&self) -> PresetSortKey {
        self.preset_sort
    }
    /// The preset sort direction.
    pub fn preset_ascending(&self) -> bool {
        self.preset_ascending
    }
    /// The preset scope filter.
    pub fn preset_scope(&self) -> PresetScope {
        self.preset_scope
    }
    /// Sets the preset scope filter.
    pub fn set_preset_scope(&mut self, s: PresetScope) {
        self.preset_scope = s;
        self.changed();
    }
    /// The preset category filter.
    pub fn preset_category(&self) -> Option<PresetCategory> {
        self.preset_category
    }
    /// Sets the preset category filter.
    pub fn set_preset_category(&mut self, c: Option<PresetCategory>) {
        self.preset_category = c;
        self.changed();
    }
    /// The preset tag filter.
    pub fn preset_tag(&self) -> Option<&str> {
        self.preset_tag.as_deref()
    }
    /// Sets the preset tag filter.
    pub fn set_preset_tag(&mut self, t: Option<String>) {
        self.preset_tag = t;
        self.changed();
    }
    /// Category, tags, favorites and use counts of the presets.
    pub fn preset_meta(&self) -> &PresetMetaTable {
        &self.preset_meta
    }
    /// Grid or list.
    pub fn view_mode(&self) -> LibraryViewMode {
        self.view_mode
    }
    /// Sets grid or list.
    pub fn set_view_mode(&mut self, m: LibraryViewMode) {
        self.view_mode = m;
        self.changed();
    }

    // MARK: Folders

    /// Adds a watched folder, shows it and reports the change.
    pub fn add_folder(&mut self, url: PathBuf, bookmark: Option<Vec<u8>>) -> WatchedFolder {
        let folder = WatchedFolder::new(self.ids.next_id(), url, None, bookmark);
        self.index.add(folder.clone());
        self.reload_folders();
        self.set_selection(LibrarySection::Folder(folder.id));
        self.events.push(LibraryModelEvent::FoldersChanged(self.folders.iter().map(|f| f.folder.clone()).collect()));
        folder
    }

    /// Re-adds folders restored from disk (no selection change, no persistence callback).
    pub fn restore_folders(&mut self, restored: Vec<WatchedFolder>) {
        for f in restored {
            self.index.add(f);
        }
        self.reload_folders();
    }

    /// Removes a watched folder.
    pub fn remove_folder(&mut self, id: Id) {
        self.index.remove(id);
        if self.selection == LibrarySection::Folder(id) {
            self.set_selection(LibrarySection::Favorites);
        }
        self.thumbnails.retain(|k, _| k.folder_id != id);
        self.failed_previews.retain(|k| k.folder_id != id);
        self.reload_folders();
        self.events.push(LibraryModelEvent::FoldersChanged(self.folders.iter().map(|f| f.folder.clone()).collect()));
    }

    /// Scans a folder again.
    pub fn rescan(&mut self, id: Id) {
        self.index.rescan(id);
        self.reload_folders();
    }

    /// The watched folder with this id.
    pub fn folder(&self, id: Id) -> Option<&WatchedFolder> {
        self.folders.iter().find(|f| f.folder.id == id).map(|f| &f.folder)
    }

    /// Indexed entries of one folder (unsorted, unfiltered).
    pub fn entries(&self, folder_id: Id) -> &[LibraryEntry] {
        self.entries_by_folder.get(&folder_id).map_or(&[], Vec::as_slice)
    }

    /// The selected folder is offline.
    pub fn is_selected_folder_offline(&self) -> bool {
        if let LibrarySection::Folder(id) = self.selection {
            return self.folders.iter().find(|f| f.folder.id == id).map(|f| f.state) == Some(FolderState::Offline);
        }
        false
    }

    // MARK: Search, sort

    // MARK: Items

    /// A presets section is selected.
    pub fn is_showing_presets(&self) -> bool {
        matches!(
            self.selection,
            LibrarySection::Presets(_) | LibrarySection::Pack(_) | LibrarySection::AudioStacks | LibrarySection::Luts
        )
    }

    /// Items of the current section after search and sort.
    /// Offline folders show nothing (their last snapshot is kept but not listed).
    pub fn items(&self) -> Vec<LibraryItem> {
        let online: Vec<&LibraryFolderRow> = self.folders.iter().filter(|f| f.state == FolderState::Online).collect();
        let of = |id: Id| self.entries_by_folder.get(&id).cloned().unwrap_or_default();
        let source: Vec<LibraryEntry> = match &self.selection {
            LibrarySection::Folder(id) => {
                if online.iter().any(|f| f.folder.id == *id) {
                    of(*id)
                } else {
                    Vec::new()
                }
            }
            LibrarySection::Favorites => {
                online.iter().flat_map(|f| of(f.folder.id)).filter(|e| self.favorites.contains(&e.id())).collect()
            }
            LibrarySection::All => online.iter().flat_map(|f| of(f.folder.id)).collect(),
            LibrarySection::Presets(_)
            | LibrarySection::Pack(_)
            | LibrarySection::AudioStacks
            | LibrarySection::Luts => Vec::new(),
        };
        let by_id: HashMap<Id, &WatchedFolder> = self.folders.iter().map(|f| (f.folder.id, &f.folder)).collect();
        library_search::filter(&source, &self.query, self.sort_key, self.ascending)
            .into_iter()
            .filter_map(|entry| {
                let f = by_id.get(&entry.folder_id)?;
                Some(LibraryItem { url: entry.url(f), is_favorite: self.favorites.contains(&entry.id()), entry })
            })
            .collect()
    }

    /// Sections of a Library folder with subfolders: All first, then one per subfolder (nested ones indented), with the
    /// collapsed state applied. Empty = show the plain flat `items` list (no subfolders, Favorites, presets).
    pub fn sections(&self) -> Vec<LibrarySectionData> {
        if !matches!(self.selection, LibrarySection::Folder(_)) {
            return Vec::new();
        }
        let all = self.items();
        let entries: Vec<LibraryEntry> = all.iter().map(|i| i.entry.clone()).collect();
        let groups = library_grouping::groups(&entries);
        if groups.is_empty() {
            return Vec::new();
        }
        let by_id: HashMap<LibraryEntryID, &LibraryItem> = all.iter().map(|i| (i.id(), i)).collect();
        let collapsed: Vec<&str> = self.collapsed_groups.iter().map(String::as_str).collect();
        library_grouping::visible(&groups, &collapsed)
            .into_iter()
            .map(|g| {
                let items = g.entries.iter().filter_map(|e| by_id.get(&e.id()).map(|i| (*i).clone())).collect();
                LibrarySectionData { group: g, items }
            })
            .collect()
    }

    /// Collapses or opens a section.
    pub fn toggle_group(&mut self, id: &str) {
        if !self.collapsed_groups.remove(id) {
            self.collapsed_groups.insert(id.to_string());
        }
        self.changed();
    }

    /// Selecting an item previews it: audio and video start playing (stopping the previous one), images show larger.
    pub fn select_item_for_preview(&mut self, item: Option<&LibraryItem>) {
        let Some((item, mode)) = item.and_then(|i| library_preview_math::mode(i.entry.kind).map(|m| (i, m))) else {
            self.preview_item = None;
            self.preview.stop();
            self.changed();
            return;
        };
        if self.preview_item.as_ref().map(LibraryItem::id) == Some(item.id()) {
            return;
        }
        self.preview_item = Some(item.clone());
        self.preview.select_file(item.id(), Some(mode), &item.url);
        self.changed();
    }

    // MARK: Preset organizing (category, tags, favorites, recents, sort)

    fn preset_meta_url(&self) -> PathBuf {
        self.favorites_url.parent().map(Path::to_path_buf).unwrap_or_default().join("preset-meta.json")
    }

    /// Category of a built-in template: the user's choice, else guessed from its name (the CTA end card is Social).
    pub fn default_category_of_template(t: &TextTemplateEntry) -> PresetCategory {
        if t.is_cta { PresetCategory::Social } else { PresetCategory::inferred(&t.name) }
    }

    /// The list entry of a saved preset.
    pub fn entry_for_preset(&self, preset: &PresetItem) -> PresetListEntry {
        let key = PresetKey::user(preset.id);
        PresetListEntry::new(
            &key,
            &preset.name,
            false,
            Some(preset.created_at),
            PresetCategory::default_for(preset.kind),
            self.preset_meta.get(&key),
        )
    }

    /// The list entry of a built-in template.
    pub fn entry_for_template(&self, template: &TextTemplateEntry) -> PresetListEntry {
        let key = PresetKey::built_in(&template.id);
        PresetListEntry::new(
            &key,
            &template.name,
            true,
            None,
            Self::default_category_of_template(template),
            self.preset_meta.get(&key),
        )
    }

    fn preset_filter(&self) -> PresetFilter {
        PresetFilter {
            query: self.query.clone(),
            category: self.preset_category,
            scope: self.preset_scope,
            tag: self.preset_tag.clone(),
        }
    }

    /// True while a scope, category or tag narrows the list (the search field is separate).
    pub fn preset_filter_active(&self) -> bool {
        self.preset_scope != PresetScope::All || self.preset_category.is_some() || self.preset_tag.is_some()
    }

    /// Clears scope, category and tag.
    pub fn clear_preset_filters(&mut self) {
        self.preset_scope = PresetScope::All;
        self.preset_category = None;
        self.preset_tag = None;
        self.changed();
    }

    /// The packs switched off.
    pub fn hidden_packs(&self) -> &BTreeSet<String> {
        &self.hidden_packs
    }

    /// Switches a pack's presets off or on in the lists (the pack's own row still shows them).
    pub fn set_pack_hidden(&mut self, name: &str, hidden: bool) {
        let changed = if hidden { self.hidden_packs.insert(name.to_string()) } else { self.hidden_packs.remove(name) };
        if changed {
            self.changed();
        }
    }

    /// Everything the current presets section can show, before search and filters.
    fn section_entries(&self) -> Vec<PresetListEntry> {
        if let LibrarySection::Pack(name) = &self.selection {
            return self
                .presets
                .iter()
                .filter(|p| p.pack.as_deref() == Some(name.as_str()))
                .map(|p| self.entry_for_preset(p))
                .collect();
        }
        let LibrarySection::Presets(kind) = self.selection else { return Vec::new() };
        let user = self
            .presets
            .iter()
            .filter(|p| p.pack.as_ref().is_none_or(|n| !self.hidden_packs.contains(n)))
            .filter(|p| {
                // saved titles sit with the text templates
                kind.is_none()
                    || Some(p.kind) == kind
                    || (kind == Some(PresetKind::TextTemplate) && p.kind.is_title_insert())
                    || (kind == Some(PresetKind::TextTemplate) && p.kind == PresetKind::AnimatedTextTemplate)
            })
            .map(|p| self.entry_for_preset(p));
        let built: Vec<PresetListEntry> = if kind.is_none() || kind == Some(PresetKind::TextTemplate) {
            self.templates.entries().iter().map(|t| self.entry_for_template(t)).collect()
        } else {
            Vec::new()
        };
        built.into_iter().chain(user).collect()
    }

    fn visible_preset_keys(&self) -> Vec<String> {
        PresetOrganizer::visible(
            &self.section_entries(),
            &self.preset_filter(),
            self.preset_sort,
            self.preset_ascending,
        )
        .into_iter()
        .map(|e| e.key)
        .collect()
    }

    /// Presets of the current presets section after search, scope, category, tag and sort.
    pub fn visible_presets(&self) -> Vec<PresetItem> {
        let by_key: HashMap<String, &PresetItem> = self.presets.iter().map(|p| (PresetKey::user(p.id), p)).collect();
        self.visible_preset_keys().iter().filter_map(|k| by_key.get(k).map(|p| (*p).clone())).collect()
    }

    /// Built-in text templates (drag to the timeline): shown under Text Templates and All Presets, same filters as the presets.
    pub fn visible_text_templates(&self) -> Vec<TextTemplateEntry> {
        let all = self.templates.entries();
        let by_key: HashMap<String, &TextTemplateEntry> = all.iter().map(|t| (PresetKey::built_in(&t.id), t)).collect();
        self.visible_preset_keys().iter().filter_map(|k| by_key.get(k).map(|t| (*t).clone())).collect()
    }

    /// The host's current LUT files; the list changes only when they did.
    pub fn set_lut_entries(&mut self, entries: Vec<sq_library::lutlibrary::LUTEntry>) {
        if entries != self.lut_entries {
            self.lut_entries = entries;
            self.changed();
        }
    }

    /// LUT files of the Luts chip after the search.
    pub fn visible_luts(&self) -> Vec<sq_library::lutlibrary::LUTEntry> {
        if self.selection != LibrarySection::Luts {
            return Vec::new();
        }
        let q = self.query.to_lowercase();
        self.lut_entries.iter().filter(|e| q.is_empty() || e.name().to_lowercase().contains(&q)).cloned().collect()
    }

    /// Built-in audio stacks of the Audio chip (id, name) after the search.
    pub fn visible_audio_stacks(&self) -> Vec<(String, String)> {
        if self.selection != LibrarySection::AudioStacks {
            return Vec::new();
        }
        let q = self.query.to_lowercase();
        sq_core_effects::effect_stack_preset::AudioPresets::all()
            .into_iter()
            .filter(|p| q.is_empty() || p.name.to_lowercase().contains(&q))
            .map(|p| (p.id.clone(), p.name.clone()))
            .collect()
    }

    /// Categories present in the current section, for the menus.
    pub fn preset_category_counts(&self) -> HashMap<PresetCategory, usize> {
        PresetOrganizer::category_counts(&self.section_entries())
    }

    /// Tags present in the current section, for the menus.
    pub fn preset_tag_counts(&self) -> Vec<(String, usize)> {
        PresetOrganizer::tag_counts(&self.section_entries())
    }

    /// Sorts by `key`; the current key flips the direction.
    pub fn sort_presets(&mut self, key: PresetSortKey) {
        if self.preset_sort == key {
            self.preset_ascending = !self.preset_ascending;
        } else {
            self.preset_sort = key;
            self.preset_ascending = true;
        }
        self.changed();
    }

    /// Marks a preset or template as favorite, or not.
    pub fn toggle_favorite_preset(&mut self, key: &str) {
        self.edit_meta(|m| {
            m.toggle_favorite(key);
        });
    }
    /// Moves a preset or template to a shelf (none = the default shelf).
    pub fn set_preset_category_of(&mut self, key: &str, category: Option<PresetCategory>) {
        self.edit_meta(|m| m.set_category(key, category));
    }
    /// Puts a tag on a preset or template, or takes it off.
    pub fn toggle_preset_tag(&mut self, key: &str, tag: &str) {
        self.edit_meta(|m| m.toggle_tag(key, tag));
    }
    /// A preset or template was applied, inserted or dragged out: feeds Recent and Most Used.
    pub fn record_preset_use(&mut self, key: &str) {
        let now = (self.clock)();
        self.edit_meta(|m| m.record_use(key, now));
    }

    fn edit_meta(&mut self, change: impl FnOnce(&mut PresetMetaTable)) {
        change(&mut self.preset_meta);
        self.changed();
        if !self.preset_meta_writable {
            return; // a newer app version's file is never overwritten
        }
        let _ = PresetMetaStore::save(&self.preset_meta, &self.preset_meta_url());
    }

    // MARK: Hooks the panel raises

    /// `onInsertTitleBlock`.
    pub fn insert_title_block(&mut self, item: PresetItem, at: Option<Time>) {
        self.events.push(LibraryModelEvent::InsertTitleBlock(item, at));
    }

    /// `onApplyPreset`: none mode = the remembered default.
    pub fn apply_preset(&mut self, item: PresetItem, mode: Option<ApplyMode>) {
        self.events.push(LibraryModelEvent::ApplyPreset(item, mode));
    }

    // MARK: Preset files and editing

    /// Adds a preset (e.g. "Save as Preset...") and shows it.
    pub fn save_preset(&mut self, item: PresetItem) -> Result<(), LibraryError> {
        self.preset_store.add(item)?;
        self.reload_presets();
        Ok(())
    }

    /// Builds a preset with a fresh id and the current time, adds it and shows it.
    pub fn save_new_preset(
        &mut self,
        make: impl FnOnce(Id, Timestamp) -> Result<PresetItem, String>,
    ) -> Result<(), String> {
        let item = make(self.ids.next_id(), (self.clock)())?;
        self.save_preset(item).map_err(|e| LibraryLabels::preset_error(&e, None).1)
    }

    /// Adds the preset, or replaces the one with its id (name and payload).
    pub fn replace_preset(&mut self, item: PresetItem) -> Result<(), LibraryError> {
        if self.preset_store.preset(item.id).is_some() {
            self.preset_store.update_payload(item.id, item.payload.clone(), item.payload_version)?;
            self.preset_store.rename(item.id, &item.name)?;
        } else {
            self.preset_store.add(item)?;
        }
        self.reload_presets();
        Ok(())
    }

    /// Deletes a preset; a Look is deleted in the Look store (it takes its preset along).
    pub fn delete_preset(&mut self, id: Id) {
        let is_look = self.look_store.as_ref().is_some_and(|l| l.library().look(&id.to_string()).is_some());
        match (is_look, self.look_store.clone()) {
            (true, Some(ls)) => {
                let key = id.to_string();
                let _ = ls.edit(|l| l.delete(&key));
                let _ = self.preset_store.delete(id);
                ls.forget_preset(id);
            }
            _ => {
                let _ = self.preset_store.delete(id);
            }
        }
        self.reload_presets();
    }

    /// Writes one preset as a `.sqpreset` file.
    /// A Look that only lives in the Look store (saved in the Text panel) has no stored preset: the file is built from
    /// the listed item, which carries the Look's values and category.
    pub fn export_preset(&self, id: Id, url: &Path) -> Result<(), LibraryError> {
        if self.preset_store.preset(id).is_none()
            && let Some(item) = self.presets.iter().find(|p| p.id == id)
        {
            let data = PresetFile::encode(item)?;
            std::fs::write(url, data).map_err(LibraryStoreError::from)?;
            return Ok(());
        }
        self.preset_store.export_preset(id, url)?;
        Ok(())
    }

    /// Imports `.sqpreset` files; returns the files that failed with their errors (the others are added).
    pub fn import_presets(&mut self, urls: &[PathBuf]) -> Vec<(PathBuf, LibraryError)> {
        let mut failures = Vec::new();
        let now = (self.clock)();
        for url in urls {
            if let Err(e) = self.preset_store.import_preset(url, self.ids.as_mut(), now) {
                failures.push((url.clone(), LibraryError::from(e)));
            }
        }
        self.reload_presets();
        failures
    }

    // MARK: Favorites

    /// Marks a file as favorite, or not.
    pub fn toggle_favorite(&mut self, id: &LibraryEntryID) {
        self.favorites.toggle(id.clone());
        if self.favorites_writable {
            let _ = FavoritesStore::save(&self.favorites, &self.favorites_url);
        }
        self.changed();
    }

    // MARK: Drag

    /// File URLs to put on the pasteboard when dragging the given items out.
    pub fn drag_urls(&self, ids: &[LibraryEntryID]) -> Vec<PathBuf> {
        let all: HashMap<LibraryEntryID, PathBuf> = self.items().into_iter().map(|i| (i.id(), i.url)).collect();
        ids.iter().filter_map(|i| all.get(i).cloned()).collect()
    }

    // MARK: Previews

    /// The preview kind an entry kind gets, none = no preview.
    pub fn preview_kind(kind: LibraryItemKind) -> Option<PreviewKind> {
        match kind {
            LibraryItemKind::Video | LibraryItemKind::Image | LibraryItemKind::Overlay => Some(PreviewKind::Thumbnail),
            LibraryItemKind::Audio => Some(PreviewKind::Waveform),
            LibraryItemKind::Lut | LibraryItemKind::Font | LibraryItemKind::Other => None,
        }
    }

    /// Item scrolled into view: make its preview (idempotent).
    pub fn item_did_appear(&mut self, item: &LibraryItem) {
        let id = item.id();
        let Some(kind) = Self::preview_kind(item.entry.kind) else { return };
        if self.thumbnails.contains_key(&id) || self.failed_previews.contains(&id) {
            return;
        }
        let Some(folder) = self.folder(item.entry.folder_id).cloned() else { return };
        let request =
            PreviewRequest::for_entry(&item.entry, &folder, kind, self.preview_pixel_size.0, self.preview_pixel_size.1);
        let result = match self.coordinator.begin(&request) {
            Ok(PreviewStart::Ready(path)) => Ok(path),
            Ok(PreviewStart::Generate(ticket)) => {
                let generated = self.provider.generate(&request, ticket.temp_path(), ticket.cancel_flag());
                self.coordinator.complete(&ticket, generated)
            }
            Ok(PreviewStart::Joined(ticket)) => {
                // An identical request runs elsewhere; nothing here waits for it.
                self.coordinator.leave(&ticket);
                return;
            }
            Err(e) => Err(e),
        };
        match result {
            Ok(url) => {
                self.thumbnails.insert(id, url);
            }
            Err(e) => {
                // Cancelled, stale or disk low: a later appearance retries. Anything else is remembered.
                if !matches!(e, PreviewError::Cancelled | PreviewError::Stale | PreviewError::DiskLow) {
                    self.failed_previews.insert(id);
                }
            }
        }
        self.changed();
    }
}

/// A preview provider that makes nothing: the draw panel takes its tiles from the host's media atlas.
/// known limit: no waveform strips for audio tiles off the Mac; upgrade when `sq-media` decodes audio peaks on Windows.
pub struct UnavailablePreviewProvider;

impl PreviewProvider for UnavailablePreviewProvider {
    fn generate(
        &self,
        _request: &PreviewRequest,
        _destination: &Path,
        _cancel: &AtomicBool,
    ) -> Result<(), PreviewError> {
        Err(PreviewError::Failed("no preview provider".to_string()))
    }
}

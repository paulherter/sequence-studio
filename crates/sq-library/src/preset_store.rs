// Swift: PresetStore.swift
//! The user's preset library (`presets.json`) and the shareable `.sqpreset` files.
//!
//! Swift: `PresetStore` is an `actor`. Here it is a plain struct with `&mut self` methods, owned by one place; `version`
//! counts every successful change so views can poll it. File access is `std::fs` (portable); the clock comes from the caller.

use crate::favorites::{LibraryStoreError, json_file_io};
use crate::library_search::{fold, numeric_compare};
use crate::title_block::TitleBlock;
use crate::title_template_preset::TitleTemplatePreset;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sq_core_effects::effect_preset::EffectPreset;
use sq_core_effects::keystone::Keystone;
use sq_core_model::effect_defaults::{PayloadError, PayloadReadError, TransitionPreset};
use sq_core_time::{Id, IdSource, SequentialIds, Timestamp};
use std::cmp::Ordering;
use std::path::{Path, PathBuf};

/// What a preset is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PresetKind {
    /// Text style.
    TextTemplate,
    /// Animated text style.
    AnimatedTextTemplate,
    /// Easing curve.
    Easing,
    /// Caption style.
    Caption,
    /// Effect stack (`EffectPreset` payload).
    Effect,
    /// Transition (`TransitionPreset` payload).
    Transition,
    /// G1: a keyframe building block (`Keystone` payload); a saved built-in keeps the built-in's id and overrides it.
    Keystone,
    /// A saved title: generator clips with their element transitions (`TitleBlock` payload). Listed under Text Templates.
    TitleBlock,
    /// A saved multi-layer title (`TitleTemplatePreset` payload: layers, slots, animation zones). Listed under Titles.
    TitleTemplate,
}

impl PresetKind {
    /// Every case, in declaration order.
    pub const ALL: [PresetKind; 9] = [
        PresetKind::TextTemplate,
        PresetKind::AnimatedTextTemplate,
        PresetKind::Easing,
        PresetKind::Caption,
        PresetKind::Effect,
        PresetKind::Transition,
        PresetKind::Keystone,
        PresetKind::TitleBlock,
        PresetKind::TitleTemplate,
    ];

    /// The name used in files.
    pub fn raw_value(self) -> &'static str {
        match self {
            PresetKind::TextTemplate => "textTemplate",
            PresetKind::AnimatedTextTemplate => "animatedTextTemplate",
            PresetKind::Easing => "easing",
            PresetKind::Caption => "caption",
            PresetKind::Effect => "effect",
            PresetKind::Transition => "transition",
            PresetKind::Keystone => "keystone",
            PresetKind::TitleBlock => "titleBlock",
            PresetKind::TitleTemplate => "titleTemplate",
        }
    }

    /// The kind with this file name.
    pub fn from_raw(raw: &str) -> Option<PresetKind> {
        Self::ALL.into_iter().find(|k| k.raw_value() == raw)
    }
}

/// A user preset. `payload` is opaque versioned JSON owned by the feature that created it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PresetItem {
    /// Identity.
    pub id: Id,
    /// What the preset is.
    pub kind: PresetKind,
    /// Shown name.
    pub name: String,
    /// When it was saved.
    #[serde(with = "sq_core_time::timestamp::iso8601")]
    pub created_at: Timestamp,
    /// Versioned JSON of the feature behind `kind`.
    #[serde(with = "sq_core_time::base64")]
    pub payload: Vec<u8>,
    /// Version of the payload's own format.
    pub payload_version: i64,
    /// Name of the `.sqpack` this preset was imported from (shown as a Library folder); `None` for presets the user made.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pack: Option<String>,
    /// Library folder as a "/" path such as `"Lower Thirds/Social"` (a folder of the preset store, not a disk folder);
    /// `None` = top level. Written to `.sqpreset` and `.sqpack`. Older builds ignore the key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
}

/// `folder` as a clean "/" path: segments trimmed, empty ones dropped; `None` when nothing is left.
pub fn normalized_folder(folder: Option<&str>) -> Option<String> {
    let parts: Vec<&str> = folder?.split('/').map(str::trim).filter(|s| !s.is_empty()).collect();
    (!parts.is_empty()).then(|| parts.join("/"))
}

impl PresetItem {
    /// A preset the user made (no pack).
    pub fn new(
        id: Id,
        kind: PresetKind,
        name: &str,
        created_at: Timestamp,
        payload: Vec<u8>,
        payload_version: i64,
    ) -> PresetItem {
        PresetItem { id, kind, name: name.to_string(), created_at, payload, payload_version, pack: None, folder: None }
    }
}

/// Where the presets of a store come from. Only `File` says what the user's presets are: a preset missing from a
/// `Recovered` or `StandIn` store was not deleted by the user.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PresetStoreOrigin {
    /// `presets.json` as it was read (or no file yet).
    File,
    /// `presets.json` was damaged: it was moved aside and the store started empty.
    Recovered,
    /// An empty store used in place of a `presets.json` that could not be opened (written by a newer build).
    StandIn,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PresetsFile {
    format_version: i64,
    presets: Vec<PresetItem>,
}

/// User preset store: `<Application Support>/Sequence Studio/Library/presets.json`.
pub struct PresetStore {
    file_url: PathBuf,
    origin: PresetStoreOrigin,
    items: Vec<PresetItem>,
    version: u64,
}

impl PresetStore {
    /// Version of the file format.
    pub const FORMAT_VERSION: i64 = 1;

    /// Location of `presets.json` below an Application Support folder (the app passes the real one).
    pub fn file_url_in(application_support: &Path) -> PathBuf {
        Self::file_url_in_support(&application_support.join("Sequence Studio"))
    }

    /// Location of `presets.json` below the app's own support folder (`<Application Support>/Sequence Studio`, the folder
    /// the app passes around): `<support>/Library/presets.json`, the file the Swift app wrote.
    pub fn file_url_in_support(support: &Path) -> PathBuf {
        support.join("Library").join("presets.json")
    }

    /// Loads the store. A newer file version fails (file untouched); a damaged file is moved aside (stamped `now`) and the
    /// store starts empty. `stand_in`: this store replaces one that could not be opened (`PresetStoreOrigin::StandIn`).
    pub fn open(application_support: &Path, stand_in: bool, now: Timestamp) -> Result<PresetStore, LibraryStoreError> {
        Self::open_in_support(&application_support.join("Sequence Studio"), stand_in, now)
    }

    /// [`PresetStore::open`] for the app's own support folder (see [`PresetStore::file_url_in_support`]).
    pub fn open_in_support(support: &Path, stand_in: bool, now: Timestamp) -> Result<PresetStore, LibraryStoreError> {
        let file_url = Self::file_url_in_support(support);
        let (items, recovered) =
            match json_file_io::load_versioned::<PresetsFile>(&file_url, Self::FORMAT_VERSION, now)? {
                json_file_io::Loaded::Missing => (Vec::new(), false),
                json_file_io::Loaded::Recovered => (Vec::new(), true),
                json_file_io::Loaded::Value(f) => (f.presets, false),
            };
        let origin = if stand_in {
            PresetStoreOrigin::StandIn
        } else if recovered {
            PresetStoreOrigin::Recovered
        } else {
            PresetStoreOrigin::File
        };
        Ok(PresetStore { file_url, origin, items, version: 0 })
    }

    /// Reads `presets.json` again: another handle on the same file (the shell's import flows) may have written it.
    /// A damaged file is moved aside (stamped `now`) and the list starts empty, as in [`PresetStore::open`].
    pub fn reload_from_disk(&mut self, now: Timestamp) -> Result<(), LibraryStoreError> {
        let items = match json_file_io::load_versioned::<PresetsFile>(&self.file_url, Self::FORMAT_VERSION, now)? {
            json_file_io::Loaded::Missing | json_file_io::Loaded::Recovered => Vec::new(),
            json_file_io::Loaded::Value(f) => f.presets,
        };
        self.items = items;
        self.version += 1;
        Ok(())
    }

    /// Where `presets.json` is.
    pub fn file_url(&self) -> &Path {
        &self.file_url
    }

    /// Where the presets come from.
    pub fn origin(&self) -> PresetStoreOrigin {
        self.origin
    }

    /// Counts every successful change.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// Every preset, in the order they were added.
    pub fn all(&self) -> &[PresetItem] {
        &self.items
    }

    /// One preset.
    pub fn preset(&self, id: Id) -> Option<&PresetItem> {
        self.items.iter().find(|i| i.id == id)
    }

    /// Presets of one kind (`None` = all), optionally filtered by name tokens, sorted by name.
    pub fn presets(&self, kind: Option<PresetKind>, query: &str) -> Vec<PresetItem> {
        let folded = fold(query);
        let tokens: Vec<&str> = folded.split_whitespace().collect();
        let mut out: Vec<PresetItem> = self
            .items
            .iter()
            .filter(|i| kind.is_none_or(|k| i.kind == k))
            .filter(|i| {
                let name = fold(&i.name);
                tokens.iter().all(|t| name.contains(t))
            })
            .cloned()
            .collect();
        out.sort_by(|a, b| match numeric_compare(&fold(&a.name), &fold(&b.name)) {
            Ordering::Equal => a.created_at.partial_cmp(&b.created_at).unwrap_or(Ordering::Equal),
            o => o,
        });
        out
    }

    /// Adds a preset (name trimmed).
    pub fn add(&mut self, item: PresetItem) -> Result<(), LibraryStoreError> {
        let mut item = item;
        item.name = item.name.trim().to_string();
        if item.name.is_empty() {
            return Err(LibraryStoreError::EmptyName);
        }
        if self.items.iter().any(|i| i.id == item.id) {
            return Err(LibraryStoreError::DuplicateId);
        }
        let mut new = self.items.clone();
        new.push(item);
        self.commit(new)
    }

    /// Adds `new` and replaces the payload and name of the presets in `replacing` (id, new item) in one write.
    pub(crate) fn commit_batch(
        &mut self,
        new: Vec<PresetItem>,
        replacing: &[(Id, PresetItem)],
    ) -> Result<(), LibraryStoreError> {
        let mut copy: Vec<PresetItem> = self
            .items
            .iter()
            .map(|old| match replacing.iter().find(|(id, _)| *id == old.id) {
                Some((_, r)) => PresetItem {
                    payload: r.payload.clone(),
                    payload_version: r.payload_version,
                    name: r.name.clone(),
                    ..old.clone()
                },
                None => old.clone(),
            })
            .collect();
        copy.extend(new);
        self.commit(copy)
    }

    /// Renames a preset (name trimmed).
    pub fn rename(&mut self, id: Id, name: &str) -> Result<(), LibraryStoreError> {
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return Err(LibraryStoreError::EmptyName);
        }
        self.mutate(id, |p| p.name = trimmed.to_string())
    }

    /// Files a preset in the Library folder `folder` (a "/" path; `None` or blank = top level).
    pub fn set_folder(&mut self, id: Id, folder: Option<String>) -> Result<(), LibraryStoreError> {
        let folder = normalized_folder(folder.as_deref());
        self.mutate(id, |p| p.folder = folder)
    }

    /// Replaces the payload of a preset.
    pub fn update_payload(&mut self, id: Id, payload: Vec<u8>, version: i64) -> Result<(), LibraryStoreError> {
        self.mutate(id, |p| {
            p.payload = payload;
            p.payload_version = version;
        })
    }

    /// Removes a preset.
    pub fn delete(&mut self, id: Id) -> Result<(), LibraryStoreError> {
        if !self.items.iter().any(|i| i.id == id) {
            return Err(LibraryStoreError::NotFound);
        }
        let new = self.items.iter().filter(|i| i.id != id).cloned().collect();
        self.commit(new)
    }

    fn mutate(&mut self, id: Id, change: impl FnOnce(&mut PresetItem)) -> Result<(), LibraryStoreError> {
        let i = self.items.iter().position(|p| p.id == id).ok_or(LibraryStoreError::NotFound)?;
        let mut copy = self.items.clone();
        change(&mut copy[i]);
        self.commit(copy)
    }

    /// Writes first, then swaps the in-memory state, so a failed write leaves both unchanged.
    fn commit(&mut self, new: Vec<PresetItem>) -> Result<(), LibraryStoreError> {
        json_file_io::write_atomically(
            &PresetsFile { format_version: Self::FORMAT_VERSION, presets: new.clone() },
            &self.file_url,
        )?;
        self.items = new;
        self.version += 1;
        Ok(())
    }

    /// Writes one preset as a `.sqpreset` file. Fails with `NotFound` for an unknown id.
    pub fn export_preset(&self, id: Id, path: &Path) -> Result<(), PresetFileError> {
        let item = self.preset(id).ok_or(LibraryStoreError::NotFound)?;
        json_file_io::write_bytes_atomically(&PresetFile::encode(item)?, path)?;
        Ok(())
    }

    /// Reads a `.sqpreset` file and adds it as a new preset.
    pub fn import_preset(
        &mut self,
        path: &Path,
        ids: &mut dyn IdSource,
        now: Timestamp,
    ) -> Result<PresetItem, PresetFileError> {
        let data = std::fs::read(path).map_err(LibraryStoreError::from)?;
        let item = PresetFile::decode(&data, ids, now)?;
        self.add(item.clone())?;
        Ok(item)
    }
}

/// Why a `.sqpreset` file could not be written or read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PresetFileError {
    /// Not JSON, or not a Sequence Studio preset.
    NotAPreset,
    /// A kind this build does not know.
    UnknownKind(String),
    /// The embedded preset cannot be read (it could never be applied).
    DamagedPayload,
    /// A store error: a newer file or payload, a missing preset, the file system.
    Store(LibraryStoreError),
}

impl From<LibraryStoreError> for PresetFileError {
    fn from(e: LibraryStoreError) -> Self {
        PresetFileError::Store(e)
    }
}

/// One shareable preset as a `.sqpreset` file: versioned JSON with the payload embedded as a JSON object.
pub struct PresetFile;

impl PresetFile {
    /// File extension.
    pub const FILE_EXTENSION: &'static str = "sqpreset";
    /// Value of the `format` key.
    pub const FORMAT_NAME: &'static str = "sequence-studio-preset";
    /// Version of the file format.
    pub const FORMAT_VERSION: i64 = 1;

    /// The file bytes of `item` (pretty, sorted keys).
    pub fn encode(item: &PresetItem) -> Result<Vec<u8>, LibraryStoreError> {
        let payload: Value = serde_json::from_slice(&item.payload).map_err(|e| LibraryStoreError::Io(e.to_string()))?;
        let mut file = json!({
            "format": Self::FORMAT_NAME, "formatVersion": Self::FORMAT_VERSION,
            "kind": item.kind.raw_value(), "name": item.name,
            "payloadVersion": item.payload_version, "payload": payload,
        });
        if let (Some(folder), Some(o)) = (&item.folder, file.as_object_mut()) {
            o.insert("folder".to_string(), Value::String(folder.clone()));
        }
        json_file_io::pretty_sorted(&file)
    }

    /// The preset in `data` as a new item (new id from `ids`, created `now`). A newer format fails with
    /// `NewerFormat`; a newer payload version is left to the feature that reads the payload.
    pub fn decode(data: &[u8], ids: &mut dyn IdSource, now: Timestamp) -> Result<PresetItem, PresetFileError> {
        let root: Value = serde_json::from_slice(data).map_err(|_| PresetFileError::NotAPreset)?;
        let obj = root.as_object().ok_or(PresetFileError::NotAPreset)?;
        let version =
            match (obj.get("format").and_then(Value::as_str), obj.get("formatVersion").and_then(Value::as_i64)) {
                (Some(f), Some(v)) if f == Self::FORMAT_NAME => v,
                _ => return Err(PresetFileError::NotAPreset),
            };
        if version > Self::FORMAT_VERSION {
            return Err(LibraryStoreError::NewerFormat { found: version, supported: Self::FORMAT_VERSION }.into());
        }
        let (Some(kind_name), Some(name), Some(payload_version), Some(payload)) = (
            obj.get("kind").and_then(Value::as_str),
            obj.get("name").and_then(Value::as_str),
            obj.get("payloadVersion").and_then(Value::as_i64),
            obj.get("payload"),
        ) else {
            return Err(PresetFileError::NotAPreset);
        };
        let kind =
            PresetKind::from_raw(kind_name).ok_or_else(|| PresetFileError::UnknownKind(kind_name.to_string()))?;
        let payload_data = serde_json::to_vec(payload).map_err(|_| PresetFileError::DamagedPayload)?;
        Self::validate(kind, &payload_data, payload_version)?;
        let mut item = PresetItem::new(ids.next_id(), kind, name, now, payload_data, payload_version);
        item.folder = normalized_folder(obj.get("folder").and_then(Value::as_str));
        Ok(item)
    }

    /// Kinds this layer knows how to read are checked on import; others stay opaque.
    /// Newer payload fails with `NewerFormat`, unreadable with `DamagedPayload`.
    pub fn validate(kind: PresetKind, payload: &[u8], version: i64) -> Result<(), PresetFileError> {
        let newer = |e: &PayloadError| {
            let PayloadError::NewerVersion { found, supported } = *e;
            PresetFileError::Store(LibraryStoreError::NewerFormat { found, supported })
        };
        let read = |r: Result<(), PayloadReadError>| match r {
            Ok(()) => Ok(()),
            Err(PayloadReadError::Version(e)) => Err(newer(&e)),
            Err(PayloadReadError::Json(_)) => Err(PresetFileError::DamagedPayload),
        };
        match kind {
            // The ids of upgraded effects are thrown away here.
            PresetKind::Effect => {
                read(EffectPreset::from_payload(payload, version, &mut SequentialIds::default()).map(drop))
            }
            PresetKind::Transition => read(TransitionPreset::from_payload(payload, version).map(drop)),
            PresetKind::Keystone => read(Keystone::from_payload(payload, version).map(drop)),
            PresetKind::TitleBlock => {
                TitleBlock::from_payload(payload, version).map(drop).map_err(PresetFileError::from)
            }
            PresetKind::TitleTemplate => {
                TitleTemplatePreset::from_payload(payload, version).map(drop).map_err(PresetFileError::from)
            }
            _ => Ok(()),
        }
    }

    /// `<name>.sqpreset` with path separators and colons replaced; "Preset" for a blank name.
    pub fn suggested_file_name(name: &str) -> String {
        let trimmed = name.trim();
        let safe = if trimmed.is_empty() { "Preset".to_string() } else { trimmed.replace(['/', ':'], "-") };
        format!("{safe}.{}", Self::FILE_EXTENSION)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use sq_core_effects::effect_preset::Anchor;
    use sq_core_time::Time;

    const NOW: Timestamp = Timestamp::from_reference_seconds(800_000_000.0);

    fn item(name: &str, kind: PresetKind, payload: &str) -> PresetItem {
        let created = Timestamp::from_unix_seconds(1_000.0);
        let id = Id::from_u128(u128::from(name.bytes().map(u64::from).sum::<u64>()) + 1000 * kind as u128);
        PresetItem::new(id, kind, name, created, payload.as_bytes().to_vec(), 3)
    }

    fn open(dir: &TempDir) -> PresetStore {
        PresetStore::open(dir.path(), false, NOW).unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn a_second_handle_writes_and_the_first_reads_it_back_from_disk() {
        let dir = TempDir::new();
        let mut first = open(&dir);
        let mut second = open(&dir);
        second.add(item("Pop", PresetKind::Easing, "{}")).unwrap_or_else(|e| panic!("{e}"));
        assert!(first.all().is_empty(), "the first handle still holds its old list");
        let before = first.version();
        first.reload_from_disk(NOW).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(first.all().len(), 1);
        assert!(first.version() > before);
    }

    #[test]
    fn file_lives_under_injected_application_support() {
        let dir = TempDir::new();
        let store = open(&dir);
        assert_eq!(store.file_url(), dir.path().join("Sequence Studio/Library/presets.json"));
        assert!(!store.file_url().exists());
    }

    #[test]
    fn crud_persists_across_reopen() {
        let dir = TempDir::new();
        let mut store = open(&dir);
        let a = item("Lower Third", PresetKind::TextTemplate, r#"{"x":1}"#);
        assert!(store.add(a.clone()).is_ok());
        assert!(store.add(item("Ease Out", PresetKind::Easing, "{}")).is_ok());
        assert!(store.rename(a.id, "  Title  ").is_ok());
        assert!(store.update_payload(a.id, b"[1]".to_vec(), 4).is_ok());
        let mut reopened = open(&dir);
        assert_eq!(reopened.all().len(), 2);
        let got = reopened.preset(a.id).cloned();
        assert_eq!(got.as_ref().map(|g| g.name.as_str()), Some("Title"));
        assert_eq!(got.as_ref().map(|g| g.payload.clone()), Some(b"[1]".to_vec()));
        assert_eq!(got.map(|g| (g.payload_version, g.kind)), Some((4, PresetKind::TextTemplate)));
        assert!(reopened.delete(a.id).is_ok());
        assert_eq!(reopened.all().len(), 1);
        assert!(reopened.preset(a.id).is_none());
    }

    #[test]
    fn search_by_kind_and_name() {
        let dir = TempDir::new();
        let mut store = open(&dir);
        for i in [
            item("Crème Schrift", PresetKind::TextTemplate, "{}"),
            item("Creme Fade", PresetKind::AnimatedTextTemplate, "{}"),
            item("Bounce", PresetKind::Easing, "{}"),
        ] {
            assert!(store.add(i).is_ok());
        }
        let names = |k, q| store.presets(k, q).into_iter().map(|p| p.name).collect::<Vec<_>>();
        assert_eq!(names(Some(PresetKind::Easing), ""), ["Bounce"]);
        assert_eq!(names(None, "FADE creme"), ["Creme Fade"]);
        assert_eq!(names(Some(PresetKind::TextTemplate), "creme"), ["Crème Schrift"]);
        assert_eq!(names(None, ""), ["Bounce", "Creme Fade", "Crème Schrift"]);
        assert!(names(Some(PresetKind::Caption), "").is_empty());
    }

    #[test]
    fn validation_errors() {
        let dir = TempDir::new();
        let mut store = open(&dir);
        let a = item("A", PresetKind::TextTemplate, "{}");
        assert!(store.add(a.clone()).is_ok());
        assert_eq!(store.add(a.clone()), Err(LibraryStoreError::DuplicateId));
        assert_eq!(store.add(item("   ", PresetKind::TextTemplate, "{}")), Err(LibraryStoreError::EmptyName));
        assert_eq!(store.rename(a.id, ""), Err(LibraryStoreError::EmptyName));
        let missing = Id::fixed(999_999);
        assert_eq!(store.rename(missing, "x"), Err(LibraryStoreError::NotFound));
        assert_eq!(store.delete(missing), Err(LibraryStoreError::NotFound));
        assert_eq!(store.all().len(), 1);
    }

    #[test]
    fn file_format_is_versioned_sorted_and_deterministic() {
        let dir = TempDir::new();
        let mut store = open(&dir);
        assert!(store.add(item("A", PresetKind::TextTemplate, "{}")).is_ok());
        let first = std::fs::read_to_string(store.file_url()).unwrap_or_default();
        assert!(first.contains("\"formatVersion\" : 1"));
        let order = ["createdAt", "\"id\"", "\"kind\"", "\"name\"", "\"payload\"", "payloadVersion"];
        let positions: Vec<usize> = order.iter().filter_map(|k| first.find(k)).collect();
        assert_eq!(positions.len(), order.len());
        assert!(positions.windows(2).all(|w| w[0] < w[1]));
        let mut again = open(&dir);
        let id = again.all()[0].id;
        assert!(again.rename(id, "A").is_ok());
        assert_eq!(std::fs::read_to_string(store.file_url()).unwrap_or_default(), first);
    }

    #[test]
    fn newer_format_fails_and_leaves_file_untouched() {
        let dir = TempDir::new();
        let url = PresetStore::file_url_in(dir.path());
        let body = br#"{"formatVersion":2,"presets":[]}"#;
        json_file_io_write(&url, body);
        assert_eq!(
            PresetStore::open(dir.path(), false, NOW).err(),
            Some(LibraryStoreError::NewerFormat { found: 2, supported: 1 })
        );
        assert_eq!(std::fs::read(&url).unwrap_or_default(), body);
    }

    fn json_file_io_write(url: &Path, body: &[u8]) {
        let _ = std::fs::create_dir_all(url.parent().unwrap_or(Path::new(".")));
        let _ = std::fs::write(url, body);
    }

    #[test]
    fn corrupt_file_is_backed_up_and_store_starts_empty() {
        let dir = TempDir::new();
        let url = PresetStore::file_url_in(dir.path());
        json_file_io_write(&url, b"{ broken");
        let mut store = open(&dir);
        assert!(store.all().is_empty());
        assert_eq!(store.origin(), PresetStoreOrigin::Recovered);
        let files = json_file_io::names_in(url.parent().unwrap_or(Path::new(".")));
        assert!(files.iter().any(|f| f.starts_with("presets.json.corrupt-")));
        assert!(store.add(item("Fresh", PresetKind::TextTemplate, "{}")).is_ok());
        assert_eq!(open(&dir).origin(), PresetStoreOrigin::File);
    }

    #[test]
    fn stand_in_origin() {
        let dir = TempDir::new();
        let store = PresetStore::open(dir.path(), true, NOW).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(store.origin(), PresetStoreOrigin::StandIn);
    }

    fn effect_item() -> (EffectPreset, PresetItem) {
        let preset = EffectPreset::new(Anchor::Stretch, Time::new(4, 1));
        let payload = preset.payload().unwrap_or_default();
        (
            preset,
            PresetItem::new(
                Id::fixed(5),
                PresetKind::Effect,
                "Pop In",
                Timestamp::from_unix_seconds(5.0),
                payload,
                EffectPreset::PAYLOAD_VERSION,
            ),
        )
    }

    fn decode(text: &str) -> Result<PresetItem, PresetFileError> {
        PresetFile::decode(text.as_bytes(), &mut SequentialIds::default(), NOW)
    }

    fn file(kind: &str, payload_version: i64, payload: &str) -> String {
        format!(
            r#"{{"format":"{}","formatVersion":1,"kind":"{kind}","name":"x","payloadVersion":{payload_version},"payload":{payload}}}"#,
            PresetFile::FORMAT_NAME
        )
    }

    #[test]
    fn effect_preset_round_trips_through_file() {
        let (preset, item) = effect_item();
        let data = PresetFile::encode(&item).unwrap_or_default();
        let back = PresetFile::decode(&data, &mut SequentialIds::default(), NOW).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!((back.kind, back.name.as_str(), back.payload_version), (PresetKind::Effect, "Pop In", 1));
        assert_ne!(back.id, item.id);
        let read = EffectPreset::from_payload(&back.payload, back.payload_version, &mut SequentialIds::default());
        assert_eq!(read.ok(), Some(preset));
    }

    #[test]
    fn file_is_readable_versioned_json() {
        let (_, item) = effect_item();
        let obj: Value = serde_json::from_slice(&PresetFile::encode(&item).unwrap_or_default()).unwrap_or(Value::Null);
        assert_eq!(obj["format"], PresetFile::FORMAT_NAME);
        assert_eq!(obj["formatVersion"], PresetFile::FORMAT_VERSION);
        assert_eq!(obj["kind"], "effect");
        assert!(obj["payload"].is_object());
    }

    #[test]
    fn rejects_foreign_newer_and_broken_files() {
        assert_eq!(decode(r#"{"a":1}"#), Err(PresetFileError::NotAPreset));
        assert_eq!(decode("nope"), Err(PresetFileError::NotAPreset));
        let newer = format!(
            r#"{{"format":"{}","formatVersion":99,"kind":"effect","name":"x","payloadVersion":1,"payload":{{}}}}"#,
            PresetFile::FORMAT_NAME
        );
        assert_eq!(decode(&newer), Err(LibraryStoreError::NewerFormat { found: 99, supported: 1 }.into()));
        assert_eq!(decode(&file("hologram", 1, "{}")), Err(PresetFileError::UnknownKind("hologram".into())));
    }

    #[test]
    fn store_exports_and_imports() {
        let (dir, other) = (TempDir::new(), TempDir::new());
        let mut store = open(&dir);
        let (preset, item) = effect_item();
        assert!(store.add(item.clone()).is_ok());
        let path = dir.path().join("Pop In.sqpreset");
        assert_eq!(store.export_preset(item.id, &path), Ok(()));
        let mut store2 = open(&other);
        let imported =
            store2.import_preset(&path, &mut SequentialIds::default(), NOW).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(store2.all().iter().map(|p| p.id).collect::<Vec<_>>(), [imported.id]);
        let read =
            EffectPreset::from_payload(&imported.payload, imported.payload_version, &mut SequentialIds::default());
        assert_eq!(read.ok(), Some(preset));
        assert_eq!(open(&other).all().iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["Pop In"]);
        assert_eq!(store.export_preset(Id::fixed(77), &path), Err(LibraryStoreError::NotFound.into()));
    }

    #[test]
    fn effect_payload_is_validated_on_import() {
        assert_eq!(
            decode(&file("effect", 99, "{}")),
            Err(LibraryStoreError::NewerFormat { found: 99, supported: 1 }.into())
        );
        assert_eq!(decode(&file("effect", 1, r#"{"anchor":42}"#)), Err(PresetFileError::DamagedPayload));
        assert_eq!(decode(&file("textTemplate", 1, "{}")).map(|p| p.kind), Ok(PresetKind::TextTemplate));
    }

    #[test]
    fn transition_payload_is_validated_on_import() {
        assert_eq!(
            decode(&file("transition", 99, "{}")),
            Err(LibraryStoreError::NewerFormat { found: 99, supported: 1 }.into())
        );
        assert_eq!(decode(&file("transition", 1, r#"{"kind":"nope"}"#)), Err(PresetFileError::DamagedPayload));
    }

    #[test]
    fn store_import_rejects_bad_payload_without_adding() {
        let dir = TempDir::new();
        let path = dir.path().join("bad.sqpreset");
        let _ = std::fs::write(&path, file("effect", 1, "[]"));
        let mut store = open(&dir);
        assert_eq!(
            store.import_preset(&path, &mut SequentialIds::default(), NOW),
            Err(PresetFileError::DamagedPayload)
        );
        assert!(store.all().is_empty());
    }

    #[test]
    fn suggested_file_name_is_safe() {
        assert_eq!(PresetFile::suggested_file_name("Pop/In: fast"), "Pop-In- fast.sqpreset");
        assert_eq!(PresetFile::suggested_file_name("  "), "Preset.sqpreset");
    }

    /// A real user `presets.json` (57 Premiere imports), copied to `scratch-real/` (ignored by git); skipped when absent.
    #[test]
    fn real_user_file_loads_and_every_payload_decodes() {
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scratch-real/presets.json");
        let Ok(bytes) = std::fs::read(&src) else {
            assert!(std::env::var("SQ_REAL_PRESETS").is_err(), "copy missing");
            return;
        };
        let dir = TempDir::new();
        let url = PresetStore::file_url_in(dir.path());
        json_file_io_write(&url, &bytes);
        let store = open(&dir);
        assert_eq!(store.origin(), PresetStoreOrigin::File);
        assert_eq!(store.all().len(), 57);
        let mut bad = Vec::new();
        for p in store.all() {
            let r = match p.kind {
                PresetKind::Effect => {
                    EffectPreset::from_payload(&p.payload, p.payload_version, &mut SequentialIds::default())
                        .map(drop)
                        .map_err(|e| format!("{e:?}"))
                }
                _ => Ok(()),
            };
            if let Err(e) = r {
                bad.push(format!("{} :: {e}", p.name));
            }
        }
        assert!(bad.is_empty(), "undecodable: {bad:#?}");
    }

    #[test]
    fn support_folder_variant_reads_the_swift_layout() {
        // `<Application Support>/Sequence Studio/Library/presets.json`, opened through either entry point.
        let dir = TempDir::new();
        let support = dir.path().join("Sequence Studio");
        assert_eq!(PresetStore::file_url_in_support(&support), PresetStore::file_url_in(dir.path()));
        let mut a = open(&dir);
        assert!(a.add(item("Zoom In & Out / TOP", PresetKind::Effect, "{}")).is_ok());
        let b = PresetStore::open_in_support(&support, false, NOW).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(b.all().len(), 1);
        assert_eq!(b.file_url(), support.join("Library").join("presets.json"));
    }
}

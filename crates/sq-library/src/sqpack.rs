// Swift: SQPack.swift
//! `.sqpack`: one shareable bundle of presets (any kind) plus the LUTs and OFL fonts they use.
//!
//! Format: one UTF-8 JSON file, data only (nothing in it is ever executed; assets are checked by extension, header and
//! SHA-256 and only ever written to the LUT or font folder). Layout:
//!
//! ```text
//! { "format": "sequence-studio-pack", "formatVersion": 1,
//!   "manifest": { "name", "author", "version", "createdAt", "kinds": ["effect", ...] },
//!   "entries":  [ { "kind", "name", "payloadVersion", "payload": {...}, "assets": ["luts/x.cube"] } ],
//!   "assets":   [ { "path", "sha256", "data": <base64>, "license": { "id", "notice" } } ] }
//! ```
//!
//! `kind` is a plain string, not an enum: a new preset kind is added by registering it in `SQPackKindRegistry`, not by
//! changing the format. A kind this app does not know is skipped on import (listed in `SQPackReadResult::skipped`), never
//! fatal, so a pack from a newer build still opens with everything that can be read.

use crate::favorites::LibraryStoreError;
use crate::preset_store::{PresetFile, PresetFileError, PresetItem, PresetKind};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sq_core_time::text::graphemes;
use sq_core_time::{Timestamp, base64, sha256_digest};
use std::collections::{BTreeSet, HashMap};
use std::path::Path;
use std::sync::Arc;

/// Name, author and kinds of a pack.
#[derive(Clone, Debug, PartialEq)]
pub struct SQPackManifest {
    /// Shown name and Library folder.
    pub name: String,
    /// Who made it.
    pub author: String,
    /// The pack's own version text.
    pub version: String,
    /// When it was made.
    pub created_at: Timestamp,
    /// Distinct entry kinds, sorted. Filled in by encode/decode from the entries; informational in the file.
    pub kinds: Vec<String>,
}

impl SQPackManifest {
    /// A manifest with the Swift defaults (no author, version "1.0", no kinds).
    pub fn new(name: &str, created_at: Timestamp) -> SQPackManifest {
        SQPackManifest {
            name: name.to_string(),
            author: String::new(),
            version: "1.0".to_string(),
            created_at,
            kinds: Vec::new(),
        }
    }
}

/// License of a bundled font.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SQPackLicense {
    /// SPDX id. Only the SIL Open Font License is accepted for fonts ("OFL-1.1").
    pub id: String,
    /// Copyright line and Reserved Font Name statement, as recorded by the font's authors.
    pub notice: String,
}

/// What an asset is, by its folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SQPackAssetKind {
    /// A color lookup table.
    Lut,
    /// A font.
    Font,
}

/// A file bundled in a pack.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SQPackAsset {
    /// `luts/<file>` or `fonts/<file>`: exactly two components.
    pub path: String,
    /// The file.
    pub data: Vec<u8>,
    /// Required for fonts.
    pub license: Option<SQPackLicense>,
}

impl SQPackAsset {
    /// An asset without a license.
    pub fn new(path: &str, data: Vec<u8>) -> SQPackAsset {
        SQPackAsset { path: path.to_string(), data, license: None }
    }

    /// LUT or font, by the folder in `path`.
    pub fn kind(&self) -> Option<SQPackAssetKind> {
        if self.path.starts_with("luts/") {
            Some(SQPackAssetKind::Lut)
        } else if self.path.starts_with("fonts/") {
            Some(SQPackAssetKind::Font)
        } else {
            None
        }
    }
}

/// One preset in a pack.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SQPackEntry {
    /// Kind name (a `PresetKind` file name or a registered kind).
    pub kind: String,
    /// Shown name.
    pub name: String,
    /// Version of the payload's format.
    pub payload_version: i64,
    /// JSON bytes owned by the feature behind `kind`.
    pub payload: Vec<u8>,
    /// Paths of the pack assets this entry uses.
    pub assets: Vec<String>,
    /// Library folder ("/" path) the preset is filed in; `None` = top level of the pack.
    pub folder: Option<String>,
}

impl SQPackEntry {
    /// The entry that carries a stored preset.
    pub fn from_item(item: &PresetItem, assets: Vec<String>) -> SQPackEntry {
        SQPackEntry {
            kind: item.kind.raw_value().to_string(),
            name: item.name.clone(),
            payload_version: item.payload_version,
            payload: item.payload.clone(),
            assets,
            folder: item.folder.clone(),
        }
    }
}

/// A whole pack.
#[derive(Clone, Debug, PartialEq)]
pub struct SQPack {
    /// Name, author and kinds.
    pub manifest: SQPackManifest,
    /// The presets.
    pub entries: Vec<SQPackEntry>,
    /// The bundled files.
    pub assets: Vec<SQPackAsset>,
}

/// An entry of a kind this build does not know.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SQPackSkipped {
    /// Entry name.
    pub name: String,
    /// Its kind.
    pub kind: String,
}

/// A pack that was read.
#[derive(Clone, Debug, PartialEq)]
pub struct SQPackReadResult {
    /// What could be read.
    pub pack: SQPack,
    /// Entries of kinds this build does not know (made by a newer version).
    pub skipped: Vec<SQPackSkipped>,
}

/// Why a pack could not be written or read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SQPackError {
    /// Not a pack file.
    NotAPack,
    /// Written by a newer build.
    NewerFormat {
        /// Version in the file.
        found: i64,
        /// Newest version this build reads.
        supported: i64,
    },
    /// What exceeded its cap: "file", "entries", "payload", "asset", "assets".
    TooLarge(String),
    /// The manifest is missing or its name is bad.
    InvalidManifest(String),
    /// A part has the wrong shape.
    Malformed(String),
    /// An asset path, extension or content is not allowed.
    InvalidAsset(String),
    /// The SHA-256 of an asset does not match.
    ChecksumMismatch(String),
    /// A font without a recorded OFL license.
    MissingLicense(String),
    /// An entry whose payload cannot be read.
    DamagedEntry(String),
    /// No entries.
    EmptyPack,
    /// The file system refused.
    Io(String),
}

/// Size limits, checked while reading (a hostile file cannot make the app allocate more than this).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SQPackCaps {
    /// Whole file.
    pub max_file_bytes: usize,
    /// Entries.
    pub max_entries: usize,
    /// One payload.
    pub max_payload_bytes: usize,
    /// Assets.
    pub max_assets: usize,
    /// One asset.
    pub max_asset_bytes: usize,
    /// All assets together.
    pub max_total_asset_bytes: usize,
}

impl Default for SQPackCaps {
    fn default() -> Self {
        SQPackCaps {
            max_file_bytes: 96 * 1024 * 1024,
            max_entries: 2000,
            max_payload_bytes: 2 * 1024 * 1024,
            max_assets: 200,
            max_asset_bytes: 16 * 1024 * 1024,
            max_total_asset_bytes: 64 * 1024 * 1024,
        }
    }
}

/// Checks one payload: `Ok`, a newer version (`Store(NewerFormat)`) or anything else (damaged).
pub type Validator = Arc<dyn Fn(&[u8], i64) -> Result<(), PresetFileError> + Send + Sync>;

/// Which entry kinds a build understands and how each payload is validated. `standard` knows every `PresetKind`;
/// other layers (workspaces, later the multi-layer text templates) register their kind and validator here.
#[derive(Clone, Default)]
pub struct SQPackKindRegistry {
    validators: HashMap<String, Validator>,
}

impl SQPackKindRegistry {
    /// A registry that knows no kind.
    pub fn new() -> SQPackKindRegistry {
        SQPackKindRegistry::default()
    }

    /// Knows every `PresetKind`.
    pub fn standard() -> SQPackKindRegistry {
        let mut r = SQPackKindRegistry::new();
        for kind in PresetKind::ALL {
            r.register(
                kind.raw_value(),
                Arc::new(move |payload, version| PresetFile::validate(kind, payload, version)),
            );
        }
        r
    }

    /// Adds a kind with its validator.
    pub fn register(&mut self, kind: &str, validate: Validator) {
        self.validators.insert(kind.to_string(), validate);
    }

    /// The kind is registered.
    pub fn knows(&self, kind: &str) -> bool {
        self.validators.contains_key(kind)
    }

    pub(crate) fn validate(&self, entry: &SQPackEntry) -> Result<(), SQPackError> {
        let damaged = || SQPackError::DamagedEntry(entry.name.clone());
        let v = self.validators.get(&entry.kind).ok_or_else(damaged)?;
        match v(&entry.payload, entry.payload_version) {
            Ok(()) => Ok(()),
            Err(PresetFileError::Store(LibraryStoreError::NewerFormat { found, supported })) => {
                Err(SQPackError::NewerFormat { found, supported })
            }
            Err(_) => Err(damaged()),
        }
    }
}

/// Reading and writing of the `.sqpack` format.
pub struct SQPackFormat;

fn trimmed(s: &str) -> &str {
    s.trim()
}

fn has_control(s: &str) -> bool {
    s.chars().any(|c| u32::from(c) < 32)
}

fn extension_lowercase(path: &str) -> String {
    let file = path.rsplit('/').next().unwrap_or("");
    file.rsplit_once('.').map(|(_, e)| e.to_lowercase()).unwrap_or_default()
}

/// ISO 8601 text of a date (whole seconds, UTC), the way the encoder writes it.
fn iso_string(t: Timestamp) -> String {
    #[derive(Serialize)]
    struct Wrap(#[serde(with = "sq_core_time::timestamp::iso8601")] Timestamp);
    match sq_core_time::json_sorted::to_value(Wrap(t)) {
        Ok(Value::String(s)) => s,
        _ => String::new(),
    }
}

fn iso_parse(s: &str) -> Option<Timestamp> {
    #[derive(Deserialize)]
    struct Wrap(#[serde(with = "sq_core_time::timestamp::iso8601")] Timestamp);
    serde_json::from_value::<Wrap>(Value::String(s.to_string())).ok().map(|w| w.0)
}

fn sorted_kinds(entries: &[SQPackEntry]) -> Vec<String> {
    entries.iter().map(|e| e.kind.clone()).collect::<BTreeSet<_>>().into_iter().collect()
}

impl SQPackFormat {
    /// File extension.
    pub const FILE_EXTENSION: &'static str = "sqpack";
    /// Value of the `format` key.
    pub const FORMAT_NAME: &'static str = "sequence-studio-pack";
    /// Version of the file format.
    pub const FORMAT_VERSION: i64 = 1;

    // MARK: Encode

    /// Validates everything the importer would and returns the file bytes.
    pub fn encode(pack: &SQPack, caps: &SQPackCaps, registry: &SQPackKindRegistry) -> Result<Vec<u8>, SQPackError> {
        Self::validate_name(&pack.manifest.name)?;
        if pack.entries.is_empty() {
            return Err(SQPackError::EmptyPack);
        }
        if pack.entries.len() > caps.max_entries {
            return Err(SQPackError::TooLarge("entries".into()));
        }
        Self::validate_assets(&pack.assets, caps)?;
        let paths: BTreeSet<&str> = pack.assets.iter().map(|a| a.path.as_str()).collect();
        let mut entry_json = Vec::new();
        for e in &pack.entries {
            Self::validate_entry_name(&e.name)?;
            if e.payload.len() > caps.max_payload_bytes {
                return Err(SQPackError::TooLarge("payload".into()));
            }
            registry.validate(e)?;
            if let Some(missing) = e.assets.iter().find(|a| !paths.contains(a.as_str())) {
                return Err(SQPackError::InvalidAsset(missing.clone()));
            }
            let payload: Value =
                serde_json::from_slice(&e.payload).map_err(|_| SQPackError::DamagedEntry(e.name.clone()))?;
            let mut entry = json!({
                "kind": e.kind, "name": e.name, "payloadVersion": e.payload_version, "payload": payload, "assets": e.assets,
            });
            if let (Some(folder), Some(o)) = (&e.folder, entry.as_object_mut()) {
                o.insert("folder".to_string(), Value::String(folder.clone()));
            }
            entry_json.push(entry);
        }
        let m = &pack.manifest;
        let kinds = sorted_kinds(&pack.entries);
        let asset_json: Vec<Value> = pack
            .assets
            .iter()
            .map(|a| {
                let mut o = Map::new();
                o.insert("path".into(), json!(a.path));
                o.insert("sha256".into(), json!(sha256_digest::hex(&a.data)));
                o.insert("data".into(), json!(base64::encode(&a.data)));
                if let Some(l) = &a.license {
                    o.insert("license".into(), json!({"id": l.id, "notice": l.notice}));
                }
                Value::Object(o)
            })
            .collect();
        let root = json!({
            "format": Self::FORMAT_NAME, "formatVersion": Self::FORMAT_VERSION,
            "manifest": {"name": m.name, "author": m.author, "version": m.version,
                         "createdAt": iso_string(m.created_at), "kinds": kinds},
            "entries": entry_json, "assets": asset_json,
        });
        let data = serde_json::to_vec(&root).map_err(|e| SQPackError::Io(e.to_string()))?;
        if data.len() > caps.max_file_bytes {
            return Err(SQPackError::TooLarge("file".into()));
        }
        Ok(data)
    }

    // MARK: Decode

    /// Reads and validates a pack.
    pub fn decode(
        data: &[u8],
        caps: &SQPackCaps,
        registry: &SQPackKindRegistry,
    ) -> Result<SQPackReadResult, SQPackError> {
        if data.len() > caps.max_file_bytes {
            return Err(SQPackError::TooLarge("file".into()));
        }
        let root: Value = serde_json::from_slice(data).map_err(|_| SQPackError::NotAPack)?;
        let version =
            match (root.get("format").and_then(Value::as_str), root.get("formatVersion").and_then(Value::as_i64)) {
                (Some(f), Some(v)) if f == Self::FORMAT_NAME && v >= 1 => v,
                _ => return Err(SQPackError::NotAPack),
            };
        if version > Self::FORMAT_VERSION {
            return Err(SQPackError::NewerFormat { found: version, supported: Self::FORMAT_VERSION });
        }
        let invalid_manifest = || SQPackError::InvalidManifest("manifest".into());
        let m = root.get("manifest").and_then(Value::as_object).ok_or_else(invalid_manifest)?;
        let name = m.get("name").and_then(Value::as_str).ok_or_else(invalid_manifest)?;
        Self::validate_name(name)?;
        let prefix = |key: &str, count: usize| -> String {
            graphemes(m.get(key).and_then(Value::as_str).unwrap_or("")).take(count).collect()
        };
        let mut manifest = SQPackManifest::new(trimmed(name), Timestamp::from_unix_seconds(0.0));
        manifest.author = prefix("author", 200);
        manifest.version = prefix("version", 40);
        // The Swift default for a missing date is `Date()`; the clock is not read here, so a missing date is the epoch.
        if let Some(d) = m.get("createdAt").and_then(Value::as_str).and_then(iso_parse) {
            manifest.created_at = d;
        }

        let assets = Self::decode_assets(root.get("assets"), caps)?;
        let paths: BTreeSet<&str> = assets.iter().map(|a| a.path.as_str()).collect();

        let raw_entries =
            root.get("entries").and_then(Value::as_array).ok_or_else(|| SQPackError::Malformed("entries".into()))?;
        if raw_entries.len() > caps.max_entries {
            return Err(SQPackError::TooLarge("entries".into()));
        }
        let (mut entries, mut skipped) = (Vec::new(), Vec::new());
        for raw in raw_entries {
            let malformed = || SQPackError::Malformed("entry".into());
            let o = raw.as_object().ok_or_else(malformed)?;
            let (Some(kind), Some(ename), Some(pv), Some(payload)) = (
                o.get("kind").and_then(Value::as_str),
                o.get("name").and_then(Value::as_str),
                o.get("payloadVersion").and_then(Value::as_i64),
                o.get("payload"),
            ) else {
                return Err(malformed());
            };
            Self::validate_entry_name(ename)?;
            if !registry.knows(kind) {
                skipped.push(SQPackSkipped { name: ename.to_string(), kind: kind.to_string() });
                continue;
            }
            let payload_data = serde_json::to_vec(payload).map_err(|_| SQPackError::DamagedEntry(ename.to_string()))?;
            if payload_data.len() > caps.max_payload_bytes {
                return Err(SQPackError::TooLarge("payload".into()));
            }
            let refs: Vec<String> = match o.get("assets") {
                None => Vec::new(),
                Some(list) => list
                    .as_array()
                    .and_then(|a| a.iter().map(|s| s.as_str().map(str::to_string)).collect())
                    .ok_or_else(|| SQPackError::Malformed("assets".into()))?,
            };
            let entry = SQPackEntry {
                kind: kind.to_string(),
                name: trimmed(ename).to_string(),
                payload_version: pv,
                payload: payload_data,
                assets: refs,
                folder: crate::preset_store::normalized_folder(o.get("folder").and_then(Value::as_str)),
            };
            registry.validate(&entry)?;
            if let Some(missing) = entry.assets.iter().find(|a| !paths.contains(a.as_str())) {
                return Err(SQPackError::InvalidAsset(missing.clone()));
            }
            entries.push(entry);
        }
        if entries.is_empty() {
            return Err(SQPackError::EmptyPack);
        }
        manifest.kinds = sorted_kinds(&entries);
        Ok(SQPackReadResult { pack: SQPack { manifest, entries, assets }, skipped })
    }

    fn decode_assets(value: Option<&Value>, caps: &SQPackCaps) -> Result<Vec<SQPackAsset>, SQPackError> {
        let Some(value) = value else { return Ok(Vec::new()) };
        let list = value.as_array().ok_or_else(|| SQPackError::Malformed("assets".into()))?;
        if list.len() > caps.max_assets {
            return Err(SQPackError::TooLarge("assets".into()));
        }
        let (mut out, mut total) = (Vec::new(), 0usize);
        for raw in list {
            let malformed = || SQPackError::Malformed("asset".into());
            let o = raw.as_object().ok_or_else(malformed)?;
            let (Some(path), Some(b64), Some(sum)) = (
                o.get("path").and_then(Value::as_str),
                o.get("data").and_then(Value::as_str),
                o.get("sha256").and_then(Value::as_str),
            ) else {
                return Err(malformed());
            };
            Self::validate_path(path)?;
            if b64.len() > caps.max_asset_bytes / 3 * 4 + 8 {
                return Err(SQPackError::TooLarge("asset".into()));
            }
            let data = base64::decode(b64).ok_or_else(|| SQPackError::InvalidAsset(path.to_string()))?;
            if data.len() > caps.max_asset_bytes {
                return Err(SQPackError::TooLarge("asset".into()));
            }
            total += data.len();
            if total > caps.max_total_asset_bytes {
                return Err(SQPackError::TooLarge("assets".into()));
            }
            if sha256_digest::hex(&data) != sum.to_lowercase() {
                return Err(SQPackError::ChecksumMismatch(path.to_string()));
            }
            let license = o.get("license").and_then(Value::as_object).and_then(|l| {
                Some(SQPackLicense {
                    id: l.get("id")?.as_str()?.to_string(),
                    notice: l.get("notice")?.as_str()?.to_string(),
                })
            });
            out.push(SQPackAsset { path: path.to_string(), data, license });
        }
        Self::validate_assets(&out, caps)?;
        Ok(out)
    }

    // MARK: Validation (shared by encode, decode and the installer)

    pub(crate) fn validate_assets(assets: &[SQPackAsset], caps: &SQPackCaps) -> Result<(), SQPackError> {
        if assets.len() > caps.max_assets {
            return Err(SQPackError::TooLarge("assets".into()));
        }
        let (mut seen, mut total) = (BTreeSet::new(), 0usize);
        for a in assets {
            if a.data.len() > caps.max_asset_bytes {
                return Err(SQPackError::TooLarge("asset".into()));
            }
            total += a.data.len();
            if total > caps.max_total_asset_bytes {
                return Err(SQPackError::TooLarge("assets".into()));
            }
            if !seen.insert(a.path.to_lowercase()) {
                return Err(SQPackError::InvalidAsset(a.path.clone()));
            }
            Self::validate_asset(a)?;
        }
        Ok(())
    }

    /// Path, extension, content header and (fonts) license of one asset.
    pub(crate) fn validate_asset(a: &SQPackAsset) -> Result<(), SQPackError> {
        Self::validate_path(&a.path)?;
        let ext = extension_lowercase(&a.path);
        let invalid = || SQPackError::InvalidAsset(a.path.clone());
        match a.kind() {
            Some(SQPackAssetKind::Lut) => {
                if !["cube", "3dl"].contains(&ext.as_str())
                    || a.data.is_empty()
                    || a.data.contains(&0)
                    || std::str::from_utf8(&a.data).is_err()
                {
                    return Err(invalid());
                }
            }
            Some(SQPackAssetKind::Font) => {
                if !["ttf", "otf"].contains(&ext.as_str()) || a.data.len() < 4 {
                    return Err(invalid());
                }
                let head = &a.data[..4];
                if head != [0, 1, 0, 0] && head != b"OTTO" && head != b"true" {
                    return Err(invalid());
                }
                let licensed = a.license.as_ref().is_some_and(|l| {
                    ["OFL-1.1", "OFL"].contains(&l.id.trim().to_uppercase().as_str()) && !trimmed(&l.notice).is_empty()
                });
                if !licensed {
                    return Err(SQPackError::MissingLicense(a.path.clone()));
                }
            }
            None => return Err(invalid()),
        }
        Ok(())
    }

    /// `luts/<file>` or `fonts/<file>`: two components, a plain file name (letters, digits, space . _ - ( )), no dot-files, no `..`.
    pub(crate) fn validate_path(path: &str) -> Result<(), SQPackError> {
        let invalid = || SQPackError::InvalidAsset(path.to_string());
        let parts: Vec<&str> = path.split('/').collect();
        if parts.len() != 2 || !["luts", "fonts"].contains(&parts[0]) {
            return Err(invalid());
        }
        let file = parts[1];
        let allowed = |c: char| c.is_alphabetic() || c.is_numeric() || " ._-()".contains(c);
        let first = file.chars().next();
        let ok = !file.is_empty()
            && graphemes(file).count() <= 100
            && file.chars().all(allowed)
            && first != Some('.')
            && first != Some(' ')
            && !file.contains("..");
        if ok { Ok(()) } else { Err(invalid()) }
    }

    /// The pack name: becomes a Library folder, so no separators, no control characters, no leading dot.
    pub fn validate_name(name: &str) -> Result<(), SQPackError> {
        let t = trimmed(name);
        let bad = t.contains(['/', '\\', ':']) || has_control(t);
        if t.is_empty() || graphemes(t).count() > 120 || bad || t.starts_with('.') {
            return Err(SQPackError::InvalidManifest("name".into()));
        }
        Ok(())
    }

    pub(crate) fn validate_entry_name(name: &str) -> Result<(), SQPackError> {
        let t = trimmed(name);
        if t.is_empty() || graphemes(t).count() > 200 || has_control(t) {
            return Err(SQPackError::Malformed("name".into()));
        }
        Ok(())
    }

    // MARK: Files

    /// Encodes `pack` and writes it to `path`.
    pub fn write(pack: &SQPack, path: &Path, registry: &SQPackKindRegistry) -> Result<(), SQPackError> {
        let data = Self::encode(pack, &SQPackCaps::default(), registry)?;
        crate::favorites::json_file_io::write_bytes_atomically(&data, path).map_err(|e| SQPackError::Io(e.to_string()))
    }

    /// Reads a pack file; the size is checked before the file is read.
    pub fn read(
        path: &Path,
        caps: &SQPackCaps,
        registry: &SQPackKindRegistry,
    ) -> Result<SQPackReadResult, SQPackError> {
        let size = std::fs::metadata(path).map_err(|e| SQPackError::Io(e.to_string()))?.len();
        if usize::try_from(size).map_or(true, |s| s > caps.max_file_bytes) {
            return Err(SQPackError::TooLarge("file".into()));
        }
        Self::decode(&std::fs::read(path).map_err(|e| SQPackError::Io(e.to_string()))?, caps, registry)
    }

    /// `<name>.sqpack` with path separators and colons replaced; "Pack" for a blank name.
    pub fn suggested_file_name(name: &str) -> String {
        let t = trimmed(name);
        let safe = if t.is_empty() { "Pack".to_string() } else { t.replace(['/', ':'], "-") };
        format!("{safe}.{}", Self::FILE_EXTENSION)
    }
}

#[cfg(test)]
pub(crate) mod fixtures {
    use super::*;
    use sq_core_effects::effect_preset::{Anchor, EffectPreset};
    use sq_core_time::{Id, Time};

    pub(crate) const NOW: Timestamp = Timestamp::from_reference_seconds(800_000_000.0);

    pub(crate) fn effect_item(name: &str, id: u64) -> PresetItem {
        let payload = EffectPreset::new(Anchor::Stretch, Time::new(4, 1)).payload().unwrap_or_default();
        PresetItem::new(Id::fixed(id), PresetKind::Effect, name, NOW, payload, EffectPreset::PAYLOAD_VERSION)
    }

    pub(crate) fn cube(n: usize) -> Vec<u8> {
        let mut s = format!("TITLE \"t\"\nLUT_3D_SIZE {n}\n");
        for _ in 0..n * n * n {
            s.push_str("0.0 0.0 0.0\n");
        }
        s.into_bytes()
    }

    pub(crate) fn font() -> Vec<u8> {
        let mut d = vec![0, 1, 0, 0];
        d.extend([7u8; 64]);
        d
    }

    pub(crate) fn ofl(notice: &str) -> SQPackLicense {
        SQPackLicense { id: "OFL-1.1".into(), notice: notice.into() }
    }

    pub(crate) fn pack(entries: Option<Vec<SQPackEntry>>, assets: Vec<SQPackAsset>) -> SQPack {
        let entries = entries.unwrap_or_else(|| vec![SQPackEntry::from_item(&effect_item("Pop In", 1), vec![])]);
        let mut manifest = SQPackManifest::new("Pulse Presets Bundle 3.0", Timestamp::from_unix_seconds(100.0));
        manifest.author = "Alex".into();
        manifest.version = "3.0".into();
        SQPack { manifest, entries, assets }
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::*;
    use super::*;

    fn std_encode(p: &SQPack) -> Result<Vec<u8>, SQPackError> {
        SQPackFormat::encode(p, &SQPackCaps::default(), &SQPackKindRegistry::standard())
    }

    fn std_decode(d: &[u8]) -> Result<SQPackReadResult, SQPackError> {
        decode_with(d, &SQPackCaps::default())
    }

    fn decode_with(d: &[u8], caps: &SQPackCaps) -> Result<SQPackReadResult, SQPackError> {
        SQPackFormat::decode(d, caps, &SQPackKindRegistry::standard())
    }

    fn encoded(p: &SQPack) -> Vec<u8> {
        std_encode(p).unwrap_or_else(|e| panic!("{e:?}"))
    }

    fn rewrite(data: &[u8], change: impl FnOnce(&mut Value)) -> Vec<u8> {
        let mut v: Value = serde_json::from_slice(data).unwrap_or(Value::Null);
        change(&mut v);
        serde_json::to_vec(&v).unwrap_or_default()
    }

    fn lut_pack() -> SQPack {
        pack(None, vec![SQPackAsset::new("luts/ok.cube", cube(2))])
    }

    #[test]
    fn round_trip_keeps_entries_and_assets() {
        let lut = SQPackAsset::new("luts/warm.cube", cube(2));
        let fnt = SQPackAsset {
            license: Some(ofl("Copyright 2024 Test Authors")),
            ..SQPackAsset::new("fonts/Test-Regular.ttf", font())
        };
        let entry = SQPackEntry::from_item(&effect_item("Pop In", 1), vec!["luts/warm.cube".into()]);
        let back = std_decode(&encoded(&pack(Some(vec![entry]), vec![lut, fnt]))).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(
            (back.pack.manifest.name.as_str(), back.pack.manifest.author.as_str()),
            ("Pulse Presets Bundle 3.0", "Alex")
        );
        assert_eq!(back.pack.manifest.created_at, Timestamp::from_unix_seconds(100.0));
        assert_eq!((back.pack.entries.len(), back.pack.entries[0].name.as_str()), (1, "Pop In"));
        assert_eq!(back.pack.entries[0].assets, ["luts/warm.cube"]);
        let mut paths: Vec<&str> = back.pack.assets.iter().map(|a| a.path.as_str()).collect();
        paths.sort_unstable();
        assert_eq!(paths, ["fonts/Test-Regular.ttf", "luts/warm.cube"]);
        assert_eq!(back.pack.assets.iter().find(|a| a.path == "luts/warm.cube").map(|a| a.data.clone()), Some(cube(2)));
        assert!(back.skipped.is_empty());
        assert_eq!(back.pack.manifest.kinds, ["effect"]);
    }

    #[test]
    fn file_is_versioned_json() {
        let o: Value = serde_json::from_slice(&encoded(&pack(None, vec![]))).unwrap_or(Value::Null);
        assert_eq!(o["format"], SQPackFormat::FORMAT_NAME);
        assert_eq!(o["formatVersion"], SQPackFormat::FORMAT_VERSION);
        assert_eq!(o["manifest"]["name"], "Pulse Presets Bundle 3.0");
    }

    #[test]
    fn rejects_non_pack_and_newer_version() {
        assert_eq!(std_decode(b"nope"), Err(SQPackError::NotAPack));
        let preset_file = PresetFile::encode(&effect_item("x", 1)).unwrap_or_default();
        assert_eq!(std_decode(&preset_file), Err(SQPackError::NotAPack));
        let good = encoded(&pack(None, vec![]));
        let newer = rewrite(&good, |v| v["formatVersion"] = json!(2));
        assert_eq!(std_decode(&newer), Err(SQPackError::NewerFormat { found: 2, supported: 1 }));
        assert_eq!(std_decode(&rewrite(&good, |v| v["formatVersion"] = json!(0))), Err(SQPackError::NotAPack));
    }

    #[test]
    fn rejects_malicious_asset_paths() {
        let paths = [
            "../evil.cube",
            "luts/../../evil.cube",
            "/etc/x.cube",
            "luts/a/b.cube",
            "luts\\x.cube",
            "luts/.hidden.cube",
            "luts/x.sh",
            "bin/x.cube",
            "luts/",
            "luts/x\u{0}.cube",
            "fonts/x.cube",
            "luts/x.ttf",
            "luts/..cube",
        ];
        let good = encoded(&lut_pack());
        for path in paths {
            let bad = rewrite(&good, |v| v["assets"][0]["path"] = json!(path));
            assert!(std_decode(&bad).is_err(), "path {path}");
        }
    }

    #[test]
    fn encode_rejects_bad_asset_path() {
        assert!(std_encode(&pack(None, vec![SQPackAsset::new("../x.cube", cube(2))])).is_err());
    }

    #[test]
    fn rejects_checksum_mismatch_and_wrong_content() {
        let good = encoded(&lut_pack());
        let tampered = rewrite(&good, |v| v["assets"][0]["data"] = json!(base64::encode(b"TITLE x\nLUT_3D_SIZE 2\n")));
        assert_eq!(std_decode(&tampered), Err(SQPackError::ChecksumMismatch("luts/ok.cube".into())));
        let elf = SQPackAsset::new("luts/b.cube", vec![0x7f, 0x45, 0x4c, 0x46, 0, 0]);
        assert!(std_encode(&pack(None, vec![elf])).is_err());
        let script =
            SQPackAsset { license: Some(ofl("c")), ..SQPackAsset::new("fonts/f.ttf", b"#!/bin/sh\n".to_vec()) };
        assert!(std_encode(&pack(None, vec![script])).is_err());
    }

    #[test]
    fn fonts_need_a_recorded_ofl_licence() {
        let missing = SQPackError::MissingLicense("fonts/a.ttf".into());
        let with = |license| pack(None, vec![SQPackAsset { license, ..SQPackAsset::new("fonts/a.ttf", font()) }]);
        assert_eq!(std_encode(&with(None)), Err(missing.clone()));
        let other = SQPackLicense { id: "Commercial".into(), notice: "x".into() };
        assert_eq!(std_encode(&with(Some(other))), Err(missing.clone()));
        assert_eq!(std_encode(&with(Some(ofl(" ")))), Err(missing.clone()));
        let data = encoded(&with(Some(ofl("c"))));
        let stripped = rewrite(&data, |v| {
            if let Some(o) = v["assets"][0].as_object_mut() {
                o.remove("license");
            }
        });
        assert_eq!(std_decode(&stripped), Err(missing));
    }

    #[test]
    fn oversized_pack_is_rejected_before_parsing() {
        let caps = SQPackCaps { max_file_bytes: 100, ..SQPackCaps::default() };
        assert_eq!(decode_with(&encoded(&pack(None, vec![])), &caps), Err(SQPackError::TooLarge("file".into())));
    }

    #[test]
    fn caps_on_entries_payload_and_assets() {
        let two = pack(
            Some(vec![
                SQPackEntry::from_item(&effect_item("A", 1), vec![]),
                SQPackEntry::from_item(&effect_item("B", 2), vec![]),
            ]),
            vec![],
        );
        let data = encoded(&two);
        let std = SQPackCaps::default();
        let too_large = |what: &str| Some(SQPackError::TooLarge(what.into()));
        assert_eq!(decode_with(&data, &SQPackCaps { max_entries: 1, ..std }).err(), too_large("entries"));
        assert_eq!(decode_with(&data, &SQPackCaps { max_payload_bytes: 10, ..std }).err(), too_large("payload"));
        let big = encoded(&pack(None, vec![SQPackAsset::new("luts/ok.cube", cube(8))]));
        assert_eq!(decode_with(&big, &SQPackCaps { max_asset_bytes: 100, ..std }).err(), too_large("asset"));
        assert_eq!(decode_with(&big, &SQPackCaps { max_total_asset_bytes: 100, ..std }).err(), too_large("assets"));
        assert_eq!(decode_with(&big, &SQPackCaps { max_assets: 0, ..std }).err(), too_large("assets"));
    }

    #[test]
    fn rejects_bad_manifest_and_damaged_payload() {
        let good = encoded(&pack(None, vec![]));
        for name in ["", "   ", "a/b", "..", &"x".repeat(500)] {
            let bad = rewrite(&good, |v| v["manifest"]["name"] = json!(name));
            assert!(std_decode(&bad).is_err(), "name {}", name.chars().take(8).collect::<String>());
        }
        assert!(std_decode(&rewrite(&good, |v| v["manifest"] = Value::Null)).is_err());
        let damaged = rewrite(&good, |v| v["entries"][0]["payload"] = json!({"junk": 1}));
        assert_eq!(std_decode(&damaged).err(), Some(SQPackError::DamagedEntry("Pop In".into())));
        assert_eq!(std_decode(&rewrite(&good, |v| v["entries"] = json!([]))).err(), Some(SQPackError::EmptyPack));
    }

    #[test]
    fn entry_referencing_missing_asset_is_rejected() {
        let entry = SQPackEntry::from_item(&effect_item("Pop In", 1), vec!["luts/none.cube".into()]);
        assert!(std_encode(&pack(Some(vec![entry]), vec![])).is_err());
    }

    #[test]
    fn duplicate_asset_paths_are_rejected() {
        let p = pack(None, vec![SQPackAsset::new("luts/a.cube", cube(2)), SQPackAsset::new("luts/A.cube", cube(2))]);
        assert!(std_encode(&p).is_err());
    }

    #[test]
    fn unknown_kinds_are_skipped_not_fatal() {
        let good = encoded(&pack(None, vec![]));
        let future = rewrite(&good, |v| {
            if let Some(list) = v["entries"].as_array_mut() {
                list.push(json!({"kind": "multiLayerTemplate", "name": "Future", "payloadVersion": 1, "payload": {"layers": []}, "assets": []}));
            }
        });
        let r = std_decode(&future).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(r.pack.entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["Pop In"]);
        assert_eq!(r.skipped, [SQPackSkipped { name: "Future".into(), kind: "multiLayerTemplate".into() }]);
    }

    #[test]
    fn registered_kind_plugs_in_with_its_own_validator() {
        let mut registry = SQPackKindRegistry::standard();
        registry.register(
            "multiLayerTemplate",
            Arc::new(|payload, version| {
                let ok = version == 1 && serde_json::from_slice::<Value>(payload).is_ok_and(|v| v.is_object());
                if ok { Ok(()) } else { Err(PresetFileError::NotAPreset) }
            }),
        );
        let entry = SQPackEntry {
            kind: "multiLayerTemplate".into(),
            name: "Lower Third".into(),
            payload_version: 1,
            payload: br#"{"layers":[]}"#.to_vec(),
            assets: vec![],
            folder: None,
        };
        let caps = SQPackCaps::default();
        let data = SQPackFormat::encode(&pack(Some(vec![entry]), vec![]), &caps, &registry).unwrap_or_default();
        let back = SQPackFormat::decode(&data, &caps, &registry).unwrap_or_else(|e| panic!("{e:?}"));
        assert!(back.pack.entries[0].kind == "multiLayerTemplate" && back.skipped.is_empty());
        // The same file read by an app that does not know the kind: skipped, nothing left, so an empty pack.
        assert_eq!(std_decode(&data).err(), Some(SQPackError::EmptyPack));
        let bad = SQPackEntry {
            name: "Bad".into(),
            payload_version: 9,
            payload: b"{}".to_vec(),
            kind: "multiLayerTemplate".into(),
            assets: vec![],
            folder: None,
        };
        assert_eq!(
            SQPackFormat::encode(&pack(Some(vec![bad]), vec![]), &caps, &registry).err(),
            Some(SQPackError::DamagedEntry("Bad".into()))
        );
    }

    #[test]
    fn file_round_trip_and_suggested_name() {
        let dir = crate::folder_scanner::test_dir::TempDir::new();
        let path = dir.path().join("x.sqpack");
        assert_eq!(SQPackFormat::write(&pack(None, vec![]), &path, &SQPackKindRegistry::standard()), Ok(()));
        let read = SQPackFormat::read(&path, &SQPackCaps::default(), &SQPackKindRegistry::standard());
        assert_eq!(read.map(|r| r.pack.entries.len()), Ok(1));
        assert_eq!(SQPackFormat::suggested_file_name("Pulse: Bundle/3"), "Pulse- Bundle-3.sqpack");
        assert_eq!(SQPackFormat::suggested_file_name("  "), "Pack.sqpack");
    }
}

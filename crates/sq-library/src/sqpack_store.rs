// Swift: SQPackStore.swift
//! Packs and the preset store: bundling presets, importing a pack into its Library folder, installing pack assets.

use crate::favorites::LibraryStoreError;
use crate::library_search::fold;
use crate::preset_store::{PresetItem, PresetKind, PresetStore};
use crate::sqpack::{
    SQPack, SQPackAsset, SQPackAssetKind, SQPackEntry, SQPackError, SQPackFormat, SQPackKindRegistry, SQPackManifest,
};
use serde_json::Value;
use sq_core_time::{Id, IdSource, Timestamp};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

/// What to do with an imported preset whose name already exists in the pack's folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SQPackConflict {
    /// Keep both: the new one gets " 2", " 3" ... after its name.
    Rename,
    /// Overwrite the existing preset with the pack's version.
    Replace,
    /// Leave the existing preset, drop the pack's.
    Skip,
}

/// What an import did.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SQPackImportResult {
    /// New presets.
    pub added: Vec<PresetItem>,
    /// Presets overwritten.
    pub replaced: usize,
    /// Pack presets dropped.
    pub skipped: usize,
    /// Entries of kinds that do not live in the preset store (workspaces, ...): the caller installs them.
    pub deferred: Vec<SQPackEntry>,
}

/// Why a pack could not be imported.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SQPackImportError {
    /// The pack is not acceptable.
    Pack(SQPackError),
    /// The preset store refused.
    Store(LibraryStoreError),
}

impl From<SQPackError> for SQPackImportError {
    fn from(e: SQPackError) -> Self {
        SQPackImportError::Pack(e)
    }
}

impl From<LibraryStoreError> for SQPackImportError {
    fn from(e: LibraryStoreError) -> Self {
        SQPackImportError::Store(e)
    }
}

impl PresetStore {
    /// Bundles the presets `ids` (in that order; unknown ids are ignored). `assets` are the files they use, `asset_refs`
    /// maps a preset id to the asset paths it references.
    pub fn make_pack(
        &self,
        ids: &[Id],
        manifest: &SQPackManifest,
        assets: Vec<SQPackAsset>,
        asset_refs: &HashMap<Id, Vec<String>>,
    ) -> Result<SQPack, SQPackError> {
        let items: Vec<&PresetItem> = ids.iter().filter_map(|id| self.preset(*id)).collect();
        if items.is_empty() {
            return Err(SQPackError::EmptyPack);
        }
        let mut m = manifest.clone();
        m.kinds = items.iter().map(|i| i.kind.raw_value().to_string()).collect::<BTreeSet<_>>().into_iter().collect();
        let entries = items
            .iter()
            .map(|i| SQPackEntry::from_item(i, asset_refs.get(&i.id).cloned().unwrap_or_default()))
            .collect();
        Ok(SQPack { manifest: m, entries, assets })
    }

    /// Names of pack entries that already exist in the pack's folder (same kind and name).
    pub fn conflicts(&self, pack: &SQPack) -> Vec<String> {
        pack.entries
            .iter()
            .filter(|e| {
                PresetKind::from_raw(&e.kind).is_some_and(|k| self.existing(k, &e.name, &pack.manifest.name).is_some())
            })
            .map(|e| e.name.clone())
            .collect()
    }

    /// Adds the pack's presets to the store in a folder named after the pack, in one write. New presets get ids from
    /// `ids` and are created `now`.
    pub fn import_pack(
        &mut self,
        pack: &SQPack,
        conflict: SQPackConflict,
        registry: &SQPackKindRegistry,
        ids: &mut dyn IdSource,
        now: Timestamp,
    ) -> Result<SQPackImportResult, SQPackImportError> {
        let folder = pack.manifest.name.trim().to_string();
        SQPackFormat::validate_name(&folder)?;
        let mut result = SQPackImportResult::default();
        let mut replacing: Vec<(Id, PresetItem)> = Vec::new();
        let mut taken: BTreeSet<String> = BTreeSet::new(); // "kind|folded name" claimed by this batch
        for e in &pack.entries {
            registry.validate(e)?;
            let Some(kind) = PresetKind::from_raw(&e.kind) else {
                result.deferred.push(e.clone());
                continue;
            };
            let key = |n: &str| format!("{}|{}", kind.raw_value(), fold(n));
            let mut name = e.name.trim().to_string();
            let old = self.existing(kind, &name, &folder).map(|o| o.id);
            if let (Some(old_id), false) = (old, taken.contains(&key(&name))) {
                match conflict {
                    SQPackConflict::Skip => {
                        result.skipped += 1;
                        continue;
                    }
                    SQPackConflict::Replace => {
                        let mut item = PresetItem::new(old_id, kind, &name, now, e.payload.clone(), e.payload_version);
                        item.pack = Some(folder.clone());
                        replacing.push((old_id, item));
                        taken.insert(key(&name));
                        result.replaced += 1;
                        continue;
                    }
                    SQPackConflict::Rename => {}
                }
            }
            if old.is_some() || taken.contains(&key(&name)) {
                let mut n = 2;
                while self.existing(kind, &format!("{name} {n}"), &folder).is_some()
                    || taken.contains(&key(&format!("{name} {n}")))
                {
                    n += 1;
                }
                name = format!("{name} {n}");
            }
            taken.insert(key(&name));
            let mut item = PresetItem::new(ids.next_id(), kind, &name, now, e.payload.clone(), e.payload_version);
            item.pack = Some(folder.clone());
            result.added.push(item);
        }
        if !result.added.is_empty() || !replacing.is_empty() {
            self.commit_batch(result.added.clone(), &replacing)?;
        }
        Ok(result)
    }

    fn existing(&self, kind: PresetKind, name: &str, pack: &str) -> Option<&PresetItem> {
        let n = fold(name.trim());
        self.all().iter().find(|i| i.kind == kind && i.pack.as_deref() == Some(pack) && fold(&i.name) == n)
    }
}

/// Where `SQPackInstaller::install` put the files.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Installed {
    /// LUT files written (or reused).
    pub luts: Vec<PathBuf>,
    /// Font files to register with the system for this session (in the host).
    pub fonts: Vec<PathBuf>,
}

/// Writes pack assets into the LUT folder and a font folder. Re-validates every asset first: the paths are never trusted.
pub struct SQPackInstaller;

impl SQPackInstaller {
    /// Installs `assets`; a file that exists with other content is not touched (the new one gets a number).
    pub fn install(
        assets: &[SQPackAsset],
        lut_directory: &Path,
        font_directory: &Path,
    ) -> Result<Installed, SQPackImportError> {
        for a in assets {
            SQPackFormat::validate_asset(a)?;
        }
        let io = |e: std::io::Error| SQPackImportError::Store(LibraryStoreError::Io(e.to_string()));
        let mut out = Installed::default();
        for a in assets {
            let Some(kind) = a.kind() else { continue };
            let dir = if kind == SQPackAssetKind::Lut { lut_directory } else { font_directory };
            std::fs::create_dir_all(dir).map_err(io)?;
            let file = a.path.rsplit('/').next().unwrap_or("");
            let (stem, ext) = file.rsplit_once('.').unwrap_or((file, ""));
            let (mut name, mut n) = (file.to_string(), 2);
            let mut dest = dir.join(&name);
            while dest.exists() {
                if std::fs::read(&dest).is_ok_and(|have| have == a.data) {
                    break; // already installed: reuse
                }
                name = format!("{stem} {n}.{ext}");
                n += 1;
                dest = dir.join(&name);
            }
            if !dest.exists() {
                crate::favorites::json_file_io::write_bytes_atomically(&a.data, &dest)?;
            }
            if kind == SQPackAssetKind::Lut {
                out.luts.push(dest);
            } else {
                out.fonts.push(dest);
            }
        }
        Ok(out)
    }
}

/// Finds the LUT files a preset payload refers to, so "Export as Pack" can bundle them.
pub struct SQPackAssetScanner;

impl SQPackAssetScanner {
    /// File names (last path component) of every JSON string in `payload` that ends in `.cube` or `.3dl` and is a valid
    /// pack asset name.
    pub fn lut_file_names(payload: &[u8]) -> Vec<String> {
        fn walk(v: &Value, found: &mut Vec<String>) {
            match v {
                Value::String(s) => {
                    let lower = s.to_lowercase();
                    if !(lower.ends_with(".cube") || lower.ends_with(".3dl")) {
                        return;
                    }
                    let name = s.rsplit('/').next().unwrap_or("");
                    if SQPackFormat::validate_path(&format!("luts/{name}")).is_ok() && !found.iter().any(|f| f == name)
                    {
                        found.push(name.to_string());
                    }
                }
                Value::Array(a) => a.iter().for_each(|x| walk(x, found)),
                Value::Object(o) => o.values().for_each(|x| walk(x, found)),
                _ => {}
            }
        }
        let Ok(root) = serde_json::from_slice::<Value>(payload) else { return Vec::new() };
        let mut found = Vec::new();
        walk(&root, &mut found);
        found.sort();
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use crate::sqpack::fixtures::*;
    use sq_core_effects::effect_preset::EffectPreset;
    use sq_core_time::SequentialIds;
    use std::sync::Arc;

    fn open(dir: &TempDir) -> PresetStore {
        PresetStore::open(dir.path(), false, NOW).unwrap_or_else(|e| panic!("{e}"))
    }

    fn entries(names: &[&str]) -> Option<Vec<SQPackEntry>> {
        Some(
            names
                .iter()
                .enumerate()
                .map(|(i, n)| SQPackEntry::from_item(&effect_item(n, i as u64 + 1), vec![]))
                .collect(),
        )
    }

    fn import(store: &mut PresetStore, p: &SQPack, c: SQPackConflict, ids: &mut SequentialIds) -> SQPackImportResult {
        store.import_pack(p, c, &SQPackKindRegistry::standard(), ids, NOW).unwrap_or_else(|e| panic!("{e:?}"))
    }

    #[test]
    fn export_bundles_chosen_presets() {
        let dir = TempDir::new();
        let mut store = open(&dir);
        let (a, b) = (effect_item("A", 1), effect_item("B", 2));
        assert!(store.add(a.clone()).is_ok() && store.add(b).is_ok());
        let manifest = SQPackManifest::new("Mine", NOW);
        let p = store.make_pack(&[a.id], &manifest, vec![], &HashMap::new()).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(p.entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["A"]);
        assert_eq!(p.manifest.kinds, ["effect"]);
        assert_eq!(store.make_pack(&[], &manifest, vec![], &HashMap::new()).err(), Some(SQPackError::EmptyPack));
    }

    #[test]
    fn import_lands_in_pack_folder_and_works_immediately() {
        let dir = TempDir::new();
        let mut store = open(&dir);
        let p = pack(entries(&["A", "B"]), vec![]);
        let r = import(&mut store, &p, SQPackConflict::Rename, &mut SequentialIds::default());
        assert_eq!((r.added.len(), r.replaced, r.deferred.len()), (2, 0, 0));
        assert!(
            store.all().len() == 2 && store.all().iter().all(|i| i.pack.as_deref() == Some("Pulse Presets Bundle 3.0"))
        );
        let item = &store.all()[0];
        assert!(EffectPreset::from_payload(&item.payload, item.payload_version, &mut SequentialIds::default()).is_ok());
        assert!(open(&dir).all().iter().all(|i| i.pack.as_deref() == Some("Pulse Presets Bundle 3.0")));
    }

    #[test]
    fn duplicate_conflict_rename_replace_skip() {
        let dir = TempDir::new();
        let mut store = open(&dir);
        let mut ids = SequentialIds::default();
        let p = pack(entries(&["A"]), vec![]);
        import(&mut store, &p, SQPackConflict::Rename, &mut ids);
        assert_eq!(store.conflicts(&p), ["A"]);
        let renamed = import(&mut store, &p, SQPackConflict::Rename, &mut ids);
        assert_eq!(renamed.added.iter().map(|i| i.name.as_str()).collect::<Vec<_>>(), ["A 2"]);
        let again = import(&mut store, &p, SQPackConflict::Rename, &mut ids);
        assert_eq!(again.added.iter().map(|i| i.name.as_str()).collect::<Vec<_>>(), ["A 3"]);
        let skipped = import(&mut store, &p, SQPackConflict::Skip, &mut ids);
        assert!(skipped.added.is_empty() && skipped.skipped == 1);
        let replaced = import(&mut store, &p, SQPackConflict::Replace, &mut ids);
        assert!(replaced.replaced == 1 && replaced.added.is_empty());
        assert_eq!(store.all().len(), 3);
    }

    #[test]
    fn non_store_kinds_are_handed_back_deferred() {
        let dir = TempDir::new();
        let mut store = open(&dir);
        let mut registry = SQPackKindRegistry::standard();
        registry.register("workspace", Arc::new(|_, _| Ok(())));
        let ws = SQPackEntry {
            kind: "workspace".into(),
            name: "Edit Wide".into(),
            payload_version: 1,
            payload: b"{}".to_vec(),
            assets: vec![],
        };
        let mut list = entries(&["Pop In"]).unwrap_or_default();
        list.push(ws);
        let p = pack(Some(list), vec![]);
        let r = store
            .import_pack(&p, SQPackConflict::Rename, &registry, &mut SequentialIds::default(), NOW)
            .unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(
            (r.added.len(), r.deferred.iter().map(|e| e.name.as_str()).collect::<Vec<_>>()),
            (1, vec!["Edit Wide"])
        );
    }

    #[test]
    fn assets_install_to_lut_and_font_directories() {
        let dir = TempDir::new();
        let assets = [
            SQPackAsset::new("luts/warm.cube", cube(2)),
            SQPackAsset { license: Some(ofl("c")), ..SQPackAsset::new("fonts/T.ttf", font()) },
        ];
        let (lut_dir, font_dir) = (dir.path().join("LUTs"), dir.path().join("Fonts"));
        let _ = std::fs::create_dir_all(&lut_dir);
        let _ = std::fs::write(lut_dir.join("warm.cube"), b"existing");
        let installed = SQPackInstaller::install(&assets, &lut_dir, &font_dir).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(installed.luts, [lut_dir.join("warm 2.cube")]); // existing file untouched
        assert_eq!(std::fs::read(lut_dir.join("warm.cube")).unwrap_or_default(), b"existing");
        assert_eq!(installed.fonts, [font_dir.join("T.ttf")]);
        // The same pack again reuses the files.
        let again = SQPackInstaller::install(&assets, &lut_dir, &font_dir).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(again, installed);
    }

    #[test]
    fn scanner_finds_lut_names_in_payloads() {
        let payload =
            br#"{"a":{"lut":"/Users/x/LUTs/Warm Tone.cube"},"b":["Cool.3dl","notes.txt"],"c":"bad|name.cube"}"#;
        assert_eq!(SQPackAssetScanner::lut_file_names(payload), ["Cool.3dl", "Warm Tone.cube"]);
        assert!(SQPackAssetScanner::lut_file_names(b"nope").is_empty());
    }

    #[test]
    fn store_file_without_pack_field_still_loads() {
        let dir = TempDir::new();
        let url = PresetStore::file_url_in(dir.path());
        let json = r#"{"formatVersion":1,"presets":[{"id":"00000000-0000-0000-0000-000000000001","kind":"effect","name":"Old","createdAt":"2026-01-01T00:00:00Z","payload":"e30=","payloadVersion":1}]}"#;
        let _ = std::fs::create_dir_all(url.parent().unwrap_or(Path::new(".")));
        let _ = std::fs::write(&url, json);
        assert_eq!(open(&dir).all().first().map(|i| i.pack.clone()), Some(None));
    }
}

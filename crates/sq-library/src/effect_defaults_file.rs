// Swift: EffectDefaultsFile.swift
//! FB-W: the user's effect and transition defaults, `<Application Support>/Sequence Studio/Library/defaults.json`
//! (next to `presets.json`). Small, so it is read and written whole and synchronously.

use crate::favorites::{LibraryStoreError, json_file_io};
use crate::preset_store::PresetStore;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sq_core_model::effect_defaults::{EffectDefaults, PayloadReadError};
use sq_core_time::{IdSource, Timestamp};
use std::path::{Path, PathBuf};

/// Reading and writing of `defaults.json`.
pub struct EffectDefaultsFile;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct File {
    format_version: i64,
    payload_version: i64,
    defaults: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Header {
    format_version: i64,
    #[serde(default)]
    payload_version: Option<i64>,
}

impl EffectDefaultsFile {
    /// Version of the file format.
    pub const FORMAT_VERSION: i64 = 1;

    /// Where `defaults.json` lives below an Application Support folder.
    pub fn file_url_in(application_support: &Path) -> PathBuf {
        PresetStore::file_url_in(application_support).with_file_name("defaults.json")
    }

    /// Where `defaults.json` lives below the app's own support folder (next to `presets.json`).
    pub fn file_url_in_support(support: &Path) -> PathBuf {
        PresetStore::file_url_in_support(support).with_file_name("defaults.json")
    }

    /// Empty when there is no file. A newer format or payload fails with `NewerFormat` (file untouched); a damaged file is
    /// moved aside (stamped `now`) and the defaults start empty. `ids` give the keys of upgraded effects their ids.
    pub fn load(path: &Path, now: Timestamp, ids: &mut dyn IdSource) -> Result<EffectDefaults, LibraryStoreError> {
        if !path.exists() {
            return Ok(EffectDefaults::default());
        }
        let data = std::fs::read(path)?;
        if let Ok(h) = serde_json::from_slice::<Header>(&data) {
            if h.format_version > Self::FORMAT_VERSION {
                return Err(LibraryStoreError::NewerFormat {
                    found: h.format_version,
                    supported: Self::FORMAT_VERSION,
                });
            }
            if let Some(p) = h.payload_version.filter(|p| *p > EffectDefaults::PAYLOAD_VERSION) {
                return Err(LibraryStoreError::NewerFormat { found: p, supported: EffectDefaults::PAYLOAD_VERSION });
            }
            // Through the payload reader, so its upgrades (old shadow colors, custom alignment) run.
            let read = serde_json::from_slice::<File>(&data).map_err(PayloadReadError::Json).and_then(|f| {
                let payload = serde_json::to_vec(&f.defaults).map_err(PayloadReadError::Json)?;
                EffectDefaults::from_payload(&payload, f.payload_version, ids)
            });
            if let Ok(defaults) = read {
                return Ok(defaults);
            }
        }
        json_file_io::backup_corrupt(path, now)?;
        Ok(EffectDefaults::default())
    }

    /// Writes the defaults.
    pub fn save(defaults: &EffectDefaults, path: &Path) -> Result<(), LibraryStoreError> {
        let defaults =
            sq_core_time::json_sorted::to_value(defaults).map_err(|e| LibraryStoreError::Io(e.to_string()))?;
        json_file_io::write_atomically(
            &File { format_version: Self::FORMAT_VERSION, payload_version: EffectDefaults::PAYLOAD_VERSION, defaults },
            path,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use sq_core_model::AnimatedProperty;
    use sq_core_model::ClipEffect;
    use sq_core_time::{Id, SequentialIds};

    const NOW: Timestamp = Timestamp::from_reference_seconds(800_000_000.0);

    fn sample() -> EffectDefaults {
        let mut e =
            ClipEffect::make(Id::from_u128(1), ClipEffect::GAUSSIAN_BLUR_KIND).unwrap_or_else(|| panic!("blur"));
        e.parameters.insert(ClipEffect::BLURRINESS_KEY.to_string(), AnimatedProperty::new(12.0));
        let mut d = EffectDefaults::default();
        d.effects.insert(e.kind.clone(), e);
        d
    }

    fn load(path: &Path) -> Result<EffectDefaults, LibraryStoreError> {
        EffectDefaultsFile::load(path, NOW, &mut SequentialIds::default())
    }

    #[test]
    fn lives_next_to_the_presets_in_the_user_library() {
        let dir = TempDir::new();
        let url = EffectDefaultsFile::file_url_in(dir.path());
        assert_eq!(url.parent(), PresetStore::file_url_in(dir.path()).parent());
        assert_eq!(url.file_name().and_then(|n| n.to_str()), Some("defaults.json"));
    }

    #[test]
    fn missing_file_is_empty_and_save_round_trips() {
        let dir = TempDir::new();
        let url = EffectDefaultsFile::file_url_in(dir.path());
        assert_eq!(load(&url).map(|d| d.is_empty()), Ok(true));
        let d = sample();
        assert!(EffectDefaultsFile::save(&d, &url).is_ok());
        assert_eq!(load(&url), Ok(d));
    }

    #[test]
    fn newer_format_fails_and_leaves_the_file() {
        let dir = TempDir::new();
        let url = EffectDefaultsFile::file_url_in(dir.path());
        let _ = std::fs::create_dir_all(url.parent().unwrap_or(Path::new(".")));
        let _ = std::fs::write(&url, br#"{"formatVersion": 99, "payloadVersion": 1, "defaults": {}}"#);
        assert_eq!(load(&url).err(), Some(LibraryStoreError::NewerFormat { found: 99, supported: 1 }));
        assert!(url.exists());
    }

    #[test]
    fn corrupt_file_is_moved_aside_and_starts_empty() {
        let dir = TempDir::new();
        let url = EffectDefaultsFile::file_url_in(dir.path());
        let _ = std::fs::create_dir_all(url.parent().unwrap_or(Path::new(".")));
        let _ = std::fs::write(&url, b"not json");
        assert_eq!(load(&url).map(|d| d.is_empty()), Ok(true));
        assert!(!url.exists());
    }
}

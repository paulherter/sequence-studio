// Swift: TitleTemplatePreset.swift
//! A saved title template in the Library: the template plus a small PNG thumbnail, stored as the payload of a
//! `TitleTemplate` preset.
//!
//! known limit: the SQCore `TitleTemplate` (layers, slots, animation zones) is not in `sq-core-model` yet, so the template is
//! kept as a JSON value here and checked only for what the Swift code checks (a `content.tracks` array that is not
//! empty, a `formatVersion` of at most 5). Upgrade to the typed `TitleTemplate` when it is ported.

use crate::favorites::LibraryStoreError;
use crate::preset_store::{PresetFileError, PresetItem, PresetKind};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sq_core_time::{Id, Timestamp};
use std::collections::BTreeSet;

/// Why a title template payload cannot be read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PayloadError {
    /// Written by a newer build (of the payload or of the template).
    NewerVersion {
        /// The version found.
        found: i64,
        /// The newest version this build reads.
        supported: i64,
    },
    /// Not a title template.
    Damaged,
}

impl From<PayloadError> for PresetFileError {
    fn from(e: PayloadError) -> Self {
        match e {
            PayloadError::NewerVersion { found, supported } => {
                LibraryStoreError::NewerFormat { found, supported }.into()
            }
            PayloadError::Damaged => PresetFileError::DamagedPayload,
        }
    }
}

/// Newest `TitleTemplate.formatVersion` this build reads.
const TEMPLATE_FORMAT_VERSION: i64 = 5;

/// A saved title template (TEMPLATE-ECOSYSTEM T3). Applying copies the template into the project, so nothing of the
/// library entry goes into a project file.
#[derive(Clone, Debug, PartialEq)]
pub struct TitleTemplatePreset {
    /// The template as JSON (see the module note).
    pub template: Value,
    /// PNG bytes of the Library thumbnail (`None`: the row shows an icon).
    pub thumbnail: Option<Vec<u8>>,
}

#[derive(Serialize, Deserialize)]
struct Payload {
    template: Value,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "sq_core_time::base64::option")]
    thumbnail: Option<Vec<u8>>,
}

impl TitleTemplatePreset {
    /// Version of the JSON payload (`PresetItem.payload_version` for `TitleTemplate` presets).
    pub const PAYLOAD_VERSION: i64 = 1;

    /// Reads a payload of `version`.
    pub fn from_payload(payload: &[u8], version: i64) -> Result<TitleTemplatePreset, PayloadError> {
        if version > Self::PAYLOAD_VERSION {
            return Err(PayloadError::NewerVersion { found: version, supported: Self::PAYLOAD_VERSION });
        }
        let p: Payload = serde_json::from_slice(payload).map_err(|_| PayloadError::Damaged)?;
        let found = p.template.get("formatVersion").and_then(Value::as_i64).unwrap_or(1);
        if found > TEMPLATE_FORMAT_VERSION {
            return Err(PayloadError::NewerVersion { found, supported: TEMPLATE_FORMAT_VERSION });
        }
        let has_tracks =
            p.template.pointer("/content/tracks").and_then(Value::as_array).is_some_and(|tracks| !tracks.is_empty());
        if !has_tracks {
            return Err(PayloadError::Damaged);
        }
        Ok(TitleTemplatePreset { template: p.template, thumbnail: p.thumbnail })
    }

    /// The JSON bytes, keys sorted.
    pub fn payload(&self) -> Result<Vec<u8>, serde_json::Error> {
        // A `Value` keeps its object keys sorted (`preserve_order` is on in the app build: use `sq_core_time::json_sorted`).
        let p = Payload { template: self.template.clone(), thumbnail: self.thumbnail.clone() };
        serde_json::to_vec(&sq_core_time::json_sorted::to_value(p)?)
    }

    /// The preset to store; `name` also becomes the template's own name.
    pub fn preset_item(&self, name: &str, id: Id, created_at: Timestamp) -> Result<PresetItem, serde_json::Error> {
        let mut copy = self.clone();
        if let Some(obj) = copy.template.as_object_mut() {
            obj.insert("name".to_string(), Value::String(name.to_string()));
        }
        Ok(PresetItem::new(id, PresetKind::TitleTemplate, name, created_at, copy.payload()?, Self::PAYLOAD_VERSION))
    }

    /// The names title templates already use in `items` (presets of other kinds may share a name with a template).
    pub fn names(items: &[PresetItem]) -> BTreeSet<String> {
        items.iter().filter(|i| i.kind == PresetKind::TitleTemplate).map(|i| i.name.clone()).collect()
    }

    /// Reads a `TitleTemplate` preset.
    pub fn from_preset(preset: &PresetItem) -> Result<TitleTemplatePreset, PayloadError> {
        if preset.kind != PresetKind::TitleTemplate {
            return Err(PayloadError::Damaged);
        }
        Self::from_payload(&preset.payload, preset.payload_version)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use crate::preset_store::PresetStore;
    use serde_json::json;

    const NOW: Timestamp = Timestamp::from_reference_seconds(800_000_000.0);

    fn template(name: &str) -> Value {
        json!({"name": name, "formatVersion": 5, "content": {"tracks": [{"kind": "video"}]},
               "slots": [{"name": "Text 1", "kind": "text", "path": "template.text"}]})
    }

    #[test]
    fn preset_round_trip_keeps_template_and_thumbnail() {
        let png = vec![0x89, 0x50, 0x4E, 0x47, 1, 2, 3];
        let item = TitleTemplatePreset { template: template("Intro"), thumbnail: Some(png.clone()) }
            .preset_item("My Intro", Id::fixed(1), NOW)
            .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(
            (item.kind, item.payload_version),
            (PresetKind::TitleTemplate, TitleTemplatePreset::PAYLOAD_VERSION)
        );
        let back = TitleTemplatePreset::from_preset(&item).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(back.template, template("My Intro"));
        assert_eq!(back.thumbnail, Some(png));
    }

    #[test]
    fn names_count_title_templates_only() {
        let t = TitleTemplatePreset { template: template("Intro"), thumbnail: None };
        let items = [
            t.preset_item("Lower Third", Id::fixed(1), NOW).unwrap_or_else(|e| panic!("{e}")),
            PresetItem::new(Id::fixed(2), PresetKind::Effect, "Glow", NOW, vec![], 1),
        ];
        assert_eq!(TitleTemplatePreset::names(&items), BTreeSet::from(["Lower Third".to_string()]));
    }

    #[test]
    fn store_reopen_and_sort_under_titles() {
        let dir = TempDir::new();
        let mut store = PresetStore::open(dir.path(), false, NOW).unwrap_or_else(|e| panic!("{e}"));
        let t = TitleTemplatePreset { template: template("Intro"), thumbnail: None };
        assert!(store.add(t.preset_item("Intro", Id::fixed(1), NOW).unwrap_or_else(|e| panic!("{e}"))).is_ok());
        let reopened = PresetStore::open(dir.path(), false, NOW).unwrap_or_else(|e| panic!("{e}"));
        let item = reopened.presets(Some(PresetKind::TitleTemplate), "").remove(0);
        assert_eq!(TitleTemplatePreset::from_preset(&item).map(|t| t.template["name"].clone()), Ok(json!("Intro")));
    }

    #[test]
    fn damaged_and_newer_payloads_are_refused() {
        assert_eq!(TitleTemplatePreset::from_payload(b"{}", 1), Err(PayloadError::Damaged));
        assert_eq!(
            TitleTemplatePreset::from_payload(b"{}", 9),
            Err(PayloadError::NewerVersion { found: 9, supported: 1 })
        );
        assert!(crate::preset_store::PresetFile::validate(PresetKind::TitleTemplate, b"[1]", 1).is_err());
        let newer = br#"{"template":{"formatVersion":6,"content":{"tracks":[1]}}}"#;
        assert_eq!(
            TitleTemplatePreset::from_payload(newer, 1),
            Err(PayloadError::NewerVersion { found: 6, supported: 5 })
        );
    }
}

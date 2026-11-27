// Swift: TitleTemplatePreset.swift
//! A saved title template in the Library: the template plus a small PNG thumbnail, stored as the payload of a
//! `TitleTemplate` preset. Payload version 2 holds the typed `TitleTemplate`; version 1 held the same JSON untyped and
//! still reads (the typed read checks it the way the old one did: a non-empty `content.tracks`, a `formatVersion` the
//! build knows).

use crate::favorites::LibraryStoreError;
use crate::preset_store::{PresetFileError, PresetItem, PresetKind};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sq_core_model::TitleTemplate;
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

/// A saved title template (TEMPLATE-ECOSYSTEM T3). Applying copies the template into the project, so nothing of the
/// library entry goes into a project file.
#[derive(Clone, Debug, PartialEq)]
pub struct TitleTemplatePreset {
    /// The template.
    pub template: TitleTemplate,
    /// PNG bytes of the Library thumbnail (`None`: the row shows an icon).
    pub thumbnail: Option<Vec<u8>>,
}

#[derive(Serialize)]
struct Payload<'a> {
    template: &'a TitleTemplate,
    #[serde(skip_serializing_if = "Option::is_none", with = "sq_core_time::base64::option")]
    thumbnail: &'a Option<Vec<u8>>,
}

#[derive(Deserialize)]
struct RawPayload {
    template: Value,
    #[serde(default, with = "sq_core_time::base64::option")]
    thumbnail: Option<Vec<u8>>,
}

impl TitleTemplatePreset {
    /// Version of the JSON payload (`PresetItem.payload_version` for `TitleTemplate` presets). 2: typed template.
    pub const PAYLOAD_VERSION: i64 = 2;

    /// Reads a payload of `version` (1 or 2).
    pub fn from_payload(payload: &[u8], version: i64) -> Result<TitleTemplatePreset, PayloadError> {
        if version > Self::PAYLOAD_VERSION {
            return Err(PayloadError::NewerVersion { found: version, supported: Self::PAYLOAD_VERSION });
        }
        let p: RawPayload = serde_json::from_slice(payload).map_err(|_| PayloadError::Damaged)?;
        let found = p.template.get("formatVersion").and_then(Value::as_i64).unwrap_or(1);
        if found > TitleTemplate::FORMAT_VERSION {
            return Err(PayloadError::NewerVersion { found, supported: TitleTemplate::FORMAT_VERSION });
        }
        let has_tracks =
            p.template.pointer("/content/tracks").and_then(Value::as_array).is_some_and(|tracks| !tracks.is_empty());
        if !has_tracks {
            return Err(PayloadError::Damaged);
        }
        let template: TitleTemplate = serde_json::from_value(p.template).map_err(|_| PayloadError::Damaged)?;
        Ok(TitleTemplatePreset { template, thumbnail: p.thumbnail })
    }

    /// The JSON bytes, keys sorted.
    pub fn payload(&self) -> Result<Vec<u8>, serde_json::Error> {
        // A `Value` keeps its object keys sorted (`preserve_order` is on in the app build: use `sq_core_time::json_sorted`).
        let p = Payload { template: &self.template, thumbnail: &self.thumbnail };
        serde_json::to_vec(&sq_core_time::json_sorted::to_value(p)?)
    }

    /// The preset to store; `name` also becomes the template's own name.
    pub fn preset_item(&self, name: &str, id: Id, created_at: Timestamp) -> Result<PresetItem, serde_json::Error> {
        let mut copy = self.clone();
        copy.template.name = name.to_string();
        Ok(PresetItem::new(id, PresetKind::TitleTemplate, name, created_at, copy.payload()?, Self::PAYLOAD_VERSION))
    }

    /// Like [`Self::preset_item`], filed in the Library folder `folder` (a "/" path, `None` = top level).
    pub fn preset_item_in(
        &self,
        name: &str,
        folder: Option<&str>,
        id: Id,
        created_at: Timestamp,
    ) -> Result<PresetItem, serde_json::Error> {
        let mut item = self.preset_item(name, id, created_at)?;
        item.folder = crate::preset_store::normalized_folder(folder);
        Ok(item)
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
    use crate::preset_store::{PresetFile, PresetStore};
    use serde_json::json;
    use sq_core_model::{
        SequenceFormat, SlotValue, TemplateFieldKind, TemplateSlot, TemplateSlotKind, Timeline, Track, TrackKind,
    };
    use sq_core_time::{SequentialIds, Time};

    const NOW: Timestamp = Timestamp::from_reference_seconds(800_000_000.0);

    fn slot(n: u64, kind: TemplateSlotKind, value: SlotValue) -> TemplateSlot {
        TemplateSlot {
            id: Id::fixed(n),
            name: format!("Slot {n}"),
            kind,
            layer: Id::fixed(99),
            graphics_layer: None,
            path: "template.text".into(),
            value,
        }
    }

    fn template_with(name: &str, slots: Vec<TemplateSlot>) -> TitleTemplate {
        let content = Timeline::new(
            Id::fixed(50),
            name,
            SequenceFormat::new(Time::new(1, 30)),
            vec![Track::new(Id::fixed(51), TrackKind::Video)],
        );
        TitleTemplate::new(Id::fixed(52), name, None, content, slots, None)
    }

    fn template(name: &str) -> TitleTemplate {
        template_with(name, vec![slot(1, TemplateSlotKind::Text, SlotValue::Text("Title".into()))])
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
        let mut expected = template("Intro");
        expected.name = "My Intro".to_string();
        assert_eq!(back.template, expected);
        assert_eq!(back.thumbnail, Some(png));
    }

    #[test]
    fn a_version_1_payload_still_reads() {
        // Written by the build before the typed payload: payload version 1, template as plain JSON.
        let t = template("Old");
        let v1 = serde_json::to_vec(&json!({"template": t})).unwrap_or_default();
        let back = TitleTemplatePreset::from_payload(&v1, 1).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(back.template, t);
        assert!(PresetFile::validate(PresetKind::TitleTemplate, &v1, 1).is_ok());
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
        assert_eq!(TitleTemplatePreset::from_preset(&item).map(|t| t.template.name), Ok("Intro".to_string()));
    }

    #[test]
    fn damaged_and_newer_payloads_are_refused() {
        assert_eq!(TitleTemplatePreset::from_payload(b"{}", 1), Err(PayloadError::Damaged));
        assert_eq!(
            TitleTemplatePreset::from_payload(b"{}", 9),
            Err(PayloadError::NewerVersion { found: 9, supported: 2 })
        );
        assert!(PresetFile::validate(PresetKind::TitleTemplate, b"[1]", 1).is_err());
        let newer = br#"{"template":{"formatVersion":7,"content":{"tracks":[1]}}}"#;
        assert_eq!(
            TitleTemplatePreset::from_payload(newer, 2),
            Err(PayloadError::NewerVersion { found: 7, supported: 6 })
        );
    }

    #[test]
    fn emoji_and_image_slots_write_format_6_which_a_reader_that_stops_at_5_refuses() {
        let plain = template("P");
        assert_eq!(plain.written_format_version(), 1);
        let emoji = template_with("E", vec![slot(1, TemplateSlotKind::Emoji, SlotValue::Text("\u{1F600}".into()))]);
        let image = template_with(
            "I",
            vec![slot(
                2,
                TemplateSlotKind::Image,
                SlotValue::Media { path: "/a/b.png".into(), bookmark: Some(vec![1, 2]) },
            )],
        );
        for t in [emoji, image] {
            assert_eq!(t.written_format_version(), 6);
            let item = TitleTemplatePreset { template: t.clone(), thumbnail: None }
                .preset_item("X", Id::fixed(1), NOW)
                .unwrap_or_else(|e| panic!("{e}"));
            let raw: Value = serde_json::from_slice(&item.payload).unwrap_or_default();
            // The rule an older build applies (`found > its newest`, newest = 5) rejects this payload.
            assert!(raw["template"]["formatVersion"].as_i64().unwrap_or(0) > 5);
            let back = TitleTemplatePreset::from_preset(&item).unwrap_or_else(|e| panic!("{e:?}"));
            assert_eq!(back.template.slots, t.slots);
        }
    }

    #[test]
    fn fields_list_the_slots_then_a_duration() {
        let t = template_with(
            "F",
            vec![
                slot(1, TemplateSlotKind::Text, SlotValue::Text("A".into())),
                slot(2, TemplateSlotKind::Emoji, SlotValue::Text("\u{1F600}".into())),
                slot(3, TemplateSlotKind::Number, SlotValue::Number(2.0)),
            ],
        );
        let f = t.fields();
        let kinds: Vec<_> = f.iter().map(|x| x.kind).collect();
        assert_eq!(
            kinds,
            [TemplateFieldKind::Text, TemplateFieldKind::Emoji, TemplateFieldKind::Number, TemplateFieldKind::Duration]
        );
        assert_eq!(f[0].value, json!("A"));
        assert_eq!(f[3].id, t.id);
        assert_eq!(f[3].value["intro"], json!(0.0));
    }

    #[test]
    fn folder_round_trips_through_store_sqpreset_and_old_files_have_none() {
        let dir = TempDir::new();
        let mut store = PresetStore::open(dir.path(), false, NOW).unwrap_or_else(|e| panic!("{e}"));
        let t = TitleTemplatePreset { template: template("Intro"), thumbnail: None };
        let item = t
            .preset_item_in("Intro", Some(" Lower Thirds / Social/ "), Id::fixed(1), NOW)
            .unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(item.folder.as_deref(), Some("Lower Thirds/Social"));
        assert!(store.add(item.clone()).is_ok());
        let plain = t.preset_item("Plain", Id::fixed(2), NOW).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(plain.folder, None);
        assert!(store.add(plain).is_ok());
        assert!(store.set_folder(Id::fixed(2), Some("A".into())).is_ok());
        let reopened = PresetStore::open(dir.path(), false, NOW).unwrap_or_else(|e| panic!("{e}"));
        let folders: Vec<_> =
            reopened.presets(Some(PresetKind::TitleTemplate), "").iter().map(|p| p.folder.clone()).collect();
        assert!(folders.contains(&Some("Lower Thirds/Social".to_string())) && folders.contains(&Some("A".to_string())));
        // .sqpreset carries it; a file without the key reads as top level.
        let file = PresetFile::encode(&item).unwrap_or_default();
        let back = PresetFile::decode(&file, &mut SequentialIds::default(), NOW).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(back.folder.as_deref(), Some("Lower Thirds/Social"));
        let mut raw: Value = serde_json::from_slice(&file).unwrap_or_default();
        if let Some(o) = raw.as_object_mut() {
            o.remove("folder");
        }
        let old = PresetFile::decode(&serde_json::to_vec(&raw).unwrap_or_default(), &mut SequentialIds::default(), NOW)
            .unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(old.folder, None);
        assert!(store.set_folder(Id::fixed(2), None).is_ok());
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ProjectFile.swift (`realMigrations`, `migrations`, `migrateVNtoVM`), ProjectFile+V19 ... V27

use crate::{ProjectFile, ProjectFileError};
use serde_json::{Map, Value, json};
use sq_core_color::ClipGradeExt;
use sq_core_model::ClipColor;
use std::collections::BTreeMap;

/// The top-level object of a project file.
pub type JsonObject = Map<String, Value>;

/// Upgrades the top-level object from version N to N+1.
pub type MigrationStep<'a> = Box<dyn Fn(JsonObject) -> Result<JsonObject, ProjectFileError> + 'a>;

/// Steps keyed by the version N they upgrade from.
pub type Migrations<'a> = BTreeMap<i64, MigrationStep<'a>>;

impl ProjectFile<'_> {
    /// The steps that change data. A version without an entry here is an identity step (see `migrations`): every format
    /// change since v2 other than these only added fields that are optional on decode.
    pub fn real_migrations(&self) -> Migrations<'_> {
        let mut t: Migrations<'_> = BTreeMap::new();
        t.insert(1, Box::new(migrate_v1_to_v2));
        t.insert(9, Box::new(move |o| Ok(self.migrate_v9_to_v10(o))));
        t.insert(23, Box::new(move |o| Ok(self.migrate_v23_to_v24(o))));
        t.insert(25, Box::new(move |o| Ok(self.migrate_v25_to_v26(o))));
        t.insert(26, Box::new(move |o| Ok(self.migrate_v26_to_v27(o))));
        t.insert(33, Box::new(|o| Ok(migrate_v33_to_v34(o))));
        t
    }

    /// The full chain 1..<current version. Missing steps are identity.
    pub fn migrations(&self) -> Migrations<'_> {
        let mut t = self.real_migrations();
        for v in 1..crate::CURRENT_VERSION {
            t.entry(v).or_insert_with(|| Box::new(Ok));
        }
        t
    }

    /// v10: Scale is relative to the picture's own pixels instead of the aspect-fitted picture. A project that does not
    /// decode is passed on unchanged (the final decode then reports it).
    fn migrate_v9_to_v10(&self, obj: JsonObject) -> JsonObject {
        self.reencode(obj, |p, f| {
            f.migrate_scale_to_source_pixels(p);
            true
        })
    }

    /// v24: Drop Shadow's three 0...255 channels become one color parameter.
    fn migrate_v23_to_v24(&self, obj: JsonObject) -> JsonObject {
        self.reencode(obj, |p, f| f.migrate_legacy_shadow_color(p))
    }

    /// v26: drops overrides whose variant or effect does not exist.
    fn migrate_v25_to_v26(&self, obj: JsonObject) -> JsonObject {
        self.reencode(obj, |p, f| f.prune_variant_overrides(p))
    }

    /// v27: the Color effects a clip kept inside `color` become `ClipEffect`s of kind `color`. The clip decoder does that, so
    /// this step only re-encodes.
    fn migrate_v26_to_v27(&self, obj: JsonObject) -> JsonObject {
        self.reencode(obj, |p, _| {
            for timeline in p.timelines.iter_mut() {
                for track in timeline.tracks.iter_mut() {
                    track.map_clips_keeping_timing(|c| {
                        let mut c = c.clone();
                        if let Some(effects) = c.footage_color.legacy_effects.take() {
                            let f = &c.footage_color;
                            let mut old = ClipColor::new(f.source, f.use_embedded_lut, effects);
                            (old.log_mode, old.target_space, old.hdr_conform) =
                                (f.log_mode, f.target_space, f.hdr_conform);
                            c.adopt_legacy_grade(&old, &mut ClipIds { clip: c.id, n: 0 });
                        }
                        c
                    });
                }
            }
            true
        })
    }

    /// Decodes the project, lets `change` edit it, and writes it back when `change` says it changed anything. Anything that
    /// does not decode or encode leaves the object as it was.
    fn reencode(
        &self,
        mut obj: JsonObject,
        change: impl FnOnce(&mut sq_core_model::Project, &dyn crate::ProjectFixups) -> bool,
    ) -> JsonObject {
        let Some(mut project) = obj.get("project").and_then(|v| self.decode_project(v)) else { return obj };
        if !change(&mut project, self.fixups) {
            return obj;
        }
        match self.project_value(&project) {
            Some(migrated) => {
                obj.insert("project".to_string(), migrated);
                obj
            }
            None => obj,
        }
    }
}

/// v2: `Timeline.frameDuration` moved into `Timeline.format` (defaults 1920x1080, 48 kHz). Track flags, `inOut` and
/// `markers` are optional on decode, so nothing else changes.
pub fn migrate_v1_to_v2(mut obj: JsonObject) -> Result<JsonObject, ProjectFileError> {
    let Some(Value::Object(project)) = obj.get_mut("project") else { return Err(ProjectFileError::Corrupt) };
    if let Some(slot) = project.get_mut("timelines") {
        let items = match slot.take() {
            Value::Array(items) => items,
            _ => Vec::new(),
        };
        let items = items
            .into_iter()
            .map(|item| match item {
                Value::Object(mut t) => {
                    if let Some(fd) = t.remove("frameDuration") {
                        t.insert(
                            "format".to_string(),
                            json!({"width": 1920, "height": 1080, "frameDuration": fd, "audioSampleRate": 48_000}),
                        );
                    }
                    Value::Object(t)
                }
                other => other,
            })
            .collect();
        *slot = Value::Array(items);
    }
    Ok(obj)
}

/// v34: forget a stored Rec.709 detection of video media (not stills) so detection reruns on open: v33 builds stored
/// "rec709" for PQ (HDR10) files and for every untagged file alike.
pub fn migrate_v33_to_v34(mut obj: JsonObject) -> JsonObject {
    let Some(Value::Object(project)) = obj.get_mut("project") else { return obj };
    let Some(Value::Array(media)) = project.get_mut("media") else { return obj };
    for item in media {
        let Some(Value::Object(info)) = item.get_mut("info") else { continue };
        if info.contains_key("video")
            && info.get("isStill").and_then(Value::as_bool) != Some(true)
            && info.get("detectedColorSpace").and_then(Value::as_str) == Some("rec709")
        {
            info.remove("detectedColorSpace");
        }
    }
    obj
}

/// Ids for the effects a clip gains in a migration: derived from the clip id, so reading a file twice gives the same
/// result (Swift draws random UUIDs; ids only have to differ inside one clip).
struct ClipIds {
    clip: sq_core_time::Id,
    n: u128,
}

impl sq_core_time::IdSource for ClipIds {
    fn next_id(&mut self) -> sq_core_time::Id {
        self.n += 1;
        sq_core_time::Id::from_u128(self.clip.as_u128() ^ self.n)
    }
}

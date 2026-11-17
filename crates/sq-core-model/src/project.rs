// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Project.swift (types; logic: task M-4)

use crate::CowVec;
use crate::media_info::lenient;
use crate::{
    Bin, BinItem, ColorSpaceID, ImportMode, LabelColor, Marker, MediaInfo, MediaPolicy, ProjectLiveDucking, SmartBin,
    SourceMarks, StyleKit, Subclip, Timeline,
};
use crate::{FileExtras, UnknownKeys};
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, Time, Timestamp};
use std::collections::BTreeMap;

/// What identifies a media file on disk besides its path.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaFingerprint {
    /// File size in bytes.
    pub size: i64,
    /// Modification date (ISO 8601 in project files).
    #[serde(default, skip_serializing_if = "Option::is_none", with = "sq_core_time::timestamp::iso8601::option")]
    pub modified: Option<Timestamp>,
    /// Hash of the first bytes, when computed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_hash: Option<String>,
}

/// Result of checking a media file against its fingerprint.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaStatus {
    /// Present and unchanged.
    Ok,
    /// Not found.
    Missing,
    /// Size or date differ.
    Changed,
}

/// One imported media file.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaRef {
    /// Identity; clips refer to it.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// File path (`/` separators).
    pub path: String,
    /// macOS security-scoped bookmark (base64 in JSON).
    #[serde(default, skip_serializing_if = "Option::is_none", with = "sq_core_time::base64::option")]
    pub bookmark: Option<Vec<u8>>,
    /// Size and date when imported.
    pub fingerprint: MediaFingerprint,
    /// Length, when probed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<Time>,
    /// Probe results.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub info: Option<MediaInfo>,
    /// Label color.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<LabelColor>,
    /// Poster frame for thumbnails.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster_time: Option<Time>,
    /// Markers on the source.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_markers: Option<Vec<Marker>>,
    /// Set when this item is a subclip of another.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subclip: Option<Subclip>,
    /// Keys of a newer file that this build does not know; kept and written back.
    #[serde(flatten, default, skip_serializing_if = "UnknownKeys::is_empty")]
    pub unknown: UnknownKeys,
}

/// A whole project: media, sequences, bins.
///
/// Reading is forgiving: `importMode`, `mediaPolicy`, `styleKit`, `inputColorSpace`, `liveDucking`, `builtInStyles`,
/// `notes` and `smartBins` drop a malformed value, `sourceMarks` and `activeVariants` skip bad entries, `rootBin`
/// defaults to a bin named "Root" with the project id, and empty notes, smart bins and source marks read as absent.
/// Swift then normalizes the bins (`normalizeBins`); that step waits for the bin logic and is not part of reading yet.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "ProjectWire")]
pub struct Project {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Imported media.
    pub media: CowVec<MediaRef>,
    /// Sequences.
    pub timelines: CowVec<Timeline>,
    /// The sequence shown in the timeline panel.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_timeline: Option<Id>,
    /// Bin tree.
    pub root_bin: Bin,
    /// In/out marks per media id; written as an object keyed by the id text.
    pub source_marks: BTreeMap<Id, SourceMarks>,
    /// Copy, move or leave media on import.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub import_mode: Option<ImportMode>,
    /// Project media policy.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_policy: Option<MediaPolicy>,
    /// Active format variant per timeline id; written only when not empty.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub active_variants: BTreeMap<Id, Id>,
    /// Shared text and color styles.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub style_kit: Option<StyleKit>,
    /// Working color space of new media.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_color_space: Option<ColorSpaceID>,
    /// Project-wide live ducking.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub live_ducking: Option<ProjectLiveDucking>,
    /// Version of the built-in styles the project has seen.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub built_in_styles: Option<i64>,
    /// Project notes; `None` when empty.
    #[doc(hidden)]
    #[serde(rename = "notes", skip_serializing_if = "Option::is_none")]
    pub notes_store: Option<String>,
    /// Saved searches; `None` when empty.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub smart_bins: Option<Vec<SmartBin>>,
    /// Keys of a newer file that this build does not know; kept and written back.
    #[serde(flatten, default, skip_serializing_if = "UnknownKeys::is_empty")]
    pub unknown: UnknownKeys,
    /// Keys of a newer file next to `project` (the file's top level); kept and written back by the file layer.
    #[serde(skip)]
    pub file_unknown: UnknownKeys,
    /// Everything else the file had at any level that this build has no field for (see `FileExtras`).
    #[serde(skip)]
    pub file_extras: FileExtras,
}

/// `Project` as stored.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProjectWire {
    id: Id,
    name: String,
    media: CowVec<MediaRef>,
    timelines: CowVec<Timeline>,
    #[serde(default)]
    active_timeline: Option<Id>,
    #[serde(default)]
    root_bin: Option<Bin>,
    #[serde(default)]
    source_marks: BTreeMap<String, SourceMarks>,
    #[serde(default, deserialize_with = "lenient")]
    import_mode: Option<ImportMode>,
    #[serde(default, deserialize_with = "lenient")]
    media_policy: Option<MediaPolicy>,
    #[serde(default, deserialize_with = "lenient")]
    style_kit: Option<StyleKit>,
    #[serde(default, deserialize_with = "lenient")]
    input_color_space: Option<ColorSpaceID>,
    #[serde(default, deserialize_with = "lenient")]
    live_ducking: Option<ProjectLiveDucking>,
    #[serde(default, deserialize_with = "lenient")]
    built_in_styles: Option<i64>,
    #[serde(rename = "notes", default, deserialize_with = "lenient")]
    notes_store: Option<String>,
    #[serde(default, deserialize_with = "lenient")]
    smart_bins: Option<Vec<SmartBin>>,
    #[serde(default, deserialize_with = "lenient")]
    active_variants: Option<BTreeMap<String, String>>,
    #[serde(flatten)]
    unknown: UnknownKeys,
}

impl From<ProjectWire> for Project {
    fn from(w: ProjectWire) -> Self {
        let source_marks = w
            .source_marks
            .into_iter()
            .filter_map(|(k, v)| Id::parse(&k).filter(|_| !v.is_empty()).map(|id| (id, v)))
            .collect();
        // A variant must exist on its timeline.
        let has_variant =
            |t: Id, v: Id| w.timelines.iter().any(|tl| tl.id == t && tl.variants.iter().any(|x| x.id == v));
        let active_variants = w
            .active_variants
            .into_iter()
            .flatten()
            .filter_map(|(k, v)| Some((Id::parse(&k)?, Id::parse(&v)?)))
            .filter(|(t, v)| has_variant(*t, *v))
            .collect();
        let mut project = Project {
            id: w.id,
            name: w.name,
            media: w.media,
            active_timeline: w.active_timeline,
            root_bin: w.root_bin.unwrap_or_else(|| Bin::new(w.id, "Root", Vec::new())),
            source_marks,
            import_mode: w.import_mode,
            media_policy: w.media_policy,
            active_variants,
            style_kit: w.style_kit,
            input_color_space: w.input_color_space,
            live_ducking: w.live_ducking,
            built_in_styles: w.built_in_styles,
            notes_store: w.notes_store.filter(|n| !n.is_empty()),
            smart_bins: w.smart_bins.filter(|b| !b.is_empty()),
            timelines: w.timelines,
            unknown: w.unknown,
            file_unknown: UnknownKeys::default(),
            file_extras: FileExtras::default(),
        };
        project.normalize_bins();
        project
    }
}

impl MediaFingerprint {
    /// A fingerprint of a file of `size` bytes with no date and no head hash.
    pub fn new(size: i64) -> MediaFingerprint {
        MediaFingerprint { size, modified: None, head_hash: None }
    }
}

impl MediaRef {
    /// A media item with no probe info, label, markers or subclip.
    pub fn new(id: Id, name: &str, path: &str, fingerprint: MediaFingerprint) -> MediaRef {
        MediaRef {
            id,
            name: name.to_string(),
            path: path.to_string(),
            bookmark: None,
            fingerprint,
            duration: None,
            info: None,
            label: None,
            poster_time: None,
            source_markers: None,
            subclip: None,
            unknown: UnknownKeys::default(),
        }
    }

    /// `Missing` if nothing is at `path`, `Changed` if size or modification date differ, else `Ok`.
    pub fn status(&self) -> MediaStatus {
        let Ok(meta) = std::fs::metadata(&self.path) else { return MediaStatus::Missing };
        if i64::try_from(meta.len()).unwrap_or(-1) != self.fingerprint.size {
            return MediaStatus::Changed;
        }
        let actual = meta.modified().ok().map(|m| match m.duration_since(std::time::UNIX_EPOCH) {
            Ok(d) => d.as_secs_f64(),
            Err(e) => -e.duration().as_secs_f64(),
        });
        match (self.fingerprint.modified, actual) {
            (Some(expected), Some(actual)) if (actual - expected.unix_seconds()).abs() > 1.0 => MediaStatus::Changed,
            _ => MediaStatus::Ok,
        }
    }
}

/// Trims what Foundation's `.whitespaces` (spaces and tab) or, with `newlines`, `.whitespacesAndNewlines` trims.
pub fn trim_spaces(s: &str, newlines: bool) -> &str {
    s.trim_matches(|c: char| match c as u32 {
        0x09 | 0x20 | 0xA0 | 0x1680 | 0x2000..=0x200A | 0x202F | 0x205F | 0x3000 => true,
        0x0A..=0x0D | 0x85 | 0x2028 | 0x2029 => newlines,
        _ => false,
    })
}

impl Project {
    /// `builtInStyles` a new project starts with.
    pub const CURRENT_BUILT_IN_STYLES: i64 = 1;

    /// A project over `media` and `timelines`; the first timeline is active and everything is filed in the root bin.
    pub fn new(id: Id, name: &str, media: Vec<MediaRef>, timelines: Vec<Timeline>) -> Project {
        let mut project = Project {
            id,
            name: name.to_string(),
            media: media.into(),
            active_timeline: timelines.first().map(|t| t.id),
            timelines: timelines.into(),
            root_bin: Bin::new(id, "Root", Vec::new()),
            source_marks: BTreeMap::new(),
            import_mode: None,
            media_policy: None,
            active_variants: BTreeMap::new(),
            style_kit: None,
            input_color_space: None,
            live_ducking: None,
            built_in_styles: Some(Project::CURRENT_BUILT_IN_STYLES),
            notes_store: None,
            smart_bins: None,
            unknown: UnknownKeys::default(),
            file_unknown: UnknownKeys::default(),
            file_extras: FileExtras::default(),
        };
        project.normalize_bins();
        project
    }

    /// The media item with `id`.
    pub fn media(&self, id: Id) -> Option<&MediaRef> {
        self.media.iter().find(|m| m.id == id)
    }

    /// Adds `item`, or replaces the entry with the same ID. New media is filed in the root bin.
    pub fn add(&mut self, item: MediaRef) {
        if let Some(i) = self.media.iter().position(|m| m.id == item.id) {
            self.media[i] = item;
        } else {
            self.root_bin.children.push(BinItem::Media(item.id));
            self.media.push(item);
        }
    }

    /// The project's free-text notes (empty when none).
    pub fn notes(&self) -> &str {
        self.notes_store.as_deref().unwrap_or("")
    }

    /// Sets the notes; empty text is stored as absent.
    pub fn set_notes(&mut self, notes: &str) {
        self.notes_store = (!notes.is_empty()).then(|| notes.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const P: &str = "00000000-0000-0000-0000-0000000000a1";
    const T: &str = "00000000-0000-0000-0000-0000000000b1";
    const V: &str = "00000000-0000-0000-0000-0000000000c1";
    const M: &str = "00000000-0000-0000-0000-0000000000d1";

    fn timeline(variants: serde_json::Value) -> serde_json::Value {
        json!({"id": T, "name": "S", "variants": variants,
               "format": {"width": 1920, "height": 1080, "frameDuration": {"value": 1, "timescale": 30},
                          "audioSampleRate": 48000}})
    }

    fn project(extra: serde_json::Value) -> Project {
        let mut p = json!({"id": P, "name": "P", "media": [], "timelines": [timeline(json!([]))]});
        for (k, v) in extra.as_object().into_iter().flatten() {
            p[k] = v.clone();
        }
        serde_json::from_value(p).unwrap()
    }

    #[test]
    fn root_bin_defaults_to_root_with_the_project_id() {
        let p = project(json!({}));
        assert_eq!(
            (p.root_bin.id, p.root_bin.name.as_str(), p.root_bin.children.len()),
            (Id::parse(P).unwrap(), "Root", 1),
            "reading files the unfiled sequence"
        );
        assert!(p.source_marks.is_empty() && p.active_variants.is_empty());
    }

    #[test]
    fn broken_lenient_keys_read_as_absent() {
        let p = project(json!({"importMode": "teleport", "mediaPolicy": 1, "styleKit": "kit", "inputColorSpace": "x",
            "liveDucking": {"isOn": 1}, "builtInStyles": "new", "notes": 5, "smartBins": {}, "activeVariants": 3}));
        assert_eq!((p.import_mode, p.media_policy, p.style_kit, p.input_color_space), (None, None, None, None));
        assert_eq!((p.live_ducking, p.built_in_styles, p.notes_store, p.smart_bins), (None, None, None, None));
        assert!(p.active_variants.is_empty());
    }

    #[test]
    fn empty_notes_and_smart_bins_read_as_absent() {
        let p = project(json!({"notes": "", "smartBins": []}));
        assert_eq!((p.notes_store, p.smart_bins), (None, None));
        let q = project(json!({"notes": "hi", "builtInStyles": 1, "importMode": "copy"}));
        assert_eq!(
            (q.notes_store.as_deref(), q.built_in_styles, q.import_mode),
            (Some("hi"), Some(1), Some(ImportMode::Copy))
        );
    }

    #[test]
    fn source_marks_skip_bad_keys_and_empty_marks() {
        let p = project(
            json!({"sourceMarks": {M: {"markIn": {"value": 1, "timescale": 1}}, "not-a-uuid": {"markIn": {"value": 1, "timescale": 1}},
                                              "00000000-0000-0000-0000-0000000000d2": {}}}),
        );
        assert_eq!(p.source_marks.keys().copied().collect::<Vec<_>>(), vec![Id::parse(M).unwrap()]);
        let back = serde_json::to_value(&p).unwrap();
        assert_eq!(back["sourceMarks"], json!({M.to_uppercase(): {"markIn": {"value": 1, "timescale": 1}}}));
    }

    #[test]
    fn active_variants_keep_only_existing_variants() {
        let variant = json!({"id": V, "name": "Sq", "width": 1080, "height": 1080});
        let mk = |variants: serde_json::Value, active: serde_json::Value| {
            let p =
                json!({"id": P, "name": "P", "media": [], "timelines": [timeline(variants)], "activeVariants": active});
            serde_json::from_value::<Project>(p).unwrap().active_variants
        };
        assert_eq!(mk(json!([variant]), json!({T: V})).len(), 1);
        assert!(mk(json!([]), json!({T: V})).is_empty());
        assert!(mk(json!([variant]), json!({"nope": V})).is_empty());
        let other = "00000000-0000-0000-0000-0000000000ff";
        assert!(mk(json!([variant]), json!({other: V})).is_empty());
    }

    #[test]
    fn active_variants_are_written_only_when_not_empty() {
        let p = project(json!({}));
        let v = serde_json::to_value(&p).unwrap();
        assert!(v.get("activeVariants").is_none());
        assert!(v.get("sourceMarks").is_some() && v.get("rootBin").is_some());
    }

    #[test]
    fn project_file_fixture_decodes() {
        let file: serde_json::Value =
            serde_json::from_str(include_str!("../../../Packages/SQCore/Tests/Fixtures/project-v71.json")).unwrap();
        let p: Project = serde_json::from_value(file["project"].clone()).unwrap();
        assert_eq!((p.name.as_str(), p.timelines.len(), p.built_in_styles), ("P", 1, Some(1)));
        let t = &p.timelines[0];
        assert_eq!((t.name.as_str(), t.tracks.len(), t.caption_tracks.len()), ("S", 1, 1));
        assert_eq!(t.caption_tracks[0].items().len(), 2);
        assert_eq!(p.root_bin.children, vec![BinItem::Sequence(t.id)]);
        assert_eq!(p.style_kit.as_ref().map(|k| k.looks.len()), Some(2));
        assert_eq!(p.active_timeline, Some(t.id));
    }

    #[test]
    fn media_status_compares_size_and_date() {
        let dir = std::env::temp_dir().join(format!("sq-core-model-status-{}", std::process::id()));
        let file = dir.join("a.bin");
        assert!(std::fs::create_dir_all(&dir).is_ok() && std::fs::write(&file, b"12345").is_ok());
        let path = file.to_string_lossy().into_owned();
        let status = |size: i64, modified: Option<f64>| {
            let mut m = MediaRef::new(Id::NIL, "a", &path, MediaFingerprint::new(size));
            m.fingerprint.modified = modified.map(Timestamp::from_unix_seconds);
            m.status()
        };
        let now = std::fs::metadata(&file)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok());
        let secs = now.map_or(0.0, |d| d.as_secs_f64());
        assert_eq!(status(5, None), MediaStatus::Ok);
        assert_eq!(status(5, Some(secs + 0.5)), MediaStatus::Ok, "within a second");
        assert_eq!(status(5, Some(secs + 5.0)), MediaStatus::Changed);
        assert_eq!(status(6, None), MediaStatus::Changed);
        let gone = MediaRef::new(Id::NIL, "a", "/definitely/not/here.mov", MediaFingerprint::new(5));
        assert_eq!(gone.status(), MediaStatus::Missing);
        assert!(std::fs::remove_dir_all(&dir).is_ok());
    }

    #[test]
    fn add_replaces_by_id_and_files_new_media_in_the_root_bin() {
        let mut p = Project::new(Id::NIL, "P", vec![], vec![]);
        let a = MediaRef::new(Id::fixed(1), "a", "/a", MediaFingerprint::new(1));
        p.add(a.clone());
        p.add(MediaRef { name: "renamed".into(), ..a });
        assert_eq!((p.media.len(), p.root_bin.children.len()), (1, 1));
        assert_eq!(p.media(Id::fixed(1)).map(|m| m.name.as_str()), Some("renamed"));
        assert_eq!(p.notes(), "");
        p.set_notes("x");
        assert_eq!(p.notes_store.as_deref(), Some("x"));
        p.set_notes("");
        assert_eq!(p.notes_store, None);
    }

    #[test]
    fn trim_spaces_keeps_newlines_unless_asked() {
        assert_eq!(trim_spaces(" \t a \n", false), "a \n");
        assert_eq!(trim_spaces(" \t a \n", true), "a");
    }
}

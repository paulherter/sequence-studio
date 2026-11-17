// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: Mogrt.swift. Motion Graphics Templates (.mogrt), docs/ENGINE-NOTES.md "Motion Graphics Templates (.mogrt)". The
//! package is a ZIP: definition.json (name, authoring app, exposed controls, frame size, duration, fonts), thumb.png, and
//! the graphic itself: project.prgraphic (authored in Premiere: a ZIP around one ordinary gzip project with one sequence) or
//! project.aegraphic (authored in After Effects: a ZIP around an .aep composition, which only After Effects can render).
//! A Premiere-authored template therefore runs through the same reader and mapper as a project import.
//!
//! `MogrtImporter::open` reads the package; `MogrtImporter::read` then maps the sequence and captures it as a `TitleTemplate`.

use crate::prdocument::{PRDocument, PRParamValue, PRReader};
use crate::primport_report::{PRImportReport, Status};
use crate::prmapper::PRMapper;
use crate::prmapper::shapes::SHAPE_MATCH_NAME;
use crate::prmapper::text::text_layer;
use crate::prtext_blob::Rgb;
use serde_json::{Map, Value};
use sq_core_edit::title_template::TitleTemplateExt;
use sq_core_model::{SlotValue, TitleTemplate, TrackKind};
use sq_core_time::{Id, IdSource};
use sq_core_time::{Time, Vec2};
use sq_prproj_reader::zip::Zip;
use std::collections::BTreeMap;
use std::fmt;

/// Why a template was not imported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MogrtImportError {
    /// Not a ZIP, or no definition inside.
    NotATemplate,
    /// Authored in After Effects: the layers live in an .aep composition this app cannot render.
    NeedsAfterEffects { name: String },
    /// The definition is there, the graphic is not.
    MissingGraphic { name: String },
    /// The package or the project inside is damaged.
    Unreadable { name: String },
    /// Nothing of the template has a counterpart (no text layer); `dropped` counts what was left out.
    NothingImportable { name: String, dropped: i64 },
}

impl fmt::Display for MogrtImportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MogrtImportError::NotATemplate => write!(f, "This file is not a Motion Graphics Template (.mogrt)."),
            MogrtImportError::NeedsAfterEffects { name } => write!(
                f,
                "\u{201C}{name}\u{201D} was made in After Effects. It needs After Effects to render and cannot be imported yet. Templates made with a video editor's own text and shape tools can be imported."
            ),
            MogrtImportError::MissingGraphic { name } => {
                write!(f, "\u{201C}{name}\u{201D} contains no graphic to import.")
            }
            MogrtImportError::Unreadable { name } => {
                write!(f, "\u{201C}{name}\u{201D} is damaged and could not be read.")
            }
            MogrtImportError::NothingImportable { name, dropped } => {
                write!(f, "\u{201C}{name}\u{201D} has no text layer that can be imported")?;
                if *dropped > 0 {
                    write!(f, " ({dropped} unsupported {} left out).", if *dropped == 1 { "item" } else { "items" })
                } else {
                    write!(f, ".")
                }
            }
        }
    }
}

impl std::error::Error for MogrtImportError {}

/// Type of an exposed control. Codes seen in real definitions: 1 checkbox, 2 slider, 3 angle, 4 color, 5 point, 6 text, 9
/// vector (scale), 13 menu. Anything else keeps its code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MogrtControlKind {
    Checkbox,
    Slider,
    Angle,
    Color,
    Point,
    Text,
    Vector,
    Menu,
    Other(i64),
}

impl MogrtControlKind {
    fn from_code(code: i64) -> MogrtControlKind {
        match code {
            1 => MogrtControlKind::Checkbox,
            2 => MogrtControlKind::Slider,
            3 => MogrtControlKind::Angle,
            4 => MogrtControlKind::Color,
            5 => MogrtControlKind::Point,
            6 => MogrtControlKind::Text,
            9 => MogrtControlKind::Vector,
            13 => MogrtControlKind::Menu,
            c => MogrtControlKind::Other(c),
        }
    }

    /// Plain name of the control type.
    pub fn label(self) -> String {
        match self {
            MogrtControlKind::Checkbox => "checkbox".into(),
            MogrtControlKind::Slider => "slider".into(),
            MogrtControlKind::Angle => "angle".into(),
            MogrtControlKind::Color => "color".into(),
            MogrtControlKind::Point => "point".into(),
            MogrtControlKind::Text => "text".into(),
            MogrtControlKind::Vector => "scale".into(),
            MogrtControlKind::Menu => "menu".into(),
            MogrtControlKind::Other(code) => format!("type {code}"),
        }
    }
}

/// The default value of a control.
#[derive(Debug, Clone, PartialEq)]
pub enum MogrtControlValue {
    Text(String),
    Bool(bool),
    Number(f64),
    Color { red: f64, green: f64, blue: f64, alpha: f64 },
    Point { x: f64, y: f64 },
    Vector(Vec<f64>),
    Menu { index: i64, items: Vec<String> },
    None,
}

/// One control the template exposes for editing (`clientControls` of the definition).
#[derive(Debug, Clone, PartialEq)]
pub struct MogrtControl {
    pub id: String,
    pub name: String,
    pub kind: MogrtControlKind,
    pub value: MogrtControlValue,
    /// Text controls: the font and size the definition records (empty / 0 in Premiere-authored templates).
    pub font_name: Option<String>,
    pub font_size: Option<f64>,
}

/// The program that authored the template.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MogrtAuthor {
    Premiere,
    AfterEffects,
    Unknown(String),
}

/// What definition.json says about the template.
#[derive(Debug, Clone, PartialEq)]
pub struct MogrtDefinition {
    pub name: String,
    pub author: MogrtAuthor,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub duration: Option<Time>,
    /// PostScript names of the fonts the template uses.
    pub fonts: Vec<String>,
    pub controls: Vec<MogrtControl>,
}

type Json = Map<String, Value>;

/// Frame sides above this are not a frame size.
const MAX_FRAME_SIDE: i64 = 65_536;

/// The en_US entry of a per-locale dictionary, else its first by key.
fn localized(any: Option<&Value>) -> Option<&Value> {
    let d = any?.as_object()?;
    d.get("en_US").or_else(|| d.keys().min().and_then(|k| d.get(k)))
}

/// A localized string table (`{"strDB":[{"localeString":"en_US","str":"..."}]}`): en_US, else the first entry.
fn string(any: Option<&Value>) -> Option<String> {
    let db = any?.as_object()?.get("strDB")?.as_array()?;
    let entries: Vec<&Json> = db.iter().map(Value::as_object).collect::<Option<_>>()?;
    let first = entries.first()?;
    let pick = entries.iter().find(|e| e.get("localeString").and_then(Value::as_str) == Some("en_US")).unwrap_or(first);
    pick.get("str").and_then(Value::as_str).map(str::to_string)
}

fn number(any: Option<&Value>) -> Option<f64> {
    let d = match any? {
        Value::Number(n) => n.as_f64()?,
        Value::Bool(b) => f64::from(u8::from(*b)),
        _ => return None,
    };
    d.is_finite().then_some(d)
}

/// A whole-number reading inside `lo..=hi`; anything else (1e300, a fraction far out of range) is `None`.
fn int_in(any: Option<&Value>, lo: i64, hi: i64) -> Option<i64> {
    let d = number(any)?;
    (d >= lo as f64 && d <= hi as f64).then_some(d as i64)
}

/// `NSNumber.stringValue`.
fn number_string(v: &Value) -> Option<String> {
    match v {
        Value::Number(n) => Some(n.as_i64().map_or_else(|| n.to_string(), |i| i.to_string())),
        Value::Bool(b) => Some(if *b { "1" } else { "0" }.to_string()),
        _ => None,
    }
}

fn control(c: &Json) -> MogrtControl {
    let kind = MogrtControlKind::from_code(c.get("type").and_then(|t| number(Some(t))).map_or(-1, |d| d as i64));
    let raw = c.get("value");
    let numbers: Vec<f64> =
        raw.and_then(Value::as_array).map(|a| a.iter().filter_map(|v| number(Some(v))).collect()).unwrap_or_default();
    let value = match kind {
        MogrtControlKind::Text => string(raw).map_or(MogrtControlValue::None, MogrtControlValue::Text),
        MogrtControlKind::Checkbox => match raw {
            Some(Value::Bool(b)) => MogrtControlValue::Bool(*b),
            Some(Value::Number(n)) => MogrtControlValue::Bool(n.as_f64().is_some_and(|d| d != 0.0)),
            _ => MogrtControlValue::None,
        },
        MogrtControlKind::Slider | MogrtControlKind::Angle => {
            number(raw).map_or(MogrtControlValue::None, MogrtControlValue::Number)
        }
        MogrtControlKind::Color => {
            if numbers.len() >= 3 {
                MogrtControlValue::Color {
                    red: numbers[0],
                    green: numbers[1],
                    blue: numbers[2],
                    alpha: numbers.get(3).copied().unwrap_or(1.0),
                }
            } else {
                MogrtControlValue::None
            }
        }
        MogrtControlKind::Point => {
            let p = raw.and_then(Value::as_object);
            match (number(p.and_then(|p| p.get("x"))), number(p.and_then(|p| p.get("y")))) {
                (Some(x), Some(y)) => MogrtControlValue::Point { x, y },
                _ => MogrtControlValue::None,
            }
        }
        MogrtControlKind::Vector => {
            if numbers.is_empty() {
                MogrtControlValue::None
            } else {
                MogrtControlValue::Vector(numbers)
            }
        }
        MogrtControlKind::Menu => {
            let items = c
                .get("menucontent")
                .and_then(Value::as_array)
                .map(|a| a.iter().map(|v| string(Some(v)).unwrap_or_default()).collect())
                .unwrap_or_default();
            int_in(raw, 0, 1_000_000).map_or(MogrtControlValue::None, |index| MogrtControlValue::Menu { index, items })
        }
        MogrtControlKind::Other(_) => MogrtControlValue::None,
    };
    let font = c.get("fonteditinfo").and_then(Value::as_object);
    let font_name =
        font.and_then(|f| f.get("fontEditValue")).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
    let font_size = number(font.and_then(|f| f.get("fontSizeEditValue"))).filter(|&s| s > 0.0);
    let id = c.get("id").and_then(|v| v.as_str().map(str::to_string).or_else(|| number_string(v))).unwrap_or_default();
    MogrtControl { id, name: string(c.get("uiName")).unwrap_or_default(), kind, value, font_name, font_size }
}

impl MogrtDefinition {
    /// Parses definition.json; `None` when it is not a JSON object.
    pub fn parse(data: &[u8]) -> Option<MogrtDefinition> {
        let Value::Object(root) = serde_json::from_slice::<Value>(data).ok()? else { return None };
        let author_app = root.get("authorApp").and_then(Value::as_str).unwrap_or("");
        let author = match author_app {
            "ppro" => MogrtAuthor::Premiere,
            "aefx" => MogrtAuthor::AfterEffects,
            other => MogrtAuthor::Unknown(other.to_string()),
        };
        let info = localized(root.get("sourceInfoLocalized")).and_then(Value::as_object);
        let size = info
            .and_then(|i| i.get("framesize"))
            .and_then(Value::as_object)
            .and_then(|f| f.get("size"))
            .and_then(Value::as_object);
        let mut duration = None;
        if let Some(d) = info.and_then(|i| i.get("duration")).and_then(Value::as_object)
            && let (Some(v), Some(s)) = (number(d.get("value")), number(d.get("scale")))
            && v >= 0.0
            && s >= 1.0
            && v == v.round()
            && s == s.round()
            && v < 1e15
            && s < 1e15
        {
            duration = Some(Time::new(v as i64, s as i64));
        }
        let controls = root
            .get("clientControls")
            .and_then(Value::as_array)
            .and_then(|a| a.iter().map(Value::as_object).collect::<Option<Vec<_>>>())
            .map(|a| a.into_iter().map(control).collect())
            .unwrap_or_default();
        let fonts = localized(root.get("usedFontsLocalized"))
            .and_then(Value::as_array)
            .and_then(|a| a.iter().map(|v| v.as_str().map(str::to_string)).collect::<Option<Vec<_>>>())
            .unwrap_or_default();
        Some(MogrtDefinition {
            name: string(root.get("capsuleNameLocalized"))
                .or_else(|| root.get("capsuleName").and_then(Value::as_str).map(str::to_string))
                .unwrap_or_default(),
            author,
            width: int_in(size.and_then(|s| s.get("x")), 1, MAX_FRAME_SIDE),
            height: int_in(size.and_then(|s| s.get("y")), 1, MAX_FRAME_SIDE),
            duration,
            fonts,
            controls,
        })
    }
}

/// A text layer of the template's graphic as it was authored (before mapping).
#[derive(Debug, Clone, PartialEq)]
pub struct MogrtTextLayer {
    pub text: String,
    pub font_name: Option<String>,
    pub size: Option<f64>,
    /// Fill, 0...1 per channel; `None` when the layer records none.
    pub color: Option<Rgb>,
    /// 0 left, 1 right, 2 center (the text blob's own code); `None` when not recorded.
    pub alignment: Option<i64>,
    /// Layer position as 0...1 of the frame; `None` when not recorded.
    pub position: Option<Vec2>,
}

/// The template as the package describes it: definition plus the layers of its graphic.
#[derive(Debug, Clone, PartialEq)]
pub struct MogrtDescription {
    pub definition: MogrtDefinition,
    pub text_layers: Vec<MogrtTextLayer>,
    /// Shape layers of the graphic. Rectangles, ellipses and straight polygons become Graphics layers; pen paths with
    /// curves are dropped and listed in the report.
    pub shape_layer_count: i64,
}

/// A template package read up to the point where its sequence would be mapped and captured.
#[derive(Debug, Clone)]
pub struct OpenedMogrt {
    pub description: MogrtDescription,
    /// The project inside the package.
    pub document: PRDocument,
    /// thumb.png of the package (PNG bytes), for the Library row.
    pub thumbnail: Option<Vec<u8>>,
}

/// An imported template.
#[derive(Debug, Clone)]
pub struct MogrtImportResult {
    pub template: TitleTemplate,
    /// thumb.png of the package, for the Library row.
    pub thumbnail: Option<Vec<u8>>,
    pub description: MogrtDescription,
    pub report: PRImportReport,
}

/// Reads .mogrt packages.
pub struct MogrtImporter;

impl MogrtImporter {
    pub const FILE_EXTENSION: &'static str = "mogrt";
    /// Thumbnails above this are not carried into the Library payload.
    const MAX_THUMBNAIL_SIZE: usize = 2 << 20;

    /// Opens the package: definition, project and the layers of its graphic. `file_name` names the template when its
    /// definition has no name.
    pub fn open(data: &[u8], file_name: &str) -> Result<OpenedMogrt, MogrtImportError> {
        let not_a_template = || MogrtImportError::NotATemplate;
        let zip = Zip::new(data).map_err(|_| not_a_template())?;
        let def_data = zip.data_named("definition.json").ok().flatten().ok_or_else(not_a_template)?;
        let mut definition = MogrtDefinition::parse(&def_data).ok_or_else(not_a_template)?;
        if definition.name.trim_matches(crate::interchange_xml::is_blank_or_newline).is_empty() {
            definition.name = file_name.to_string();
        }
        let name = definition.name.clone();
        if definition.author == MogrtAuthor::AfterEffects || zip.entry("project.aegraphic").is_some() {
            return Err(MogrtImportError::NeedsAfterEffects { name });
        }
        if zip.entry("project.prgraphic").is_none() {
            return Err(MogrtImportError::MissingGraphic { name });
        }
        let unreadable = || MogrtImportError::Unreadable { name: name.clone() };
        let graphic = zip.data_named("project.prgraphic").ok().flatten().ok_or_else(unreadable)?;
        let project_file = Self::project_data(&graphic).map_err(|_| unreadable())?;
        let Some(project_file) = project_file else { return Err(MogrtImportError::MissingGraphic { name }) };
        let document = PRReader::read(&project_file).map_err(|_| unreadable())?;

        let items: Vec<_> =
            document.sequences.iter().flat_map(|s| s.video_tracks.iter().flat_map(|t| t.items.iter())).collect();
        let text_layers = items
            .iter()
            .flat_map(|i| i.components_named("AE.ADBE Text"))
            .filter_map(text_layer)
            .map(|(text, comp)| MogrtTextLayer {
                text: text.text,
                font_name: text.font_name,
                size: text.size,
                color: text.fill,
                alignment: text.alignment,
                position: PRParamValue::point(comp.param(3).and_then(|p| p.static_value.as_deref())),
            })
            .collect();
        let shape_layer_count = items.iter().map(|i| i.components_named(SHAPE_MATCH_NAME).len() as i64).sum();
        let thumbnail = zip.data_named("thumb.png").ok().flatten().filter(|t| t.len() <= Self::MAX_THUMBNAIL_SIZE);
        Ok(OpenedMogrt {
            description: MogrtDescription { definition, text_layers, shape_layer_count },
            document,
            thumbnail,
        })
    }

    /// Report feature name of a control that has no counterpart.
    pub fn control_feature(c: &MogrtControl) -> String {
        format!("Control \u{201c}{}\u{201d} ({})", c.name, c.kind.label())
    }

    /// Imports the package: `open`, then the sequence is mapped and captured as a title template. Text slots take the name
    /// of the text control with the same default string; every other control has no counterpart and is reported.
    pub fn read(data: &[u8], file_name: &str, ids: &mut dyn IdSource) -> Result<MogrtImportResult, MogrtImportError> {
        let opened = Self::open(data, file_name)?;
        let OpenedMogrt { description, document, thumbnail } = opened;
        let definition = &description.definition;
        let name = definition.name.clone();

        // Shape layers become Graphics layers; the ones the model cannot draw (pen paths) come back as dropped notes.
        let mapped = PRMapper::map(&document, &name, &BTreeMap::new(), true, ids);
        let mut report = mapped.report;
        let project = mapped.project;
        let timeline =
            project.active_timeline.and_then(|id| project.timeline(id)).or_else(|| project.timelines.first());
        let mut layer_ids: Vec<Id> = Vec::new();
        for track in timeline.iter().flat_map(|t| t.tracks.iter()) {
            for clip in track.clips() {
                if track.kind != TrackKind::Video {
                    report.note("Audio", Status::Dropped, "a template carries picture only");
                } else if clip.generator.is_none() {
                    report.note(
                        "Embedded media",
                        Status::Dropped,
                        &format!("{}: footage and nested sequences of a template are not imported", clip.name),
                    );
                } else {
                    layer_ids.push(clip.id);
                }
            }
        }
        let dropped =
            |r: &PRImportReport| r.entries().iter().filter(|e| e.status == Status::Dropped).map(|e| e.count).sum();
        let captured = timeline
            .filter(|_| !layer_ids.is_empty())
            .and_then(|t| TitleTemplate::capture(&layer_ids, t.id, &project, &name, &[], ids).ok())
            .filter(|t| !t.slots.is_empty());
        let Some(mut template) = captured else {
            for c in &definition.controls {
                report.note(&Self::control_feature(c), Status::Dropped, "no layer to edit");
            }
            return Err(MogrtImportError::NothingImportable { name, dropped: dropped(&report) });
        };

        let mut open: Vec<&MogrtControl> = definition.controls.iter().collect();
        for slot in &mut template.slots {
            let SlotValue::Text(s) = &slot.value else { continue };
            let Some(c) = open
                .iter()
                .position(|c| c.kind == MogrtControlKind::Text && c.value == MogrtControlValue::Text(s.clone()))
            else {
                continue;
            };
            let label = open[c].name.trim_matches(crate::interchange_xml::is_blank_or_newline);
            if !label.is_empty() {
                slot.name = label.to_string();
            }
            open.remove(c);
        }
        for c in open {
            let why = if c.kind == MogrtControlKind::Text {
                "no text layer with this text"
            } else {
                "no editable counterpart yet"
            };
            report.note(&Self::control_feature(c), Status::Dropped, why);
        }
        Ok(MogrtImportResult { template, thumbnail, description, report })
    }

    /// project.prgraphic is a ZIP around one project file; a bare (gzip or plain XML) project is taken as it is. `Ok(None)`:
    /// the archive holds no project (only folders or empty files). `Err` for a damaged archive.
    pub(crate) fn project_data(graphic: &[u8]) -> Result<Option<Vec<u8>>, sq_prproj_reader::inflate::Corrupt> {
        if graphic.is_empty() {
            return Ok(None);
        }
        if !graphic.starts_with(&[0x50, 0x4b]) {
            return Ok(Some(graphic.to_vec()));
        }
        let inner = Zip::new(graphic)?;
        // Folder entries and empty files are no project, whatever they are called.
        let files: Vec<_> = inner
            .entries
            .iter()
            .filter(|e| !e.name.ends_with('/') && !e.name.ends_with('\\') && e.uncompressed_size > 0)
            .collect();
        let Some(entry) = files.iter().find(|e| e.name.to_lowercase().ends_with(".prproj")).or(files.first()) else {
            return Ok(None);
        };
        inner.data(entry).map(Some)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEFINITION: &str = r#"{
        "authorApp": "ppro",
        "capsuleNameLocalized": {"strDB": [{"localeString": "de_DE", "str": "Titel"}, {"localeString": "en_US", "str": "Title"}]},
        "sourceInfoLocalized": {"en_US": {"framesize": {"size": {"x": 1920, "y": 1080}}, "duration": {"value": 300, "scale": 30}}},
        "usedFontsLocalized": {"en_US": ["Inter-Bold"]},
        "clientControls": [
            {"id": "c1", "type": 6, "uiName": {"strDB": [{"localeString": "en_US", "str": "Headline"}]},
             "value": {"strDB": [{"localeString": "en_US", "str": "Hello"}]}, "fonteditinfo": {"fontEditValue": "Inter-Bold", "fontSizeEditValue": 48}},
            {"id": 7, "type": 4, "value": [1, 0.5, 0]},
            {"id": "m", "type": 13, "value": 1, "menucontent": [{"strDB": [{"localeString": "en_US", "str": "A"}]}]},
            {"id": "x", "type": 42, "value": 3}
        ]
    }"#;

    #[test]
    fn definition_reads_name_size_duration_and_controls() {
        let d = MogrtDefinition::parse(DEFINITION.as_bytes()).unwrap();
        assert_eq!(d.name, "Title");
        assert_eq!(d.author, MogrtAuthor::Premiere);
        assert!(d.width == Some(1920) && d.height == Some(1080));
        assert_eq!(d.duration, Some(Time::new(10, 1)));
        assert_eq!(d.fonts, vec!["Inter-Bold".to_string()]);
        assert_eq!(d.controls.len(), 4);
        let text = &d.controls[0];
        assert!(
            text.kind == MogrtControlKind::Text
                && text.value == MogrtControlValue::Text("Hello".into())
                && text.name == "Headline"
        );
        assert!(text.font_name.as_deref() == Some("Inter-Bold") && text.font_size == Some(48.0));
        assert_eq!(d.controls[1].id, "7");
        assert_eq!(d.controls[1].value, MogrtControlValue::Color { red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0 });
        assert_eq!(d.controls[2].value, MogrtControlValue::Menu { index: 1, items: vec!["A".into()] });
        assert!(d.controls[3].kind == MogrtControlKind::Other(42) && d.controls[3].kind.label() == "type 42");
    }

    #[test]
    fn hostile_numbers_are_ignored_not_trapped() {
        let d = MogrtDefinition::parse(br#"{"sourceInfoLocalized": {"en_US": {"framesize": {"size": {"x": 1e300, "y": 0}}, "duration": {"value": 1e300, "scale": 30}}}}"#).unwrap();
        assert!(d.width.is_none() && d.height.is_none() && d.duration.is_none());
        assert!(MogrtDefinition::parse(b"[1]").is_none());
    }

    #[test]
    fn not_a_zip_is_not_a_template() {
        assert_eq!(MogrtImporter::open(b"hello", "x").err(), Some(MogrtImportError::NotATemplate));
    }

    #[test]
    fn bare_projects_pass_through_and_empty_archives_hold_none() {
        assert_eq!(MogrtImporter::project_data(b"<PremiereData/>").unwrap(), Some(b"<PremiereData/>".to_vec()));
        assert_eq!(MogrtImporter::project_data(b"").unwrap(), None);
    }
}

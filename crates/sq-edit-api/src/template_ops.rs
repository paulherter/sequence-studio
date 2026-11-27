//! Title templates in the edit API: `GET/POST /v1/templates` and the `insertTemplate` operation.

use crate::edit_operation::EditOperation;
use crate::edit_transaction::{TransactionError, TransactionErrorKind};
use serde::Serialize;
use serde_json::{Map, Value, json};
use sq_core_edit::title_template::ProjectTitleTemplateExt;
use sq_core_model::{
    EditError, Project, SlotValue, TemplateEditError, TemplateField, TemplateFieldKind, TitleTemplate,
};
use sq_core_time::{Id, IdSource};
use std::collections::BTreeMap;

/// One template of the Library as `GET /v1/templates` lists it.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TemplateInfo {
    /// The Library item id.
    pub id: String,
    /// Shown name.
    pub name: String,
    /// Library folder ("/" path), absent at the top level.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    /// The editable fields, with their current values.
    pub fields: Vec<TemplateField>,
}

/// A template with the field values a request set, ready to place (filled in by the router).
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedTemplate {
    /// The template as saved.
    pub template: TitleTemplate,
    /// New slot values by slot id.
    pub values: BTreeMap<Id, SlotValue>,
}

/// The `GET /v1/templates` answer: every folder (sorted) and every template.
pub fn templates_json(list: &[TemplateInfo]) -> Value {
    let mut folders: Vec<&str> = list.iter().filter_map(|t| t.folder.as_deref()).collect();
    folders.sort_unstable();
    folders.dedup();
    json!({
        "folders": folders,
        "templates": list,
        "usage": "insertTemplate {template: id or name, track, at, duration?, fields?: {<field id or name>: value}}",
    })
}

fn kind_name(kind: TemplateFieldKind) -> &'static str {
    match kind {
        TemplateFieldKind::Text => "text",
        TemplateFieldKind::Emoji => "emoji",
        TemplateFieldKind::Color => "color",
        TemplateFieldKind::Font => "font",
        TemplateFieldKind::Number => "number",
        TemplateFieldKind::Image => "image",
        TemplateFieldKind::Duration => "duration",
    }
}

/// Reads `fields` (`{<field id or name>: value}`) against the template's own fields. An unknown field or a value of
/// the wrong shape names the field and lists the known ones.
pub fn parse_fields(template: &TitleTemplate, fields: &Value) -> Result<BTreeMap<Id, SlotValue>, String> {
    let empty = Map::new();
    let map = match fields {
        Value::Object(m) => m,
        Value::Null => &empty,
        _ => return Err("fields: expected an object {<field id or name>: value}".into()),
    };
    let known = template.fields();
    let list = || {
        known
            .iter()
            .filter(|f| f.kind != TemplateFieldKind::Duration)
            .map(|f| format!("{} '{}' ({})", f.id, f.name, kind_name(f.kind)))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let mut out = BTreeMap::new();
    for (key, value) in map {
        let by_id: Vec<&TemplateField> = known.iter().filter(|f| f.id.to_string().eq_ignore_ascii_case(key)).collect();
        let hits =
            if by_id.is_empty() { known.iter().filter(|f| f.name.eq_ignore_ascii_case(key)).collect() } else { by_id };
        let field = match hits.as_slice() {
            [f] => *f,
            [] => return Err(format!("fields: unknown field '{key}'; known fields: {}", list())),
            _ => return Err(format!("fields: '{key}' names several fields; use the id. Known fields: {}", list())),
        };
        let slot = parse_value(field, value).map_err(|why| format!("fields.{key}: {why}"))?;
        out.insert(field.id, slot);
    }
    Ok(out)
}

fn parse_value(field: &TemplateField, value: &Value) -> Result<SlotValue, String> {
    let wrong = |want: &str| Err(format!("a {} field takes {want}", kind_name(field.kind)));
    match field.kind {
        TemplateFieldKind::Text => value.as_str().map_or_else(|| wrong("a string"), |s| Ok(SlotValue::Text(s.into()))),
        TemplateFieldKind::Emoji => match value.as_str() {
            Some(s) if sq_core_model::is_single_emoji(s) => Ok(SlotValue::Text(s.into())),
            _ => wrong("one emoji as a string"),
        },
        TemplateFieldKind::Font => match value.as_str() {
            Some(s) if !s.trim().is_empty() => Ok(SlotValue::Font(s.into())),
            _ => wrong("a font name"),
        },
        TemplateFieldKind::Number => match value.as_f64() {
            Some(n) if n.is_finite() => Ok(SlotValue::Number(n)),
            _ => wrong("a number"),
        },
        TemplateFieldKind::Color => {
            let part = |k: &str, default: Option<f64>| match value.get(k) {
                None => default
                    .ok_or_else(|| format!("a color field takes {{red, green, blue, alpha?}} (0...1): {k} is missing")),
                Some(v) => v.as_f64().filter(|n| (0.0..=1.0).contains(n)).ok_or_else(|| {
                    format!("a color field takes {{red, green, blue, alpha?}} (0...1): {k} is not in 0...1")
                }),
            };
            if !value.is_object() {
                return wrong("{red, green, blue, alpha?} (each 0...1)");
            }
            Ok(SlotValue::Color {
                red: part("red", None)?,
                green: part("green", None)?,
                blue: part("blue", None)?,
                alpha: part("alpha", Some(1.0))?,
            })
        }
        TemplateFieldKind::Image => {
            let Some(path) = value.as_str() else { return wrong("an absolute file path") };
            let p = std::path::Path::new(path);
            if !p.is_absolute()
                || path.chars().any(char::is_control)
                || p.components().any(|c| matches!(c, std::path::Component::ParentDir))
            {
                return Err("an image field takes an absolute path without '..'".into());
            }
            if !p.is_file() {
                return Err(format!("no such file: {path}"));
            }
            Ok(SlotValue::Media { path: path.into(), bookmark: None })
        }
        TemplateFieldKind::Duration => Err("the length is not a field: use the operation's `duration`".into()),
    }
}

/// Places the resolved template of `op` (an `InsertTemplate`) on `work`; `index` is its place in the batch.
pub(crate) fn insert(
    work: &mut Project,
    sequence: Id,
    index: usize,
    op: &EditOperation,
    ids: &mut dyn IdSource,
) -> Result<(), TransactionError> {
    let EditOperation::InsertTemplate { track, at, duration, resolved, .. } = op else { return Ok(()) };
    let fail = |kind| TransactionError::at(kind, index, op.name());
    let Some(resolved) = resolved else {
        let mut e = fail(TransactionErrorKind::Invalid);
        e.detail = Some("insertTemplate: the template was not looked up (it needs the app's template library)".into());
        return Err(e);
    };
    let Some(fd) = work.timeline(sequence).map(sq_core_model::Timeline::frame_duration) else {
        return Err(fail(TransactionErrorKind::Edit(EditError::TimelineNotFound)));
    };
    if work.timeline(sequence).is_some_and(|t| t.track(*track).is_none()) {
        return Err(fail(TransactionErrorKind::TrackNotFound));
    }
    work.apply_title_template(&resolved.template, sequence, *track, at.snapped(fd), *duration, &resolved.values, ids)
        .map(|_| ())
        .map_err(|e| match e {
            TemplateEditError::Edit(e) => fail(TransactionErrorKind::Edit(e)),
            TemplateEditError::Template(e) => {
                let mut err = fail(TransactionErrorKind::Invalid);
                err.detail = Some(format!("insertTemplate: {e:?}"));
                err
            }
        })
}

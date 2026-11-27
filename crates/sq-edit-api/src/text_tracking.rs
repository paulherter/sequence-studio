//! Tracking (letter spacing, points) of a text layer as a keyable parameter `layer.<id>.tracking`. The keys live in the
//! text template (`TextTemplate::tracking_keys`, clip-local time), so every edit that re-encodes the text keeps them and the
//! text renderer reads them per frame; while they exist they replace `style.tracking`.

use crate::clip_params::{KeyShape, drop_key, handle_json, move_in, put_key, shift_in};
use serde_json::{Value, json};
use sq_core_model::{AnimatedProperty, GraphicsContent, GraphicsLayer};
use sq_core_time::{Id, IdSource, Time};
use sq_text::text_generator::TextGenerator;
use sq_text::text_template::TextTemplate;

const MIN: f64 = -20.0;
const MAX: f64 = 200.0;

/// The layer id of a `layer.<id>.tracking` path.
pub(crate) fn layer_of_path(path: &str) -> Option<Id> {
    Id::parse(path.strip_prefix("layer.")?.strip_suffix(".tracking")?)
}

fn number(v: &Value) -> Result<f64, String> {
    v.as_f64()
        .filter(|n| n.is_finite() && (MIN..=MAX).contains(n))
        .ok_or_else(|| format!("tracking: a number {MIN}...{MAX} (points between letters)"))
}

fn edit(layer: &mut GraphicsLayer, f: impl FnOnce(&mut TextTemplate) -> Result<(), String>) -> Result<(), String> {
    let GraphicsContent::Text { generator } = &layer.content else {
        return Err("the layer is not a text layer".into());
    };
    let (mut template, animations) = TextGenerator::decode(generator).map_err(|e| format!("text layer: {e}"))?;
    f(&mut template)?;
    let generator = TextGenerator::make_ref(&template, animations.as_ref()).map_err(|e| e.to_string())?;
    layer.content = GraphicsContent::Text { generator };
    Ok(())
}

/// The static value (refused while keyed: the keys win, a silent no-op would mislead).
pub(crate) fn set(layer: &mut GraphicsLayer, value: &Value) -> Result<(), String> {
    let v = number(value)?;
    edit(layer, |t| {
        if t.tracking_keys.is_some() {
            return Err("the parameter has keyframes: use setKeyframe / removeKeyframe".into());
        }
        t.style.tracking = v;
        Ok(())
    })
}

/// A key at clip-local `at` (inside the clip); the first key starts the track from the style's tracking.
pub(crate) fn set_key(
    layer: &mut GraphicsLayer,
    duration: Time,
    at: Time,
    value: &Value,
    shape: &KeyShape,
    ids: &mut dyn IdSource,
) -> Result<(), String> {
    if at < Time::ZERO || at > duration {
        return Err("at must lie inside the clip (clip-local time, 0 = clip start)".into());
    }
    let v = number(value)?;
    edit(layer, |t| {
        let base = t.style.tracking;
        put_key(t.tracking_keys.get_or_insert_with(|| AnimatedProperty::new(base)), at, v, shape, ids)
    })
}

/// Removes the key at `at`; the last key going leaves the style's static tracking.
pub(crate) fn remove_key(layer: &mut GraphicsLayer, at: Time) -> Result<(), String> {
    edit(layer, |t| {
        let p = t.tracking_keys.as_mut().ok_or("no keyframe at that time")?;
        if !drop_key(p, at) {
            return Err("no keyframe at that time".into());
        }
        if p.track.is_empty() {
            t.tracking_keys = None;
        }
        Ok(())
    })
}

/// Moves one key (see `Host::move_key`).
pub(crate) fn move_key(layer: &mut GraphicsLayer, duration: Time, from: Time, to: Time) -> Result<(), String> {
    edit(layer, |t| move_in(t.tracking_keys.as_mut().ok_or("no keyframe at 'from'")?, from, to, duration))
}

/// Shifts the keys at or after `after`; 0 when the layer has no tracking keys (nothing is re-encoded then).
pub(crate) fn shift_keys(
    layer: &mut GraphicsLayer,
    duration: Time,
    by: Time,
    after: Option<Time>,
) -> Result<usize, String> {
    let keyed = match &layer.content {
        GraphicsContent::Text { generator } => TextGenerator::decode(generator)
            .is_ok_and(|(t, _)| t.tracking_keys.as_ref().is_some_and(|p| !p.track.is_empty())),
        _ => false,
    };
    if !keyed {
        return Ok(0);
    }
    let mut n = 0;
    edit(layer, |t| {
        n = shift_in(t.tracking_keys.as_mut().ok_or("no tracking keys")?, by, after, duration)?;
        Ok(())
    })?;
    Ok(n)
}

/// The parameter entry for the clip's param list.
pub(crate) fn param_json(layer_name: &str, id: Id, t: &TextTemplate) -> Value {
    let mut m = json!({"path": format!("layer.{id}.tracking"), "group": layer_name, "title": "Tracking", "type": "number",
        "unit": "pt", "min": MIN, "max": MAX, "default": 0.0, "value": t.style.tracking, "animated": false, "layer": id});
    if let Some(p) = t.tracking_keys.as_ref().filter(|p| !p.track.is_empty()) {
        m["animated"] = json!(true);
        m["keyframes"] = Value::Array(p.track.keys.iter().map(|k| json!({"at": k.time, "value": k.value, "interpolation": format!("{:?}", k.interpolation).to_lowercase(), "inHandle": handle_json(k.in_handle), "outHandle": handle_json(k.out_handle)})).collect());
    }
    m
}

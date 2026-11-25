//! The parameter, effect and text-layer operations of an agent commit, on one sequence. Every verb calls the model's own
//! edit (`Clip::add_effect`, `AnimatedProperty` keys, `GraphicsDocument`), the ones the inspector uses.

use crate::clip_params::{Addr, Host, parse_path};
use serde_json::Value;
use sq_core_effects::effects_editing::ClipEffectsEditingExt;
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{Clip, EditError, GeneratorRef, GraphicsContent, GraphicsDocument, Timeline};
use sq_core_time::{Id, IdSource, Interpolation, Time};

/// Why an operation failed: the model refused it, or the request does not fit the clip (message for the agent).
pub(crate) enum OpFailure {
    Edit(EditError),
    Invalid(String),
}

impl From<EditError> for OpFailure {
    fn from(e: EditError) -> Self {
        OpFailure::Edit(e)
    }
}

impl From<&str> for OpFailure {
    fn from(s: &str) -> Self {
        OpFailure::Invalid(s.to_string())
    }
}

impl From<String> for OpFailure {
    fn from(s: String) -> Self {
        OpFailure::Invalid(s)
    }
}

fn with_clip<R>(
    t: &mut Timeline,
    id: Id,
    f: impl FnOnce(&mut Clip) -> Result<R, OpFailure>,
) -> Result<R, OpFailure> {
    let ti = t.tracks.iter().position(|tr| tr.clip(id).is_some()).ok_or(EditError::ClipNotFound)?;
    if t.tracks[ti].is_locked {
        return Err(EditError::TrackLocked.into());
    }
    let mut c = t.tracks[ti].clip(id).cloned().ok_or(EditError::ClipNotFound)?;
    let r = f(&mut c)?;
    t.tracks[ti].replace(c);
    Ok(r)
}

/// `f` on the clip's own parameters, or on the layer a `layer.<id>.` path names.
fn with_host<R>(
    c: &mut Clip,
    layer: Option<Id>,
    f: impl FnOnce(&mut Host<'_>) -> Result<R, String>,
) -> Result<R, OpFailure> {
    let duration = c.duration();
    match layer {
        None => Ok(f(&mut Host::of_clip(c))?),
        Some(l) => {
            let doc = c.graphics_store.as_mut().ok_or("the clip has no layers (not a graphics clip)")?;
            let layer = doc.layers.iter_mut().find(|x| x.id == l).ok_or_else(|| format!("no layer {l} on this clip"))?;
            Ok(f(&mut Host::of_layer(layer, duration))?)
        }
    }
}

fn layer_of(c: &mut Clip, layer: Id) -> Result<&mut sq_core_model::GraphicsLayer, OpFailure> {
    let doc = c.graphics_store.as_mut().ok_or("the clip has no layers (not a graphics clip)")?;
    Ok(doc.layers.iter_mut().find(|x| x.id == layer).ok_or_else(|| format!("no layer {layer} on this clip"))?)
}

pub(crate) fn set_param(t: &mut Timeline, clip: Id, param: &str, value: &Value) -> Result<(), OpFailure> {
    // The text and the style of a text layer are parameters too (`layer.<id>.text`, `layer.<id>.style`).
    if let Some(r) = param.strip_prefix("layer.")
        && let Some((id, field @ ("text" | "style"))) = r.split_once('.')
        && let Some(id) = Id::parse(id)
    {
        return with_clip(t, clip, |c| {
            let d = c.duration();
            let l = layer_of(c, id)?;
            let spec = serde_json::json!({ field: value });
            Ok(crate::text_layers::apply(l, &spec, false, d)?)
        });
    }
    let (layer, addr) = parse_path(param)?;
    with_clip(t, clip, |c| with_host(c, layer, |h| h.set(&addr, value)))
}

pub(crate) fn set_keyframe(
    t: &mut Timeline,
    clip: Id,
    param: &str,
    at: Time,
    value: &Value,
    interpolation: Option<Interpolation>,
    ids: &mut dyn IdSource,
) -> Result<(), OpFailure> {
    let (layer, addr) = parse_path(param)?;
    if addr == Addr::GainDb {
        return Err("audio.gainDb cannot be keyframed; use audio.volumeDb".to_string().into());
    }
    with_clip(t, clip, |c| with_host(c, layer, |h| h.set_key(&addr, at, value, interpolation, ids)))
}

pub(crate) fn remove_keyframe(t: &mut Timeline, clip: Id, param: &str, at: Time) -> Result<(), OpFailure> {
    let (layer, addr) = parse_path(param)?;
    with_clip(t, clip, |c| with_host(c, layer, |h| h.remove_key(&addr, at)))
}

pub(crate) fn add_effect(
    t: &mut Timeline,
    clip: Id,
    kind: &str,
    index: Option<usize>,
    ids: &mut dyn IdSource,
) -> Result<(), OpFailure> {
    with_clip(t, clip, |c| {
        let id = c.add_effect(kind, None, ids).ok_or_else(|| {
            format!("effect '{kind}' cannot be added to this clip (unknown kind, a video effect on an audio clip or the reverse, or generator-owned); see GET /v1/effects")
        })?;
        if let Some(i) = index {
            c.move_effect(id, i as i64);
        }
        Ok(())
    })
}

pub(crate) fn remove_effect(t: &mut Timeline, clip: Id, effect: Id) -> Result<(), OpFailure> {
    with_clip(t, clip, |c| {
        if c.remove_effect(effect) { Ok(()) } else { Err(format!("no effect {effect} on this clip").into()) }
    })
}

pub(crate) fn add_graphic(
    t: &mut Timeline,
    track: Id,
    at: Time,
    duration: Time,
    name: Option<&str>,
    layers: &[Value],
    ids: &mut dyn IdSource,
) -> Result<(), OpFailure> {
    let fd = t.frame_duration();
    let (start, duration) = (at.snapped(fd), duration.snapped(fd).max(fd));
    let mut built = Vec::new();
    for (i, spec) in layers.iter().enumerate() {
        let l = crate::text_layers::new_layer(spec, &format!("Text {}", i + 1), ids, duration)
            .map_err(|e| format!("layers[{i}]: {e}"))?;
        built.push(l);
    }
    let placement = GeneratorPlacement { timeline: t.id, track, start, duration };
    let id = t.place_generator_clip(GeneratorRef::graphics_clip(), Some(name.unwrap_or("Graphic")), placement, ids)?;
    with_clip(t, id, |c| {
        c.set_graphics(Some(GraphicsDocument { layers: built, groups: Vec::new() }));
        Ok(())
    })
}

pub(crate) fn set_text_layer(t: &mut Timeline, clip: Id, layer: Id, spec: &Value) -> Result<(), OpFailure> {
    with_clip(t, clip, |c| {
        let d = c.duration();
        let l = layer_of(c, layer)?;
        if !l.is_text() {
            return Err("the layer is not a text layer".to_string().into());
        }
        Ok(crate::text_layers::apply(l, spec, false, d)?)
    })
}

pub(crate) fn add_text_layer(
    t: &mut Timeline,
    clip: Id,
    spec: &Value,
    index: Option<usize>,
    ids: &mut dyn IdSource,
) -> Result<(), OpFailure> {
    with_clip(t, clip, |c| {
        let d = c.duration();
        let doc = c.graphics_store.as_mut().ok_or("the clip is not a graphics clip; make one with addGraphic")?;
        if doc.layers.len() >= crate::text_layers::MAX_LAYERS {
            return Err(format!("a graphic holds at most {} layers", crate::text_layers::MAX_LAYERS).into());
        }
        let l = crate::text_layers::new_layer(spec, &format!("Text {}", doc.layers.len() + 1), ids, d)?;
        let at = index.unwrap_or(doc.layers.len()).min(doc.layers.len());
        doc.layers.insert(at, l);
        Ok(())
    })
}

pub(crate) fn remove_text_layer(t: &mut Timeline, clip: Id, layer: Id) -> Result<(), OpFailure> {
    with_clip(t, clip, |c| {
        let doc = c.graphics_store.as_mut().ok_or("the clip is not a graphics clip")?;
        let i = doc.index_of(layer).ok_or_else(|| format!("no layer {layer} on this clip"))?;
        if !matches!(doc.layers[i].content, GraphicsContent::Text { .. }) {
            return Err("the layer is not a text layer".to_string().into());
        }
        doc.layers.remove(i);
        Ok(())
    })
}

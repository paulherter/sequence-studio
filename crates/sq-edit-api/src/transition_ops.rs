//! `addTransition`, `removeTransition` and `applyPreset`: thin calls of the commands the Effects panel and the timeline use
//! (`add_transition_looked`, `Timeline::apply_preset`); the catalogs for `GET /v1/transitions` and `GET /v1/effectPresets`.

use crate::param_ops::OpFailure;
use serde_json::{Value, json};
use sq_core_effects::effect_preset::{Anchor, ApplyMode, EffectPreset, TimelineEffectPresetExt};
use sq_core_effects::effect_stack_preset::EffectStackPresets;
use sq_core_effects::transition::{
    TimelineTransitions, TransitionKindExt, TransitionPoint, TransitionSpec, add_element_transitions_looked,
    add_transition_looked,
};
use sq_core_model::{ClipEdge, EditError, Timeline, TrackKind, TransitionAlignment, TransitionKind};
use sq_core_time::{Id, IdSource, Time};
use std::collections::BTreeSet;

fn kind_name(k: TransitionKind) -> String {
    serde_json::to_value(k).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
}

/// `GET /v1/transitions`: every kind with its wire name, shown name, track kind and whether it acts on one clip edge.
pub(crate) fn transitions_json() -> Value {
    let fd = Time::new(1, 30);
    let all = [TrackKind::Video, TrackKind::Audio].into_iter().flat_map(TransitionKind::kinds_for);
    let list: Vec<Value> = all
        .map(|k| {
            json!({
                "kind": kind_name(k), "name": k.name(),
                "track": if k.track_kind() == TrackKind::Audio { "audio" } else { "video" },
                "element": k.is_element(),
                "defaultSeconds": k.preset_duration(fd).map(|d| d.value() as f64 / d.timescale() as f64),
            })
        })
        .collect();
    json!({
        "transitions": list,
        "usage": "addTransition {clip, edge: head|tail} or {between: [outgoing, incoming]}, kind, duration, alignment?: center|start|end",
        "note": "element kinds (move, zoom, pop) act on one clip edge; the others also sit between two touching clips",
    })
}

pub(crate) fn parse_kind(s: &str) -> Result<TransitionKind, String> {
    serde_json::from_value(json!(s)).map_err(|_| format!("kind: unknown '{s}'; see GET /v1/transitions"))
}

pub(crate) fn parse_alignment(s: &str) -> Result<TransitionAlignment, String> {
    match s {
        "center" => Ok(TransitionAlignment::Center),
        "start" => Ok(TransitionAlignment::StartAtCut),
        "end" => Ok(TransitionAlignment::EndAtCut),
        other => Err(format!("alignment: unknown '{other}'; known: center, start, end")),
    }
}

fn track_of(t: &Timeline, clip: Id) -> Result<(Id, bool), OpFailure> {
    let tr = t.tracks.iter().find(|tr| tr.clip(clip).is_some()).ok_or(EditError::ClipNotFound)?;
    Ok((tr.id, tr.is_locked))
}

/// Where a transition goes.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Place {
    Edge(Id, ClipEdge),
    Between(Id, Id),
}

pub(crate) fn add_transition(
    t: &mut Timeline,
    place: Place,
    kind: &str,
    duration: Time,
    alignment: &str,
    ids: &mut dyn IdSource,
) -> Result<(), OpFailure> {
    let kind = parse_kind(kind)?;
    let alignment = parse_alignment(alignment)?;
    let first = match place {
        Place::Edge(c, _) | Place::Between(c, _) => c,
    };
    let (track, locked) = track_of(t, first)?;
    if locked {
        return Err(EditError::TrackLocked.into());
    }
    let spec = TransitionSpec { kind, track, duration, alignment };
    match place {
        Place::Edge(clip, edge) if kind.is_element() => {
            add_element_transitions_looked(t, clip, &[edge], &spec, None, ids)?;
        }
        Place::Edge(clip, edge) => {
            let point = if edge == ClipEdge::Head { TransitionPoint::Head(clip) } else { TransitionPoint::Tail(clip) };
            add_transition_looked(t, point, &spec, None, ids)?;
        }
        Place::Between(..) if kind.is_element() => {
            return Err(
                format!("{}: an element transition sits on one clip edge; use clip + edge", kind_name(kind)).into()
            );
        }
        Place::Between(a, b) => {
            let point = TransitionPoint::Cut { outgoing: a, incoming: b };
            add_transition_looked(t, point, &spec, None, ids)?;
        }
    }
    Ok(())
}

pub(crate) fn remove_transition(t: &mut Timeline, id: Id) -> Result<(), OpFailure> {
    t.remove_transition(id).map_err(Into::into)
}

/// A preset the user saved or imported (Library > Presets), as the host hands it to the API.
#[derive(Clone, Debug, PartialEq)]
pub struct UserEffectPreset {
    /// The preset's id in the user store (a UUID).
    pub id: String,
    /// Shown name.
    pub name: String,
    /// The decoded preset.
    pub preset: EffectPreset,
}

fn anchor_name(a: Anchor) -> &'static str {
    match a {
        Anchor::Start => "start",
        Anchor::End => "end",
        Anchor::Stretch => "stretch",
    }
}

/// `GET /v1/effectPresets`: the built-in effect presets (motion, keying, looks, audio chains) and the user's own
/// (`"user": true`; `preset` = their id, a name works too).
pub(crate) fn presets_json(user: &[UserEffectPreset]) -> Value {
    let mut list: Vec<Value> = EffectStackPresets::offered()
        .into_iter()
        .map(|p| {
            json!({
                "preset": p.id, "name": p.name, "bin": format!("{:?}", p.bin).to_lowercase(),
                "track": if p.track_kind() == TrackKind::Audio { "audio" } else { "video" },
                "at": if p.anchor == Anchor::End { "tail" } else { "head" },
            })
        })
        .collect();
    list.extend(user.iter().map(|u| {
        json!({
            "preset": u.id, "name": u.name, "user": true, "kind": "effect", "anchor": anchor_name(u.preset.anchor),
            "track": if u.preset.track_kind() == TrackKind::Audio { "audio" } else { "video" },
            "at": if u.preset.anchor == Anchor::End { "tail" } else { "head" },
        })
    }));
    json!({ "presets": list, "usage": "applyPreset {clip, preset, at?: head|tail, mode?: absolute|relative}" })
}

/// Swaps an `applyPreset` that names none of the built-ins for the user preset with that id or name (a built-in wins a
/// name clash; two user presets with one name are ambiguous: use the id).
pub(crate) fn resolve_user_presets(
    ops: Vec<crate::edit_operation::EditOperation>,
    user: &[UserEffectPreset],
) -> Result<Vec<crate::edit_operation::EditOperation>, String> {
    use crate::edit_operation::EditOperation;
    ops.into_iter()
        .map(|op| {
            let EditOperation::ApplyPreset { clip, preset, at, mode } = &op else { return Ok(op) };
            if built_in(preset).is_some() {
                return Ok(op);
            }
            let by_id: Vec<&UserEffectPreset> = user.iter().filter(|u| u.id.eq_ignore_ascii_case(preset)).collect();
            let hits = if by_id.is_empty() {
                user.iter().filter(|u| u.name.eq_ignore_ascii_case(preset)).collect()
            } else {
                by_id
            };
            match hits.as_slice() {
                [] => Ok(op),
                [u] => Ok(EditOperation::ApplyUserPreset {
                    clip: *clip,
                    name: u.name.clone(),
                    preset: Box::new(u.preset.clone()),
                    at: *at,
                    mode: mode.clone(),
                }),
                _ => Err(format!(
                    "preset: '{preset}' names several of your presets; use the id from GET /v1/effectPresets"
                )),
            }
        })
        .collect()
}

fn built_in(preset: &str) -> Option<sq_core_effects::effect_stack_preset::EffectStackPreset> {
    EffectStackPresets::preset(preset)
        .or_else(|| EffectStackPresets::preset_by_row_id(preset))
        .or_else(|| EffectStackPresets::all().into_iter().find(|p| p.name.eq_ignore_ascii_case(preset)))
}

pub(crate) fn apply_preset(
    t: &mut Timeline,
    clip: Id,
    preset: &str,
    at: Option<ClipEdge>,
    mode: Option<&str>,
    ids: &mut dyn IdSource,
) -> Result<(), OpFailure> {
    let found = built_in(preset).ok_or_else(|| format!("preset: unknown '{preset}'; see GET /v1/effectPresets"))?;
    if let Some(edge) = at {
        let own = if found.anchor == Anchor::End { ClipEdge::Tail } else { ClipEdge::Head };
        if edge != own {
            let own = if own == ClipEdge::Tail { "tail" } else { "head" };
            return Err(format!(
                "preset '{}' is anchored at the clip's {own}; leave `at` out or use {own}",
                found.name
            )
            .into());
        }
    }
    let mode = match mode {
        None | Some("absolute") => ApplyMode::Absolute,
        Some("relative") => ApplyMode::Relative,
        Some(o) => return Err(format!("mode: unknown '{o}'; known: absolute, relative").into()),
    };
    let targets: BTreeSet<Id> = std::iter::once(clip).collect();
    // The same call the Effects panel makes (EditorSession::apply_stack_preset): one clip, one undo step.
    t.apply_preset(&found.preset(), &targets, mode, ids).map(|_| ()).map_err(Into::into)
}

/// A user preset: the call the Effects panel makes for it (`Timeline::apply_preset`), honouring the preset's own anchor.
pub(crate) fn apply_user_preset(
    t: &mut Timeline,
    clip: Id,
    name: &str,
    preset: &EffectPreset,
    at: Option<ClipEdge>,
    mode: Option<&str>,
    ids: &mut dyn IdSource,
) -> Result<(), OpFailure> {
    if let Some(edge) = at {
        let own = if preset.anchor == Anchor::End { ClipEdge::Tail } else { ClipEdge::Head };
        if edge != own {
            let own = if own == ClipEdge::Tail { "tail" } else { "head" };
            return Err(format!("preset '{name}' is anchored at the clip's {own}; leave `at` out or use {own}").into());
        }
    }
    let mode = match mode {
        None | Some("absolute") => ApplyMode::Absolute,
        Some("relative") => ApplyMode::Relative,
        Some(o) => return Err(format!("mode: unknown '{o}'; known: absolute, relative").into()),
    };
    let targets: BTreeSet<Id> = std::iter::once(clip).collect();
    t.apply_preset(preset, &targets, mode, ids).map(|_| ()).map_err(Into::into)
}

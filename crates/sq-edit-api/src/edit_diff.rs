// Swift: EditDiff.swift
//! What a commit changes in one sequence.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sq_core_model::{Clip, Project, Timeline};
use crate::project_state::TransitionState;
use sq_core_time::{Id, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// One clip as the diff sees it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipRef {
    /// Clip id.
    pub id: Id,
    /// Track holding the clip.
    pub track: Id,
    /// Shown name.
    pub name: String,
    /// Position on the track.
    pub start: Time,
    /// Length on the track.
    pub duration: Time,
    /// Portion of the source used.
    pub source: TimeRange,
    /// Whether the clip plays.
    pub enabled: bool,
}

/// A clip before and after.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Change {
    /// Clip id.
    pub id: Id,
    /// State before the commit.
    pub before: ClipRef,
    /// State after the commit.
    pub after: ClipRef,
}

/// One inspector parameter that differs after the commit (`before` / `after` absent: the parameter did not exist).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParamChange {
    /// Param path (`GET /v1/clip/{id}/params`).
    pub param: String,
    /// Static value and keyframes before.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<Value>,
    /// Static value and keyframes after.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<Value>,
}

/// The inspector parameters of one clip that differ.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipParamChanges {
    /// Clip id.
    pub clip: Id,
    /// The parameters.
    pub params: Vec<ParamChange>,
}

/// What a commit changes in one sequence: clips added, removed and changed (position, length, source range, track,
/// enabled), the sequence length before and after, and marker count changes. Sorted by start for stable output.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditDiff {
    /// Clips only the new state has.
    pub added: Vec<ClipRef>,
    /// Clips only the old state has.
    pub removed: Vec<ClipRef>,
    /// Clips in both states that differ.
    pub changed: Vec<Change>,
    /// Sequence length before.
    pub duration_before: Time,
    /// Sequence length after.
    pub duration_after: Time,
    /// Markers only the new state has.
    pub markers_added: i64,
    /// Markers only the old state has.
    pub markers_removed: i64,
    /// Media items shown with another pixel aspect after the commit; absent when none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pixel_aspect_changes: Option<i64>,
    /// Inspector parameters (motion, opacity, volume, effects, text layers) that differ, per clip; absent when none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub param_changes: Vec<ClipParamChanges>,
    /// Transitions only the new state has; absent when none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub transitions_added: Vec<TransitionState>,
    /// Transitions only the old state has; absent when none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub transitions_removed: Vec<TransitionState>,
}

fn order(a: &ClipRef, b: &ClipRef) -> std::cmp::Ordering {
    (a.start, a.id.to_string()).cmp(&(b.start, b.id.to_string()))
}

fn refs(t: &Timeline) -> BTreeMap<Id, ClipRef> {
    let mut out = BTreeMap::new();
    for tr in &t.tracks {
        for c in tr.clips() {
            out.insert(
                c.id,
                ClipRef {
                    id: c.id,
                    track: tr.id,
                    name: c.name.clone(),
                    start: c.start,
                    duration: c.duration(),
                    source: c.source,
                    enabled: c.is_enabled,
                },
            );
        }
    }
    out
}

fn clips_of(t: &Timeline) -> BTreeMap<Id, &Clip> {
    t.tracks.iter().flat_map(|tr| tr.clips().iter()).map(|c| (c.id, c)).collect()
}

/// path -> {value, keyframes} of every parameter of the clip.
fn param_values(c: &Clip) -> BTreeMap<String, Value> {
    let listing = crate::clip_params::clip_params_json(c);
    let list = listing.get("params").and_then(Value::as_array).cloned().unwrap_or_default();
    list.into_iter()
        .filter_map(|p| {
            let path = p.get("path")?.as_str()?.to_string();
            let mut v = json!({"value": p.get("value")});
            if let Some(k) = p.get("keyframes") {
                v["keyframes"] = k.clone();
            }
            Some((path, v))
        })
        .collect()
}

fn param_changes(before: &Timeline, after: &Timeline) -> Vec<ClipParamChanges> {
    let (b, a) = (clips_of(before), clips_of(after));
    let mut out = Vec::new();
    for (id, old) in &b {
        let Some(new) = a.get(id).filter(|n| *n != old) else { continue };
        let (pb, pa) = (param_values(old), param_values(new));
        let mut params = Vec::new();
        for path in pb.keys().chain(pa.keys().filter(|k| !pb.contains_key(*k))) {
            let (x, y) = (pb.get(path), pa.get(path));
            if x != y {
                params.push(ParamChange { param: path.clone(), before: x.cloned(), after: y.cloned() });
            }
        }
        if !params.is_empty() {
            out.push(ClipParamChanges { clip: *id, params });
        }
    }
    out
}

impl EditDiff {
    /// Whether nothing changed.
    pub fn is_empty(&self) -> bool {
        self.added.is_empty()
            && self.removed.is_empty()
            && self.changed.is_empty()
            && self.duration_before == self.duration_after
            && self.markers_added == 0
            && self.markers_removed == 0
            && self.pixel_aspect_changes.is_none()
            && self.param_changes.is_empty()
            && self.transitions_added.is_empty()
            && self.transitions_removed.is_empty()
    }

    /// The diff from `before` to `after`.
    pub fn new(before: &Timeline, after: &Timeline) -> EditDiff {
        let (b, a) = (refs(before), refs(after));
        let mut added: Vec<ClipRef> = a.values().filter(|r| !b.contains_key(&r.id)).cloned().collect();
        added.sort_by(order);
        let mut removed: Vec<ClipRef> = b.values().filter(|r| !a.contains_key(&r.id)).cloned().collect();
        removed.sort_by(order);
        let mut changed: Vec<Change> = b
            .values()
            .filter_map(|old| {
                let new = a.get(&old.id).filter(|new| *new != old)?;
                Some(Change { id: old.id, before: old.clone(), after: new.clone() })
            })
            .collect();
        changed.sort_by(|x, y| order(&x.before, &y.before));
        let mb: BTreeSet<Id> = before.markers.iter().map(|m| m.id).collect();
        let ma: BTreeSet<Id> = after.markers.iter().map(|m| m.id).collect();
        let (tb, ta) = (TransitionState::all(before), TransitionState::all(after));
        let transitions_added = ta.iter().filter(|x| !tb.iter().any(|y| y.id == x.id)).cloned().collect();
        let transitions_removed = tb.iter().filter(|x| !ta.iter().any(|y| y.id == x.id)).cloned().collect();
        EditDiff {
            added,
            removed,
            changed,
            duration_before: before.duration(),
            duration_after: after.duration(),
            markers_added: ma.difference(&mb).count() as i64,
            markers_removed: mb.difference(&ma).count() as i64,
            pixel_aspect_changes: None,
            param_changes: param_changes(before, after),
            transitions_added,
            transitions_removed,
        }
    }

    /// Counts media items whose shown pixel aspect differs between the two projects (`setPixelAspect` operations).
    pub fn note_media(&mut self, before: &Project, after: &Project) {
        let display = |m: &sq_core_model::MediaRef| m.info.as_ref()?.video.as_ref().map(|v| v.display_pixel_aspect());
        let n = after.media.iter().filter(|m| before.media(m.id).is_some_and(|old| display(old) != display(m))).count();
        self.pixel_aspect_changes = if n == 0 { None } else { Some(n as i64) };
    }
}

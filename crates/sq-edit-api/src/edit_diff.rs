// Swift: EditDiff.swift
//! What a commit changes in one sequence.

use serde::{Deserialize, Serialize};
use sq_core_model::{Project, Timeline};
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
        EditDiff {
            added,
            removed,
            changed,
            duration_before: before.duration(),
            duration_after: after.duration(),
            markers_added: ma.difference(&mb).count() as i64,
            markers_removed: mb.difference(&ma).count() as i64,
            pixel_aspect_changes: None,
        }
    }

    /// Counts media items whose shown pixel aspect differs between the two projects (`setPixelAspect` operations).
    pub fn note_media(&mut self, before: &Project, after: &Project) {
        let display = |m: &sq_core_model::MediaRef| m.info.as_ref()?.video.as_ref().map(|v| v.display_pixel_aspect());
        let n = after.media.iter().filter(|m| before.media(m.id).is_some_and(|old| display(old) != display(m))).count();
        self.pixel_aspect_changes = if n == 0 { None } else { Some(n as i64) };
    }
}

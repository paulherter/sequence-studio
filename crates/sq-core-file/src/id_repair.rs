// SPDX-License-Identifier: GPL-3.0-or-later

//! Duplicate ids in a saved sequence. Older builds minted sequential ids from several sources, so two clips (or tracks)
//! of one sequence could share an id, and selecting one found nothing. The repair works on the file's JSON before it is
//! decoded, so keys the model does not know stay with the element they belong to. The first holder of an id keeps it
//! (links and transitions that name it keep working); every later holder gets a fresh random id.

use serde_json::Value;
use sq_core_time::{IdSource, RandomIds};
use std::collections::BTreeSet;

/// A random id that is not in `taken`; it is added to it.
fn fresh(taken: &mut BTreeSet<String>) -> String {
    loop {
        let id = RandomIds.next_id().to_string();
        if taken.insert(id.to_uppercase()) {
            return id;
        }
    }
}

/// Gives every repeated clip id and track id of every sequence in `project` (the `project` object of a file) a fresh id,
/// after the first holder. Returns one line per repair.
pub(crate) fn repair_duplicate_ids(project: &mut Value) -> Vec<String> {
    let mut notes = Vec::new();
    let Some(timelines) = project.get_mut("timelines").and_then(Value::as_array_mut) else { return notes };
    for timeline in timelines {
        let name = timeline.get("name").and_then(Value::as_str).unwrap_or("").to_string();
        let Some(tracks) = timeline.get_mut("tracks").and_then(Value::as_array_mut) else { continue };
        // Every id of the sequence counts as taken, so a fresh one cannot land on a later element.
        let mut taken: BTreeSet<String> = BTreeSet::new();
        for track in tracks.iter() {
            taken.extend(track.get("id").and_then(Value::as_str).map(str::to_uppercase));
            let clips = track.get("clips").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
            taken.extend(clips.iter().filter_map(|c| c.get("id").and_then(Value::as_str)).map(str::to_uppercase));
        }
        let mut seen_tracks: BTreeSet<String> = BTreeSet::new();
        let mut seen_clips: BTreeSet<String> = BTreeSet::new();
        for track in tracks.iter_mut() {
            if let Some(old) = track.get("id").and_then(Value::as_str).map(str::to_string)
                && !seen_tracks.insert(old.to_uppercase())
            {
                let new = fresh(&mut taken);
                sq_os::errln!("SQREPAIR track id {old} repeated in sequence \"{name}\": a later track now has {new}");
                notes.push(format!("track {old} -> {new}"));
                track["id"] = Value::String(new);
            }
            let Some(clips) = track.get_mut("clips").and_then(Value::as_array_mut) else { continue };
            for clip in clips {
                let Some(old) = clip.get("id").and_then(Value::as_str).map(str::to_string) else { continue };
                if seen_clips.insert(old.to_uppercase()) {
                    continue;
                }
                let new = fresh(&mut taken);
                sq_os::errln!("SQREPAIR clip id {old} repeated in sequence \"{name}\": a later clip now has {new}");
                notes.push(format!("clip {old} -> {new}"));
                clip["id"] = Value::String(new);
            }
        }
    }
    notes
}

#[cfg(test)]
mod tests;

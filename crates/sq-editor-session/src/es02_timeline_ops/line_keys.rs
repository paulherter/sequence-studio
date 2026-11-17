//! Keys on the opacity / volume rubber bands as selected in the timeline, and their frame nudges.

use std::collections::BTreeSet;

use sq_core_audio::audio_gain::{AudioGain, MIN_KEY_GAP};
use sq_core_model::Clip;
use sq_core_time::{Id, Time};

use super::prelude::*;
use crate::{Change, EditorSession};

/// Which rubber band a key belongs to.
// Swift: EditorSession+LineKeys.swift:5
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum LineKeyProperty {
    Opacity,
    Volume,
}

/// One key on a clip's opacity or volume line, as selected in the timeline.
// Swift: EditorSession+LineKeys.swift:8
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LineKeyRef {
    // Swift: EditorSession+LineKeys.swift:9
    pub clip: Id,
    // Swift: EditorSession+LineKeys.swift:10
    pub property: LineKeyProperty,
    // Swift: EditorSession+LineKeys.swift:11
    pub key: Id,
}

impl LineKeyRef {
    // Swift: EditorSession+LineKeys.swift:12
    pub fn new(clip: Id, property: LineKeyProperty, key: Id) -> LineKeyRef {
        LineKeyRef { clip, property, key }
    }
}

impl EditorSession {
    /// The selected keys of the opacity / volume lines.
    // Swift: EditorSession+LineKeys.swift:7
    pub fn selected_line_keys(&self) -> &BTreeSet<LineKeyRef> {
        &self.selected_line_keys
    }

    /// Selects keys on the opacity / volume lines (a click on a key; Shift-click extends). Keys follow the clip
    /// selection: only keys of selected clips are kept, and changing the clip selection clears them. Frame nudges
    /// (`nudge_selection`) then move these keys instead of the clips.
    // Swift: EditorSession+LineKeys.swift:21
    pub fn select_line_keys(&mut self, keys: &BTreeSet<LineKeyRef>) {
        let next: BTreeSet<LineKeyRef> = keys.iter().filter(|k| self.selection.contains(&k.clip)).copied().collect();
        if next == self.selected_line_keys {
            return;
        }
        self.selected_line_keys = next;
        self.notify(Change::SELECTION);
    }

    /// Moves the selected line keys by `n` frames in time, keeping their levels. Keys stay inside the clip and never
    /// cross or land on a neighbor. Returns false when no key is selected (the caller nudges clips instead).
    pub(crate) fn nudge_line_keys(&mut self, frames: i64) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let refs: Vec<LineKeyRef> = self
            .selected_line_keys
            .iter()
            .filter(|r| {
                self.selection.contains(&r.clip) && t.tracks.iter().any(|tr| tr.clips().iter().any(|c| c.id == r.clip))
            })
            .copied()
            .collect();
        if refs.is_empty() || frames == 0 {
            return !refs.is_empty();
        }
        let d = t.frame_duration() * frames;
        self.attempt("Nudge Keyframes", None, |tl| {
            let fd = tl.frame_duration();
            let clip_ids: BTreeSet<Id> = refs.iter().map(|r| r.clip).collect();
            for clip_id in clip_ids {
                let Some(mut c) = tl.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == clip_id).cloned() else {
                    continue;
                };
                for p in [LineKeyProperty::Opacity, LineKeyProperty::Volume] {
                    let ids: BTreeSet<Id> =
                        refs.iter().filter(|r| r.clip == clip_id && r.property == p).map(|r| r.key).collect();
                    if !ids.is_empty() {
                        shift_keys(&ids, p, &mut c, d, fd);
                    }
                }
                tl.replace_clip(c)?;
            }
            Ok(())
        });
        true
    }
}

fn shift_keys(ids: &BTreeSet<Id>, p: LineKeyProperty, c: &mut Clip, d: Time, _frame_duration: Time) {
    let keys = |c: &Clip| match p {
        LineKeyProperty::Opacity => c.animation.opacity.track.keys.clone(),
        LineKeyProperty::Volume => c.animation.volume.track.keys.clone(),
    };
    // Leading keys first, so a run of selected keys moves as one block instead of tripping over itself.
    let mut order: Vec<Id> = keys(c).iter().filter(|k| ids.contains(&k.id)).map(|k| k.id).collect();
    if d > Time::ZERO {
        order.reverse();
    }
    for id in order {
        let all = keys(c);
        let Some(i) = all.iter().position(|k| k.id == id) else { continue };
        let mut t = (all[i].time + d).max(Time::ZERO).min(c.duration());
        if i > 0 {
            t = t.max(all[i - 1].time + MIN_KEY_GAP);
        }
        if i + 1 < all.len() {
            t = t.min(all[i + 1].time - MIN_KEY_GAP);
        }
        match p {
            LineKeyProperty::Opacity => c.move_opacity_key(id, t, all[i].value, None),
            LineKeyProperty::Volume => c.move_volume_key(id, t, AudioGain::db_from_linear(all[i].value)),
        }
    }
}

// Swift: Captions.swift (the `Timeline` caption verbs that touch an item list)
//! The caption verbs of Swift `Timeline`: thin track wrappers over the item-list operations (`CaptionItemsExt`).

use std::collections::BTreeSet;

use crate::caption_handover::TimelineCaptionsExt;
use crate::caption_items::CaptionItemsExt;
use sq_core_model::{CaptionItem, CaptionPosition, CaptionTrack, ClipEdge, EditError, KaraokeStyle, Timeline};
use sq_core_time::{Id, IdSource, Time, TimeRange};

fn track_index(t: &Timeline, id: Id) -> Result<usize, EditError> {
    let i = t.caption_tracks.iter().position(|c| c.id == id).ok_or(EditError::ClipNotFound)?;
    if t.caption_tracks[i].is_locked { Err(EditError::TrackLocked) } else { Ok(i) }
}

fn location(t: &Timeline, id: Id) -> Result<usize, EditError> {
    let i =
        t.caption_tracks.iter().position(|c| c.items().iter().any(|x| x.id == id)).ok_or(EditError::ClipNotFound)?;
    if t.caption_tracks[i].is_locked { Err(EditError::TrackLocked) } else { Ok(i) }
}

/// A new empty caption track; `items` can only be set through the model's JSON shape (read-only in Rust).
fn new_track(id: Id, name: String, like: Option<&CaptionTrack>) -> Result<CaptionTrack, EditError> {
    let mut v = serde_json::json!({"id": id, "name": name});
    if let Some(f) = like {
        v["styleRef"] = f.style_ref.clone().into();
        v["animationRef"] = f.animation_ref.clone().into();
        if let Ok(k) = serde_json::to_value(&f.karaoke) {
            v["karaoke"] = k;
        }
        if let Some(l) = &f.look_id {
            v["lookID"] = l.clone().into();
        }
    }
    serde_json::from_value(v).map_err(|_| EditError::EmptyClip)
}

/// The unlocked caption tracks that hold any of `ids` (a locked one refuses the edit).
fn tracks_holding(t: &Timeline, ids: &BTreeSet<Id>) -> Result<Vec<usize>, EditError> {
    let mut out = Vec::new();
    for (i, c) in t.caption_tracks.iter().enumerate() {
        if c.items().iter().any(|x| ids.contains(&x.id)) {
            if c.is_locked {
                return Err(EditError::TrackLocked);
            }
            out.push(i);
        }
    }
    Ok(out)
}

/// Timeline caption verbs (Swift `Timeline` extension in `Captions.swift`).
pub trait TimelineCaptionEditsExt {
    fn replace_captions(
        &mut self,
        items: Vec<CaptionItem>,
        track: Option<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
    fn add_caption_track(&mut self, ids: &mut dyn IdSource) -> Id;
    fn set_caption_text(&mut self, id: Id, lines: Vec<String>) -> Result<(), EditError>;
    /// Moves a caption (clamped by neighbors and 0). Returns the applied start.
    fn move_caption(&mut self, id: Id, to: Time) -> Result<Time, EditError>;
    /// Moves one edge of a caption (clamped by neighbors, 0 and one frame minimum). Returns the new range.
    fn trim_caption(&mut self, id: Id, edge: ClipEdge, to: Time) -> Result<TimeRange, EditError>;
    /// Removes the caption from its (unlocked) track.
    fn delete_caption(&mut self, id: Id) -> Result<(), EditError>;
    fn split_caption(&mut self, id: Id, t: Time, ids: &mut dyn IdSource) -> Result<(Id, Id), EditError>;
    fn merge_captions(&mut self, ids: &BTreeSet<Id>) -> Result<Id, EditError>;
    fn add_caption(
        &mut self,
        at: Time,
        duration: Time,
        track: Option<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
    fn replace_caption_text(
        &mut self,
        find: &str,
        with: &str,
        case_sensitive: bool,
        track: Option<Id>,
    ) -> Result<usize, EditError>;
    fn set_caption_style(
        &mut self,
        style_ref: &str,
        animation_ref: Option<&str>,
        track: Id,
        keeps_look: bool,
    ) -> Result<(), EditError>;
    fn set_caption_item_style(&mut self, ids: &BTreeSet<Id>, style_ref: Option<&str>) -> Result<(), EditError>;
    fn set_caption_item_animation(&mut self, ids: &BTreeSet<Id>, animation_ref: Option<&str>) -> Result<(), EditError>;
    fn reset_caption_items_to_track_look(&mut self, ids: &BTreeSet<Id>) -> Result<(), EditError>;
    fn set_caption_item_position(&mut self, ids: &BTreeSet<Id>, p: Option<CaptionPosition>) -> Result<(), EditError>;
    fn set_track_karaoke(&mut self, karaoke: Option<KaraokeStyle>, track: Id) -> Result<(), EditError>;
}

impl TimelineCaptionEditsExt for Timeline {
    fn replace_captions(
        &mut self,
        items: Vec<CaptionItem>,
        track: Option<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let target = match track {
            Some(id) => Some(id),
            None => self.caption_tracks.first().map(|t| t.id),
        };
        if let Some(id) = target {
            let i = track_index(self, id)?;
            self.caption_tracks[i].with_items(|v| v.replace_all(items))?;
            return Ok(id);
        }
        let mut t = new_track(ids.next_id(), self.next_caption_track_name(), None)?;
        t.with_items(|v| v.replace_all(items))?;
        let id = t.id;
        self.caption_tracks.push(t);
        Ok(id)
    }

    fn add_caption_track(&mut self, ids: &mut dyn IdSource) -> Id {
        let id = ids.next_id();
        let name = self.next_caption_track_name();
        match new_track(id, name, self.caption_tracks.first()) {
            Ok(t) => {
                self.caption_tracks.push(t);
                id
            }
            Err(_) => id,
        }
    }

    fn set_caption_text(&mut self, id: Id, lines: Vec<String>) -> Result<(), EditError> {
        let i = location(self, id)?;
        self.caption_tracks[i].with_items(|v| v.set_lines(id, lines));
        Ok(())
    }

    fn move_caption(&mut self, id: Id, to: Time) -> Result<Time, EditError> {
        let i = location(self, id)?;
        self.caption_tracks[i].with_items(|v| v.move_item(id, to)).ok_or(EditError::ClipNotFound)
    }

    fn trim_caption(&mut self, id: Id, edge: ClipEdge, to: Time) -> Result<TimeRange, EditError> {
        let i = location(self, id)?;
        let fd = self.frame_duration();
        self.caption_tracks[i].with_items(|v| v.trim(id, edge, to, fd)).ok_or(EditError::ClipNotFound)
    }

    fn delete_caption(&mut self, id: Id) -> Result<(), EditError> {
        let i = location(self, id)?;
        self.caption_tracks[i].with_items(|v| v.remove_item(id));
        Ok(())
    }

    fn split_caption(&mut self, id: Id, t: Time, ids: &mut dyn IdSource) -> Result<(Id, Id), EditError> {
        let i = location(self, id)?;
        self.caption_tracks[i].with_items(|v| v.split_at(id, t, ids)).ok_or(EditError::EmptyClip)
    }

    fn merge_captions(&mut self, ids: &BTreeSet<Id>) -> Result<Id, EditError> {
        let first = ids.iter().next().ok_or(EditError::ClipNotFound)?;
        let i = location(self, *first)?;
        if !ids.iter().all(|id| self.caption_tracks[i].items().iter().any(|x| x.id == *id)) {
            return Err(EditError::WrongTrackKind);
        }
        self.caption_tracks[i].with_items(|v| v.merge(ids)).ok_or(EditError::EmptyClip)
    }

    fn add_caption(
        &mut self,
        at: Time,
        duration: Time,
        track: Option<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let id = match track.or_else(|| self.caption_tracks.first().map(|t| t.id)) {
            Some(id) => id,
            None => self.replace_captions(Vec::new(), None, ids)?,
        };
        let i = track_index(self, id)?;
        let (style, animation) =
            (self.caption_tracks[i].style_ref.clone(), self.caption_tracks[i].animation_ref.clone());
        self.caption_tracks[i].with_items(|v| v.add(at, duration, (&style, &animation), ("", ""), ids))
    }

    fn replace_caption_text(
        &mut self,
        find: &str,
        with: &str,
        case_sensitive: bool,
        track: Option<Id>,
    ) -> Result<usize, EditError> {
        if let Some(track) = track {
            let i = track_index(self, track)?;
            return Ok(if find == with {
                0
            } else {
                self.caption_tracks[i].with_items(|v| v.replace_text(find, with, case_sensitive))
            });
        }
        // Locked tracks are skipped (and not counted); only when every track is locked is the edit refused.
        if !self.caption_tracks.is_empty() && self.caption_tracks.iter().all(|t| t.is_locked) {
            return Err(EditError::TrackLocked);
        }
        if find == with {
            return Ok(0);
        }
        let mut n = 0;
        for t in self.caption_tracks.iter_mut().filter(|t| !t.is_locked) {
            n += t.with_items(|v| v.replace_text(find, with, case_sensitive));
        }
        Ok(n)
    }

    fn set_caption_style(
        &mut self,
        style_ref: &str,
        animation_ref: Option<&str>,
        track: Id,
        keeps_look: bool,
    ) -> Result<(), EditError> {
        let i = track_index(self, track)?;
        let t = &mut self.caption_tracks[i];
        t.style_ref = style_ref.to_string();
        if let Some(a) = animation_ref {
            t.animation_ref = a.to_string();
        }
        t.with_items(|v| v.set_style(style_ref, animation_ref));
        // Choosing a style forgets the Look the track had; an edit on top of the Look (`keeps_look`) keeps it.
        if !keeps_look {
            t.look_id = None;
        }
        Ok(())
    }

    fn set_caption_item_style(&mut self, ids: &BTreeSet<Id>, style_ref: Option<&str>) -> Result<(), EditError> {
        if ids.is_empty() {
            return Ok(());
        }
        tracks_holding(self, ids)?;
        for t in &mut self.caption_tracks {
            let (s, a) = (t.style_ref.clone(), t.animation_ref.clone());
            t.with_items(|v| v.set_item_style(ids, style_ref, &s, &a));
        }
        Ok(())
    }

    fn set_caption_item_animation(&mut self, ids: &BTreeSet<Id>, animation_ref: Option<&str>) -> Result<(), EditError> {
        if ids.is_empty() {
            return Ok(());
        }
        tracks_holding(self, ids)?;
        for t in &mut self.caption_tracks {
            let (s, a) = (t.style_ref.clone(), t.animation_ref.clone());
            t.with_items(|v| v.set_item_animation(ids, animation_ref, &s, &a));
        }
        Ok(())
    }

    fn reset_caption_items_to_track_look(&mut self, ids: &BTreeSet<Id>) -> Result<(), EditError> {
        if ids.is_empty() {
            return Ok(());
        }
        tracks_holding(self, ids)?;
        for t in &mut self.caption_tracks {
            let (s, a) = (t.style_ref.clone(), t.animation_ref.clone());
            t.with_items(|v| v.reset_items_to_track_look(ids, &s, &a));
        }
        Ok(())
    }

    fn set_caption_item_position(&mut self, ids: &BTreeSet<Id>, p: Option<CaptionPosition>) -> Result<(), EditError> {
        if ids.is_empty() {
            return Ok(());
        }
        tracks_holding(self, ids)?;
        for t in &mut self.caption_tracks {
            t.with_items(|v| v.set_item_position(ids, p));
        }
        Ok(())
    }

    fn set_track_karaoke(&mut self, karaoke: Option<KaraokeStyle>, track: Id) -> Result<(), EditError> {
        let i = track_index(self, track)?;
        self.caption_tracks[i].karaoke = karaoke;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_role::tests::timeline;
    use crate::caption_item::tests::{item, range};
    use sq_core_time::SequentialIds;

    fn with_items(items: Vec<CaptionItem>) -> Timeline {
        let mut tl = timeline(vec![]);
        tl.set_frame_duration(Time::new(1, 30));
        let mut ids = SequentialIds::default();
        tl.replace_captions(items, None, &mut ids).unwrap();
        tl
    }

    #[test]
    fn replace_captions_creates_the_first_track_and_refuses_overlaps() {
        let mut tl = with_items(vec![item(&["a"], range(0, 1000)), item(&["b"], range(1000, 2000))]);
        assert_eq!(tl.caption_tracks.len(), 1);
        assert_eq!(tl.caption_tracks[0].name, "Captions 1");
        let clash = vec![item(&["a"], range(0, 1000)), item(&["b"], range(500, 2000))];
        assert_eq!(tl.replace_captions(clash, None, &mut SequentialIds::default()), Err(EditError::Collision));
        assert_eq!(tl.caption_tracks[0].items().len(), 2);
    }

    #[test]
    fn move_trim_and_delete_follow_the_item_rules_and_refuse_a_locked_track() {
        let (a, b) = (item(&["a"], range(0, 1000)), item(&["b"], range(1000, 2000)));
        let mut tl = with_items(vec![a.clone(), b.clone()]);
        // The neighbor wins: b cannot move onto a.
        assert_eq!(tl.move_caption(b.id, Time::ZERO), Ok(range(0, 1000).end()));
        assert_eq!(tl.trim_caption(a.id, ClipEdge::Tail, Time::new(5, 1)), Ok(range(0, 1000)));
        tl.delete_caption(a.id).unwrap();
        assert_eq!(tl.caption_tracks[0].items().len(), 1);
        tl.caption_tracks[0].is_locked = true;
        assert_eq!(tl.delete_caption(b.id), Err(EditError::TrackLocked));
        assert_eq!(tl.delete_caption(a.id), Err(EditError::ClipNotFound));
    }
}

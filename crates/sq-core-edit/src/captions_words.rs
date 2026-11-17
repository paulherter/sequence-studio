//! Port of the `Timeline` half of `Captions+Words.swift`: word edits, split, join, retime and find / replace on the caption
//! tracks. The item-level code is in `sq-core-audio` (`CaptionItemsExt`, `CaptionWordEditExt`).

use sq_core_audio::{CaptionItemsExt as _, CaptionNeighbor, CaptionTextMatch, CaptionWordEditExt as _};
use sq_core_model::{ClipEdge, EditError, Timeline};
use sq_core_time::{Id, IdSource, Time, TimeRange};

/// Index of the caption track holding caption `id`; `ClipNotFound` for an unknown caption, `TrackLocked` for a locked track.
fn caption_location(tl: &Timeline, id: Id) -> Result<usize, EditError> {
    let i =
        tl.caption_tracks.iter().position(|t| t.items().iter().any(|c| c.id == id)).ok_or(EditError::ClipNotFound)?;
    if tl.caption_tracks[i].is_locked {
        return Err(EditError::TrackLocked);
    }
    Ok(i)
}

/// `extension Timeline` of `Captions+Words.swift`.
pub trait TimelineCaptionWordsExt {
    /// Replaces one word of a caption by `text`: several words when it holds spaces, deletion when it is empty. Returns the
    /// number of words that stand there now.
    fn set_caption_word(&mut self, id: Id, index: usize, text: &str) -> Result<usize, EditError>;

    /// Deletes one word; its time becomes a pause. The caption goes with its last word.
    fn delete_caption_word(&mut self, id: Id, index: usize) -> Result<(), EditError>;

    /// Inserts the words of `text` before word `index` (`tokens.len()` appends). Returns the number inserted.
    fn insert_caption_word(&mut self, id: Id, index: usize, text: &str) -> Result<usize, EditError>;

    /// Splits a caption at a word boundary: word `index` starts the second caption. Word timings stay with their words.
    fn split_caption(&mut self, id: Id, before_word: usize, ids: &mut dyn IdSource) -> Result<(Id, Id), EditError>;

    /// Joins a caption with the one before or after it (word timings are kept). Returns the joined caption's id.
    fn join_caption(&mut self, id: Id, with: CaptionNeighbor) -> Result<Id, EditError>;

    /// Moves one edge of a word to `t` (clamped at the neighboring word and the caption, one frame minimum, nothing
    /// ripples). Returns the word's new range.
    fn retime_caption_word(
        &mut self,
        id: Id,
        index: usize,
        edge: ClipEdge,
        t: Time,
        rolling: bool,
    ) -> Result<TimeRange, EditError>;

    /// Every match of `find` on the caption tracks (one track with `track`), in time order. Locked tracks are searched too;
    /// replacing there fails.
    fn caption_text_matches(&self, find: &str, case_sensitive: bool, track: Option<Id>) -> Vec<CaptionTextMatch>;

    /// Replaces one match (from `caption_text_matches` of the current timeline) by `new`; word timings follow the text.
    fn replace_caption_match(&mut self, m: &CaptionTextMatch, new: &str) -> Result<(), EditError>;
}

impl TimelineCaptionWordsExt for Timeline {
    fn set_caption_word(&mut self, id: Id, index: usize, text: &str) -> Result<usize, EditError> {
        let i = caption_location(self, id)?;
        self.caption_tracks[i].with_items(|items| items.set_word(id, index, text)).ok_or(EditError::ClipNotFound)
    }

    fn delete_caption_word(&mut self, id: Id, index: usize) -> Result<(), EditError> {
        self.set_caption_word(id, index, "").map(|_| ())
    }

    fn insert_caption_word(&mut self, id: Id, index: usize, text: &str) -> Result<usize, EditError> {
        let i = caption_location(self, id)?;
        self.caption_tracks[i].with_items(|items| items.insert_word(id, index, text)).ok_or(EditError::ClipNotFound)
    }

    fn split_caption(&mut self, id: Id, before_word: usize, ids: &mut dyn IdSource) -> Result<(Id, Id), EditError> {
        let i = caption_location(self, id)?;
        let fd = self.frame_duration();
        let snap = move |t: Time| t.snapped(fd);
        self.caption_tracks[i]
            .with_items(|items| items.split_before_word(id, before_word, &snap, ids))
            .ok_or(EditError::EmptyClip)
    }

    fn join_caption(&mut self, id: Id, with: CaptionNeighbor) -> Result<Id, EditError> {
        let i = caption_location(self, id)?;
        self.caption_tracks[i].with_items(|items| {
            let other = items.neighbor_of(id, with).map(|c| c.id).ok_or(EditError::ClipNotFound)?;
            items.merge(&[id, other].into()).ok_or(EditError::EmptyClip)
        })
    }

    fn retime_caption_word(
        &mut self,
        id: Id,
        index: usize,
        edge: ClipEdge,
        t: Time,
        rolling: bool,
    ) -> Result<TimeRange, EditError> {
        let i = caption_location(self, id)?;
        let min = self.frame_duration();
        self.caption_tracks[i]
            .with_items(|items| items.retime_word(id, index, edge, t, min, rolling))
            .ok_or(EditError::ClipNotFound)
    }

    fn caption_text_matches(&self, find: &str, case_sensitive: bool, track: Option<Id>) -> Vec<CaptionTextMatch> {
        if find.is_empty() {
            return Vec::new();
        }
        let mut out: Vec<CaptionTextMatch> = Vec::new();
        for t in self.caption_tracks.iter().filter(|t| track.is_none_or(|id| t.id == id)) {
            for item in t.items() {
                for m in item.text_matches(find, case_sensitive) {
                    out.push(CaptionTextMatch {
                        track: t.id,
                        caption: item.id,
                        line: m.line,
                        range: m.range,
                        words: m.words,
                        time: item.range.start,
                    });
                }
            }
        }
        // Stable by time: matches of one caption keep their reading order.
        out.sort_by_key(|m| m.time);
        out
    }

    fn replace_caption_match(&mut self, m: &CaptionTextMatch, new: &str) -> Result<(), EditError> {
        let i = caption_location(self, m.caption)?;
        let ok = self.caption_tracks[i].with_items(|items| {
            let Some(k) = items.iter().position(|c| c.id == m.caption) else { return false };
            if !items[k].replace_characters(m.range.clone(), m.line, new) {
                return false;
            }
            if items[k].tokens().is_empty() {
                items.remove(k); // the caption goes with its last word
            }
            true
        });
        if ok { Ok(()) } else { Err(EditError::ClipNotFound) }
    }
}

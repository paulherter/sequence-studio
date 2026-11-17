// Swift: TimelinePanel+CaptionWords.swift
//! Correcting captions on the caption track, translated from `TimelineView+CaptionWords`: the inline word field, Return
//! and Delete on the selected word, the word items of the context menu. The edits are core (`Captions+Words.swift`);
//! each one is one `Commit` (one undo step) through `interaction.commit_caption_edit`.
//!
//! The inline field over a word on the caption track (the Mac `CaptionWordEditor`): Return takes the text, Esc drops it,
//! Tab and Shift-Tab take it and move on to the next or previous word; a press elsewhere takes it too.

use crate::action::TimelineAction;
use crate::geom::RectExt as _;
use crate::panel::TimelinePanel;
use sq_core_audio::caption_handover::TimelineCaptionsExt as _;
use sq_core_audio::caption_words::CaptionNeighbor;
use sq_core_edit::captions_words::TimelineCaptionWordsExt as _;
use sq_core_model::{CaptionItem, CaptionTrack, Timeline};
use sq_core_time::{Id, Time};
use sq_draw::inspector::text_field_control::{Alignment, TAB, TextFieldControl};
use sq_draw::{Canvas, InputKey, InputModifiers, UiCx};
use sq_timeline_ui::{CaptionRow, CaptionWordLayout, CaptionWordRef, TimelineGeometry, TimelineZoom};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::spacing;
use std::collections::BTreeSet;

/// What the field stands on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CaptionWordTarget {
    /// Retype this word.
    Word(CaptionWordRef),
    /// Type new words that go before word `at` (`tokens.count`: at the end).
    Insert { caption: Id, at: usize },
}

impl CaptionWordTarget {
    pub(crate) fn caption(&self) -> Id {
        match self {
            CaptionWordTarget::Word(r) => r.caption,
            CaptionWordTarget::Insert { caption, .. } => *caption,
        }
    }
}

/// The inline field over a word on the caption track.
pub(crate) struct CaptionWordField {
    pub target: CaptionWordTarget,
    /// The caption's words when the field opened: when they differ later (an undo, another panel), the field no longer
    /// stands on its word and what was typed is dropped.
    pub opened: Vec<String>,
    pub control: TextFieldControl,
}

impl CaptionWordField {
    /// The word hidden under the field while it is retyped.
    pub(crate) fn hidden_word(&self, caption: Id) -> Option<usize> {
        match self.target {
            CaptionWordTarget::Word(r) if r.caption == caption => Some(r.index),
            _ => None,
        }
    }
}

struct CaptionAt<'a> {
    row: CaptionRow,
    item: &'a CaptionItem,
    track: &'a CaptionTrack,
}

impl TimelinePanel {
    fn caption_at(&self, id: Id) -> Option<CaptionAt<'_>> {
        let (row, item) = CaptionWordLayout::locate(id, &self.timeline, &self.geometry)?;
        let track = self.timeline.caption_track(row.track)?;
        Some(CaptionAt { row, item, track })
    }

    /// True while a word field is open (the panel takes every key).
    pub fn is_editing_word(&self) -> bool {
        self.word_field.is_some()
    }

    pub(crate) fn has_visible_word_selection(&self) -> bool {
        let Some(r) = self.interaction.word_selection() else { return false };
        let Some(c) = self.caption_at(r.caption) else { return false };
        CaptionWordLayout::shows_words(c.item, &self.geometry)
    }

    /// True when the caption's words are shown, or would be at a zoom this timeline can reach.
    pub(crate) fn can_show_words(&self, item: &CaptionItem) -> bool {
        if CaptionWordLayout::shows_words(item, &self.geometry) {
            return true;
        }
        let mut reached = self.geometry.clone();
        reached.points_per_second = TimelineZoom::clamp(CaptionWordLayout::zoom_for_words(item), &self.zoom_limits());
        CaptionWordLayout::shows_words(item, &reached)
    }

    // MARK: Opening

    /// Double-click on a caption: the word under the pointer becomes a field (a caption drawn as one block is zoomed in
    /// to word level first). `None`, with the zoom untouched, when there is no word to edit there (the caller opens the
    /// Text panel).
    pub(crate) fn begin_word_editing_at(&mut self, p: CGPoint, id: Id) -> Option<Vec<TimelineAction>> {
        {
            let c = self.caption_at(id)?;
            if c.track.is_locked || c.item.tokens().is_empty() || !self.can_show_words(c.item) {
                return None;
            }
        }
        let (zoom, scroll) = (self.geometry.points_per_second, self.geometry.scroll_x);
        let item = self.caption_at(id)?.item.clone();
        if !CaptionWordLayout::shows_words(&item, &self.geometry) {
            self.set_zoom(CaptionWordLayout::zoom_for_words(&item), Some(p.x));
        }
        let out = CaptionWordLayout::hit(p, id, &self.timeline, &self.geometry)
            .and_then(|hit| self.begin_word_editing(hit.word));
        if out.is_none() {
            self.geometry.points_per_second = zoom;
            self.geometry.scroll_x = scroll;
        }
        out
    }

    /// Opens the field on one word (zooms to word level and scrolls it into view when needed). `None` when it cannot.
    pub fn begin_word_editing(&mut self, r: CaptionWordRef) -> Option<Vec<TimelineAction>> {
        let mut out = self.finish_word_field(true, 0);
        let none_or = |out: Vec<TimelineAction>| if out.is_empty() { None } else { Some(out) };
        let (item, locked) = match self.caption_at(r.caption) {
            Some(c) => (c.item.clone(), c.track.is_locked),
            None => return none_or(out),
        };
        if locked {
            return none_or(out);
        }
        let words = item.effective_words();
        if r.index >= words.len() || !self.can_show_words(&item) {
            return none_or(out);
        }
        self.show_word_level(&item, words[r.index].range.start);
        if !CaptionWordLayout::shows_words(&item, &self.geometry) {
            return none_or(out);
        }
        out.extend(self.select_word(Some(r)));
        self.open_word_field(CaptionWordField {
            target: CaptionWordTarget::Word(r),
            opened: item.tokens(),
            control: TextFieldControl::new(&words[r.index].text),
        });
        Some(out)
    }

    /// Opens an empty field at a word boundary: what is typed goes before word `index`.
    pub fn begin_word_insert(&mut self, id: Id, index: usize) -> Option<Vec<TimelineAction>> {
        let out = self.finish_word_field(true, 0);
        let none_or = |out: Vec<TimelineAction>| if out.is_empty() { None } else { Some(out) };
        let (item, locked) = match self.caption_at(id) {
            Some(c) => (c.item.clone(), c.track.is_locked),
            None => return none_or(out),
        };
        if locked {
            return none_or(out);
        }
        let words = item.effective_words();
        if index > words.len() || !self.can_show_words(&item) {
            return none_or(out);
        }
        let at = if index < words.len() {
            words[index].range.start
        } else {
            words.last().map_or(item.range.end(), |w| w.range.end())
        };
        self.show_word_level(&item, at);
        if !CaptionWordLayout::shows_words(&item, &self.geometry) {
            return none_or(out);
        }
        self.open_word_field(CaptionWordField {
            target: CaptionWordTarget::Insert { caption: id, at: index },
            opened: item.tokens(),
            control: TextFieldControl::new(""),
        });
        Some(out)
    }

    /// Return with a word selected: opens the same field a double-click opens.
    pub(crate) fn edit_selected_word(&mut self) -> Option<Vec<TimelineAction>> {
        let r = self.interaction.word_selection()?;
        if self.word_field.is_some()
            || self.gesture.is_some()
            || !self.has_visible_word_selection()
            || !self.selection.is_empty()
            || self.caption_selection != BTreeSet::from([r.caption])
        {
            return None;
        }
        self.begin_word_editing(r)
    }

    fn open_word_field(&mut self, mut f: CaptionWordField) {
        f.control.alignment = Alignment::Center;
        f.control.mouse_down(None, 1); // editing, everything selected (the Mac field selects all)
        self.word_field = Some(f);
    }

    fn show_word_level(&mut self, item: &CaptionItem, t: Time) {
        if !CaptionWordLayout::shows_words(item, &self.geometry) {
            let x = self.geometry.x(t);
            let min_x = TimelineGeometry::CONTENT_ORIGIN_X;
            self.set_zoom(CaptionWordLayout::zoom_for_words(item), Some(x.max(min_x).min(self.size.width.max(min_x))));
        }
        self.reveal_time(t);
    }

    /// Scrolls so that `t` is inside the visible tracks (a third in from the left); nothing when it already is.
    pub(crate) fn reveal_time(&mut self, t: Time) {
        let min_x = TimelineGeometry::CONTENT_ORIGIN_X;
        let x = self.geometry.x(t);
        let width = (self.size.width - min_x).max(1.0);
        let margin = (f64::from(spacing::LG) * 2.0).min(width / 4.0);
        if !(x < min_x + margin || x > self.size.width - margin) {
            return;
        }
        self.geometry.scroll_x = (self.geometry.scroll_x + x - (min_x + width / 3.0)).max(0.0);
        self.clamp_scroll();
    }

    /// `TimelineView.selectWord`: the word and its caption become the selection.
    pub(crate) fn select_word(&mut self, r: Option<CaptionWordRef>) -> Vec<TimelineAction> {
        self.feed_interaction();
        if let Some(r) = r {
            self.interaction.set_selection(BTreeSet::new());
            self.interaction.set_caption_selection(BTreeSet::from([r.caption]));
        }
        self.interaction.set_word_selection(r);
        self.refresh_from_interaction()
    }

    // MARK: The open field

    /// Where the field sits: over its word (never narrower than a short word needs), or centered on the boundary new
    /// words go to. `None` when the word is gone.
    pub(crate) fn word_field_frame(&self) -> Option<CGRect> {
        let f = self.word_field.as_ref()?;
        let c = self.caption_at(f.target.caption())?;
        let words = c.item.effective_words();
        let min_width = 64.0;
        match f.target {
            CaptionWordTarget::Word(r) => {
                let w = words.get(r.index)?;
                let b = CaptionWordLayout::box_of(&w.range, &self.geometry, &c.row);
                let width = (b.width + 2.0 * f64::from(spacing::XS)).max(min_width);
                Some(CGRect::new(b.mid_x() - width / 2.0, c.row.y, width, c.row.height))
            }
            CaptionWordTarget::Insert { at, .. } => {
                if at > words.len() {
                    return None;
                }
                let t = if at < words.len() {
                    words[at].range.start
                } else {
                    words.last().map_or(c.item.range.end(), |w| w.range.end())
                };
                Some(CGRect::new(self.geometry.x(t) - min_width / 2.0, c.row.y, min_width, c.row.height))
            }
        }
    }

    /// True while the caption the field was opened on still has the words it had then.
    fn field_still_stands(&self, f: &CaptionWordField) -> bool {
        match self.caption_at(f.target.caption()) {
            Some(c) => !c.track.is_locked && c.item.tokens() == f.opened,
            None => false,
        }
    }

    /// The timeline changed from outside (undo, another panel): the field goes when its word is gone.
    pub(crate) fn word_field_follows_timeline(&mut self) {
        let gone = match &self.word_field {
            Some(f) => !self.field_still_stands(f) || self.word_field_frame().is_none(),
            None => false,
        };
        if gone {
            self.word_field = None;
        }
    }

    /// Keys while the field is open: every key is the field's.
    pub(crate) fn word_field_key(&mut self, k: InputKey, mods: InputModifiers, ui: &mut UiCx) -> Vec<TimelineAction> {
        let Some(f) = self.word_field.as_mut() else { return Vec::new() };
        if k == TAB {
            return self.finish_word_field(true, if mods.contains(InputModifiers::SHIFT) { -1 } else { 1 });
        }
        match k {
            InputKey::Enter => self.finish_word_field(true, 0),
            InputKey::Escape => self.finish_word_field(false, 0),
            _ => {
                let _ = f.control.key(k, mods, ui);
                Vec::new()
            }
        }
    }

    /// A press while the field is open: inside keeps editing, elsewhere takes the text (the Mac field loses focus).
    pub(crate) fn word_field_press(&mut self, p: CGPoint) -> Option<Vec<TimelineAction>> {
        self.word_field.as_ref()?;
        // A press inside the field places the caret (double click: word, triple: all); the text can only be measured
        // with a canvas, so the next frame resolves it (`draw_word_field`).
        if self.word_field_frame().is_some_and(|r| r.has(p)) {
            let clicks = self.click_count(p);
            self.word_field_press_at = Some((p.x, clicks));
            self.word_field_drag = Some((p.x, p.x, false));
            return Some(Vec::new());
        }
        None
    }

    /// Ends the field. `step` -1 / +1 opens the previous / next word afterwards (Tab).
    pub(crate) fn finish_word_field(&mut self, commit: bool, step: i64) -> Vec<TimelineAction> {
        let Some(f) = self.word_field.take() else { return Vec::new() };
        if !commit || !self.field_still_stands(&f) {
            return Vec::new();
        }
        let text = f.control.editor().map_or_else(|| f.control.text.clone(), |e| e.string().to_string());
        let typed = text.split(char::is_whitespace).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ");
        let mut out = self.timeline.clone();
        let (first, count): (i64, i64);
        let id = f.target.caption();
        let place = self
            .timeline
            .caption_tracks
            .iter()
            .find_map(|tr| tr.items().iter().position(|i| i.id == id).map(|k| (tr.id, k)));
        let mut actions: Vec<TimelineAction> = Vec::new();
        match f.target {
            CaptionWordTarget::Word(r) => {
                first = r.index as i64;
                let Some(c) = self.caption_at(id) else { return Vec::new() };
                let words = c.item.effective_words();
                let Some(w) = words.get(r.index) else { return Vec::new() };
                if w.text == typed {
                    count = 1;
                } else {
                    let Ok(n) = out.set_caption_word(id, r.index, &typed) else { return Vec::new() };
                    count = n as i64;
                    let left = out
                        .caption_tracks
                        .iter()
                        .flat_map(|t| t.items().iter())
                        .find(|i| i.id == id)
                        .map_or(0, |i| i.tokens().len());
                    let select = if left == 0 { None } else { Some(CaptionWordRef::new(id, r.index.min(left - 1))) };
                    actions.extend(self.apply_caption_edit(
                        out,
                        if typed.is_empty() { "Delete Word" } else { "Edit Word" },
                        BTreeSet::from([id]),
                        select,
                    ));
                }
            }
            CaptionWordTarget::Insert { at, .. } => {
                first = at as i64;
                if typed.is_empty() {
                    return Vec::new();
                }
                let Ok(n) = out.insert_caption_word(id, at, &typed) else { return Vec::new() };
                if n == 0 {
                    return Vec::new();
                }
                count = n as i64;
                actions.extend(self.apply_caption_edit(
                    out,
                    if n == 1 { "Insert Word" } else { "Insert Words" },
                    BTreeSet::from([id]),
                    Some(CaptionWordRef::new(id, at)),
                ));
            }
        }
        if step == 0 {
            return actions;
        }
        let index = if step > 0 { first + count } else { first - 1 };
        let Some(next) = self.word_from(id, index, step > 0, place) else { return actions };
        actions.extend(self.begin_word_editing(next).unwrap_or_default());
        actions
    }

    /// The word at `index` of caption `id`, or past its ends the first word of the next caption (the last word of the
    /// previous one) on the same track. A caption that is gone (its last word deleted) is continued from `place`.
    fn word_from(&self, id: Id, index: i64, forward: bool, place: Option<(Id, usize)>) -> Option<CaptionWordRef> {
        let track: &CaptionTrack;
        let mut i: i64;
        if let Some((tr, k)) = self
            .timeline
            .caption_tracks
            .iter()
            .find(|t| t.items().iter().any(|i| i.id == id))
            .and_then(|tr| tr.items().iter().position(|i| i.id == id).map(|k| (tr, k)))
        {
            if index >= 0 && (index as usize) < tr.items()[k].tokens().len() {
                return Some(CaptionWordRef::new(id, index as usize));
            }
            track = tr;
            i = k as i64 + if forward { 1 } else { -1 };
        } else if let Some((ptrack, pitem)) = place
            && let Some(tr) = self.timeline.caption_track(ptrack)
        {
            track = tr;
            i = if forward { pitem as i64 } else { pitem as i64 - 1 };
        } else {
            return None;
        }
        while i >= 0 && (i as usize) < track.items().len() {
            let item = &track.items()[i as usize];
            let n = item.tokens().len();
            if n > 0 {
                return Some(CaptionWordRef::new(item.id, if forward { 0 } else { n - 1 }));
            }
            i += if forward { 1 } else { -1 };
        }
        None
    }

    /// `applyCaptionEdit`: a word edit made outside a gesture becomes the panel's timeline and one session commit.
    pub fn apply_caption_edit(
        &mut self,
        out: Timeline,
        undo_name: &str,
        captions: BTreeSet<Id>,
        word: Option<CaptionWordRef>,
    ) -> Vec<TimelineAction> {
        if out == self.timeline {
            return Vec::new();
        }
        self.feed_interaction();
        let commit = self.interaction.commit_caption_edit(out, undo_name, &captions, word);
        let mut actions = self.refresh_from_interaction();
        actions.push(TimelineAction::Commit(Box::new(commit)));
        actions
    }

    // MARK: Word edits

    /// Delete with a word selected: removes that word. `None` when no word is selected or shown, or more than its caption
    /// is selected: Delete then keeps its meaning.
    pub(crate) fn delete_selected_word(&mut self) -> Option<Vec<TimelineAction>> {
        let r = self.interaction.word_selection()?;
        if self.gesture.is_some()
            || !self.has_visible_word_selection()
            || !self.selection.is_empty()
            || self.caption_selection != BTreeSet::from([r.caption])
        {
            return None;
        }
        self.delete_word(r)
    }

    pub fn delete_word(&mut self, r: CaptionWordRef) -> Option<Vec<TimelineAction>> {
        let mut out = self.timeline.clone();
        out.delete_caption_word(r.caption, r.index).ok()?;
        let left = out
            .caption_tracks
            .iter()
            .flat_map(|t| t.items().iter())
            .find(|i| i.id == r.caption)
            .map_or(0, |i| i.tokens().len());
        let word = if left == 0 { None } else { Some(CaptionWordRef::new(r.caption, r.index.min(left - 1))) };
        Some(self.apply_caption_edit(out, "Delete Word", BTreeSet::from([r.caption]), word))
    }

    /// Splits a caption so that word `index` starts the second one.
    pub fn split_caption(&mut self, id: Id, before_word: usize) -> Vec<TimelineAction> {
        let mut out = self.timeline.clone();
        let mut ids = self.fresh_ids();
        let Ok((_, second)) = out.split_caption(id, before_word, &mut ids) else { return Vec::new() };
        self.apply_caption_edit(out, "Split Caption", BTreeSet::from([second]), None)
    }

    /// Joins a caption with the one before or after it on its track.
    pub fn join_caption(&mut self, id: Id, with: CaptionNeighbor) -> Vec<TimelineAction> {
        let mut out = self.timeline.clone();
        let Ok(joined) = out.join_caption(id, with) else { return Vec::new() };
        self.apply_caption_edit(out, "Join Captions", BTreeSet::from([joined]), None)
    }

    // MARK: Drawing

    /// The open field over its word (hidden while the word is outside the tracks, like the Mac field).
    pub(crate) fn draw_word_field(&mut self, cv: &mut Canvas, clip: CGRect) {
        if self.word_field.is_none() {
            return;
        }
        let Some(r) = self.word_field_frame() else { return };
        if !(r.min_x() >= clip.min_x() && r.max_x() <= clip.max_x()) {
            return;
        }
        cv.fill(r.inset(0.0, 1.0), self.theme.timeline());
        let press = self.word_field_press_at.take();
        let Some(f) = self.word_field.as_mut() else { return };
        if let Some((x, clicks)) = press {
            let caret = f.control.caret_index(cv, x, r);
            f.control.mouse_down(caret, clicks);
        }
        // Dragging inside the field selects from the press to the pointer (the Mac field editor).
        if let Some((from_x, x, true)) = self.word_field_drag {
            self.word_field_drag = Some((from_x, x, false));
            if let (Some(from), Some(to)) = (f.control.caret_index(cv, from_x, r), f.control.caret_index(cv, x, r)) {
                f.control.mouse_dragged(to, Some(from));
            }
        }
        // The caret blinks with the host's clock (`ui_now`, set before every frame).
        let mut cx = UiCx::new();
        cx.now = self.ui_now;
        f.control.draw(cv, r, &self.theme, true, &mut cx);
    }
}

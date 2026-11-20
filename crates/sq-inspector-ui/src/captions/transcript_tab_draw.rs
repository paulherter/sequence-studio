// Swift: Draw/TranscriptTabDraw.swift
//! The Transcribe tab of the Text panel on the shared toolkit. Transcribe (the whole sequence), the language, a progress
//! line while it runs, then the transcript: hovering marks a word, a click seeks to it, a double-click types into it
//! (Return or Escape ends it), the search row marks every match, and Create Captions... sits in the footer. State lives in
//! `CaptionsPanelModel`; the host owns one model per sequence and hands it in with `set_model`.
//! Coordinates: points, y down, (0, 0) = the tab's top-left.
//
// known limit: no mascot beside the progress bar and no search-field magnifier; a match inside a word is marked on exactly
// its characters, a match across a space only inside the words. The language names come from a small table of the
// default languages (the Swift tab asked `Locale`); any other identifier shows as it is. Upgrade with a portable locale
// name source.

use std::cell::RefCell;
use std::ops::Range;
use std::rc::Rc;

use sq_core_time::Time;
use sq_draw::inspector::inspector_controls::{Direction, InspectorDraw, InspectorTokens};
use sq_draw::inspector::scrub_field_control::ClickCounter;
use sq_draw::inspector::text_field_control::TextFieldControl;
use sq_draw::theme::{radius, type_size};
use sq_draw::{Alignment, Canvas, Color, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;

use crate::captions::captions_tab_draw::MenuFn;
use crate::captions::panel_model::{CaptionsPanelModel, CaptionsState};
use crate::captions::search::TranscriptSearch;

type Notify<T> = Option<Box<dyn FnMut(T)>>;
/// The model a tab shows (the host keeps one per sequence).
pub type SharedModel = Rc<RefCell<CaptionsPanelModel>>;
/// Mark All: the hit times and the search text.
pub type MarkHit = (Vec<Time>, String);

/// What can be hovered, pressed or focused.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Control {
    Transcribe,
    Language,
    Cancel,
    Search,
    Prev,
    Next,
    MarkAll,
    Text,
    Create,
}

const CONTROLS: [Control; 9] = [
    Control::Transcribe,
    Control::Language,
    Control::Cancel,
    Control::Search,
    Control::Prev,
    Control::Next,
    Control::MarkAll,
    Control::Text,
    Control::Create,
];

/// What the tab shows for the model's state.
#[derive(Clone, Debug, PartialEq)]
pub enum Phase {
    Idle,
    Running(f64),
    Ready,
    Failed(String),
}

/// A word laid out in the text area: its index, its box, its text and its UTF-16 range in the transcript text.
#[derive(Clone, Debug, PartialEq)]
pub struct Placed {
    pub index: usize,
    pub rect: CGRect,
    pub text: String,
    pub range: Range<usize>,
}

struct Frames {
    transcribe: CGRect,
    language: CGRect,
    cancel: CGRect,
    status: CGRect,
    search: CGRect,
    prev: CGRect,
    next: CGRect,
    mark_all: CGRect,
    bar: CGRect,
    text: CGRect,
    create: CGRect,
    progress: CGRect,
}

fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

/// The text of the UTF-16 range `r` of `s` (clamped).
fn utf16_slice(s: &str, r: Range<usize>) -> String {
    let units: Vec<u16> = s.encode_utf16().collect();
    let end = r.end.min(units.len());
    let start = r.start.min(end);
    String::from_utf16_lossy(&units[start..end])
}

fn intersect(a: &Range<usize>, b: &Range<usize>) -> Range<usize> {
    let start = a.start.max(b.start);
    start..a.end.min(b.end).max(start)
}

pub struct TranscriptTabDraw {
    pub theme: DrawTheme,
    pub size: CGSize,
    /// Seconds for double-click timing (the host's clock).
    pub clock: Box<dyn Fn() -> f64>,
    /// The playhead (sequence time); the host sets it before each draw.
    pub playhead: Time,
    model: Option<SharedModel>,
    pub on_menu: Option<MenuFn>,
    /// Create Captions... (the host's dialog over the model).
    pub on_create_captions: Notify<()>,
    /// Mark All: the hit times and the search text (the host adds the markers as one undo step).
    pub on_mark_hits: Notify<MarkHit>,
    /// "Replace the transcript?" is due (the host asks, then calls `confirm_overwrite` or `cancel_overwrite` of the model).
    pub on_confirm_overwrite: Notify<()>,
    search: TextFieldControl,
    current_match: Option<Range<usize>>,
    match_label: Option<String>,
    hovered_word: Option<usize>,
    /// The word being typed into (its index) and its field.
    editing: Option<(usize, TextFieldControl)>,
    scroll_y: f64,
    focus: Option<Control>,
    hover: Option<Control>,
    pressed: Option<Control>,
    language_open: bool,
    counter: ClickCounter,
    overwrite_asked: bool,
    transcribe_width: f64,
    language_width: f64,
    /// Width of the "Spoken language" label in the empty state (measured with the buttons).
    spoken_width: f64,
    mark_all_width: f64,
    cancel_width: f64,
    create_width: f64,
    placed: Vec<Placed>,
    content_height: f64,
    layout_key: String,
    layout_had_atlas: bool,
}

impl Default for TranscriptTabDraw {
    fn default() -> Self {
        Self::new()
    }
}

impl TranscriptTabDraw {
    pub const EDIT_HINT: &'static str = "Editing text. Return or Esc keeps it; Cmd+Z undoes the edit.";

    /// The hint with the undo key of this system (Ctrl+Z off the Mac).
    pub fn edit_hint() -> String {
        let text = SQL10n::string(Self::EDIT_HINT);
        let cmd = sq_os::Platform::current().command_key_name();
        text.replace("Cmd+Z", &format!("{cmd}+Z")).replace("⌘Z", &format!("{cmd}+Z"))
    }
    pub const NO_SEQUENCE_TITLE: &'static str = "No sequence open";
    pub const NO_SEQUENCE_HINT: &'static str = "Open a sequence to transcribe it and create captions";

    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): Spacing.sm 8, quietField 22;
    // upgrade when SQUIKit's tokens move into a portable file.
    const PAD: f64 = 8.0;
    const ROW_HEIGHT: f64 = 22.0;
    /// Measured on the Mac render: button to language popup.
    const TOP_GAP: f64 = 3.0;
    const LINE_HEIGHT: f64 = 22.0;
    /// NSTextContainer.lineFragmentPadding.
    const LINE_PAD: f64 = 5.0;
    const INSET_Y: f64 = 4.0;
    const STATUS_HEIGHT: f64 = 14.0;
    const ICON_WIDTH: f64 = 22.0;

    pub fn new() -> TranscriptTabDraw {
        TranscriptTabDraw {
            theme: DrawTheme::default(),
            size: CGSize { width: 320.0, height: 400.0 },
            clock: Box::new(|| 0.0),
            playhead: Time::ZERO,
            model: None,
            on_menu: None,
            on_create_captions: None,
            on_mark_hits: None,
            on_confirm_overwrite: None,
            search: Self::new_search(),
            current_match: None,
            match_label: None,
            hovered_word: None,
            editing: None,
            scroll_y: 0.0,
            focus: None,
            hover: None,
            pressed: None,
            language_open: false,
            counter: ClickCounter::new(),
            overwrite_asked: false,
            transcribe_width: 78.0,
            language_width: 186.0,
            spoken_width: 96.0,
            mark_all_width: 70.0,
            cancel_width: 60.0,
            create_width: 130.0,
            placed: Vec::new(),
            content_height: 0.0,
            layout_key: String::new(),
            layout_had_atlas: false,
        }
    }

    fn new_search() -> TextFieldControl {
        let mut f = TextFieldControl::new("");
        f.alignment = Alignment::Left;
        f.font_size = f64::from(type_size::BODY);
        f.placeholder = "Find in transcript".to_string();
        f
    }

    /// The display name of the transcript language (the bar's step note); `None` without a sequence model.
    pub fn language_name(&self) -> Option<String> {
        self.model.as_ref().map(|m| Self::language_title(m.borrow().language()))
    }

    /// The sequence's transcript model; `None` = nothing to show (no sequence). Another model resets the view.
    pub fn set_model(&mut self, model: Option<SharedModel>) {
        let same = match (&self.model, &model) {
            (Some(a), Some(b)) => Rc::ptr_eq(a, b),
            (None, None) => true,
            _ => false,
        };
        self.model = model;
        if !same {
            self.reset_view();
        }
    }

    pub fn model(&self) -> Option<&SharedModel> {
        self.model.as_ref()
    }

    fn reset_view(&mut self) {
        self.search = Self::new_search();
        self.current_match = None;
        self.match_label = None;
        self.hovered_word = None;
        self.editing = None;
        self.scroll_y = 0.0;
        self.focus = None;
        self.overwrite_asked = false;
        self.layout_key.clear();
    }

    pub fn scroll_y(&self) -> f64 {
        self.scroll_y
    }

    pub fn hovered_word(&self) -> Option<usize> {
        self.hovered_word
    }

    /// The index of the word being typed into.
    pub fn editing_word(&self) -> Option<usize> {
        self.editing.as_ref().map(|e| e.0)
    }

    /// A field is open (the host keeps IME on while it is).
    pub fn is_editing_text(&self) -> bool {
        self.editing.is_some() || self.search.is_editing()
    }

    fn search_term(&self) -> String {
        self.search.editor().map_or_else(|| self.search.text.clone(), |e| e.string())
    }

    // MARK: State (CaptionsPanelView.refresh)

    pub fn phase(&self) -> Phase {
        let Some(m) = &self.model else { return Phase::Idle };
        let m = m.borrow();
        match m.state() {
            CaptionsState::Idle => Phase::Idle,
            CaptionsState::Transcribing { progress } => Phase::Running(*progress),
            CaptionsState::Ready => {
                if m.transcript().is_none() {
                    Phase::Idle
                } else {
                    Phase::Ready
                }
            }
            CaptionsState::Failed(s) => Phase::Failed(s.clone()),
        }
    }

    fn is_running(&self) -> bool {
        matches!(self.phase(), Phase::Running(_))
    }

    fn is_ready(&self) -> bool {
        self.phase() == Phase::Ready
    }

    fn is_idle(&self) -> bool {
        self.phase() == Phase::Idle
    }

    pub fn transcribe_title(&self) -> &'static str {
        let Some(m) = &self.model else { return "Transcribe" };
        if self.is_running() {
            return "Transcribing\u{2026}";
        }
        if matches!(self.phase(), Phase::Failed(_)) {
            return "Try Again";
        }
        if m.borrow().transcript().is_none() { "Transcribe" } else { "Transcribe Again" }
    }

    /// One filled button per state: Transcribe or Try Again; the quiet Transcribe Again; Transcribing... is dimmed.
    pub fn transcribe_is_accent(&self) -> bool {
        self.model.is_some() && !self.is_running() && matches!(self.phase(), Phase::Failed(_))
    }

    pub fn status_text(&self) -> String {
        let Some(m) = &self.model else { return String::new() };
        if self.editing.is_some() {
            return Self::edit_hint();
        }
        let m = m.borrow();
        match m.state() {
            CaptionsState::Idle => SQL10n::string(if m.can_transcribe() {
                "Not transcribed yet."
            } else {
                "Nothing audible in this sequence."
            }),
            CaptionsState::Transcribing { progress } => match m.status_note() {
                Some(note) => format!("{}...", SQL10n::string(note)),
                None => SQL10n::format("Transcribing %@ %%", &[&((progress * 100.0).round() as i64).to_string()]),
            },
            CaptionsState::Ready => {
                let n = m.edited_word_ids().len();
                if m.is_outdated() {
                    return SQL10n::string("The timeline changed since this transcript. Transcribe again.");
                }
                let words = m.transcript().map_or(0, |t| t.words.len());
                if n > 0 {
                    SQL10n::plural_with(words as i64, "%@ word, %@ edited", "%@ words, %@ edited", &[&n.to_string()])
                } else {
                    SQL10n::plural(words as i64, "%@ word", "%@ words")
                }
            }
            CaptionsState::Failed(msg) => {
                if msg.starts_with("Transcription failed") {
                    SQL10n::string(msg)
                } else {
                    format!("{} {}", SQL10n::string("Transcription failed."), SQL10n::string(msg))
                }
            }
        }
    }

    fn language_title(id: &str) -> String {
        CaptionsPanelModel::language_title(id)
    }

    // MARK: Layout (CaptionsPanelView.build: a vertical stack, 8 pt apart and inset, hidden rows collapse)

    fn count_width(&self) -> f64 {
        if self.match_label.is_none() { 0.0 } else { 44.0 }
    }

    /// The empty state's block: icon 26, title 20, explanation 3 x 14, then the language row and the button.
    const EMPTY_TOP_BLOCK: f64 = 26.0 + 10.0 + 20.0 + 4.0 + 42.0 + 10.0;

    /// The y of the language row and of the Transcribe button inside the centered empty-state block.
    fn empty_rows(&self) -> (f64, f64) {
        let h = Self::ROW_HEIGHT;
        let block = Self::EMPTY_TOP_BLOCK + h + 8.0 + h;
        let top = ((self.size.height - block) / 2.0).round().max(8.0);
        (top + Self::EMPTY_TOP_BLOCK, top + Self::EMPTY_TOP_BLOCK + h + 8.0)
    }

    /// Widths of the "Spoken language" label and its popup in the empty state. In a narrow panel the popup gives way
    /// first (down to 96), then the label, which is cut at its end with an ellipsis, never at its start.
    fn empty_row_widths(&self) -> (f64, f64) {
        let avail = (self.size.width - 2.0 * Self::PAD).max(0.0);
        if self.spoken_width + 8.0 + self.language_width <= avail {
            return (self.spoken_width, self.language_width);
        }
        let lang = (avail - 8.0 - self.spoken_width).max(96.0).min(self.language_width);
        let label = (avail - 8.0 - lang).clamp(0.0, self.spoken_width);
        (label, lang)
    }

    fn frames(&self) -> Frames {
        let (p, h) = (Self::PAD, Self::ROW_HEIGHT);
        let inner = (self.size.width - 2.0 * p).max(0.0);
        let tr = CGRect::new(p, 0.0, self.transcribe_width, h);
        let lang = CGRect::new(tr.max_x() + Self::TOP_GAP, 0.0, self.language_width, h);
        if self.is_idle() {
            // The empty state carries both controls (kit): language row, then the Transcribe button, centered.
            let (lang_row, button_row) = self.empty_rows();
            let (label_w, lang_w) = self.empty_row_widths();
            let row_w = label_w + 8.0 + lang_w;
            // Centered; a row wider than the panel starts at the padding instead of leaving the panel on the left.
            let lang = CGRect::new(
                ((self.size.width - row_w) / 2.0).round().max(Self::PAD) + label_w + 8.0,
                lang_row,
                lang_w,
                h,
            );
            let tr = CGRect::new(
                ((self.size.width - self.transcribe_width) / 2.0).round(),
                button_row,
                self.transcribe_width,
                h,
            );
            return Frames {
                transcribe: tr,
                language: lang,
                cancel: CGRect::new(0.0, 0.0, 0.0, 0.0),
                status: CGRect::new(0.0, 0.0, 0.0, 0.0),
                search: CGRect::new(0.0, 0.0, 0.0, 0.0),
                prev: CGRect::new(0.0, 0.0, 0.0, 0.0),
                next: CGRect::new(0.0, 0.0, 0.0, 0.0),
                mark_all: CGRect::new(0.0, 0.0, 0.0, 0.0),
                bar: CGRect::new(0.0, 0.0, 0.0, 0.0),
                text: CGRect::new(0.0, 0.0, 0.0, 0.0),
                create: CGRect::new(
                    self.size.width - p - self.create_width,
                    self.size.height - p - h,
                    self.create_width,
                    h,
                ),
                progress: CGRect::new(0.0, 0.0, 0.0, 0.0),
            };
        }
        let mut y = h + p;
        let (mut progress, mut cancel, mut status, mut search) = (
            CGRect::new(0.0, 0.0, 0.0, 0.0),
            CGRect::new(0.0, 0.0, 0.0, 0.0),
            CGRect::new(0.0, 0.0, 0.0, 0.0),
            CGRect::new(0.0, 0.0, 0.0, 0.0),
        );
        let (mut bar, mut prev, mut next, mut mark) = (
            CGRect::new(0.0, 0.0, 0.0, 0.0),
            CGRect::new(0.0, 0.0, 0.0, 0.0),
            CGRect::new(0.0, 0.0, 0.0, 0.0),
            CGRect::new(0.0, 0.0, 0.0, 0.0),
        );
        if self.is_running() {
            cancel = CGRect::new(self.size.width - p - self.cancel_width, y, self.cancel_width, h);
            progress = CGRect::new(p, y + (h - 4.0) / 2.0, (cancel.min_x() - 10.0 - p).max(0.0), 4.0);
            y += h + p;
        }
        if !self.is_idle() {
            status = CGRect::new(p, y, inner, Self::STATUS_HEIGHT);
            y += Self::STATUS_HEIGHT + p;
        }
        let ready = self.is_ready();
        if ready {
            mark = CGRect::new(self.size.width - p - self.mark_all_width, y, self.mark_all_width, h);
            next = CGRect::new(mark.min_x() - 4.0 - Self::ICON_WIDTH, y, Self::ICON_WIDTH, h);
            prev = CGRect::new(next.min_x() - 4.0 - Self::ICON_WIDTH, y, Self::ICON_WIDTH, h);
            let cw = self.count_width();
            let sw = (prev.min_x() - 4.0 - p - cw - if cw > 0.0 { 4.0 } else { 0.0 }).max(40.0);
            search = CGRect::new(p, y, sw, h);
            y += h + p;
            bar = CGRect::new(p, y, inner, 2.0);
            y += 2.0 + p;
        }
        let create =
            CGRect::new(self.size.width - p - self.create_width, self.size.height - p - h, self.create_width, h);
        let text = if ready {
            CGRect::new(p, y, inner, (create.min_y() - p - y).max(0.0))
        } else {
            CGRect::new(0.0, 0.0, 0.0, 0.0)
        };
        Frames {
            transcribe: tr,
            language: lang,
            cancel,
            status,
            search,
            prev,
            next,
            mark_all: mark,
            bar,
            text,
            create,
            progress,
        }
    }

    pub fn frame(&self, k: Control) -> CGRect {
        let f = self.frames();
        match k {
            Control::Transcribe => f.transcribe,
            Control::Language => f.language,
            Control::Cancel => f.cancel,
            Control::Search => f.search,
            Control::Prev => f.prev,
            Control::Next => f.next,
            Control::MarkAll => f.mark_all,
            Control::Text => f.text,
            Control::Create => {
                if self.is_ready() {
                    f.create
                } else {
                    CGRect::new(0.0, 0.0, 0.0, 0.0)
                }
            }
        }
    }

    pub fn control_at(&self, p: CGPoint) -> Option<Control> {
        CONTROLS.into_iter().find(|k| {
            let r = self.frame(*k);
            r.width > 0.0 && r.contains(p)
        })
    }

    // MARK: Words (the transcript wrapped in 22 pt lines)

    pub fn placed(&self) -> &[Placed] {
        &self.placed
    }

    /// Lays the words out in the text area's width; cached on the text, the width and the atlas.
    fn layout_words(&mut self, c: Option<&Canvas>, width: f64) {
        let Some(model) = self.model.clone() else {
            self.placed.clear();
            self.content_height = 0.0;
            self.layout_key.clear();
            return;
        };
        let m = model.borrow();
        let Some(t) = m.transcript() else {
            self.placed.clear();
            self.content_height = 0.0;
            self.layout_key.clear();
            return;
        };
        let has_atlas = c.is_some_and(|c| c.atlas().is_some());
        let ranges = m.word_ranges();
        let key = format!("{}|{}|{}", width as i64, ranges.len(), t.text());
        if key == self.layout_key && has_atlas == self.layout_had_atlas {
            return;
        }
        self.layout_key = key;
        self.layout_had_atlas = has_atlas;
        let fs = f64::from(type_size::TITLE);
        let measure = |s: &str| match c {
            Some(c) if has_atlas => c.size_of(s, fs, 0).width,
            _ => s.chars().count() as f64 * fs * 0.55,
        };
        let space = measure(" ");
        let avail = (width - 2.0 * Self::LINE_PAD).max(1.0);
        let (mut x, mut line) = (0.0_f64, 0_usize);
        self.placed.clear();
        for (i, (r, word)) in ranges.iter().zip(&t.words).enumerate() {
            let sw = measure(&word.text);
            if x > 0.0 && x + sw > avail {
                line += 1;
                x = 0.0;
            }
            self.placed.push(Placed {
                index: i,
                rect: CGRect::new(
                    Self::LINE_PAD + x,
                    Self::INSET_Y + line as f64 * Self::LINE_HEIGHT,
                    sw,
                    Self::LINE_HEIGHT,
                ),
                text: word.text.clone(),
                range: r.clone(),
            });
            x += sw + space;
        }
        self.content_height = Self::INSET_Y * 2.0 + (line + 1) as f64 * Self::LINE_HEIGHT;
    }

    /// Lays the words out without a canvas (a letter is 0.55 em); the tests and a host before the first draw use it.
    pub fn layout_without_canvas(&mut self) {
        let w = self.frame(Control::Text).width;
        self.layout_words(None, w);
    }

    fn clamp_scroll(&mut self, view_height: f64) {
        self.scroll_y = self.scroll_y.max(0.0).min((self.content_height - view_height).max(0.0));
    }

    fn word_at(&self, p: CGPoint) -> Option<&Placed> {
        let t = self.frame(Control::Text);
        let q = CGPoint::new(p.x - t.min_x(), p.y - t.min_y() + self.scroll_y);
        // A gap between words belongs to the word before it, like the text view's insertion point.
        let best =
            self.placed.iter().rfind(|w| w.rect.min_y() <= q.y && q.y < w.rect.max_y() && w.rect.min_x() - 3.0 <= q.x);
        best.filter(|w| q.x <= w.rect.max_x() + 3.0)
    }

    // MARK: Actions

    fn matches(&self) -> Vec<Range<usize>> {
        let text = self.model.as_ref().and_then(|m| m.borrow().transcript().map(|t| t.text())).unwrap_or_default();
        TranscriptSearch::matches(&text, &self.search_term(), false)
    }

    /// Moves to the next or previous match, shows it and puts the playhead on that word.
    pub fn step_search(&mut self, forward: bool) {
        let Some(model) = self.model.clone() else { return };
        let ms = self.matches();
        let length = model.borrow().transcript().map_or(0, |t| utf16_len(&t.text()));
        let i = match (&self.current_match, forward) {
            (Some(cur), _) => TranscriptSearch::step(&ms, cur.start, forward),
            // Swift starts before the first character going forward: the first match.
            (None, true) => (!ms.is_empty()).then_some(0),
            (None, false) => TranscriptSearch::step(&ms, length, false),
        };
        let Some(i) = i else { return };
        let hit = ms[i].clone();
        self.current_match = Some(hit.clone());
        self.match_label = Some(SQL10n::format("%@ of %@", &[&(i + 1).to_string(), &ms.len().to_string()]));
        if let Some(w) = self.placed.iter().find(|w| w.range.contains(&hit.start) || w.range.start >= hit.start) {
            let h = self.frame(Control::Text).height;
            let (top, bottom) = (w.rect.min_y(), w.rect.max_y());
            if top < self.scroll_y {
                self.scroll_y = top - Self::INSET_Y;
            } else if bottom > self.scroll_y + h {
                self.scroll_y = bottom - h + Self::INSET_Y;
            }
            self.clamp_scroll(h);
        }
        model.borrow_mut().seek_to_character(hit.start);
    }

    pub fn mark_all(&mut self) {
        let Some(model) = self.model.clone() else { return };
        model.borrow_mut().flush_edits();
        let times: Vec<Time> = {
            let m = model.borrow();
            self.matches()
                .iter()
                .filter_map(|r| m.word_index_at_character(r.start))
                .filter_map(|i| m.transcript().and_then(|t| t.words.get(i)).map(|w| w.range.start))
                .collect()
        };
        if times.is_empty() {
            return;
        }
        let term = self.search_term();
        if let Some(f) = self.on_mark_hits.as_mut() {
            f((times, term));
        }
    }

    pub fn begin_editing(&mut self, word: usize) {
        let Some(model) = &self.model else { return };
        if *model.borrow().state() != CaptionsState::Ready {
            return;
        }
        let Some(w) = self.placed.iter().find(|w| w.index == word) else { return };
        self.hovered_word = None;
        let mut f = TextFieldControl::new(&w.text);
        f.alignment = Alignment::Left;
        f.font_size = f64::from(type_size::TITLE);
        f.mouse_down(None, 1);
        self.editing = Some((word, f));
        self.focus = Some(Control::Text);
    }

    /// Commits the open word field and the search field (a menu chord, a press in another panel).
    pub fn end_text_edits(&mut self) {
        let _ = self.search.commit();
        self.end_editing(true);
    }

    /// Writes the typed word into the transcript text (the model's debounced edit, flushed at once) and closes the field.
    pub fn end_editing(&mut self, keep: bool) {
        let Some((index, mut field)) = self.editing.take() else { return };
        let Some(model) = self.model.clone() else { return };
        if !keep {
            return;
        }
        let Some(w) = self.placed.iter().find(|w| w.index == index) else { return };
        let typed = field.commit().unwrap_or_else(|| field.text.clone());
        if typed == w.text {
            return;
        }
        let mut m = model.borrow_mut();
        let Some(text) = m.transcript().map(|t| t.text()) else { return };
        let units: Vec<u16> = text.encode_utf16().collect();
        let mut out: Vec<u16> = units[..w.range.start.min(units.len())].to_vec();
        out.extend(typed.encode_utf16());
        out.extend_from_slice(&units[w.range.end.min(units.len())..]);
        m.text_changed(&String::from_utf16_lossy(&out));
        m.flush_edits();
    }

    pub fn language_menu(&self) -> Vec<SQMenuItem> {
        let Some(model) = &self.model else { return Vec::new() };
        let m = model.borrow();
        let common = m.common_language_count();
        let mut items = Vec::new();
        for (i, id) in m.languages.iter().enumerate() {
            if i == common && common > 0 && common < m.languages.len() {
                items.push(SQMenuItem::separator()); // the common languages, then everything else alphabetically
            }
            let mut item = SQMenuItem::new(&Self::language_title(id));
            item.is_checked = id == m.language();
            let (weak, id) = (Rc::downgrade(model), id.clone());
            item.action = Some(Rc::new(move || {
                if let Some(m) = weak.upgrade() {
                    m.borrow_mut().set_language(&id);
                }
            }));
            items.push(item);
        }
        items
    }

    // MARK: Session to UI

    /// Per draw: the playhead word, the overwrite question.
    pub fn sync(&mut self) {
        let Some(model) = self.model.clone() else { return };
        let asked = {
            let mut m = model.borrow_mut();
            m.update_playhead(self.playhead);
            m.needs_overwrite_confirmation()
        };
        if asked {
            if !self.overwrite_asked {
                self.overwrite_asked = true;
                if let Some(f) = self.on_confirm_overwrite.as_mut() {
                    f(());
                }
            }
        } else {
            self.overwrite_asked = false;
        }
    }

    // MARK: Drawing

    /// No sequence open: the empty state instead of the tab (TextPanelView.emptyLabel).
    pub fn shows_empty_state(&self) -> bool {
        self.model.is_none()
    }

    pub fn draw(&mut self, c: &mut Canvas, ui: &mut UiCx) {
        self.sync();
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        let whole = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        c.fill(whole, t.panel());
        let Some(model) = self.model.clone() else {
            // TextPanelView.emptyLabel: no sequence, no transcript page.
            c.draw_empty_state_art(
                &SQL10n::string(Self::NO_SEQUENCE_TITLE),
                &SQL10n::string(Self::NO_SEQUENCE_HINT),
                whole,
                0.0,
                true,
                &t,
            );
            return;
        };
        self.measure(c, &model);
        let f = self.frames();
        let (can_transcribe, can_create, outdated) = {
            let m = model.borrow();
            (m.can_transcribe(), m.can_create_captions(), m.is_outdated())
        };
        let enabled_top = can_transcribe && !self.is_running();
        let fh = Self::ROW_HEIGHT;
        InspectorDraw::button(
            c,
            &SQL10n::string(self.transcribe_title()),
            f.transcribe,
            self.hover == Some(Control::Transcribe),
            self.pressed == Some(Control::Transcribe),
            enabled_top,
            self.transcribe_is_accent(),
            fh,
            &t,
        );
        if !self.is_idle() {
            self.draw_step_label(
                c,
                "Step 1 of 2",
                f.language.max_x() + 10.0,
                f.transcribe,
                self.size.width - Self::PAD,
                &t,
            );
        }
        let lang = Self::language_title(model.borrow().language());
        InspectorDraw::popup(
            c,
            &lang,
            f.language,
            self.hover == Some(Control::Language),
            self.language_open,
            enabled_top,
            true,
            fh,
            None,
            &t,
        );

        if let Phase::Running(p) = self.phase() {
            InspectorDraw::progress(c, p, f.progress, &t);
            InspectorDraw::button(
                c,
                &SQL10n::string("Cancel"),
                f.cancel,
                self.hover == Some(Control::Cancel),
                self.pressed == Some(Control::Cancel),
                true,
                false,
                fh,
                &t,
            );
        }
        if self.is_idle() {
            // The kit's empty state: mic, heading, a short explanation, then the language and the Transcribe button.
            let (lang_row, _) = self.empty_rows();
            let top = lang_row - Self::EMPTY_TOP_BLOCK;
            let mut title = self.status_text();
            if title.ends_with('.') {
                title.pop();
            }
            // "Not transcribed yet" reads as the kit's heading once the tab can transcribe.
            let heading = if can_transcribe { SQL10n::string("Write down what is said") } else { title };
            let hint = if can_transcribe {
                SQL10n::string(
                    "Sequence Studio listens to the sequence and writes every word. You can correct the text afterwards. Then make captions from it in the next step.",
                )
            } else {
                String::new()
            };
            c.draw_icon(SQIcon::Microphone, CGPoint::new(self.size.width / 2.0 - 13.0, top), 26.0, t.label3(), None);
            let w = (self.size.width - 2.0 * Self::PAD * 2.0).max(0.0);
            let x = Self::PAD * 2.0;
            c.draw_text_in(&heading, CGRect::new(x, top + 36.0, w, 20.0), 15.0, t.label(), TextAlign::Center, 0.0, 0);
            for (i, line) in c.wrap(&hint, w, fs).into_iter().take(3).enumerate() {
                c.draw_text_in(
                    &line,
                    CGRect::new(x, top + 60.0 + i as f64 * 14.0, w, 14.0),
                    fs,
                    t.label2(),
                    TextAlign::Center,
                    0.0,
                    0,
                );
            }
            if can_transcribe {
                let label_w = self.empty_row_widths().0;
                let label =
                    CGRect::new(f.language.min_x() - 8.0 - label_w, f.language.min_y(), label_w, f.language.height);
                let text = c.ellipsized(&SQL10n::string("Spoken language"), fs, 0, label_w);
                c.draw_text_in(&text, label, fs, t.label3(), TextAlign::Left, 0.0, 0);
            }
            return;
        }
        let failed = matches!(self.phase(), Phase::Failed(_));
        let status_color = if failed {
            t.red()
        } else if self.editing.is_some() {
            t.accent()
        } else {
            t.label3()
        };
        c.draw_text_in(&self.status_text(), f.status, fs, status_color, TextAlign::Left, 0.0, 0);
        if !self.is_ready() {
            return;
        }

        // Search row.
        let mut sf = self.search.clone();
        sf.hovering = self.hover == Some(Control::Search);
        sf.draw(c, f.search, &t, self.focus == Some(Control::Search), ui);
        if sf.text.is_empty() && !sf.is_editing() {
            c.draw_text_in(
                &SQL10n::string("Find in transcript"),
                f.search.inset_by(6.0, 0.0),
                fs,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
        let term = self.search_term();
        let label =
            self.match_label.clone().or_else(|| if term.is_empty() { None } else { Some(SQL10n::string("No match")) });
        if let Some(l) = label {
            c.draw_text_in(
                &l,
                CGRect::new(
                    f.search.max_x() + 4.0,
                    f.search.min_y(),
                    f.prev.min_x() - f.search.max_x() - 8.0,
                    f.search.height,
                ),
                fs,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
        let hits = self.matches();
        for (k, dir) in [(Control::Prev, Direction::Up), (Control::Next, Direction::Down)] {
            let (r, on) = (self.frame(k), !hits.is_empty());
            InspectorDraw::button(c, "", r, self.hover == Some(k), self.pressed == Some(k), on, false, fh, &t);
            let label = t.label();
            let a = if on { label.a } else { label.a * InspectorTokens::DISABLED_ALPHA };
            InspectorDraw::chevron(c, r, dir, label.with_alpha(a), 8.0);
        }
        InspectorDraw::button(
            c,
            &SQL10n::string("Mark All"),
            f.mark_all,
            self.hover == Some(Control::MarkAll),
            self.pressed == Some(Control::MarkAll),
            !hits.is_empty() && !outdated,
            false,
            fh,
            &t,
        );
        c.fill_rounded(f.bar, 1.0, t.accent_fill());
        self.draw_text(c, ui, &model, f.text);
        InspectorDraw::button(
            c,
            &SQL10n::string("Create Captions\u{2026}"),
            f.create,
            self.hover == Some(Control::Create),
            self.pressed == Some(Control::Create),
            can_create,
            // Step 2 is due: the one filled button.
            can_create,
            fh,
            &t,
        );
        self.draw_step_label(c, "Step 2 of 2", Self::PAD, f.create, f.create.min_x() - 10.0, &t);
    }

    /// "Step 1 of 2" / "Step 2 of 2": a quiet right-aligned note on a button's row, only when it fits.
    fn draw_step_label(&self, c: &mut Canvas, text: &str, min_x: f64, row: CGRect, max_x: f64, t: &DrawTheme) {
        let label = SQL10n::string(text);
        let w = c.size_of(&label, 11.0, 0).width.ceil();
        if max_x - w >= min_x {
            let r = CGRect::new(max_x - w, row.min_y(), w, row.height);
            c.draw_text_in(&label, r, 11.0, t.label3(), TextAlign::Right, 0.0, 0);
        }
    }

    /// Button and popup widths from the canvas (SQButton.intrinsicContentSize; the popup is as wide as its widest item).
    fn measure(&mut self, c: &Canvas, model: &SharedModel) {
        self.transcribe_width = InspectorDraw::button_width(c, &SQL10n::string(self.transcribe_title()));
        self.mark_all_width = InspectorDraw::button_width(c, &SQL10n::string("Mark All"));
        self.spoken_width = c.size_of(&SQL10n::string("Spoken language"), f64::from(type_size::BODY), 0).width.ceil();
        self.cancel_width = InspectorDraw::button_width(c, &SQL10n::string("Cancel"));
        self.create_width = InspectorDraw::button_width(c, &SQL10n::string("Create Captions\u{2026}"));
        let fs = f64::from(type_size::BODY);
        let m = model.borrow();
        // SQPopup measures the first 64 items only.
        let widest = m
            .languages
            .iter()
            .take(64)
            .map(|l| Self::language_title(l))
            .chain(std::iter::once(Self::language_title(m.language())))
            .map(|s| c.size_of(&s, fs, 0).width)
            .fold(0.0_f64, f64::max);
        // SQPopup.intrinsicContentSize: title inset 10 + text + gap 8 + chevron 7 + inset 7, plus half a point of slack
        // because the canvas snaps glyph advances to the pixel grid and runs under NSString.
        self.language_width = (widest + 0.5 + 10.0 + 8.0 + 7.0 + 7.0).ceil().max(120.0);
    }

    fn draw_text(&mut self, c: &mut Canvas, ui: &mut UiCx, model: &SharedModel, r: CGRect) {
        let (t, fs) = (self.theme, f64::from(type_size::TITLE));
        self.layout_words(Some(c), r.width);
        self.clamp_scroll(r.height);
        let edit = self.editing.is_some();
        let page = if edit { t.content().lifted(0.06) } else { t.panel() };
        c.fill_rounded(r, f64::from(radius::CONTROL), page);
        c.save_gstate();
        c.clip_to(r);
        c.translate_by(r.min_x(), r.min_y() - self.scroll_y);
        let m = model.borrow();
        let current = m.current_word_id();
        let words = m.transcript().map(|t| t.words.as_slice()).unwrap_or(&[]);
        let hits = self.matches();
        let editing_index = self.editing.as_ref().map(|e| e.0);
        for w in &self.placed {
            if !(w.rect.max_y() > self.scroll_y && w.rect.min_y() < self.scroll_y + r.height) {
                continue;
            }
            let word = words.get(w.index);
            if edit && editing_index == Some(w.index) {
                continue;
            }
            let is_current = word.is_some_and(|x| Some(x.id) == current);
            if self.hovered_word == Some(w.index) && !edit {
                c.fill(w.rect, t.fill_hover());
            }
            if is_current {
                c.fill(w.rect, t.accent_tint());
            }
            for h in &hits {
                let i = intersect(h, &w.range);
                if i.is_empty() {
                    continue;
                }
                let lo = i.start - w.range.start;
                let hi = i.end - w.range.start;
                let x0 = c.size_of(&utf16_slice(&w.text, 0..lo), fs, 0).width;
                let x1 = c.size_of(&utf16_slice(&w.text, 0..hi), fs, 0).width;
                let hit = CGRect::new(w.rect.min_x() + x0, w.rect.min_y(), x1 - x0, w.rect.height);
                let col = if self.current_match.as_ref() == Some(h) { t.yellow() } else { t.yellow().with_alpha(0.35) };
                c.fill(hit, col);
            }
            let on_current_match = self.current_match.as_ref().is_some_and(|cm| !intersect(cm, &w.range).is_empty());
            let color = if is_current {
                t.on_clip()
            } else if on_current_match {
                Color::BLACK
            } else {
                t.label()
            };
            c.draw_text_in(&w.text, w.rect, fs, color, TextAlign::Left, 0.0, 0);
            if let Some(word) = word
                && (word.is_edited || word.is_unsure())
            {
                let col = if word.is_unsure() { t.warning() } else { t.yellow() };
                c.fill(CGRect::new(w.rect.min_x(), w.rect.max_y() - 5.0, w.rect.width, 1.0), col);
            }
        }
        if let Some((index, field)) = &self.editing
            && let Some(w) = self.placed.iter().find(|w| w.index == *index)
        {
            field.draw(c, w.rect.inset_by(-6.0, 0.0), &t, true, ui);
        }
        c.restore_gstate();
        if edit {
            c.stroke_rounded(r.inset_by(1.0, 1.0), f64::from(radius::CONTROL), 2.0, t.accent());
        }
    }

    // MARK: Pointer and keys

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        self.hover = p.and_then(|p| self.control_at(p));
        match p {
            Some(p) if self.hover == Some(Control::Text) && self.editing.is_none() => {
                self.hovered_word = self.word_at(p).map(|w| w.index);
            }
            _ => self.hovered_word = None,
        }
    }

    pub fn mouse_down(&mut self, p: CGPoint, _m: InputModifiers, click_count: Option<i64>) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, (self.clock)()));
        let k = self.control_at(p);
        if k != Some(Control::Search) && self.search.is_editing() {
            let _ = self.search.commit();
        }
        if k != Some(Control::Text) && self.editing.is_some() {
            self.end_editing(true);
        }
        self.pressed = k;
        match k {
            Some(Control::Search) => {
                self.focus = Some(Control::Search);
                self.search.mouse_down(None, 1);
            }
            Some(Control::Text) => {
                self.focus = Some(Control::Text);
                if self.editing.is_some() {
                    return;
                }
                let Some((index, start)) = self.word_at(p).map(|w| (w.index, w.range.start)) else { return };
                if n >= 2 {
                    self.begin_editing(index);
                } else if let Some(m) = &self.model {
                    m.borrow_mut().seek_to_character(start);
                }
            }
            Some(Control::Language) => {
                self.pressed = None;
                self.language_open = true;
                let f = self.frame(Control::Language);
                let allowed = self.model.as_ref().is_some_and(|m| m.borrow().can_transcribe()) && !self.is_running();
                if allowed {
                    let items = self.language_menu();
                    if let Some(f2) = self.on_menu.as_mut() {
                        f2(items, f);
                    }
                }
                self.language_open = false;
            }
            other => self.focus = other,
        }
    }

    pub fn mouse_dragged(&mut self, _p: CGPoint) {}

    pub fn mouse_up(&mut self, p: CGPoint) {
        let k = self.pressed.take();
        let Some(k) = k else { return };
        if self.control_at(p) != Some(k) {
            return;
        }
        let Some(model) = self.model.clone() else { return };
        let (can_transcribe, can_create) = {
            let m = model.borrow();
            (m.can_transcribe(), m.can_create_captions())
        };
        match k {
            Control::Transcribe if can_transcribe && !self.is_running() => model.borrow_mut().transcribe(false),
            Control::Cancel => model.borrow_mut().cancel_transcription(),
            Control::Prev => self.step_search(false),
            Control::Next => self.step_search(true),
            Control::MarkAll => self.mark_all(),
            Control::Create if can_create => {
                if let Some(f) = self.on_create_captions.as_mut() {
                    f(());
                }
            }
            _ => {}
        }
    }

    pub fn scroll(&mut self, p: CGPoint, dy: f64) -> bool {
        if self.control_at(p) != Some(Control::Text) {
            return false;
        }
        let before = self.scroll_y;
        self.scroll_y -= dy;
        let h = self.frame(Control::Text).height;
        self.clamp_scroll(h);
        self.scroll_y != before
    }

    /// Keys: the word field first (Return or Escape ends it), then the search field (Return = next, Shift+Return = previous).
    pub fn key(&mut self, k: InputKey, m: InputModifiers, ui: &mut UiCx) -> bool {
        if let Some((_, field)) = self.editing.as_mut() {
            if k == InputKey::Enter || k == InputKey::Escape {
                self.end_editing(true);
            } else {
                let _ = field.key(k, m, ui);
            }
            return true;
        }
        if self.search.is_editing() {
            if k == InputKey::Enter {
                self.step_search(!m.contains(InputModifiers::SHIFT));
            } else if k == InputKey::Escape {
                self.search.cancel();
            } else {
                let before = self.search_term();
                let _ = self.search.key(k, m, ui);
                if self.search_term() != before {
                    self.current_match = None;
                    self.match_label = None;
                }
            }
            return true;
        }
        false
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        match self.control_at(p)? {
            Control::Transcribe => Some(SQL10n::string("Transcribes the speech of the whole sequence")),
            Control::Prev => Some(SQL10n::string("Previous match (Shift+Return)")),
            Control::Next => Some(SQL10n::string("Next match (Return)")),
            Control::MarkAll => Some(SQL10n::string("Set a marker at every match, named after the search text")),
            Control::Create if self.model.as_ref().is_some_and(|m| !m.borrow().can_create_captions()) => {
                Some(SQL10n::string("The timeline changed since this transcript. Transcribe again."))
            }
            Control::Text => {
                let i = self.hovered_word?;
                let m = self.model.as_ref()?.borrow();
                let unsure = m.transcript()?.words.get(i)?.is_unsure();
                unsure.then(|| SQL10n::string("Unsure word"))
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::captions::panel_model::CaptionsPanelEvent;
    use sq_core_time::{Id, TimeRange};
    use sq_transcribe::transcript::{Transcript, TranscriptWord};
    use std::collections::BTreeSet;
    use std::path::PathBuf;

    fn transcript(words: &[&str]) -> Transcript {
        Transcript::new(
            "de-DE",
            words
                .iter()
                .enumerate()
                .map(|(i, w)| {
                    let r = TimeRange::from_end(Time::new(i as i64, 2), Time::new(i as i64 + 1, 2));
                    TranscriptWord::new(Id::fixed(i as u64 + 1), w, r)
                })
                .collect(),
        )
    }

    fn model(words: &[&str]) -> SharedModel {
        let mut m = CaptionsPanelModel::new();
        m.source_url = Some(PathBuf::from("/tmp/a.wav"));
        if !words.is_empty() {
            m.transcribe(false);
            let run = m
                .take_events()
                .into_iter()
                .find_map(|e| if let CaptionsPanelEvent::Transcribe(r) = e { Some(r.run) } else { None })
                .unwrap_or(0);
            m.finish(Ok(transcript(words)), run);
        }
        Rc::new(RefCell::new(m))
    }

    fn tab(words: &[&str]) -> (TranscriptTabDraw, SharedModel) {
        let m = model(words);
        let mut d = TranscriptTabDraw::new();
        d.size = CGSize { width: 320.0, height: 400.0 };
        d.set_model(Some(Rc::clone(&m)));
        d.layout_without_canvas();
        (d, m)
    }

    fn center(r: CGRect) -> CGPoint {
        CGPoint::new(r.mid_x(), r.mid_y())
    }

    fn seeks(m: &SharedModel) -> Vec<Time> {
        m.borrow_mut()
            .take_events()
            .into_iter()
            .filter_map(|e| if let CaptionsPanelEvent::Seek(t) = e { Some(t) } else { None })
            .collect()
    }

    #[test]
    fn utf16_helpers_cut_by_code_units() {
        assert_eq!(utf16_slice("a\u{1F600}b", 1..3), "\u{1F600}");
        assert_eq!(utf16_len("a\u{1F600}b"), 4);
        assert_eq!(intersect(&(2..5), &(4..9)), 4..5);
        assert!(intersect(&(0..2), &(3..4)).is_empty());
    }

    #[test]
    fn no_model_shows_the_empty_state_and_an_idle_model_the_hint() {
        let d = TranscriptTabDraw::new();
        assert!(d.shows_empty_state());
        assert_eq!(d.phase(), Phase::Idle);
        assert!(d.status_text().is_empty());
        assert_eq!(d.control_at(CGPoint::new(300.0, 300.0)), None);
        let (d, _) = tab(&[]);
        assert_eq!(d.phase(), Phase::Idle);
        assert_eq!(d.status_text(), "Not transcribed yet.");
        assert_eq!(d.transcribe_title(), "Transcribe");
        assert!(!d.transcribe_is_accent());
    }

    #[test]
    fn the_idle_empty_state_holds_the_language_row_and_the_transcribe_button() {
        let (mut d, _) = tab(&[]);
        d.size = CGSize::new(600.0, 400.0);
        let (lang, tr) = (d.frame(Control::Language), d.frame(Control::Transcribe));
        // centered in the panel, language row above the button, both clear of the tab bar
        assert!(lang.min_y() > 40.0 && tr.min_y() > lang.max_y());
        assert!((tr.mid_x() - 300.0).abs() < 1.5);
        assert!(lang.max_x() < 600.0);
    }

    /// The "Spoken language" label is never cut at its start: at every panel width (1280x800 at scales 1, 1.25 and 1.5
    /// leaves the inspector 200 to 330 points) the label and the popup stay inside the panel.
    #[test]
    fn the_spoken_language_label_stays_inside_a_narrow_panel() {
        for width in [160.0, 200.0, 240.0, 256.0, 280.0, 300.0, 330.0, 600.0] {
            let (mut d, _) = tab(&[]);
            d.size = CGSize::new(width, 400.0);
            let lang = d.frame(Control::Language);
            let (label_w, lang_w) = d.empty_row_widths();
            let label_x = lang.min_x() - 8.0 - label_w;
            assert!(label_x >= TranscriptTabDraw::PAD - 0.01, "label starts at {label_x} in a {width} panel");
            assert!(
                lang.max_x() <= width - TranscriptTabDraw::PAD + 0.01 || width < 160.0,
                "popup ends at {}",
                lang.max_x()
            );
            assert!(label_w <= d.spoken_width && lang_w >= 96.0f64.min(d.language_width));
            assert!((lang.width - lang_w).abs() < 0.01);
        }
    }

    #[test]
    fn a_ready_transcript_shows_its_rows_and_word_count() {
        let (d, _) = tab(&["eins", "zwei", "drei"]);
        assert_eq!(d.phase(), Phase::Ready);
        assert_eq!(d.transcribe_title(), "Transcribe Again");
        assert_eq!(d.status_text(), "3 words");
        assert!(d.frame(Control::Search).width >= 40.0);
        assert!(d.frame(Control::Text).height > 0.0);
        assert_eq!(d.placed().len(), 3);
        assert_eq!(d.placed()[1].range, 5..9);
        // The footer button is the lowest control.
        assert!(d.frame(Control::Create).min_y() > d.frame(Control::Text).max_y());
    }

    #[test]
    fn the_words_wrap_into_lines() {
        let words: Vec<&str> = std::iter::repeat_n("wortwort", 120).collect();
        let (d, _) = tab(&words);
        let lines = d.placed().iter().map(|w| w.rect.min_y() as i64).collect::<BTreeSet<_>>();
        assert!(lines.len() > 1);
        assert!(d.content_height > d.frame(Control::Text).height);
    }

    #[test]
    fn a_click_on_a_word_seeks_to_it() {
        let (mut d, m) = tab(&["eins", "zwei", "drei"]);
        let t = d.frame(Control::Text);
        let w = d.placed()[1].rect;
        let p = CGPoint::new(t.min_x() + w.mid_x(), t.min_y() + w.mid_y());
        d.mouse_moved(Some(p));
        assert_eq!(d.hovered_word(), Some(1));
        d.mouse_down(p, InputModifiers::NONE, Some(1));
        d.mouse_up(p);
        assert_eq!(seeks(&m), vec![Time::new(1, 2)]);
    }

    #[test]
    fn a_double_click_types_into_the_word_and_return_keeps_it() {
        let (mut d, m) = tab(&["eins", "zwei"]);
        let t = d.frame(Control::Text);
        let w = d.placed()[0].rect;
        let p = CGPoint::new(t.min_x() + w.mid_x(), t.min_y() + w.mid_y());
        d.mouse_down(p, InputModifiers::NONE, Some(2));
        assert_eq!(d.editing_word(), Some(0));
        assert!(d.is_editing_text());
        assert_eq!(d.status_text(), TranscriptTabDraw::edit_hint());
        let mut ui = UiCx::new();
        assert!(d.key(InputKey::Escape, InputModifiers::NONE, &mut ui));
        assert_eq!(d.editing_word(), None);
        assert_eq!(m.borrow().transcript().map(|t| t.text()).as_deref(), Some("eins zwei"));
    }

    #[test]
    fn search_marks_matches_and_steps_with_a_label_and_a_seek() {
        let (mut d, m) = tab(&["eins", "zwei", "eins"]);
        d.search = TextFieldControl::new("eins");
        assert_eq!(d.matches(), vec![0..4, 10..14]);
        d.step_search(true);
        assert_eq!(d.match_label.as_deref(), Some("1 of 2"));
        d.step_search(true);
        assert_eq!(d.match_label.as_deref(), Some("2 of 2"));
        d.step_search(true);
        assert_eq!(d.match_label.as_deref(), Some("1 of 2"));
        d.step_search(false);
        assert_eq!(d.match_label.as_deref(), Some("2 of 2"));
        assert_eq!(seeks(&m).last(), Some(&Time::new(2, 2)));
    }

    #[test]
    fn mark_all_reports_one_time_per_match() {
        let (mut d, _) = tab(&["eins", "zwei", "eins"]);
        d.search = TextFieldControl::new("eins");
        let got: Rc<RefCell<Vec<MarkHit>>> = Rc::new(RefCell::new(Vec::new()));
        let sink = Rc::clone(&got);
        d.on_mark_hits = Some(Box::new(move |hit| sink.borrow_mut().push(hit)));
        let p = center(d.frame(Control::MarkAll));
        d.mouse_down(p, InputModifiers::NONE, Some(1));
        d.mouse_up(p);
        assert_eq!(*got.borrow(), vec![(vec![Time::new(0, 2), Time::new(2, 2)], "eins".to_string())]);
    }

    #[test]
    fn transcribe_again_asks_before_it_overwrites() {
        let (mut d, m) = tab(&["eins"]);
        let asked = Rc::new(RefCell::new(0));
        let sink = Rc::clone(&asked);
        d.on_confirm_overwrite = Some(Box::new(move |()| *sink.borrow_mut() += 1));
        let p = center(d.frame(Control::Transcribe));
        d.mouse_down(p, InputModifiers::NONE, Some(1));
        d.mouse_up(p);
        assert!(m.borrow().needs_overwrite_confirmation());
        d.sync();
        d.sync();
        assert_eq!(*asked.borrow(), 1);
    }

    #[test]
    fn the_language_button_offers_the_languages_and_a_row_sets_it() {
        let (mut d, m) = tab(&["eins"]);
        let menus: Rc<RefCell<Vec<Vec<SQMenuItem>>>> = Rc::new(RefCell::new(Vec::new()));
        let sink = Rc::clone(&menus);
        d.on_menu = Some(Box::new(move |items, _| sink.borrow_mut().push(items)));
        let p = center(d.frame(Control::Language));
        d.mouse_down(p, InputModifiers::NONE, Some(1));
        let items = menus.borrow()[0].clone();
        assert_eq!(items.len(), m.borrow().languages.len());
        let pick = items.iter().find(|i| i.title.contains("French")).expect("French row");
        (pick.action.as_ref().expect("action"))();
        assert_eq!(m.borrow().language(), "fr-FR");
    }

    #[test]
    fn create_captions_needs_a_current_transcript() {
        let (mut d, _) = tab(&["eins"]);
        let n = Rc::new(RefCell::new(0));
        let sink = Rc::clone(&n);
        d.on_create_captions = Some(Box::new(move |()| *sink.borrow_mut() += 1));
        let p = center(d.frame(Control::Create));
        d.mouse_down(p, InputModifiers::NONE, Some(1));
        d.mouse_up(p);
        assert_eq!(*n.borrow(), 1);
        assert_eq!(d.help(center(d.frame(Control::Prev))).as_deref(), Some("Previous match (Shift+Return)"));
    }

    #[test]
    fn the_wheel_scrolls_only_the_text_and_clamps() {
        let words: Vec<&str> = std::iter::repeat_n("wortwort", 200).collect();
        let (mut d, _) = tab(&words);
        let t = d.frame(Control::Text);
        let p = center(t);
        assert!(!d.scroll(CGPoint::new(10.0, 2.0), -30.0));
        assert!(d.scroll(p, -30.0));
        assert_eq!(d.scroll_y(), 30.0);
        assert!(!d.scroll(p, 500.0) || d.scroll_y() == 0.0);
        d.scroll(p, -1.0e6);
        assert_eq!(d.scroll_y(), d.content_height - t.height);
    }

    #[test]
    fn drawing_without_an_atlas_does_not_panic() {
        for words in [&[][..], &["eins", "zwei"][..]] {
            let (mut d, _) = tab(words);
            let mut c = Canvas::with_size(320.0, 400.0, None, 1.0);
            d.draw(&mut c, &mut UiCx::new());
        }
        let mut d = TranscriptTabDraw::new();
        let mut c = Canvas::with_size(320.0, 400.0, None, 1.0);
        d.draw(&mut c, &mut UiCx::new());
    }
}

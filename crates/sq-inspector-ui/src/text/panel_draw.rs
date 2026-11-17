// Swift: Draw/TextPanelDraw.swift
//! The Captions panel on the shared toolkit. The v9 capture bar (a 38 pt bar, the tab switch at the leading inset) over
//! the shown tab: Transcript, Captions (`CaptionsTabDraw`) and Style (`CaptionStyleTabDraw`). Templates live in the Library.
//! Coordinates: points, y down, (0, 0) = the panel's top-left. Every call that edits takes the session (the Swift class
//! held it); the tabs' menus, color pickers and status lines are collected and passed on once per event.
//
// known limit: the Transcribe tab starts hidden, like the Swift panel without a transcription service (Windows today):
// the host calls `use_transcription` once it has one and hands each sequence's `CaptionsPanelModel` in with
// `set_transcript_model` (Swift built the models itself from the session; the sequence source, languages, saved
// language and the Create Captions dialog stay the host's). Mark All reports the hit times through `on_mark_hits`;
// the session has no `addSearchHitMarkers` yet.

use std::cell::RefCell;
use std::rc::Rc;

use sq_core_model::EffectColor;
use sq_draw::theme::{radius, type_size};
use sq_draw::{Canvas, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_editor_session::EditorSession;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;

use crate::captions::captions_tab_draw::{CaptionsTabDraw, MenuFn};
use crate::captions::style_tab_draw::CaptionStyleTabDraw;
use crate::captions::transcript_tab_draw::{MarkHit, SharedModel, TranscriptTabDraw};

/// The panel's tabs, in the Swift order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Tab {
    Transcript,
    Captions,
    Style,
}

impl Tab {
    pub const ALL: [Tab; 3] = [Tab::Transcript, Tab::Captions, Tab::Style];

    pub fn title(self) -> &'static str {
        match self {
            Tab::Transcript => "Transcript",
            Tab::Captions => "Captions",
            Tab::Style => "Style",
        }
    }

    /// The quiet note at the trailing end of the bar: the transcript language, the caption count and what the style
    /// applies to. The two steps ("Step 1 of 2", "Step 2 of 2") are named once, beside their buttons in the body.
    pub fn bar_note(self, language: Option<&str>, captions: usize) -> Option<String> {
        let count = |n: usize| if n == 1 { "1 caption".to_string() } else { format!("{n} captions") };
        match self {
            // The step numbers sit on the button rows of both tabs; the bar says only what the step is about.
            Tab::Transcript => language.map(str::to_string),
            Tab::Captions => Some(count(captions)),
            Tab::Style => Some(format!("Applies to {}", count(captions))),
        }
    }

    /// The Swift raw value (the order of the switch).
    fn raw_value(self) -> usize {
        self as usize
    }
}

type Notify<T> = Option<Box<dyn FnMut(T)>>;
/// A menu a tab asked for: the rows and the anchor in the tab's points.
type QueuedMenu = (Vec<SQMenuItem>, CGRect);

pub struct TextPanelDraw {
    pub theme: DrawTheme,
    size: CGSize,
    pub captions: CaptionsTabDraw,
    pub style: CaptionStyleTabDraw,
    pub transcript: TranscriptTabDraw,
    tabs: Vec<Tab>,
    tab: Tab,
    hover_tab: Option<Tab>,
    pressed_tab: Option<Tab>,
    /// The page took the press (drags and the release go to it).
    page_pressed: bool,
    /// Popups and row menus of every tab, anchors in panel points (the tab bar included). The rows queue commands: the
    /// host calls `run_commands` once the menu closes.
    pub on_menu: Option<MenuFn>,
    /// The Look tab's swatches, anchor in panel points; answer with `color_picked`. Without it swatches do nothing.
    pub on_pick_color: Option<Box<dyn FnMut(EffectColor, CGRect)>>,
    /// Status lines of every tab (template placed, look saved, captions exported).
    pub on_status: Notify<String>,
    /// Create Captions... on the Transcribe tab (the host's dialog over the model).
    pub on_create_captions: Notify<()>,
    /// "Replace the transcript?" is due; answer with `confirm_overwrite` or `cancel_overwrite` of the model.
    pub on_confirm_overwrite: Notify<()>,
    /// Mark All on the Transcribe tab: the hit times and the search text (the host adds the markers).
    pub on_mark_hits: Notify<MarkHit>,
    segment_widths: [f64; 3],
    menus: Rc<RefCell<Vec<QueuedMenu>>>,
    colors: Rc<RefCell<Vec<(EffectColor, CGRect)>>>,
    statuses: Rc<RefCell<Vec<String>>>,
    creates: Rc<RefCell<usize>>,
    overwrites: Rc<RefCell<usize>>,
    marks: Rc<RefCell<Vec<MarkHit>>>,
}

impl TextPanelDraw {
    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): Spacing.sm 8, the SQSegmented height 22,
    // 10 pt label insets and 1 pt track padding; upgrade when SQUIKit's tokens move into a portable file.
    pub const BAR_HEIGHT: f64 = 38.0;
    const PAD: f64 = 8.0;
    const SEGMENT_HEIGHT: f64 = 22.0;
    const SEGMENT_INSET: f64 = 10.0;
    /// SQSegmented.trackPadding: the track edge to the first segment.
    const TRACK_PADDING: f64 = 1.0;

    /// `captions`, `style`: the tabs, made by the host (the Look tab needs the font list and an id source).
    pub fn new(captions: CaptionsTabDraw, style: CaptionStyleTabDraw) -> TextPanelDraw {
        let menus = Rc::new(RefCell::new(Vec::new()));
        let colors = Rc::new(RefCell::new(Vec::new()));
        let statuses = Rc::new(RefCell::new(Vec::new()));
        let creates = Rc::new(RefCell::new(0));
        let overwrites = Rc::new(RefCell::new(0));
        let marks = Rc::new(RefCell::new(Vec::new()));
        let mut p = TextPanelDraw {
            theme: DrawTheme::default(),
            size: CGSize { width: 320.0, height: 480.0 },
            captions,
            style,
            transcript: TranscriptTabDraw::new(),
            tabs: vec![Tab::Captions, Tab::Style],
            tab: Tab::Captions,
            hover_tab: None,
            pressed_tab: None,
            page_pressed: false,
            on_menu: None,
            on_pick_color: None,
            on_status: None,
            on_create_captions: None,
            on_confirm_overwrite: None,
            on_mark_hits: None,
            segment_widths: Tab::ALL.map(|t| t.title().chars().count() as f64 * 8.0 + 2.0 * Self::SEGMENT_INSET),
            menus: Rc::clone(&menus),
            colors: Rc::clone(&colors),
            statuses: Rc::clone(&statuses),
            creates: Rc::clone(&creates),
            overwrites: Rc::clone(&overwrites),
            marks: Rc::clone(&marks),
        };
        p.layout_pages();
        let sink = Rc::clone(&menus);
        p.captions.on_menu = Some(Box::new(move |items, anchor| sink.borrow_mut().push((items, anchor))));
        let sink = Rc::clone(&menus);
        p.style.on_menu = Some(Box::new(move |items, anchor| sink.borrow_mut().push((items, anchor))));
        p.style.on_pick_color = Some(Box::new(move |current, anchor| colors.borrow_mut().push((current, anchor))));
        let sink = Rc::clone(&statuses);
        p.captions.on_status = Some(Box::new(move |s| sink.borrow_mut().push(s)));
        let sink = Rc::clone(&statuses);
        p.style.on_status = Some(Box::new(move |s| sink.borrow_mut().push(s)));
        let sink = Rc::clone(&menus);
        p.transcript.on_menu = Some(Box::new(move |items, anchor| sink.borrow_mut().push((items, anchor))));
        p.transcript.on_create_captions = Some(Box::new(move |()| *creates.borrow_mut() += 1));
        p.transcript.on_confirm_overwrite = Some(Box::new(move |()| *overwrites.borrow_mut() += 1));
        p.transcript.on_mark_hits = Some(Box::new(move |hit| marks.borrow_mut().push(hit)));
        p
    }

    pub fn size(&self) -> CGSize {
        self.size
    }

    pub fn set_size(&mut self, size: CGSize) {
        self.size = size;
        self.layout_pages();
    }

    /// Applies `theme` to every tab.
    pub fn set_theme(&mut self, theme: DrawTheme) {
        self.theme = theme;
        self.captions.theme = theme;
        self.style.set_theme(theme);
        self.transcript.theme = theme;
    }

    /// The tabs the switch shows, in order.
    pub fn tabs(&self) -> &[Tab] {
        &self.tabs
    }

    pub fn tab(&self) -> Tab {
        self.tab
    }

    /// Adds the Transcribe tab (shown first, as on the Mac) and opens it. The host hands each sequence's model in with
    /// `set_transcript_model`.
    pub fn use_transcription(&mut self) {
        self.tabs = Tab::ALL.to_vec();
        self.tab = Tab::Transcript;
    }

    /// The transcript model of the active sequence; `None` = no sequence.
    pub fn set_transcript_model(&mut self, model: Option<SharedModel>) {
        self.transcript.set_model(model);
    }

    fn body(&self) -> CGRect {
        CGRect::new(0.0, Self::BAR_HEIGHT, self.size.width, (self.size.height - Self::BAR_HEIGHT).max(0.0))
    }

    fn layout_pages(&mut self) {
        let body = self.body();
        let size = CGSize { width: body.width, height: body.height };
        self.captions.size = size;
        self.style.set_size(size);
        self.transcript.size = size;
    }

    pub fn select(&mut self, s: &EditorSession, t: Tab) {
        if t == self.tab || !self.tabs.contains(&t) {
            return;
        }
        self.tab = t;
        if t == Tab::Style {
            self.style.refresh(s);
        }
    }

    pub fn frame(&self, t: Tab) -> CGRect {
        let mut x = Self::PAD + Self::TRACK_PADDING;
        for k in self.tabs.iter().filter(|k| k.raw_value() < t.raw_value()) {
            x += self.segment_widths[k.raw_value()];
        }
        let y = ((Self::BAR_HEIGHT - Self::SEGMENT_HEIGHT) / 2.0).round();
        CGRect::new(x, y, self.segment_widths[t.raw_value()], Self::SEGMENT_HEIGHT)
    }

    fn tab_at(&self, p: CGPoint) -> Option<Tab> {
        if p.y >= Self::BAR_HEIGHT {
            return None;
        }
        self.tabs.iter().copied().find(|t| self.frame(*t).contains(p))
    }

    fn local(p: CGPoint) -> CGPoint {
        CGPoint::new(p.x, p.y - Self::BAR_HEIGHT)
    }

    // MARK: Session to UI

    /// A project or selection change.
    pub fn sync(&mut self, s: &EditorSession) {
        self.captions.sync(s);
        if self.tab == Tab::Style {
            self.style.refresh(s);
        }
    }

    // MARK: Collected requests

    /// Passes on what the tabs asked since the last call: menus and statuses at once, color pickers when the host has
    /// one (without it the picker closes at once).
    fn flush(&mut self, s: &mut EditorSession) {
        let menus: Vec<_> = self.menus.borrow_mut().drain(..).collect();
        for (items, anchor) in menus {
            if let Some(f) = self.on_menu.as_mut() {
                f(items, Self::below_bar(anchor));
            }
        }
        let colors: Vec<_> = self.colors.borrow_mut().drain(..).collect();
        for (current, anchor) in colors {
            match self.on_pick_color.as_mut() {
                Some(f) => f(current, Self::below_bar(anchor)),
                None => self.style.color_picked(s, None),
            }
        }
        let creates = std::mem::take(&mut *self.creates.borrow_mut());
        for _ in 0..creates {
            if let Some(f) = self.on_create_captions.as_mut() {
                f(());
            }
        }
        let overwrites = std::mem::take(&mut *self.overwrites.borrow_mut());
        for _ in 0..overwrites {
            if let Some(f) = self.on_confirm_overwrite.as_mut() {
                f(());
            }
        }
        let marks: Vec<_> = self.marks.borrow_mut().drain(..).collect();
        for hit in marks {
            if let Some(f) = self.on_mark_hits.as_mut() {
                f(hit);
            }
        }
        let statuses: Vec<_> = self.statuses.borrow_mut().drain(..).collect();
        for line in statuses {
            if let Some(f) = self.on_status.as_mut() {
                f(line);
            }
        }
    }

    fn below_bar(r: CGRect) -> CGRect {
        CGRect::new(r.min_x(), r.min_y() + Self::BAR_HEIGHT, r.width, r.height)
    }

    /// Runs what the closed menu (or the answered name prompt) of a tab queued.
    pub fn run_commands(&mut self, s: &mut EditorSession) {
        self.captions.run_menu_commands(s);
        self.style.run_commands(s);
        self.flush(s);
    }

    /// The host's answer to `on_pick_color`: each change, then `None` when the picker closed.
    pub fn color_picked(&mut self, s: &mut EditorSession, color: Option<EffectColor>) {
        self.style.color_picked(s, color);
        self.flush(s);
    }

    // MARK: Drawing

    pub fn draw(&mut self, c: &mut Canvas, s: &EditorSession, ui: &mut UiCx) {
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        c.fill(CGRect::new(0.0, 0.0, self.size.width, self.size.height), t.panel());
        if c.atlas().is_some() {
            for k in Tab::ALL {
                self.segment_widths[k.raw_value()] =
                    c.size_of(&SQL10n::string(k.title()), fs, 0).width.ceil() + 2.0 * Self::SEGMENT_INSET;
            }
        }
        // The pills sit flat on the panel (artifact: only the active pill has a fill, no track behind them).
        for k in self.tabs.clone() {
            let (f, on) = (self.frame(k), k == self.tab);
            if on || self.hover_tab == Some(k) || self.pressed_tab == Some(k) {
                c.fill_rounded(
                    f.inset_by(0.0, Self::TRACK_PADDING),
                    f64::from(radius::SMALL),
                    if on { t.raised() } else { t.hover() },
                );
            }
            c.draw_text_in(
                &SQL10n::string(k.title()),
                f,
                fs,
                if on { t.label() } else { t.label2() },
                TextAlign::Center,
                0.0,
                0,
            );
        }
        let language = self.transcript.language_name();
        if let Some(note) = self.tab.bar_note(language.as_deref(), s.caption_items().len()) {
            let first_end = self.tabs.last().map_or(0.0, |k| self.frame(*k).max_x());
            let w = (self.size.width - first_end - 2.0 * Self::PAD).max(0.0);
            c.draw_text_in(
                &SQL10n::string(&note),
                CGRect::new(self.size.width - Self::PAD - w, 0.0, w, Self::BAR_HEIGHT),
                f64::from(type_size::CAPTION),
                t.label3(),
                TextAlign::Right,
                0.0,
                0,
            );
        }
        c.save_gstate();
        c.clip_to(self.body());
        c.translate_by(0.0, Self::BAR_HEIGHT);
        match self.tab {
            Tab::Transcript => {
                self.transcript.playhead = s.playhead();
                self.transcript.draw(c, ui);
            }
            Tab::Captions => self.captions.draw(c, s, ui),
            Tab::Style => self.style.draw(c, ui),
        }
        c.restore_gstate();
    }

    // MARK: Pointer and keys

    pub fn mouse_moved(&mut self, p: Option<CGPoint>, ui: &mut UiCx) {
        self.hover_tab = p.and_then(|p| self.tab_at(p));
        let q = p.filter(|p| p.y >= Self::BAR_HEIGHT).map(Self::local);
        match self.tab {
            Tab::Transcript => self.transcript.mouse_moved(q),
            Tab::Captions => self.captions.mouse_moved(q),
            Tab::Style => self.style.mouse_moved(q, ui),
        }
    }

    pub fn mouse_down(
        &mut self,
        s: &mut EditorSession,
        ui: &mut UiCx,
        p: CGPoint,
        m: InputModifiers,
        click_count: Option<i64>,
    ) {
        if p.y < Self::BAR_HEIGHT {
            self.pressed_tab = self.tab_at(p);
            self.page_pressed = false;
            return;
        }
        self.page_pressed = true;
        let q = Self::local(p);
        match self.tab {
            Tab::Transcript => self.transcript.mouse_down(q, m, click_count),
            Tab::Captions => self.captions.mouse_down(s, q, m, click_count),
            Tab::Style => self.style.mouse_down(s, ui, q, m, click_count),
        }
        self.flush(s);
    }

    pub fn mouse_dragged(&mut self, s: &mut EditorSession, ui: &mut UiCx, p: CGPoint, m: InputModifiers) {
        if !self.page_pressed {
            return;
        }
        let q = Self::local(p);
        match self.tab {
            Tab::Style => self.style.mouse_dragged(s, ui, q, m),
            Tab::Transcript => self.transcript.mouse_dragged(q),
            Tab::Captions => {}
        }
        self.flush(s);
    }

    pub fn mouse_up(&mut self, s: &mut EditorSession, ui: &mut UiCx, p: CGPoint) {
        if let Some(t) = self.pressed_tab.take() {
            if self.tab_at(p) == Some(t) {
                self.select(s, t);
            }
            return;
        }
        if !self.page_pressed {
            return;
        }
        self.page_pressed = false;
        let q = Self::local(p);
        match self.tab {
            Tab::Transcript => self.transcript.mouse_up(q),
            Tab::Captions => self.captions.mouse_up(s, q),
            Tab::Style => self.style.mouse_up(s, ui, q),
        }
        self.flush(s);
    }

    pub fn scroll(&mut self, p: CGPoint, dy: f64) -> bool {
        if p.y < Self::BAR_HEIGHT {
            return false;
        }
        let q = Self::local(p);
        match self.tab {
            Tab::Transcript => self.transcript.scroll(q, dy),
            Tab::Captions => self.captions.scroll(q, dy),
            Tab::Style => self.style.scroll(q, dy),
        }
    }

    pub fn key(&mut self, s: &mut EditorSession, ui: &mut UiCx, k: InputKey, m: InputModifiers) -> bool {
        let handled = match self.tab {
            Tab::Transcript => self.transcript.key(k, m, ui),
            Tab::Captions => self.captions.key(s, ui, k, m),
            Tab::Style => self.style.key(s, ui, k, m),
        };
        self.flush(s);
        handled
    }

    /// Commits every open field of the three tabs, so none stays open without the keyboard (a menu chord, a press in
    /// another panel).
    pub fn end_text_edits(&mut self, s: &mut EditorSession, ui: &mut UiCx) {
        self.transcript.end_text_edits();
        self.captions.end_text_edits(s);
        self.style.end_text_edits(s, ui);
        self.flush(s);
    }

    /// Per frame; true while the Look tab's gallery previews a look (the host keeps redrawing).
    pub fn tick(&mut self, s: &mut EditorSession, now: f64) -> bool {
        let busy = self.tab == Tab::Style && self.style.tick(s, now);
        self.flush(s);
        busy
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        if p.y < Self::BAR_HEIGHT {
            return None;
        }
        let q = Self::local(p);
        match self.tab {
            Tab::Transcript => self.transcript.help(q),
            Tab::Captions => self.captions.help(q),
            Tab::Style => self.style.help(q),
        }
    }

    /// Typing in a field of the shown tab (the host keeps IME on while it is open).
    pub fn is_editing_text(&self) -> bool {
        match self.tab {
            Tab::Style => self.style.is_editing_text(),
            Tab::Transcript => self.transcript.is_editing_text(),
            Tab::Captions => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{CaptionHorizontal, CaptionVertical, Project, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::{IdSource, SequentialIds, Time};
    use sq_editor_session::SessionDeps;
    use std::collections::BTreeSet;

    use crate::captions::style_tab_draw::Control;

    /// A session with one caption that is not selected, so the Look tab edits the track look.
    fn session() -> EditorSession {
        let mut ids = SequentialIds::default();
        let tracks = vec![Track::new(ids.next_id(), TrackKind::Video), Track::new(ids.next_id(), TrackKind::Audio)];
        let tl = Timeline::new(ids.next_id(), "Main", SequenceFormat::new(Time::new(1, 30)), tracks);
        let project = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
        let dir = std::env::temp_dir().join(format!("sq-inspector-ui-text-panel-{}", std::process::id()));
        let mut deps = SessionDeps::headless(dir);
        deps.ids = Box::new(SequentialIds::default());
        let mut s = EditorSession::new(project, deps);
        assert!(s.add_caption_at_playhead().is_some());
        s.set_selection(BTreeSet::new(), BTreeSet::new());
        s
    }

    fn panel() -> TextPanelDraw {
        let style = CaptionStyleTabDraw::new(Box::new(Vec::new), Box::new(SequentialIds::default()));
        let mut p = TextPanelDraw::new(CaptionsTabDraw::new(), style);
        p.set_size(CGSize { width: 340.0, height: 4000.0 });
        p
    }

    fn click(p: &mut TextPanelDraw, s: &mut EditorSession, at: CGPoint) {
        let mut cx = UiCx::new();
        p.mouse_down(s, &mut cx, at, InputModifiers::NONE, Some(1));
        p.mouse_up(s, &mut cx, at);
    }

    fn click_look(p: &mut TextPanelDraw, s: &mut EditorSession, k: &Control) {
        let f = p.style.frame(k).expect("control shown");
        click(p, s, CGPoint::new(f.mid_x(), f.mid_y() + TextPanelDraw::BAR_HEIGHT));
    }

    fn open_look_tab(p: &mut TextPanelDraw, s: &mut EditorSession) {
        let f = p.frame(Tab::Style);
        click(p, s, CGPoint::new(f.mid_x(), f.mid_y()));
        assert_eq!(p.tab(), Tab::Style);
    }

    #[test]
    fn the_bar_names_the_two_steps() {
        assert_eq!(Tab::Transcript.title(), "Transcript");
        assert_eq!(Tab::Captions.title(), "Captions");
        assert_eq!(Tab::Style.title(), "Style");
        // Audit A26: the steps are named beside their buttons only, never twice.
        assert_eq!(Tab::Transcript.bar_note(Some("English (US)"), 0).as_deref(), Some("English (US)"));
        assert_eq!(Tab::Transcript.bar_note(None, 0), None);
        assert_eq!(Tab::Captions.bar_note(None, 6).as_deref(), Some("6 captions"));
        assert_eq!(Tab::Captions.bar_note(None, 1).as_deref(), Some("1 caption"));
        assert_eq!(Tab::Style.bar_note(None, 6).as_deref(), Some("Applies to 6 captions"));
    }

    #[test]
    fn the_tab_list_is_exactly_transcript_captions_style() {
        let titles: Vec<_> = Tab::ALL.iter().map(|t| t.title()).collect();
        assert_eq!(titles, ["Transcript", "Captions", "Style"]);
        let mut p = panel();
        p.use_transcription();
        let titles: Vec<_> = p.tabs().iter().map(|t| t.title()).collect();
        assert_eq!(titles, ["Transcript", "Captions", "Style"]);
    }

    #[test]
    fn use_transcription_adds_the_tab_first_and_opens_it() {
        let mut s = session();
        let mut p = panel();
        p.use_transcription();
        assert_eq!(p.tabs(), &Tab::ALL);
        assert_eq!(p.tab(), Tab::Transcript);
        // No sequence model: the empty state draws, and the Look tab is one click away.
        let mut c = Canvas::with_size(340.0, 4000.0, None, 1.0);
        p.draw(&mut c, &s, &mut UiCx::new());
        assert!(p.transcript.shows_empty_state());
        open_look_tab(&mut p, &mut s);
    }

    #[test]
    fn the_switch_shows_two_tabs_until_transcription_and_a_click_selects_one() {
        let mut s = session();
        let mut p = panel();
        assert_eq!(p.tabs(), &[Tab::Captions, Tab::Style]);
        assert_eq!(p.tab(), Tab::Captions);
        open_look_tab(&mut p, &mut s);
        assert!(p.style.state_shown());
    }

    #[test]
    fn position_segment_moves_the_captions_in_one_undo_step() {
        let mut s = session();
        let mut p = panel();
        open_look_tab(&mut p, &mut s);
        click_look(&mut p, &mut s, &Control::Vertical(0));
        assert_eq!(s.caption_position().vertical, CaptionVertical::Top);
        click_look(&mut p, &mut s, &Control::Horizontal(2));
        assert_eq!(s.caption_position().horizontal, CaptionHorizontal::Right);
        assert!(s.undo());
        assert_eq!(s.caption_position().horizontal, CaptionHorizontal::Center);
        assert_eq!(s.caption_position().vertical, CaptionVertical::Top);
    }

    #[test]
    fn word_highlight_turns_on_and_keep_spoken_follows() {
        let mut s = session();
        let mut p = panel();
        open_look_tab(&mut p, &mut s);
        assert!(s.caption_karaoke().is_none());
        click_look(&mut p, &mut s, &Control::Karaoke);
        assert!(s.caption_karaoke().is_some());
        click_look(&mut p, &mut s, &Control::KaraokeKeep);
        assert_eq!(s.caption_karaoke().map(|k| k.keep_spoken), Some(true));
        click_look(&mut p, &mut s, &Control::Karaoke);
        assert!(s.caption_karaoke().is_none());
    }
}

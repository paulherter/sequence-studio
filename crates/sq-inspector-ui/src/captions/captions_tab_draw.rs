// Swift: Draw/CaptionsTabDraw.swift
//! The List tab of the Captions panel on the shared toolkit. Find / Replace With / Replace All / Match Case, the captions
//! of the sequence as a list (start time, text; a click selects and seeks, Command and Shift extend, a double-click or
//! Return types into the caption: one undo step per Return), the row context menu, and the footer with the caption count
//! and Create Captions. Everything edits through `EditorSession`; every call that edits takes the session (the Swift
//! class held it). Coordinates: points, y down, (0, 0) = the tab's top-left.
//
// Translate Captions: the row is always in the menu like Swift's, dimmed while `translation_targets` is empty (Swift
// on Windows has no translator; the Mac fills the list from Apple Translation). A backend sets the targets and hears
// the chosen code through `on_translate`.

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;

use sq_core_audio::{CaptionTidyOptions, TimelineCaptionsExt};
use sq_core_model::CaptionItem;
use sq_core_time::{Id, Time};
use sq_draw::inspector::inspector_controls::{CheckState, InspectorDraw};
use sq_draw::inspector::scrub_field_control::ClickCounter;
use sq_draw::inspector::text_field_control::TextFieldControl;
use sq_draw::theme::type_size;
use sq_draw::{Alignment, Canvas, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_editor_session::EditorSession;
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_transcribe::subtitle_reader::SubtitleReader;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;
use sq_uikit::timecode::Timecode;

use crate::captions::list_draw::CaptionListDraw;
use crate::captions::list_model::{CaptionListModel, CaptionListRow};
use crate::captions::search::caption_match;
use crate::ec::inspector_text_formats::AnimationPresetName;

/// What can be hovered, pressed or focused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Control {
    Find,
    Replace,
    ReplaceAll,
    MatchCase,
    List,
    Create,
}

/// What a row of the open context menu does once the host closes the menu (the rows hold no session): the host calls
/// `run_menu_commands`.
#[derive(Clone, Debug, PartialEq)]
pub enum CaptionsMenuCommand {
    EditInText,
    SplitAtPlayhead,
    Merge,
    SetLook(String),
    ResetToTrackLook,
    Tidy,
    Translate(String),
    AddCaption,
    NewTrack,
    ImportSubtitles,
    ExportSrt,
    Delete,
}

type Notify<T> = Option<Box<dyn FnMut(T)>>;

/// What the open row field types into: the caption's text, or its start (the timecode column).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Typing {
    Text,
    Start,
}
/// Opens a menu: the rows and the anchor.
pub type MenuFn = Box<dyn FnMut(Vec<SQMenuItem>, CGRect)>;

pub struct CaptionsTabDraw {
    pub theme: DrawTheme,
    pub size: CGSize,
    /// Seconds for double-click timing (the host's clock).
    pub clock: Box<dyn Fn() -> f64>,
    /// The context menu and its anchor in tab points.
    pub on_menu: Option<MenuFn>,
    pub on_seek: Notify<Time>,
    pub on_status: Notify<String>,
    /// Create Captions (the host's dialog); `None`: no transcript, the button is dimmed.
    pub on_create_captions: Notify<()>,
    /// Import Subtitles / Export SRT: the host asks for a file.
    pub on_import_srt: Notify<()>,
    pub on_export_srt: Notify<()>,
    /// Languages a translator can write, as BCP-47 codes with English names, sorted by name (empty: no translator).
    pub translation_targets: Vec<(String, String)>,
    /// A language of the Translate Captions submenu was chosen (BCP-47 code); the host runs `translate_captions`.
    pub on_translate: Notify<String>,
    /// Why Create Captions is dimmed (its tooltip).
    pub create_hint: String,
    list: CaptionListDraw,
    find: TextFieldControl,
    replace: TextFieldControl,
    match_case: bool,
    editing: Option<(Id, Typing, TextFieldControl)>,
    focus: Option<Control>,
    hover: Option<Control>,
    pressed: Option<Control>,
    anchor: Option<usize>,
    counter: ClickCounter,
    menu_sink: Rc<RefCell<Vec<CaptionsMenuCommand>>>,
}

impl Default for CaptionsTabDraw {
    fn default() -> Self {
        Self::new()
    }
}

impl CaptionsTabDraw {
    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit): Spacing.sm 6, Metrics.quietField 22;
    // upgrade when the tokens move into a portable file.
    pub const PAD: f64 = 6.0;
    pub const FIELD_HEIGHT: f64 = 22.0;
    pub const GAP: f64 = 6.0;
    pub const FOOTER_HEIGHT: f64 = 38.0;
    pub const REPLACE_ALL_WIDTH: f64 = 92.0;
    pub const CREATE_WIDTH: f64 = 132.0;

    pub fn new() -> CaptionsTabDraw {
        let body = f64::from(type_size::BODY);
        let field = || {
            let mut f = TextFieldControl::new("");
            f.alignment = Alignment::Left;
            f.font_size = body;
            f
        };
        let mut list = CaptionListDraw::default();
        list.insets = (Self::PAD, Self::PAD);
        CaptionsTabDraw {
            theme: DrawTheme::default(),
            size: CGSize { width: 320.0, height: 400.0 },
            clock: Box::new(|| 0.0),
            on_menu: None,
            on_seek: None,
            on_status: None,
            on_create_captions: None,
            on_import_srt: None,
            on_export_srt: None,
            translation_targets: Vec::new(),
            on_translate: None,
            create_hint: "Transcribe the sequence first".to_string(),
            list,
            find: field(),
            replace: field(),
            match_case: false,
            editing: None,
            focus: None,
            hover: None,
            pressed: None,
            anchor: None,
            counter: ClickCounter::new(),
            menu_sink: Rc::new(RefCell::new(Vec::new())),
        }
    }

    pub fn list(&self) -> &CaptionListDraw {
        &self.list
    }

    pub fn is_editing_caption(&self) -> bool {
        self.editing.is_some()
    }

    pub fn match_case(&self) -> bool {
        self.match_case
    }

    pub fn focus(&self) -> Option<Control> {
        self.focus
    }

    pub fn frame(&self, k: Control) -> CGRect {
        let (w, pad, fh) = (self.size.width, Self::PAD, Self::FIELD_HEIGHT);
        let inner = (w - 2.0 * pad).max(0.0);
        let row_y = pad + fh + Self::GAP;
        let check_y = row_y + fh + Self::GAP;
        let top = check_y + fh + 8.0;
        match k {
            Control::Find => CGRect::new(pad, pad, inner, fh),
            Control::Replace => CGRect::new(pad, row_y, (inner - Self::REPLACE_ALL_WIDTH - 8.0).max(40.0), fh),
            Control::ReplaceAll => CGRect::new(w - pad - Self::REPLACE_ALL_WIDTH, row_y, Self::REPLACE_ALL_WIDTH, fh),
            Control::MatchCase => CGRect::new(pad, check_y, 120.0, fh),
            Control::List => CGRect::new(0.0, top, w, (self.size.height - Self::FOOTER_HEIGHT - top).max(0.0)),
            Control::Create => CGRect::new(
                w - pad - Self::CREATE_WIDTH,
                self.size.height - Self::FOOTER_HEIGHT + (Self::FOOTER_HEIGHT - fh) / 2.0,
                Self::CREATE_WIDTH,
                fh,
            ),
        }
    }

    pub fn control_at(&self, p: CGPoint) -> Option<Control> {
        [Control::Find, Control::Replace, Control::ReplaceAll, Control::MatchCase, Control::List, Control::Create]
            .into_iter()
            .find(|&k| self.frame(k).contains(p))
    }

    // MARK: Model

    pub fn rows(&self) -> &[CaptionListRow] {
        self.list.model().rows()
    }

    /// The selected captions in list order.
    pub fn selected_ids(&self, session: &EditorSession) -> Vec<Id> {
        self.rows().iter().map(|r| r.id).filter(|id| session.caption_selection().contains(id)).collect()
    }

    fn find_text(&self) -> String {
        self.find.editor().map_or_else(|| self.find.text.clone(), |e| e.string())
    }

    /// Reads the sequence's captions, the selection and the playhead.
    pub fn sync(&mut self, session: &EditorSession) {
        if let Some(tl) = session.active_timeline() {
            self.list.set_model(CaptionListModel::from_timeline(Some(tl), &Self::timecode(session), false));
        } else {
            self.list.set_model(CaptionListModel::new());
        }
        self.list.set_selected(session.caption_selection().clone());
        self.list.set_playhead(session.playhead());
        self.list.clamp_scroll(self.frame(Control::List).height);
        if let Some((id, ..)) = &self.editing
            && !self.rows().iter().any(|r| r.id == *id)
        {
            self.editing = None;
        }
    }

    /// Footer text: the caption count, or the match count while a Find text is set.
    pub fn hint(&self, session: &EditorSession) -> String {
        let find = self.find_text();
        if !find.is_empty() {
            let n = session.active_timeline().map_or(0, |t| t.caption_matches(&find, self.match_case).len());
            return if n == 0 {
                SQL10n::string("No match")
            } else {
                SQL10n::format("%@ of %@ match", &[&n.to_string(), &self.rows().len().to_string()])
            };
        }
        let tracks = session.active_timeline().map_or(0, |t| t.caption_tracks.len());
        let count = i64::try_from(self.rows().len()).unwrap_or(i64::MAX);
        SQL10n::plural(count, "%@ caption", "%@ captions")
            + &if tracks > 1 { SQL10n::format(" on %@ tracks", &[&tracks.to_string()]) } else { String::new() }
    }

    fn status(&mut self, s: String) {
        if let Some(f) = self.on_status.as_mut() {
            f(s);
        }
    }

    // MARK: Actions

    /// Return in Find: the next caption that matches (Shift: the one before), from the selected caption or the playhead.
    pub fn step_find(&mut self, session: &mut EditorSession, forward: bool) {
        let find = self.find_text();
        if find.is_empty() {
            return;
        }
        let Some(tl) = session.active_timeline() else { return };
        let items = session.caption_items();
        let sel = self.selected_ids(session);
        let from = match sel.as_slice() {
            [one] => items.iter().find(|i| i.id == *one).map_or(session.playhead(), |i| i.range.start),
            _ => session.playhead(),
        };
        let Some(next) = caption_match(tl, &find, self.match_case, from, forward) else { return };
        session.select(BTreeSet::new(), BTreeSet::from([next]));
        if let Some(it) = items.iter().find(|i| i.id == next) {
            let start = it.range.start;
            if let Some(f) = self.on_seek.as_mut() {
                f(start);
            }
        }
        self.sync(session);
        if let Some(i) = self.rows().iter().position(|r| r.id == next) {
            self.reveal(i);
        }
    }

    pub fn replace_all(&mut self, session: &mut EditorSession) {
        let find = self.find_text();
        if find.is_empty() {
            return;
        }
        if find == self.replace.text {
            self.status(SQL10n::string("Find and Replace are the same: nothing to change."));
            return;
        }
        let skipped = if session.active_timeline().is_some_and(|t| t.caption_tracks.iter().any(|c| c.is_locked)) {
            SQL10n::string(" Locked caption tracks were skipped.")
        } else {
            String::new()
        };
        if let Some(n) = session.replace_caption_text(&find, &self.replace.text, self.match_case) {
            let msg = if n == 0 {
                SQL10n::string("No match.") + &skipped
            } else {
                SQL10n::plural(n, "Replaced %@ time.", "Replaced %@ times.") + &skipped
            };
            self.status(msg);
        }
        self.sync(session);
    }

    /// Opens typing on the caption's row (a double-click, Return on one selected row, Add Caption at Playhead).
    pub fn begin_editing(&mut self, session: &mut EditorSession, id: Id) {
        self.begin_typing(session, id, Typing::Text);
    }

    /// Whether a press at `p` on row `i` lands in the timecode column (left of the text column).
    fn in_time_column(&self, i: usize, p: CGPoint) -> bool {
        let lf = self.frame(Control::List);
        p.x - lf.min_x() < self.list.columns(i, lf.width).1.min_x()
    }

    /// Opens typing on the caption's start time (a double-click on the timecode).
    fn begin_editing_start(&mut self, session: &mut EditorSession, id: Id) {
        self.begin_typing(session, id, Typing::Start);
    }

    fn begin_typing(&mut self, session: &mut EditorSession, id: Id, what: Typing) {
        self.sync(session);
        let Some(i) = self.rows().iter().position(|r| r.id == id) else { return };
        self.commit_editing(session);
        self.end_field_editing();
        session.select(BTreeSet::new(), BTreeSet::from([id]));
        self.list.set_selected(BTreeSet::from([id]));
        self.reveal(i);
        let start = match what {
            Typing::Text => self.rows()[i].text.clone(),
            Typing::Start => self.rows()[i].time.clone(),
        };
        let mut f = TextFieldControl::new(&start);
        f.alignment = Alignment::Left;
        f.font_size = f64::from(type_size::BODY);
        f.mouse_down(None, 1);
        self.editing = Some((id, what, f));
        self.focus = Some(Control::List);
    }

    /// Writes the typed caption text or start (one undo step) and closes the row field.
    pub fn commit_editing(&mut self, session: &mut EditorSession) {
        let Some((id, what, mut field)) = self.editing.take() else { return };
        // A Return in the field already committed it.
        let text = field.commit().unwrap_or_else(|| field.text.clone());
        let row = self.rows().iter().find(|r| r.id == id).map(|r| (r.text.clone(), r.time.clone()));
        match (what, row) {
            (Typing::Text, Some((old, _))) if old != text => {
                session.set_caption_text(id, &text, false);
            }
            (Typing::Start, Some((_, old))) if old != text.trim() => self.commit_start(session, id, &text),
            _ => {}
        }
        self.sync(session);
    }

    /// Moves the caption to the typed start, keeping its length; a text that is no timecode changes nothing.
    fn commit_start(&mut self, session: &mut EditorSession, id: Id, text: &str) {
        let Some(start) = Self::timecode(session).parse(text) else {
            self.status(SQL10n::string("Type a start time like 00:00:02:00."));
            return;
        };
        session.move_caption(id, start.max(Time::ZERO));
    }

    /// The sequence's timecode (the list's start column).
    fn timecode(session: &EditorSession) -> Timecode {
        let fd = session.active_timeline().map_or(Time::new(1, 30), |t| t.frame_duration());
        Timecode::new(fd, fd == Time::new(1001, 30000) || fd == Time::new(1001, 60000))
    }

    /// Commits the caption being typed and the Find and Replace fields (a menu chord, a press in another panel).
    pub fn end_text_edits(&mut self, session: &mut EditorSession) {
        self.commit_editing(session);
        self.end_field_editing();
    }

    fn end_field_editing(&mut self) {
        let _ = self.find.commit();
        let _ = self.replace.commit();
    }

    fn reveal(&mut self, i: usize) {
        let h = self.frame(Control::List).height;
        let row = CaptionListDraw::ROW_HEIGHT;
        let (top, y) = (i as f64 * row, self.list.scroll_y());
        if top < y {
            self.list.scroll(y - top, h);
        } else if top + row > y + h {
            self.list.scroll(-(top + row - y - h), h);
        }
    }

    fn add_caption(&mut self, session: &mut EditorSession) {
        if let Some(id) = session.add_caption_at_playhead() {
            self.begin_editing(session, id);
        }
    }

    /// Rows of the right-click menu (the clicked row is selected first); the rows push `CaptionsMenuCommand`s.
    pub fn context_items(&self, session: &EditorSession) -> Vec<SQMenuItem> {
        let n = self.selected_ids(session).len();
        let at_playhead = session.active_timeline().is_some_and(|t| !t.captions_at(session.playhead()).is_empty());
        let has_timeline = session.active_timeline().is_some();
        let item = |title: &str, enabled: bool, cmd: CaptionsMenuCommand| {
            let sink = Rc::clone(&self.menu_sink);
            let mut i = SQMenuItem::new(title);
            i.is_enabled = enabled;
            i.action = Some(Rc::new(move || sink.borrow_mut().push(cmd.clone())));
            i
        };
        let looks = CaptionPresetLibrary::built_in()
            .style_ids()
            .into_iter()
            .map(|id| item(&AnimationPresetName::title(&id), n >= 1, CaptionsMenuCommand::SetLook(id)))
            .collect::<Vec<_>>();
        let mut look = SQMenuItem::new("Look");
        look.is_enabled = n >= 1;
        look.submenu = Some(looks);
        let mut translate = SQMenuItem::new("Translate Captions");
        translate.is_enabled = !self.rows().is_empty() && !self.translation_targets.is_empty();
        translate.submenu = Some(
            self.translation_targets
                .iter()
                .map(|(code, name)| {
                    let sink = Rc::clone(&self.menu_sink);
                    let cmd = CaptionsMenuCommand::Translate(code.clone());
                    let mut i = SQMenuItem::new(name);
                    i.action = Some(Rc::new(move || sink.borrow_mut().push(cmd.clone())));
                    i
                })
                .collect(),
        );
        let mut delete = item("Delete", n >= 1, CaptionsMenuCommand::Delete);
        delete.shortcut = sq_uikit::key_binding_text::KeyBindingText::delete_hint_here();
        vec![
            item("Edit in Text", n == 1, CaptionsMenuCommand::EditInText),
            item("Split Caption at Playhead", at_playhead, CaptionsMenuCommand::SplitAtPlayhead),
            item("Merge Captions", n >= 2, CaptionsMenuCommand::Merge),
            SQMenuItem::separator(),
            look,
            item(
                "Reset to Track Look",
                n >= 1 && session.selected_captions_have_overrides(),
                CaptionsMenuCommand::ResetToTrackLook,
            ),
            SQMenuItem::separator(),
            item("Tidy for Short Video", !self.rows().is_empty(), CaptionsMenuCommand::Tidy),
            translate,
            SQMenuItem::separator(),
            item("Add Caption at Playhead", has_timeline, CaptionsMenuCommand::AddCaption),
            item("New Caption Track", has_timeline, CaptionsMenuCommand::NewTrack),
            item("Import Subtitles\u{2026}", self.on_import_srt.is_some(), CaptionsMenuCommand::ImportSubtitles),
            item(
                "Export SRT\u{2026}",
                !self.rows().is_empty() && self.on_export_srt.is_some(),
                CaptionsMenuCommand::ExportSrt,
            ),
            SQMenuItem::separator(),
            delete,
        ]
    }

    /// Runs the rows the closed menu picked.
    pub fn run_menu_commands(&mut self, session: &mut EditorSession) {
        let commands: Vec<_> = self.menu_sink.borrow_mut().drain(..).collect();
        for cmd in commands {
            match cmd {
                CaptionsMenuCommand::EditInText => {
                    if let Some(id) = self.selected_ids(session).first().copied() {
                        self.begin_editing(session, id);
                    }
                }
                CaptionsMenuCommand::SplitAtPlayhead => {
                    session.split_caption(None);
                }
                CaptionsMenuCommand::Merge => {
                    session.merge_selected_captions();
                }
                CaptionsMenuCommand::SetLook(id) => {
                    session.set_selected_caption_style(Some(&id));
                }
                CaptionsMenuCommand::ResetToTrackLook => {
                    session.reset_selected_captions_to_track_look();
                }
                CaptionsMenuCommand::Tidy => self.tidy(session),
                CaptionsMenuCommand::Translate(code) => {
                    self.status(SQL10n::string("Translating\u{2026}"));
                    if let Some(f) = self.on_translate.as_mut() {
                        f(code);
                    }
                }
                CaptionsMenuCommand::AddCaption => self.add_caption(session),
                CaptionsMenuCommand::NewTrack => self.new_track(session),
                CaptionsMenuCommand::ImportSubtitles => {
                    if let Some(f) = self.on_import_srt.as_mut() {
                        f(());
                    }
                }
                CaptionsMenuCommand::ExportSrt => {
                    if let Some(f) = self.on_export_srt.as_mut() {
                        f(());
                    }
                }
                CaptionsMenuCommand::Delete => {
                    session.delete_selected_captions();
                }
            }
            self.sync(session);
        }
    }

    fn tidy(&mut self, session: &mut EditorSession) {
        if let Some(n) = session.tidy_captions(&CaptionTidyOptions::tik_tok()) {
            let n = i64::try_from(n).unwrap_or(i64::MAX);
            self.status(SQL10n::plural(n, "Tidied: %@ caption.", "Tidied: %@ captions."));
        }
        self.sync(session);
    }

    fn new_track(&mut self, session: &mut EditorSession) {
        if let Some(id) = session.add_caption_track() {
            let name = session.active_timeline().and_then(|t| t.caption_track(id)).map(|t| t.name.clone());
            if let Some(name) = name {
                self.status(SQL10n::format("Added %@.", &[&name]));
            }
        }
        self.sync(session);
    }

    /// A click on row `i`: plain selects it (and seeks), Command toggles it, Shift selects the range from the anchor.
    fn select_row(&mut self, session: &mut EditorSession, i: usize, m: InputModifiers) {
        let mut ids: BTreeSet<Id> = self.selected_ids(session).into_iter().collect();
        let id = self.rows()[i].id;
        let anchor = self.anchor.filter(|a| *a < self.rows().len());
        if let (true, Some(a)) = (m.contains(InputModifiers::SHIFT), anchor) {
            ids = self.rows()[a.min(i)..=a.max(i)].iter().map(|r| r.id).collect();
        } else if m.contains(InputModifiers::COMMAND) {
            if !ids.remove(&id) {
                ids.insert(id);
            }
            self.anchor = Some(i);
        } else {
            ids = BTreeSet::from([id]);
            self.anchor = Some(i);
        }
        let seek = ids.len() == 1 && ids.contains(&id);
        session.select(BTreeSet::new(), ids.clone());
        self.list.set_selected(ids);
        if seek {
            let start = self.rows()[i].range.start;
            if let Some(f) = self.on_seek.as_mut() {
                f(start);
            }
        }
    }

    // MARK: Subtitle files (the host picks the file)

    /// Reads a picked subtitle file onto the caption track (one undo step) and reports the count or the reason.
    pub fn import_subtitles(&mut self, session: &mut EditorSession, data: &[u8], file_extension: &str) {
        let format = SubtitleReader::format_for_extension(&file_extension.to_lowercase())
            .unwrap_or(sq_transcribe::subtitle_reader::Format::Srt);
        let msg = match session.import_srt(data, format) {
            Some(n) => {
                SQL10n::plural(i64::try_from(n).unwrap_or(i64::MAX), "Imported %@ caption.", "Imported %@ captions.")
            }
            None => session
                .last_error()
                .map_or_else(|| SQL10n::string("Could not import the subtitle file."), str::to_string),
        };
        self.status(msg);
        self.sync(session);
    }

    /// What Export SRT writes: the captions of every visible caption track, in time order.
    pub fn export_items(session: &EditorSession) -> Vec<CaptionItem> {
        let mut items: Vec<CaptionItem> = session
            .active_timeline()
            .map(|t| t.caption_tracks.iter().filter(|c| c.is_visible).flat_map(|c| c.items()).cloned().collect())
            .unwrap_or_default();
        items.sort_by_key(|i| i.range.start);
        items
    }

    // MARK: Drawing

    pub fn draw(&mut self, c: &mut Canvas, session: &EditorSession, ui: &mut UiCx) {
        self.sync(session);
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        c.fill(CGRect::new(0.0, 0.0, self.size.width, self.size.height), t.panel());
        self.draw_field(c, Control::Find, "Find", ui);
        self.draw_field(c, Control::Replace, "Replace with", ui);
        let has_find = !self.find_text().is_empty();
        InspectorDraw::button(
            c,
            &SQL10n::string("Replace All"),
            self.frame(Control::ReplaceAll),
            self.hover == Some(Control::ReplaceAll),
            self.pressed == Some(Control::ReplaceAll),
            has_find && !self.rows().is_empty(),
            false,
            Self::FIELD_HEIGHT,
            &t,
        );
        let mc = self.frame(Control::MatchCase);
        let boxed = CGRect::new(mc.min_x(), mc.mid_y() - 7.0, 14.0, 14.0);
        InspectorDraw::checkbox(
            c,
            if self.match_case { CheckState::On } else { CheckState::Off },
            boxed,
            self.hover == Some(Control::MatchCase),
            self.pressed == Some(Control::MatchCase),
            true,
            false,
            &t,
        );
        c.draw_text_in(
            &SQL10n::string("Match case"),
            CGRect::new(boxed.max_x() + 6.0, mc.min_y(), mc.width - 20.0, mc.height),
            fs,
            t.label(),
            TextAlign::Left,
            0.0,
            0,
        );

        let lf = self.frame(Control::List);
        if self.rows().is_empty() {
            let mid = lf.mid_y();
            c.draw_text_in(
                &SQL10n::string("No captions yet"),
                CGRect::new(Self::PAD, mid - 20.0, lf.width - 2.0 * Self::PAD, 18.0),
                fs,
                t.label2(),
                TextAlign::Center,
                0.0,
                0,
            );
            c.draw_wrapped(
                &SQL10n::string("Transcribe the sequence first, then create captions from the transcript."),
                CGRect::new(Self::PAD * 3.0, mid, (lf.width - 6.0 * Self::PAD).max(0.0), 40.0),
                f64::from(type_size::CAPTION),
                15.0,
                t.label3(),
            );
        } else {
            c.save_gstate();
            c.translate_by(lf.min_x(), lf.min_y());
            self.list.draw(c, lf.width, lf.height, &t);
            if let Some((id, what, field)) = &self.editing
                && let Some(i) = self.rows().iter().position(|r| r.id == *id)
            {
                let cols = self.list.columns(i, lf.width);
                let col = if *what == Typing::Start { cols.0 } else { cols.1 };
                if col.max_y() > 0.0 && col.min_y() < lf.height {
                    c.clip_to(CGRect::new(0.0, 0.0, lf.width, lf.height));
                    field.draw(c, col.inset_by(-4.0, 1.0), &t, true, ui);
                }
            }
            c.restore_gstate();
        }

        // Footer: a line, the count, Create Captions.
        let fy = self.size.height - Self::FOOTER_HEIGHT;
        c.fill(CGRect::new(0.0, fy, self.size.width, 1.0), t.divider());
        let cf = self.frame(Control::Create);
        c.draw_text_in(
            &self.hint(session),
            CGRect::new(Self::PAD, fy, (cf.min_x() - 2.0 * Self::PAD).max(0.0), Self::FOOTER_HEIGHT),
            fs,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        InspectorDraw::button(
            c,
            &SQL10n::string("Create Captions\u{2026}"),
            cf,
            self.hover == Some(Control::Create),
            self.pressed == Some(Control::Create),
            self.on_create_captions.is_some(),
            false,
            Self::FIELD_HEIGHT,
            &t,
        );
    }

    fn draw_field(&mut self, c: &mut Canvas, k: Control, placeholder: &str, ui: &mut UiCx) {
        let hovering = self.hover == Some(k);
        let focused = self.focus == Some(k);
        let t = self.theme;
        let r = self.frame(k);
        let f = if k == Control::Find { &mut self.find } else { &mut self.replace };
        f.hovering = hovering;
        f.draw(c, r, &t, focused, ui);
        if f.text.is_empty() && !f.is_editing() {
            c.draw_text_in(
                &SQL10n::string(placeholder),
                r.inset_by(6.0, 0.0),
                f.font_size,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
    }

    // MARK: Pointer and keys

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        self.hover = p.and_then(|p| self.control_at(p));
        self.list.hovered = match (p, self.hover) {
            (Some(p), Some(Control::List)) => {
                let lf = self.frame(Control::List);
                self.list.row_at(CGPoint::new(p.x - lf.min_x(), p.y - lf.min_y()), lf.height)
            }
            _ => None,
        };
    }

    pub fn mouse_down(&mut self, session: &mut EditorSession, p: CGPoint, m: InputModifiers, click_count: Option<i64>) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, (self.clock)()));
        let k = self.control_at(p);
        self.pressed = k;
        // Leaving a field commits it.
        if k != Some(Control::Find) {
            let _ = self.find.commit();
        }
        if k != Some(Control::Replace) {
            let _ = self.replace.commit();
        }
        match k {
            Some(Control::Find) => {
                self.commit_editing(session);
                self.focus = k;
                self.find.mouse_down(None, 1);
            }
            Some(Control::Replace) => {
                self.commit_editing(session);
                self.focus = k;
                self.replace.mouse_down(None, 1);
            }
            Some(Control::List) => {
                self.focus = k;
                let lf = self.frame(Control::List);
                let q = CGPoint::new(p.x - lf.min_x(), p.y - lf.min_y());
                let Some(i) = self.list.row_at(q, lf.height) else {
                    self.commit_editing(session);
                    if m.contains(InputModifiers::SECONDARY) {
                        // The empty list has a menu too: Import Subtitles and Add Caption live there.
                        self.pressed = None;
                        let items = self.context_items(session);
                        if let Some(f) = self.on_menu.as_mut() {
                            f(items, CGRect::new(p.x, p.y, 1.0, 1.0));
                        }
                        return;
                    }
                    session.select(BTreeSet::new(), BTreeSet::new());
                    self.list.set_selected(BTreeSet::new());
                    return;
                };
                let id = self.rows()[i].id;
                // A press in the open field keeps typing; a press in the row's other column ends it (Add Caption opens the
                // text field, so the double-click on that row's timecode must not land in the text).
                let in_time = self.in_time_column(i, p);
                if self.editing.as_ref().is_some_and(|e| e.0 == id && (e.1 == Typing::Start) == in_time) {
                    return;
                }
                self.commit_editing(session);
                if m.contains(InputModifiers::SECONDARY) {
                    if !session.caption_selection().contains(&id) {
                        self.select_row(session, i, InputModifiers::default());
                    }
                    self.pressed = None;
                    let items = self.context_items(session);
                    if let Some(f) = self.on_menu.as_mut() {
                        f(items, CGRect::new(p.x, p.y, 1.0, 1.0));
                    }
                    return;
                }
                self.select_row(session, i, m);
                if n == 2 && !m.contains(InputModifiers::COMMAND) && !m.contains(InputModifiers::SHIFT) {
                    // The timecode column types the start, the rest of the row the text.
                    if in_time {
                        self.begin_editing_start(session, id);
                    } else {
                        self.begin_editing(session, id);
                    }
                }
            }
            _ => {
                self.commit_editing(session);
                self.focus = k;
            }
        }
    }

    pub fn mouse_up(&mut self, session: &mut EditorSession, p: CGPoint) {
        let k = self.pressed.take();
        if k.is_none() || self.control_at(p) != k {
            return;
        }
        match k {
            Some(Control::ReplaceAll) => self.replace_all(session),
            Some(Control::MatchCase) => self.match_case = !self.match_case,
            Some(Control::Create) => {
                if let Some(f) = self.on_create_captions.as_mut() {
                    f(());
                }
            }
            _ => {}
        }
    }

    /// The wheel scrolls the list.
    pub fn scroll(&mut self, p: CGPoint, dy: f64) -> bool {
        self.control_at(p) == Some(Control::List) && self.list.scroll(dy, self.frame(Control::List).height)
    }

    /// Keys: the open field first (Return in Find steps to the next match), then the list (Return types into the one
    /// selected caption, Delete removes the selected captions, Command-A selects all, Up / Down move the selection).
    pub fn key(&mut self, session: &mut EditorSession, ui: &mut UiCx, k: InputKey, m: InputModifiers) -> bool {
        if let Some((_, _, field)) = self.editing.as_mut() {
            let done = field.key(k, m, ui);
            if done.is_some() {
                self.commit_editing(session);
            } else if k == InputKey::Escape {
                self.editing = None;
            }
            return true;
        }
        if self.find.is_editing() {
            if k == InputKey::Enter {
                let _ = self.find.commit();
                self.step_find(session, !m.contains(InputModifiers::SHIFT));
                self.find.mouse_down(None, 1);
            } else if k == InputKey::Escape {
                self.find.cancel();
            } else {
                let _ = self.find.key(k, m, ui);
            }
            return true;
        }
        if self.replace.is_editing() {
            if k == InputKey::Enter {
                let _ = self.replace.commit();
                self.replace_all(session);
            } else {
                let _ = self.replace.key(k, m, ui);
            }
            return true;
        }
        if self.focus != Some(Control::List) {
            return false;
        }
        let sel = self.selected_ids(session);
        match k {
            InputKey::Enter if sel.len() == 1 => {
                self.begin_editing(session, sel[0]);
                true
            }
            InputKey::Delete | InputKey::Backspace => {
                if sel.is_empty() {
                    return false;
                }
                session.delete_selected_captions();
                self.sync(session);
                true
            }
            InputKey::Character('a') if m.contains(InputModifiers::COMMAND) => {
                let all = self.rows().iter().map(|r| r.id).collect();
                session.select(BTreeSet::new(), all);
                self.sync(session);
                true
            }
            InputKey::Up | InputKey::Down => {
                let count = self.rows().len();
                if count == 0 {
                    return false;
                }
                let up = k == InputKey::Up;
                let cur = sel.last().and_then(|id| self.rows().iter().position(|r| r.id == *id));
                let i = match (cur, up) {
                    (Some(c), true) => c.saturating_sub(1),
                    (Some(c), false) => (c + 1).min(count - 1),
                    (None, true) => count - 1,
                    (None, false) => 0,
                };
                self.select_row(
                    session,
                    i,
                    if m.contains(InputModifiers::SHIFT) { InputModifiers::SHIFT } else { InputModifiers::default() },
                );
                self.reveal(i);
                true
            }
            _ => false,
        }
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        match self.control_at(p)? {
            Control::Create if self.on_create_captions.is_none() => Some(SQL10n::string(&self.create_hint)),
            Control::MatchCase => Some(SQL10n::string("Match case")),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Project, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::{IdSource, SequentialIds};
    use sq_editor_session::SessionDeps;

    fn session() -> EditorSession {
        let mut ids = SequentialIds::default();
        let tracks = vec![Track::new(ids.next_id(), TrackKind::Video), Track::new(ids.next_id(), TrackKind::Audio)];
        let tl = Timeline::new(ids.next_id(), "Main", SequenceFormat::new(Time::new(1, 30)), tracks);
        let project = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
        let dir = std::env::temp_dir().join(format!("sq-inspector-ui-captions-tab-{}", std::process::id()));
        let mut deps = SessionDeps::headless(dir);
        deps.ids = Box::new(SequentialIds::default());
        EditorSession::new(project, deps)
    }

    fn with_captions(n: usize) -> (EditorSession, CaptionsTabDraw) {
        let mut s = session();
        let mut d = CaptionsTabDraw::new();
        for i in 0..n {
            s.seek(Time::new(i as i64 * 4, 1));
            assert!(s.add_caption_at_playhead().is_some());
        }
        d.sync(&s);
        (s, d)
    }

    fn center(r: CGRect) -> CGPoint {
        CGPoint::new(r.mid_x(), r.mid_y())
    }

    #[test]
    fn the_layout_stacks_find_replace_options_list_and_footer() {
        let d = CaptionsTabDraw::new();
        assert_eq!(d.frame(Control::Find), CGRect::new(6.0, 6.0, 308.0, 22.0));
        let (rep, all) = (d.frame(Control::Replace), d.frame(Control::ReplaceAll));
        assert_eq!((rep.y, rep.width, all.x), (34.0, 208.0, 222.0));
        assert_eq!(d.frame(Control::MatchCase).y, 62.0);
        let list = d.frame(Control::List);
        assert_eq!((list.y, list.max_y()), (92.0, 362.0));
        assert_eq!(d.control_at(center(d.frame(Control::Create))), Some(Control::Create));
        assert_eq!(d.control_at(CGPoint::new(1.0, 399.0)), None);
    }

    #[test]
    fn the_footer_counts_captions() {
        let (s, d) = with_captions(2);
        assert_eq!(d.rows().len(), 2);
        assert_eq!(d.hint(&s), "2 captions");
        assert_eq!(with_captions(1).1.hint(&with_captions(1).0), "1 caption");
    }

    #[test]
    fn a_click_selects_and_seeks_and_a_double_click_opens_typing() {
        let (mut s, mut d) = with_captions(3);
        let seeks = Rc::new(RefCell::new(Vec::new()));
        let sink = Rc::clone(&seeks);
        d.on_seek = Some(Box::new(move |t| sink.borrow_mut().push(t)));
        let lf = d.frame(Control::List);
        let row1 = CGPoint::new(lf.x + 100.0, lf.y + 24.0 + 12.0);
        d.mouse_down(&mut s, row1, InputModifiers::default(), Some(1));
        assert_eq!(d.selected_ids(&s), vec![d.rows()[1].id]);
        assert_eq!(*seeks.borrow(), vec![d.rows()[1].range.start]);
        d.mouse_down(&mut s, row1, InputModifiers::default(), Some(2));
        assert!(d.is_editing_caption());
    }

    /// Double-clicks the row's `column` (0 = timecode, 1 = text) and types `text` over what the field holds, then Return.
    fn double_click_and_type(s: &mut EditorSession, d: &mut CaptionsTabDraw, row: usize, column: usize, text: &str) {
        let lf = d.frame(Control::List);
        let (time, body) = d.list.columns(row, lf.width);
        let col = if column == 0 { time } else { body };
        let at = CGPoint::new(lf.x + col.mid_x(), lf.y + col.mid_y());
        d.mouse_down(s, at, InputModifiers::default(), Some(1));
        d.mouse_down(s, at, InputModifiers::default(), Some(2));
        assert!(d.is_editing_caption());
        let mut ui = UiCx::new();
        d.key(s, &mut ui, InputKey::Character('a'), InputModifiers::COMMAND);
        for ch in text.chars() {
            d.key(s, &mut ui, InputKey::Character(ch), InputModifiers::default());
        }
        d.key(s, &mut ui, InputKey::Enter, InputModifiers::default());
    }

    #[test]
    fn a_double_click_on_the_timecode_types_the_start_and_leaves_the_text() {
        let (mut s, mut d) = with_captions(2);
        let (id, before) = (d.rows()[1].id, d.rows()[1].clone());
        double_click_and_type(&mut s, &mut d, 1, 0, "00:00:05:00");
        let item = s.caption_item(id).expect("caption");
        assert_eq!(item.range.start, Time::new(5, 1));
        assert_eq!(item.range.duration, before.range.duration, "moving keeps the length");
        assert_eq!(d.rows()[1].text, before.text);
        assert!(!d.is_editing_caption());
    }

    /// Add Caption at Playhead opens the new row's text field; a double-click on that row's timecode used to land in that
    /// open field (the press was swallowed) and typed the start into the text.
    #[test]
    fn a_double_click_on_the_start_of_a_just_added_caption_types_the_start() {
        let (mut s, mut d) = with_captions(0);
        d.add_caption(&mut s);
        assert!(d.is_editing_caption(), "the new row opens its text");
        let (id, before) = (d.rows()[0].id, d.rows()[0].clone());
        double_click_and_type(&mut s, &mut d, 0, 0, "00:00:02:00");
        assert_eq!(s.caption_item(id).expect("caption").range.start, Time::new(2, 1));
        assert_eq!(d.rows()[0].text, before.text, "the text stays");
        assert!(!d.is_editing_caption());
    }

    #[test]
    fn a_double_click_on_the_text_still_types_the_text() {
        let (mut s, mut d) = with_captions(1);
        let (id, start) = (d.rows()[0].id, d.rows()[0].range.start);
        double_click_and_type(&mut s, &mut d, 0, 1, "Hello");
        assert_eq!(d.rows()[0].text, "Hello");
        assert_eq!(s.caption_item(id).expect("caption").range.start, start);
    }

    #[test]
    fn a_start_that_is_no_timecode_changes_nothing_and_says_so() {
        let (mut s, mut d) = with_captions(1);
        let said = Rc::new(RefCell::new(Vec::new()));
        let sink = Rc::clone(&said);
        d.on_status = Some(Box::new(move |t| sink.borrow_mut().push(t)));
        let (id, before) = (d.rows()[0].id, d.rows()[0].clone());
        double_click_and_type(&mut s, &mut d, 0, 0, "soon");
        assert_eq!(s.caption_item(id).expect("caption").range.start, before.range.start);
        assert_eq!(d.rows()[0].text, before.text);
        assert_eq!(said.borrow().len(), 1);
    }

    #[test]
    fn shift_extends_and_command_toggles_the_selection() {
        let (mut s, mut d) = with_captions(4);
        let lf = d.frame(Control::List);
        let at = |i: usize| CGPoint::new(lf.x + 100.0, lf.y + i as f64 * 24.0 + 12.0);
        d.mouse_down(&mut s, at(0), InputModifiers::default(), Some(1));
        d.mouse_down(&mut s, at(2), InputModifiers::SHIFT, Some(1));
        assert_eq!(d.selected_ids(&s).len(), 3);
        d.mouse_down(&mut s, at(1), InputModifiers::COMMAND, Some(1));
        assert_eq!(d.selected_ids(&s).len(), 2);
    }

    #[test]
    fn return_types_into_the_selected_caption_and_escape_drops_the_edit() {
        let (mut s, mut d) = with_captions(1);
        let mut ui = UiCx::new();
        let lf = d.frame(Control::List);
        d.mouse_down(&mut s, CGPoint::new(lf.x + 100.0, lf.y + 12.0), InputModifiers::default(), Some(1));
        assert!(d.key(&mut s, &mut ui, InputKey::Enter, InputModifiers::default()));
        assert!(d.is_editing_caption());
        assert!(d.key(&mut s, &mut ui, InputKey::Escape, InputModifiers::default()));
        assert!(!d.is_editing_caption());
    }

    #[test]
    fn delete_removes_the_selected_captions() {
        let (mut s, mut d) = with_captions(2);
        let mut ui = UiCx::new();
        let lf = d.frame(Control::List);
        d.mouse_down(&mut s, CGPoint::new(lf.x + 100.0, lf.y + 12.0), InputModifiers::default(), Some(1));
        assert!(d.key(&mut s, &mut ui, InputKey::Delete, InputModifiers::default()));
        assert_eq!(d.rows().len(), 1);
    }

    #[test]
    fn a_translator_fills_the_submenu_and_a_pick_reaches_the_host_with_its_code() {
        let (mut s, mut d) = with_captions(2);
        d.translation_targets = vec![("de".into(), "German".into()), ("fr".into(), "French".into())];
        let got = Rc::new(RefCell::new(Vec::new()));
        let sink = Rc::clone(&got);
        d.on_translate = Some(Box::new(move |c| sink.borrow_mut().push(c)));
        let items = d.context_items(&s);
        let row = items.iter().find(|i| i.title == SQL10n::string("Translate Captions")).expect("row");
        assert!(row.is_enabled);
        let sub = row.submenu.as_ref().expect("languages");
        assert_eq!(sub.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(), ["German", "French"]);
        sub[1].action.clone().expect("action")();
        d.run_menu_commands(&mut s);
        assert_eq!(*got.borrow(), vec!["fr".to_string()]);
    }

    #[test]
    fn a_right_click_on_the_empty_list_opens_the_menu_with_import_subtitles() {
        let (mut s, mut d) = with_captions(0);
        let got = Rc::new(RefCell::new(Vec::new()));
        let sink = Rc::clone(&got);
        d.on_menu = Some(Box::new(move |items, _| sink.borrow_mut().push(items)));
        d.on_import_srt = Some(Box::new(|()| {}));
        let lf = d.frame(Control::List);
        d.mouse_down(&mut s, CGPoint::new(lf.x + 100.0, lf.y + 12.0), InputModifiers::SECONDARY, Some(1));
        let menus = got.borrow();
        assert_eq!(menus.len(), 1);
        let import = menus[0].iter().find(|i| i.title == SQL10n::string("Import Subtitles\u{2026}")).expect("row");
        assert!(import.is_enabled);
    }

    #[test]
    fn the_context_menu_enables_rows_by_selection_and_runs_after_it_closes() {
        let (mut s, mut d) = with_captions(2);
        let items = d.context_items(&s);
        let by =
            |items: &[SQMenuItem], t: &str| items.iter().find(|i| i.title == SQL10n::string(t)).map(|i| i.is_enabled);
        assert_eq!(by(&items, "Merge Captions"), Some(false));
        assert_eq!(by(&items, "Tidy for Short Video"), Some(true));
        assert_eq!(
            by(&items, "Translate Captions"),
            Some(false),
            "no translator: the row is dimmed, as in Swift on Windows"
        );
        let lf = d.frame(Control::List);
        d.mouse_down(&mut s, CGPoint::new(lf.x + 100.0, lf.y + 12.0), InputModifiers::default(), Some(1));
        d.mouse_down(&mut s, CGPoint::new(lf.x + 100.0, lf.y + 36.0), InputModifiers::SHIFT, Some(1));
        let items = d.context_items(&s);
        assert_eq!(by(&items, "Merge Captions"), Some(true));
        let merge = items.iter().find(|i| i.title == SQL10n::string("Merge Captions")).and_then(|i| i.action.clone());
        merge.expect("merge action")();
        d.run_menu_commands(&mut s);
        assert_eq!(d.rows().len(), 1);
    }

    #[test]
    fn find_steps_to_the_matches_and_replace_all_reports() {
        let (mut s, mut d) = with_captions(2);
        let status = Rc::new(RefCell::new(Vec::new()));
        let sink = Rc::clone(&status);
        d.on_status = Some(Box::new(move |m| sink.borrow_mut().push(m)));
        d.find.text = "zzz".to_string();
        d.replace.text = "yyy".to_string();
        assert_eq!(d.hint(&s), "No match");
        d.replace_all(&mut s);
        assert_eq!(*status.borrow(), vec!["No match.".to_string()]);
        d.find.text = "yyy".to_string();
        d.replace_all(&mut s);
        assert_eq!(status.borrow().len(), 2);
        assert!(status.borrow()[1].contains("same"));
    }

    #[test]
    fn match_case_toggles_on_release_inside_and_help_names_the_dimmed_button() {
        let (mut s, mut d) = with_captions(0);
        let p = center(d.frame(Control::MatchCase));
        d.mouse_down(&mut s, p, InputModifiers::default(), Some(1));
        d.mouse_up(&mut s, p);
        assert!(d.match_case());
        assert_eq!(d.help(center(d.frame(Control::Create))).as_deref(), Some("Transcribe the sequence first"));
    }

    #[test]
    fn drawing_without_an_atlas_does_not_panic() {
        let (s, mut d) = with_captions(3);
        let mut c = Canvas::with_size(320.0, 400.0, None, 1.0);
        d.draw(&mut c, &s, &mut UiCx::new());
    }
}

// Swift: SQAppShell/TextHost.swift
//! The Text panel (Transcript, Captions, Style) as an app host. The panel edits the session of the [`HostCx`]; the
//! menus and status lines its tabs ask for wait in [`TextHost::take_menus`] and go out as app events.

use crate::color_popover::{ColorPopover, PickerAids, PopoverEvent};
use sq_app_shell::{AppEvent, AppHost, HostCx};
use sq_core_model::EffectColor;
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent, InputModifiers};
use sq_editor_session::Change;
use sq_inspector_ui::captions::captions_tab_draw::CaptionsTabDraw;
use sq_inspector_ui::captions::style_tab_draw::CaptionStyleTabDraw;
use sq_inspector_ui::text::block_draw::NameAsks;
use sq_inspector_ui::text::panel_draw::TextPanelDraw;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::rc::Rc;

mod look_host;
mod speech_flow;
mod srt_files;
mod translate_job;
use speech_flow::{Ask, Speech};
use srt_files::SrtAsk;
use translate_job::{TranslateJob, Work, real_work};

/// Mark All hits (times and search text) and picked colors, shared with the panel callbacks.
type MarkHits = Rc<RefCell<Vec<(Vec<sq_core_time::Time>, String)>>>;
type Picks = Rc<RefCell<Vec<(EffectColor, CGRect)>>>;
type Menus = Rc<RefCell<Vec<(Vec<SQMenuItem>, CGRect)>>>;

/// The Text panel in a dock slot.
pub struct TextHost {
    panel: TextPanelDraw,
    frame: CGRect,
    /// A press started inside the panel: drags and the release follow it outside the frame too.
    pressed: bool,
    menus: Menus,
    statuses: Rc<RefCell<Vec<String>>>,
    /// Mark All of the transcript search: hit times and the search text.
    marks: MarkHits,
    picks: Picks,
    /// The Look tab's color picker, open below the swatch that asked for it.
    popover: Option<ColorPopover<()>>,
    /// The recent colors and the monitor pipette the picker offers.
    picker_aids: PickerAids,
    /// The window (points): the picker stays inside it.
    window: CGRect,
    /// Language codes the Captions menu asked to translate into.
    translate_asked: Rc<RefCell<Vec<String>>>,
    /// Import Subtitles / Export SRT picks of the Captions menu.
    srt_asked: Rc<RefCell<Vec<SrtAsk>>>,
    /// The translation running on a worker thread (one at a time).
    translation: Option<TranslateJob>,
    /// The Transcribe tab's flow (once the app gave the host a transcription service).
    speech: Option<Speech>,
    /// Dialogs the tab asked for; the root shows them.
    dialogs: Vec<sq_draw_shell::ShellDialog>,
    /// Names the Style tab asked for (Save as New Style, Rename Look); `take_dialogs` shows them.
    name_asks: NameAsks,
}

impl TextHost {
    /// A host over a fresh panel.
    pub fn new() -> TextHost {
        let mut panel = TextPanelDraw::new(
            CaptionsTabDraw::new(),
            CaptionStyleTabDraw::new(
                Box::new(sq_inspector_ui::text::inspector_model::TextBoxDefaults::installed_families),
                Box::new(crate::speech::RandomIds),
            ),
        );
        let menus: Menus = Rc::default();
        let statuses: Rc<RefCell<Vec<String>>> = Rc::default();
        let picks: Picks = Rc::default();
        let marks: MarkHits = Rc::default();
        let sink = Rc::clone(&marks);
        panel.transcript.on_mark_hits = Some(Box::new(move |hit| sink.borrow_mut().push(hit)));
        let sink = Rc::clone(&menus);
        panel.on_menu = Some(Box::new(move |items, anchor| sink.borrow_mut().push((items, anchor))));
        let sink = Rc::clone(&statuses);
        panel.on_status = Some(Box::new(move |line| sink.borrow_mut().push(line)));
        let sink = Rc::clone(&picks);
        panel.on_pick_color = Some(Box::new(move |current, anchor| sink.borrow_mut().push((current, anchor))));
        let translate_asked: Rc<RefCell<Vec<String>>> = Rc::default();
        let sink = Rc::clone(&translate_asked);
        panel.captions.on_translate = Some(Box::new(move |code| sink.borrow_mut().push(code)));
        let srt_asked: Rc<RefCell<Vec<SrtAsk>>> = Rc::default();
        let sink = Rc::clone(&srt_asked);
        panel.captions.on_import_srt = Some(Box::new(move |()| sink.borrow_mut().push(SrtAsk::Import)));
        let sink = Rc::clone(&srt_asked);
        panel.captions.on_export_srt = Some(Box::new(move |()| sink.borrow_mut().push(SrtAsk::Export)));
        // The row is dimmed without an ONNX runtime, as Swift dims it without the system languages.
        if sq_translate::translator::runtime_available() {
            panel.captions.translation_targets =
                sq_translate::supported_languages().into_iter().map(|(c, n)| (c.to_string(), n.to_string())).collect();
        }
        let name_asks = NameAsks::default();
        panel.style.ask_name = Some(name_asks.ask());
        panel.style.block.ask_name = Some(name_asks.ask());
        TextHost {
            name_asks,
            translate_asked,
            srt_asked,
            translation: None,
            speech: None,
            dialogs: Vec::new(),
            panel,
            frame: CGRect::default(),
            pressed: false,
            menus,
            statuses,
            marks,
            picks,
            popover: None,
            picker_aids: PickerAids::default(),
            window: CGRect::default(),
        }
    }

    /// Adds the Transcribe tab over `service` (Swift `useTranscription`): one model per sequence, Create Captions and the overwrite
    /// question as dialogs, the job on a worker. `defaults` hold the caption language and Auto language.
    #[must_use]
    pub fn with_transcription(
        mut self,
        service: std::sync::Arc<dyn sq_transcribe::transcription_service::TranscriptionService>,
        defaults: Rc<RefCell<crate::persist::FileDefaults>>,
    ) -> TextHost {
        let speech = Speech::new(service, defaults);
        let sink = Rc::clone(&speech.asks);
        self.panel.on_create_captions = Some(Box::new(move |()| sink.borrow_mut().push(Ask::CreateCaptions)));
        let sink = Rc::clone(&speech.asks);
        self.panel.on_confirm_overwrite = Some(Box::new(move |()| sink.borrow_mut().push(Ask::ReplaceTranscript)));
        self.panel.use_transcription();
        self.speech = Some(speech);
        self
    }

    /// Connects the app's Look store (Swift `CaptionLookLibrary.shared`): Create Captions picks the saved default Look from it,
    /// and the Look tab's "Save as New Look" writes to it.
    #[must_use]
    pub fn with_looks(
        mut self,
        looks: std::sync::Arc<sq_editor_session::LookStore>,
        defaults: Rc<RefCell<crate::persist::FileDefaults>>,
    ) -> TextHost {
        if let Some(speech) = &mut self.speech {
            speech.set_looks(std::sync::Arc::clone(&looks));
        }
        // The Look tab and its text block remember which sections are open, like the Swift panels (`UserDefaults`).
        self.panel.style.set_defaults(Box::new(crate::persist::FileView(Rc::clone(&defaults))));
        self.panel.style.block.set_defaults(Box::new(crate::persist::FileView(Rc::clone(&defaults))));
        self.panel.style.look_host = Some(Box::new(look_host::AppCaptionLooks::new(looks, defaults)));
        self
    }

    /// The dialogs the Transcribe tab asked for since the last call (Create Captions, Replace the transcript).
    pub fn take_dialogs(&mut self) -> Vec<sq_draw_shell::ShellDialog> {
        let mut dialogs = std::mem::take(&mut self.dialogs);
        dialogs.extend(self.name_asks.take().into_iter().map(crate::name_dialog::name_dialog));
        dialogs
    }

    /// True while a transcription runs on its worker.
    pub fn is_transcribing(&self) -> bool {
        self.speech.as_ref().is_some_and(Speech::is_busy)
    }

    /// Sequence > Transcribe and Create Captions (Swift `CaptionsHost.autoCaptions`): opens the Transcribe tab and starts the
    /// transcription that ends in captions. Returns the status line to say now.
    pub fn auto_captions(&mut self, session: &sq_editor_session::EditorSession) -> String {
        let Some(speech) = &self.speech else { return "Open a sequence first.".to_string() };
        let (line, started) = speech.auto_captions(session);
        if started {
            self.panel.select(session, sq_inspector_ui::text::panel_draw::Tab::Transcript);
        }
        line
    }

    /// Sequence > Audio Options > Remove Filler Words (Swift `CaptionsHost.removeFillerWords`): the status line to say.
    pub fn remove_filler_words(&mut self, session: &mut sq_editor_session::EditorSession) -> String {
        match &mut self.speech {
            Some(speech) => speech.remove_filler_words(session),
            // No transcription service (tests, builds without one): the captions that exist are scanned, none are made.
            None => {
                speech_flow::scan_filler_words_in(session, &sq_editor_session::AppSettings::default_caption_language())
            }
        }
    }

    /// Clip > Audio Options > Disguise Voice (Swift `CaptionsHost.disguiseVoice`): the status line to say.
    pub fn disguise_voice(&mut self, session: &mut sq_editor_session::EditorSession) -> String {
        match &self.speech {
            Some(speech) => speech.disguise_voice(session),
            None => speech_flow::disguise_voice_with(None, session),
        }
    }

    /// Hands the active sequence's model to the Transcribe tab.
    fn sync_speech(&mut self, session: &sq_editor_session::EditorSession) {
        if let Some(speech) = &mut self.speech {
            let model = speech.sync(session);
            self.panel.set_transcript_model(model);
        }
    }

    /// Opens typing on the row of caption `id` in the panel's Captions tab (Swift `CaptionsHost.editCaption`). False when
    /// the active sequence has no such caption.
    pub fn edit_caption(&mut self, session: &mut sq_editor_session::EditorSession, id: sq_core_time::Id) -> bool {
        let exists = session
            .active_timeline()
            .is_some_and(|t| t.caption_tracks.iter().any(|track| track.items().iter().any(|i| i.id == id)));
        if !exists {
            return false;
        }
        self.panel.select(session, sq_inspector_ui::text::panel_draw::Tab::Captions);
        self.panel.captions.begin_editing(session, id);
        true
    }

    /// The panel (tests, and the root when a menu closes).
    pub fn panel(&mut self) -> &mut TextPanelDraw {
        &mut self.panel
    }

    /// Tells the host how big the window is, so the picker stays inside it.
    pub fn set_window(&mut self, window: CGRect) {
        self.window = window;
    }

    /// Gives the picker popover its recent colors and monitor pipette.
    pub fn with_picker_aids(mut self, aids: PickerAids) -> TextHost {
        self.picker_aids = aids;
        self
    }

    /// A pick the pipette of the open picker finished reaches the color it edits.
    fn poll_popover_pick(&mut self, cx: &mut HostCx) {
        if let Some(PopoverEvent::Changed(color)) = self.popover.as_mut().and_then(ColorPopover::poll_pick) {
            self.panel.color_picked(cx.session, Some(color));
            self.flush(cx);
        }
    }

    /// True while the color picker is open.
    pub fn has_popover(&self) -> bool {
        self.popover.is_some()
    }

    /// Opens the picker a swatch asked for (anchor in panel points).
    fn open_pickers(&mut self, cx: &mut HostCx) {
        let asked: Vec<_> = self.picks.borrow_mut().drain(..).collect();
        let frame = self.frame;
        for (current, a) in asked {
            self.close_popover(cx);
            let anchor = CGRect::new(a.x + frame.x, a.y + frame.y, a.width, a.height);
            let visible = if self.window.width > 0.0 { self.window } else { frame };
            self.popover = Some(ColorPopover::open_with((), current, anchor, visible, &self.picker_aids));
        }
    }

    fn close_popover(&mut self, cx: &mut HostCx) {
        if self.popover.take().is_some() {
            self.panel.color_picked(cx.session, None);
        }
    }

    /// Gives the open picker an event first; true when it took it.
    pub fn handle_popover(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let Some(pop) = &mut self.popover else { return false };
        match pop.handle(e, cx.scale, cx.ui) {
            PopoverEvent::Ignored => false,
            PopoverEvent::Taken => true,
            PopoverEvent::Changed(color) => {
                self.panel.color_picked(cx.session, Some(color));
                self.flush(cx);
                true
            }
            PopoverEvent::Closed => {
                self.close_popover(cx);
                self.flush(cx);
                true
            }
            PopoverEvent::Dismissed => {
                self.close_popover(cx);
                self.flush(cx);
                false
            }
        }
    }

    /// Draws the open picker over everything else.
    pub fn draw_popover(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        if let Some(pop) = &self.popover {
            pop.draw(c, t, cx.ui);
        }
    }

    /// The menus the tabs asked for since the last call, anchors in window points.
    pub fn take_menus(&mut self) -> Vec<(Vec<SQMenuItem>, CGRect)> {
        let frame = self.frame;
        let queued: Vec<_> = self.menus.borrow_mut().drain(..).collect();
        queued
            .into_iter()
            .map(|(items, a)| (items, CGRect::new(a.x + frame.x, a.y + frame.y, a.width, a.height)))
            .collect()
    }

    /// Runs what a closed menu queued.
    pub fn pump(&mut self, cx: &mut HostCx) {
        self.panel.run_commands(cx.session);
        self.flush(cx);
    }

    /// Starts translating the current caption track into `target` (`work` runs on a worker thread). Choosing a language while a
    /// translation runs stops that one first. The checks and messages are Swift's.
    fn start_translation(&mut self, cx: &mut HostCx, target: &str, work: impl FnOnce(Vec<String>, String) -> Work) {
        if let Some(job) = self.translation.take() {
            job.cancel();
        }
        let s = &mut *cx.session;
        let Some(track) = s.current_caption_track().filter(|t| !t.items().is_empty()).cloned() else {
            s.set_error("There are no captions to translate.");
            return;
        };
        let texts: Vec<String> = track.items().iter().map(|i| i.lines.join(" ")).collect();
        let Some(from) = sq_translate::translator::detect(&texts) else {
            s.set_error("Could not tell the language of the captions.");
            return;
        };
        if from == target.split(['-', '_']).next().unwrap_or(target) {
            s.set_error("The captions are already in that language.");
            return;
        }
        let to = target.split(['-', '_']).next().unwrap_or(target).to_string();
        self.translation = Some(TranslateJob::start(track, to, work(texts, from.to_string())));
        cx.ui.request_animation();
    }

    /// Stops a running translation (Escape in the panel).
    pub fn cancel_translation(&mut self) {
        if let Some(job) = &self.translation {
            job.cancel();
        }
    }

    /// True while a translation runs.
    pub fn is_translating(&self) -> bool {
        self.translation.is_some()
    }

    /// Commits the fields typed in any tab (a menu chord, a press in another panel).
    pub(crate) fn end_text_edits(&mut self, cx: &mut HostCx) {
        self.panel.end_text_edits(cx.session, cx.ui);
        self.flush(cx);
    }

    /// Shows the progress of the running translation and, when it ended, writes the captions (one undo step) or the failure.
    fn poll_translation(&mut self, cx: &mut HostCx) {
        let Some(job) = &mut self.translation else { return };
        let (lines, ended) = job.poll();
        for line in lines {
            cx.emit(AppEvent::Status(line));
        }
        let Some((result, track, target)) = ended else {
            cx.ui.request_animation();
            return;
        };
        self.translation = None;
        match result {
            Ok(texts) => {
                if cx.session.apply_translated_captions(&track, &texts, &target).is_some() {
                    cx.emit(AppEvent::Status(format!(
                        "Translated the captions into {}.",
                        sq_translate::language_name(&target)
                    )));
                }
            }
            Err(e) => cx.session.set_error(e.to_string()),
        }
    }

    fn flush(&mut self, cx: &mut HostCx) {
        let marks: Vec<_> = self.marks.borrow_mut().drain(..).collect();
        for (times, name) in marks {
            let added = cx.session.mark_search_hits(&times, &name);
            let line = match added {
                0 => "Every match already has a marker.".to_string(),
                1 => "Marked 1 match.".to_string(),
                n => format!("Marked {n} matches."),
            };
            self.statuses.borrow_mut().push(line);
        }
        let asked: Vec<String> = self.translate_asked.borrow_mut().drain(..).collect();
        for code in asked {
            let to = code.split(['-', '_']).next().unwrap_or(&code).to_string();
            self.start_translation(cx, &code, |texts, from| real_work(texts, from, to));
        }
        let srt: Vec<SrtAsk> = self.srt_asked.borrow_mut().drain(..).collect();
        for ask in srt {
            srt_files::run(ask, &mut self.panel.captions, cx);
        }
        self.poll_translation(cx);
        if let Some(speech) = &mut self.speech {
            for line in speech.pump(cx.session) {
                cx.emit(AppEvent::Status(line));
            }
            self.dialogs.extend(speech.dialogs());
            if speech.is_busy() {
                cx.ui.request_animation();
            }
        }
        self.open_pickers(cx);
        for line in self.statuses.borrow_mut().drain(..) {
            cx.emit(AppEvent::Status(line));
        }
    }
}

impl Default for TextHost {
    fn default() -> Self {
        TextHost::new()
    }
}

fn local(frame: CGRect, x: f32, y: f32, scale: f32) -> CGPoint {
    CGPoint::new(f64::from(x / scale) - frame.x, f64::from(y / scale) - frame.y)
}

fn contains(frame: CGRect, p: CGPoint) -> bool {
    p.x >= 0.0 && p.y >= 0.0 && p.x < frame.width && p.y < frame.height
}

impl AppHost for TextHost {
    fn sync(&mut self, session: &sq_editor_session::EditorSession) {
        self.panel.sync(session);
        self.sync_speech(session);
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        self.frame = frame;
        self.panel.set_size(CGSize { width: frame.width, height: frame.height });
        if self.panel.tick(cx.session, cx.ui.now) {
            cx.ui.request_animation();
        }
        self.poll_popover_pick(cx);
        self.flush(cx);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.panel.set_theme(*t);
        c.save_gstate();
        c.translate_by(self.frame.x, self.frame.y);
        c.clip_to(CGRect { x: 0.0, y: 0.0, width: self.frame.width, height: self.frame.height });
        self.panel.draw(c, cx.session, cx.ui);
        c.restore_gstate();
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let (scale, frame) = (cx.scale, self.frame);
        let taken = match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = local(frame, x, y, scale);
                self.pressed = contains(frame, p);
                self.pressed && {
                    self.panel.mouse_down(cx.session, cx.ui, p, modifiers, None);
                    true
                }
            }
            InputEvent::MouseDragged { x, y, .. } if self.pressed => {
                self.panel.mouse_dragged(cx.session, cx.ui, local(frame, x, y, scale), InputModifiers::default());
                true
            }
            InputEvent::MouseUp { x, y } if self.pressed => {
                self.pressed = false;
                self.panel.mouse_up(cx.session, cx.ui, local(frame, x, y, scale));
                true
            }
            InputEvent::MouseMoved { x, y } => {
                let p = local(frame, x, y, scale);
                self.panel.mouse_moved(Some(p).filter(|p| contains(frame, *p)), cx.ui);
                false
            }
            InputEvent::Scroll { x, y, dy, .. } => {
                let p = local(frame, x, y, scale);
                contains(frame, p) && self.panel.scroll(p, f64::from(dy))
            }
            InputEvent::KeyDown { key: sq_draw::InputKey::Escape, .. } if self.translation.is_some() => {
                self.cancel_translation();
                true
            }
            InputEvent::KeyDown { key, modifiers } => self.panel.key(cx.session, cx.ui, key, modifiers),
            _ => false,
        };
        self.flush(cx);
        taken
    }

    fn a11y(&self, _a: &mut A11y) {}

    fn on_change(&mut self, _changes: Change, cx: &mut HostCx) {
        self.panel.sync(cx.session);
        self.sync_speech(cx.session);
    }
}

#[cfg(test)]
mod tests;

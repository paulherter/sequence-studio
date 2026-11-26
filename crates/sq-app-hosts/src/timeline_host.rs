// Swift: SQAppShell/TimelineHeaderHost.swift, TimelineEditorDialogs.swift (the hooks of `TimelineHost`)
//! The timeline as an app host: wraps [`TimelineAppHost`] (which applies the panel's actions to the session itself) and
//! turns its host hooks into queues: status lines become `AppEvent::Status`, editors and menu commands wait for the
//! app root in [`TimelineHostEvent`]s.

use crate::editor_dialogs::{self, Save, Shared};
use crate::timeline_dialogs::{self, Answers};
use sq_app_shell::{AppEvent, AppHost, HostCx};
use sq_core_audio::live_ducking::{DialogueSilenceProvider, LiveDucking};
use sq_core_model::Clip;
use sq_core_time::{Id, TimeRange};
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent, InputModifiers};
use sq_draw_shell::ShellDialog;
use sq_draw_timeline::app_host::TimelineAppHost;
use sq_draw_timeline::host::TimelineEditorRequest;
use sq_draw_timeline::{MenuOutbox, TimelineMenus, new_outbox};
use sq_editor_session::{Change, EditorSession};
use sq_media::waveform_data::WaveformData;
use sq_playback::audio::WaveformSilences;
use sq_timeline_ui::DuckCurveSource;
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

/// What the timeline asked of the app root.
#[derive(Clone, Debug, PartialEq)]
pub enum TimelineHostEvent {
    /// An editor or dialog (Inspector, monitors, Library, shell dialogs own them).
    Open(TimelineEditorRequest),
    /// A menu command for the app's command route.
    Command(EditorCommand),
}

#[derive(Default)]
struct Queues {
    events: Vec<TimelineHostEvent>,
    status: Vec<String>,
    /// Prompt dialogs the root shows.
    dialogs: Vec<ShellDialog>,
}

/// Reads the decoded waveform of a media, if any.
pub type WaveformLookup = Rc<dyn Fn(Id) -> Option<Arc<WaveformData>>>;

/// `WaveformSilences` that takes each media's waveform from the lookup the first time it is asked, and again when the
/// waveform is replaced (relink, other channel map).
struct FedSilences {
    silences: WaveformSilences,
    waveforms: WaveformLookup,
    fed: RefCell<HashMap<Id, Arc<WaveformData>>>,
}

impl DialogueSilenceProvider for FedSilences {
    fn silences(&self, clip: &Clip, track_volume_db: f64) -> Option<Vec<TimeRange>> {
        let now = (self.waveforms)(clip.media);
        let mut fed = self.fed.borrow_mut();
        let same = match (&now, fed.get(&clip.media)) {
            (Some(a), Some(b)) => Arc::ptr_eq(a, b),
            (None, None) => true,
            _ => false,
        };
        if !same {
            self.silences.set_waveform(now.clone(), clip.media);
            match now {
                Some(d) => fed.insert(clip.media, d),
                None => fed.remove(&clip.media),
            };
        }
        self.silences.silences(clip, track_volume_db)
    }
}

/// The timeline panel in the window.
pub struct TimelinePanelHost {
    inner: TimelineAppHost,
    queues: Rc<RefCell<Queues>>,
    /// Where the chosen context menu rows leave their effects.
    outbox: MenuOutbox,
    /// Context menus built by right presses, with the window point (points) they open at.
    menus: Vec<(Vec<SQMenuItem>, CGPoint)>,
    /// The key map the menus print shortcuts from.
    map: CommandMap,
    /// What finished dialogs do to the session; [`TimelinePanelHost::pump`] runs it.
    answers: Answers,
    /// Presets and status lines the editor dialogs left for the root.
    saved: Shared,
    /// The live ducking in force, read by the duck curve the panel draws on Music tracks.
    duck: Rc<RefCell<Option<LiveDucking>>>,
}

impl TimelinePanelHost {
    /// True while a pointer gesture (drag, trim, scrub, marker drag) runs: a commit then would replace an agent edit.
    pub fn is_dragging(&self) -> bool {
        self.inner.panel.is_dragging()
    }

    /// A host around a fresh panel. Every editor request is accepted and queued, so the app root answers it.
    pub fn new(theme: DrawTheme) -> TimelinePanelHost {
        let mut inner = TimelineAppHost::new(theme);
        let queues = Rc::new(RefCell::new(Queues::default()));
        let q = Rc::clone(&queues);
        inner.host.open = Some(Box::new(move |r| {
            // The duration goes through the prompt hook below, like the Swift fallback.
            if matches!(r, TimelineEditorRequest::EditTransitionDuration(_)) {
                return false;
            }
            q.borrow_mut().events.push(TimelineHostEvent::Open(r.clone()));
            true
        }));
        let q = Rc::clone(&queues);
        inner.host.prompt =
            Some(Box::new(move |p, done| q.borrow_mut().dialogs.push(timeline_dialogs::prompt(p, done))));
        let q = Rc::clone(&queues);
        inner.host.command = Some(Box::new(move |c| q.borrow_mut().events.push(TimelineHostEvent::Command(c))));
        let q = Rc::clone(&queues);
        inner.host.status = Some(Box::new(move |s| q.borrow_mut().status.push(s.to_string())));
        let duck: Rc<RefCell<Option<LiveDucking>>> = Rc::default();
        let read = Rc::clone(&duck);
        // The dialogue pause provider arrives with `attach_waveforms`; until then the duck holds through pauses.
        inner.panel.duck_curve = Some(DuckCurveSource::new(Box::new(move || read.borrow().clone()), None));
        TimelinePanelHost {
            duck,
            inner,
            queues,
            outbox: new_outbox(),
            menus: Vec::new(),
            map: CommandMap::premiere_default(),
            answers: Answers::default(),
            saved: Shared::default(),
        }
    }

    /// Sets the live ducking in force (the project's own, else Preferences); the Music tracks draw its curve.
    pub fn set_live_ducking(&mut self, setting: Option<LiveDucking>) {
        if *self.duck.borrow() != setting {
            *self.duck.borrow_mut() = setting;
        }
    }

    /// Gives the duck curve the pause provider the mix uses (`WaveformSilences`), fed from the timeline's waveforms, so
    /// the drawn curve rises through dialogue pauses like the heard one.
    pub fn attach_waveforms(&mut self, waveforms: WaveformLookup) {
        let provider: Rc<dyn DialogueSilenceProvider> =
            Rc::new(FedSilences { silences: WaveformSilences::default(), waveforms, fed: RefCell::default() });
        if let Some(c) = self.inner.panel.duck_curve.as_mut() {
            c.silences = Some(provider);
        }
    }

    /// The wrapped host (panel and hooks).
    pub fn inner(&mut self) -> &mut TimelineAppHost {
        &mut self.inner
    }

    /// Whether the panel animates, so the app keeps drawing frames.
    pub fn needs_frames(&self) -> bool {
        self.inner.needs_frames()
    }

    /// The key map whose shortcuts the context menus show.
    pub fn set_command_map(&mut self, map: CommandMap) {
        self.map = map;
    }

    /// Context menus the right presses built since the last call; the root opens them.
    pub fn take_menus(&mut self) -> Vec<(Vec<SQMenuItem>, CGPoint)> {
        std::mem::take(&mut self.menus)
    }

    /// Dialogs the timeline's text prompts built since the last call; the root shows them.
    pub fn take_dialogs(&mut self) -> Vec<ShellDialog> {
        std::mem::take(&mut self.queues.borrow_mut().dialogs)
    }

    /// The dialog of an editor request the host owns (track mix, sequence volume, marker and caption editors); `None`
    /// when another host answers it or the target is gone.
    pub fn editor_dialog(&self, session: &mut EditorSession, r: &TimelineEditorRequest) -> Option<ShellDialog> {
        timeline_dialogs::editor_dialog(session, r, &self.answers)
            .or_else(|| editor_dialogs::editor_dialog(session, r, &self.answers, &self.saved))
    }

    /// The name dialog that saves a Graphics panel layer's effects as a Library preset.
    pub(crate) fn effect_preset_dialog(&self, preset: sq_core_effects::effect_preset::EffectPreset) -> ShellDialog {
        editor_dialogs::effect_preset(preset, &self.saved)
    }

    /// The presets to add to the Library and the status lines the editor dialogs left since the last call.
    pub(crate) fn take_saved(&mut self) -> (Vec<Save>, Vec<String>) {
        let mut out = self.saved.borrow_mut();
        (std::mem::take(&mut out.saves), std::mem::take(&mut out.notes))
    }

    /// The flows the editor dialogs asked for (Create Angles Clip).
    pub(crate) fn take_flows(&mut self) -> Vec<sq_draw_shell::ShellFlow> {
        std::mem::take(&mut self.saved.borrow_mut().flows)
    }

    /// The templates that wait for their preview image.
    pub(crate) fn take_templates(&mut self) -> Vec<crate::template_thumbnail::PendingTemplate> {
        std::mem::take(&mut self.saved.borrow_mut().templates)
    }

    /// Runs the rows chosen in the context menus on the session; the status lines they left.
    pub fn pump(&mut self, cx: &mut HostCx) {
        timeline_dialogs::run(&self.answers, cx.session);
        let TimelineAppHost { panel, host } = &mut self.inner;
        for line in TimelineMenus::run_all(&self.outbox, cx.session, host, panel) {
            cx.emit(AppEvent::Status(line));
        }
        self.flush_status(cx);
    }

    /// Combine… from a key or the Clip menu: the name prompt of the clip menu row, then the nest ([`TimelineMenus::nest`]).
    pub fn combine(&mut self, session: &EditorSession) {
        TimelineMenus::nest(&self.outbox, session, &mut self.inner.host);
    }

    /// Editors and commands asked since the last call, in order.
    pub fn take_events(&mut self) -> Vec<TimelineHostEvent> {
        std::mem::take(&mut self.queues.borrow_mut().events)
    }

    fn flush_status(&mut self, cx: &mut HostCx) {
        for line in std::mem::take(&mut self.queues.borrow_mut().status) {
            cx.emit(AppEvent::Status(line));
        }
    }
}

impl AppHost for TimelinePanelHost {
    fn wants_frames(&self) -> bool {
        self.inner.needs_frames()
    }

    fn theme_changed(&mut self, theme: &DrawTheme) {
        self.inner.panel.theme = *theme;
    }

    fn sync(&mut self, session: &EditorSession) {
        self.inner.sync(session);
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        self.inner.layout(frame, cx);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.inner.draw(c, t, cx);
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        // A right press selects what is under the pointer and builds the menu (clip, gap, track header or ruler).
        if let InputEvent::MouseDown { x, y, modifiers } = *e
            && modifiers.contains(InputModifiers::SECONDARY)
            && self.inner.panel.contains(x, y)
        {
            let p = self.inner.panel.point(x, y);
            let TimelineAppHost { panel, host } = &mut self.inner;
            if let Some(items) = TimelineMenus::items(p, panel, cx.session, host, &self.map, &self.outbox) {
                let scale = f64::from(cx.scale);
                self.menus.push((items, CGPoint::new(f64::from(x) / scale, f64::from(y) / scale)));
            }
            self.flush_status(cx);
            return true;
        }
        let taken = self.inner.handle(e, cx);
        self.flush_status(cx);
        taken
    }

    fn a11y(&self, a: &mut A11y) {
        self.inner.a11y(a);
    }

    fn on_change(&mut self, changes: Change, cx: &mut HostCx) {
        self.inner.on_change(changes, cx);
        self.flush_status(cx);
    }
}

#[cfg(test)]
mod tests;

// Swift: SQAppShell/Monitors/SourceMonitorCore.swift hosted next to MonitorHost
//! The Source monitor as a dock panel: a Source-mode [`MonitorPanel`] over a [`SourceMonitorCore`], which plays one
//! project media item on its own engine and keeps its In/Out marks. Insert and Overwrite go through the core into the
//! session at the playhead. The picture comes from the core's engine through a [`MonitorPicture`], shown in a renderer
//! image slot so it can sit next to the Program monitor's video quad.

use crate::picture::fit_size;
use crate::{MonitorDeferred, MonitorPicture};
use sq_app_shell::{AppEvent, AppHost, HostCx};
use sq_core_time::{Id, IdSource, Time};
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent};
use sq_draw_monitor::monitor_panel::{MonitorPanel, PanelEvent};
use sq_draw_monitor::monitor_panel_model::{MonitorEvent, MonitorPanelModel};
use sq_draw_monitor::source_monitor_core::{SourceCoreEvent, SourceMonitorCore};
use sq_draw_shell::ShellKeys;
use sq_editor_session::{Change, EditorSession, ProgramEngine};
use sq_uikit::controls_grid::CGRect;
use sq_uikit::panel_id::PanelID;

/// The renderer image slot the Source picture goes to (the window app uploads the picture there).
pub const SOURCE_PICTURE_SLOT: usize = 5;

/// The Source monitor in a dock slot.
pub struct SourceMonitorHost {
    core: SourceMonitorCore,
    panel: MonitorPanel,
    picture: MonitorPicture,
    deferred: Vec<MonitorDeferred>,
    /// An Export Frame waiting for its full-size picture.
    grab: Option<crate::FrameGrab>,
}

impl SourceMonitorHost {
    /// A host over `engine` (the Source engine: it writes its frames into `picture`); `ids` make the one-clip timelines.
    pub fn new(engine: Box<dyn ProgramEngine>, picture: MonitorPicture, ids: Box<dyn IdSource>) -> SourceMonitorHost {
        let mut model = MonitorPanelModel::new(sq_core_time::Time::new(1, 30), MonitorMode::Source);
        model.wired.full_screen = true;
        let core = SourceMonitorCore::new(engine, Some(model), ids);
        let mut panel =
            MonitorPanel::new(MonitorPanelModel::new(sq_core_time::Time::new(1, 30), MonitorMode::Source), None);
        panel.picture_slot = Some(SOURCE_PICTURE_SLOT);
        // The Source picture and the footer handles are drag sources (Swift `MonitorCardHost` sets `onSourceDrag`).
        panel.wiring.source_drag = true;
        SourceMonitorHost { core, panel, picture, deferred: Vec::new(), grab: None }
    }

    /// The picture the Source engine writes its frames into (the Scopes measure it).
    pub fn picture(&self) -> &MonitorPicture {
        &self.picture
    }

    /// Shows `tabs` (Program | Source) in the card's header, this card being the last one.
    pub fn set_tabs(&mut self, tabs: Vec<String>) {
        self.panel.selected_tab = tabs.len().saturating_sub(1);
        self.panel.tabs = tabs;
    }

    /// The player and mark keeper.
    pub fn core(&self) -> &SourceMonitorCore {
        &self.core
    }

    /// Preferences > Playback > Preroll and Postroll for Play In to Out with roll and Play Around.
    pub fn set_roll(&mut self, preroll: Time, postroll: Time) {
        self.core.preroll = preroll;
        self.core.postroll = postroll;
    }

    /// Loads `id` into the monitor (double click in the Project panel). False for unknown media or one without a duration;
    /// the reason is in the status line.
    pub fn open(&mut self, cx: &mut HostCx, id: Id) -> bool {
        let opened = self.core.open(cx.session, id, None);
        self.finish(cx);
        opened
    }

    /// Clip > Replace and Fit > Replace Modes (Swift `SourceHost.replaceWithMode`): the one selected clip plays the Source clip.
    pub fn replace_with_mode(&mut self, cx: &mut HostCx, mode: sq_core_edit::timeline_replace_modes::ReplaceMode) {
        let status = |cx: &mut HostCx, line: &str| cx.emit(AppEvent::Status(line.to_string()));
        let Some(media) = self.core.media_id() else {
            status(cx, "Open a clip in the Source monitor first (double-click it in the Project panel).");
            return;
        };
        // One clip, or a linked pair (Linked Selection selects both): the video clip, its partner follows.
        let Some(clip) = cx.session.single_selected_clip().map(|c| c.id) else {
            status(cx, "Select one clip in the timeline to replace.");
            return;
        };
        self.core.pause();
        cx.session.replace_on_main_track(clip, media, mode, Some(self.core.current_time()));
        if let Some(e) = cx.session.last_error().map(str::to_string) {
            status(cx, &e);
        }
        self.finish(cx);
    }

    /// Append to Main Track (Swift `SourceHost.fastCutPlacement`): the Source clip, else the media `picked` in the Project
    /// panel; Fast Cut only.
    pub fn append_to_main_track(&mut self, cx: &mut HostCx, picked: Vec<Id>) {
        let line = if !cx
            .session
            .active_timeline()
            .is_some_and(sq_core_edit::timeline_magnetic_ops::MagneticOpsExt::is_fast_cut)
        {
            "Switch the sequence to Fast Cut first (Shift+G).".to_string()
        } else if !cx.session.fast_cut_command_enabled(sq_uikit::editor_command::EditorCommand::AppendToMainTrack) {
            "Select the right clips first.".to_string()
        } else {
            let media = self.core.media_id().map_or(picked, |id| vec![id]);
            cx.session.append_to_main_track(&media, sq_core_edit::timeline_source_edit::SourceStreams::Both)
        };
        cx.emit(AppEvent::Status(line));
    }

    /// Loads `id` parked on `time` of its media (Match Frame). False for unknown media or one without a duration.
    pub fn open_at(&mut self, cx: &mut HostCx, id: Id, time: sq_core_time::Time) -> bool {
        let opened = self.core.open(cx.session, id, Some(time));
        self.finish(cx);
        opened
    }

    /// What waits for the app root (menus), in the order it happened.
    pub fn take_deferred(&mut self) -> Vec<MonitorDeferred> {
        std::mem::take(&mut self.deferred)
    }

    /// Performs the rows a closed menu queued.
    pub fn pump(&mut self, cx: &mut HostCx) {
        self.with_panel(|core, _| core.pump(cx.session));
        self.finish(cx);
    }

    /// Runs `f` with the core's model sitting in the panel (the panel draws and edits the model the core keeps).
    fn with_panel<R>(&mut self, f: impl FnOnce(&mut SourceMonitorCore, &mut MonitorPanel) -> R) -> R {
        std::mem::swap(&mut self.core.model, &mut self.panel.model);
        let r = f(&mut self.core, &mut self.panel);
        std::mem::swap(&mut self.core.model, &mut self.panel.model);
        r
    }

    /// Space, J/K/L, I/O, arrows and the rest of the key map, run on the core while the Source tab has the focus (the
    /// root only offers keys here then). Auto-repeat runs only the repeatable commands.
    fn key_command(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let InputEvent::KeyDown { key, modifiers } = *e else { return false };
        let map = &self.panel.key_map;
        let Some(c) = ShellKeys::command(key, modifiers, Some(PanelID::SourceMonitor), map, cfg!(target_os = "macos"))
        else {
            return false;
        };
        if cx.ui.key_repeat && !c.is_repeatable() {
            return self.core.media_id().is_some();
        }
        let handled = self.core.handle(cx.session, c);
        self.finish(cx);
        handled
    }

    /// Answers the core's hooks and keeps what only the root can do.
    /// Attach Backtimed (Swift `SourceHost.fastCutPlacement`): the Source clip, else the media selected in the Project panel,
    /// placed on top so it ends at the playhead.
    pub fn attach_backtimed(&mut self, cx: &mut HostCx, picked: Vec<Id>) {
        use sq_core_model::ThreePointMode;
        if self.core.media_id().is_some() {
            let both = sq_core_edit::timeline_source_edit::SourceStreams::Both;
            self.core.edit(cx.session, ThreePointMode::Overwrite, both, true, true, false);
            self.finish(cx);
        } else if picked.is_empty() {
            let line = "Open a clip in the Source view first (double-click it in the Project panel).";
            cx.emit(AppEvent::Status(line.to_string()));
        } else {
            let options = sq_editor_session::PlaceOptions {
                mode: ThreePointMode::Overwrite,
                place_on_top: true,
                backtimed: true,
                patched: true,
                ..Default::default()
            };
            cx.session.place_media(&picked, &options);
        }
    }

    /// Insert, Overwrite, Fit to Fill, Replace Clip from Source and Place on Top with the Source clip loaded (Swift
    /// `SourceHost.command`); false when no clip is loaded.
    pub fn run_edit(&mut self, cx: &mut HostCx, c: sq_uikit::editor_command::EditorCommand) -> bool {
        use sq_draw::monitor::monitor_modes::MonitorAction as A;
        use sq_uikit::editor_command::EditorCommand as C;
        if self.core.media_id().is_none() {
            return false;
        }
        match c {
            C::PlaceOnTop => self.core.edit(
                cx.session,
                sq_core_model::ThreePointMode::Overwrite,
                sq_core_edit::timeline_source_edit::SourceStreams::Both,
                true,
                false,
                false,
            ),
            C::Insert => self.core.perform(cx.session, A::Insert),
            C::Overwrite => self.core.perform(cx.session, A::Overwrite),
            C::FitToFill => self.core.perform(cx.session, A::FitToFill),
            C::ReplaceClipFromSource => self.core.perform(cx.session, A::Replace),
            _ => return false,
        }
        self.finish(cx);
        true
    }

    fn finish(&mut self, cx: &mut HostCx) {
        for e in self.panel.take_events() {
            match e {
                // Solo / Mute from the waveform meter's labels reach the Source engine (Swift `SourceHost`).
                PanelEvent::WaveChannelMonitorChange(m) => self.core.engine.set_channel_monitor(m),
                e => self.deferred.push(MonitorDeferred::Panel(e)),
            }
        }
        for e in self.core.take_events() {
            match e {
                SourceCoreEvent::Status(line) => cx.emit(AppEvent::Status(line)),
                // Only one monitor plays at a time.
                SourceCoreEvent::StartedPlaying => cx.session.stop_playback(),
                // The clip's own frame at full size, saved where the save panel says (`SourceHost.exportFrame`).
                SourceCoreEvent::ExportFrame if self.grab.is_none() && self.picture.size().is_some() => {
                    let name = self
                        .core
                        .media_id()
                        .and_then(|id| cx.session.project().media(id).map(|m| m.name.clone()))
                        .unwrap_or_default();
                    let name = crate::frame_export::suggested_name(if name.is_empty() { "Frame" } else { &name });
                    self.grab = Some(crate::FrameGrab::start(&mut *self.core.engine, &self.picture, name));
                }
                SourceCoreEvent::ExportFrame => cx.emit(AppEvent::Status("There is no frame to export yet.".into())),
                _ => {}
            }
        }
        // A closed clip leaves no stale frame behind.
        if self.core.media_id().is_none() && self.picture.size().is_some() {
            self.picture.set(None);
        }
        // shortcut: events the core does not own (tabs, engine and format choices) are dropped.
        for e in self.core.model.take_events() {
            if e == MonitorEvent::FullScreen {
                self.deferred.push(MonitorDeferred::Model(e));
            }
        }
    }
}

impl AppHost for SourceMonitorHost {
    fn sync(&mut self, session: &EditorSession) {
        self.panel.sync(session);
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        // The Program monitor started: stop here.
        if cx.session.is_playing() && self.core.is_playing() {
            self.core.pause();
        }
        self.core.tick(cx.session);
        if let Some(grab) = self.grab.as_mut() {
            match grab.poll(&mut *self.core.engine, &self.picture, &mut *cx.services.panel_files) {
                crate::Grab::Waiting => cx.ui.request_animation(),
                crate::Grab::Done(line) => {
                    self.grab = None;
                    if let Some(line) = line {
                        cx.emit(AppEvent::Status(line));
                    }
                }
            }
        }
        if self.core.is_playing() {
            cx.ui.request_animation();
        }
        // The clip's own frame, not the panel's shape, sets the aspect.
        let picture = self.picture.size();
        if let Some(size) = fit_size(None, picture) {
            self.panel.set_sequence_size(size);
        }
        self.with_panel(|_, panel| panel.layout(frame, cx));
        self.finish(cx);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.panel.has_picture = self.picture.size().is_some();
        self.with_panel(|_, panel| panel.draw(c, t, cx));
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let taken = self.with_panel(|core, panel| {
            let taken = panel.handle(e, cx);
            core.pump(cx.session);
            taken
        }) || self.key_command(e, cx);
        self.finish(cx);
        taken
    }

    fn a11y(&self, a: &mut A11y) {
        self.panel.a11y(a);
    }

    fn on_change(&mut self, changes: Change, cx: &mut HostCx) {
        self.core.sync(cx.session, changes.intersects(Change::PROJECT));
        self.finish(cx);
    }
}

#[cfg(test)]
mod tests;

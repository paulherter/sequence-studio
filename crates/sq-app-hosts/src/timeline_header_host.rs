// Swift: SQAppShell/TimelineHeaderHost.swift, SharedUIController.swift (applyToolStrip, layout and handle order)
//! The header above the timeline lanes: sequence tabs, Normal | Fast Cut, Snapping, Linked Selection, Marker, Fit. The
//! host lays it out at the top of the timeline's frame, hands the rest to the panel, draws it and turns its actions into
//! session and panel commands. Menus the bar asks for wait in [`TimelineHeaderHost::take_menus`]; their rows leave picks
//! that [`TimelineHeaderHost::pump`] applies. The tools are the Tools panel's ([`crate::tools_panel_host`]).

use crate::timeline_commands::{CommandScope, is_view_command, run};
use sq_app_shell::{AppEvent, HostCx};
use sq_core_model::TimelineEditMode;
use sq_core_time::Id;
use sq_draw::{Canvas, DrawTheme, InputEvent, Rect};
use sq_draw_timeline::app_host::TimelineAppHost;
use sq_draw_timeline::header::{
    HeaderMenuHandlers, TimelineHeaderAction, TimelineHeaderMenu, TimelineHeaderState, TimelineHeaderStrip,
};
use sq_library::library_folder_store::SettingsStore;
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::rc::Rc;

/// What a chosen menu row leaves for [`TimelineHeaderHost::pump`].
enum Pick {
    Command(EditorCommand),
    TogglePlaceClips,
    Mode(TimelineEditMode),
    Tab(Id),
}

/// The header bar of one timeline.
pub struct TimelineHeaderHost {
    bar: TimelineHeaderStrip<'static>,
    map: CommandMap,
    picks: Rc<RefCell<Vec<Pick>>>,
    menus: Vec<(Vec<SQMenuItem>, CGPoint)>,
    /// Header commands that are not the timeline's own: the root runs them through the shell.
    commands: Vec<EditorCommand>,
}

/// The scope of a header button: zoom always targets the timeline, Delete is not a header button.
const SCOPE: CommandScope = CommandScope { zooms: true, owns_delete: false };

impl TimelineHeaderHost {
    /// A host with the stored defaults of the tool strip.
    pub fn new(theme: DrawTheme) -> TimelineHeaderHost {
        TimelineHeaderHost {
            bar: TimelineHeaderStrip::new(theme),
            map: CommandMap::premiere_default(),
            picks: Rc::default(),
            menus: Vec::new(),
            commands: Vec::new(),
        }
    }

    /// The key map whose shortcuts the tips and menus show.
    pub fn set_command_map(&mut self, map: CommandMap) {
        self.map = map;
    }

    /// True on the Color page: the bar and the Fast Cut strip give way to the dock strip's dropdowns and only the row
    /// with the timecode and the toggles stays (see [`TimelineHeaderStrip::compact`]).
    pub fn set_compact(&mut self, on: bool) {
        self.bar.compact = on;
    }

    /// The bar, for tests and the root's hit tests.
    pub fn bar(&self) -> &TimelineHeaderStrip<'static> {
        &self.bar
    }

    /// Menus the bar asked for since the last call, with their window point (points); the root opens them.
    pub fn take_menus(&mut self) -> Vec<(Vec<SQMenuItem>, CGPoint)> {
        std::mem::take(&mut self.menus)
    }

    /// Commands the timeline panel does not own, in order; the root runs them through the shell.
    pub fn take_commands(&mut self) -> Vec<EditorCommand> {
        std::mem::take(&mut self.commands)
    }

    /// Lays the header across the top of `frame` (points); the frame left for the lanes (points).
    pub fn layout(&mut self, frame: CGRect, cx: &mut HostCx, timeline: &TimelineAppHost) -> CGRect {
        let (scale, k) = (cx.scale, f64::from(cx.scale));
        let area =
            Rect::new((frame.x * k) as f32, (frame.y * k) as f32, (frame.width * k) as f32, (frame.height * k) as f32);
        let state = TimelineHeaderState::make(cx.session, &timeline.panel);
        let theme = self.bar.theme;
        let mut bar = std::mem::replace(&mut self.bar, TimelineHeaderStrip::new(theme)).with_atlas(cx.atlas);
        let below = bar.layout(area, scale, state);
        self.bar = bar.with_atlas(None);
        let content = below;
        self.bar.set_cell_origin(f64::from(content.x) / k, f64::from(content.y) / k);
        CGRect::new(
            f64::from(content.x) / k,
            f64::from(content.y) / k,
            f64::from(content.w) / k,
            f64::from(content.h) / k,
        )
    }

    /// Draws the header.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme) {
        self.bar.theme = *t;
        self.bar.draw(c);
    }

    /// One event (device pixels); true when a bar took it. Hover moves reach the bars but still go on to the panels.
    pub fn handle(
        &mut self,
        e: &InputEvent,
        cx: &mut HostCx,
        timeline: &mut TimelineAppHost,
        settings: &mut dyn SettingsStore,
    ) -> bool {
        let moved = matches!(e, InputEvent::MouseMoved { .. });
        if let Some(actions) = self.bar.handle(e, cx.ui, &self.map) {
            for a in actions {
                self.apply(a, cx, timeline, settings);
            }
            if !moved {
                return true;
            }
        }
        false
    }

    /// Applies the rows chosen in the bars' menus; the status lines they left go out through `cx`.
    pub fn pump(&mut self, cx: &mut HostCx, timeline: &mut TimelineAppHost, settings: &mut dyn SettingsStore) {
        let picks = std::mem::take(&mut *self.picks.borrow_mut());
        for pick in picks {
            match pick {
                Pick::Command(c) => self.run(c, cx, timeline, settings),
                Pick::TogglePlaceClips => {
                    let on = &mut timeline.panel.tool_state_mut().place_sequences_as_clips;
                    *on = !*on;
                }
                Pick::Tab(root) => cx.session.select_sequence_tab(root),
                Pick::Mode(mode) => {
                    let line = timeline.panel.set_edit_mode(mode, cx.session);
                    if !line.is_empty() {
                        cx.emit(AppEvent::Status(line));
                    }
                }
            }
        }
    }

    fn apply(
        &mut self,
        a: TimelineHeaderAction,
        cx: &mut HostCx,
        timeline: &mut TimelineAppHost,
        settings: &mut dyn SettingsStore,
    ) {
        match a {
            TimelineHeaderAction::Command(c) => self.run(c, cx, timeline, settings),
            TimelineHeaderAction::SelectTab(root) => cx.session.select_sequence_tab(root),
            TimelineHeaderAction::CloseTab(root) => cx.session.close_sequence_tab(root),
            TimelineHeaderAction::MoveTab(root, i) => cx.session.move_sequence_tab(root, i as i64),
            TimelineHeaderAction::Menu(menu, at) => self.open_header_menu(menu, at, timeline, Vec::new()),
        }
    }

    /// Queues `menu` for the root at window point `at`, `extra` rows after a separator (the Color page's dock strip
    /// opens the bar's menus through here and adds Copy and Paste Grade to the "..." menu).
    pub fn open_header_menu(
        &mut self,
        menu: TimelineHeaderMenu,
        at: CGPoint,
        timeline: &TimelineAppHost,
        extra: Vec<SQMenuItem>,
    ) {
        let (run, place, mode, tab) =
            (Rc::clone(&self.picks), Rc::clone(&self.picks), Rc::clone(&self.picks), Rc::clone(&self.picks));
        let handlers = HeaderMenuHandlers {
            run: Rc::new(move |c| run.borrow_mut().push(Pick::Command(c))),
            toggle_place_clips: Rc::new(move || place.borrow_mut().push(Pick::TogglePlaceClips)),
            pick_mode: Rc::new(move |m| mode.borrow_mut().push(Pick::Mode(m))),
            select_tab: Rc::new(move |r| tab.borrow_mut().push(Pick::Tab(r))),
        };
        let mut items = self.bar.items(
            menu,
            timeline.panel.tool_state(),
            timeline.panel.geometry.fit_all_tracks,
            &self.map,
            handlers,
        );
        if !extra.is_empty() {
            items.push(SQMenuItem::separator());
            items.extend(extra);
        }
        self.menus.push((items, at));
    }

    /// A header button: the timeline's own view commands first, else the shell through the root.
    fn run(
        &mut self,
        c: EditorCommand,
        cx: &mut HostCx,
        timeline: &mut TimelineAppHost,
        settings: &mut dyn SettingsStore,
    ) {
        if !is_view_command(&c) {
            self.commands.push(c);
            return;
        }
        let TimelineAppHost { panel, host } = timeline;
        if let Some(line) = run(&c, panel, host, cx.session, &SCOPE, settings) {
            cx.emit(AppEvent::Status(line));
        }
    }
}

#[cfg(test)]
mod tests;

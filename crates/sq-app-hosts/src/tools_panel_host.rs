// Swift: SQAppShell/TimelineHeaderHost.swift (the tool strip half), SharedUIController.swift (applyToolStrip)
//! The Tools panel: the tool column as its own dock panel (left of the timeline by default). The host puts the strip
//! into the panel's frame, draws it, and turns its actions into tool changes on the timeline panel. Menus the strip asks
//! for (the Create / Mask / Slip variants, every tool) wait in [`ToolsPanelHost::take_menus`]; their rows leave picks
//! that [`ToolsPanelHost::pump`] applies.

use sq_app_shell::HostCx;
use sq_draw::{Canvas, DrawTheme, InputEvent};
use sq_draw_timeline::app_host::TimelineAppHost;
use sq_draw_timeline::tool_strip::{ToolStrip, ToolStripAction};
use sq_editor_session::ToolState;
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::rc::Rc;

/// The tool column of one timeline.
pub struct ToolsPanelHost {
    tools: ToolStrip,
    map: CommandMap,
    picks: Rc<RefCell<Vec<ToolState>>>,
    menus: Vec<(Vec<SQMenuItem>, CGPoint)>,
}

impl ToolsPanelHost {
    pub fn new(theme: DrawTheme) -> ToolsPanelHost {
        ToolsPanelHost {
            tools: ToolStrip::new(theme),
            map: CommandMap::premiere_default(),
            picks: Rc::default(),
            menus: Vec::new(),
        }
    }

    /// The key map whose shortcuts the tips and menus show.
    pub fn set_command_map(&mut self, map: CommandMap) {
        self.map = map;
    }

    /// The strip, for tests and the root's hit tests.
    pub fn tools(&self) -> &ToolStrip {
        &self.tools
    }

    /// Menus the strip asked for since the last call, with their window point (points); the root opens them.
    pub fn take_menus(&mut self) -> Vec<(Vec<SQMenuItem>, CGPoint)> {
        std::mem::take(&mut self.menus)
    }

    /// Puts the strip into the panel's `frame` (points, header included; empty while the panel is hidden). Ticks the
    /// hold timer, which may open a variants menu.
    pub fn layout(&mut self, frame: CGRect, scale: f32, timeline: &mut TimelineAppHost) {
        self.tools.place(frame, scale);
        for a in self.tools.tick() {
            self.apply(a, timeline);
        }
    }

    /// Draws the grip and the tools.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, timeline: &TimelineAppHost) {
        self.tools.theme = *t;
        self.tools.draw(c, timeline.panel.tool_state());
    }

    /// One event (device pixels); true when the strip took it. Hover moves reach the strip but still go on to the panels.
    pub fn handle(&mut self, e: &InputEvent, cx: &mut HostCx, timeline: &mut TimelineAppHost) -> bool {
        let moved = matches!(e, InputEvent::MouseMoved { .. });
        let state = *timeline.panel.tool_state();
        match self.tools.handle(e, &state, cx.ui, &self.map) {
            Some(actions) => {
                for a in actions {
                    self.apply(a, timeline);
                }
                !moved
            }
            None => false,
        }
    }

    /// Applies the tool states chosen in the strip's menus.
    pub fn pump(&mut self, timeline: &mut TimelineAppHost) {
        for state in std::mem::take(&mut *self.picks.borrow_mut()) {
            *timeline.panel.tool_state_mut() = state;
        }
    }

    fn apply(&mut self, a: ToolStripAction, timeline: &mut TimelineAppHost) {
        match a {
            ToolStripAction::SetTool(state) => *timeline.panel.tool_state_mut() = state,
            ToolStripAction::Menu(menu, at) => {
                let tool = Rc::clone(&self.picks);
                let items = self.tools.items(
                    menu,
                    timeline.panel.tool_state(),
                    &self.map,
                    Rc::new(move |s| tool.borrow_mut().push(s)),
                );
                self.menus.push((items, at));
            }
        }
    }
}

#[cfg(test)]
mod tests;

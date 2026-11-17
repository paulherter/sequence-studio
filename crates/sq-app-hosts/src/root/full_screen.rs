//! Full screen playback: one monitor takes the whole window (the window itself goes full screen through
//! [`AppEvent::FullScreen`]) and Esc leaves again. Swift offered this on the Program monitor only.

use super::AppRoot;
use sq_app_shell::{AppEvent, AppHost, HostCx};
use sq_draw::draw_list::Color;
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey};
use sq_uikit::controls_grid::CGRect;
use sq_uikit::panel_id::PanelID;

impl AppRoot {
    /// The monitor behind `panel` fills the window; the window follows. Ignored for a panel that is not a monitor here.
    pub(super) fn enter_full_screen(&mut self, cx: &mut HostCx, panel: PanelID) {
        let available = match panel {
            PanelID::ProgramMonitor => true,
            PanelID::SourceMonitor => self.source.is_some(),
            _ => false,
        };
        if !available || self.full_screen == Some(panel) {
            return;
        }
        self.full_screen = Some(panel);
        self.dock.set_focused(Some(panel));
        cx.emit(AppEvent::FullScreen(true));
    }

    /// Back to the docked layout.
    pub(super) fn exit_full_screen(&mut self, cx: &mut HostCx) {
        if self.full_screen.take().is_some() {
            cx.emit(AppEvent::FullScreen(false));
        }
    }

    /// The full screen monitor takes the whole `frame` (after the docked layout, which it overrides).
    pub(super) fn layout_full_screen(&mut self, frame: CGRect, cx: &mut HostCx) {
        match self.full_screen {
            Some(PanelID::ProgramMonitor) => self.monitor.layout(frame, cx),
            Some(PanelID::SourceMonitor) => {
                if let Some(source) = &mut self.source {
                    source.layout(frame, cx);
                }
            }
            _ => {}
        }
    }

    /// Draws black and the one monitor (then the menu on top); false when not in full screen.
    pub(super) fn draw_full_screen(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) -> bool {
        let Some(panel) = self.full_screen else { return false };
        c.fill(self.menu.bounds, Color::BLACK);
        match panel {
            PanelID::SourceMonitor => {
                if let Some(source) = &mut self.source {
                    source.draw(c, t, cx);
                }
            }
            _ => self.monitor.draw(c, t, cx),
        }
        self.menu.draw(c, t);
        true
    }

    /// Esc leaves; everything else goes to the monitor, then to the shell's shortcuts (Space plays). `None`: not in full
    /// screen, the event is for the docked window.
    pub(super) fn handle_full_screen(&mut self, e: &InputEvent, cx: &mut HostCx) -> Option<bool> {
        let panel = self.full_screen?;
        if matches!(e, InputEvent::KeyDown { key: InputKey::Escape, .. }) {
            self.exit_full_screen(cx);
            return Some(true);
        }
        let key = matches!(e, InputEvent::KeyDown { .. });
        let taken = match panel {
            PanelID::SourceMonitor => self.source.as_mut().is_some_and(|s| s.handle(e, cx)),
            _ => self.monitor.handle(e, cx),
        } || (key && self.shell.handle(e, cx));
        self.answer(cx);
        Some(taken || key)
    }
}

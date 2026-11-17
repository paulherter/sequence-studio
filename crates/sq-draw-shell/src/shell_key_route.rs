// Swift: ShellKeyRoute.swift
//! The parts of the Mac key route (`AppController.handle(_ event:)`) that are about key state, not about one command:
//! auto-repeat, J/K/L down and up, Esc. The shared shell and the Windows app run the same code.

use crate::shell_host::{ShellCx, ShellHost};
use sq_draw::InputKey;
use sq_editor_session::{EditorSession, RouterAction};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::key_binding::{Key, KeyEvent, KeyModifiers, KeyPhase};

const SHUTTLE_COMMANDS: [EditorCommand; 3] =
    [EditorCommand::ShuttleReverse, EditorCommand::ShuttleStop, EditorCommand::ShuttleForward];

impl ShellHost {
    /// A mapped key press: repeats of commands that are not `is_repeatable` are swallowed (a held Space or Delete runs once),
    /// shuttle keys go through the down/up state machine, everything else is `execute`.
    pub(crate) fn key_command(&mut self, cx: &mut ShellCx, c: EditorCommand, k: InputKey) -> bool {
        let repeating = cx.ui.key_repeat;
        let is_shuttle = SHUTTLE_COMMANDS.contains(&c);
        if repeating && !c.is_repeatable() && !is_shuttle {
            return true;
        }
        if !is_shuttle || !self.enabled(cx.session, &*cx.hooks, c) {
            return self.execute(cx, c);
        }
        let Some(key) = crate::keys::ShellKeys::key(k) else { return self.execute(cx, c) };
        // The host's panels first (the Source monitor shuttles itself when it has the focus).
        if !repeating && cx.hooks.on_command(c) {
            return true;
        }
        if repeating && self.focus == Some(sq_uikit::panel_id::PanelID::SourceMonitor) {
            return true;
        }
        if !cx.session.is_playing() {
            self.shuttle_router.transport_stopped();
        }
        let actions = self.shuttle_router.handle_command(c, key, repeating);
        self.run_shuttle(cx.session, actions);
        true
    }

    /// The key came up (the host calls this from its key-up message): ends a J/K/L hold.
    pub fn key_up(&mut self, session: &mut EditorSession, k: InputKey) {
        let Some(key) = crate::keys::ShellKeys::key(k) else { return };
        let up = KeyEvent { key, modifiers: KeyModifiers::EMPTY, phase: KeyPhase::Up, is_repeat: false };
        if !self.shuttle_router.consumes(&up) {
            return;
        }
        let actions = self.shuttle_router.handle(&up);
        self.run_shuttle(session, actions);
    }

    /// The window lost the keyboard: held J/K/L key-ups go elsewhere (the Mac `releaseHeldKeys`).
    pub fn release_held_keys(&mut self, session: &mut EditorSession) {
        let actions = self.shuttle_router.release_all_keys();
        self.run_shuttle(session, actions);
    }

    pub(crate) fn run_shuttle(&mut self, session: &mut EditorSession, actions: Vec<RouterAction>) {
        for a in actions {
            if let RouterAction::Shuttle(s) = a {
                session.apply_shuttle(s);
            }
        }
        if !session.is_playing() {
            self.shuttle_router.transport_stopped();
        }
        // Swift cancelled and restarted a sleeping task; the app calls `tick_shuttle` when `shuttle_wake_at` is due.
        self.shuttle_wake = None;
        let Some(due) = self.shuttle_router.next_deadline() else { return };
        let now = self.now_seconds();
        self.shuttle_wake = Some(now + (due - now).max(0.0) + 0.01);
    }

    /// When the app should call `tick_shuttle` (seconds on the host's steady clock); `None` = nothing waits.
    pub fn shuttle_wake_at(&self) -> Option<f64> {
        self.shuttle_wake
    }

    /// Runs the router's due hold timers (slow mode starts without another key event).
    pub fn tick_shuttle(&mut self, session: &mut EditorSession) {
        if self.shuttle_wake.is_none_or(|w| w > self.now_seconds()) {
            return;
        }
        self.shuttle_wake = None;
        let actions = self.shuttle_router.tick();
        self.run_shuttle(session, actions);
    }

    /// Shuttle rows run from a menu or Quick Apply (no key to hold): a press and release at once. Shift+J / Shift+L nudge
    /// the playing speed one step and the next J / L continues from it.
    pub(crate) fn run_shuttle_command(&mut self, cx: &mut ShellCx, c: EditorCommand) -> bool {
        match c {
            EditorCommand::ShuttleReverse | EditorCommand::ShuttleStop | EditorCommand::ShuttleForward => {
                let key = Key::Char(match c {
                    EditorCommand::ShuttleReverse => 'j',
                    EditorCommand::ShuttleStop => 'k',
                    _ => 'l',
                });
                if !cx.session.is_playing() {
                    self.shuttle_router.transport_stopped();
                }
                let down = self.shuttle_router.handle_command(c, key, false);
                self.run_shuttle(cx.session, down);
                let up = self.shuttle_router.handle(&KeyEvent {
                    key,
                    modifiers: KeyModifiers::EMPTY,
                    phase: KeyPhase::Up,
                    is_repeat: false,
                });
                self.run_shuttle(cx.session, up);
            }
            EditorCommand::ShuttleSlowReverse | EditorCommand::ShuttleSlowForward => {
                let rate = cx.session.engine().rate().nudged(c == EditorCommand::ShuttleSlowForward);
                cx.session.apply_shuttle(sq_core_edit::playback::ShuttleAction::SetRate(rate));
                self.shuttle_router.rate_changed(rate);
            }
            _ => return false,
        }
        true
    }

    /// Esc after the panels passed on it (a dialog, menu, text field, drag or the timeline's gap selection took theirs): the
    /// selection is cleared, clips and captions, as the Mac key monitor does. The tool reset is the timeline panel's.
    pub(crate) fn escape_key(&mut self, cx: &mut ShellCx) -> bool {
        // Esc closes Trim mode first (TL-08), before the tool and the selection.
        if self.trim.is_active() {
            self.trim.exit();
            return true;
        }
        // A floating panel with the focus docks (the Mac `FloatingPanelWindow.cancelOperation`: Esc nothing else took).
        if let Some(p) = self.dock.focused()
            && self.dock.floating.is_floating(p)
        {
            self.dock.dock_back(p);
            self.sync_dock(&cx.measure);
            return true;
        }
        if cx.session.selection().is_empty() && cx.session.caption_selection().is_empty() {
            return false;
        }
        self.execute(cx, EditorCommand::DeselectAll)
    }
}

// Swift: TimelinePanel+HostDefaults.swift
//! The Mac `EditorPanels` wiring a host gives every timeline, and the host's key-up and focus-loss calls.
//! The live duck curve (`DuckCurveSource`) is set by `sq-app-hosts` `TimelinePanelHost::set_live_ducking`.

use crate::action::TimelineAction;
use crate::panel::TimelinePanel;
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt as _;
use sq_draw::InputKey;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::key_binding::Key;
use std::cell::RefCell;
use std::rc::Rc;

impl TimelinePanel {
    /// Heights kept per sequence (`TrackHeightStore`) in `defaults`.
    pub fn connect_host_defaults(
        &mut self,
        defaults: Rc<RefCell<dyn sq_library::library_folder_store::SettingsStore>>,
    ) {
        self.height_store = Some(defaults);
    }

    /// The host's key-up: S ends Hold-S (the Mac `keyUp` → `setSnapInverted(false)`), ` ends the keep-attached hold
    /// whatever mode the sequence is in by then.
    pub fn key_up(&mut self, k: InputKey) -> Vec<TimelineAction> {
        match k {
            InputKey::Character('s') => self.set_snap_inverted(false),
            InputKey::Character('`') => {
                // A tap without an edit in Fast Cut maximizes the panel under the pointer (the Mac
                // `handleKeepAttachedHold`); in Normal the key-down already ran Maximize Panel through the key map.
                let tapped = self.tool_state().keep_attached
                    && !self.keep_attached_used
                    && self.gesture.is_none()
                    && self.timeline.is_fast_cut();
                self.keep_attached_used = false;
                let mut out = self.hold_keep_attached(false);
                if tapped {
                    out.push(TimelineAction::Command(EditorCommand::MaximizePanel));
                }
                out
            }
            InputKey::Character(ch) => {
                // A tool key held past the threshold was a temporary tool: back to the one from before (the Mac key monitor).
                let lower = ch.to_lowercase().next().unwrap_or(ch);
                let now = (self.clock)();
                if let Some(back) = self.tool_hold.release(Key::Char(lower), now) {
                    self.tool_state_mut().select(back);
                }
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    /// The window lost the keyboard: a held tool key's key-up will not come, so the hold ends as if it came now (the Mac
    /// `releaseHeldKeys`). Also ends Hold-S and the keep-attached hold, whose key-ups are lost the same way.
    pub fn release_held_keys(&mut self) -> Vec<TimelineAction> {
        let now = (self.clock)();
        if let Some(back) = self.tool_hold.release_all(now) {
            self.tool_state_mut().select(back);
        }
        self.keep_attached_used = false;
        let mut out = self.set_snap_inverted(false);
        out.extend(self.hold_keep_attached(false));
        out
    }

    /// The Mac `handleKeepAttachedHold`: while ` is held, a Fast Cut move or delete leaves the attached clips on their
    /// frame; a drag in progress is replayed so its ghost shows the change at once. The host mirrors
    /// `tool_state().keep_attached` into the session's `keep_attached_held` for menu and key deletes.
    pub fn hold_keep_attached(&mut self, on: bool) -> Vec<TimelineAction> {
        if self.tool_state().keep_attached == on {
            return Vec::new();
        }
        self.tool_state_mut().keep_attached = on;
        if self.gesture.is_none() {
            return Vec::new();
        }
        match self.last_drag {
            Some(p) => self.mouse_dragged(p),
            None => Vec::new(),
        }
    }
}

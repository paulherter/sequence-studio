//! Track header toggles and the undo names of their steps.

use sq_core_time::Id;

use crate::EditorSession;

/// A track header toggle.
// Swift: TrackToggle.swift:1
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TrackToggle {
    Target,
    Visible,
    Mute,
    Solo,
    Lock,
    SyncLock,
}

/// Undo names of the track header toggles: state-specific ("Mute Track" / "Unmute Track"), never "Toggle ...".
pub enum TrackToggleNames {}

impl TrackToggleNames {
    /// Shift/Option-click on a target chip changes several tracks at once.
    // Swift: TrackToggleNames.swift:6
    pub const TARGET_ALL: &'static str = "Change Track Targets";

    /// Name of the step that sets `toggle` to `on` on every track of a kind ("Mute Tracks").
    // Swift: TrackToggleNames.swift:9
    pub fn name_plural(toggle: TrackToggle, on: bool, plural: bool) -> &'static str {
        if !plural {
            return Self::name(toggle, on);
        }
        match (toggle, on) {
            (TrackToggle::Visible, true) => "Show Track Outputs",
            (TrackToggle::Visible, false) => "Hide Track Outputs",
            (TrackToggle::Mute, true) => "Mute Tracks",
            (TrackToggle::Mute, false) => "Unmute Tracks",
            (TrackToggle::Solo, true) => "Solo Tracks",
            (TrackToggle::Solo, false) => "Unsolo Tracks",
            (TrackToggle::Lock, true) => "Lock Tracks",
            (TrackToggle::Lock, false) => "Unlock Tracks",
            (TrackToggle::Target, _) => Self::TARGET_ALL,
            (TrackToggle::SyncLock, true) => "Enable Sync Locks",
            (TrackToggle::SyncLock, false) => "Disable Sync Locks",
        }
    }

    /// Name of the step that sets `toggle` to `on`.
    // Swift: TrackToggleNames.swift:22
    pub fn name(toggle: TrackToggle, on: bool) -> &'static str {
        match (toggle, on) {
            (TrackToggle::Visible, true) => "Show Track Output",
            (TrackToggle::Visible, false) => "Hide Track Output",
            (TrackToggle::Mute, true) => "Mute Track",
            (TrackToggle::Mute, false) => "Unmute Track",
            (TrackToggle::Solo, true) => "Solo Track",
            (TrackToggle::Solo, false) => "Unsolo Track",
            (TrackToggle::Lock, true) => "Lock Track",
            (TrackToggle::Lock, false) => "Unlock Track",
            (TrackToggle::Target, true) => "Target Track",
            (TrackToggle::Target, false) => "Untarget Track",
            (TrackToggle::SyncLock, true) => "Enable Sync Lock",
            (TrackToggle::SyncLock, false) => "Disable Sync Lock",
        }
    }
}

impl EditorSession {
    /// Track header toggle. `all_of_kind`: every track of the clicked track's kind takes the clicked track's new value,
    /// in one undo step.
    // Swift: EditorSession+TrackToggles.swift:6
    pub fn toggle_tracks(&mut self, id: Id, toggle: TrackToggle, all_of_kind: bool) {
        let Some(track) = self.active_timeline().and_then(|t| t.track(id)) else { return };
        let on = !match toggle {
            TrackToggle::Visible => track.is_visible,
            TrackToggle::Mute => track.is_muted,
            TrackToggle::Solo => track.is_solo,
            TrackToggle::Lock => track.is_locked,
            TrackToggle::Target => track.is_targeted,
            TrackToggle::SyncLock => track.sync_lock,
        };
        let kind = track.kind;
        let name = TrackToggleNames::name_plural(toggle, on, all_of_kind);
        self.attempt(name, None, |t| {
            for tr in t.tracks.iter_mut().filter(|tr| tr.id == id || (all_of_kind && tr.kind == kind)) {
                match toggle {
                    TrackToggle::Visible => tr.is_visible = on,
                    TrackToggle::Mute => tr.is_muted = on,
                    TrackToggle::Solo => tr.is_solo = on,
                    TrackToggle::Lock => tr.is_locked = on,
                    TrackToggle::Target => tr.is_targeted = on,
                    TrackToggle::SyncLock => tr.sync_lock = on,
                }
            }
            Ok(())
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_follow_the_state() {
        assert_eq!(TrackToggleNames::name(TrackToggle::Mute, true), "Mute Track");
        assert_eq!(TrackToggleNames::name(TrackToggle::Lock, false), "Unlock Track");
        assert_eq!(TrackToggleNames::name_plural(TrackToggle::Solo, true, true), "Solo Tracks");
        assert_eq!(TrackToggleNames::name_plural(TrackToggle::Target, false, true), TrackToggleNames::TARGET_ALL);
        assert_eq!(TrackToggleNames::name_plural(TrackToggle::SyncLock, true, false), "Enable Sync Lock");
    }
}

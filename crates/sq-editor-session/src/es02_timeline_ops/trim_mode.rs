//! Trim mode state (TL-08 / TL-09): the edit point being trimmed and which side the buttons and keys change. While it
//! is on, the Program monitor shows the two-up view. No project data: nothing here is saved.

use sq_core_edit::playback::ShuttleKey;
use sq_core_edit::timeline_trim_mode::{TrimPoint, TrimSide};
use sq_core_time::Time;

use super::prelude::*;
use crate::EditorSession;

/// Frame times of the two monitors (last outgoing frame, first incoming frame).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TrimFrames {
    pub outgoing: Option<Time>,
    pub incoming: Option<Time>,
}

/// Trim mode model (Swift `@Observable` class holding the session): methods take the session as a parameter and
/// `version` goes up with every change of point, side or note (Swift `onChange`).
// Swift: TrimModeModel.swift:8
#[derive(Clone, Debug, PartialEq)]
pub struct TrimModeModel {
    point: Option<TrimPoint>,
    side: TrimSide,
    note: String,
    dynamic_direction: i64,
    dynamic_level: usize,
    version: u64,
}

impl TrimModeModel {
    /// The frame steps of the two-up monitor's buttons, left to right.
    // Swift: TrimModeModel.swift:10
    pub const STEPS: [i64; 4] = [-5, -1, 1, 5];
    /// Frames per press of J / L: a repeated press in the same direction (or the key held) speeds up to the last entry.
    // Swift: TrimModeModel.swift:80
    pub const DYNAMIC_STEPS: [i64; 4] = [1, 2, 5, 10];

    // Swift: TrimModeModel.swift:21
    pub fn new() -> TrimModeModel {
        TrimModeModel {
            point: None,
            side: TrimSide::Roll,
            note: String::new(),
            dynamic_direction: 0,
            dynamic_level: 0,
            version: 0,
        }
    }

    pub fn point(&self) -> Option<&TrimPoint> {
        self.point.as_ref()
    }

    pub fn side(&self) -> TrimSide {
        self.side
    }

    /// Last result line under the buttons ("Rolled +2 frames", or why nothing moved); empty when there is none.
    pub fn note(&self) -> &str {
        &self.note
    }

    // Swift: TrimModeModel.swift:16
    pub fn is_active(&self) -> bool {
        self.point.is_some()
    }

    /// Swift `onChange` (called after every change of point, side or timeline): the view re-seeks its two monitors
    /// when this goes up.
    // Swift: TrimModeModel.swift:20
    pub fn version(&self) -> u64 {
        self.version
    }

    fn changed(&mut self) {
        self.version += 1;
    }

    fn reset_dynamic(&mut self) {
        self.dynamic_direction = 0;
        self.dynamic_level = 0;
    }

    /// Starts Trim mode on `p` with `side` (`None` = the side next to the pointer, never a roll).
    // Swift: TrimModeModel.swift:25
    pub fn enter(&mut self, p: TrimPoint, side: Option<TrimSide>, pointer_before: bool) {
        self.side = side.unwrap_or_else(|| p.default_side(pointer_before));
        self.point = Some(p);
        self.note.clear();
        self.reset_dynamic();
        self.changed();
    }

    /// The edit nearest to the playhead on the targeted tracks; false when the sequence has no edit.
    // Swift: TrimModeModel.swift:33
    pub fn enter_nearest_playhead(&mut self, session: &EditorSession) -> bool {
        let Some(p) = session.active_timeline().and_then(|t| t.nearest_trim_point(session.playhead(), None)) else {
            return false;
        };
        let side = p.supports(TrimSide::Roll).then_some(TrimSide::Roll);
        self.enter(p, side, false);
        true
    }

    // Swift: TrimModeModel.swift:39
    pub fn exit(&mut self) {
        if self.point.take().is_some() {
            self.note.clear();
            self.changed();
        }
    }

    /// Ctrl+T while Trim mode is on: outgoing, incoming, roll.
    // Swift: TrimModeModel.swift:47
    pub fn cycle_side(&mut self) {
        let Some(p) = &self.point else { return };
        self.side = self.side.next(p);
        self.note.clear();
        self.reset_dynamic();
        self.changed();
    }

    // Swift: TrimModeModel.swift:53
    pub fn select(&mut self, s: TrimSide) {
        if !self.point.as_ref().is_some_and(|p| p.supports(s)) {
            return;
        }
        self.side = s;
        self.note.clear();
        self.changed();
    }

    /// The -5 -1 +1 +5 buttons and Left / Right: one undo step per press. False when Trim mode is off.
    // Swift: TrimModeModel.swift:61
    pub fn step(&mut self, session: &mut EditorSession, frames: i64) -> bool {
        let Some(p) = self.point.clone() else { return false };
        let Some(moved) = session.trim_edit(&p, self.side, frames) else {
            self.note = session.last_error().unwrap_or("Cannot trim here.").to_string();
            self.changed();
            return true;
        };
        if moved == Time::ZERO {
            self.note = "No more footage that way.".to_string();
        } else if let Some(t) = session.active_timeline() {
            let n = moved.frame_index(t.frame_duration());
            self.note = format!(
                "{} {}{n} frame{}",
                if self.side == TrimSide::Roll { "Moved edit" } else { "Trimmed" },
                if n > 0 { "+" } else { "" },
                if n.abs() == 1 { "" } else { "s" }
            );
        }
        self.refresh(session);
        true
    }

    /// J / K / L in Trim mode (dynamic trim): J trims back, L trims forward, each press one undo step; pressing the
    /// same key again goes faster (1, 2, 5, 10 frames), the other direction restarts slow, K stops. False when Trim
    /// mode is off.
    // Swift: TrimModeModel.swift:86
    pub fn dynamic_trim(&mut self, session: &mut EditorSession, key: ShuttleKey) -> bool {
        if self.point.is_none() {
            return false;
        }
        match key {
            ShuttleKey::K => {
                self.reset_dynamic();
                self.note = "Dynamic trim stopped".to_string();
                self.changed();
                true
            }
            ShuttleKey::J | ShuttleKey::L => {
                let dir = if key == ShuttleKey::L { 1 } else { -1 };
                if dir == self.dynamic_direction {
                    self.dynamic_level = (self.dynamic_level + 1).min(Self::DYNAMIC_STEPS.len() - 1);
                } else {
                    self.dynamic_direction = dir;
                    self.dynamic_level = 0;
                }
                self.step(session, dir * Self::DYNAMIC_STEPS[self.dynamic_level])
            }
        }
    }

    /// The timeline changed (undo, redo, an edit elsewhere): re-read the point, leave Trim mode when its clips are gone.
    // Swift: TrimModeModel.swift:104
    pub fn refresh(&mut self, session: &EditorSession) {
        let Some(p) = &self.point else { return };
        let Some(r) = session.active_timeline().and_then(|t| t.resolved(p)) else {
            self.exit();
            return;
        };
        if !r.supports(self.side) {
            self.side = r.default_side(false);
        }
        self.point = Some(r);
        self.changed();
    }

    /// Frame times of the two monitors (last outgoing frame, first incoming frame).
    // Swift: TrimModeModel.swift:113
    pub fn frames(&self, session: &EditorSession) -> TrimFrames {
        match (&self.point, session.active_timeline()) {
            (Some(p), Some(t)) => {
                let (outgoing, incoming) = t.trim_frames(p);
                TrimFrames { outgoing, incoming }
            }
            _ => TrimFrames { outgoing: None, incoming: None },
        }
    }
}

impl Default for TrimModeModel {
    fn default() -> TrimModeModel {
        TrimModeModel::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Id;

    fn point() -> TrimPoint {
        TrimPoint {
            track: Id::from_u128(1),
            outgoing: Some(Id::from_u128(2)),
            incoming: Some(Id::from_u128(3)),
            time: Time::new(5, 1),
        }
    }

    #[test]
    fn enter_picks_the_side_next_to_the_pointer() {
        let mut m = TrimModeModel::new();
        assert!(!m.is_active());
        m.enter(point(), None, true);
        assert!(m.is_active());
        assert_eq!(m.side(), TrimSide::Outgoing);
        m.enter(point(), Some(TrimSide::Roll), false);
        assert_eq!(m.side(), TrimSide::Roll);
    }

    #[test]
    fn cycle_side_goes_outgoing_incoming_roll() {
        let mut m = TrimModeModel::new();
        m.enter(point(), Some(TrimSide::Outgoing), false);
        m.cycle_side();
        assert_eq!(m.side(), TrimSide::Incoming);
        m.cycle_side();
        assert_eq!(m.side(), TrimSide::Roll);
    }

    #[test]
    fn select_refuses_an_unsupported_side_and_exit_clears() {
        let mut m = TrimModeModel::new();
        let mut p = point();
        p.incoming = None;
        m.enter(p, None, true);
        m.select(TrimSide::Incoming);
        assert_eq!(m.side(), TrimSide::Outgoing);
        m.exit();
        assert!(!m.is_active());
    }

    #[test]
    fn steps_match_the_buttons() {
        assert_eq!(TrimModeModel::STEPS, [-5, -1, 1, 5]);
        assert_eq!(TrimModeModel::DYNAMIC_STEPS, [1, 2, 5, 10]);
    }
}

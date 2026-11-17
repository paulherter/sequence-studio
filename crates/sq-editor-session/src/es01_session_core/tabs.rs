//! Sequence tabs, the history list and the ruler's timecode labels and tick spacing.

use std::collections::BTreeSet;

use sq_core_time::{Id, Time};
use sq_uikit::localization::SQL10n;

use super::{SequenceTab, SequenceTabs};
use crate::EditorSession;

impl SequenceTabs {
    // Swift: SequenceTabs.swift:15
    pub fn new() -> SequenceTabs {
        SequenceTabs::default()
    }

    /// The open tabs, in order.
    // Swift: SequenceTabs.swift:12
    pub fn tabs(&self) -> &[SequenceTab] {
        &self.tabs
    }

    /// Index of the active tab.
    // Swift: SequenceTabs.swift:13
    pub fn active_index(&self) -> Option<usize> {
        self.active_index
    }

    /// The sequence the timeline shows.
    // Swift: SequenceTabs.swift:19
    pub fn current(&self) -> Option<Id> {
        self.active_index.map(|i| self.tabs[i].shown())
    }

    /// Root-first path of the active tab.
    // Swift: SequenceTabs.swift:21
    pub fn breadcrumb(&self) -> Vec<Id> {
        self.active_index.map(|i| self.tabs[i].path.clone()).unwrap_or_default()
    }

    /// Opens `id` as a tab (or activates the tab that shows it / has it in its path).
    // Swift: SequenceTabs.swift:24
    pub fn open(&mut self, id: Id) {
        if let Some(i) = self.tabs.iter().position(|t| t.root() == id) {
            self.tabs[i].path.truncate(1);
            self.active_index = Some(i);
            return;
        }
        if let Some(i) = self.tabs.iter().position(|t| t.path.contains(&id)) {
            if let Some(k) = self.tabs[i].path.iter().position(|p| *p == id) {
                self.tabs[i].path.truncate(k + 1);
            }
            self.active_index = Some(i);
            return;
        }
        self.tabs.push(SequenceTab { path: vec![id] });
        self.active_index = Some(self.tabs.len() - 1);
    }

    // Swift: SequenceTabs.swift:36
    pub fn select(&mut self, root: Id) {
        if let Some(i) = self.tabs.iter().position(|t| t.root() == root) {
            self.active_index = Some(i);
        }
    }

    /// Closes the tab with this root. Returns the sequence to show afterwards (`None` = no tabs left).
    // Swift: SequenceTabs.swift:42
    pub fn close(&mut self, root: Id) -> Option<Id> {
        let Some(i) = self.tabs.iter().position(|t| t.root() == root) else { return self.current() };
        let was_active = self.active_index == Some(i);
        self.tabs.remove(i);
        if self.tabs.is_empty() {
            self.active_index = None;
        } else if was_active {
            self.active_index = Some(i.min(self.tabs.len() - 1));
        } else if let Some(a) = self.active_index.filter(|a| *a > i) {
            self.active_index = Some(a - 1);
        }
        self.current()
    }

    /// Drills into a nested sequence inside the active tab. A sequence already in the path cuts the path back to it.
    // Swift: SequenceTabs.swift:54
    pub fn enter(&mut self, id: Id) {
        let Some(i) = self.active_index else { return self.open(id) };
        match self.tabs[i].path.iter().position(|p| *p == id) {
            Some(k) => self.tabs[i].path.truncate(k + 1),
            None => self.tabs[i].path.push(id),
        }
    }

    /// Breadcrumb click: back out to `id` in the active tab's path.
    // Swift: SequenceTabs.swift:61
    pub fn pop_to(&mut self, id: Id) {
        let Some(i) = self.active_index else { return };
        if let Some(k) = self.tabs[i].path.iter().position(|p| *p == id) {
            self.tabs[i].path.truncate(k + 1);
        }
    }

    /// Moves the tab with this root to `index` (clamped); the active tab stays the same tab.
    // Swift: SequenceTabs.swift:67
    pub fn move_tab(&mut self, root: Id, index: i64) {
        let Some(from) = self.tabs.iter().position(|t| t.root() == root) else { return };
        let active_root = self.active_index.map(|i| self.tabs[i].root());
        let tab = self.tabs.remove(from);
        let at = index.clamp(0, self.tabs.len() as i64) as usize;
        self.tabs.insert(at, tab);
        if let Some(r) = active_root {
            self.active_index = self.tabs.iter().position(|t| t.root() == r);
        }
    }

    /// Drops sequences that no longer exist: paths are cut at the first missing one, tabs with a missing root close.
    /// `rootable` (default: `existing`) are the sequences that may be a tab's root: Groups exist but are never tabs.
    // Swift: SequenceTabs.swift:77
    pub fn prune(&mut self, existing: &BTreeSet<Id>, rootable: Option<&BTreeSet<Id>>) {
        let active_root = self.active_index.map(|i| self.tabs[i].root());
        let roots = rootable.unwrap_or(existing);
        self.tabs.retain(|t| existing.contains(&t.root()) && roots.contains(&t.root()));
        for t in &mut self.tabs {
            if let Some(k) = t.path.iter().position(|p| !existing.contains(p)) {
                t.path.truncate(k);
            }
        }
        if self.tabs.is_empty() {
            self.active_index = None;
        } else if let Some(i) = active_root.and_then(|r| self.tabs.iter().position(|t| t.root() == r)) {
            self.active_index = Some(i);
        } else {
            self.active_index = Some(self.active_index.unwrap_or(0).min(self.tabs.len() - 1));
        }
    }
}

/// One row of the History panel.
// Swift: HistoryList.swift:7
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryRow {
    // Swift: HistoryList.swift:8
    pub id: i64,
    // Swift: HistoryList.swift:9
    pub title: String,
    /// A step Redo would apply (shown dimmed).
    // Swift: HistoryList.swift:11
    pub is_undone: bool,
    // Swift: HistoryList.swift:12
    pub is_current: bool,
}

/// The undo history as the History panel lists it: the opening state, then every step oldest first. `position` is the
/// row of the state the project is in now; rows after it are steps that Redo would bring back.
// Swift: HistoryList.swift:6
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryList {
    // Swift: HistoryList.swift:16
    pub rows: Vec<HistoryRow>,
    // Swift: HistoryList.swift:17
    pub position: usize,
}

impl HistoryList {
    // Swift: HistoryList.swift:14
    pub const ORIGINAL_TITLE: &'static str = "Original";

    // Swift: HistoryList.swift:18
    pub fn new(undo_names: &[&str], redo_names: &[&str]) -> HistoryList {
        let mut rows = vec![HistoryRow {
            id: 0,
            title: SQL10n::string(Self::ORIGINAL_TITLE),
            is_undone: false,
            is_current: false,
        }];
        for (i, n) in undo_names.iter().enumerate() {
            rows.push(HistoryRow {
                id: i as i64 + 1,
                title: SQL10n::undo_name(n),
                is_undone: false,
                is_current: false,
            });
        }
        for (i, n) in redo_names.iter().enumerate() {
            let id = (undo_names.len() + i) as i64 + 1;
            rows.push(HistoryRow { id, title: SQL10n::undo_name(n), is_undone: true, is_current: false });
        }
        rows[undo_names.len()].is_current = true;
        HistoryList { rows, position: undo_names.len() }
    }

    /// Undos (negative) or redos (positive) that take the project from the current row to `row`; 0 when it is the
    /// current row or does not exist.
    // Swift: HistoryList.swift:34
    pub fn steps(&self, row: i64) -> i64 {
        if row >= 0 && (row as usize) < self.rows.len() { row - self.position as i64 } else { 0 }
    }
}

impl EditorSession {
    /// The history list of this session.
    // Swift: HistoryList.swift:39
    pub fn history_list(&self) -> HistoryList {
        HistoryList::new(&self.history.undo_names(), &self.history.redo_names())
    }

    /// Goes to the state of `row` of `history_list` by undoing or redoing step by step, so every step's side effects
    /// follow exactly as with Cmd+Z / Cmd+Shift+Z. True when it moved.
    // Swift: HistoryList.swift:43
    pub fn jump_to_history_row(&mut self, row: i64) -> bool {
        let n = self.history_list().steps(row);
        if n == 0 {
            return false;
        }
        for _ in 0..n.abs() {
            let moved = if n < 0 { self.undo() } else { self.redo() };
            if !moved {
                break;
            }
        }
        true
    }
}

/// Timecode labels for the ruler and viewer. Pure: frame index in, string out. 29.97 and 59.94 can be shown as drop
/// frame ("HH:MM:SS;FF") or non-drop; all other rates are labeled at their nominal rate.
// Swift: RulerScale.swift:10
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TimecodeFormat {
    /// Frames per timecode second (30 for 29.97, 24 for 23.976, 25 for 25).
    // Swift: RulerScale.swift:12
    pub nominal_fps: i64,
    // Swift: RulerScale.swift:13
    pub drop_frame: bool,
    /// Sequence Settings "Starts at" as a frame count; added to every label (positions only).
    // Swift: RulerScale.swift:15
    pub start_frame: i64,
    /// Sequence Settings "Display: Frames": labels are plain frame numbers.
    // Swift: RulerScale.swift:17
    pub frames_only: bool,
}

impl TimecodeFormat {
    /// `prefer_drop_frame` applies only to 29.97 / 59.94; otherwise ignored.
    // Swift: RulerScale.swift:20
    pub fn new(frame_duration: Time, prefer_drop_frame: bool) -> TimecodeFormat {
        let fps = frame_duration.timescale() as f64 / frame_duration.value() as f64;
        let nominal_fps = (fps.round() as i64).max(1);
        let ntsc = frame_duration.value() == 1001; // 24000/1001, 30000/1001, 60000/1001
        let drop_frame = prefer_drop_frame && ntsc && (nominal_fps == 30 || nominal_fps == 60);
        TimecodeFormat { nominal_fps, drop_frame, start_frame: 0, frames_only: false }
    }

    /// Explicit rate (Swift precondition: drop frame only at 30 or 60).
    // Swift: RulerScale.swift:26
    pub fn with_nominal(nominal_fps: i64, drop_frame: bool) -> TimecodeFormat {
        debug_assert!(nominal_fps > 0 && (!drop_frame || nominal_fps == 30 || nominal_fps == 60));
        TimecodeFormat { nominal_fps, drop_frame, start_frame: 0, frames_only: false }
    }

    /// "HH:MM:SS:FF" (";" before FF for drop frame). Negative frames get a leading "-".
    // Swift: RulerScale.swift:36
    pub fn string_for_frame(&self, position: i64) -> String {
        let frame = position + self.start_frame;
        if self.frames_only {
            return frame.to_string();
        }
        let negative = frame < 0;
        let mut n = frame.abs();
        let fps = self.nominal_fps;
        if self.drop_frame {
            let d = fps / 15;
            let per10 = fps * 600 - d * 9;
            let per_min = fps * 60 - d;
            let (tens, rem) = (n / per10, n % per10);
            n += 9 * d * tens;
            if rem > d {
                n += d * ((rem - d) / per_min);
            }
        }
        let ff = n % fps;
        let total = n / fps;
        let (ss, mm, hh) = (total % 60, total / 60 % 60, total / 3600);
        let sep = if self.drop_frame { ';' } else { ':' };
        format!("{}{hh:02}:{mm:02}:{ss:02}{sep}{ff:02}", if negative { "-" } else { "" })
    }

    // Swift: RulerScale.swift:57
    pub fn string_for_time(&self, time: Time, frame_duration: Time) -> String {
        self.string_for_frame(time.frame_index(frame_duration))
    }
}

/// Tick spacing of the ruler at a zoom level, in whole frames.
// Swift: RulerScale.swift:63
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RulerScale {
    /// Labeled ticks every `major_frames`.
    // Swift: RulerScale.swift:66
    pub major_frames: i64,
    /// Unlabeled ticks every `minor_frames`; divides `major_frames` (equal when there are no minor ticks).
    // Swift: RulerScale.swift:68
    pub minor_frames: i64,
}

impl RulerScale {
    /// Frame counts tried for the major interval, smallest first.
    fn major_candidates(n: i64) -> Vec<i64> {
        let seconds = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 18_000, 36_000];
        [1, 2, 5, 10].into_iter().filter(|s| *s < n).chain(seconds.iter().map(|s| s * n)).collect()
    }

    /// Picks the smallest major interval whose labels are at least `min_label_spacing` apart, and minor ticks (the
    /// largest subdivision out of 10, 5, 4, 2) at least `min_tick_spacing` apart. Swift defaults: 96 and 6.
    // Swift: RulerScale.swift:79
    pub fn scale(points_per_frame: f64, nominal_fps: i64, min_label_spacing: f64, min_tick_spacing: f64) -> RulerScale {
        debug_assert!(points_per_frame > 0.0 && nominal_fps > 0);
        let candidates = Self::major_candidates(nominal_fps);
        let mut major = candidates.last().copied().unwrap_or(1);
        if let Some(c) = candidates.iter().find(|c| **c as f64 * points_per_frame >= min_label_spacing) {
            major = *c;
        }
        // Beyond the table (extreme zoom-out): keep doubling so labels never collide.
        while (major as f64) * points_per_frame < min_label_spacing && major < i64::MAX / 4 {
            major *= 2;
        }
        let mut minor = major;
        for d in [10, 5, 4, 2] {
            if major % d == 0 && (major / d) as f64 * points_per_frame >= min_tick_spacing {
                minor = major / d;
                break;
            }
        }
        RulerScale { major_frames: major, minor_frames: minor }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    #[test]
    fn tabs_open_select_enter_close() {
        let (a, b, n) = (id(1), id(2), id(3));
        let mut t = SequenceTabs::new();
        t.open(a);
        t.open(b);
        assert_eq!((t.current(), t.tabs().len()), (Some(b), 2));
        t.enter(n);
        assert_eq!(t.breadcrumb(), vec![b, n]);
        t.open(a);
        assert_eq!(t.current(), Some(a));
        t.open(n); // a path member activates its tab and cuts the path back to it
        assert_eq!((t.current(), t.active_index()), (Some(n), Some(1)));
        t.pop_to(b);
        assert_eq!(t.current(), Some(b));
        assert_eq!(t.close(b), Some(a));
        assert_eq!(t.close(a), None);
        assert_eq!(t.active_index(), None);
    }

    #[test]
    fn tabs_move_keeps_the_active_tab_and_prune_cuts_paths() {
        let (a, b, c) = (id(1), id(2), id(3));
        let mut t = SequenceTabs::new();
        for x in [a, b, c] {
            t.open(x);
        }
        t.select(b);
        t.move_tab(b, 99);
        assert_eq!((t.tabs()[2].root(), t.current()), (b, Some(b)));
        t.enter(a);
        let existing: BTreeSet<Id> = [b, c].into_iter().collect();
        t.prune(&existing, None);
        assert_eq!((t.tabs().len(), t.breadcrumb()), (2, vec![b]));
        let rootable: BTreeSet<Id> = [c].into_iter().collect();
        t.prune(&existing, Some(&rootable));
        assert_eq!((t.tabs().len(), t.current()), (1, Some(c)));
    }

    #[test]
    fn history_rows_and_steps() {
        let h = HistoryList::new(&["Cut", "Move"], &["Paste"]);
        assert_eq!(h.rows.len(), 4);
        assert_eq!((h.position, h.rows[2].is_current, h.rows[3].is_undone), (2, true, true));
        assert_eq!((h.steps(0), h.steps(3), h.steps(2), h.steps(9), h.steps(-1)), (-2, 1, 0, 0, 0));
        assert_eq!(h.rows[0].title, "Original");
    }

    #[test]
    fn drop_frame_labels_skip_frame_numbers() {
        let tc = TimecodeFormat::new(Time::new(1001, 30000), true);
        assert!(tc.drop_frame);
        assert_eq!(tc.string_for_frame(0), "00:00:00;00");
        assert_eq!(tc.string_for_frame(1799), "00:00:59;29");
        assert_eq!(tc.string_for_frame(1800), "00:01:00;02");
        assert_eq!(tc.string_for_frame(17982), "00:10:00;00");
        assert_eq!(tc.string_for_frame(-30), "-00:00:01;00");
        let nd = TimecodeFormat::new(Time::new(1001, 30000), false);
        assert_eq!(nd.string_for_frame(1800), "00:01:00:00");
        let mut f = TimecodeFormat::with_nominal(25, false);
        assert_eq!(f.string_for_frame(50), "00:00:02:00");
        f.start_frame = 5;
        f.frames_only = true;
        assert_eq!(f.string_for_frame(10), "15");
    }

    #[test]
    fn ruler_scale_picks_major_and_minor_ticks() {
        let s = RulerScale::scale(4.0, 30, 96.0, 6.0);
        assert_eq!(s.major_frames, 30); // 120 points per second
        assert_eq!(s.minor_frames, 3);
        let wide = RulerScale::scale(100.0, 30, 96.0, 6.0);
        assert_eq!(wide.major_frames, 1);
        let far = RulerScale::scale(1e-9, 30, 96.0, 6.0);
        assert!(far.major_frames as f64 * 1e-9 >= 96.0);
    }
}

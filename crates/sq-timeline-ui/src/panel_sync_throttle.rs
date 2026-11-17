// Swift: PanelSyncThrottle.swift
//! While the sequence plays and the timeline is scrolled, every playback tick re-synced all side panels. Panels whose
//! values change with the playhead only need a refresh a few times a second then; the playhead, monitor time and follow
//! stay per tick.

/// Throttle of the side-panel sync while scrolling during playback.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanelSyncThrottle {
    last_sync: f64,
}

impl Default for PanelSyncThrottle {
    fn default() -> PanelSyncThrottle {
        PanelSyncThrottle { last_sync: f64::NEG_INFINITY }
    }
}

impl PanelSyncThrottle {
    /// A scroll this recent counts as "scrolling" (covers the gaps between trackpad events and momentum frames).
    pub const SCROLL_WINDOW: f64 = 0.15;
    /// Longest pause between two side-panel syncs while scrolling.
    pub const INTERVAL: f64 = 0.1;

    /// A fresh throttle.
    pub fn new() -> PanelSyncThrottle {
        PanelSyncThrottle::default()
    }

    /// `playhead_only`: the change is a playhead move during playback and nothing else. Returns whether the panels sync now.
    pub fn should_sync_panels(&mut self, now: f64, playhead_only: bool, last_scroll: f64) -> bool {
        if !(playhead_only && now - last_scroll < Self::SCROLL_WINDOW && now - self.last_sync < Self::INTERVAL) {
            self.last_sync = now;
            return true;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn go(t: &mut PanelSyncThrottle, now: f64, only: bool, scroll: f64) -> bool {
        t.should_sync_panels(now, only, scroll)
    }

    #[test]
    fn syncs_every_tick_when_not_scrolling() {
        let mut t = PanelSyncThrottle::new();
        for i in 0..10 {
            assert!(go(&mut t, 10.0 + f64::from(i) / 30.0, true, 0.0));
        }
    }

    #[test]
    fn throttles_playhead_ticks_while_scrolling() {
        let mut t = PanelSyncThrottle::new();
        let mut synced = 0;
        for i in 0..30 {
            // one second of 30 Hz ticks with a scroll in every tick
            let now = 10.0 + f64::from(i) / 30.0;
            if t.should_sync_panels(now, true, now - 0.005) {
                synced += 1;
            }
        }
        assert!((7..=11).contains(&synced));
    }

    #[test]
    fn other_changes_always_sync_and_restart_the_interval() {
        let mut t = PanelSyncThrottle::new();
        assert!(go(&mut t, 10.0, true, 10.0));
        assert!(!go(&mut t, 10.03, true, 10.02));
        assert!(go(&mut t, 10.04, false, 10.03));
        assert!(!go(&mut t, 10.07, true, 10.06));
    }

    #[test]
    fn catches_up_once_scrolling_stops() {
        let mut t = PanelSyncThrottle::new();
        assert!(go(&mut t, 10.0, true, 10.0));
        assert!(go(&mut t, 10.03, true, 9.0));
    }
}

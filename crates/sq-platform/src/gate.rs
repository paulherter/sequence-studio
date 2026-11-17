//! What the export shows outside the window: the Dock badge / taskbar progress and the sleep lock.

use crate::backend::{Badge, SleepLock};
use winit::window::Window;

/// What changed for one progress reading.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Step {
    /// The new whole percent when it differs from the shown one (`Some(None)` clears it).
    pub percent: Option<Option<u8>>,
    /// `Some(true)` take the sleep lock, `Some(false)` release it.
    pub lock: Option<bool>,
}

/// Change detection shared by every system: the badge is touched on a visible change (1 %) only, the lock follows
/// whether an export runs.
#[derive(Default)]
pub struct Gate {
    shown: Option<u8>,
    locked: bool,
}

impl Gate {
    /// `progress` is the overall export progress, `None` when nothing exports.
    pub fn step(&mut self, progress: Option<f64>) -> Option<Step> {
        let percent = progress.map(|p| (p.clamp(0.0, 1.0) * 100.0).round() as u8);
        let running = percent.is_some();
        let percent_change = (percent != self.shown).then_some(percent);
        let lock = (running != self.locked).then_some(running);
        self.shown = percent;
        self.locked = running;
        (percent_change.is_some() || lock.is_some()).then_some(Step { percent: percent_change, lock })
    }
}

/// The export's footprint on the system: progress on the app icon and no sleep while it runs. Main thread only.
pub struct ExportIndicators {
    gate: Gate,
    badge: Badge,
    lock: Option<SleepLock>,
}

impl ExportIndicators {
    pub fn new(window: &Window) -> ExportIndicators {
        ExportIndicators { gate: Gate::default(), badge: Badge::new(window), lock: None }
    }

    /// Call every frame with the overall export progress (`None` = nothing exports).
    pub fn set(&mut self, progress: Option<f64>) {
        let Some(step) = self.gate.step(progress) else { return };
        if let Some(percent) = step.percent {
            self.badge.show(percent);
        }
        match step.lock {
            Some(true) => self.lock = SleepLock::acquire(),
            Some(false) => self.lock = None,
            None => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_badge_changes_per_percent_and_clears() {
        let mut g = Gate::default();
        assert_eq!(g.step(None), None);
        assert_eq!(g.step(Some(0.424)), Some(Step { percent: Some(Some(42)), lock: Some(true) }));
        assert_eq!(g.step(Some(0.4249)), None);
        assert_eq!(g.step(Some(0.43)), Some(Step { percent: Some(Some(43)), lock: None }));
        assert_eq!(g.step(Some(1.7)), Some(Step { percent: Some(Some(100)), lock: None }));
        assert_eq!(g.step(None), Some(Step { percent: Some(None), lock: Some(false) }));
        assert_eq!(g.step(None), None);
    }
}

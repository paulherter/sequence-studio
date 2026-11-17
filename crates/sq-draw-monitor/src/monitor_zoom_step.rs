// Swift: MonitorZoomStep.swift
//! Zoom In / Zoom Out keys while a monitor has focus.

use sq_draw::monitor::monitor_modes::MonitorZoom;

/// Swift `extension MonitorZoom`.
pub trait MonitorZoomStep {
    /// Next zoom for the Zoom In / Zoom Out keys while a monitor has focus: through the popup presets, Fit at the low end.
    /// From Fit, In goes to 100 % and Out stays at Fit. A pinch value (`custom`) steps to the next preset beyond it.
    fn stepped(self, zoom_in: bool) -> MonitorZoom;
}

impl MonitorZoomStep for MonitorZoom {
    fn stepped(self, zoom_in: bool) -> MonitorZoom {
        let mut steps: Vec<i64> = MonitorZoom::presets()
            .into_iter()
            .filter_map(|z| if let MonitorZoom::Percent(p) = z { Some(p) } else { None })
            .collect();
        steps.sort_unstable();
        let current = match self {
            MonitorZoom::Fit => return if zoom_in { MonitorZoom::Percent(100) } else { MonitorZoom::Fit },
            MonitorZoom::Percent(p) | MonitorZoom::Custom(p) => p,
        };
        if zoom_in {
            if let Some(next) = steps.iter().find(|s| **s > current) {
                return MonitorZoom::Percent(*next);
            }
            return MonitorZoom::Percent(steps.last().copied().unwrap_or(current));
        }
        if let Some(prev) = steps.iter().rev().find(|s| **s < current) {
            return MonitorZoom::Percent(*prev);
        }
        MonitorZoom::Fit
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zoom_in_walks_up_the_presets() {
        assert_eq!(MonitorZoom::Fit.stepped(true), MonitorZoom::Percent(100));
        assert_eq!(MonitorZoom::Percent(100).stepped(true), MonitorZoom::Percent(150));
        assert_eq!(MonitorZoom::Percent(800).stepped(true), MonitorZoom::Percent(800));
    }

    #[test]
    fn zoom_out_walks_down_and_ends_at_fit() {
        assert_eq!(MonitorZoom::Percent(100).stepped(false), MonitorZoom::Percent(75));
        assert_eq!(MonitorZoom::Percent(10).stepped(false), MonitorZoom::Fit);
        assert_eq!(MonitorZoom::Fit.stepped(false), MonitorZoom::Fit);
    }

    #[test]
    fn pinch_values_step_to_the_next_preset_beyond() {
        assert_eq!(MonitorZoom::Custom(130).stepped(true), MonitorZoom::Percent(150));
        assert_eq!(MonitorZoom::Custom(130).stepped(false), MonitorZoom::Percent(100));
        assert_eq!(MonitorZoom::Custom(10).stepped(false), MonitorZoom::Fit);
    }
}

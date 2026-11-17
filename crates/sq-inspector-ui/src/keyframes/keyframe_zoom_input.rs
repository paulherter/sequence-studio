// Swift: KeyframeZoomInput.swift
//! Pinch, scroll and keys that zoom or pan the keyframe area. Every view of the area (lanes, ruler, graph) uses it, and
//! all of them end in `EffectControlsModel::zoom` / `pan_viewport`, so they stay in one mapping.

use sq_draw::scroll::{GestureKind, ScrollGesture};
use sq_draw::{InputKey, InputModifiers};

use crate::ec::effect_controls_model::core::EffectControlsModel;

/// What a scroll over the keyframe area does.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum KeyframeScroll {
    Zoom { factor: f64 },
    Pan { points: f64 },
    None,
}

pub enum KeyframeZoomInput {}

impl KeyframeZoomInput {
    /// Pinch: magnification 0.1 = 10 % bigger.
    pub fn magnify_factor(magnification: f64) -> f64 {
        (1.0 + magnification).max(0.05)
    }

    /// Horizontal scrolling pans; Option (or Command) + vertical scrolling zooms; plain vertical scrolling is left to the
    /// enclosing scroll view (the rows).
    pub fn classify_delta(delta_x: f64, delta_y: f64, zoom_modifier: bool) -> KeyframeScroll {
        if zoom_modifier && delta_y != 0.0 {
            return KeyframeScroll::Zoom { factor: (delta_y * 0.02).exp() };
        }
        if delta_x.abs() > delta_y.abs() && delta_x != 0.0 {
            return KeyframeScroll::Pan { points: delta_x };
        }
        KeyframeScroll::None
    }

    /// The shared toolkit's wheel at the keyframe area: the host gesture's deltas (a wheel line, not its list pixels), a
    /// pinch zooms by `magnify_factor`. `dx`/`dy` (points) only count without a host gesture.
    pub fn classify(dx: f64, dy: f64, modifiers: InputModifiers, published: Option<&ScrollGesture>) -> KeyframeScroll {
        let zoom_modifier = modifiers.contains(InputModifiers::OPTION) || modifiers.contains(InputModifiers::COMMAND);
        let Some(g) = published else { return Self::classify_delta(dx, dy, zoom_modifier) };
        match g.kind {
            GestureKind::Magnify(m) => KeyframeScroll::Zoom { factor: Self::magnify_factor(m) },
            GestureKind::SmartMagnify => KeyframeScroll::None,
            GestureKind::Scroll => Self::classify_delta(g.delta_x, g.delta_y, zoom_modifier),
        }
    }

    /// Keys of the shared toolkit: + / = zoom in, - zoom out, \ fit. True when handled.
    pub fn key(k: InputKey, modifiers: InputModifiers, model: &mut EffectControlsModel) -> bool {
        if modifiers.contains(InputModifiers::COMMAND) {
            return false; // Ctrl on Windows arrives as .command
        }
        match k {
            InputKey::Character('=') | InputKey::Character('+') | InputKey::Plus => {
                model.zoom_in();
                true
            }
            InputKey::Character('-') | InputKey::Minus => {
                model.zoom_out();
                true
            }
            InputKey::Character('\\') => {
                model.zoom_to_fit();
                true
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn option_scroll_zooms_and_horizontal_scroll_pans() {
        assert_eq!(KeyframeZoomInput::classify_delta(0.0, 10.0, true), KeyframeScroll::Zoom { factor: (0.2f64).exp() });
        assert_eq!(KeyframeZoomInput::classify_delta(5.0, 1.0, false), KeyframeScroll::Pan { points: 5.0 });
        assert_eq!(KeyframeZoomInput::classify_delta(0.0, 10.0, false), KeyframeScroll::None);
        assert_eq!(KeyframeZoomInput::magnify_factor(-2.0), 0.05);
    }

    #[test]
    fn scroll_classification_matches_the_mac_cases() {
        // Swift `scrollClassification`.
        assert_eq!(KeyframeZoomInput::classify_delta(10.0, 2.0, false), KeyframeScroll::Pan { points: 10.0 });
        assert_eq!(KeyframeZoomInput::classify_delta(1.0, 10.0, false), KeyframeScroll::None);
        assert!(
            matches!(KeyframeZoomInput::classify_delta(0.0, 5.0, true), KeyframeScroll::Zoom { factor } if factor > 1.0)
        );
        assert_eq!(KeyframeZoomInput::magnify_factor(0.25), 1.25);
        assert!(KeyframeZoomInput::magnify_factor(-5.0) > 0.0);
    }
}

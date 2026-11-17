// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: DisplayView.current and ViewGamma.current (statics there)
//! The View > Display and View > View Gamma choices of one running app: session-only, display-only (export never reads
//! them), read by every monitor and window on each frame. The app creates one handle and passes clones to the menu hooks,
//! the render thread and the windows; nothing is process-global, so two apps in one process (the tests run many) never
//! see each other's choice.

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use super::display_view::DisplayView;
use super::view_gamma::ViewGamma;

/// Shared handle on the monitors' display choices (every clone sees the same values). Defaults: `Sdr` and `Mac`.
#[derive(Clone, Default)]
pub struct ViewChoices(Arc<Choices>);

/// Index into `DisplayView::ALL` and `ViewGamma::ALL` (index 0 is the default of both).
#[derive(Default)]
struct Choices {
    display: AtomicU8,
    gamma: AtomicU8,
}

fn index_of<T: PartialEq>(all: &[T], v: &T) -> u8 {
    all.iter().position(|x| x == v).and_then(|i| u8::try_from(i).ok()).unwrap_or(0)
}

impl ViewChoices {
    /// The View > Display choice.
    pub fn display(&self) -> DisplayView {
        DisplayView::ALL.get(usize::from(self.0.display.load(Ordering::Relaxed))).copied().unwrap_or(DisplayView::Sdr)
    }

    pub fn set_display(&self, view: DisplayView) {
        self.0.display.store(index_of(&DisplayView::ALL, &view), Ordering::Relaxed);
    }

    /// The View > View Gamma choice.
    pub fn gamma(&self) -> ViewGamma {
        ViewGamma::ALL.get(usize::from(self.0.gamma.load(Ordering::Relaxed))).copied().unwrap_or(ViewGamma::Mac)
    }

    pub fn set_gamma(&self, gamma: ViewGamma) {
        self.0.gamma.store(index_of(&ViewGamma::ALL, &gamma), Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_handle_shows_sdr_with_the_mac_gamma() {
        let c = ViewChoices::default();
        assert_eq!((c.display(), c.gamma()), (DisplayView::Sdr, ViewGamma::Mac));
    }

    #[test]
    fn every_choice_round_trips() {
        let c = ViewChoices::default();
        for v in DisplayView::ALL {
            c.set_display(v);
            assert_eq!(c.display(), v);
        }
        for g in ViewGamma::ALL {
            c.set_gamma(g);
            assert_eq!(c.gamma(), g);
        }
    }

    #[test]
    fn clones_share_and_separate_handles_do_not() {
        let (a, b) = (ViewChoices::default(), ViewChoices::default());
        let clone = a.clone();
        a.set_display(DisplayView::Hdr1000);
        a.set_gamma(ViewGamma::Broadcast);
        assert_eq!((clone.display(), clone.gamma()), (DisplayView::Hdr1000, ViewGamma::Broadcast));
        assert_eq!((b.display(), b.gamma()), (DisplayView::Sdr, ViewGamma::Mac));
    }
}

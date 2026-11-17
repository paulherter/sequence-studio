//! Frame pacing while a pointer button is held and the pointer has moved (a drag of a card, clip, slider or the playhead). One
//! rule for every platform: the surface switches to the lowest-latency present path
//! ([`crate::surface::Surface::set_interactive`]: Mailbox where the system has it, otherwise a swap chain of two images) and
//! the loop draws at most about once per display refresh, always the newest pointer position. Without the pacing that path
//! would draw on every loop turn; with the default queue (Fifo, three images) a frame reaches the screen two refreshes after it
//! was drawn and the app is blocked in `get_current_texture` while events pile up: the dragged thing trails the pointer.
//! A click that never moves does not switch (a reconfigure can flash or hitch on D3D and Vulkan).

use std::time::{Duration, Instant};

/// A frame is due again after this share of a display refresh: less than a whole one, so the free-running draws never skip
/// a refresh, and more than half, so a 1000 Hz pointer does not draw twice per refresh.
const SHARE: (u32, u32) = (3, 4);

/// How far (device pixels) a held pointer must travel from the press before the press counts as a drag.
const SLOP: f32 = 3.0;

/// Whether a drag is on and when the last frame left.
#[derive(Default)]
pub struct DragPacing {
    /// Where the held button went down; `None` while no button is held.
    press: Option<(f32, f32)>,
    /// The held pointer has moved at least [`SLOP`] and nothing plays: the drag path is on.
    active: bool,
    last: Option<Instant>,
}

impl DragPacing {
    /// Follows the pointer: `held` is its position (device pixels) while a button is down, `playing` whether playback runs
    /// (its frames stay on the display's beat). Returns the new state of the drag path when it changed (the surface then
    /// switches its present path).
    pub fn update(&mut self, held: Option<(f32, f32)>, playing: bool) -> Option<bool> {
        let press = match (held, self.press) {
            (Some(at), None) => Some(at),
            (Some(_), kept) => kept,
            (None, _) => None,
        };
        self.press = press;
        let active = !playing
            && matches!((held, press), (Some((x, y)), Some((px, py))) if self.active || (x - px).hypot(y - py) >= SLOP);
        if active == self.active {
            return None;
        }
        self.active = active;
        self.last = None;
        Some(active)
    }

    /// A frame went to the system at `now`.
    pub fn drew(&mut self, now: Instant) {
        self.last = Some(now);
    }

    /// When the next frame may be drawn; `None` outside a drag (the loop draws whenever the app asks).
    pub fn due(&self, frame: Duration) -> Option<Instant> {
        self.active.then_some(())?;
        self.last.map(|last| last + frame * SHARE.0 / SHARE.1)
    }

    /// Whether a frame may be drawn at `now`.
    pub fn may_draw(&self, now: Instant, frame: Duration) -> bool {
        self.due(frame).is_none_or(|due| now >= due)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FRAME: Duration = Duration::from_micros(16_667);

    #[test]
    fn outside_a_drag_every_turn_may_draw() {
        let mut p = DragPacing::default();
        let t = Instant::now();
        p.drew(t);
        assert!(p.may_draw(t, FRAME), "no drag: the loop draws whenever the app asks, as before");
        assert_eq!(p.due(FRAME), None);
    }

    #[test]
    fn a_click_without_movement_never_switches_the_surface() {
        let mut p = DragPacing::default();
        assert_eq!(p.update(Some((100.0, 100.0)), false), None, "the press alone changes nothing");
        assert_eq!(p.update(Some((101.0, 102.0)), false), None, "under 3 px is still a click");
        assert_eq!(p.update(None, false), None, "the release of a click changes nothing either");
    }

    #[test]
    fn a_drag_switches_on_after_the_slop_and_off_on_release() {
        let mut p = DragPacing::default();
        assert_eq!(p.update(Some((100.0, 100.0)), false), None);
        assert_eq!(p.update(Some((105.0, 100.0)), false), Some(true), "5 px from the press: one switch on");
        assert_eq!(p.update(Some((101.0, 100.0)), false), None, "back near the press stays a drag");
        assert_eq!(p.update(None, false), Some(false), "the release: one switch off");
        assert_eq!(p.update(None, false), None);
    }

    #[test]
    fn playback_never_takes_the_drag_path() {
        let mut p = DragPacing::default();
        p.update(Some((0.0, 0.0)), true);
        assert_eq!(p.update(Some((50.0, 0.0)), true), None, "a drag while playing stays on the display's beat");
        assert_eq!(p.update(Some((60.0, 0.0)), false), Some(true), "playback stopped mid-drag: the drag path starts");
    }

    #[test]
    fn a_drag_draws_the_newest_state_once_per_refresh_and_not_on_every_turn() {
        let mut p = DragPacing::default();
        let t = Instant::now();
        p.update(Some((0.0, 0.0)), false);
        assert_eq!(p.update(Some((9.0, 0.0)), false), Some(true));
        assert!(p.may_draw(t, FRAME), "the first frame of a drag draws at once");
        p.drew(t);
        // A 1000 Hz pointer: a loop turn per millisecond, one frame per refresh.
        let drawn = (1..=100u64).filter(|ms| p.may_draw(t + Duration::from_millis(*ms), FRAME)).count();
        assert_eq!(drawn, 100 - 12, "every turn from 12.5 ms on is allowed until a frame is drawn");
        p.drew(t + Duration::from_millis(13));
        assert!(!p.may_draw(t + Duration::from_millis(14), FRAME));
        assert_eq!(p.due(FRAME), Some(t + Duration::from_millis(13) + FRAME * 3 / 4));
    }

    #[test]
    fn the_release_draws_at_once() {
        let mut p = DragPacing::default();
        let t = Instant::now();
        p.update(Some((0.0, 0.0)), false);
        p.update(Some((9.0, 0.0)), false);
        p.drew(t);
        p.update(None, false);
        assert!(p.may_draw(t, FRAME), "the frame of the released state is not held back");
    }
}

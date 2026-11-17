//! The second click on a popover's opener closes the popover and stays closed: the press on the opener that closes a
//! popover is consumed with its release, so an opener that opens on release (a click) does not open it again. A press
//! elsewhere is not consumed (`InputEvent::closing_popover_is_taken`): it closes the popover and acts. Menus keep every
//! press that closes them (`MenuController`).

use sq_draw::InputEvent;

/// Remembers that the last press closed a popover.
#[derive(Default)]
pub struct PopoverCloseGuard {
    release_pending: bool,
}

impl PopoverCloseGuard {
    /// The press `e` closed a popover (`was_up` before, `still_up` after).
    pub fn note(&mut self, e: &InputEvent, was_up: bool, still_up: bool) {
        if was_up && !still_up && matches!(e, InputEvent::MouseDown { .. }) {
            self.release_pending = true;
        }
    }

    /// True for the release (and drag) of the press that closed a popover; any new press starts over.
    pub fn swallows(&mut self, e: &InputEvent) -> bool {
        match e {
            InputEvent::MouseUp { .. } => std::mem::take(&mut self.release_pending),
            InputEvent::MouseDown { .. } => {
                self.release_pending = false;
                false
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_draw::InputModifiers;

    const DOWN: InputEvent = InputEvent::MouseDown { x: 10.0, y: 10.0, modifiers: InputModifiers::NONE };
    const UP: InputEvent = InputEvent::MouseUp { x: 10.0, y: 10.0 };

    /// Every popover the app has (color picker, easing curve, text and graphics pickers, Multiband) reports "closed by a
    /// press" the same way, so one table covers all openers: the closing press eats its release, a later click is free.
    #[test]
    fn the_press_that_closes_a_popover_eats_its_release_for_every_opener() {
        for opener in ["inspector color picker", "easing curve", "text picker", "graphics picker", "multiband"] {
            let mut g = PopoverCloseGuard::default();
            g.note(&DOWN, true, false);
            assert!(g.swallows(&UP), "{opener}: the release of the closing click does not reopen it");
            assert!(!g.swallows(&UP), "{opener}: only that one release");
            g.note(&DOWN, false, true);
            assert!(!g.swallows(&UP), "{opener}: a click that opens a popover is not eaten");
            g.note(&DOWN, true, false);
            assert!(!g.swallows(&DOWN) && !g.swallows(&UP), "{opener}: a new press starts over");
            g.note(&UP, true, false);
            assert!(!g.swallows(&UP), "{opener}: only a press closes through the guard");
        }
    }
}

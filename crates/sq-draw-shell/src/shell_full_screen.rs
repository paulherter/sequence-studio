// Swift: ShellFullScreen.swift
//! Program monitor Full Screen (Mac `ProgramPresentation`) as shell state: the window shows only the Program picture over
//! everything (SQAppShell `MonitorCardHost.drawFullScreen`), Esc leaves, other keys go through the normal routing. The platform
//! may also hide its window chrome: it learns of a change through [`ShellEvent::FullScreen`] (Swift `onFullScreenChange`).

use crate::shell_host::{ShellEvent, ShellHost};
use sq_draw::{InputEvent, InputKey};
use sq_editor_session::EditorSession;
use sq_uikit::controls_grid::{CGRect, CGSize};

impl ShellHost {
    /// Enters Full Screen. False without a sequence (nothing to show).
    pub fn enter_program_full_screen(&mut self, session: &EditorSession) -> bool {
        if self.is_program_full_screen || session.active_timeline().is_none() {
            return false;
        }
        self.is_program_full_screen = true;
        self.full_screen_started = self.now_seconds();
        self.emit(ShellEvent::FullScreen(true));
        true
    }

    /// Leaves Full Screen.
    pub fn exit_program_full_screen(&mut self) {
        if !self.is_program_full_screen {
            return;
        }
        self.is_program_full_screen = false;
        self.emit(ShellEvent::FullScreen(false));
    }

    /// Steady seconds at which Full Screen started.
    pub fn full_screen_started(&self) -> f64 {
        self.full_screen_started
    }

    /// Esc in Full Screen leaves it and nothing else sees that key (the Mac key monitor's first rule). True = taken.
    pub fn full_screen_key(&mut self, e: &InputEvent) -> bool {
        let InputEvent::KeyDown { key, modifiers } = *e else { return false };
        if !self.is_program_full_screen || key != InputKey::Escape || modifiers != sq_draw::InputModifiers::NONE {
            return false;
        }
        self.exit_program_full_screen();
        true
    }

    /// The picture's rectangle: the sequence's frame fitted into the window, centered.
    pub fn full_screen_picture_rect(size: CGSize, picture: (i64, i64)) -> CGRect {
        if picture.0 <= 0 || picture.1 <= 0 || size.width <= 0.0 || size.height <= 0.0 {
            return CGRect::new(0.0, 0.0, size.width, size.height);
        }
        let k = (size.width / picture.0 as f64).min(size.height / picture.1 as f64);
        let (w, h) = ((picture.0 as f64 * k).round(), (picture.1 as f64 * k).round());
        CGRect::new(((size.width - w) / 2.0).round(), ((size.height - h) / 2.0).round(), w, h)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{session, shell};
    use sq_draw::InputModifiers;

    #[test]
    fn picture_fits_the_window_and_centers() {
        let r = ShellHost::full_screen_picture_rect(CGSize::new(1000.0, 500.0), (1920, 1080));
        assert_eq!((r.width, r.height), (889.0, 500.0));
        assert_eq!((r.x, r.y), (56.0, 0.0));
        let whole = ShellHost::full_screen_picture_rect(CGSize::new(800.0, 600.0), (0, 0));
        assert_eq!(whole, CGRect::new(0.0, 0.0, 800.0, 600.0));
    }

    #[test]
    fn escape_leaves_full_screen_and_a_second_enter_is_refused() {
        let mut host = shell();
        let session = session();
        assert!(host.enter_program_full_screen(&session));
        assert!(!host.enter_program_full_screen(&session));
        assert_eq!(host.take_events(), vec![ShellEvent::FullScreen(true)]);
        let esc = InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE };
        let other = InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::SHIFT };
        assert!(!host.full_screen_key(&other));
        assert!(host.full_screen_key(&esc));
        assert!(!host.is_program_full_screen);
        assert_eq!(host.take_events(), vec![ShellEvent::FullScreen(false)]);
        assert!(!host.full_screen_key(&esc));
    }
}

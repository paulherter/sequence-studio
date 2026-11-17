// Swift: AppController+FloatingPanels.swift (FloatingPanelWindow)
//! The OS windows of the floating panels. The shell keeps the state (`ShellDock::floating`: one window per floating panel with
//! its screen frame and its rectangle on the shared canvas); this file opens a window per entry, shows the region of the frame
//! at the rectangle, sends the window's mouse events moved by the rectangle's origin and reports the frame the user gave it.

use crate::input::Pointer;
use crate::surface::Surface;
use sq_uikit::controls_grid::CGRect;
use sq_uikit::panel_id::PanelID;
use std::sync::Arc;
use winit::window::Window;

/// The primary screen the shell's screen points (y up, origin at the bottom left) are measured on.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Screen {
    /// Top left of the screen, device pixels.
    pub origin: (i32, i32),
    /// Size in points.
    pub size: (f64, f64),
    /// Device pixels per point.
    pub scale: f64,
}

impl Screen {
    /// The screen as the shell's `main_screen_frame` (points, y up).
    pub fn frame(&self) -> CGRect {
        CGRect::new(0.0, 0.0, self.size.0, self.size.1)
    }

    /// Where the OS window of `frame` (points, y up) sits: top left and size in device pixels.
    pub fn os_rect(self, frame: CGRect) -> ((i32, i32), (u32, u32)) {
        let top = self.size.1 - frame.y - frame.height;
        (
            (self.origin.0 + (frame.x * self.scale).round() as i32, self.origin.1 + (top * self.scale).round() as i32),
            ((frame.width * self.scale).round().max(1.0) as u32, (frame.height * self.scale).round().max(1.0) as u32),
        )
    }

    /// The shell frame (points, y up) of an OS window at `pos` with `size` device pixels; the window's own scale
    /// converts its size (a float on another display or a compositor scale), the screen's the position.
    pub fn shell_frame_at(self, pos: (i32, i32), size: (u32, u32), window_scale: f64) -> CGRect {
        let (w, h) = (f64::from(size.0) / window_scale, f64::from(size.1) / window_scale);
        let top = f64::from(pos.1 - self.origin.1) / self.scale;
        CGRect::new(f64::from(pos.0 - self.origin.0) / self.scale, self.size.1 - top - h, w, h)
    }

    /// The frame after the OS moved or resized a float. `pos` is `None` where the system does not tell a window's position
    /// (Wayland): the size is still taken, the left and top edges stay where `applied` had them. Without this a resize
    /// by the grip never reached the shell there, and the content stayed at the old size.
    pub fn frame_after(self, pos: Option<(i32, i32)>, size: (u32, u32), window_scale: f64, applied: CGRect) -> CGRect {
        match pos {
            Some(p) => self.shell_frame_at(p, size, window_scale),
            None => {
                let (w, h) = (f64::from(size.0) / window_scale, f64::from(size.1) / window_scale);
                CGRect::new(applied.x, applied.max_y() - h, w, h)
            }
        }
    }
}

/// The part of the shared canvas a float window shows: `rect` (points, y down) at the canvas scale, in canvas pixels. It
/// does not depend on the window's pixel size: the renderer maps the cut list onto the window, so the content fills it
/// exactly at any window scale.
pub fn canvas_region(rect: CGRect, canvas_scale: f64) -> (f32, f32, f32, f32) {
    (
        (rect.x * canvas_scale) as f32,
        (rect.y * canvas_scale) as f32,
        (rect.width * canvas_scale) as f32,
        (rect.height * canvas_scale) as f32,
    )
}

/// A cursor position in the float window (device px of the window) as a canvas point (canvas px).
pub fn canvas_point(rect: CGRect, canvas_scale: f64, window_scale: f64, pos: (f64, f64)) -> (f64, f64) {
    let k = canvas_scale / window_scale.max(f64::EPSILON);
    (pos.0 * k + rect.x * canvas_scale, pos.1 * k + rect.y * canvas_scale)
}

/// One open floating window.
pub struct FloatWin {
    pub panel: PanelID,
    pub window: Arc<Window>,
    pub surface: Surface,
    pub pointer: Pointer,
    /// The monitor picture generation this surface holds.
    pub uploaded_generation: i64,
    /// Where the window sits on the shared canvas, points (y down).
    pub rect: CGRect,
    /// The screen frame last given to the OS window or read from it (no echo back to the shell).
    pub applied: CGRect,
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCREEN: Screen = Screen { origin: (0, 0), size: (1280.0, 720.0), scale: 1.5 };

    #[test]
    fn a_frame_round_trips_through_the_os_window() {
        let frame = CGRect::new(100.0, 200.0, 400.0, 300.0);
        let (pos, size) = SCREEN.os_rect(frame);
        assert_eq!(size, (600, 450));
        // y up: the top edge is 720 - 200 - 300 = 220 pt below the screen top.
        assert_eq!(pos, (150, 330));
        assert_eq!(SCREEN.shell_frame_at(pos, size, SCREEN.scale), frame);
    }

    #[test]
    fn a_screen_not_at_the_origin_offsets_the_window() {
        let s = Screen { origin: (-1920, 0), size: (1920.0, 1080.0), scale: 1.0 };
        let (pos, _) = s.os_rect(CGRect::new(10.0, 0.0, 100.0, 100.0));
        assert_eq!(pos, (-1910, 980));
    }

    #[test]
    fn the_region_is_the_rect_at_the_canvas_scale_for_every_scale() {
        let rect = CGRect::new(1280.0, 0.0, 400.0, 300.0);
        for (scale, w, h) in [(1.0, 400.0, 300.0), (1.5, 600.0, 450.0), (2.0, 800.0, 600.0)] {
            let (x, y, rw, rh) = canvas_region(rect, scale);
            assert_eq!((rw, rh), (w, h), "scale {scale}");
            assert_eq!((x, y), (1280.0 * scale as f32, 0.0));
            // The window the OS opens for this frame has the same size in its own pixels: nothing is left blank.
            let s = Screen { origin: (0, 0), size: (1280.0, 720.0), scale };
            let (_, size) = s.os_rect(CGRect::new(0.0, 0.0, 400.0, 300.0));
            assert_eq!((f32::from(size.0 as u16), f32::from(size.1 as u16)), (rw, rh));
        }
    }

    #[test]
    fn a_resize_without_a_known_position_keeps_the_top_left_and_takes_the_new_size() {
        let s = Screen { origin: (0, 0), size: (1280.0, 720.0), scale: 1.5 };
        let applied = CGRect::new(100.0, 200.0, 379.0, 462.0);
        let f = s.frame_after(None, (876, 855), 1.5, applied);
        assert_eq!((f.width, f.height), (584.0, 570.0));
        assert_eq!((f.x, f.max_y()), (100.0, applied.max_y()));
        assert_ne!(f, applied, "the shell is told, so the canvas rectangle follows");
    }

    #[test]
    fn a_window_with_its_own_scale_reports_its_frame_in_points() {
        // A 600 x 450 px window at scale 1.5 is 400 x 300 pt even when the screen is measured at 2.
        let s = Screen { origin: (0, 0), size: (1280.0, 720.0), scale: 2.0 };
        let f = s.shell_frame_at((0, 0), (600, 450), 1.5);
        assert_eq!((f.width, f.height), (400.0, 300.0));
    }

    #[test]
    fn a_cursor_maps_to_the_canvas_whatever_the_window_scale() {
        let rect = CGRect::new(1280.0, 10.0, 400.0, 300.0);
        // Same scale: the window origin is the rect origin.
        assert_eq!(canvas_point(rect, 1.5, 1.5, (30.0, 60.0)), (1280.0 * 1.5 + 30.0, 15.0 + 60.0));
        // The window at 1 while the canvas is at 2: a pixel is two canvas pixels.
        assert_eq!(canvas_point(rect, 2.0, 1.0, (30.0, 60.0)), (2560.0 + 60.0, 20.0 + 120.0));
        // The far corner of the window lands on the far corner of the rect.
        let (x, y) = canvas_point(rect, 2.0, 1.0, (400.0, 300.0));
        assert_eq!((x, y), (rect.max_x() * 2.0, rect.max_y() * 2.0));
    }
}

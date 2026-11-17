//! The eyedropper that samples the Program monitor picture: the inspector arms it, the monitor host answers with the
//! next click inside the picture (Swift `AppScreenSampler`, here limited to the picture the app shows itself).

use sq_draw::RgbaImage;
use sq_uikit::controls_grid::CGRect;
use std::cell::RefCell;
use std::rc::Rc;

/// sRGB components 0...1 of one picked pixel.
pub type Rgb = (f64, f64, f64);

/// One picked pixel and where it was: frame fractions `(u, v)` (0...1, origin top left), so a reader of the linear
/// picture can average a patch there.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pick {
    pub rgb: Rgb,
    pub at: (f64, f64),
    /// True when the pixel came from the Program picture (`at` is a place in it, a linear patch may be read there);
    /// false when it came from the app's own window frame (UI pixels, display-encoded only).
    pub on_picture: bool,
}

/// The sampler's one state. `Picked(None)`-style answers are `Canceled`; both wait to be taken once.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum SamplerState {
    #[default]
    Idle,
    /// A click is awaited; the loupe follows the pointer.
    Sampling,
    Picked(Pick),
    Canceled,
}

#[derive(Default)]
struct State {
    mode: SamplerState,
    /// The app's last presented frame (window pixels, display-encoded), rendered once when sampling starts.
    window: Option<RgbaImage>,
}

/// A handle shared by the inspector host and the monitor host (clones see the same state).
#[derive(Clone, Default)]
pub struct Eyedropper(Rc<RefCell<State>>);

impl Eyedropper {
    /// The next click is sampled: in the monitor picture (monitor pixels) or in the app's own window frame.
    pub fn arm(&self) {
        let mut s = self.0.borrow_mut();
        s.mode = SamplerState::Sampling;
        s.window = None;
    }

    /// The state now.
    pub fn state(&self) -> SamplerState {
        self.0.borrow().mode
    }

    /// True while a click is awaited.
    pub fn is_armed(&self) -> bool {
        self.state() == SamplerState::Sampling
    }

    /// Ends a running pick without a color.
    pub fn cancel(&self) {
        let mut s = self.0.borrow_mut();
        if s.mode == SamplerState::Sampling {
            s.mode = SamplerState::Canceled;
            s.window = None;
        }
    }

    /// The finished pick, once: `Some(None)` = canceled.
    pub fn take_answer(&self) -> Option<Option<Rgb>> {
        self.take_pick().map(|p| p.map(|p| p.rgb))
    }

    /// The finished pick with its place in the frame, once: `Some(None)` = canceled.
    pub fn take_pick(&self) -> Option<Option<Pick>> {
        let mut s = self.0.borrow_mut();
        let answer = match s.mode {
            SamplerState::Picked(p) => Some(Some(p)),
            SamplerState::Canceled => Some(None),
            _ => None,
        };
        if answer.is_some() {
            s.mode = SamplerState::Idle;
        }
        answer
    }

    /// True when a finished pick waits to be taken.
    pub fn has_answer(&self) -> bool {
        matches!(self.state(), SamplerState::Picked(_) | SamplerState::Canceled)
    }

    /// Sampling has started and the window frame is not in yet: the window loop renders its last frame once.
    pub fn wants_window_frame(&self) -> bool {
        let s = self.0.borrow();
        s.mode == SamplerState::Sampling && s.window.is_none()
    }

    /// The window loop's answer to [`wants_window_frame`](Self::wants_window_frame).
    pub fn set_window_frame(&self, frame: RgbaImage) {
        let mut s = self.0.borrow_mut();
        if s.mode == SamplerState::Sampling {
            s.window = Some(frame);
        }
    }

    /// The loupe grid around window pixel `(x, y)`; `None` before the frame is in or outside it.
    pub fn window_loupe(&self, x: f64, y: f64) -> Option<sq_draw_monitor::color_loupe::ColorLoupe> {
        let s = self.0.borrow();
        let image = s.window.as_ref()?;
        let (u, v) = (x / image.width.max(1) as f64, y / image.height.max(1) as f64);
        loupe(image, u, v)
    }

    /// A press at window pixel `(x, y)` outside the Program picture: picks that pixel of the window frame (no frame
    /// or outside it: canceled). Returns true (the press is used up).
    pub fn pick_window(&self, x: f64, y: f64) -> bool {
        let mut s = self.0.borrow_mut();
        if s.mode != SamplerState::Sampling {
            return false;
        }
        let pick = s.window.as_ref().and_then(|image| {
            let (u, v) = (x / image.width.max(1) as f64, y / image.height.max(1) as f64);
            sample(image, u, v).map(|rgb| Pick { rgb, at: (u, v), on_picture: false })
        });
        s.mode = pick.map_or(SamplerState::Canceled, SamplerState::Picked);
        s.window = None;
        true
    }

    /// A press at `(x, y)` (window points) while the picture fills `canvas`. Returns true when the press was the pick or
    /// ended it (a press outside the picture cancels), so the monitor does not also use it.
    pub fn offer(&self, picture: Option<&RgbaImage>, canvas: CGRect, x: f64, y: f64) -> bool {
        if !self.is_armed() {
            return false;
        }
        let inside = canvas.width > 0.0 && canvas.height > 0.0 && x >= canvas.x && y >= canvas.y;
        let u = (x - canvas.x) / canvas.width.max(f64::MIN_POSITIVE);
        let v = (y - canvas.y) / canvas.height.max(f64::MIN_POSITIVE);
        let color = if inside {
            picture.and_then(|p| sample(p, u, v)).map(|rgb| Pick { rgb, at: (u, v), on_picture: true })
        } else {
            None
        };
        let mut s = self.0.borrow_mut();
        s.mode = color.map_or(SamplerState::Canceled, SamplerState::Picked);
        s.window = None;
        true
    }
}

/// The pixel under frame fractions `(u, v)` (0...1, origin top left); `None` outside the picture or for an empty one.
pub fn sample(image: &RgbaImage, u: f64, v: f64) -> Option<Rgb> {
    if image.width == 0 || image.height == 0 || !(0.0..1.0).contains(&u) || !(0.0..1.0).contains(&v) {
        return None;
    }
    let (x, y) = ((u * image.width as f64) as usize, (v * image.height as f64) as usize);
    let at = (y * image.width + x) * 4;
    let px = image.pixels.get(at..at + 3)?;
    Some((f64::from(px[0]) / 255.0, f64::from(px[1]) / 255.0, f64::from(px[2]) / 255.0))
}

/// The loupe's grid around frame fractions `(u, v)` from the shown picture (Swift `ProgramLinearFrame.loupe`):
/// `ColorLoupe::SIDE` pixels per side, cut at the picture edge with the center moved to match. `None` outside the picture.
pub fn loupe(image: &RgbaImage, u: f64, v: f64) -> Option<sq_draw_monitor::color_loupe::ColorLoupe> {
    if !(0.0..=1.0).contains(&u) || !(0.0..=1.0).contains(&v) || image.pixels.len() < image.width * image.height * 4 {
        return None;
    }
    let side = sq_draw_monitor::color_loupe::ColorLoupe::SIDE;
    let (x0, y0, w, h) = super::picture_sampler::patch(image.width, image.height, [u, v], (side / 2) as i64)?;
    let cx = ((u * image.width as f64) as usize).min(image.width - 1);
    let cy = ((v * image.height as f64) as usize).min(image.height - 1);
    let mut pixels = Vec::with_capacity(w * h);
    for y in y0..y0 + h {
        for x in x0..x0 + w {
            let at = (y * image.width + x) * 4;
            pixels.push([image.pixels[at], image.pixels[at + 1], image.pixels[at + 2]]);
        }
    }
    Some(sq_draw_monitor::color_loupe::ColorLoupe { width: w, height: h, pixels, center_x: cx - x0, center_y: cy - y0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_loupe_is_cut_at_the_edge_and_keeps_the_pointer_cell_centered_on_the_pixel() {
        let (w, h) = (20usize, 20usize);
        let mut pixels = Vec::new();
        for y in 0..h {
            for x in 0..w {
                pixels.extend_from_slice(&[x as u8, y as u8, 7, 255]);
            }
        }
        let img = RgbaImage { width: w, height: h, pixels };
        let mid = loupe(&img, 0.5, 0.5).expect("loupe");
        assert_eq!((mid.width, mid.height), (11, 11));
        assert_eq!(mid.center(), [10, 10, 7]);
        let corner = loupe(&img, 0.0, 0.0).expect("loupe");
        assert_eq!((corner.width, corner.height, corner.center_x, corner.center_y), (6, 6, 0, 0));
        assert_eq!(corner.center(), [0, 0, 7]);
        assert!(loupe(&img, 1.5, 0.5).is_none());
    }

    fn two_pixels() -> RgbaImage {
        RgbaImage { width: 2, height: 1, pixels: vec![255, 0, 0, 255, 0, 0, 255, 255] }
    }

    #[test]
    fn samples_the_pixel_under_the_fraction() {
        let img = two_pixels();
        assert_eq!(sample(&img, 0.25, 0.5), Some((1.0, 0.0, 0.0)));
        assert_eq!(sample(&img, 0.75, 0.5), Some((0.0, 0.0, 1.0)));
        assert_eq!(sample(&img, 1.0, 0.5), None);
        assert_eq!(sample(&img, -0.1, 0.5), None);
    }

    #[test]
    fn a_click_in_the_picture_answers_once() {
        let e = Eyedropper::default();
        let canvas = CGRect::new(100.0, 50.0, 200.0, 100.0);
        assert!(!e.offer(Some(&two_pixels()), canvas, 250.0, 80.0), "not armed: the press is not ours");
        e.arm();
        assert!(e.offer(Some(&two_pixels()), canvas, 250.0, 80.0));
        assert_eq!(e.take_answer(), Some(Some((0.0, 0.0, 1.0))));
        assert_eq!(e.take_answer(), None);
        assert!(!e.is_armed());
    }

    #[test]
    fn a_click_outside_or_cancel_answers_none() {
        let e = Eyedropper::default();
        let canvas = CGRect::new(100.0, 50.0, 200.0, 100.0);
        e.arm();
        assert!(e.offer(Some(&two_pixels()), canvas, 10.0, 80.0));
        assert_eq!(e.take_answer(), Some(None));
        e.arm();
        e.cancel();
        assert_eq!(e.take_answer(), Some(None));
        e.cancel();
        assert_eq!(e.take_answer(), None, "cancel without a pick says nothing");
    }

    fn window_frame() -> RgbaImage {
        // 4 x 2 window: left half a UI gray, right half a green.
        let mut pixels = Vec::new();
        for _y in 0..2 {
            for x in 0..4 {
                pixels.extend_from_slice(if x < 2 { &[40, 40, 40, 255] } else { &[0, 200, 0, 255] });
            }
        }
        RgbaImage { width: 4, height: 2, pixels }
    }

    #[test]
    fn the_state_machine_runs_idle_sampling_picked_idle() {
        let e = Eyedropper::default();
        assert_eq!(e.state(), SamplerState::Idle);
        assert!(!e.wants_window_frame());
        e.arm();
        assert_eq!(e.state(), SamplerState::Sampling);
        assert!(e.wants_window_frame());
        e.set_window_frame(window_frame());
        assert!(!e.wants_window_frame());
        assert!(e.pick_window(3.5, 0.5));
        assert!(matches!(e.state(), SamplerState::Picked(p) if !p.on_picture));
        assert_eq!(e.take_answer(), Some(Some((0.0, 200.0 / 255.0, 0.0))));
        assert_eq!(e.state(), SamplerState::Idle);
        assert!(!e.pick_window(1.0, 1.0), "idle: nothing to pick");
    }

    #[test]
    fn a_window_pick_reads_the_pixel_under_the_pointer_and_is_not_a_picture_pick() {
        let e = Eyedropper::default();
        e.arm();
        e.set_window_frame(window_frame());
        assert!(e.pick_window(0.2, 1.9));
        let pick = e.take_pick().and_then(|p| p);
        assert_eq!(pick.map(|p| p.rgb), Some((40.0 / 255.0, 40.0 / 255.0, 40.0 / 255.0)));
        assert_eq!(pick.map(|p| p.on_picture), Some(false));
    }

    #[test]
    fn a_window_press_without_a_frame_or_outside_it_cancels() {
        let e = Eyedropper::default();
        e.arm();
        assert!(e.pick_window(1.0, 1.0), "no frame yet");
        assert_eq!(e.take_pick(), Some(None));
        e.arm();
        e.set_window_frame(window_frame());
        assert!(e.pick_window(9.0, 0.5), "outside the window");
        assert_eq!(e.take_pick(), Some(None));
    }

    #[test]
    fn cancel_drops_the_frame_and_a_new_arm_starts_clean() {
        let e = Eyedropper::default();
        e.arm();
        e.set_window_frame(window_frame());
        assert!(e.window_loupe(1.0, 1.0).is_some());
        e.cancel();
        assert_eq!(e.state(), SamplerState::Canceled);
        assert!(e.window_loupe(1.0, 1.0).is_none());
        e.set_window_frame(window_frame());
        assert!(e.window_loupe(1.0, 1.0).is_none(), "a late frame after cancel is dropped");
        assert_eq!(e.take_pick(), Some(None));
        e.arm();
        assert!(e.wants_window_frame());
    }

    #[test]
    fn the_window_loupe_is_centered_on_the_pixel_and_cut_at_the_edge() {
        let e = Eyedropper::default();
        e.arm();
        e.set_window_frame(window_frame());
        let l = e.window_loupe(3.5, 0.5).expect("loupe");
        assert_eq!(l.center(), [0, 200, 0]);
        let first = e.window_loupe(0.5, 0.5).expect("loupe");
        assert_eq!(first.center(), [40, 40, 40]);
    }
}

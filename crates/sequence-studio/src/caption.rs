//! The drawn window caption of the borderless Windows and Linux windows: Minimize, Maximize/Restore and Close at the
//! right end of the menu row, and the hit test that makes the rest of that row a drag area and the window's edges resize
//! handles (Swift `CaptionRowHost`, WindowCaption.swift). The logic is shared: `caption_root.rs` draws it on both systems;
//! Windows answers its frame messages from the hit test, the Linux window loop (main.rs) turns the same hit test into
//! winit's move and resize requests (`WindowControls`), because winit has no system title bar to do that.

use sq_draw::{Canvas, DrawTheme, InputEvent};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqicon::SQIcon;
use std::sync::{Arc, Mutex};
use winit::window::{CursorIcon, ResizeDirection};

/// The title bar's height in points (the menu titles and the title row share it); the window buttons are as tall.
pub const HEIGHT: f64 = sq_uikit::redesign_tokens::size::TOP_BAR as f64;
/// Air between the last control of the bar (Export, the start screen's search) and the Minimize button, in points.
pub const BUTTONS_AIR: f64 = 8.0;
/// Export's right edge sits this far from the window edge: the three buttons and the air (spec §14).
pub const EXPORT_MARGIN: f64 = BUTTONS_WIDTH + BUTTONS_AIR;
/// Windows 11 caption buttons are 46 points wide.
const BUTTON_WIDTH: f64 = 46.0;
/// The three buttons together.
pub const BUTTONS_WIDTH: f64 = 3.0 * BUTTON_WIDTH;
/// The invisible resize band inside the window's edges (points); none while maximized.
const RESIZE_BAND: f64 = 6.0;
/// Room kept free for dragging between the menu titles and the buttons (points).
const DRAG_ROOM: f64 = 48.0;

/// The start bar's right inset so its search field ends `BUTTONS_AIR` before the buttons, like Export: the field already keeps
/// `START_BAR_EDGE` of its own.
pub const START_BAR_INSET: f64 = BUTTONS_WIDTH + BUTTONS_AIR - sq_draw_shell::START_BAR_EDGE;

/// Export's right edge from the window edge. Windows and Linux draw their own buttons there (146 pt, spec §14); the Mac's
/// lights float at the left, so its app bar keeps 10 pt.
pub fn export_margin(platform: sq_os::Platform) -> f64 {
    if draws_own_buttons(platform) { EXPORT_MARGIN } else { 10.0 }
}

/// Windows and Linux draw min/max/close in the app bar (no system title bar on either: client-side decorations on
/// Linux); the Mac keeps its native lights.
pub fn draws_own_buttons(platform: sq_os::Platform) -> bool {
    platform != sq_os::Platform::Mac
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Minimize,
    Maximize,
    Close,
}

const BUTTONS: [Button; 3] = [Button::Minimize, Button::Maximize, Button::Close];

/// What a window point is to the window manager.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowHit {
    Client,
    Caption,
    Button(Button),
    Left,
    Right,
    Top,
    Bottom,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

impl WindowHit {
    /// The edge or corner a press starts resizing from and the cursor that shows it.
    pub fn resize(self) -> Option<(ResizeDirection, CursorIcon)> {
        Some(match self {
            WindowHit::Left => (ResizeDirection::West, CursorIcon::EwResize),
            WindowHit::Right => (ResizeDirection::East, CursorIcon::EwResize),
            WindowHit::Top => (ResizeDirection::North, CursorIcon::NsResize),
            WindowHit::Bottom => (ResizeDirection::South, CursorIcon::NsResize),
            WindowHit::TopLeft => (ResizeDirection::NorthWest, CursorIcon::NwseResize),
            WindowHit::TopRight => (ResizeDirection::NorthEast, CursorIcon::NeswResize),
            WindowHit::BottomLeft => (ResizeDirection::SouthWest, CursorIcon::NeswResize),
            WindowHit::BottomRight => (ResizeDirection::SouthEast, CursorIcon::NwseResize),
            WindowHit::Client | WindowHit::Caption | WindowHit::Button(_) => return None,
        })
    }
}

/// A second press this soon (seconds) and this near (points) after a press that a control or menu took is the second half
/// of a double-click on that control.
const DOUBLE_CLICK_SECONDS: f64 = 0.6;
const DOUBLE_CLICK_SLOP: f32 = 6.0;

/// What a press on the title bar does to the window.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TitleAction {
    Nothing,
    /// Hand the mouse to the window manager's move.
    Drag,
    /// A double-click on empty bar space.
    ToggleMaximize,
}

/// Decides for every press whether it moves the window, maximizes it, or does nothing. Only EMPTY bar space may do either
/// (`WindowHit::Caption`: no menu title, button or popup row); a press right after one that a control took is the second
/// half of a double-click on that control (a Workspace button row that has closed by now) and never drags or maximizes.
#[derive(Clone, Copy, Debug, Default)]
pub struct TitleClicks {
    /// When and where (device pixels) the last press that something took (or that missed the empty bar) landed.
    other: Option<(f64, f32, f32)>,
    /// The same for the last press on empty bar space.
    empty: Option<(f64, f32, f32)>,
}

impl TitleClicks {
    /// A primary press at (`x`, `y`) device pixels at `now` seconds; `hit` is what the point is (`CaptionState::hit_px`)
    /// and `taken` whether the app took the press.
    pub fn press(&mut self, hit: WindowHit, x: f32, y: f32, scale: f32, taken: bool, now: f64) -> TitleAction {
        let slop = DOUBLE_CLICK_SLOP * scale;
        let near = |p: Option<(f64, f32, f32)>| {
            p.is_some_and(|(t, px, py)| {
                now - t <= DOUBLE_CLICK_SECONDS && (x - px).abs() <= slop && (y - py).abs() <= slop
            })
        };
        let (second_half, double) = (near(self.other), near(self.empty));
        let on_empty = hit == WindowHit::Caption && !taken;
        self.other = (!on_empty).then_some((now, x, y));
        // A second press on the bar is the double-click; after it the next one starts a new count.
        self.empty = (on_empty && !double && !second_half).then_some((now, x, y));
        match (on_empty, second_half, double) {
            (false, ..) | (_, true, _) => TitleAction::Nothing,
            (true, false, true) => TitleAction::ToggleMaximize,
            (true, false, false) => TitleAction::Drag,
        }
    }
}

/// Where the buttons are and what the pointer does to them. Shared between the draw UI (layout, draw, input) and the
/// window procedure (hit test, maximize button), so every access is short and never blocks.
#[derive(Default)]
pub struct CaptionState {
    /// Maximized: Restore shows instead of Maximize and the edges do not resize.
    pub maximized: bool,
    /// Device pixels per point.
    pub scale: f64,
    size: (f64, f64),
    frames: [CGRect; 3],
    /// Menu titles and anything else in the drag row that takes clicks.
    controls: Vec<CGRect>,
    /// The height of the drag rows (menu row and title row); 0 while a menu is open, so a click outside reaches the menu.
    drag_height: f64,
    hovered: Option<Button>,
    pressed: Option<Button>,
    /// Close was clicked and the window loop has not asked the app yet (Linux; Windows posts its own close message).
    close_asked: bool,
}

pub type Shared = Arc<Mutex<CaptionState>>;

impl CaptionState {
    /// The Close button fired; the window loop picks the request up with [`CaptionState::take_close`].
    pub fn ask_close(&mut self) {
        self.close_asked = true;
    }

    /// Whether Close was clicked since the last call.
    pub fn take_close(&mut self) -> bool {
        std::mem::take(&mut self.close_asked)
    }

    /// The menu titles' room from `x` in a window `width` points wide.
    pub fn menu_room(x: f64, width: f64) -> f64 {
        (width - 3.0 * BUTTON_WIDTH - DRAG_ROOM - x).max(0.0)
    }

    /// Places the buttons in a window of `width` x `height` points; `controls` are the clickable frames of the drag
    /// rows, which reach down to `rows_bottom`.
    pub fn layout(&mut self, width: f64, height: f64, controls: Vec<CGRect>, rows_bottom: f64, menu_open: bool) {
        self.size = (width, height);
        self.controls = controls;
        self.drag_height = if menu_open { 0.0 } else { rows_bottom };
        for (i, frame) in self.frames.iter_mut().enumerate() {
            *frame = CGRect::new(width - BUTTON_WIDTH * (3 - i) as f64, 0.0, BUTTON_WIDTH, HEIGHT);
        }
    }

    fn button_at(&self, p: CGPoint) -> Option<Button> {
        BUTTONS.into_iter().zip(&self.frames).find(|(_, f)| f.contains(p)).map(|(b, _)| b)
    }

    /// What the point `p` (points) is: edges resize (unless maximized), the buttons are buttons, the drag row drags
    /// except over its controls.
    pub fn hit(&self, p: CGPoint) -> WindowHit {
        let (w, h) = self.size;
        if !self.maximized {
            let (b, corner) = (RESIZE_BAND, 2.0 * RESIZE_BAND);
            let (l, r, t, bt) = (p.x < b, p.x >= w - b, p.y < b, p.y >= h - b);
            let (lc, rc, tc, bc) = (p.x < corner, p.x >= w - corner, p.y < corner, p.y >= h - corner);
            if (t && lc) || (l && tc) {
                return WindowHit::TopLeft;
            }
            if (t && rc) || (r && tc) {
                return WindowHit::TopRight;
            }
            if (bt && lc) || (l && bc) {
                return WindowHit::BottomLeft;
            }
            if (bt && rc) || (r && bc) {
                return WindowHit::BottomRight;
            }
            for (on, hit) in [(l, WindowHit::Left), (r, WindowHit::Right), (t, WindowHit::Top), (bt, WindowHit::Bottom)]
            {
                if on {
                    return hit;
                }
            }
        }
        if let Some(b) = self.button_at(p) {
            return WindowHit::Button(b);
        }
        if p.y < 0.0 || p.y >= self.drag_height || self.controls.iter().any(|c| c.contains(p)) {
            return WindowHit::Client;
        }
        WindowHit::Caption
    }

    /// The hit of a client pixel.
    pub fn hit_px(&self, x: f32, y: f32) -> WindowHit {
        let k = self.scale.max(0.01);
        self.hit(CGPoint::new(f64::from(x) / k, f64::from(y) / k))
    }

    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme) {
        for (b, r) in BUTTONS.into_iter().zip(&self.frames) {
            let active = self.pressed == Some(b) || (self.pressed.is_none() && self.hovered == Some(b));
            let mut ink = t.label2();
            if active {
                if b == Button::Close {
                    let red = t.red();
                    c.fill(*r, if self.pressed == Some(b) { red.lifted(-0.1) } else { red });
                    ink = sq_draw::Color::WHITE;
                } else {
                    c.fill(*r, if self.pressed == Some(b) { t.fill_pressed() } else { t.fill_hover() });
                }
            }
            let icon = match b {
                Button::Minimize => SQIcon::Minus,
                Button::Maximize if self.maximized => SQIcon::Copy,
                Button::Maximize => SQIcon::RoundedSquare,
                Button::Close => SQIcon::Close,
            };
            let size = if b == Button::Close { 16.0 } else { 14.0 };
            let at =
                CGPoint::new((r.x + r.width / 2.0 - size / 2.0).round(), (r.y + r.height / 2.0 - size / 2.0).round());
            c.draw_icon(icon, at, size, ink, None);
        }
    }

    /// The pointer moved to client pixel (`x`, `y`); true when the hover changed.
    pub fn moved(&mut self, x: f32, y: f32) -> bool {
        let k = self.scale.max(0.01);
        let over = self.button_at(CGPoint::new(f64::from(x) / k, f64::from(y) / k));
        std::mem::replace(&mut self.hovered, over) != over
    }

    /// The pointer left the buttons.
    pub fn left(&mut self) -> bool {
        self.hovered.take().is_some()
    }

    /// A press at client pixel (`x`, `y`); true when it hit a button.
    pub fn pressed_at(&mut self, x: f32, y: f32) -> bool {
        let k = self.scale.max(0.01);
        self.pressed = self.button_at(CGPoint::new(f64::from(x) / k, f64::from(y) / k));
        self.hovered = self.pressed;
        self.pressed.is_some()
    }

    /// A release at client pixel (`x`, `y`): the pressed button when the pointer is still over it.
    pub fn released_at(&mut self, x: f32, y: f32) -> Option<Button> {
        let k = self.scale.max(0.01);
        let b = self.pressed.take()?;
        (self.button_at(CGPoint::new(f64::from(x) / k, f64::from(y) / k)) == Some(b)).then_some(b)
    }

    /// Hover, press and release on the buttons (client-area events in pixels). Returns whether the event is the
    /// buttons' and the button a release fired.
    pub fn handle(&mut self, e: &InputEvent) -> (bool, Option<Button>) {
        match *e {
            InputEvent::MouseMoved { x, y } => {
                self.moved(x, y);
                (false, None)
            }
            InputEvent::MouseDown { x, y, modifiers } if !modifiers.contains(sq_draw::InputModifiers::SECONDARY) => {
                (self.pressed_at(x, y), None)
            }
            InputEvent::MouseDragged { x, y, .. } if self.pressed.is_some() => {
                self.moved(x, y);
                (true, None)
            }
            InputEvent::MouseUp { x, y } if self.pressed.is_some() => (true, self.released_at(x, y)),
            _ => (false, None),
        }
    }
}

/// What the window loop of a system without a system title bar (Linux) asks of the caption: the same frames the Windows
/// frame messages read, answered as winit's move and resize requests. The loop makes the winit calls themselves.
pub struct WindowControls {
    state: Shared,
    clicks: TitleClicks,
    /// The resize cursor of the edge under the pointer.
    edge: Option<CursorIcon>,
    /// The resize cursor the window shows now.
    shown: Option<CursorIcon>,
}

impl WindowControls {
    pub fn new(state: Shared) -> WindowControls {
        WindowControls { state, clicks: TitleClicks::default(), edge: None, shown: None }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, CaptionState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn hit(&self, x: f32, y: f32) -> WindowHit {
        self.lock().hit_px(x, y)
    }

    /// The edge or corner a primary press at (`x`, `y`) device pixels starts resizing from; that press stays out of the app.
    pub fn edge_press(&self, x: f32, y: f32) -> Option<ResizeDirection> {
        self.hit(x, y).resize().map(|(direction, _)| direction)
    }

    /// What a primary press at (`x`, `y`) does to the window once the app has answered it (`taken`).
    pub fn title_press(&mut self, x: f32, y: f32, scale: f32, taken: bool, now: f64) -> TitleAction {
        let hit = self.hit(x, y);
        self.clicks.press(hit, x, y, scale, taken, now)
    }

    /// Whether (`x`, `y`) is empty bar space: a secondary press there opens the window manager's window menu.
    pub fn is_empty_bar(&self, x: f32, y: f32) -> bool {
        self.hit(x, y) == WindowHit::Caption
    }

    /// The pointer moved to (`x`, `y`); an app drag in progress (`dragging`) keeps its own cursor at the window's edge.
    pub fn hover(&mut self, x: f32, y: f32, dragging: bool) {
        self.edge = if dragging { None } else { self.hit(x, y).resize().map(|(_, icon)| icon) };
    }

    /// The pointer left the window: no edge cursor, no lit caption button.
    pub fn left(&mut self) {
        self.edge = None;
        self.lock().left();
    }

    /// What the window's cursor must become: `Some(Some(icon))` a resize cursor, `Some(None)` back to the app's own,
    /// `None` no change.
    pub fn cursor_change(&mut self) -> Option<Option<CursorIcon>> {
        (self.edge != self.shown).then(|| {
            self.shown = self.edge;
            self.edge
        })
    }

    /// Whether a resize cursor is on the window, so the app's own cursor must stay off it.
    pub fn shows_edge_cursor(&self) -> bool {
        self.shown.is_some()
    }

    /// Whether Close was clicked since the last call.
    pub fn take_close(&self) -> bool {
        self.lock().take_close()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> CaptionState {
        let mut s = CaptionState { scale: 2.0, ..CaptionState::default() };
        s.layout(1000.0, 600.0, vec![CGRect::new(0.0, 0.0, 200.0, HEIGHT)], 72.0, false);
        s
    }

    #[test]
    fn regions_of_the_window() {
        let s = state();
        assert_eq!(s.hit(CGPoint::new(500.0, 10.0)), WindowHit::Caption);
        assert_eq!(s.hit(CGPoint::new(100.0, 10.0)), WindowHit::Client);
        assert_eq!(s.hit(CGPoint::new(980.0, 16.0)), WindowHit::Button(Button::Close));
        assert_eq!(s.hit(CGPoint::new(910.0, 16.0)), WindowHit::Button(Button::Maximize));
        assert_eq!(s.hit(CGPoint::new(500.0, 300.0)), WindowHit::Client);
        assert_eq!(s.hit(CGPoint::new(500.0, 50.0)), WindowHit::Caption);
        assert_eq!(s.hit(CGPoint::new(500.0, 72.0)), WindowHit::Client);
        assert_eq!(s.hit(CGPoint::new(2.0, 300.0)), WindowHit::Left);
        assert_eq!(s.hit(CGPoint::new(500.0, 2.0)), WindowHit::Top);
        assert_eq!(s.hit(CGPoint::new(999.0, 599.0)), WindowHit::BottomRight);
    }

    /// Export and the start screen's search end the same distance before the Minimize button.
    #[test]
    fn export_and_the_start_search_keep_the_same_air_before_the_buttons() {
        let width = 1000.0;
        let export_gap = (width - export_margin(sq_os::Platform::Linux)) - (width - BUTTONS_WIDTH);
        let search_right = width - START_BAR_INSET - sq_draw_shell::START_BAR_EDGE;
        assert_eq!(width - BUTTONS_WIDTH - search_right, BUTTONS_AIR);
        assert_eq!(-export_gap, BUTTONS_AIR);
    }

    /// Bug 40: a double click zooms (maximizes) the window only on the caption. Every title-bar control must hit as the
    /// client, whatever part of it is clicked, and only the empty strips between them hit as the caption.
    #[test]
    fn title_bar_controls_are_never_the_caption_and_only_empty_strips_are() {
        let controls = [
            ("File menu", CGRect::new(24.0, 10.0, 40.0, 28.0)),
            ("Edit menu", CGRect::new(64.0, 10.0, 40.0, 28.0)),
            ("Workspace button", CGRect::new(300.0, 10.0, 170.0, 28.0)),
            ("Edit | Color switch", CGRect::new(600.0, 10.0, 200.0, 28.0)),
            ("Export button", CGRect::new(820.0, 10.0, 90.0, 28.0)),
        ];
        let mut s = CaptionState { scale: 1.0, ..CaptionState::default() };
        s.layout(1400.0, 900.0, controls.iter().map(|c| c.1).collect(), 72.0, false);
        for (name, r) in controls {
            for (fx, fy) in [(0.02, 0.05), (0.5, 0.5), (0.98, 0.95), (0.5, 0.05), (0.5, 0.95)] {
                let p = CGPoint::new(r.x + r.width * fx, r.y + r.height * fy);
                assert_eq!(s.hit(p), WindowHit::Client, "{name} at {p:?} is the client, never the caption");
            }
        }
        for (what, p) in [
            ("between the menus and the workspace button", CGPoint::new(200.0, 20.0)),
            ("between the workspace button and the switch", CGPoint::new(520.0, 20.0)),
            ("between the switch and Export", CGPoint::new(810.0, 20.0)),
            ("right of Export", CGPoint::new(1000.0, 20.0)),
            ("the strip below the controls", CGPoint::new(700.0, 60.0)),
        ] {
            assert_eq!(s.hit(p), WindowHit::Caption, "{what}");
        }
        // A popup is open: nothing of the rows is the caption, so a click outside reaches the popup.
        s.layout(1400.0, 900.0, Vec::new(), 72.0, true);
        assert_eq!(s.hit(CGPoint::new(200.0, 20.0)), WindowHit::Client);
    }

    #[test]
    fn maximized_has_no_resize_edges_and_an_open_menu_has_no_drag_row() {
        let mut s = state();
        s.maximized = true;
        assert_eq!(s.hit(CGPoint::new(2.0, 300.0)), WindowHit::Client);
        s.layout(1000.0, 600.0, Vec::new(), 72.0, true);
        assert_eq!(s.hit(CGPoint::new(500.0, 10.0)), WindowHit::Client);
    }

    #[test]
    fn pixels_follow_the_display_scale() {
        let s = state();
        assert_eq!(s.hit_px(1000.0, 20.0), WindowHit::Caption);
        assert_eq!(s.hit_px(1970.0, 30.0), WindowHit::Button(Button::Close));
    }

    #[test]
    fn a_release_over_the_pressed_button_fires_it() {
        let mut s = state();
        let e = |x| InputEvent::MouseUp { x, y: 20.0 };
        assert_eq!(
            s.handle(&InputEvent::MouseDown { x: 1970.0, y: 20.0, modifiers: sq_draw::InputModifiers::NONE }),
            (true, None)
        );
        assert_eq!(s.handle(&e(1970.0)), (true, Some(Button::Close)));
        s.pressed_at(1970.0, 20.0);
        assert_eq!(s.handle(&e(100.0)), (true, None));
        assert_eq!(s.handle(&e(100.0)), (false, None));
    }

    #[test]
    fn menu_room_leaves_the_buttons_and_the_drag_room() {
        assert_eq!(CaptionState::menu_room(10.0, 1000.0), 1000.0 - 138.0 - 48.0 - 10.0);
        assert_eq!(CaptionState::menu_room(10.0, 100.0), 0.0);
    }

    #[test]
    fn windows_and_linux_draw_their_own_buttons_and_the_mac_keeps_its_lights() {
        use sq_os::Platform;
        assert!(draws_own_buttons(Platform::Windows) && draws_own_buttons(Platform::Linux));
        assert!(!draws_own_buttons(Platform::Mac));
        assert_eq!(export_margin(Platform::Windows), 146.0);
        assert_eq!(export_margin(Platform::Linux), 146.0);
        assert_eq!(export_margin(Platform::Mac), 10.0);
    }

    #[test]
    fn every_edge_and_corner_resizes_from_its_side_and_nothing_else_does() {
        let s = state();
        let at = |x, y| s.hit(CGPoint::new(x, y)).resize().map(|(d, _)| d);
        assert_eq!(at(2.0, 300.0), Some(ResizeDirection::West));
        assert_eq!(at(998.0, 300.0), Some(ResizeDirection::East));
        assert_eq!(at(500.0, 2.0), Some(ResizeDirection::North));
        assert_eq!(at(500.0, 598.0), Some(ResizeDirection::South));
        assert_eq!(at(2.0, 2.0), Some(ResizeDirection::NorthWest));
        assert_eq!(at(998.0, 2.0), Some(ResizeDirection::NorthEast));
        assert_eq!(at(2.0, 598.0), Some(ResizeDirection::SouthWest));
        assert_eq!(at(998.0, 598.0), Some(ResizeDirection::SouthEast));
        // The corner reaches 12 pt along each edge, so the close button's top right corner still resizes.
        assert_eq!(at(995.0, 10.0), Some(ResizeDirection::NorthEast));
        for p in [(500.0, 20.0), (100.0, 10.0), (500.0, 300.0), (975.0, 16.0)] {
            assert_eq!(at(p.0, p.1), None, "{p:?} is the bar, a control or the client");
        }
    }

    #[test]
    fn a_second_press_on_empty_bar_space_maximizes_and_a_press_after_a_control_never_does() {
        let (e, c) = (WindowHit::Caption, WindowHit::Client);
        let mut g = TitleClicks::default();
        assert_eq!(g.press(e, 500.0, 20.0, 1.0, false, 1.0), TitleAction::Drag);
        assert_eq!(g.press(e, 502.0, 21.0, 1.0, false, 1.3), TitleAction::ToggleMaximize);
        assert_eq!(g.press(e, 502.0, 21.0, 1.0, false, 1.5), TitleAction::Drag, "a third press starts a new count");
        // Too late, or too far away: a new first press.
        assert_eq!(g.press(e, 502.0, 21.0, 1.0, false, 3.0), TitleAction::Drag);
        assert_eq!(g.press(e, 600.0, 21.0, 1.0, false, 3.2), TitleAction::Drag);
        // The second click of a double-click on a control (a popup row that closed) is neither a drag nor a zoom.
        assert_eq!(g.press(c, 500.0, 20.0, 1.0, true, 5.0), TitleAction::Nothing);
        assert_eq!(g.press(e, 501.0, 20.0, 1.0, false, 5.2), TitleAction::Nothing);
        assert_eq!(g.press(e, 501.0, 20.0, 1.0, false, 5.3), TitleAction::Drag, "the bar is empty again");
        // The slop is in points: twice the scale, twice the pixels.
        assert_eq!(g.press(e, 500.0, 20.0, 2.0, false, 9.0), TitleAction::Drag);
        assert_eq!(g.press(e, 510.0, 20.0, 2.0, false, 9.1), TitleAction::ToggleMaximize);
        // A press the app took, or that is no bar at all, is never a drag.
        assert_eq!(g.press(e, 500.0, 20.0, 1.0, true, 11.0), TitleAction::Nothing);
        assert_eq!(g.press(c, 500.0, 300.0, 1.0, false, 12.0), TitleAction::Nothing);
    }

    #[test]
    fn close_is_asked_once() {
        let mut s = state();
        assert!(!s.take_close());
        s.ask_close();
        assert!(s.take_close() && !s.take_close());
    }
}

#[cfg(test)]
mod window_controls_tests {
    use super::*;

    /// A 1000 x 600 pt window at 2 device pixels per point with one menu title at the left of the bar.
    fn controls() -> WindowControls {
        let mut state = CaptionState { scale: 2.0, ..CaptionState::default() };
        state.layout(1000.0, 600.0, vec![CGRect::new(0.0, 0.0, 200.0, HEIGHT)], 72.0, false);
        WindowControls::new(Arc::new(Mutex::new(state)))
    }

    #[test]
    fn a_press_on_an_edge_or_corner_resizes_and_a_press_inside_does_not() {
        let c = controls();
        assert_eq!(c.edge_press(4.0, 600.0), Some(ResizeDirection::West));
        assert_eq!(c.edge_press(1996.0, 600.0), Some(ResizeDirection::East));
        assert_eq!(c.edge_press(1000.0, 4.0), Some(ResizeDirection::North));
        assert_eq!(c.edge_press(1000.0, 1196.0), Some(ResizeDirection::South));
        assert_eq!(c.edge_press(2.0, 2.0), Some(ResizeDirection::NorthWest));
        assert_eq!(c.edge_press(1998.0, 1198.0), Some(ResizeDirection::SouthEast));
        // The window buttons, the menu title, the empty bar and the client all keep their press.
        for (x, y) in [(1950.0, 30.0), (1820.0, 30.0), (200.0, 30.0), (1000.0, 30.0), (1000.0, 600.0)] {
            assert_eq!(c.edge_press(x, y), None, "{x},{y}");
        }
    }

    #[test]
    fn only_empty_bar_space_drags_maximizes_or_opens_the_window_menu() {
        let mut c = controls();
        assert!(c.is_empty_bar(1000.0, 30.0) && c.is_empty_bar(1000.0, 100.0));
        assert!(!c.is_empty_bar(200.0, 30.0), "a menu title");
        assert!(!c.is_empty_bar(1950.0, 30.0), "the close button");
        assert!(!c.is_empty_bar(1000.0, 600.0), "the client");
        assert_eq!(c.title_press(1000.0, 30.0, 2.0, false, 1.0), TitleAction::Drag);
        assert_eq!(c.title_press(1002.0, 30.0, 2.0, false, 1.2), TitleAction::ToggleMaximize);
        assert_eq!(c.title_press(200.0, 30.0, 2.0, true, 2.0), TitleAction::Nothing);
        assert_eq!(c.title_press(1950.0, 30.0, 2.0, true, 4.0), TitleAction::Nothing);
    }

    /// The start screen has no title row: the bar row drags everywhere except over its menu titles and the search field,
    /// whatever the screen under it answers for a press outside it (`taken` false for empty bar space).
    #[test]
    fn the_empty_start_bar_drags_and_zooms_while_its_controls_do_not() {
        let mut state = CaptionState { scale: 2.0, ..CaptionState::default() };
        let (titles, search) = (CGRect::new(0.0, 0.0, 200.0, HEIGHT), CGRect::new(740.0, 6.0, 120.0, 28.0));
        state.layout(1000.0, 600.0, vec![titles, search], HEIGHT, false);
        let mut c = WindowControls::new(Arc::new(Mutex::new(state)));
        for (i, share) in [0.35_f32, 0.5, 0.7].into_iter().enumerate() {
            let (x, y, now) = (2000.0 * share, 30.0, 10.0 * i as f64);
            assert_eq!(c.title_press(x, y, 2.0, false, now), TitleAction::Drag, "{share}: first press drags");
            assert_eq!(
                c.title_press(x, y, 2.0, false, now + 0.2),
                TitleAction::ToggleMaximize,
                "{share}: double-click"
            );
        }
        assert_eq!(c.title_press(1600.0, 30.0, 2.0, true, 50.0), TitleAction::Nothing, "the search field took it");
        assert_eq!(c.title_press(100.0, 30.0, 2.0, true, 52.0), TitleAction::Nothing, "a menu title took it");
    }

    #[test]
    fn the_edge_cursor_follows_the_pointer_and_is_given_back() {
        let mut c = controls();
        assert_eq!(c.cursor_change(), None);
        c.hover(4.0, 600.0, false);
        assert_eq!(c.cursor_change(), Some(Some(CursorIcon::EwResize)));
        assert!(c.shows_edge_cursor());
        assert_eq!(c.cursor_change(), None, "told once");
        c.hover(1000.0, 4.0, false);
        assert_eq!(c.cursor_change(), Some(Some(CursorIcon::NsResize)));
        c.hover(1000.0, 600.0, false);
        assert_eq!(c.cursor_change(), Some(None));
        assert!(!c.shows_edge_cursor());
        // An app drag that reaches the edge keeps its own cursor; leaving the window gives it back too.
        c.hover(4.0, 600.0, true);
        assert_eq!(c.cursor_change(), None);
        c.hover(4.0, 600.0, false);
        assert_eq!(c.cursor_change(), Some(Some(CursorIcon::EwResize)));
        c.left();
        assert_eq!(c.cursor_change(), Some(None));
    }

    #[test]
    fn maximized_windows_have_no_edges_and_close_clicks_reach_the_loop() {
        let mut c = controls();
        c.lock().maximized = true;
        assert_eq!(c.edge_press(4.0, 600.0), None);
        c.hover(4.0, 600.0, false);
        assert_eq!(c.cursor_change(), None);
        assert!(!c.take_close());
        assert_eq!(c.hit(1954.0, 20.0), WindowHit::Button(Button::Close));
        c.lock().ask_close();
        assert!(c.take_close() && !c.take_close());
    }
}

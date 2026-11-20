//! What the host and the drawn panels tell each other (Swift singletons `HostHover`, `HostRequests`, `HostTypedText`,
//! `HostKeyRepeat`, `HostGesture`, `HostDragPreview`, `TextClipboard`), as one struct the app owns and lends to panels.
//! The UI runs on one thread; tests make their own `UiCx`.

use crate::canvas::Canvas;
use crate::draw_list::{Color, Rect};
use crate::glyph_atlas::TextAlign;
use crate::input::InputEvent;
use crate::scroll::ScrollGesture;
use crate::spring::DropSettle;
use crate::theme::{self, DrawTheme};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqicon::SQIcon;

/// The pointer shape a drawn panel asks for; each host maps it to its own cursors.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DrawCursor {
    /// The arrow.
    Arrow,
    /// Crosshair.
    Crosshair,
    /// Text I-beam.
    IBeam,
    /// Resize left-right.
    ResizeLeftRight,
    /// Resize up-down.
    ResizeUpDown,
    /// Open hand.
    OpenHand,
    /// Closed hand.
    ClosedHand,
    /// Pointing hand.
    PointingHand,
    /// Drag copy.
    DragCopy,
    /// Zoom in.
    ZoomIn,
    /// Not allowed.
    NotAllowed,
    /// Trim, ripple and rate stretch per side.
    TrimIn,
    /// See `TrimIn`.
    TrimOut,
    /// See `TrimIn`.
    RippleIn,
    /// See `TrimIn`.
    RippleOut,
    /// See `TrimIn`.
    RateIn,
    /// See `TrimIn`.
    RateOut,
    /// Roll.
    Roll,
    /// Slip.
    Slip,
    /// Slide.
    Slide,
    /// Razor.
    Razor,
    /// Track Select Forward.
    TrackSelect,
    /// Four-way move (drawn from the icon set, the Mac `OverlayCursors.move`).
    Move,
    /// Curved rotate arrow turned toward the corner at this many degrees (clockwise from +x, y down; 15 degree steps, 0..360).
    OverlayRotate(u16),
    /// Double arrow along this direction in degrees (15 degree steps, 0..180).
    OverlayResize(u16),
}

impl DrawCursor {
    /// The step of the overlay cursors in degrees (the Mac `OverlayCursors.step`).
    pub const OVERLAY_STEP: f64 = 15.0;

    fn quantized(angle: f64, period: f64) -> u16 {
        let a = angle.rem_euclid(period);
        (((a / Self::OVERLAY_STEP).round() * Self::OVERLAY_STEP) as u16) % period as u16
    }
    /// The rotate cursor of the corner whose outward direction on screen is `angle` degrees (clockwise from +x, y down).
    pub fn rotate(angle: f64) -> DrawCursor {
        DrawCursor::OverlayRotate(Self::quantized(angle, 360.0))
    }
    /// The double arrow along a handle's direction (a direction and its opposite look the same).
    pub fn resize(angle: f64) -> DrawCursor {
        DrawCursor::OverlayResize(Self::quantized(angle, 180.0))
    }
    /// `cursor_glyph::strokes` has lines for it: the tool shapes, the overlay cursors, and drag copy and zoom in, which
    /// Windows has no system cursor for.
    pub fn has_drawn_glyph(self) -> bool {
        self.is_tool_glyph() || self.is_overlay_glyph() || matches!(self, DrawCursor::DragCopy | DrawCursor::ZoomIn)
    }
    /// The monitor overlay cursors, drawn from the icon set on Mac and Windows alike.
    pub fn is_overlay_glyph(self) -> bool {
        matches!(self, DrawCursor::Move | DrawCursor::OverlayRotate(_) | DrawCursor::OverlayResize(_))
    }
    /// A shape the system has no cursor for: the host draws it.
    pub fn is_tool_glyph(self) -> bool {
        use DrawCursor::*;
        matches!(
            self,
            TrimIn | TrimOut | RippleIn | RippleOut | RateIn | RateOut | Roll | Slip | Slide | Razor | TrackSelect
        )
    }
}

/// One tooltip at a time, the Mac `SQTooltip` rules: shown [`TooltipLayout::DELAY`] after the pointer came to rest on a control
/// with a tip, at once when the previous tip closed by leaving its control within the hand-over window; hidden on exit,
/// press, wheel or key, and after a press it stays hidden until the pointer reaches another control.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TooltipState {
    /// The tip of the control under the pointer.
    pub text: Option<String>,
    /// Window pixels of the pointer when the control was entered.
    pub anchor: (f32, f32),
    show_at: f64,
    shown: bool,
    suppressed: bool,
    last_exit: Option<f64>,
}

impl TooltipState {
    fn hover(&mut self, offer: Option<String>, pointer: (f32, f32), now: f64) {
        if offer == self.text {
            return;
        }
        if self.shown {
            self.last_exit = Some(now);
        }
        self.shown = false;
        self.suppressed = false;
        self.text = offer;
        self.anchor = pointer;
        self.show_at = now + TooltipLayout::show_delay(now, self.last_exit);
    }
    fn dismiss(&mut self) {
        self.shown = false;
        self.last_exit = None;
        if self.text.is_some() {
            self.suppressed = true;
        }
    }
    /// A tip that will show once `now` reaches its time.
    pub fn pending(&self, _now: f64) -> bool {
        self.text.is_some() && !self.suppressed && !self.shown
    }
    /// The tip is on screen at `now`.
    pub fn is_visible(&self, now: f64) -> bool {
        self.text.is_some() && !self.suppressed && (self.shown || now >= self.show_at)
    }
    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, now: f64) {
        if !self.is_visible(now) {
            return;
        }
        let Some(text) = self.text.clone() else { return };
        self.shown = true;
        let k = c.scale.max(0.01) as f64;
        let bounds = CGSize { width: c.list.width() as f64 / k, height: c.list.height() as f64 / k };
        let pointer = CGPoint { x: self.anchor.0 as f64 / k, y: self.anchor.1 as f64 / k };
        // Fades in over `duration::BASE` once the delay passed (the tip is already there for input; only the picture follows).
        c.open_motion(CGRect::default(), 1, false, |c| TooltipLayout::draw(&text, c, pointer, bounds, t));
    }
}

/// Size, place and look of a tip (12 pt `label2` on `surface-tooltip`, padding 8 x 12, radius 8, a 0.5 ink edge, a trailing "(key)" as
/// a keycap chip).
pub struct TooltipLayout;

impl TooltipLayout {
    /// Seconds before a tip shows.
    pub const DELAY: f64 = 0.6;
    /// A tip closed by leaving its control hands over to a neighbor within this many seconds.
    pub const HAND_OVER_WINDOW: f64 = 0.8;
    const PADDING_X: f64 = 12.0;
    const PADDING_Y: f64 = 8.0;
    const RADIUS: f64 = 8.0;
    const FONT_SIZE: f64 = 12.0;
    const POINTER_OFFSET: (f64, f64) = (10.0, 18.0);
    const MARGIN: f64 = 4.0;
    const MAX_TEXT_WIDTH: f64 = 320.0;
    const CHIP_HEIGHT: f64 = 14.0;
    const CHIP_MIN_WIDTH: f64 = 14.0;
    const CHIP_PADDING: f64 = 3.0;
    const CHIP_RADIUS: f64 = 3.0;
    const CHIP_GAP: f64 = 4.0;
    const CHIP_FONT: f64 = 10.0;

    /// Delay before the tip shows.
    pub fn show_delay(now: f64, last_exit: Option<f64>) -> f64 {
        match last_exit {
            Some(l) if now - l >= 0.0 && now - l <= Self::HAND_OVER_WINDOW => 0.0,
            _ => Self::DELAY,
        }
    }

    /// "Snap (N)" -> ("Snap", Some("N")).
    pub fn split(text: &str) -> (&str, Option<&str>) {
        if let (true, Some(open)) = (text.ends_with(')'), text.rfind(" (")) {
            let key = &text[open + 2..text.len() - 1];
            if !key.is_empty() && key.chars().count() <= 12 && !key.contains('(') {
                return (&text[..open], Some(key));
            }
        }
        (text, None)
    }

    /// Below-right of the pointer; flipped above / to the left where it would leave `bounds`, then clamped.
    pub fn frame(size: CGSize, pointer: CGPoint, bounds: CGSize) -> CGRect {
        let (mut x, mut y) = (pointer.x + Self::POINTER_OFFSET.0, pointer.y + Self::POINTER_OFFSET.1);
        if x + size.width > bounds.width - Self::MARGIN {
            x = pointer.x - size.width - 2.0;
        }
        if y + size.height > bounds.height - Self::MARGIN {
            y = pointer.y - size.height - 4.0;
        }
        x = x.min((bounds.width - size.width - Self::MARGIN).max(Self::MARGIN)).max(Self::MARGIN);
        y = y.min((bounds.height - size.height - Self::MARGIN).max(Self::MARGIN)).max(Self::MARGIN);
        CGRect::new(x.round(), y.round(), size.width, size.height)
    }

    fn draw(text: &str, c: &mut Canvas, pointer: CGPoint, bounds: CGSize, t: &DrawTheme) {
        let (name, key) = Self::split(text);
        let fs = Self::FONT_SIZE;
        let line = c.size_of("Ag", fs, 0).height.max(14.0);
        let name_w = c.size_of(name, fs, 0).width;
        let key_w = key.map_or(0.0, |k| {
            Self::CHIP_MIN_WIDTH.max(c.size_of(k, Self::CHIP_FONT, 0).width.ceil() + Self::CHIP_PADDING * 2.0)
        });
        // A long tip wraps whole (its key stays in the text); a short one gets the keycap chip.
        let wraps = name_w + if key.is_none() { 0.0 } else { Self::CHIP_GAP + key_w } > Self::MAX_TEXT_WIDTH;
        let text_w = if wraps {
            Self::MAX_TEXT_WIDTH
        } else {
            name_w.ceil() + if key.is_none() { 0.0 } else { Self::CHIP_GAP + key_w }
        };
        let lines = if wraps { c.wrap(text, Self::MAX_TEXT_WIDTH, fs).len().max(1) } else { 1 };
        let size = CGSize {
            width: text_w + Self::PADDING_X * 2.0,
            height: (line * lines as f64).ceil() + Self::PADDING_Y * 2.0,
        };
        let bx = Self::frame(size, pointer, bounds);
        c.fill_rounded(bx, Self::RADIUS, t.token(sq_uikit::redesign_tokens::color::TOOLTIP));
        let ink = t.palette.ink;
        let edge = Color::new((ink.r / 255.0) as f32, (ink.g / 255.0) as f32, (ink.b / 255.0) as f32, 0.14);
        c.stroke_rounded(bx.inset_by(0.25, 0.25), Self::RADIUS, 0.5, edge);
        let inner = bx.inset_by(Self::PADDING_X, Self::PADDING_Y);
        if wraps {
            c.draw_wrapped(text, inner, fs, line, t.label2_on_raised());
            return;
        }
        c.draw_text_in(
            name,
            CGRect::new(inner.x, inner.y, name_w.ceil() + 1.0, inner.height),
            fs,
            t.label2_on_raised(),
            TextAlign::Left,
            0.0,
            0,
        );
        let Some(key) = key else { return };
        let chip = CGRect::new(
            inner.x + name_w.ceil() + Self::CHIP_GAP,
            (bx.mid_y() - Self::CHIP_HEIGHT / 2.0).round(),
            key_w,
            Self::CHIP_HEIGHT,
        );
        c.fill_rounded(chip, Self::CHIP_RADIUS, t.ink_fill(0.06));
        c.stroke_rounded(chip.inset_by(0.25, 0.25), Self::CHIP_RADIUS, 0.5, t.ink_fill(0.10));
        c.draw_text_in(key, chip, Self::CHIP_FONT, t.label2_on_raised(), TextAlign::Center, 0.0, 0);
    }
}

/// What the drawn panels ask of the window about the pointer: the cursor shape at the pointer and the tooltip of the control
/// under it. The host brackets every input event with [`begin_event`](Self::begin_event) / [`end_event`](Self::end_event);
/// while a move or drag is routed, the panel under the pointer calls [`request`](Self::request) and
/// [`offer_tip`](Self::offer_tip) (the first offer wins: hosts route top-most first).
#[derive(Debug, Default)]
pub struct Hover {
    /// The shape the panel under the pointer asked for during the last mouse event (`None`: the host's own rules).
    pub cursor: Option<DrawCursor>,
    /// The tooltip state.
    pub tooltip: TooltipState,
    offer: Option<String>,
    collecting: bool,
}

impl Hover {
    /// A panel's shape at the pointer for this event.
    pub fn request(&mut self, c: Option<DrawCursor>) {
        if let Some(c) = c {
            self.cursor = Some(c);
        }
    }
    /// The tip of a possibly cut label: its full text when it is cut, nothing when it shows whole.
    pub fn offer_truncated(&mut self, label: &crate::middle_fit::TruncatedLabel) {
        self.offer_tip(label.tip());
    }
    /// Replaces the request outside a mouse event.
    pub fn replace(&mut self, c: Option<DrawCursor>) {
        self.cursor = c;
    }
    /// The tip of the control under the pointer (empty: none there). Only while a move is routed.
    pub fn offer_tip(&mut self, text: Option<&str>) {
        if let (true, None, Some(t)) = (self.collecting, &self.offer, text.filter(|t| !t.is_empty())) {
            self.offer = Some(t.to_string());
        }
    }
    /// Before the host routes `e`: mouse events start a fresh cursor request; a press, wheel or key hides the tip.
    pub fn begin_event(&mut self, e: &InputEvent) {
        match e {
            InputEvent::MouseMoved { .. } => {
                self.cursor = None;
                self.offer = None;
                self.collecting = true;
            }
            InputEvent::MouseDragged { .. } | InputEvent::MouseUp { .. } => self.cursor = None,
            InputEvent::MouseDown { .. } | InputEvent::Scroll { .. } => {
                self.cursor = None;
                self.tooltip.dismiss();
            }
            InputEvent::KeyDown { .. } => self.tooltip.dismiss(),
        }
    }
    /// After the host routed `e` (`now`: seconds of a steady clock).
    pub fn end_event(&mut self, e: &InputEvent, now: f64) {
        if let InputEvent::MouseMoved { x, y } = *e {
            self.collecting = false;
            self.tooltip.hover(self.offer.clone(), (x, y), now);
        }
    }
    /// The pointer left the window: no tip, no request.
    pub fn pointer_exited(&mut self, now: f64) {
        self.cursor = None;
        self.tooltip.hover(None, (0.0, 0.0), now);
    }
    /// A tip waits for its delay: the host keeps drawing frames until it shows.
    pub fn needs_frame(&self, now: f64) -> bool {
        self.tooltip.pending(now)
    }
    /// The tip once its delay passed, near the pointer and inside the canvas.
    pub fn draw_tooltip(&mut self, c: &mut Canvas, t: &DrawTheme, now: f64) {
        self.tooltip.draw(c, t, now);
    }
}

/// What drawn controls ask of the host window, read by the host once per frame: pointer lock while a value field scrubs and
/// the open text editor's caret (where the host puts the IME composition and candidate windows).
#[derive(Clone, Debug, Default)]
pub struct Requests {
    /// A scrub drag is running: hide the pointer, keep it in place and deliver virtual drag coordinates.
    pub pointer_lock: bool,
    /// The caret of the text editor drawn this frame, device px of the canvas list; `None`: no editor drawn.
    pub caret: Option<Rect>,
    /// The input method's composition (marked text) not yet committed.
    pub composition: String,
}

impl Requests {
    /// The composition inline at the caret drawn this frame: the uncommitted text on a field-colored box from the caret,
    /// underlined. The host calls it after every panel, before the menus.
    pub fn draw_composition(&self, c: &mut Canvas, t: &DrawTheme) {
        let Some(caret) = self.caret.filter(|_| !self.composition.is_empty()) else { return };
        let k = c.scale.max(0.01) as f64;
        let h = (caret.h as f64 / k).max(12.0);
        let size = (h * 0.72).max(theme::type_size::BODY as f64).min(96.0);
        let w = c.size_of(&self.composition, size, 0).width;
        let b = CGRect::new(caret.x as f64 / k, caret.y as f64 / k, w + 4.0, h);
        c.fill(b, t.overlay());
        c.draw_text_in(&self.composition, b.inset_by(2.0, 0.0), size, t.label(), TextAlign::Left, 0.0, 0);
        c.fill(CGRect::new(b.x + 2.0, b.max_y() - 2.0, w, 1.0), t.accent());
    }
}

/// The virtual pointer of a locked drag (hidden, pinned, raw deltas keep counting, so the drag is not bounded by the screen
/// edge). Panels see the virtual spot instead of the real one.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PointerLockTracker {
    locked: bool,
    virtual_x: f32,
    virtual_y: f32,
}

impl PointerLockTracker {
    /// The lock is on.
    pub fn is_locked(&self) -> bool {
        self.locked
    }
    /// A move with the button down. `locked`: [`Requests::pointer_lock`]. `dx`/`dy`: the event's raw travel in the same unit as
    /// `x`/`y`. Returns the position the panels see; the first locked move is the pin point itself.
    pub fn drag(&mut self, x: f32, y: f32, dx: f32, dy: f32, locked: bool) -> (f32, f32) {
        if !locked {
            self.locked = false;
            return (x, y);
        }
        if !self.locked {
            self.locked = true;
            self.virtual_x = x;
            self.virtual_y = y;
        } else {
            self.virtual_x += dx;
            self.virtual_y += dy;
        }
        (self.virtual_x, self.virtual_y)
    }
    /// The button went up: the release point panels see (the virtual one after a locked drag).
    pub fn release(&mut self, x: f32, y: f32) -> (f32, f32) {
        let out = if self.locked { (self.virtual_x, self.virtual_y) } else { (x, y) };
        self.locked = false;
        out
    }
}

/// Writes the system clipboard text.
pub type ClipboardWrite = Box<dyn Fn(&str)>;

/// Reads the system clipboard text.
pub type ClipboardRead = Box<dyn Fn() -> Option<String>>;

/// The system's text clipboard for the drawn text fields. The host sets `read_system` / `write_system`; until then a field
/// copies into this process only.
#[derive(Default)]
pub struct TextClipboard {
    /// Reads the system clipboard text.
    pub read_system: Option<ClipboardRead>,
    /// Writes the system clipboard text.
    pub write_system: Option<ClipboardWrite>,
    local: Option<String>,
}

impl TextClipboard {
    /// Copies `s`.
    pub fn write(&mut self, s: &str) {
        self.local = Some(s.to_string());
        if let Some(w) = &self.write_system {
            w(s);
        }
    }
    /// The system text with Windows line ends (CRLF) turned into the field's LF; the process's last copy when the system has none.
    pub fn read(&self) -> Option<String> {
        match self.read_system.as_ref().and_then(|r| r()) {
            Some(s) => Some(s.replace("\r\n", "\n").replace('\r', "\n")),
            None => self.local.clone(),
        }
    }
}

/// The chip that follows the pointer while something is dragged out of a panel: a small icon and the name.
#[derive(Clone, Debug, PartialEq)]
pub struct DragPreview {
    /// The name.
    pub title: String,
    /// The icon.
    pub icon: SQIcon,
    /// The pointer in window points.
    pub point: CGPoint,
}

impl DragPreview {
    const HEIGHT: f64 = 24.0;
    const MAX_WIDTH: f64 = 240.0;
    const ICON_SIZE: f64 = 14.0;

    /// The chip's frame for a pointer at `p` and a title `text_width` wide: down and right of the pointer.
    pub fn frame(p: CGPoint, text_width: f64) -> CGRect {
        let w = (text_width + Self::ICON_SIZE + 8.0 + 8.0 + 6.0).min(Self::MAX_WIDTH);
        CGRect::new(p.x + 12.0, p.y + 8.0, w, Self::HEIGHT)
    }

    /// Draws the chip.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme) {
        let fs = theme::type_size::BODY as f64;
        let r = Self::frame(self.point, c.size_of(&self.title, fs, 0).width);
        // Pickup: the chip fades in, no scale (a drag is frequent; the drag itself starts at once).
        c.open_motion(r, 20, false, |c| {
            c.fill_rounded(r, theme::radius::SMALL as f64, t.panel());
            c.stroke_rounded(r, theme::radius::SMALL as f64, 1.0, t.accent());
            c.draw_icon(
                self.icon,
                CGPoint { x: r.x + 8.0, y: r.mid_y() - Self::ICON_SIZE / 2.0 },
                Self::ICON_SIZE,
                t.label2(),
                None,
            );
            let text =
                CGRect::new(r.x + 8.0 + Self::ICON_SIZE + 6.0, r.y, r.width - (8.0 + Self::ICON_SIZE + 6.0), r.height);
            c.draw_text_in(&self.title, text, fs, t.label(), TextAlign::Left, 0.0, 0);
        });
    }
}

/// The one context the app lends to every panel call: the clock, the host hints published beside an event, and the requests
/// panels make of the window. Replaces the Swift singletons; tests build their own.
#[derive(Default)]
pub struct UiCx {
    /// Seconds of a steady clock, set by the host before each event and frame.
    pub now: f64,
    /// Cursor and tooltip.
    pub hover: Hover,
    /// Pointer lock, caret, composition.
    pub requests: Requests,
    /// The text the keyboard layout made of the key press being delivered (a field types this instead of the key).
    pub typed_text: Option<String>,
    /// The key press being delivered is an auto-repeat.
    pub key_repeat: bool,
    /// The gesture of the scroll event being delivered.
    pub gesture: Option<ScrollGesture>,
    /// The system delivers the momentum tail of a fling as scroll events (Mac).
    pub system_momentum: bool,
    /// The text clipboard.
    pub clipboard: TextClipboard,
    /// The drag chip, if a drag is running.
    pub drag_preview: Option<DragPreview>,
    /// A dropped chip settling onto where the items landed (`DropSettle`, the `Spring` ease), with the landing point.
    drop_chip: Option<(DragPreview, CGPoint, DropSettle)>,
    animation: bool,
}

impl UiCx {
    /// A context at time 0.
    pub fn new() -> UiCx {
        UiCx::default()
    }
    /// A drag moved: show the chip at `point`. An empty title shows nothing. A new drag ends a settling chip.
    pub fn show_drag(&mut self, title: &str, icon: SQIcon, point: CGPoint) {
        self.drop_chip = None;
        self.drag_preview = (!title.is_empty()).then(|| DragPreview { title: title.to_string(), icon, point });
    }
    /// The drag ended or was canceled.
    pub fn clear_drag(&mut self) {
        self.drag_preview = None;
    }
    /// The drag ended with a drop: the chip settles from the pointer onto `landing` (`Spring` ease, 180 ms); reduced
    /// motion and a drop right on the landing point just clear it.
    pub fn drop_drag(&mut self, landing: CGPoint) {
        let Some(chip) = self.drag_preview.take() else { return };
        let from = CGPoint { x: chip.point.x - landing.x, y: chip.point.y - landing.y };
        let settle = DropSettle::drop(from, self.now);
        if settle.is_running() {
            self.drop_chip = Some((chip, landing, settle));
            self.animation = true;
        }
    }
    /// A press lands a settling chip at once.
    pub fn press(&mut self) {
        self.drop_chip = None;
    }
    /// The settling chip as it is drawn now (its pointer point moved by the settle offset), `None` once landed.
    pub fn settling_chip(&mut self) -> Option<DragPreview> {
        let now = self.now;
        let (chip, landing, settle) = self.drop_chip.as_mut()?;
        let o = settle.offset(now);
        if !settle.is_running() {
            self.drop_chip = None;
            return None;
        }
        self.animation = true;
        Some(DragPreview { point: CGPoint { x: landing.x + o.x, y: landing.y + o.y }, ..chip.clone() })
    }
    /// Draws the chip that follows the pointer, or the one that settles after a drop.
    pub fn draw_drag(&mut self, c: &mut Canvas, t: &DrawTheme) {
        if let Some(chip) = self.drag_preview.clone().or_else(|| self.settling_chip()) {
            chip.draw(c, t);
        }
    }
    /// The gesture of the event being handled: what the host published, else a wheel from its pixels.
    pub fn gesture_or_wheel(&self, pixels_x: f32, pixels_y: f32) -> ScrollGesture {
        self.gesture.unwrap_or_else(|| ScrollGesture::wheel(pixels_x, pixels_y))
    }
    /// Runs `deliver` with the typed text set; it is cleared afterwards.
    pub fn with_typed_text<T>(&mut self, text: Option<&str>, deliver: impl FnOnce(&mut UiCx) -> T) -> T {
        self.typed_text = text.map(str::to_string);
        let out = deliver(self);
        self.typed_text = None;
        out
    }
    /// Runs `deliver` with the repeat flag set.
    pub fn with_key_repeat<T>(&mut self, repeating: bool, deliver: impl FnOnce(&mut UiCx) -> T) -> T {
        self.key_repeat = repeating;
        let out = deliver(self);
        self.key_repeat = false;
        out
    }
    /// Runs `deliver` with the scroll gesture published.
    pub fn with_gesture<T>(&mut self, g: ScrollGesture, deliver: impl FnOnce(&mut UiCx) -> T) -> T {
        self.gesture = Some(g);
        let out = deliver(self);
        self.gesture = None;
        out
    }
    /// Asks for another frame (an animation runs).
    pub fn request_animation(&mut self) {
        self.animation = true;
    }
    /// Whether an animation was requested since the last call; clears the request.
    pub fn take_animation(&mut self) -> bool {
        std::mem::take(&mut self.animation)
    }
    /// The host should draw another frame: an animation was asked for or a tooltip is due.
    pub fn needs_frame(&self) -> bool {
        self.animation || self.hover.needs_frame(self.now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::InputModifiers;

    fn mv(h: &mut Hover, tip: Option<&str>, x: f32, now: f64) {
        let e = InputEvent::MouseMoved { x, y: 50.0 };
        h.begin_event(&e);
        h.offer_tip(tip);
        h.end_event(&e, now);
    }

    // Swift HostHoverTests
    #[test]
    fn tip_shows_after_the_delay_and_hides_on_exit() {
        let mut h = Hover::default();
        mv(&mut h, Some("Snapping (S)"), 100.0, 10.0);
        assert!(!h.tooltip.is_visible(10.5));
        assert!(h.needs_frame(10.5));
        assert!(h.tooltip.is_visible(10.8));
        mv(&mut h, Some("Snapping (S)"), 104.0, 11.0);
        assert!(h.tooltip.is_visible(11.0) && h.tooltip.anchor.0 == 100.0, "moving inside the control keeps it");
        mv(&mut h, None, 100.0, 12.0);
        assert!(!h.tooltip.is_visible(20.0));
    }

    #[test]
    fn neighbor_shows_at_once_after_a_tip_closed_by_leaving() {
        let mut h = Hover::default();
        mv(&mut h, Some("A"), 100.0, 0.0);
        let mut c = Canvas::with_size(400.0, 300.0, None, 1.0);
        h.draw_tooltip(&mut c, &DrawTheme::default(), 1.0);
        mv(&mut h, Some("B"), 100.0, 1.2);
        assert!(h.tooltip.is_visible(1.2));
        mv(&mut h, None, 100.0, 2.0);
        mv(&mut h, Some("C"), 100.0, 3.0);
        assert!(!h.tooltip.is_visible(3.5), "1 s after: the full delay again");
    }

    #[test]
    fn press_hides_the_tip_until_another_control() {
        let mut h = Hover::default();
        mv(&mut h, Some("A"), 100.0, 0.0);
        h.begin_event(&InputEvent::MouseDown { x: 100.0, y: 50.0, modifiers: InputModifiers::NONE });
        assert!(!h.tooltip.is_visible(5.0));
        mv(&mut h, Some("A"), 100.0, 6.0);
        assert!(!h.tooltip.is_visible(9.0));
        mv(&mut h, Some("B"), 100.0, 10.0);
        assert!(h.tooltip.is_visible(10.8));
    }

    #[test]
    fn first_offer_wins_and_only_during_a_move() {
        let mut h = Hover::default();
        h.offer_tip(Some("outside a move"));
        let e = InputEvent::MouseMoved { x: 1.0, y: 1.0 };
        h.begin_event(&e);
        h.offer_tip(Some("top"));
        h.offer_tip(Some("below"));
        h.end_event(&e, 0.0);
        assert_eq!(h.tooltip.text.as_deref(), Some("top"));
    }

    #[test]
    fn cursor_request_lasts_until_the_next_mouse_event() {
        let mut h = Hover::default();
        h.begin_event(&InputEvent::MouseMoved { x: 0.0, y: 0.0 });
        h.request(Some(DrawCursor::Razor));
        h.request(None);
        assert_eq!(h.cursor, Some(DrawCursor::Razor));
        h.begin_event(&InputEvent::KeyDown { key: crate::input::InputKey::Space, modifiers: InputModifiers::NONE });
        assert_eq!(h.cursor, Some(DrawCursor::Razor));
        h.begin_event(&InputEvent::MouseMoved { x: 1.0, y: 0.0 });
        assert_eq!(h.cursor, None);
    }

    #[test]
    fn key_is_split_into_a_chip() {
        assert_eq!(TooltipLayout::split("Snapping (S)"), ("Snapping", Some("S")));
        assert_eq!(TooltipLayout::split("Lock Track"), ("Lock Track", None));
    }

    #[test]
    fn frame_stays_inside_the_window() {
        let (b, s) = (CGSize { width: 300.0, height: 200.0 }, CGSize { width: 80.0, height: 30.0 });
        let f = TooltipLayout::frame(s, CGPoint { x: 290.0, y: 190.0 }, b);
        assert!(f.max_x() <= 296.0 && f.max_y() <= 196.0 && f.x >= 4.0 && f.y >= 4.0);
        let g = TooltipLayout::frame(s, CGPoint { x: 20.0, y: 20.0 }, b);
        assert_eq!((g.x, g.y), (30.0, 38.0));
    }

    #[test]
    fn drawn_tip_uses_the_tooltip_token() {
        let mut h = Hover::default();
        mv(&mut h, Some("Lock Track"), 100.0, 0.0);
        // The tip fades in: the first frame after its delay is transparent, a later one is the full token.
        crate::motion::begin_frame(1.0);
        let mut c = Canvas::with_size(400.0, 300.0, None, 2.0);
        h.draw_tooltip(&mut c, &DrawTheme::default(), 1.0);
        assert_eq!(c.list.quads().first().map(|q| q.color.a), Some(0.0));
        crate::motion::begin_frame(1.5);
        let mut c = Canvas::with_size(400.0, 300.0, None, 2.0);
        h.draw_tooltip(&mut c, &DrawTheme::default(), 1.5);
        assert_eq!(c.list.quads().first().map(|q| q.color), Some(DrawTheme::default().token(sq_uikit::redesign_tokens::color::TOOLTIP)));
        assert!(!crate::motion::needs_frame());
    }

    #[test]
    fn overlay_cursor_angles_step_by_fifteen_degrees() {
        assert_eq!(DrawCursor::resize(0.0), DrawCursor::OverlayResize(0));
        assert_eq!(DrawCursor::resize(180.0), DrawCursor::OverlayResize(0));
        assert_eq!(DrawCursor::resize(52.0), DrawCursor::OverlayResize(45));
        assert_eq!(DrawCursor::resize(-45.0), DrawCursor::OverlayResize(135));
        assert_eq!(DrawCursor::resize(173.0), DrawCursor::OverlayResize(0));
        assert_eq!(DrawCursor::rotate(45.0), DrawCursor::OverlayRotate(45));
        assert_eq!(DrawCursor::rotate(-45.0), DrawCursor::OverlayRotate(315));
        assert_eq!(DrawCursor::rotate(353.0), DrawCursor::OverlayRotate(0));
        assert!(DrawCursor::Razor.is_tool_glyph() && !DrawCursor::Arrow.is_tool_glyph());
    }

    // Swift PointerLockTrackerTests
    #[test]
    fn locked_drag_counts_raw_deltas_past_the_screen_edge() {
        let mut t = PointerLockTracker::default();
        assert_eq!(t.drag(100.0, 50.0, 3.0, 0.0, false), (100.0, 50.0));
        assert_eq!(t.drag(104.0, 50.0, 4.0, 0.0, true), (104.0, 50.0));
        assert_eq!(t.drag(104.0, 50.0, 10.0, -2.0, true), (114.0, 48.0));
        assert_eq!(t.drag(104.0, 50.0, 2000.0, 0.0, true).0, 2114.0);
        assert_eq!(t.release(104.0, 50.0), (2114.0, 48.0));
        assert!(!t.is_locked());
    }

    #[test]
    fn unlocked_drag_and_release_use_the_real_position() {
        let mut t = PointerLockTracker::default();
        assert_eq!(t.drag(5.0, 6.0, 1.0, 1.0, false), (5.0, 6.0));
        assert_eq!(t.release(7.0, 8.0), (7.0, 8.0));
    }

    #[test]
    fn clipboard_normalizes_line_ends_and_falls_back_to_the_last_copy() {
        let mut c = TextClipboard::default();
        assert_eq!(c.read(), None);
        c.write("copied");
        assert_eq!(c.read().as_deref(), Some("copied"));
        c.read_system = Some(Box::new(|| Some("a\r\nb\rc".to_string())));
        assert_eq!(c.read().as_deref(), Some("a\nb\nc"));
    }

    #[test]
    fn scoped_hints_are_cleared_after_delivery() {
        let mut cx = UiCx::new();
        assert_eq!(cx.with_typed_text(Some("ä"), |cx| cx.typed_text.clone()).as_deref(), Some("ä"));
        assert!(cx.typed_text.is_none());
        assert!(cx.with_key_repeat(true, |cx| cx.key_repeat) && !cx.key_repeat);
        let pad = ScrollGesture { delta_y: 3.0, precise: true, ..Default::default() };
        assert_eq!(cx.with_gesture(pad, |cx| cx.gesture_or_wheel(0.0, 40.0)), pad);
        assert!(cx.gesture.is_none());
        assert_eq!(cx.gesture_or_wheel(0.0, 40.0), ScrollGesture { delta_y: 1.0, ..Default::default() });
        cx.request_animation();
        assert!(cx.needs_frame() && cx.take_animation() && !cx.take_animation());
    }

    #[test]
    fn drag_chip_follows_the_pointer_and_empty_titles_show_nothing() {
        let mut cx = UiCx::new();
        cx.show_drag("Clip", SQIcon::ChevronRight, CGPoint { x: 10.0, y: 10.0 });
        assert!(cx.drag_preview.is_some());
        cx.show_drag("", SQIcon::ChevronRight, CGPoint { x: 10.0, y: 10.0 });
        assert!(cx.drag_preview.is_none());
        let f = DragPreview::frame(CGPoint { x: 10.0, y: 10.0 }, 1000.0);
        assert_eq!((f.x, f.y, f.width, f.height), (22.0, 18.0, 240.0, 24.0));
    }

    #[test]
    fn a_dropped_chip_settles_onto_the_landing_point_and_a_press_or_reduced_motion_ends_it() {
        crate::motion::set_reduce_motion(false);
        let mut cx = UiCx::new();
        let landing = CGPoint { x: 100.0, y: 40.0 };
        cx.show_drag("Clip", SQIcon::ChevronRight, CGPoint { x: 160.0, y: 40.0 });
        cx.drop_drag(landing);
        assert!(cx.drag_preview.is_none());
        assert_eq!(cx.settling_chip().expect("settling").point.x, 160.0, "starts at the pointer");
        cx.now = 0.09;
        let mid = cx.settling_chip().expect("still settling").point.x;
        assert!(mid < 160.0 && mid > 100.0, "on its way: {mid}");
        cx.now = 0.3;
        assert!(cx.settling_chip().is_none(), "landed");
        cx.now = 0.0;
        cx.show_drag("Clip", SQIcon::ChevronRight, CGPoint { x: 160.0, y: 40.0 });
        cx.drop_drag(landing);
        cx.press();
        assert!(cx.settling_chip().is_none(), "a press lands it at once");
        crate::motion::set_reduce_motion(true);
        cx.show_drag("Clip", SQIcon::ChevronRight, CGPoint { x: 160.0, y: 40.0 });
        cx.drop_drag(landing);
        crate::motion::set_reduce_motion(false);
        assert!(cx.settling_chip().is_none(), "reduced motion: instant");
    }

    #[test]
    fn composition_is_drawn_only_with_a_caret() {
        let mut c = Canvas::with_size(200.0, 100.0, None, 1.0);
        let mut r = Requests { composition: "ka".into(), ..Default::default() };
        r.draw_composition(&mut c, &DrawTheme::default());
        assert!(c.list.quads().is_empty());
        r.caret = Some(Rect::new(10.0, 10.0, 1.0, 16.0));
        r.draw_composition(&mut c, &DrawTheme::default());
        assert_eq!(c.list.quads().len(), 1, "the box; no atlas means no text width, so no underline");
    }

    #[test]
    fn overlay_angles_snap_to_the_step_and_wrap() {
        // Swift `resizeAngleMapsToAxisOrDiagonal` / `rotateAngleMapsToItsCorner`, on the 15 degree overlay steps.
        assert_eq!(DrawCursor::resize(0.0), DrawCursor::OverlayResize(0));
        assert_eq!(DrawCursor::resize(180.0), DrawCursor::OverlayResize(0));
        assert_eq!(DrawCursor::resize(225.0), DrawCursor::OverlayResize(45));
        assert_eq!(DrawCursor::resize(90.0), DrawCursor::OverlayResize(90));
        assert_eq!(DrawCursor::resize(-45.0), DrawCursor::OverlayResize(135));
        assert_eq!(DrawCursor::resize(135.0), DrawCursor::OverlayResize(135));
        assert_eq!(DrawCursor::rotate(45.0), DrawCursor::OverlayRotate(45));
        assert_eq!(DrawCursor::rotate(-45.0), DrawCursor::OverlayRotate(315));
        assert_eq!(DrawCursor::rotate(225.0), DrawCursor::OverlayRotate(225));
    }
}

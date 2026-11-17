// Swift: ShellFloating.swift
//! Floating panels of the shared app (the Mac `AppController+FloatingPanels`, `FloatingPanelState` and `FloatingPanelWindow`
//! translated): a dock panel popped out into a window of its own. The layout tree is not touched, a floating panel only
//! counts as hidden in the copy the dock lays out, so docking it back restores its exact slot. State is per workspace and
//! persisted next to `workspaces.json` (`floating-panels.json`, the same file the Mac app writes).
//!
//! The panels draw into one shared canvas. A floating panel gets a rectangle on that canvas to the right of the main window
//! (`FloatingWindow::rect`, points); the host opens an OS window per `windows` entry, shows the region of the frame at the
//! rectangle and sends the window's mouse events moved by the rectangle's origin. Everything else (title bar, Dock and
//! Close buttons, the panel hosts) is the one set of code the main window runs.
//!
//! Mapping: `ShellFloating` held a weak back reference to its dock. Here it is plain state and geometry; the steps that also
//! change the dock (`float`, `dock_back`, `close`, `set_frame`, `toggle_zoom`, `tear_off`, `press`, `load`) are methods of
//! [`ShellDock`], which owns the floating state. Hooks became [`DockEvent`]s; `screens` and `mainScreenFrame` closures
//! became plain fields the host keeps current.

use crate::shell_dock::{DockEvent, ShellDock};
use sq_draw::theme::spacing;
use sq_draw::{Canvas, DrawTheme, TextAlign};
use sq_editor_session::{FloatingPanelFrame, FloatingPanelState};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqicon::SQIcon;
use std::collections::HashMap;
use std::time::Instant;

/// One floating window.
#[derive(Clone, Debug, PartialEq)]
pub struct FloatingWindow {
    /// The panel it shows.
    pub panel: PanelID,
    /// Its title row text.
    pub title: String,
    /// The OS window (screen points, y up, title row included).
    pub frame: CGRect,
    /// Where it sits on the shared canvas (points, y down, title row included).
    pub rect: CGRect,
}

/// What lies under a canvas point.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FloatingHit {
    /// The title row.
    Title(PanelID),
    /// The Dock button.
    Dock(PanelID),
    /// The Close button.
    Close(PanelID),
    /// The resize grip.
    Grip(PanelID),
    /// The panel content.
    Content(PanelID),
}

impl FloatingHit {
    /// The panel of the hit.
    pub fn panel(self) -> PanelID {
        match self {
            FloatingHit::Title(p)
            | FloatingHit::Dock(p)
            | FloatingHit::Close(p)
            | FloatingHit::Grip(p)
            | FloatingHit::Content(p) => p,
        }
    }
}

/// The floating windows of the workspace on screen.
pub struct ShellFloating {
    pub(crate) state: FloatingPanelState,
    windows: Vec<FloatingWindow>,
    revision: u64,
    /// Frames from before Maximize Panel (the Mac `unzoomedFrame`): a second call puts the window back.
    pub(crate) unzoomed: HashMap<PanelID, CGRect>,
    pub(crate) key: String,
    dirty_at: Option<f64>,
    /// Panels whose window the host brings forward (`floating.raise`), read by [`ShellFloating::take_raised`].
    raised: Vec<PanelID>,
    /// Visible frames of the displays (screen points, y up, the main display first).
    pub screens: Vec<CGRect>,
    /// The main window's frame (screen points, y up), `None` when the host does not know it.
    pub main_screen_frame: Option<CGRect>,
    /// Seconds on a steady clock (the debounce of the save).
    pub clock: Box<dyn Fn() -> f64>,
}

impl Default for ShellFloating {
    fn default() -> Self {
        ShellFloating::new(FloatingPanelState::default())
    }
}

impl ShellFloating {
    /// Height of the title row the shell draws (`SQFloatingPanel.titleBarHeight`).
    pub const TITLE_BAR: f64 = 28.0;
    const GAP: f64 = 24.0;
    const BUTTON: f64 = 24.0;
    /// The invisible resize handle in the bottom-right corner (a borderless window has no system resize edges).
    pub const GRIP: f64 = 16.0;
    /// A tab released this far outside the window pops out (the Mac rule).
    pub(crate) const TEAR_OFF_MARGIN: f64 = 16.0;
    /// A release this close to (or on) the window's outer edge pops out as well: a maximized window reaches the screen
    /// edge, the pointer cannot go further, so the margin outside the window is out of reach (Windows VM, 2026-11-13).
    pub(crate) const TEAR_OFF_RIM: f64 = 3.0;
    const SAVE_DELAY: f64 = 0.5;

    /// A floating set with `state`.
    pub fn new(state: FloatingPanelState) -> ShellFloating {
        let start = Instant::now();
        ShellFloating {
            state,
            windows: Vec::new(),
            revision: 0,
            unzoomed: HashMap::new(),
            key: String::new(),
            dirty_at: None,
            raised: Vec::new(),
            screens: Vec::new(),
            main_screen_frame: None,
            clock: Box::new(move || start.elapsed().as_secs_f64()),
        }
    }

    // Program and Source share one monitor card (one picture), as in Swift `ShellFloating`: only one of them shows its
    // picture at a time: the floating one wins (`ShellDock::monitor_card`), the other docked group shows a placeholder.
    /// Whether `p` can be popped out.
    pub fn can_float(p: PanelID) -> bool {
        PanelID::dockable().contains(&p)
    }

    // MARK: Mixed DPI

    /// The scale the one frame is drawn at: the largest of the main window and the floating windows. A window on a display
    /// with a smaller scale shows the frame reduced (crisp); none shows it enlarged. One scale = no second frame pass, the
    /// panels keep one set of pixel positions.
    pub fn draw_scale(main: f32, floating: &[f32]) -> f32 {
        floating
            .iter()
            .copied()
            .fold(None, |m: Option<f32>, v| Some(m.map_or(v, |m| m.max(v))))
            .unwrap_or(main)
            .max(main)
    }

    /// Window scale over draw scale (1 when they agree or the draw scale is unknown).
    pub fn ratio(window: f32, draw: f32) -> f32 {
        if draw > 0.0 { window / draw } else { 1.0 }
    }

    /// Size in the frame's pixels of a window extent given in the window's own pixels.
    pub fn draw_size(own: i64, window: f32, draw: f32) -> i64 {
        let r = Self::ratio(window, draw);
        if r > 0.0 { (own as f32 / r).round() as i64 } else { own }
    }

    /// A coordinate in the window's own pixels, in the frame's pixels.
    pub fn drawn(own: f32, window: f32, draw: f32) -> f32 {
        let r = Self::ratio(window, draw);
        if r > 0.0 { own / r } else { own }
    }

    // MARK: State

    /// The persisted state.
    pub fn state(&self) -> &FloatingPanelState {
        &self.state
    }

    /// The floating windows of the workspace on screen, in panel order.
    pub fn windows(&self) -> &[FloatingWindow] {
        &self.windows
    }

    /// Counts every change of the window set or of a frame the shell chose (the host opens, closes and moves OS windows).
    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub(crate) fn bump_revision(&mut self) {
        self.revision += 1;
    }

    /// The panels that float now.
    pub fn panels(&self) -> std::collections::HashSet<PanelID> {
        self.windows.iter().map(|w| w.panel).collect()
    }

    /// Whether `p` floats.
    pub fn is_floating(&self, p: PanelID) -> bool {
        self.windows.iter().any(|w| w.panel == p)
    }

    /// The window of `p`.
    pub fn window_of(&self, p: PanelID) -> Option<&FloatingWindow> {
        self.windows.iter().find(|w| w.panel == p)
    }

    /// Whether `p` is maximized in its window.
    pub fn is_zoomed(&self, p: PanelID) -> bool {
        self.unzoomed.contains_key(&p)
    }

    /// Canvas size the floating rectangles need, points (zero without windows).
    pub fn canvas_extent(&self) -> CGSize {
        CGSize::new(
            self.windows.iter().map(|w| w.rect.max_x()).fold(0.0, f64::max),
            self.windows.iter().map(|w| w.rect.max_y()).fold(0.0, f64::max),
        )
    }

    /// The dock's layout pass: picks the workspace's windows and places their rectangles right of `main_width` (points).
    pub(crate) fn refresh(&mut self, key: &str, main_width: f64) {
        self.key = key.to_string();
        let clamp = self.screens.clone();
        let mut next: Vec<FloatingWindow> = Vec::new();
        let mut x = main_width + Self::GAP;
        for p in sq_uikit::panel_id::PanelID::ALL {
            if !Self::can_float(p) {
                continue;
            }
            let Some(mut f) = self.state.frame(p, key).map(|f| f.rect()) else { continue };
            let m = p.min_size();
            f.width = f.width.max(m.0);
            f.height = f.height.max(m.1 + Self::TITLE_BAR);
            if !clamp.is_empty() && self.window_of(p).is_none() {
                f = FloatingPanelState::clamp(f, &clamp, Self::TITLE_BAR);
            }
            let rect = CGRect::new(x, 0.0, f.width, f.height);
            x += f.width + Self::GAP;
            next.push(FloatingWindow { panel: p, title: EditorCommand::localized_panel_title(p), frame: f, rect });
        }
        let changed = next.iter().map(|w| w.panel).ne(self.windows.iter().map(|w| w.panel));
        if changed {
            self.revision += 1;
        }
        self.unzoomed.retain(|k, _| next.iter().any(|w| w.panel == *k));
        self.windows = next;
    }

    /// Records a frame the user gave the OS window; false when nothing changed.
    pub(crate) fn store_frame(&mut self, f: CGRect, p: PanelID) -> Option<bool> {
        let i = self.windows.iter().position(|w| w.panel == p)?;
        if self.windows[i].frame == f {
            return None;
        }
        let resized = self.windows[i].frame.width != f.width || self.windows[i].frame.height != f.height;
        self.state.set_frame(FloatingPanelFrame::from_rect(f), p, &self.key);
        self.windows[i].frame = f;
        self.mark_dirty();
        Some(resized)
    }

    /// The panels whose OS window the host brings to the front (Swift `floating.raise`: Maximize Panel on a floating panel).
    pub fn take_raised(&mut self) -> Vec<PanelID> {
        std::mem::take(&mut self.raised)
    }

    /// Asks the host to bring the window of `p` forward (read by [`ShellFloating::take_raised`]).
    pub fn raise(&mut self, p: PanelID) {
        if !self.raised.contains(&p) {
            self.raised.push(p);
        }
    }

    /// Replaces the stored frames with a copy another dock changed (the root's dock and the shell's own dock share one
    /// floating state) and queues the save.
    pub fn adopt_state(&mut self, s: FloatingPanelState) {
        self.state = s;
        self.mark_dirty();
    }

    // MARK: Persistence

    pub(crate) fn mark_dirty(&mut self) {
        self.dirty_at = Some((self.clock)());
    }

    /// The state to write once it has been quiet for half a second (a drag moves the window many times); `force` at quit.
    pub fn flush(&mut self, force: bool) -> Option<FloatingPanelState> {
        let at = self.dirty_at?;
        if !force && (self.clock)() - at < Self::SAVE_DELAY {
            return None;
        }
        self.dirty_at = None;
        Some(self.state.clone())
    }

    // MARK: Geometry and events

    fn title_rect(w: &FloatingWindow) -> CGRect {
        CGRect::new(w.rect.min_x(), w.rect.min_y(), w.rect.width, Self::TITLE_BAR)
    }

    /// The width the title row's Dock and Close buttons take at its right end (with the edge gap and a gap before them).
    pub fn buttons_width() -> f64 {
        6.0 + 2.0 * Self::BUTTON + spacing::SM as f64
    }

    fn close_rect(w: &FloatingWindow) -> CGRect {
        let s = Self::BUTTON;
        CGRect::new(w.rect.max_x() - 6.0 - s, w.rect.min_y() + (Self::TITLE_BAR - s) / 2.0, s, s)
    }

    fn dock_rect(w: &FloatingWindow) -> CGRect {
        let c = Self::close_rect(w);
        CGRect::new(c.x - Self::BUTTON, c.y, c.width, c.height)
    }

    fn grip_rect(w: &FloatingWindow) -> CGRect {
        CGRect::new(w.rect.max_x() - Self::GRIP, w.rect.max_y() - Self::GRIP, Self::GRIP, Self::GRIP)
    }

    /// What lies under a canvas point (points), `None` outside every floating rectangle.
    pub fn hit(&self, p: CGPoint) -> Option<FloatingHit> {
        let w = self.windows.iter().find(|w| w.rect.contains(p))?;
        if Self::close_rect(w).contains(p) {
            return Some(FloatingHit::Close(w.panel));
        }
        if Self::dock_rect(w).contains(p) {
            return Some(FloatingHit::Dock(w.panel));
        }
        if Self::grip_rect(w).contains(p) {
            return Some(FloatingHit::Grip(w.panel));
        }
        if Self::title_rect(w).contains(p) {
            return Some(FloatingHit::Title(w.panel));
        }
        Some(FloatingHit::Content(w.panel))
    }

    /// The title row of one window: the Mac `FloatingPanelTitleBar`.
    pub(crate) fn draw_title(&self, c: &mut Canvas, w: &FloatingWindow, t: &DrawTheme, focused: bool) {
        let bar = Self::title_rect(w);
        c.fill(bar, t.titlebar());
        c.fill(CGRect::new(bar.min_x(), bar.max_y() - 1.0, bar.width, 1.0), t.divider());
        let pad = spacing::MD as f64;
        let text = CGRect::new(
            bar.min_x() + pad,
            bar.min_y(),
            (Self::dock_rect(w).min_x() - bar.min_x() - pad - spacing::SM as f64).max(0.0),
            bar.height,
        );
        let semibold = c.semibold();
        c.draw_text_in(
            &w.title,
            text,
            11.0,
            if focused { t.label() } else { t.label2() },
            TextAlign::Left,
            0.0,
            semibold,
        );
        for (r, icon) in [(Self::dock_rect(w), SQIcon::Minimize), (Self::close_rect(w), SQIcon::Close)] {
            let s = 14.0;
            c.draw_icon(icon, CGPoint::new(r.mid_x() - s / 2.0, r.mid_y() - s / 2.0), s, t.label2(), None);
        }
    }
}

fn overlap(a: &CGRect, b: &CGRect) -> f64 {
    let (x0, x1) = (a.min_x().max(b.min_x()), a.max_x().min(b.max_x()));
    let (y0, y1) = (a.min_y().max(b.min_y()), a.max_y().min(b.max_y()));
    if x1 <= x0 || y1 <= y0 { 0.0 } else { (x1 - x0) * (y1 - y0) }
}

impl ShellDock {
    /// The host replaces the saved floating state (at launch, after a workspace load).
    pub fn load_floating(&mut self, s: FloatingPanelState) {
        self.floating.state = s;
        self.relayout();
        self.events.push(DockEvent::Changed);
    }

    /// Pops `p` out. Without a drop point the window opens at the dock size, offset from the dock position (the Mac
    /// `floatPanel`); with one (a tab dragged out of the window, screen points) its title row sits under the pointer.
    pub fn float(&mut self, p: PanelID, at: Option<CGPoint>) -> bool {
        if !ShellFloating::can_float(p) || self.floating.is_floating(p) {
            return false;
        }
        let bar = ShellFloating::TITLE_BAR;
        let mut frame;
        if let Some(drop) = at {
            frame = FloatingPanelState::tear_off_frame(p, drop, bar).rect();
        } else {
            let mut current = CGRect::new(0.0, 0.0, 520.0, 360.0);
            if let (Some(c), Some(main)) = (self.content_frame(p), self.floating.main_screen_frame) {
                current = CGRect::new(main.min_x() + c.min_x(), main.max_y() - c.max_y(), c.width, c.height);
            }
            frame = FloatingPanelState::default_frame(p, current, 40.0).rect();
            frame.height += bar;
            frame.y -= bar;
        }
        frame = FloatingPanelState::clamp(frame, &self.floating.screens, bar);
        let key = self.floating.key.clone();
        self.floating.state.float(p, &key, FloatingPanelFrame::from_rect(frame));
        if self.maximized() == Some(p) {
            self.toggle_maximize(p);
        }
        self.floating.mark_dirty();
        self.set_focused(Some(p));
        self.floating_changed();
        true
    }

    /// Back into the layout, at the position it left.
    pub fn dock_back(&mut self, p: PanelID) {
        if !self.floating.is_floating(p) {
            return;
        }
        self.floating.unzoomed.remove(&p);
        let key = self.floating.key.clone();
        self.floating.state.dock(p, &key);
        self.floating.mark_dirty();
        self.set_focused(Some(p));
        self.floating_changed();
    }

    /// Every floating panel goes back into the layout (Reset to Saved Layout; a host that cannot show OS windows).
    /// Without this a panel restored as floating but without a window is hidden from the layout and nothing shows it.
    pub fn dock_all_floating(&mut self) {
        for p in self.floating.panels() {
            self.dock_back(p);
        }
    }

    /// Pulls every floating window whose title row lies outside `floating.screens` back onto a screen (a stored frame
    /// from another display layout would leave the panel out of reach).
    pub fn fit_floating_to_screens(&mut self) {
        if self.floating.screens.is_empty() {
            return;
        }
        for w in self.floating.windows().to_vec() {
            let f = FloatingPanelState::clamp(w.frame, &self.floating.screens, ShellFloating::TITLE_BAR);
            if f != w.frame {
                self.set_floating_frame(f, w.panel);
            }
        }
    }

    /// Close Panel of a floating panel: not floating any more and hidden in the layout, like a docked one.
    pub fn close_floating(&mut self, p: PanelID) {
        if !self.floating.is_floating(p) {
            return;
        }
        self.floating.unzoomed.remove(&p);
        let key = self.floating.key.clone();
        self.floating.state.dock(p, &key);
        self.floating.mark_dirty();
        self.close(p);
    }

    /// The user moved or resized the OS window (screen points, y up).
    pub fn set_floating_frame(&mut self, f: CGRect, p: PanelID) {
        if self.floating.store_frame(f, p) == Some(true) {
            self.relayout();
            self.events.push(DockEvent::Changed);
        }
    }

    /// Maximize Panel on a floating panel (the Mac `toggleFloatingZoom`): the window fills the visible area of the display it
    /// is mostly on; a second call restores the frame from before. The host follows through `revision`.
    pub(crate) fn toggle_floating_zoom(&mut self, p: PanelID) {
        let Some(w) = self.floating.window_of(p).cloned() else { return };
        let target;
        if let Some(back) = self.floating.unzoomed.remove(&p) {
            target = back;
        } else {
            let mut best: Option<CGRect> = None;
            for s in &self.floating.screens {
                // `max(by:)` keeps the last of equal overlaps? Swift returns the last maximum only on strict `<`; this keeps the first.
                if best.is_none_or(|b| overlap(&b, &w.frame) < overlap(s, &w.frame)) {
                    best = Some(*s);
                }
            }
            let Some(visible) = best else { return };
            self.floating.unzoomed.insert(p, w.frame);
            target = visible;
        }
        self.set_floating_frame(target, p);
        self.floating.bump_revision();
        self.set_focused(Some(p));
        self.floating.raised.push(p);
        self.events.push(DockEvent::Raise(p));
        self.events.push(DockEvent::Changed);
    }

    /// A tab dragged out of the window floats (the pointer is `window_point`, window points, `window` the window size).
    pub(crate) fn tear_off(&mut self, p: PanelID, window_point: CGPoint, window: CGSize) -> bool {
        if !ShellFloating::can_float(p) || self.floating.is_floating(p) {
            return false;
        }
        let Some(main) = self.floating.main_screen_frame else { return false };
        let m = ShellFloating::TEAR_OFF_MARGIN;
        let r = ShellFloating::TEAR_OFF_RIM;
        let bounds = CGRect::new(0.0, 0.0, window.width, window.height);
        // Beyond the margin, or on the rim: anywhere between stays a dock drop.
        if bounds.inset_by(-m, -m).contains(window_point) && bounds.inset_by(r, r).contains(window_point) {
            return false;
        }
        self.float(p, Some(CGPoint::new(main.min_x() + window_point.x, main.max_y() - window_point.y)))
    }

    fn floating_changed(&mut self) {
        self.floating.bump_revision();
        self.relayout();
        self.events.push(DockEvent::Changed);
    }

    /// The press on a title row button; true when the press belonged to the title row (the OS drags the window by it).
    pub(crate) fn floating_press(&mut self, at: CGPoint) -> bool {
        match self.floating.hit(at) {
            Some(FloatingHit::Dock(panel)) => {
                self.dock_back(panel);
                true
            }
            Some(FloatingHit::Close(panel)) => {
                self.close_floating(panel);
                true
            }
            Some(FloatingHit::Title(_)) => true,
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draw_scale_is_the_largest_scale() {
        assert_eq!(ShellFloating::draw_scale(1.0, &[2.0, 1.5]), 2.0);
        assert_eq!(ShellFloating::draw_scale(2.0, &[1.0]), 2.0);
        assert_eq!(ShellFloating::draw_scale(1.0, &[]), 1.0);
    }

    #[test]
    fn mixed_dpi_helpers_follow_the_ratio() {
        assert_eq!(ShellFloating::ratio(1.0, 2.0), 0.5);
        assert_eq!(ShellFloating::ratio(1.0, 0.0), 1.0);
        assert_eq!(ShellFloating::draw_size(500, 1.0, 2.0), 1000);
        assert_eq!(ShellFloating::drawn(10.0, 1.0, 2.0), 20.0);
    }

    fn dock() -> ShellDock {
        let mut d = ShellDock::default();
        d.set_frame(CGRect::new(0.0, 44.0, 1600.0, 900.0));
        d.relayout();
        d
    }

    #[test]
    fn reset_to_saved_layout_docks_every_floating_panel_again() {
        let mut d = dock();
        assert!(d.float(PanelID::Effects, None));
        assert!(d.float(PanelID::Project, None));
        d.reset_layout();
        assert!(d.floating.panels().is_empty(), "no panel stays floating");
        let shown: Vec<PanelID> = d.groups().iter().filter(|g| !g.is_floating).flat_map(|g| g.panels.clone()).collect();
        assert!(shown.contains(&PanelID::Effects) && shown.contains(&PanelID::Project), "{shown:?}");
    }

    #[test]
    fn showing_a_floating_panel_raises_its_window_and_keeps_it_open() {
        let mut d = dock();
        assert!(d.float(PanelID::Effects, None));
        d.floating.take_raised();
        d.show(PanelID::Effects);
        assert!(d.floating.is_floating(PanelID::Effects));
        assert_eq!(d.floating.take_raised(), vec![PanelID::Effects]);
    }

    #[test]
    fn a_window_stored_off_every_screen_is_pulled_back_on() {
        let mut d = dock();
        assert!(d.float(PanelID::Effects, None));
        let off = CGRect::new(9000.0, 9000.0, 400.0, 300.0);
        d.floating.store_frame(off, PanelID::Effects);
        d.floating.screens = vec![CGRect::new(0.0, 0.0, 1920.0, 1080.0)];
        d.fit_floating_to_screens();
        let f = d.floating.window_of(PanelID::Effects).expect("still floating").frame;
        assert!(f.min_x() < 1920.0 && f.min_y() < 1080.0, "{f:?}");
    }

    #[test]
    fn a_host_without_windows_docks_all_floating_panels() {
        let mut d = dock();
        assert!(d.float(PanelID::Effects, None));
        d.dock_all_floating();
        assert!(!d.floating.is_floating(PanelID::Effects));
        assert!(d.groups().iter().any(|g| !g.is_floating && g.panels.contains(&PanelID::Effects)));
    }

    #[test]
    fn a_floated_panel_leaves_the_layout_and_docks_back_to_its_slot() {
        let mut d = dock();
        let before: Vec<PanelID> = d.groups().iter().map(|g| g.selected).collect();
        assert!(d.float(PanelID::Project, None));
        assert!(d.floating.is_floating(PanelID::Project));
        assert!(!d.visible_panels().is_empty());
        let floating: Vec<&crate::shell_dock::Group> = d.groups().iter().filter(|g| g.is_floating).collect();
        assert_eq!(floating.len(), 1);
        assert_eq!(floating[0].selected, PanelID::Project);
        // right of the main window, with the title row above the content
        assert!(floating[0].frame.min_x() > d.frame.max_x());
        // the panel's own tools (count, New Folder, "...") stop short of the Dock and Close buttons
        let w = d.floating.window_of(PanelID::Project).expect("window");
        assert!(floating[0].tools_strip().max_x() <= ShellFloating::dock_rect(w).min_x());
        assert_eq!(floating[0].content.min_y(), floating[0].frame.min_y() + ShellFloating::TITLE_BAR);
        assert!(!d.groups().iter().any(|g| !g.is_floating && g.selected == PanelID::Project));
        assert!(d.floating.flush(true).is_some());
        d.dock_back(PanelID::Project);
        assert!(!d.floating.is_floating(PanelID::Project));
        let after: Vec<PanelID> = d.groups().iter().map(|g| g.selected).collect();
        assert_eq!(before, after);
    }

    #[test]
    fn maximizing_a_floating_panel_asks_the_host_to_raise_its_window_once() {
        let mut d = dock();
        d.float(PanelID::Library, None);
        d.floating.screens = vec![CGRect::new(0.0, 0.0, 1600.0, 900.0)];
        assert!(d.floating.take_raised().is_empty());
        d.toggle_floating_zoom(PanelID::Library);
        assert_eq!(d.floating.take_raised(), vec![PanelID::Library]);
        assert!(d.floating.take_raised().is_empty());
    }

    #[test]
    fn the_window_row_of_a_floating_panel_closes_it_and_a_shortcut_keeps_it_floating() {
        // Swift `windowRowOfAFloatingPanelClosesItAndAShortcutKeepsItFloating`.
        let mut d = dock();
        d.float(PanelID::Library, None);
        d.show(PanelID::Library);
        assert!(d.floating.is_floating(PanelID::Library));
        d.toggle(PanelID::Library);
        assert!(!d.floating.is_floating(PanelID::Library) && !d.visible_panels().contains(&PanelID::Library));
    }

    #[test]
    fn transiently_hidden_steps_leave_the_layout_and_the_stored_workspace() {
        // Swift `transientlyHiddenStepsLeaveTheLayoutAndTheStoredWorkspace`.
        let mut d = dock();
        d.set_page(sq_editor_session::WorkspacePage::Color);
        d.show(PanelID::Steps);
        assert!(d.shows(PanelID::Steps));
        let stored = d.store().current();
        d.take_events();
        d.set_transiently_hidden([PanelID::Steps].into_iter().collect());
        assert!(!d.shows(PanelID::Steps) && !d.visible_panels().contains(&PanelID::Steps));
        assert!(d.store().current() == stored, "shown, not stored");
        assert!(!d.take_events().iter().any(|e| matches!(e, DockEvent::SaveWorkspaces)));
        d.toggle(PanelID::Steps);
        d.show(PanelID::Steps);
        assert!(!d.shows(PanelID::Steps), "the Window row and the shortcut leave it hidden");
        d.set_transiently_hidden(Default::default());
        assert!(d.shows(PanelID::Steps));
    }

    #[test]
    fn the_title_row_buttons_dock_and_close() {
        let mut d = dock();
        d.float(PanelID::Project, None);
        let w = d.floating.window_of(PanelID::Project).cloned().expect("window");
        let dock_btn = ShellFloating::dock_rect(&w);
        assert_eq!(
            d.floating.hit(CGPoint::new(dock_btn.mid_x(), dock_btn.mid_y())),
            Some(FloatingHit::Dock(PanelID::Project))
        );
        let content = CGPoint::new(w.rect.mid_x(), w.rect.max_y() - 40.0);
        assert_eq!(d.floating.hit(content), Some(FloatingHit::Content(PanelID::Project)));
        assert!(d.floating_press(CGPoint::new(dock_btn.mid_x(), dock_btn.mid_y())));
        assert!(!d.floating.is_floating(PanelID::Project));
        d.float(PanelID::Project, None);
        let w = d.floating.window_of(PanelID::Project).cloned().expect("window");
        let close = ShellFloating::close_rect(&w);
        assert!(d.floating_press(CGPoint::new(close.mid_x(), close.mid_y())));
        assert!(!d.floating.is_floating(PanelID::Project) && !d.visible_panels().contains(&PanelID::Project));
    }

    #[test]
    fn only_dockable_panels_float() {
        assert!(ShellFloating::can_float(PanelID::Timeline));
        assert!(!ShellFloating::can_float(PanelID::ColorClips));
    }
}

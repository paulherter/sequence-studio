//! The Library panel as an app host (the Swift `LibraryPanelHost` wiring of SQAppShell, `SharedUIController`).

use crate::library::library_draw_panel::{LibraryDrawPanel, LibraryPanelEvent, LibraryPicture};
use crate::library::library_panel_model::LibraryItem;
use sq_app_shell::{AppHost, HostCx};
use sq_draw::{Canvas, DrawTheme, InputEvent};
use sq_editor_session::EditorSession;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

/// The thumbnail of a file for a tile rect (the host's media atlas).
pub type PictureSource = Box<dyn Fn(&LibraryItem, CGRect) -> Option<LibraryPicture>>;

/// The Library panel in a dock slot. The panel's hooks are [`LibraryPanelEvent`]s ([`LibraryPanelHost::take_events`]);
/// the model's are `LibraryModelEvent`s (`panel.model.take_events()`): the app turns both into dialogs and timeline calls.
pub struct LibraryPanelHost {
    /// The panel.
    pub panel: LibraryDrawPanel,
    /// The file thumbnails; none = the kind icons.
    pub picture: Option<PictureSource>,
    frame: CGRect,
    scale: f32,
    /// The Import... button's frame in window points (in the tab strip above the panel); none = no strip.
    strip_import: Option<CGRect>,
}

impl LibraryPanelHost {
    /// A host around `panel`.
    pub fn new(panel: LibraryDrawPanel) -> LibraryPanelHost {
        LibraryPanelHost { panel, picture: None, frame: CGRect::default(), scale: 1.0, strip_import: None }
    }

    /// The panel's hooks that fired, in order.
    ///
    /// The panel reports panel-local points; the host turns menu and drag points into window points (the root hit-tests
    /// them against the dock panels, so a local point never reached the timeline).
    pub fn take_events(&mut self) -> Vec<LibraryPanelEvent> {
        let (dx, dy) = (self.frame.x, self.frame.y);
        let at = |p: CGPoint| CGPoint::new(p.x + dx, p.y + dy);
        let mut events = self.panel.take_events();
        for e in &mut events {
            match e {
                LibraryPanelEvent::Menu(_, p) | LibraryPanelEvent::Drag(_, _, p) => *p = at(*p),
                _ => {}
            }
        }
        events
    }

    /// The Import... button's frame in window points; the panel gets it in its own points.
    pub fn set_strip_import(&mut self, r: Option<CGRect>) {
        self.strip_import = r;
        let (dx, dy) = (self.frame.x, self.frame.y);
        self.panel.set_import_rect(r.map(|r| CGRect::new(r.x - dx, r.y - dy, r.width, r.height)));
    }

    fn local(&self, x: f32, y: f32) -> CGPoint {
        let k = f64::from(self.scale);
        CGPoint::new(f64::from(x) / k - self.frame.x, f64::from(y) / k - self.frame.y)
    }

    fn inside(&self, p: CGPoint) -> bool {
        CGRect::new(0.0, 0.0, self.frame.width, self.frame.height).contains(p)
    }
}

impl AppHost for LibraryPanelHost {
    fn sync(&mut self, _session: &EditorSession) {
        self.panel.model.pump();
        self.panel.refresh();
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        self.frame = frame;
        // Events are pixels: a display scale change must reach the hit tests before the next draw.
        self.scale = cx.scale;
        self.panel.size = CGSize::new(frame.width, frame.height);
        self.set_strip_import(self.strip_import);
        self.panel.sync_scroll_range();
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.scale = c.scale;
        c.save_gstate();
        c.translate_by(self.frame.x, self.frame.y);
        let source = self.picture.take();
        let none = |_: &LibraryItem, _: CGRect| None;
        match &source {
            Some(f) => self.panel.draw(c, t, cx.ui, f.as_ref()),
            None => self.panel.draw(c, t, cx.ui, &none),
        }
        self.picture = source;
        c.restore_gstate();
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        self.scale = cx.scale;
        let now = cx.ui.now;
        self.panel.now = now;
        let taken = match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = self.local(x, y);
                if !self.inside(p) && !self.panel.import_rect().is_some_and(|r| r.contains(p)) {
                    return false;
                }
                self.panel.mouse_down(p, modifiers, now);
                true
            }
            InputEvent::MouseDragged { x, y, .. } => {
                let p = self.local(x, y);
                let was = self.panel.is_pressed();
                self.panel.mouse_dragged(p);
                was
            }
            InputEvent::MouseUp { x, y } => {
                let p = self.local(x, y);
                let was = self.panel.is_pressed();
                self.panel.mouse_up(p);
                was
            }
            InputEvent::MouseMoved { x, y } => {
                let p = self.local(x, y);
                self.panel.mouse_moved(self.inside(p).then_some(p));
                false
            }
            InputEvent::Scroll { x, y, dy, .. } => {
                let p = self.local(x, y);
                self.panel.scroll_at(p, cx.ui.gesture, f64::from(dy) / f64::from(self.scale))
            }
            InputEvent::KeyDown { key, modifiers } => self.panel.key(key, modifiers, cx.ui),
        };
        self.panel.pump();
        taken
    }
}

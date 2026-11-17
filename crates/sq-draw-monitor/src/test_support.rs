//! Shared fixtures of the panel tests: a session, the services and one `HostCx` per event.

use crate::monitor_panel::MonitorPanel;
use crate::monitor_panel_model::MonitorPanelModel;
use sq_app_shell::{AppEvent, AppServices, HostCx};
use sq_core_time::{SequentialIds, Time};
use sq_draw::canvas::Canvas;
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_draw::scroll::ScrollGesture;
use sq_draw::{InputEvent, InputKey, InputModifiers, UiCx};
use sq_editor_session::{EditorSession, SessionDeps};
use sq_uikit::controls_grid::{CGPoint, CGRect};

/// What the panel borrows for one event.
pub(crate) struct Rig {
    pub session: EditorSession,
    pub ui: UiCx,
    pub services: AppServices,
    pub events: Vec<AppEvent>,
}

impl Rig {
    pub(crate) fn new() -> Rig {
        let mut ids = SequentialIds::default();
        let project = EditorSession::make_untitled(&mut ids);
        let dir = std::env::temp_dir().join("sq-draw-monitor-tests");
        Rig {
            session: EditorSession::new(project, SessionDeps::headless(dir)),
            ui: UiCx::new(),
            services: AppServices::headless(),
            events: Vec::new(),
        }
    }

    /// Routes `e` like the app does: hover bracket around the panel's `handle`.
    pub(crate) fn send(&mut self, p: &mut MonitorPanel, e: InputEvent) -> bool {
        self.ui.hover.begin_event(&e);
        let mut cx = HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: None,
            scale: 1.0,
        };
        let taken = p.handle_event(&e, &mut cx);
        self.ui.hover.end_event(&e, self.ui.now);
        taken
    }

    pub(crate) fn down(&mut self, p: &mut MonitorPanel, x: f64, y: f64, modifiers: InputModifiers) -> bool {
        self.send(p, InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers })
    }
    pub(crate) fn drag(&mut self, p: &mut MonitorPanel, x: f64, y: f64) -> bool {
        self.send(p, InputEvent::dragged(x as f32, y as f32))
    }
    pub(crate) fn up(&mut self, p: &mut MonitorPanel, x: f64, y: f64) -> bool {
        self.send(p, InputEvent::MouseUp { x: x as f32, y: y as f32 })
    }
    pub(crate) fn moved(&mut self, p: &mut MonitorPanel, x: f64, y: f64) -> bool {
        self.send(p, InputEvent::MouseMoved { x: x as f32, y: y as f32 })
    }
    pub(crate) fn key(&mut self, p: &mut MonitorPanel, key: InputKey) -> bool {
        self.send(p, InputEvent::KeyDown { key, modifiers: InputModifiers::NONE })
    }
    pub(crate) fn click(&mut self, p: &mut MonitorPanel, at: CGPoint) {
        self.down(p, at.x, at.y, InputModifiers::NONE);
        self.up(p, at.x, at.y);
    }
    pub(crate) fn scroll(
        &mut self,
        p: &mut MonitorPanel,
        at: CGPoint,
        dx: f32,
        dy: f32,
        modifiers: InputModifiers,
        g: Option<ScrollGesture>,
    ) -> bool {
        self.ui.gesture = g;
        let taken = self.send(p, InputEvent::Scroll { x: at.x as f32, y: at.y as f32, dx, dy, modifiers });
        self.ui.gesture = None;
        taken
    }
}

/// A Program or Source card, 250 frames long at 25 fps, laid out in 800 x 500.
pub(crate) fn panel(mode: MonitorMode) -> MonitorPanel {
    let mut m = MonitorPanelModel::new(Time::new(1, 25), mode);
    m.duration = Time::new(250, 25);
    let mut p = MonitorPanel::new(m, None);
    p.layout_px(sq_draw::Rect::new(0.0, 0.0, 800.0, 500.0), 1.0);
    p
}

/// A card that has been drawn once (popups and tabs are laid out while drawing).
pub(crate) fn drawn(mode: MonitorMode) -> MonitorPanel {
    let mut p = panel(mode);
    draw(&mut p);
    p
}

pub(crate) fn canvas() -> Canvas<'static> {
    Canvas::with_size(800.0, 500.0, None, 1.0)
}

pub(crate) fn draw(p: &mut MonitorPanel) -> Canvas<'static> {
    let mut c = canvas();
    let t = p.theme;
    let mut rig = Rig::new();
    let mut cx = HostCx {
        session: &mut rig.session,
        ui: &mut rig.ui,
        services: &mut rig.services,
        events: &mut rig.events,
        atlas: None,
        scale: 1.0,
    };
    sq_app_shell::AppHost::draw(p, &mut c, &t, &mut cx);
    c
}

/// Like [`draw`] with the bundled Inter, so text has its real width (the plain canvas measures every string as 0).
pub(crate) fn draw_with_text(p: &mut MonitorPanel) -> Canvas<'static> {
    thread_local! {
        static ATLAS: &'static sq_draw::GlyphAtlas = {
            let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
            Box::leak(Box::new(sq_draw::GlyphAtlas::inter(&root).unwrap_or_else(|| panic!("bundled Inter loads"))))
        };
    }
    let atlas: &'static sq_draw::GlyphAtlas = ATLAS.with(|a| *a);
    let mut c = Canvas::with_size(800.0, 500.0, Some(atlas), 1.0);
    let t = p.theme;
    let mut rig = Rig::new();
    let mut cx = HostCx {
        session: &mut rig.session,
        ui: &mut rig.ui,
        services: &mut rig.services,
        events: &mut rig.events,
        atlas: Some(atlas),
        scale: 1.0,
    };
    sq_app_shell::AppHost::draw(p, &mut c, &t, &mut cx);
    c
}

pub(crate) fn mid(r: CGRect) -> CGPoint {
    CGPoint::new(r.mid_x(), r.mid_y())
}

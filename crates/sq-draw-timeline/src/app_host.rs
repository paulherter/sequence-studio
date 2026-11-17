// Swift: SharedUIController / WinShell wiring of the timeline panel
//! The timeline as an [`AppHost`]: pulls the timeline, selection and playhead from the session every frame, lays the
//! panel out in the frame the app gives it, draws it, routes input to it and applies the actions it returns.

use crate::action::TimelineAction;
use crate::host::TimelineHost;
use crate::panel::{SessionView, TimelinePanel};
use crate::session_bridge;
use sq_app_shell::{AppEvent, AppHost, HostCx};
use sq_draw::{Canvas, DrawTheme, InputEvent, Rect};
use sq_editor_session::EditorSession;
use sq_uikit::controls_grid::{CGRect, CGSize};
use std::collections::BTreeSet;

/// The timeline panel with its host hooks, as one panel host of the app.
pub struct TimelineAppHost {
    /// The panel.
    pub panel: TimelinePanel,
    /// The editors and dialogs the timeline asks the app for.
    pub host: TimelineHost,
}

impl TimelineAppHost {
    /// A host around an empty panel.
    pub fn new(theme: DrawTheme) -> TimelineAppHost {
        TimelineAppHost { panel: TimelinePanel::new(theme), host: TimelineHost::new() }
    }

    /// Whether the panel animates (zoom ease, spring back, autoscroll): the app keeps drawing frames.
    pub fn needs_frames(&self) -> bool {
        self.panel.is_zooming()
            || self.panel.word_field.is_some()
            || self.panel.is_springing_back()
            || self.panel.is_autoscrolling()
    }

    /// Commits the open caption word field: a menu chord or a press in another panel takes the typed word like a press
    /// elsewhere in the timeline does.
    pub fn end_text_edits(&mut self, cx: &mut HostCx) {
        let typed = self.panel.finish_word_field(true, 0);
        self.apply(typed, cx);
    }

    fn apply(&mut self, actions: Vec<TimelineAction>, cx: &mut HostCx) {
        for a in actions {
            if let Some(status) = session_bridge::apply(a, cx.session, &mut self.host, Some(&mut self.panel)) {
                cx.emit(AppEvent::Status(status));
            }
            for flow in std::mem::take(&mut self.host.flows) {
                cx.emit(AppEvent::Flow(flow));
            }
        }
    }
}

impl AppHost for TimelineAppHost {
    fn wants_frames(&self) -> bool {
        self.needs_frames()
    }

    fn sync(&mut self, session: &EditorSession) {
        if let Some(t) = session.active_timeline() {
            let labels = session.project().label_resolver();
            // The session owns both (Swift SharedUIController.swift:746): the panel only mirrors them.
            let transition = session.selected_transition();
            let line_keys = session.selected_line_keys().iter().map(|k| k.key).collect();
            self.panel.sync(SessionView {
                timeline: t,
                selection: session.selection(),
                captions: session.caption_selection(),
                playhead: session.playhead(),
                selected_transition: transition,
                labels,
                line_keys,
            });
        }
        self.panel.is_playing = session.is_playing();
        self.panel.follow_playback(session.is_playing());
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        // Autoscroll and zoom ticks apply right away: layout holds the session.
        let ticked = self.panel.tick();
        self.apply(ticked, cx);
        let m = cx.measure();
        let s = f64::from(m.scale);
        self.panel.layout_px(
            Rect::new((frame.x * s) as f32, (frame.y * s) as f32, (frame.width * s) as f32, (frame.height * s) as f32),
            m.scale,
        );
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, _cx: &mut HostCx) {
        self.panel.theme = *t;
        self.panel.ui_now = _cx.ui.now;
        let (scale, size): (f32, CGSize) = (self.panel.scale, self.panel.size);
        c.save_gstate();
        c.translate_by(f64::from(self.panel.frame.x / scale), f64::from(self.panel.frame.y / scale));
        c.clip_to(CGRect::new(0.0, 0.0, size.width, size.height));
        self.panel.draw_timeline(c);
        c.restore_gstate();
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let before = self.panel.is_dragging();
        let actions = self.panel.handle(e, cx.ui);
        let inside = match *e {
            InputEvent::MouseDown { x, y, .. } | InputEvent::MouseMoved { x, y } | InputEvent::Scroll { x, y, .. } => {
                self.panel.contains(x, y)
            }
            InputEvent::MouseDragged { .. } | InputEvent::MouseUp { .. } => before,
            InputEvent::KeyDown { .. } => self.panel.key_handled(),
        };
        let took = inside || !actions.is_empty();
        self.apply(actions, cx);
        took
    }
}

/// The ids a selection set holds, for callers that compare selections.
pub type IdSet = BTreeSet<sq_core_time::Id>;

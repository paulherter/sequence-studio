// Swift: KeyframeGraphDraw.swift
//! Value graph of one scalar component on the shared toolkit: `KeyframeGraphView` translated (fit, hit test and the
//! gesture stay in `KeyframeGraphGeometry` / `GraphGestureState`). Grid, curve, handles of selected keys, small key
//! markers, the top / bottom value and the graph kind; a gesture previews locally and reports `Edit` once on release (one
//! undo step). Coordinates: points, y down, (0, 0) = the graph's top-left.

use std::collections::BTreeSet;
use std::ops::RangeInclusive;

use sq_core_time::{EaseSide, EasingCurve, EasingLibrary, Id, IdSource, KeyframeTrack, Time};
use sq_draw::draw_list::Color;
use sq_draw::theme::radius;
use sq_draw::{Canvas, DrawTheme, InputModifiers, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::key_glyph::KeyGlyph;
use sq_uikit::keyframe_graph_editing::{GraphEditLimits, GraphGestureResult, GraphGestureState};
use sq_uikit::keyframe_graph_geometry::{
    GraphFit, GraphHandleSide, GraphHit, GraphInsets, GraphMode, KeyframeGraphGeometry,
};
use sq_uikit::keyframe_viewport::GraphAxisLabels;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;

use super::{draw_marquee, text_in};
use crate::keyframes::easing_menu_spec::{EasingMenuEntry, EasingMenuSpec};
use crate::keyframes::keyframe_zoom_input::{KeyframeScroll, KeyframeZoomInput};
use sq_draw::scroll::ScrollGesture;

/// What the graph asks its owner to do (Swift's `onEdit`, `onSelectionChange`, ... hooks).
#[derive(Clone, Debug, PartialEq)]
pub enum KeyframeGraphEvent {
    /// `onEdit`: the gesture ended with a new track.
    Edit(KeyframeTrack<f64>),
    /// `onSelectionChange`.
    SelectionChange(BTreeSet<Id>),
    /// `onLibraryChange`.
    LibraryChange(EasingLibrary),
    /// `onModeChange`.
    ModeChange(GraphMode),
    /// `onZoom(factor, anchorSeconds)`.
    Zoom { factor: f64, anchor: f64 },
    /// `onPan(seconds)`.
    Pan(f64),
}

/// The choice of an easing menu row; the graph keeps the ease side and the preset library, so the owner hands the choice
/// back to [`KeyframeGraphDraw::run_menu_action`].
#[derive(Clone, Debug, PartialEq)]
pub enum GraphMenuAction {
    /// Switch between the speed and the value graph.
    Mode(GraphMode),
    /// Which side the next curve applies to.
    Side(EaseSide),
    /// Apply a curve to the selected keys.
    Curve(EasingCurve),
    /// Save the first selected key's curve as a preset (asks for the name through `onPrompt`).
    SaveCurve,
}

/// A row of the easing menu.
#[derive(Clone)]
pub struct GraphMenuItem {
    /// The row.
    pub item: SQMenuItem,
    /// What choosing it does; `None` for separators and headers.
    pub action: Option<GraphMenuAction>,
}

/// Value graph of one scalar component.
pub struct KeyframeGraphDraw {
    /// Size of the graph in points.
    pub size: CGSize,
    track: KeyframeTrack<f64>,
    mode: GraphMode,
    /// Keys that are selected.
    pub selected_key_ids: BTreeSet<Id>,
    /// Playhead in clip seconds.
    pub playhead_seconds: Option<f64>,
    /// One frame.
    pub frame_duration: Time,
    /// Earliest key time.
    pub min_time: Time,
    max_time: Option<Time>,
    /// The saved easing curves.
    pub easing_library: EasingLibrary,
    visible_time: Option<RangeInclusive<f64>>,
    /// Display units per data unit (axis labels).
    pub display_scale: f64,
    /// Space around the plot.
    pub insets: GraphInsets,
    /// Width of the label area painted as panel (0 in Effect Controls: the left pane is the rows column's).
    pub leading_panel_width: f64,
    /// True when the owner can show a name dialog (Save Curve); false leaves the item out of the menu.
    pub has_prompt: bool,
    events: Vec<KeyframeGraphEvent>,
    fit: GraphFit,
    gesture: Option<GraphGestureState>,
    preview: Option<KeyframeTrack<f64>>,
    marquee: Option<CGRect>,
    ease_side: EaseSide,
    hover_hit: GraphHit,
}

impl Default for KeyframeGraphDraw {
    fn default() -> Self {
        Self::new()
    }
}

impl KeyframeGraphDraw {
    /// An empty graph in value mode.
    pub fn new() -> KeyframeGraphDraw {
        KeyframeGraphDraw {
            size: CGSize::default(),
            track: KeyframeTrack { keys: Vec::new() },
            mode: GraphMode::Value,
            selected_key_ids: BTreeSet::new(),
            playhead_seconds: None,
            frame_duration: Time::new(1, 30),
            min_time: Time::ZERO,
            max_time: None,
            easing_library: EasingLibrary::default(),
            visible_time: None,
            display_scale: 1.0,
            insets: GraphInsets::default(),
            leading_panel_width: 0.0,
            has_prompt: false,
            events: Vec::new(),
            fit: GraphFit { time: 0.0..=1.0, value: 0.0..=1.0 },
            gesture: None,
            preview: None,
            marquee: None,
            ease_side: EaseSide::Both,
            hover_hit: GraphHit::Empty,
        }
    }

    /// Takes the events pushed since the last call.
    pub fn take_events(&mut self) -> Vec<KeyframeGraphEvent> {
        std::mem::take(&mut self.events)
    }

    /// The track as set by the owner.
    pub fn track(&self) -> &KeyframeTrack<f64> {
        &self.track
    }
    /// `track` with its `didSet`: refits unless a gesture runs.
    pub fn set_track(&mut self, t: KeyframeTrack<f64>) {
        self.track = t;
        if self.gesture.is_none() {
            self.refit();
        }
    }
    /// The graph kind.
    pub fn mode(&self) -> GraphMode {
        self.mode
    }
    /// `mode` with its `didSet`.
    pub fn set_mode(&mut self, m: GraphMode) {
        self.mode = m;
        self.refit();
    }
    /// The last key time shown (the clip's duration).
    pub fn max_time(&self) -> Option<Time> {
        self.max_time
    }
    /// `maxTime` with its `didSet`.
    pub fn set_max_time(&mut self, t: Option<Time>) {
        let changed = self.max_time != t;
        self.max_time = t;
        if self.gesture.is_none() && changed {
            self.refit();
        }
    }
    /// `visibleTime` with its `didSet`.
    pub fn set_visible_time(&mut self, r: Option<RangeInclusive<f64>>) {
        let changed = self.visible_time != r;
        self.visible_time = r;
        if self.gesture.is_none() && changed {
            self.refit();
        }
    }
    /// The marquee rectangle while one is dragged.
    pub fn marquee(&self) -> Option<CGRect> {
        self.marquee
    }
    /// The key or handle under the pointer.
    pub fn hover_hit(&self) -> GraphHit {
        self.hover_hit
    }

    fn shown_track(&self) -> &KeyframeTrack<f64> {
        self.preview.as_ref().unwrap_or(&self.track)
    }

    /// Fits the axes to the track again.
    pub fn refit(&mut self) {
        let range = self.max_time.map(|m| {
            let lo = sq_uikit::keyframe_graph_geometry::GraphMath::seconds(self.min_time);
            lo..=sq_uikit::keyframe_graph_geometry::GraphMath::seconds(m).max(lo)
        });
        self.fit = GraphFit::make(&self.track, self.mode, 0.12, range, self.visible_time.clone());
    }

    /// The current geometry.
    pub fn geometry(&self) -> KeyframeGraphGeometry {
        KeyframeGraphGeometry { size: self.size, insets: self.insets, fit: self.fit.clone(), mode: self.mode }
    }

    fn limits(&self) -> GraphEditLimits {
        GraphEditLimits { frame_duration: self.frame_duration, min_time: self.min_time, max_time: self.max_time }
    }

    // MARK: Drawing

    /// Draws the graph.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme) {
        let g = self.geometry();
        let bounds = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        c.save_gstate();
        c.clip_to(bounds);
        c.fill(bounds, t.lane());
        if self.leading_panel_width > 0.0 {
            c.fill(CGRect::new(0.0, 0.0, self.leading_panel_width.min(self.size.width), self.size.height), t.panel());
        }
        let plot = g.plot();
        if let Some(ph) = self.playhead_seconds {
            let x = g.x(ph).round();
            if x >= self.leading_panel_width && x < self.size.width {
                c.fill(CGRect::new(x - 1.0, 0.0, 2.0, self.size.height), t.playhead());
            }
        }
        c.save_gstate();
        c.clip_to(plot.inset_by(-1.0, -4.0));
        for v in g.grid_values(3) {
            c.fill(
                CGRect::new(plot.min_x(), g.y(v).round(), plot.width, 1.0),
                if v == 0.0 { t.label3() } else { t.separator() },
            );
        }
        let tr = self.shown_track();
        // Theme.Colors.curveX / curveY
        let curve = if self.mode == GraphMode::Value { Color::hex(0xFF9F0A, 1.0) } else { Color::hex(0x64D2FF, 1.0) };
        for seg in g.curve_polylines(tr) {
            c.stroke_polyline(&seg.points, 1.5, curve);
        }
        for k in tr.keys.iter().filter(|k| self.selected_key_ids.contains(&k.id)) {
            let Some(i) = tr.keys.iter().position(|q| q.id == k.id) else { continue };
            let kp = g.key_point(tr, i);
            for side in [GraphHandleSide::InSide, GraphHandleSide::OutSide] {
                let Some(hp) = g.handle_point(tr, k.id, side) else { continue };
                c.stroke_line(kp, hp, KeyframeGraphGeometry::HANDLE_LINE_WIDTH, t.accent());
                let d = KeyframeGraphGeometry::HANDLE_KNOB_DIAMETER;
                c.fill_ellipse(CGRect::new(hp.x - d / 2.0, hp.y - d / 2.0, d, d), t.accent());
            }
        }
        if let Some(p) = self.hover_point(&g, tr) {
            c.fill_rounded(CGRect::new(p.x - 6.0, p.y - 6.0, 12.0, 12.0), radius::SMALL as f64, t.fill_hover());
        }
        for (i, k) in KeyGlyph::glyphs(tr).iter().enumerate() {
            let p = g.key_point(tr, i);
            c.fill(
                CGRect::new(p.x - 3.0, p.y - 3.0, 6.0, 6.0),
                if self.selected_key_ids.contains(&k.id) { t.accent() } else { t.keyframe() },
            );
        }
        c.restore_gstate();
        // Axis labels: the top and bottom of the visible range and the graph kind, right-aligned left of the plot.
        let right = (if self.leading_panel_width > 0.0 { self.leading_panel_width } else { plot.min_x() }) - 10.0;
        let fs = sq_draw::theme::type_size::CAPTION as f64;
        if right > 0.0 {
            let hi = GraphAxisLabels::format(*self.fit.value.end(), self.display_scale);
            let lo = GraphAxisLabels::format(*self.fit.value.start(), self.display_scale);
            text_in(c, &hi, CGRect::new(0.0, plot.min_y() - 2.0, right, 13.0), fs, t.accent(), TextAlign::Right);
            text_in(c, &lo, CGRect::new(0.0, plot.max_y() - 11.0, right, 13.0), fs, t.accent(), TextAlign::Right);
            let kind = SQL10n::string(if self.mode == GraphMode::Speed { "Speed" } else { "Value" });
            text_in(
                c,
                &kind,
                CGRect::new(0.0, self.size.height / 2.0 - 6.5, right, 13.0),
                fs,
                t.label3(),
                TextAlign::Right,
            );
        }
        if let Some(m) = self.marquee {
            draw_marquee(c, m, t);
        }
        c.restore_gstate();
    }

    fn hover_point(&self, g: &KeyframeGraphGeometry, t: &KeyframeTrack<f64>) -> Option<CGPoint> {
        if self.gesture.is_some() {
            return None;
        }
        match self.hover_hit {
            GraphHit::Key(id) => t.keys.iter().position(|k| k.id == id).map(|i| g.key_point(t, i)),
            GraphHit::Handle(id, side) => g.handle_point(t, id, side),
            GraphHit::Segment { .. } | GraphHit::Empty => None,
        }
    }

    // MARK: Mouse

    /// The pointer moved over the graph (`None`: it left).
    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        if self.gesture.is_some() {
            return;
        }
        let Some(p) = p else {
            self.hover_hit = GraphHit::Empty;
            return;
        };
        let h = self.geometry().hit_test(p, &self.track, &self.selected_key_ids);
        self.hover_hit = match h {
            GraphHit::Key(_) | GraphHit::Handle(..) => h,
            GraphHit::Segment { .. } | GraphHit::Empty => GraphHit::Empty,
        };
    }

    /// Press at `p`.
    pub fn mouse_down(&mut self, p: CGPoint, shift: bool) {
        self.refit();
        let g = GraphGestureState::new(
            p,
            shift,
            self.geometry(),
            self.track.clone(),
            self.selected_key_ids.clone(),
            self.limits(),
        );
        let current = g.current();
        self.gesture = Some(g);
        self.apply(current);
    }

    /// Drag to `p`.
    pub fn mouse_dragged(&mut self, p: CGPoint, shift: bool) {
        let r = self.gesture.as_mut().map(|g| g.drag(p, shift));
        if let Some(r) = r {
            self.apply(r);
        }
    }

    /// Release at `p`: one `Edit` when the gesture changed the track.
    pub fn mouse_up(&mut self, p: CGPoint) {
        let Some(mut g) = self.gesture.take() else { return };
        let r = g.end(p);
        self.preview = None;
        self.marquee = None;
        self.set_selection(r.selection);
        if r.commit {
            self.track = r.track.clone();
            self.events.push(KeyframeGraphEvent::Edit(r.track));
        } else {
            self.refit();
        }
        self.mouse_moved(Some(p));
    }

    /// True while a gesture runs.
    pub fn is_dragging(&self) -> bool {
        self.gesture.is_some()
    }

    fn apply(&mut self, r: GraphGestureResult) {
        self.preview = if r.track == self.track { None } else { Some(r.track) };
        self.marquee = r.marquee;
        self.set_selection(r.selection);
    }

    fn set_selection(&mut self, s: BTreeSet<Id>) {
        if s == self.selected_key_ids {
            return;
        }
        self.selected_key_ids = s.clone();
        self.events.push(KeyframeGraphEvent::SelectionChange(s));
    }

    /// Wheel (KeyframeZoomInput rules): Option / Ctrl zooms around the pointer, horizontal pans.
    pub fn scroll(
        &mut self,
        p: CGPoint,
        dx: f64,
        dy: f64,
        modifiers: InputModifiers,
        published: Option<&ScrollGesture>,
    ) -> bool {
        let g = self.geometry();
        match KeyframeZoomInput::classify(dx, dy, modifiers, published) {
            KeyframeScroll::Zoom { factor } => {
                self.events.push(KeyframeGraphEvent::Zoom { factor, anchor: g.seconds_at_x(p.x) });
                true
            }
            KeyframeScroll::Pan { points } => {
                self.events.push(KeyframeGraphEvent::Pan(-points / g.points_per_second().max(1e-6)));
                true
            }
            KeyframeScroll::None => false,
        }
    }

    // MARK: Easing menu

    /// Right click: selects the key under the pointer (if not selected) and returns the easing menu.
    pub fn context_menu(&mut self, p: CGPoint) -> Vec<GraphMenuItem> {
        self.refit();
        if let GraphHit::Key(id) = self.geometry().hit_test(p, &self.track, &self.selected_key_ids)
            && !self.selected_key_ids.contains(&id)
        {
            self.set_selection(BTreeSet::from([id]));
        }
        self.make_easing_items()
    }

    /// Rows: graph mode, side choice (applies to in / out / both), built-in curves, user presets, Save Curve.
    pub fn make_easing_items(&self) -> Vec<GraphMenuItem> {
        let spec = EasingMenuSpec::new(&self.easing_library, self.ease_side, !self.selected_key_ids.is_empty());
        let mut items: Vec<GraphMenuItem> = Vec::new();
        for (m, title) in [(GraphMode::Speed, "Speed"), (GraphMode::Value, "Value")] {
            let mut item = SQMenuItem::new(title);
            item.is_checked = self.mode == m;
            items.push(GraphMenuItem { item, action: Some(GraphMenuAction::Mode(m)) });
        }
        items.push(GraphMenuItem { item: SQMenuItem::separator(), action: None });
        for entry in spec.entries {
            match entry {
                EasingMenuEntry::Header(title) => {
                    items.push(GraphMenuItem { item: SQMenuItem::header(&title), action: None })
                }
                EasingMenuEntry::Side { side, title, checked } => {
                    let mut item = SQMenuItem::new(&title);
                    item.is_checked = checked;
                    items.push(GraphMenuItem { item, action: Some(GraphMenuAction::Side(side)) });
                }
                EasingMenuEntry::Curve { curve, enabled } => {
                    let mut item = SQMenuItem::new(&EasingMenuSpec::title(&curve));
                    item.is_enabled = enabled;
                    items.push(GraphMenuItem { item, action: Some(GraphMenuAction::Curve(curve)) });
                }
                EasingMenuEntry::Separator => items.push(GraphMenuItem { item: SQMenuItem::separator(), action: None }),
                EasingMenuEntry::SaveCurve { enabled } => {
                    if !self.has_prompt {
                        continue;
                    }
                    let mut item = SQMenuItem::new("Save as preset\u{2026}");
                    item.is_enabled = enabled;
                    items.push(GraphMenuItem { item, action: Some(GraphMenuAction::SaveCurve) });
                }
            }
        }
        items
    }

    /// Runs a chosen easing menu row. `SaveCurve` returns true: the owner asks for a name and calls
    /// [`KeyframeGraphDraw::save_selected_curve`] with it.
    pub fn run_menu_action(&mut self, a: GraphMenuAction) -> bool {
        match a {
            GraphMenuAction::Mode(m) => self.events.push(KeyframeGraphEvent::ModeChange(m)),
            GraphMenuAction::Side(s) => self.ease_side = s,
            GraphMenuAction::Curve(c) => self.apply_easing_curve(&c),
            GraphMenuAction::SaveCurve => return true,
        }
        false
    }

    fn apply_easing_curve(&mut self, c: &EasingCurve) {
        if self.selected_key_ids.is_empty() {
            return;
        }
        let mut t = self.track.clone();
        t.apply(c, &self.selected_key_ids, self.ease_side);
        if t == self.track {
            return;
        }
        self.track = t.clone();
        self.events.push(KeyframeGraphEvent::Edit(t));
    }

    /// The name dialog came back: saves the first selected key's curve (a blank name saves nothing).
    pub fn save_selected_curve(&mut self, ids: &mut dyn IdSource, name: Option<&str>) {
        let Some(key) = self.track.keys.iter().find(|k| self.selected_key_ids.contains(&k.id)).cloned() else { return };
        let Some(name) = name.map(|n| n.trim_matches(|c: char| c == ' ' || c == '\t')) else { return };
        if name.is_empty() {
            return;
        }
        self.easing_library.save_curve(ids, &key, name.to_string());
        self.events.push(KeyframeGraphEvent::LibraryChange(self.easing_library.clone()));
    }
}

// Swift: MonitorPanel.swift, MonitorPanel+Tips.swift
//! The Program / Source monitor on the shared toolkit: MonitorPanelView translated to the canvas. The state, menus and
//! command routing are the [`MonitorPanelModel`]; this type only lays out, draws and turns pointer events into model
//! calls. It is an [`AppHost`]: `sync` pulls the session, `layout` places the card, `draw` paints it and `handle` routes
//! input. Header: title, content popup (the sequence or the Source clip), Platform Safe Zone while one is on, Zoom,
//! Playback Quality and the "..." monitor menu. Picture: zoomed and panned through [`MonitorViewMapping`] (wheel pans,
//! Ctrl / Alt + wheel zooms about the pointer, as the Mac trackpad), safe margins, aspect frame, platform zone, rulers and
//! guides, drop dot and resolution badge. Footer: `MonitorFooter`. Coordinates: window points; events arrive in pixels.
//!
//! The Swift `on*` hooks are [`PanelEvent`]s in `events` (the owner takes them with [`MonitorPanel::take_events`]);
//! hooks that returned a value are fields the owner fills before each call (`type_tool_on`, `hand_tool_on`,
//! `create_mode_now`, `loudness`) or small traits ([`PictureToolsHost`], [`GraphicsLayerSource`]) that receive the session.

use crate::angle_tile::AnglesGridLayout;
use crate::cg::RectExt;
use crate::create_tool_drag::CreateToolDrag;
use crate::graphics_layer_overlay::GraphicsLayerOverlay;
use crate::monitor_drop_zone::MonitorDropZone;
use crate::monitor_menus::MonitorMenus;
use crate::monitor_panel_model::{MonitorEvent, MonitorPanelModel, ProgramEmptyKind};
use crate::monitor_panel_overlays::GuideAxisDrag;
use crate::monitor_panel_source_drag::{MonitorDragPhase, SourceDragState, SourceWaveMeter};
use crate::monitor_text_field::MonitorTextField;
use crate::monitor_view_mapping::MonitorViewMapping;
use crate::shortcut_tips::MonitorActionTips;
use crate::slip_two_up::SlipTwoUpPicture;
use crate::step_window_overlay::StepWindowOverlay;
use crate::transform_overlay::TransformOverlay;
use crate::zoom_edit_overlay::ZoomEditOverlay;
use sq_app_shell::{AppEvent, AppHost, HostCx};
use sq_core_edit::cut_check::NormRect;
use sq_core_edit::platform_uimock::PlatformUIMockElement;
use sq_core_edit::viewer_zoom::ViewerZoom;
use sq_core_model::ShapeKind;
use sq_core_time::{Time, Vec2};
use sq_draw::canvas::Canvas;
use sq_draw::monitor::loudness_meter::{LoudnessReading, LoudnessTarget};
use sq_draw::monitor::loudness_readout::LoudnessReadout;
use sq_draw::monitor::monitor_footer::{MonitorFooter, MonitorFooterEvent, MonitorFooterState};
use sq_draw::monitor::monitor_guides::Axis;
use sq_draw::monitor::monitor_modes::{MonitorMode, MonitorZoom};
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{DrawTheme, metrics, radius, spacing};
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{Color, InputEvent, InputKey, InputModifiers, InspectorDraw, Rect, TextAlign, UiCx, scroll::GestureKind};
use sq_editor_session::EditorSession;
use sq_editor_session::es01_session_core::CreateToolMode;
use sq_editor_session::es02_timeline_ops::SnapResult;
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;

/// Draws Pip into a rect.
pub type EmptyMascotDraw = Box<dyn Fn(&mut Canvas, CGRect)>;

/// The header popups.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HeaderControl {
    /// The sequence / Source clip popup.
    Content,
    /// The Platform Safe Zone popup.
    Zone,
    /// The zoom popup.
    Zoom,
    /// The playback quality popup.
    Quality,
    /// The "..." menu.
    Options,
}

/// What the Swift panel's `on*` hooks reported, in call order.
#[derive(Clone, Debug)]
pub enum PanelEvent {
    /// `onMenu`: popups and right-click menus: rows, the control (or point) they open from in window points, and the
    /// pointer for a right click. The host opens them in the shell's one menu system.
    Menu {
        /// The rows.
        items: Vec<SQMenuItem>,
        /// The control or point they open from.
        anchor: CGRect,
        /// The pointer for a right click.
        pointer: Option<CGPoint>,
    },
    /// `onZoomGesture`: a wheel zoom or pan changed the shown zoom.
    ZoomGesture(ViewerZoom),
    /// `onPickClip`: a click on the picture that no overlay or guide took, in sequence px from the canvas center; the host
    /// selects the topmost clip there (`TextHitTest::topmost_visual_clip`).
    PickClip(Vec2),
    /// `onSelectTab`: Program | Source tabs in the header.
    SelectTab(usize),
    /// `onSourceDrag`: the Source picture or a stream handle dragged toward the timeline (window pixels).
    SourceDrag {
        /// The streams dragged.
        streams: sq_core_edit::timeline_source_edit::SourceStreams,
        /// Moved, ended or canceled.
        phase: MonitorDragPhase,
        /// Pointer x in window pixels.
        x: f32,
        /// Pointer y in window pixels.
        y: f32,
    },
    /// `onWaveChannelMonitorChange`: Solo / Mute from the waveform meter's labels.
    WaveChannelMonitorChange(sq_audiofx::channel_monitor::ChannelMonitor),
    /// `onTypeClick`: the Type tool placed point text.
    TypeClick(Vec2),
    /// `onTypeBox`: the Type tool dragged an area text box out (center and size).
    TypeBox {
        /// Center in sequence px.
        center: Vec2,
        /// Size in sequence px.
        size: Vec2,
    },
    /// `onTextDoubleClick`: a double-click on the picture (Select tool); the host edits the text under it.
    TextDoubleClick(Vec2),
    /// `onCreateShape`: the Create tool made a shape (kind, from, to) in sequence px.
    CreateShape(ShapeKind, Vec2, Vec2),
    /// `onCreateStroke`: the Create tool drew a stroke (points, tolerance).
    CreateStroke(Vec<Vec2>, f64),
    /// `onCaptionDoubleClick`: a double-click on a caption.
    CaptionDoubleClick(Vec2),
}

/// Which optional Swift hooks the owner consumes (Swift tested `hook != nil`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PanelWiring {
    /// `onSourceDrag`: the Source picture is a drag source.
    pub source_drag: bool,
    /// `onTypeClick` or `onTypeBox`: the Type tool works.
    pub type_tool: bool,
    /// `onTextDoubleClick`.
    pub text_double_click: bool,
    /// `onCreateShape` or `onCreateStroke`: the Create tool works.
    pub create_tool: bool,
}

impl PanelWiring {
    /// Every hook consumed.
    pub fn all() -> PanelWiring {
        PanelWiring { source_drag: true, type_tool: true, text_double_click: true, create_tool: true }
    }
}

/// Captions on the picture (Select tool): hit test, press (true = the host selected it), drag by a sequence px delta with
/// a snap distance (0 = off, Alt) returning the guides to show, release.
pub trait PictureToolsHost {
    /// A caption lies under `p` (sequence px from the canvas center).
    fn caption_hit_test(&self, s: &EditorSession, p: Vec2) -> bool;
    /// A press on a caption; true when the host selected it.
    fn caption_drag_began(&mut self, s: &mut EditorSession, p: Vec2) -> bool;
    /// The caption dragged by `delta`, snapped within `snap` (0 = off).
    fn caption_drag_moved(&mut self, s: &mut EditorSession, delta: Vec2, snap: f64) -> SnapResult;
    /// The drag ended.
    fn caption_drag_ended(&mut self, s: &mut EditorSession);
}

/// The monitor card: header, picture and footer.
pub struct MonitorPanel {
    /// The state the card shows.
    pub model: MonitorPanelModel,
    /// The theme (set from `draw`).
    pub theme: DrawTheme,
    /// "Program" / "Source": the header title (the Mac tab strip's label).
    pub title: String,
    pub(crate) frame: CGRect,
    pub(crate) scale: f32,
    pub(crate) sequence_size: CGSize,
    /// The host has a decoded frame bound to the video quad.
    pub has_picture: bool,
    /// Renderer image slot that carries this card's picture; `None` uses the window's one video quad (the Program card).
    pub picture_slot: Option<usize>,
    /// The bound picture keeps its alpha (a transparent composite): the Transparency Grid option shows a checkerboard
    /// behind it. Off while the host's picture is opaque.
    pub picture_has_alpha: bool,
    /// A Slip drag runs: the two-up (first and last frame of the slipped clip) instead of the picture.
    pub slip_two_up: Option<SlipTwoUpPicture>,
    /// Platform UI zone (frame fractions) and its UI mock: the host computes them from the model's `safe_zone`.
    pub platform_zone: Option<NormRect>,
    /// The platform UI mock elements.
    pub platform_mock: Vec<PlatformUIMockElement>,
    /// Transform box, Crop handles and motion path of the selected clip (Program monitor; the host fills it).
    pub overlay: TransformOverlay,
    /// The layers of the selected graphic (text, shapes): picked, boxed and moved one by one, above the clip's box.
    pub layer_overlay: GraphicsLayerOverlay,
    /// Where the pointer rests on the picture (sequence px from the canvas center), `None` beside it.
    pub(crate) pointer_sequence_position: Option<Vec2>,
    pub(crate) last_pointer: Option<CGPoint>,
    /// Program | Source tabs in the header instead of the title (empty = the title); `selected_tab` is this panel's.
    pub tabs: Vec<String>,
    /// The tab this panel is.
    pub selected_tab: usize,
    pub(crate) tab_rects: Vec<CGRect>,
    /// A press on the Source waveform view is scrubbing.
    pub(crate) press_in_wave: bool,
    pub(crate) source_drag: Option<SourceDragState>,
    /// The Source player's meter feed for audio-only media: set by the owner before `poll_wave_meter`; `has_wave_meter`
    /// says the owner provides one (Swift `waveMeterReading != nil`).
    pub has_wave_meter: bool,
    /// The newest meter reading of the Source player.
    pub wave_meter_reading: Option<sq_draw::monitor::audio_meter::MeterReading>,
    /// The level meter beside the Source waveform.
    pub wave_meter: SourceWaveMeter,
    /// The on-canvas text field and the Type tool's click / drag-out on the picture.
    pub text_field: MonitorTextField,
    /// The Type tool is the armed tool.
    pub type_tool_on: bool,
    pub(crate) type_press: Option<(CGPoint, CGPoint)>,
    /// Hand tool: a drag pans the shown picture, a double-click fits it.
    pub hand_tool_on: bool,
    pub(crate) hand_last: Option<CGPoint>,
    pub(crate) last_press: Option<(f64, CGPoint)>,
    /// The steady time of the event being handled (`UiCx::now`), for double-clicks.
    pub(crate) now: f64,
    /// Create tool on the picture: the mode now (`None` = not the Create tool).
    pub create_mode_now: Option<CreateToolMode>,
    pub(crate) create_drag: Option<CreateToolDrag>,
    /// Captions on the picture (Select tool).
    pub captions: Option<Box<dyn PictureToolsHost>>,
    pub(crate) caption_press: Option<(CGPoint, bool, SnapResult)>,
    /// Dynamic Zoom editor and Color Step window over the picture (the host sets and clears them).
    pub zoom_edit: Option<ZoomEditOverlay>,
    /// The Color Step window editor.
    pub step_window_edit: Option<StepWindowOverlay>,
    /// The angle tile under the pointer in the multi-angle Source view.
    pub(crate) angle_hover: Option<usize>,
    /// Which optional hooks the owner consumes.
    pub wiring: PanelWiring,
    pub(crate) viewer_zoom: ViewerZoom,
    shown_model_zoom: MonitorZoom,
    pub(crate) footer: MonitorFooter,
    pub(crate) header_rect: CGRect,
    /// The viewer slot (picture area inside the 12 pt margin at Fit) and the picture in it.
    pub(crate) slot: CGRect,
    pub(crate) canvas_rect: CGRect,
    /// Header popups in drawing order (laid out while drawing: their widths come from the glyphs).
    pub(crate) header_controls: Vec<(HeaderControl, CGRect)>,
    hovered_control: Option<HeaderControl>,
    /// Press in progress: the footer (scrub, grips, buttons) or a guide.
    press_in_footer: bool,
    /// Program loudness readout (bottom left of the picture): short-term and integrated LUFS while the engine measures;
    /// the host sets it on the Program monitor only.
    pub loudness: Option<LoudnessReading>,
    /// The loudness target the readout is measured against.
    pub loudness_target: LoudnessTarget,
    /// Project items dragged over the monitor: a focus ring and a tint; the Program monitor also names the half under the
    /// pointer (Insert left, Overwrite right). The host sets both from its drag callbacks.
    pub drop_highlight: bool,
    /// The half under the pointer.
    pub drop_zone: Option<MonitorDropZone>,
    /// The "New Sequence..." button of the empty Program monitor (laid out while drawing, like the header popups).
    pub(crate) new_sequence_rect: CGRect,
    /// Draws Pip into the Program empty state; the host owns the animation.
    pub empty_mascot: Option<EmptyMascotDraw>,
    /// The monitor has keyboard focus: its header line turns accent.
    pub is_focused: bool,
    /// Where the last draw put Pip (zero when none).
    pub(crate) empty_mascot_rect: CGRect,
    new_sequence_hover: bool,
    new_sequence_pressed: bool,
    /// Caret offsets of the open timecode field as last drawn (the canvas measures glyphs only while drawing).
    timecode_carets: Vec<f64>,
    pub(crate) active_guide: Option<GuideAxisDrag>,
    /// What the draw pass asked of the UI (the IME caret of the timecode field and the text field); the owner copies
    /// `requests` to its `UiCx` after the frame. `AppHost::draw` has no `UiCx`.
    pub draw_cx: UiCx,
    /// The key map the footer tips read (`CommandMap::current()` when the panel was made; the owner refreshes it).
    pub key_map: CommandMap,
    pub(crate) events: Vec<PanelEvent>,
}

impl MonitorPanel {
    /// Thickness of the active line under the header.
    pub const ACTIVE_LINE_THICKNESS: f64 = 2.0;
    /// `SQMascotPlace.programEmpty.side`.
    pub const EMPTY_MASCOT_SIDE: f64 = 72.0;
    const HEADER_HEIGHT: f64 = metrics::MONITOR_HEADER as f64;
    const FOOTER_HEIGHT: f64 = metrics::MONITOR_FOOTER as f64;

    /// A card over `model`; `title` defaults to "Program" / "Source".
    pub fn new(model: MonitorPanelModel, title: Option<&str>) -> MonitorPanel {
        let title = title
            .map(str::to_string)
            .unwrap_or_else(|| SQL10n::string(if model.mode == MonitorMode::Program { "Program" } else { "Source" }));
        MonitorPanel {
            model,
            theme: DrawTheme::default(),
            title,
            frame: CGRect::default(),
            scale: 1.0,
            sequence_size: CGSize::new(1920.0, 1080.0),
            has_picture: false,
            picture_slot: None,
            picture_has_alpha: false,
            slip_two_up: None,
            platform_zone: None,
            platform_mock: Vec::new(),
            overlay: TransformOverlay::new(),
            layer_overlay: GraphicsLayerOverlay::new(),
            pointer_sequence_position: None,
            last_pointer: None,
            tabs: Vec::new(),
            selected_tab: 0,
            tab_rects: Vec::new(),
            press_in_wave: false,
            source_drag: None,
            has_wave_meter: false,
            wave_meter_reading: None,
            wave_meter: SourceWaveMeter::new(),
            text_field: MonitorTextField::new(),
            type_tool_on: false,
            type_press: None,
            hand_tool_on: false,
            hand_last: None,
            last_press: None,
            now: 0.0,
            create_mode_now: None,
            create_drag: None,
            captions: None,
            caption_press: None,
            zoom_edit: None,
            step_window_edit: None,
            angle_hover: None,
            wiring: PanelWiring::default(),
            viewer_zoom: ViewerZoom::Fit,
            shown_model_zoom: MonitorZoom::Fit,
            footer: MonitorFooter::new(),
            header_rect: CGRect::default(),
            slot: CGRect::default(),
            canvas_rect: CGRect::default(),
            header_controls: Vec::new(),
            hovered_control: None,
            press_in_footer: false,
            loudness: None,
            loudness_target: LoudnessTarget::default(),
            drop_highlight: false,
            drop_zone: None,
            new_sequence_rect: CGRect::default(),
            empty_mascot: None,
            is_focused: false,
            empty_mascot_rect: CGRect::default(),
            new_sequence_hover: false,
            new_sequence_pressed: false,
            timecode_carets: Vec::new(),
            active_guide: None,
            draw_cx: UiCx::new(),
            key_map: CommandMap::current(),
            events: Vec::new(),
        }
    }

    /// Takes the hook calls since the last take, in the order Swift made them.
    pub fn take_events(&mut self) -> Vec<PanelEvent> {
        std::mem::take(&mut self.events)
    }

    /// The card in window points.
    pub fn frame(&self) -> CGRect {
        self.frame
    }

    /// Device pixels per point.
    pub fn scale(&self) -> f32 {
        self.scale
    }

    /// The footer.
    pub fn footer(&self) -> &MonitorFooter {
        &self.footer
    }

    /// The header strip.
    pub fn header_rect(&self) -> CGRect {
        self.header_rect
    }

    /// The viewer slot.
    pub fn slot(&self) -> CGRect {
        self.slot
    }

    /// The picture in the slot.
    pub fn canvas_rect(&self) -> CGRect {
        self.canvas_rect
    }

    /// The header popups as last drawn.
    pub fn header_controls(&self) -> &[(HeaderControl, CGRect)] {
        &self.header_controls
    }

    /// The zoom the picture is shown at: the popup's value, or the last wheel / pinch value.
    pub fn viewer_zoom(&self) -> ViewerZoom {
        self.viewer_zoom
    }

    /// The "New Sequence..." button as last drawn.
    pub fn new_sequence_rect(&self) -> CGRect {
        self.new_sequence_rect
    }

    /// Where the last draw put Pip (zero when none).
    pub fn empty_mascot_rect(&self) -> CGRect {
        self.empty_mascot_rect
    }

    /// Where the pointer rests on the picture (sequence px from the canvas center), `None` beside it: the host previews the
    /// Magic tool's object on the clip under it.
    pub fn pointer_sequence_position(&self) -> Option<Vec2> {
        self.pointer_sequence_position
    }

    /// Picture size in pixels (the sequence format, or the Source clip): aspect and zoom percentages.
    pub fn sequence_size(&self) -> CGSize {
        self.sequence_size
    }

    /// Sets the picture size; the layer overlay follows.
    pub fn set_sequence_size(&mut self, s: CGSize) {
        self.sequence_size = s;
        self.layer_overlay.set_sequence_size(s);
    }

    /// The overlay learned of a pointer that has not moved since (a layer that appeared under it): it hears the position again.
    pub fn repeat_pointer_overlay(&mut self) {
        if let Some(p) = self.last_pointer
            && !self.overlay.is_dragging()
        {
            let r = self.canvas_rect;
            self.overlay.pointer_moved(p, r);
        }
    }

    /// `PanelActiveMarker.lineFrame(in:headerHeight:)`: inset `sm` each side, the header's bottom 2 pt.
    pub fn active_line_rect(header: CGRect) -> CGRect {
        let inset = spacing::SM as f64;
        CGRect::new(
            header.min_x() + inset,
            header.max_y() - Self::ACTIVE_LINE_THICKNESS,
            (header.width - 2.0 * inset).max(0.0),
            Self::ACTIVE_LINE_THICKNESS,
        )
    }

    /// A press, drag or editor is running on the card.
    pub fn is_dragging(&self) -> bool {
        self.press_in_footer
            || self.press_in_wave
            || self.active_guide.is_some()
            || self.overlay.is_dragging()
            || self.layer_overlay.is_dragging()
            || self.hand_last.is_some()
            || self.source_drag.is_some()
            || self.type_press.is_some()
            || self.picture_tool_dragging()
    }

    // MARK: Layout

    /// MonitorPanelView.viewerMargin: 12 pt around the picture at Fit, none once zoomed.
    pub fn viewer_margin(zoom: ViewerZoom) -> f64 {
        if zoom.is_fit() { spacing::MD as f64 } else { 0.0 }
    }

    /// Lays the card out in `r` (pixels, as the screen hands out its rects).
    pub fn layout_px(&mut self, r: Rect, scale: f32) {
        self.scale = scale.max(0.01);
        let k = self.scale as f64;
        let frame = CGRect::new(r.x as f64 / k, r.y as f64 / k, r.w as f64 / k, r.h as f64 / k);
        self.layout_frame(frame);
    }

    /// Lays the card out in `frame` (window points).
    pub fn layout_frame(&mut self, frame: CGRect) {
        self.frame = frame;
        if self.model.zoom() != self.shown_model_zoom {
            // the popup (or a key) picked a zoom
            self.shown_model_zoom = self.model.zoom();
            self.viewer_zoom = Self::viewer_zoom_for(self.model.zoom());
        }
        // With Program | Source tabs the header is the dock's tab strip, so it takes the strip's height and the labels sit on
        // the same line as the other panels' tabs.
        let header = if self.tabs.is_empty() {
            Self::HEADER_HEIGHT
        } else {
            sq_uikit::redesign_tokens::size::PANEL_HEADER as f64
        };
        self.header_rect = CGRect::new(frame.min_x(), frame.min_y(), frame.width, header);
        let footer_rect =
            CGRect::new(frame.min_x(), frame.max_y() - Self::FOOTER_HEIGHT, frame.width, Self::FOOTER_HEIGHT);
        let pic = CGRect::new(
            frame.min_x(),
            self.header_rect.max_y(),
            frame.width,
            (footer_rect.min_y() - self.header_rect.max_y()).max(0.0),
        );
        let m = Self::viewer_margin(self.viewer_zoom);
        self.slot = pic.inset_by(m.min(pic.width / 2.0), m.min(pic.height / 2.0));
        let mapping = self.mapping();
        self.canvas_rect = mapping.canvas_rect().offset_by(self.slot.min_x(), self.slot.min_y());
        let st = self.footer_state();
        self.footer.layout(footer_rect, &st, 0.0);
    }

    /// The picture placement for the slot (the Mac `MonitorViewMapping` of the surface).
    pub fn mapping(&self) -> MonitorViewMapping {
        MonitorViewMapping::new(
            CGSize::new(self.slot.width, self.slot.height),
            self.scale as f64,
            self.sequence_size,
            self.viewer_zoom,
        )
    }

    /// The popup's zoom as the presenter's.
    pub fn viewer_zoom_for(z: MonitorZoom) -> ViewerZoom {
        match z {
            MonitorZoom::Fit => ViewerZoom::Fit,
            MonitorZoom::Percent(p) | MonitorZoom::Custom(p) => ViewerZoom::Percent(p),
        }
    }

    /// The footer's state from the model (the fields the host keeps current).
    pub fn footer_state(&self) -> MonitorFooterState {
        let m = &self.model;
        let mut f = MonitorFooterState::new(m.mode, m.frame_duration, m.drop_frame);
        f.current_time = m.current_time;
        f.duration = m.duration;
        f.mark_in = m.mark_in;
        f.mark_out = m.mark_out;
        f.marker_times = m.marker_times.clone();
        f.is_playing = m.is_playing;
        f.marks_editable = m.marks_editable();
        f.source_file_view = m.source_file_view;
        f
    }

    /// Program with nothing to show, or Source with no clip: the empty state instead of the picture. (title, hint)
    pub fn empty_text(&self) -> Option<(Option<&'static str>, &'static str)> {
        if self.model.mode == MonitorMode::Program {
            let k = self.model.program_empty_state();
            return if k == ProgramEmptyKind::None { None } else { Some((None, k.hint())) };
        }
        if self.model.source_items.is_empty() {
            Some((Some("No clip in Source"), "Double-click a clip in the Project panel, or drag it here"))
        } else {
            None
        }
    }

    // MARK: Drawing

    /// Draws the card. The footer's IME caret request lands in `draw_cx.requests`.
    pub fn draw_card(&mut self, c: &mut Canvas, t: &DrawTheme) {
        self.theme = *t;
        self.scale = c.scale;
        let t = *t;
        c.fill_rounded(self.frame, t.panel_radius(), t.panel());
        self.draw_header(c);
        // The Mac `pic` view (header to footer, edge to edge) carries the backdrop too: the picture margin is not panel colored.
        c.fill(
            CGRect::new(
                self.frame.min_x(),
                self.header_rect.max_y(),
                self.frame.width,
                (self.footer.frame().min_y() - self.header_rect.max_y()).max(0.0),
            ),
            t.monitor_backdrop(),
        );
        c.save_gstate();
        c.clip_to(self.slot);
        c.fill(self.slot, t.monitor_backdrop());
        self.new_sequence_rect = CGRect::default();
        self.empty_mascot_rect = CGRect::default();
        let slot = self.slot;
        let empty = self.empty_text();
        if self.shows_angles_grid() {
            self.draw_angles_grid(c);
        } else if let Some((Some(title), hint)) = empty {
            // Source with no clip: the Mac `EmptyStateView` (15 pt semibold title, body hint).
            c.draw_empty_state(&SQL10n::string(title), &SQL10n::string(hint), slot, 0.0, &t.on_viewer());
        } else if let Some((title, hint)) = empty {
            self.draw_program_empty(c, title, hint, &t);
        } else if self.shows_waveform() {
            self.draw_waveform(c);
            self.draw_wave_meter(c);
        } else if let Some(two) = self.slip_two_up.clone() {
            self.draw_slip_two_up(c, &two);
        } else {
            let r = self.canvas_rect;
            // Offline media: the Mac monitor shows its gray backdrop under the card, not a black frame.
            if self.shows_checkerboard() {
                self.draw_checkerboard(c, r);
            } else if self.model.offline_card_detail().is_none() {
                c.fill(r, Color::BLACK);
            }
            if self.has_picture {
                let px = c.px(r);
                match self.picture_slot {
                    Some(slot) => c.list.image(px, slot, [0.0, 0.0, 1.0, 1.0], Color::WHITE),
                    None => c.list.video(px, [0.0, 0.0, 1.0, 1.0]),
                }
            }
            if !self.model.overlays_hidden() {
                self.draw_overlays(c, r);
            }
            self.overlay.draw(c, r, &t);
            self.layer_overlay.draw(c, r, &t);
            self.draw_text_tools(c);
            self.draw_picture_tools(c);
            self.draw_offline_card(c);
            self.draw_badges(c);
        }
        c.restore_gstate();
        self.draw_drop_target(c);
        let st = self.footer_state();
        let mut f = self.footer.clone();
        let duration_width = sq_draw::monitor::monitor_footer::MonitorFooter::duration_slot(
            c.size_of(&st.footer_duration_text(), 12.0, 0).width,
        );
        f.layout(self.footer.frame(), &st, duration_width);
        f.draw(c, &st, &t, &mut self.draw_cx);
        if let Some(e) = self.footer.timecode_edit() {
            let semibold = c.semibold();
            self.timecode_carets = MonitorFooter::timecode_carets(&e.string(), |s| c.size_of(s, 12.0, semibold).width);
        }
    }

    fn draw_program_empty(&mut self, c: &mut Canvas, title: Option<&str>, hint: &str, t: &DrawTheme) {
        // ProgramEmptyView: Pip (72 pt, the host draws him), 14 pt gap, the hint, 14 pt gap, the button, centered as one stack.
        let slot = self.slot;
        let hint = SQL10n::string(hint);
        let has_new_sequence =
            self.model.program_empty_state() == ProgramEmptyKind::NoSequence && self.model.wired.new_sequence;
        let shows_pip = self.model.mode == MonitorMode::Program && self.empty_mascot.is_some();
        let mut y = slot.mid_y() - if title.is_none() { 8.0 } else { 18.0 };
        self.empty_mascot_rect = CGRect::default();
        if shows_pip {
            let line_count = c.wrap(&hint, 220.0f64.min(slot.width - 48.0), 11.0).len();
            let total = Self::EMPTY_MASCOT_SIDE
                + 14.0
                + line_count as f64 * 16.0
                + if has_new_sequence { 14.0 + 24.0 } else { 0.0 };
            let top = (slot.mid_y() - total / 2.0).round();
            self.empty_mascot_rect = CGRect::new(
                (slot.mid_x() - Self::EMPTY_MASCOT_SIDE / 2.0).round(),
                top.max(slot.min_y() + 4.0),
                Self::EMPTY_MASCOT_SIDE,
                Self::EMPTY_MASCOT_SIDE,
            );
            if let Some(m) = &self.empty_mascot {
                m(c, self.empty_mascot_rect);
            }
            y = self.empty_mascot_rect.max_y() + 14.0;
        }
        if let Some(title) = title {
            c.draw_text_in(
                title,
                CGRect::new(slot.min_x(), y, slot.width, 18.0),
                13.0,
                t.on_viewer().label2(),
                TextAlign::Center,
                0.0,
                0,
            );
            y += 20.0;
        }
        for line in c.wrap(&hint, 220.0f64.min(slot.width - 48.0), 11.0) {
            c.draw_text_in(
                &line,
                CGRect::new(slot.min_x(), y, slot.width, 16.0),
                11.0,
                t.on_viewer().label3(),
                TextAlign::Center,
                0.0,
                0,
            );
            y += 16.0;
        }
        // ProgramEmptyView: the large "New Sequence..." button under the hint while no sequence is open.
        if has_new_sequence {
            let title = "New Sequence…";
            let w = InspectorDraw::button_width(c, title);
            self.new_sequence_rect = CGRect::new((slot.mid_x() - w / 2.0).round(), y + 14.0, w, 24.0);
            InspectorDraw::button(
                c,
                title,
                self.new_sequence_rect,
                self.new_sequence_hover,
                self.new_sequence_pressed,
                true,
                false,
                24.0,
                t,
            );
        }
    }

    /// v9 header: title, the content popup, then at the right the zone (while on), Zoom, Quality and "...". Flat popups:
    /// text and chevron, a fill only on hover.
    /// The least width the content popup keeps before the other header popups give way.
    const CONTENT_MIN_WIDTH: f64 = 56.0;

    fn draw_header(&mut self, c: &mut Canvas) {
        let t = self.theme;
        let body = 11.0;
        let boxed = 24.0;
        let pad = spacing::MD as f64;
        let mid_y = self.header_rect.mid_y();
        // The active mark of a panel with a header of its own: the 2 pt line at the header's bottom, accent while the
        // monitor has focus, quiet gray otherwise. With Program | Source tabs the header is the dock's tab strip: a 1 pt
        // separator and the line only under the selected tab, drawn by `draw_title_or_tabs`.
        if self.tabs.is_empty() {
            c.fill_rounded(
                Self::active_line_rect(self.header_rect),
                Self::ACTIVE_LINE_THICKNESS / 2.0,
                if self.is_focused { t.accent() } else { t.label3() },
            );
        } else {
            c.fill(
                CGRect::new(self.header_rect.min_x(), self.header_rect.max_y() - 1.0, self.header_rect.width, 1.0),
                t.separator(),
            );
        }
        let title_w = self.draw_title_or_tabs(c, self.header_rect.min_x() + pad, body);
        self.header_controls = Vec::new();
        let popup_width = |c: &Canvas, s: &str| (c.size_of(s, body, 0).width + 8.0 + 10.0 + 8.0 + 4.0).ceil();
        let mut right = self.header_rect.max_x() - pad;
        let mut controls: Vec<(HeaderControl, CGRect, Option<String>)> = Vec::new();
        right -= boxed;
        controls.push((HeaderControl::Options, CGRect::new(right, mid_y - boxed / 2.0, boxed, boxed), None));
        let shows_tools = if self.model.mode == MonitorMode::Source {
            self.model.viewer_mode != crate::monitor_drop_indicator::SourceViewerMode::Waveform
        } else {
            self.model.has_sequence
        };
        let content_text: Option<String> = if self.model.mode == MonitorMode::Source {
            Some(MonitorMenus::source_title(&self.model.source_items, self.model.source_current))
        } else if self.model.has_sequence {
            Some(MonitorMenus::program_title(
                &self.model.sequence_items,
                self.model.sequence_current,
                &self.model.sequence_name,
                &self.model.format_items,
                self.model.format_current,
            ))
        } else {
            None
        };
        // The header never lays a popup over the tabs: the popups left of "..." need room right of the tabs, and the content
        // popup keeps a short share of it first. A popup without room is left out; Zoom and Quality stay in the "..." menu.
        let min_x = self.header_rect.min_x() + pad + title_w + spacing::SM as f64;
        let xs = spacing::XS as f64;
        // The content popup keeps room for its first word whole (a name is never cut to `Sequen...`), else it is left out.
        let content_floor = |c: &Canvas, t: &str| {
            let first = t.split_whitespace().next().unwrap_or(t);
            popup_width(c, t).min(popup_width(c, first).max(Self::CONTENT_MIN_WIDTH))
        };
        let content_share = content_text.as_ref().map_or(0.0, |t| content_floor(c, t) + xs);
        let fold = |right: &mut f64, w: f64| -> bool {
            if *right - w - xs - content_share < min_x {
                return false;
            }
            *right -= w + xs;
            true
        };
        if shows_tools {
            for (ctl, text) in [
                (HeaderControl::Quality, self.model.quality_badge_text()),
                (HeaderControl::Zoom, self.model.badge_text()),
            ] {
                let w = popup_width(c, &text);
                if fold(&mut right, w) {
                    controls.push((ctl, CGRect::new(right, mid_y - boxed / 2.0, w, boxed), Some(text)));
                }
            }
        }
        if self.model.mode == MonitorMode::Program
            && self.model.safe_zone() != crate::safe_zone_choice::SafeZoneChoice::Off
        {
            let text = self.model.safe_zone().badge_title().to_string();
            let w = popup_width(c, &text);
            if fold(&mut right, w) {
                controls.push((HeaderControl::Zone, CGRect::new(right, mid_y - boxed / 2.0, w, boxed), Some(text)));
            }
        }
        if let Some(text) = content_text {
            // The Mac strip lays the content popup right-aligned, next to Zoom and Quality (not after the tabs).
            let natural = popup_width(c, &text);
            let w = natural.min(right - xs - min_x);
            if w >= content_floor(c, &text) {
                controls.push((
                    HeaderControl::Content,
                    CGRect::new(right - xs - w, mid_y - boxed / 2.0, w, boxed),
                    Some(text),
                ));
            }
        }
        for (ctl, r, text) in controls {
            self.header_controls.push((ctl, r));
            c.stone_button(
                r,
                ButtonKind::Quiet,
                Touch { hovering: self.hovered_control == Some(ctl), ..Touch::default() },
                &t,
            );
            let Some(text) = text else {
                c.draw_icon(SQIcon::Ellipsis, CGPoint::new(r.mid_x() - 7.0, r.mid_y() - 7.0), 14.0, t.label2(), None);
                continue;
            };
            let enabled = ctl != HeaderControl::Content
                || self.model.mode == MonitorMode::Program
                || !self.model.source_items.is_empty();
            // 8 pt inset on the left, the chevron's 18 pt on the right: a long name ends in an ellipsis, not at the chevron.
            let shown = c.ellipsized(&text, body, 0, r.width - 8.0 - 18.0);
            c.draw_text_in(&shown, r, body, if enabled { t.label() } else { t.label3() }, TextAlign::Left, 8.0, 0);
            c.draw_icon(
                SQIcon::ChevronDown,
                CGPoint::new(r.max_x() - 8.0 - 10.0, r.mid_y() - 5.0),
                10.0,
                t.label3(),
                None,
            );
        }
    }

    /// The "Media offline" card (AppKit `MonitorPanelView.offlineCard`): centered on the slot, HUD fill, 12 pt title over
    /// the 10 pt "<file> was moved or renamed", 16 pt side and 6 pt top/bottom padding, at most the slot less 16 pt a side.
    /// `None` while the model names no offline file.
    pub fn offline_card_rect(&self, title_width: f64, detail_width: f64) -> Option<CGRect> {
        self.model.offline_card_detail()?;
        let side = spacing::LG as f64;
        // Never wider than the picture it explains (an 8K clip in a small monitor shows a narrow picture), but not so
        // narrow that the title is cut; the slot less its margins always caps it.
        let slot_max = self.slot.width - side * 2.0;
        let pic =
            if self.canvas_rect.width > 0.0 { self.canvas_rect.width.min(self.slot.width) } else { self.slot.width };
        let max_w = (pic - side).max(Self::OFFLINE_CARD_MIN_WIDTH).min(slot_max);
        let w = (title_width.max(detail_width) + side * 2.0).min(max_w);
        let h = Self::OFFLINE_CARD_HEIGHT;
        Some(CGRect::new((self.slot.mid_x() - w / 2.0).round(), (self.slot.mid_y() - h / 2.0).round(), w, h))
    }

    /// 6 + 15 (12 pt line) + 4 + 13 (10 pt line) + 6.
    pub(crate) const OFFLINE_CARD_HEIGHT: f64 = 44.0;
    /// The narrowest the card gets beside a small picture.
    pub(crate) const OFFLINE_CARD_MIN_WIDTH: f64 = 120.0;

    fn draw_offline_card(&self, c: &mut Canvas) {
        let t = self.theme;
        let title = self.model.offline_card_title();
        let detail = self.model.offline_card_detail().unwrap_or_default();
        let dw = c.size_of(&detail, 10.0, 0).width;
        let semibold = c.semibold();
        let Some(r) = self.offline_card_rect(c.size_of(&title, 12.0, semibold).width, dw) else { return };
        c.fill_rounded(r, radius::CONTROL as f64, t.viewer_hud());
        let side = spacing::LG as f64;
        let inner = r.inset_by(side, 0.0);
        c.draw_text_in(
            &title,
            CGRect::new(inner.min_x(), r.min_y() + 6.0, inner.width, 15.0),
            12.0,
            Color::WHITE.with_alpha(0.92),
            TextAlign::Center,
            0.0,
            semibold,
        );
        c.save_gstate();
        c.clip_to(inner);
        // The file name gives way (cut at a word boundary with an ellipsis); " was moved or renamed" always stays.
        let detail = self.model.offline_card_detail_fitted(inner.width, |t| c.size_of(t, 10.0, 0).width);
        let dw = c.size_of(&detail, 10.0, 0).width;
        c.draw_text_in(
            &detail,
            CGRect::new(inner.min_x(), r.min_y() + 25.0, inner.width, 13.0),
            10.0,
            Color::WHITE.with_alpha(0.6),
            if dw > inner.width { TextAlign::Left } else { TextAlign::Center },
            0.0,
            0,
        );
        c.restore_gstate();
    }

    /// MonitorPanelView.setDropHighlight / showDropZone: drop tint and focus ring over the card, and the Program half under
    /// the pointer with its action name.
    fn draw_drop_target(&self, c: &mut Canvas) {
        if !self.drop_highlight {
            return;
        }
        let t = self.theme;
        c.fill(self.frame, t.accent().with_alpha(0.10));
        if self.model.mode == MonitorMode::Program
            && let Some(zone) = self.drop_zone
        {
            let r = zone
                .rect(CGSize::new(self.frame.width, self.frame.height))
                .offset_by(self.frame.min_x(), self.frame.min_y());
            c.fill(r, t.accent().with_alpha(0.10));
            c.draw_text_in(zone.title(), r, 11.0, t.label(), TextAlign::Center, 0.0, 0);
        }
        c.stroke_rounded(self.frame.inset_by(0.5, 0.5), t.panel_radius(), 1.0, t.accent().with_alpha(0.55));
    }

    /// Drop dot (bottom left), loudness readout, scrub latency (top left) and resolution badge (bottom right) on the slot.
    fn draw_badges(&self, c: &mut Canvas) {
        let t = self.theme;
        let slot = self.slot;
        let inset = spacing::SM as f64;
        let h14 = 14.0;
        if let Some(latency) = &self.model.latency_text {
            let s = format!(" {latency} ");
            let w = c.size_of(&s, 10.0, 0).width;
            let r = CGRect::new(slot.min_x() + 10.0, slot.min_y() + 10.0, w, h14);
            c.fill(r, t.viewer_hud());
            c.draw_text_in(&s, r, 10.0, t.label2(), TextAlign::Left, 0.0, 0);
        }
        if let Some(reading) = &self.loudness
            && let Some(text) = LoudnessReadout::text(reading)
        {
            let over = LoudnessReadout::is_over(reading, &self.loudness_target);
            let s = format!(" {text} ");
            let w = c.size_of(&s, 10.0, 0).width;
            // The Mac label shares the corner with the drop dot; here it sits right of the dot so both stay readable.
            let dot = if self.model.mode == MonitorMode::Program && self.model.drop_indicator_enabled {
                14.0 + 4.0
            } else {
                0.0
            };
            let r = CGRect::new(slot.min_x() + inset + dot, slot.max_y() - inset - h14, w, h14);
            c.fill(r, t.viewer_hud());
            c.draw_text_in(&s, r, 10.0, if over { t.yellow() } else { t.label2() }, TextAlign::Left, 0.0, 0);
        }
        if self.model.mode == MonitorMode::Program && self.model.drop_indicator_enabled {
            let size = 14.0;
            let d = 6.0;
            let o = CGPoint::new(slot.min_x() + inset, slot.max_y() - inset - size);
            let warning = Self::color(t.palette.warning);
            c.fill_ellipse(
                CGRect::new(o.x + (size - d) / 2.0, o.y + (size - d) / 2.0, d, d),
                if self.model.drop_amber() || self.model.drop_realtime_not_achieved() {
                    warning
                } else {
                    t.label3().with_alpha(0.5)
                },
            );
            if let Some(text) = self.model.drop_badge_text() {
                c.draw_text_in(
                    text,
                    CGRect::new(o.x + size, o.y, 200.0, size),
                    10.0,
                    if self.model.drop_realtime_not_achieved() { warning } else { t.label2() },
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
        }
        if let Some(text) = self.model.resolution_badge_text() {
            let s = format!(" {text} ");
            let w = c.size_of(&s, 10.0, 0).width;
            let h = 14.0;
            let r = CGRect::new(slot.max_x() - inset - w, slot.max_y() - inset - h, w, h);
            c.fill(r, t.viewer_hud());
            c.draw_text_in(&s, r, 10.0, t.label2(), TextAlign::Left, 0.0, 0);
        }
    }

    /// The Transparency Grid behind a picture with alpha (Program monitor option).
    pub fn shows_checkerboard(&self) -> bool {
        self.model.mode == MonitorMode::Program && self.model.shows_transparency_grid() && self.picture_has_alpha
    }

    /// 8 pt squares over `r` in the color picker's checker grays.
    pub(crate) fn draw_checkerboard(&self, c: &mut Canvas, r: CGRect) {
        let cell = 8.0;
        c.fill(r, DrawTheme::CHECKER_DARK);
        c.save_gstate();
        c.clip_to(r);
        let mut y = r.min_y();
        let mut row = 0;
        while y < r.max_y() {
            let mut x = r.min_x() + if row % 2 == 0 { cell } else { 0.0 };
            while x < r.max_x() {
                c.fill(CGRect::new(x, y, cell, cell), DrawTheme::CHECKER_LIGHT);
                x += cell * 2.0;
            }
            y += cell;
            row += 1;
        }
        c.restore_gstate();
    }

    /// A palette color as a draw color.
    pub(crate) fn color(p: sq_uikit::appearance_palette::PaletteColor) -> Color {
        Color::new((p.r / 255.0) as f32, (p.g / 255.0) as f32, (p.b / 255.0) as f32, p.a as f32)
    }

    // MARK: Input

    /// True when the event was the monitor's. Moves are never kept (other panels clear their hover).
    pub fn handle_event(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        self.now = cx.ui.now;
        let k = self.scale as f64;
        let pt = |x: f32, y: f32| CGPoint::new(x as f64 / k, y as f64 / k);
        let taken = match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                self.overlay.modifiers_now = Some(modifiers);
                self.mouse_down(pt(x, y), modifiers, cx)
            }
            InputEvent::MouseDragged { x, y, modifiers } => {
                // The overlay and the create / zoom drags read the live keys (Swift `overlay.modifiersNow`).
                self.overlay.modifiers_now = Some(modifiers);
                self.mouse_dragged(pt(x, y), x, y, cx)
            }
            InputEvent::MouseUp { x, y } => self.mouse_up(pt(x, y), x, y, cx),
            InputEvent::MouseMoved { x, y } => {
                self.mouse_moved(pt(x, y), cx);
                false
            }
            InputEvent::Scroll { x, y, dx, dy, modifiers } => self.scroll(pt(x, y), dx, dy, modifiers, cx),
            InputEvent::KeyDown { key, modifiers } => self.key_down(key, modifiers, cx),
        };
        self.pump(cx.session);
        taken
    }

    fn mouse_down(&mut self, p: CGPoint, mods: InputModifiers, cx: &mut HostCx) -> bool {
        if !self.frame.contains(p) {
            return false;
        }
        let right = mods.contains(InputModifiers::SECONDARY);
        if !right && self.new_sequence_rect.contains(p) {
            self.new_sequence_pressed = true;
            return true;
        }
        if !right
            && let Some(h) = self.footer.stream_handle_at(p)
            && self.begin_source_drag_press(h, p)
        {
            return true;
        }
        if self.footer.frame().contains(p) {
            self.press_in_footer = !right;
            let carets = self.timecode_carets.clone();
            let st = self.footer_state();
            let caret = move |x: f64| MonitorFooter::caret_index(x, &carets);
            let events = self.footer.mouse_down(p, &st, right, Some(&caret));
            self.apply(events, cx);
            return true;
        }
        if !right && let Some(i) = self.tab_at(p) {
            if i != self.selected_tab {
                self.events.push(PanelEvent::SelectTab(i));
            }
            return true;
        }
        if let Some((ctl, r)) = self.header_controls.iter().find(|(_, r)| r.contains(p)).copied() {
            if !right {
                self.open_header(ctl, r);
            }
            return true;
        }
        if self.slot.contains(p) {
            if right {
                if !self.model.context_menu.is_empty() {
                    self.events.push(PanelEvent::Menu {
                        items: self.model.context_menu.clone(),
                        anchor: CGRect::new(p.x, p.y, 0.0, 0.0),
                        pointer: Some(p),
                    });
                }
            } else if self.shows_waveform() {
                let mr = self.wave_meter_rect();
                if mr.contains(p) {
                    let hit = CGPoint::new(p.x - mr.min_x(), p.y - mr.min_y());
                    if self.wave_meter.click(hit, mr.height, mods.contains(InputModifiers::OPTION)) {
                        self.events.push(PanelEvent::WaveChannelMonitorChange(self.wave_meter.channel_monitor()));
                    }
                    return true;
                }
                self.press_in_wave = true;
                self.scrub_waveform(true, p);
            } else if self.model.mode == MonitorMode::Program && self.hand_tool_on {
                self.begin_hand_press(p);
                if self.hand_last.is_some() {
                    cx.ui.hover.request(Some(DrawCursor::ClosedHand));
                }
            } else if self.text_field.is_editing() && self.text_field.mouse_down(p, mods, self.canvas_rect) {
                // the caret moved inside the open text field (a press outside ended it and goes on below)
            } else if self.begin_picture_tool_press(p, mods, cx) {
                // Dynamic Zoom / Step window editor, the angle tiles, the Create tool or a caption took it
            } else if self.guide_target(p).is_some() {
                self.begin_guide_drag(p); // rulers and guides first, then the transform box, then the picture
            } else if self.model.mode == MonitorMode::Source
                && self.begin_source_drag_press(sq_core_edit::timeline_source_edit::SourceStreams::Both, p)
            {
                // the Source picture is the Video and Audio drag source (StreamDragView over the viewer)
            } else if self.begin_text_press(p) {
                // Type tool press, or the second press of a double-click on the picture
            } else if self.overlay.mask_tool.is_none()
                && !self.text_field.is_editing()
                && self.layer_overlay.mouse_down(cx.session, p, mods, self.canvas_rect)
            {
                // a layer of the selected graphic, its handle, or the empty canvas while layers are selected
            } else if !self.overlay.mouse_down(p, mods, self.canvas_rect)
                && let Some(pos) =
                    self.mapping().click_position(CGPoint::new(p.x - self.slot.min_x(), p.y - self.slot.min_y()))
            {
                self.events.push(PanelEvent::PickClip(pos));
            }
            self.request_drag_cursor(cx);
        }
        true
    }

    fn mouse_dragged(&mut self, p: CGPoint, x: f32, y: f32, cx: &mut HostCx) -> bool {
        if self.picture_tool_dragging() {
            self.picture_tool_dragged(p, cx);
            self.request_drag_cursor(cx);
            return true;
        }
        if self.overlay.is_dragging() {
            self.overlay.mouse_dragged(p);
            self.request_drag_cursor(cx);
            return true;
        }
        if let Some(last) = self.hand_last {
            self.hand_last = Some(p);
            cx.ui.hover.request(Some(DrawCursor::ClosedHand));
            let z = self.mapping().panned(CGSize::new(p.x - last.x, p.y - last.y));
            self.zoom_gesture(z);
            return true;
        }
        if self.layer_overlay.is_dragging() {
            let now = self.overlay.modifiers_now;
            self.layer_overlay.mouse_dragged(cx.session, p, now);
            self.request_drag_cursor(cx);
            return true;
        }
        if self.source_drag.is_some() {
            self.source_drag_moved(p, x, y);
            return true;
        }
        if let Some(press) = &mut self.type_press {
            press.1 = p;
            return true;
        }
        if self.press_in_wave {
            self.scrub_waveform(false, p);
            return true;
        }
        if self.active_guide.is_some() {
            self.drag_guide(p);
            return true;
        }
        if !self.press_in_footer {
            return false;
        }
        let st = self.footer_state();
        let events = self.footer.mouse_dragged(p, &st);
        self.apply(events, cx);
        true
    }

    fn mouse_up(&mut self, p: CGPoint, x: f32, y: f32, cx: &mut HostCx) -> bool {
        let taken = self.mouse_up_inner(p, x, y, cx);
        self.request_hover_cursor(p, cx);
        taken
    }

    fn mouse_up_inner(&mut self, p: CGPoint, x: f32, y: f32, cx: &mut HostCx) -> bool {
        if self.new_sequence_pressed {
            self.new_sequence_pressed = false;
            if self.new_sequence_rect.contains(p) {
                self.model.emit(MonitorEvent::NewSequence);
            }
            return true;
        }
        if self.picture_tool_dragging() {
            self.picture_tool_ended(p, cx);
            return true;
        }
        if self.overlay.is_dragging() {
            self.overlay.mouse_up(p);
            return true;
        }
        if self.hand_last.is_some() {
            self.hand_last = None;
            return true;
        }
        if self.layer_overlay.is_dragging() {
            self.layer_overlay.mouse_up(cx.session);
            return true;
        }
        if self.source_drag.is_some() {
            self.source_drag_ended(x, y, false);
            return true;
        }
        if self.type_press.is_some() {
            self.end_type_press(p);
            return true;
        }
        if self.press_in_wave {
            self.press_in_wave = false;
            self.model.emit(MonitorEvent::ScrubEnded);
            return true;
        }
        if self.active_guide.is_some() {
            self.end_guide_drag(p);
            return true;
        }
        if !self.press_in_footer {
            return false;
        }
        self.press_in_footer = false;
        let st = self.footer_state();
        let events = self.footer.mouse_up(p, &st);
        self.apply(events, cx);
        true
    }

    fn mouse_moved(&mut self, p: CGPoint, cx: &mut HostCx) {
        self.footer.mouse_moved(p);
        self.new_sequence_hover = self.new_sequence_rect.contains(p);
        if let Some(a) = self.footer.hovered
            && let Some(title) = a.button_title(self.model.is_playing)
        {
            cx.ui.hover.offer_tip(Some(&a.tip(title, &self.key_map)));
        }
        self.hovered_control = self.header_controls.iter().find(|(_, r)| r.contains(p)).map(|(c, _)| *c);
        if let Some(ctl) = self.hovered_control {
            cx.ui.hover.offer_tip(Some(&self.header_tip(ctl)));
        }
        self.angle_hover =
            if self.shows_angles_grid() { AnglesGridLayout::index(p, &self.angle_cells()) } else { None };
        self.last_pointer = Some(p);
        self.pointer_sequence_position = if self.slot.contains(p) {
            self.mapping().click_position(CGPoint::new(p.x - self.slot.min_x(), p.y - self.slot.min_y()))
        } else {
            None
        };
        if !self.overlay.is_dragging() {
            let r = self.canvas_rect;
            self.overlay.pointer_moved(p, r);
        }
        self.request_hover_cursor(p, cx);
    }

    fn scroll(&mut self, p: CGPoint, dx: f32, dy: f32, mods: InputModifiers, cx: &mut HostCx) -> bool {
        if !self.frame.contains(p) {
            return false;
        }
        if !self.slot.contains(p) || self.empty_text().is_some() {
            return true;
        }
        let local = CGPoint::new(p.x - self.slot.min_x(), p.y - self.slot.min_y());
        // ProgramSurfaceView.scrollWheel / magnify with the AppKit deltas: a wheel line counts 8 trackpad points.
        let g = cx.ui.gesture_or_wheel(dx, dy);
        match g.kind {
            GestureKind::Magnify(m) => {
                let z = self.mapping().zoomed(1.0 + m, local);
                self.zoom_gesture(z);
            }
            GestureKind::SmartMagnify => {}
            GestureKind::Scroll => {
                let k = if g.precise { 1.0 } else { 8.0 };
                if mods.contains(InputModifiers::COMMAND) || mods.contains(InputModifiers::OPTION) {
                    // Cmd / Option + scroll zooms about the pointer (Ctrl / Alt on Windows).
                    let z = self.mapping().zoomed((g.delta_y * k * 0.01).exp(), local);
                    self.zoom_gesture(z);
                } else if !self.viewer_zoom.is_fit() {
                    // nothing to pan at Fit
                    let z = self.mapping().panned(CGSize::new(g.delta_x * k, g.delta_y * k));
                    self.zoom_gesture(z);
                }
            }
        }
        true
    }

    fn key_down(&mut self, key: InputKey, mods: InputModifiers, cx: &mut HostCx) -> bool {
        if self.text_field.is_editing() {
            return self.text_field.key(key, mods, cx.ui);
        }
        if let Some(events) = self.footer.timecode_key(key, mods, cx.ui) {
            self.apply(events, cx);
            return true;
        }
        if self.picture_tool_key(key, mods, cx) {
            return true;
        }
        if key == InputKey::Escape && self.type_press.is_some() {
            self.type_press = None;
            return true;
        }
        if key == InputKey::Escape && self.active_source_drag().is_some() {
            self.source_drag_ended(0.0, 0.0, true);
            return true;
        }
        key == InputKey::Escape && self.overlay.cancel_drag()
    }

    /// The shape the picture asks for at `p` while no drag runs (Hand, Create, layer handles, transform box).
    pub(crate) fn request_hover_cursor(&self, p: CGPoint, cx: &mut HostCx) {
        let hover = &mut cx.ui.hover;
        if self.model.mode == MonitorMode::Program && self.hand_tool_on && self.slot.contains(p) {
            hover.request(Some(if self.hand_last.is_some() { DrawCursor::ClosedHand } else { DrawCursor::OpenHand }));
        } else if let Some(c) = (!self.overlay.is_dragging()
            && !self.layer_overlay.is_dragging()
            && self.overlay.mask_tool.is_none()
            && !self.text_field.is_editing())
        .then(|| self.layer_overlay.hover_cursor(p, self.canvas_rect))
        .flatten()
        {
            hover.request(Some(c));
        } else if let Some(c) =
            (!self.overlay.is_dragging()).then(|| self.overlay.hover_cursor(p, self.canvas_rect)).flatten()
        {
            hover.request(Some(c));
        } else if self.model.mode == MonitorMode::Program
            && self.slot.contains(p)
            && self.create_mode_now.is_some_and(|m| m != CreateToolMode::Text)
            && !self.overlay.is_dragging()
        {
            hover.request(Some(DrawCursor::Crosshair)); // Create tool: shapes, lines and strokes (resetCursorRects)
        }
    }

    /// A press or drag keeps the shape of what it holds (the hover forgets it on every drag event).
    pub(crate) fn request_drag_cursor(&self, cx: &mut HostCx) {
        if self.overlay.is_dragging() {
            cx.ui.hover.request(self.overlay.drag_cursor());
        } else if self.create_drag.is_some() {
            cx.ui.hover.request(Some(DrawCursor::Crosshair));
        }
    }

    /// A wheel zoom or pan: show it, put its value in the zoom popup without reporting it back.
    pub fn zoom_gesture(&mut self, v: ViewerZoom) {
        self.viewer_zoom = v;
        match v {
            ViewerZoom::Fit => self.model.display_zoom(MonitorZoom::Fit),
            ViewerZoom::Percent(p) => self.model.display_zoom(MonitorZoom::Percent(p)),
            ViewerZoom::View { scale, .. } => {
                self.model.display_zoom(MonitorZoom::Custom((scale * 100.0).round() as i64))
            }
        }
        self.shown_model_zoom = self.model.zoom();
        let m = Self::viewer_margin(self.viewer_zoom);
        let pic = CGRect::new(
            self.frame.min_x(),
            self.header_rect.max_y(),
            self.frame.width,
            (self.footer.frame().min_y() - self.header_rect.max_y()).max(0.0),
        );
        self.slot = pic.inset_by(m.min(pic.width / 2.0), m.min(pic.height / 2.0));
        let mapping = self.mapping();
        self.canvas_rect = mapping.canvas_rect().offset_by(self.slot.min_x(), self.slot.min_y());
        self.events.push(PanelEvent::ZoomGesture(v));
    }

    /// Rows of a header popup.
    pub fn header_items(&self, ctl: HeaderControl) -> Vec<SQMenuItem> {
        let m = &self.model;
        match ctl {
            HeaderControl::Content => {
                if m.mode == MonitorMode::Source {
                    return MonitorMenus::source_items(
                        &m.source_items,
                        m.source_current,
                        m.event_sink(MonitorEvent::PickSource),
                        m.event_action(MonitorEvent::CloseSource),
                        m.event_action(MonitorEvent::CloseAllSources),
                    );
                }
                // Sequences first, then the shown sequence's frame formats (its variants), so they are one click away.
                let mut rows = MonitorMenus::sequence_items(
                    &m.sequence_items,
                    m.sequence_current,
                    m.event_sink(MonitorEvent::PickSequence),
                );
                rows.push(SQMenuItem::separator());
                rows.extend(m.format_menu());
                rows
            }
            HeaderControl::Zone => m.safe_zone_menu(),
            HeaderControl::Zoom => m.zoom_menu(),
            HeaderControl::Quality => m.quality_menu(),
            HeaderControl::Options => m.option_items(Vec::new()),
        }
    }

    /// Go to Timecode (the Mac `focusTimecodeField`): opens the footer's timecode with its text selected; Return
    /// commits, Esc or a press elsewhere puts the time back.
    pub fn focus_timecode_field(&mut self) {
        let st = self.footer_state();
        self.footer.begin_timecode_edit(&st);
    }

    /// The timecode field is open.
    pub fn is_editing_timecode(&self) -> bool {
        self.footer.is_editing_timecode()
    }

    /// Ends the field's edit without seeking (a press outside the monitor).
    pub fn end_timecode_edit(&mut self) {
        self.footer.end_timecode_edit();
    }

    fn open_header(&mut self, ctl: HeaderControl, r: CGRect) {
        let items = self.header_items(ctl);
        if !items.is_empty() {
            self.events.push(PanelEvent::Menu { items, anchor: r, pointer: None });
        }
    }

    /// Footer events as model calls (MonitorScrubBar and the transport buttons on the Mac).
    fn apply(&mut self, events: Vec<MonitorFooterEvent>, cx: &mut HostCx) {
        for ev in events {
            match ev {
                MonitorFooterEvent::Action(a) => self.model.perform(a),
                MonitorFooterEvent::ScrubBegan => self.model.emit(MonitorEvent::ScrubBegan),
                MonitorFooterEvent::Scrub(t) => self.scrub(t),
                MonitorFooterEvent::ScrubEnded => self.model.emit(MonitorEvent::ScrubEnded),
                MonitorFooterEvent::PreviewMark(h, t) => self.model.preview_mark(h, t),
                MonitorFooterEvent::CommitMark(h) => self.model.commit_mark(h),
                MonitorFooterEvent::CommitTimecode(typed) => {
                    // `MonitorPanelView.commitTimecode`: a rejected text keeps the time and shows the hint.
                    if !self.model.commit_timecode_text(&typed) {
                        let hint = MonitorPanelModel::timecode_hint(&typed);
                        if !hint.is_empty() {
                            cx.emit(AppEvent::Status(SQL10n::string(&hint)));
                        }
                    }
                }
                MonitorFooterEvent::MarkMenu { x, y } => {
                    let p = CGPoint::new(x, y);
                    self.events.push(PanelEvent::Menu {
                        items: self.model.mark_menu(),
                        anchor: CGRect::new(p.x, p.y, 0.0, 0.0),
                        pointer: Some(p),
                    });
                }
            }
        }
    }

    /// A scrub step: `Scrub` while the owner wired it, else a plain `Seek`.
    pub(crate) fn scrub(&mut self, t: Time) {
        if self.model.wired.scrub {
            self.model.emit(MonitorEvent::Scrub(t));
        } else {
            self.model.emit(MonitorEvent::Seek(t));
        }
    }

    /// Applies what menu rows queued and the format popups asked of the session; the owner calls it after a menu row ran
    /// (`handle` does it after every event).
    pub fn pump(&mut self, session: &mut EditorSession) {
        self.model.apply_menu_commands();
        if self.model.mode == MonitorMode::Program {
            self.model.apply_format_events(session);
        }
    }

    // MARK: Tips

    /// The tip of a header control (`MonitorPanelView` setup).
    pub fn header_tip(&self, ctl: HeaderControl) -> String {
        match ctl {
            HeaderControl::Content => {
                SQL10n::string(if self.model.mode == MonitorMode::Source { "Source Clips" } else { "Open Sequences" })
            }
            HeaderControl::Zone => SQL10n::string("Platform Safe Zone"),
            HeaderControl::Zoom => SQL10n::string("Zoom: Fit, or 10 to 800 %"),
            HeaderControl::Quality => SQL10n::string("Playback Quality"),
            HeaderControl::Options => SQL10n::string("More"),
        }
    }

    /// The tip of the header control at `p` (panel points), `None` off the controls.
    pub fn header_tip_at(&self, p: CGPoint) -> Option<String> {
        self.header_controls.iter().find(|(_, r)| r.contains(p)).map(|(c, _)| self.header_tip(*c))
    }

    pub(crate) fn guide_axis_fraction(&self, axis: Axis, p: CGPoint) -> f64 {
        let r = self.canvas_rect;
        if axis == Axis::Vertical {
            (p.x - r.min_x()) / r.width.max(1.0)
        } else {
            (p.y - r.min_y()) / r.height.max(1.0)
        }
    }
}

impl AppHost for MonitorPanel {
    fn sync(&mut self, session: &EditorSession) {
        self.model.apply_menu_commands();
        if self.model.mode == MonitorMode::Program {
            self.model.sync_formats(session);
            self.model.sync_transport(session);
            // The strip shows the sequence's In and Out (Swift `MonitorHost.syncSequence`); a grip being dragged keeps its preview.
            if !self.footer.gesture().is_active() {
                self.model.sync_marks(session);
            }
        }
        self.layer_overlay.refresh(session);
    }

    fn layout(&mut self, frame: CGRect, _cx: &mut HostCx) {
        self.layout_frame(frame);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, _cx: &mut HostCx) {
        self.draw_card(c, t);
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        self.handle_event(e, cx)
    }
}

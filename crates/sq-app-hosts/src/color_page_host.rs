// Swift: SQAppShell/ColorPageHost.swift
//! The Color page of the editing window: the Color settings, the Steps graph, the Sources strip, the viewer header above
//! the Program monitor and the Scopes card, all driven by one [`ColorGradeController`]. The Edit | Color switch itself is
//! in the title row; this host reacts to the page the dock shows. Edits go through the controller into the session, so
//! each is one undo step as on the Swift side.

use crate::MonitorPicture;
use crate::analysis_links::eyedropper::Eyedropper;
use crate::poster_pump::{PosterPump, SharedAtlas};
use crate::project_services::FfmpegPosters;
use sq_app_shell::{ATLAS_SLOT, AppEvent, HostCx, ImageUpload};
use sq_core_color::color_decision_import;
use sq_core_time::{Id, IdSource, SequentialIds};
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey, InputModifiers};
use sq_draw_monitor::scopes_panel::{ScopeSource, ScopesPanel};
use sq_draw_shell::ShellDock;
use sq_editor_session::{Change, ColorClipboard, EditorSession, WorkspacePage};
use sq_inspector_ui::color::color_grade_controller::{ColorGradeController, ColorGradeEvent, ColorMenuCommand};
use sq_inspector_ui::color::color_grade_draw::LutFilesFor;
use sq_inspector_ui::color::color_grade_draw::{ColorGradeDraw, ColorGradeHost, GradeFileRequest};
use sq_inspector_ui::color::color_grade_target::ColorSourceListCache;
use sq_inspector_ui::color::color_graph_menus::LUTTarget;
use sq_inspector_ui::color::color_inspector_model::LUTChoice;
use sq_inspector_ui::color::color_inspector_model_graph::GraphLUTSlot;
use sq_inspector_ui::color::color_sources_draw::{ColorSourcesDraw, ColorSourcesLayout, SourceThumbnail};
use sq_inspector_ui::color::color_steps_draw::{ColorStepsDraw, StepsHostRequest};
use sq_inspector_ui::color::color_viewer_header_draw::{
    ColorStripToolsDraw, ColorViewerHeaderDraw, StripDropdown, StripPanel,
};
use sq_library::lutlibrary::check_lut_file;
use sq_runtime::ModalAsk;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::design_tokens::sq_tokens::metrics;
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::task::{Context, Poll, Waker};

/// What a LUT chooser is for.
enum LutJob {
    Grade(sq_inspector_ui::color::color_grade_draw::LutFilesFor),
    /// A Steps menu's slot and the Step selected when it opened.
    Step(LUTTarget, Option<Id>),
}

/// The parts of the page that take the pointer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Part {
    Grade,
    Steps,
    Sources,
    Header,
    Scopes,
}

/// The panels of the Color page over one controller.
pub struct ColorPageHost {
    /// The LUT library with its listing (Swift `LUTLibraryStore.shared`); `None` = no folder (tests).
    luts: Option<(sq_library::lutlibrary::LUTLibrary, Vec<sq_library::lutlibrary::LUTEntry>)>,
    /// Built on the first layout: it needs the session.
    controller: Option<ColorGradeController>,
    clipboard: ColorClipboard,
    grade: ColorGradeDraw,
    steps: ColorStepsDraw,
    sources: ColorSourcesDraw,
    header: ColorViewerHeaderDraw,
    scopes: ScopesPanel,
    frames: BTreeMap<Part, CGRect>,
    /// The part with keyboard focus (the last one clicked).
    focus: Option<Part>,
    pressed: Option<Part>,
    on_color_page: bool,
    /// Menus the panels asked for, anchors in window points.
    menus: Vec<(Vec<SQMenuItem>, CGRect)>,
    strip_tools: ColorStripToolsDraw,
    /// The Before | After | Split strip above the Program monitor (Swift `ColorPageHost.showsViewerHeader`; the app sets
    /// it off, so does this host by default).
    pub shows_viewer_header: bool,
    /// The tab strips that show a Color panel, window points.
    strips: HashMap<StripPanel, CGRect>,
    /// The width the dock keeps free at the right end of each of those strips.
    tool_widths: HashMap<StripPanel, f64>,
    pressed_tool: Option<StripPanel>,
    /// The frames the Scopes measure.
    picture: Option<MonitorPicture>,
    /// Color decision choosers still open; the Step they are for.
    decisions: Vec<(ModalAsk<Option<PathBuf>>, Id)>,
    /// The Scopes show no picture.
    scopes_clear: bool,
    /// The Source monitor's frames (the Edit page's Scopes read them while the Source monitor is the active panel).
    source_picture: Option<MonitorPicture>,
    /// Which picture the Scopes measure now (`choose_scope_source`).
    scope_source: ScopeSource,
    /// The dropper shared with the monitor host, and the Step the white-balance pick was armed for (`key`, `effect`).
    eyedropper: Option<(Eyedropper, Option<(sq_core_time::Id, i64)>)>,
    /// The Program monitor card below the viewer header (the Split divider is cut to it).
    monitor_body: Option<CGRect>,
    /// The picture's canvas on the monitor and the sequence width (window points).
    picture_view: Option<(CGRect, f64)>,
    /// Poster frames of the Sources tiles, packed into the shared thumbnail atlas.
    posters: PosterPump,
    /// The Scopes' picture generation last handed to the renderer.
    scope_generation: u64,
    /// The Sources tiles' names as last drawn, for the accessibility nodes.
    source_names: Vec<String>,
    source_list: ColorSourceListCache,
}

/// The first of the two image slots of the Scopes' pictures (`DrawList::IMAGE_SLOTS`: 2-3 scopes).
const SCOPE_SLOT: usize = 2;

/// The monitor the Scopes measure: Source while the Source monitor is the active panel (and one exists), else Program.
/// The Scopes use the image slots 2-3 on both pages; only one Scopes card is ever drawn, so no slot is added.
pub(crate) fn choose_scope_source(focused: Option<PanelID>, has_source: bool) -> ScopeSource {
    if has_source && focused == Some(PanelID::SourceMonitor) { ScopeSource::Source } else { ScopeSource::Program }
}

/// Height of a Sources tile's poster in pixels.
const SOURCE_POSTER_HEIGHT: i64 = 144;

/// The Color panel a strip belongs to.
const STRIPS: [(StripPanel, PanelID); 4] = [
    (StripPanel::ColorInspector, PanelID::ColorInspector),
    (StripPanel::Steps, PanelID::Steps),
    (StripPanel::Sources, PanelID::ColorClips),
    // The Timeline's strip on the Color page, when it shares a group: its hint and Copy / Paste Grade.
    (StripPanel::Timeline, PanelID::Timeline),
];

impl Default for ColorPageHost {
    fn default() -> Self {
        ColorPageHost::new()
    }
}

/// sRGB component (0...1) to linear light.
fn srgb_to_linear(c: f64) -> f32 {
    (if c <= 0.040_45 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }) as f32
}

fn local(frame: CGRect, x: f32, y: f32, scale: f32) -> CGPoint {
    CGPoint::new(f64::from(x / scale) - frame.x, f64::from(y / scale) - frame.y)
}

/// The part under `p` (window points).
fn part_at(frames: &BTreeMap<Part, CGRect>, p: CGPoint) -> Option<Part> {
    [Part::Header, Part::Grade, Part::Steps, Part::Sources, Part::Scopes]
        .into_iter()
        .find(|part| frames.get(part).is_some_and(|f| f.contains(p)))
}

impl ColorPageHost {
    /// Shot poses of the Color page: `color-pro` shows the empty Pro page, `color-grade` starts a Pro grade from the
    /// Simple one (what the two buttons do). False when there is no controller yet or the name is not one of them.
    pub fn shot_pose(&mut self, name: &str, cx: &mut HostCx) -> bool {
        let Some(controller) = self.controller.as_mut() else { return false };
        let Some(m) = controller.model_mut() else { return false };
        match name {
            "color-pro" => m.set_shows_empty_pro(true),
            "color-grade" => m.start_from_simple(),
            _ => return false,
        }
        controller.pump(cx.session, &mut self.clipboard);
        self.pump(cx);
        true
    }

    /// A host with no controller yet.
    pub fn new() -> ColorPageHost {
        ColorPageHost {
            luts: None,
            controller: None,
            eyedropper: None,
            monitor_body: None,
            picture_view: None,
            clipboard: ColorClipboard::new(),
            grade: ColorGradeDraw::new(),
            steps: {
                let mut steps = ColorStepsDraw::new();
                steps.can_choose_lut_file = true;
                steps.can_import_decision = true;
                steps
            },
            sources: ColorSourcesDraw::new(),
            header: ColorViewerHeaderDraw::new(),
            scopes: ScopesPanel::new(),
            frames: BTreeMap::new(),
            focus: None,
            pressed: None,
            on_color_page: false,
            menus: Vec::new(),
            strip_tools: ColorStripToolsDraw::new(),
            shows_viewer_header: false,
            strips: HashMap::new(),
            tool_widths: HashMap::new(),
            pressed_tool: None,
            picture: None,
            decisions: Vec::new(),
            scopes_clear: false,
            source_picture: None,
            scope_source: ScopeSource::Program,
            posters: PosterPump::new(
                Arc::new(FfmpegPosters),
                Arc::new(crate::project_services::poster_pool(1)),
                SharedAtlas::default(),
            ),
            scope_generation: 0,
            source_names: Vec::new(),
            source_list: ColorSourceListCache::new(false),
        }
        .with_scope_slots()
    }

    /// Turns the white-balance eyedropper on: it samples the Program monitor picture through `eyedropper`.
    /// The LUT collection the Import LUTs row copies into and the LUT pop-ups list.
    pub fn with_lut_library(mut self, library: sq_library::lutlibrary::LUTLibrary) -> ColorPageHost {
        let entries = library.entries();
        self.luts = Some((library, entries));
        self
    }

    /// The LUT files of the library (what the Library's LUTs chip lists).
    pub fn lut_entries(&self) -> Vec<sq_library::lutlibrary::LUTEntry> {
        self.luts.as_ref().map(|(_, e)| e.clone()).unwrap_or_default()
    }

    /// Sets `path` as the Creative look of the first effect of the clip on the Color page, like picking it in the LUT
    /// popup. False when no clip is shown there.
    pub fn apply_look_lut(&mut self, path: &str) -> bool {
        use sq_inspector_ui::color::color_inspector_model::{ColorLUTSlot, LUTChoice};
        let Some(m) = self.controller.as_mut().and_then(|c| c.model_mut()) else { return false };
        let Some(effect) = m.effects().first().map(|e| e.id) else { return false };
        m.set_lut(effect, ColorLUTSlot::Look, Some(&LUTChoice::file(path)));
        true
    }

    /// Answers what the model asked of the library (import, star) and keeps the model's listing current.
    fn run_lut_events(&mut self, cx: &mut HostCx) {
        use sq_inspector_ui::color::color_inspector_model::ColorInspectorEvent as E;
        let (Some((library, entries)), Some(controller)) = (&mut self.luts, &mut self.controller) else { return };
        for e in std::mem::take(&mut controller.host_lut_events) {
            match e {
                E::ToggleFavouriteLut(name) => {
                    if let Err(err) = library.toggle_favourite(&name) {
                        cx.emit(AppEvent::Status(format!("Could not save the favorite: {err}")));
                    }
                }
                E::ImportLuts(paths) => {
                    let paths: Vec<std::path::PathBuf> = paths.into_iter().map(Into::into).collect();
                    let result = library.import_luts(&paths);
                    if let Some((p, why)) = result.failures.first() {
                        let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                        cx.emit(AppEvent::Status(format!("Could not import {name}: {why}")));
                    }
                }
                _ => {}
            }
            *entries = library.entries();
        }
        if let Some(m) = controller.model_mut().filter(|m| m.lut_entries != *entries) {
            m.lut_entries = entries.clone();
        }
    }

    pub fn with_eyedropper(mut self, eyedropper: Eyedropper) -> ColorPageHost {
        self.eyedropper = Some((eyedropper, None));
        self
    }

    /// The pick of a white-balance eyedropper that the monitor answered: the controller solves Temperature and Tint from
    /// the picked color (linear light) as one undo step.
    /// Swift `ProgramLinearFrame.average(at:)`: the mean of the 5 x 5 patch of the rendered frame in linear light; the
    /// shown sRGB pixel only when the picture has no linear copy.
    fn picked_linear(picture: Option<&MonitorPicture>, pick: crate::analysis_links::eyedropper::Pick) -> [f32; 3] {
        let patch = picture
            .filter(|_| pick.on_picture)
            .and_then(MonitorPicture::linear)
            .and_then(|image| crate::analysis_links::picture_sampler::patch_mean(&image, [pick.at.0, pick.at.1], 2));
        patch.unwrap_or_else(|| {
            let (r, g, b) = pick.rgb;
            [srgb_to_linear(r), srgb_to_linear(g), srgb_to_linear(b)]
        })
    }

    fn finish_eyedropper(&mut self, cx: &mut HostCx) {
        let (Some((dropper, armed)), Some(controller)) = (&mut self.eyedropper, &mut self.controller) else { return };
        // Another host's pick is not ours: only an armed white-balance pick takes the answer.
        if armed.is_none() || !dropper.has_answer() {
            return;
        }
        let (Some(answer), Some((key, effect))) = (dropper.take_pick(), armed.take()) else { return };
        let linear = answer.map(|pick| Self::picked_linear(self.picture.as_ref(), pick));
        controller.picked_screen_color(cx.session, key);
        controller.finish_white_balance(cx.session, &mut self.clipboard, key, effect, linear);
        self.collect(cx);
    }

    fn with_scope_slots(mut self) -> ColorPageHost {
        self.scopes.slot_base = SCOPE_SLOT;
        self
    }

    /// Runs `wake` when a Sources poster decode finishes.
    pub fn set_wake(&mut self, wake: std::sync::Arc<dyn Fn() + Send + Sync>) {
        self.posters.set_wake(wake);
    }

    /// Packs the Sources posters into `atlas`, which the Project panel shares (call right after construction).
    pub fn share_atlas(&mut self, atlas: SharedAtlas) {
        self.posters.set_atlas(atlas);
    }

    /// The pictures for the renderer's image slots since the last call: the Scopes' (when they changed) and the
    /// Sources posters.
    pub fn take_image_uploads(&mut self) -> Vec<ImageUpload> {
        let mut uploads = self.posters.take_uploads();
        let generation = self.scopes.image_generation();
        if generation != self.scope_generation {
            self.scope_generation = generation;
            let images = self.scopes.images();
            uploads.extend(images.iter().enumerate().filter_map(|(i, image)| {
                image.clone().map(|image| ImageUpload { slot: SCOPE_SLOT + i, at: None, image })
            }));
        }
        uploads
    }

    /// The Scopes measure the frames put into `picture`.
    pub fn set_picture(&mut self, picture: MonitorPicture) {
        self.picture = Some(picture);
    }

    /// The Source monitor's picture, which the Scopes measure while that monitor is the active panel.
    pub fn set_source_picture(&mut self, picture: MonitorPicture) {
        self.source_picture = Some(picture);
    }

    /// Tells the Scopes which monitor is the active panel (call before `draw`). The Color page always measures Program.
    pub fn set_focused_panel(&mut self, focused: Option<PanelID>) {
        let wanted = choose_scope_source(focused, self.source_picture.is_some() && !self.on_color_page);
        if wanted != self.scope_source {
            self.scope_source = wanted;
            // The two pictures count generations on their own: forget the last measure so the new one is binned.
            self.scopes.clear();
            self.scopes_clear = true;
        }
    }

    /// The controller, made on first use.
    fn controller<'a>(
        slot: &'a mut Option<ColorGradeController>,
        session: &mut EditorSession,
    ) -> &'a mut ColorGradeController {
        slot.get_or_insert_with(|| {
            let make: Box<dyn Fn() -> Box<dyn IdSource>> = Box::new(|| Box::new(SequentialIds::default()));
            let mut c = ColorGradeController::new(session, make);
            c.sync(session, Change::PROJECT | Change::SELECTION);
            c
        })
    }

    /// The Color page shows (the dock's page).
    pub fn is_on_color_page(&self) -> bool {
        self.on_color_page
    }

    /// The clips the Color panel grades, outlined on the timeline while the Color page shows (Swift `gradeOutline`).
    pub fn grade_outline(&self) -> std::collections::BTreeSet<sq_core_time::Id> {
        match &self.controller {
            Some(c) if self.on_color_page => c.grade_outline().clone(),
            _ => Default::default(),
        }
    }

    /// The status bar's grade text on the Color page ("Pro grade active, 4 steps"), empty elsewhere.
    pub fn grade_status(&self, session: &EditorSession) -> String {
        match &self.controller {
            Some(c) if self.on_color_page => c.grade_status(session),
            _ => String::new(),
        }
    }

    /// The Program monitor's card on the Color page loses the viewer header's strip at its top.
    pub fn monitor_card(&mut self, card: CGRect, dock: &ShellDock) -> CGRect {
        self.on_color_page = dock.store().page == WorkspacePage::Color;
        self.monitor_body = None;
        if !self.on_color_page || card.width <= 0.0 {
            self.frames.remove(&Part::Header);
            return card;
        }
        // Swift: `SharedUIController.makeColorPage` sets `showsViewerHeader = false`: no Before | After | Split strip (the
        // layout is in the Color tab's "..." menu), on both systems.
        if !self.shows_viewer_header {
            self.frames.remove(&Part::Header);
            self.monitor_body = Some(card);
            return card;
        }
        let h = f64::from(metrics::PANEL_HEADER);
        self.frames.insert(Part::Header, CGRect::new(card.x, card.y, card.width, h));
        let body = CGRect::new(card.x, card.y + h, card.width, (card.height - h).max(0.0));
        self.monitor_body = Some(body);
        body
    }

    /// Where the Program picture sits (window points) and how wide the sequence is, for the Split divider (call each
    /// frame before [`draw`](Self::draw)).
    pub fn set_picture_view(&mut self, canvas: CGRect, sequence_width: f64) {
        self.picture_view = Some((canvas, sequence_width));
    }

    /// The Split divider line over the picture (Swift `ColorPageHost.drawSplitDivider`), only while Split shows.
    fn split_divider(&self) -> Option<CGRect> {
        let (canvas, sequence_width) = self.picture_view?;
        if !self.on_color_page || !self.controller.as_ref().is_some_and(ColorGradeController::split_shown) {
            return None;
        }
        Self::split_divider_frame(canvas, sequence_width, self.monitor_body?, 1.0)
    }

    /// The divider's frame (Swift `ProgramSurfaceView.splitDividerFrame`): centered on `ColorBypass.splitWidth` of the
    /// sequence width mapped onto the canvas, spanning the visible part of the picture; `None` when none is visible.
    fn split_divider_frame(canvas: CGRect, sequence_width: f64, bounds: CGRect, line_width: f64) -> Option<CGRect> {
        let w = (sequence_width.round() as i64).max(1);
        let x = canvas.x + canvas.width * sq_core_color::ColorBypass::split_width(w) as f64 / w as f64;
        let (x0, y0) = (canvas.x.max(bounds.x), canvas.y.max(bounds.y));
        let (x1, y1) = (canvas.max_x().min(bounds.max_x()), canvas.max_y().min(bounds.max_y()));
        if x1 <= x0 || y1 <= y0 {
            return None;
        }
        Some(CGRect::new((x - line_width / 2.0).round(), y0, line_width, y1 - y0))
    }

    /// Places the panels on the dock's cards (call after the dock laid out and [`monitor_card`](Self::monitor_card)).
    pub fn layout(&mut self, dock: &mut ShellDock, cx: &mut HostCx) {
        let on = self.on_color_page;
        let cards = [
            (Part::Grade, PanelID::ColorInspector),
            (Part::Steps, PanelID::Steps),
            (Part::Sources, PanelID::ColorClips),
        ];
        let controller = Self::controller(&mut self.controller, cx.session);
        // The picker flags are set before the first press can reach the panel, not only after a pump: a click on the
        // eyedropper right after the first frame must arm it.
        controller.can_pick_screen_color = self.eyedropper.is_some();
        for (part, id) in cards {
            match dock.content_frame(id) {
                Some(f) => self.frames.insert(part, f),
                None => self.frames.remove(&part),
            };
        }
        controller.set_is_on_color_page(cx.session, on);
        controller.set_is_active(cx.session, on || self.frames.contains_key(&Part::Grade));
        // Steps is the Pro grade's graph: no Simple grade, no Steps panel (shown, not stored).
        let hidden: HashSet<PanelID> =
            if on && !controller.pro_shown() { HashSet::from([PanelID::Steps]) } else { HashSet::new() };
        if dock.transiently_hidden() != &hidden {
            dock.set_transiently_hidden(hidden);
            for (part, id) in cards {
                match dock.content_frame(id) {
                    Some(f) => self.frames.insert(part, f),
                    None => self.frames.remove(&part),
                };
            }
        }
        // The strips' legend names the graded file; it must be known before the strips are measured.
        {
            let controller = Self::controller(&mut self.controller, cx.session);
            let name = controller.file_row(cx.session).map(|r| r.0);
            controller.set_legend(name);
        }
        self.layout_strips(dock, cx, on);
        let controller = Self::controller(&mut self.controller, cx.session);
        self.grade.file_row = controller.file_row(cx.session);
        controller.set_steps_shown(on && self.frames.contains_key(&Part::Steps));
        controller.set_sources_shown(cx.session, on && self.frames.contains_key(&Part::Sources));
        controller.set_strip_visible(cx.session, on && dock.shows(PanelID::Timeline));
        match dock.content_frame(PanelID::Scopes) {
            Some(f) => {
                self.frames.insert(Part::Scopes, f);
                self.scopes.layout_frame(f);
                self.scopes.hint = if on { controller.on_screen_hint().map(str::to_string) } else { None };
            }
            None => {
                self.frames.remove(&Part::Scopes);
            }
        }
        let size = |f: Option<&CGRect>| f.map(|f| CGSize { width: f.width, height: f.height });
        if let Some(s) = size(self.frames.get(&Part::Grade)) {
            self.grade.size = s;
            let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
            self.grade.tick(&mut host, cx.ui.now);
        }
        if let Some(s) = size(self.frames.get(&Part::Steps)) {
            self.steps.size = s;
        }
        if let Some(s) = size(self.frames.get(&Part::Sources)) {
            self.sources.size = s;
        }
        if let Some(s) = size(self.frames.get(&Part::Header)) {
            self.header.size = s;
        }
        if let Some(f) = self.focus
            && !self.frames.contains_key(&f)
        {
            self.focus = None;
        }
    }

    /// Whether a grade was copied (tests).
    #[cfg(test)]
    pub(crate) fn clipboard_has_color(&self) -> bool {
        self.clipboard.has_color()
    }

    /// Tells the strips' dropdowns which sequence is open and whether the timeline is in Fast Cut.
    pub fn set_timeline_labels(&mut self, sequence: String, fast_cut: bool) {
        self.strip_tools.sequence = sequence;
        self.strip_tools.fast_cut = fast_cut;
    }

    /// The timeline dropdowns pressed since the last call, with their frames (window points); the root opens the
    /// timeline header's menus for them.
    pub fn take_dropdowns(&mut self) -> Vec<(StripDropdown, CGRect)> {
        std::mem::take(&mut self.strip_tools.dropdowns)
    }

    /// Copy Grade and Paste Grade rows for the "..." menu of the dropdowns (they leave their picks with this page).
    pub fn grade_menu_items(&self, session: &EditorSession) -> Vec<SQMenuItem> {
        let Some(controller) = &self.controller else { return Vec::new() };
        ColorViewerHeaderDraw::menu_items(controller, session, &self.clipboard)
    }

    /// Reserves the strips' right ends for the tools (the dock keeps tabs and presses out of them) and finds the strips.
    fn layout_strips(&mut self, dock: &mut ShellDock, cx: &mut HostCx, on: bool) {
        let measure = cx.measure();
        let Some(controller) = &self.controller else { return };
        let widths: HashMap<StripPanel, f64> = STRIPS
            .iter()
            .filter(|(_, id)| on && dock.shows(*id))
            .map(|(sp, _)| {
                let w = ColorStripToolsDraw::width(controller, *sp, &|s| {
                    measure.width(s, f64::from(sq_uikit::design_tokens::sq_tokens::type_size::BODY), 0)
                });
                (*sp, w.ceil())
            })
            .collect();
        if widths != self.tool_widths {
            let table: Vec<(PanelID, f64)> =
                STRIPS.iter().filter_map(|(sp, id)| Some((*id, *widths.get(sp)?))).collect();
            dock.strip_tools = Box::new(move |p| table.iter().find(|(id, _)| *id == p).map_or(0.0, |(_, w)| *w));
            dock.relayout();
            self.tool_widths = widths;
            for (part, id) in [
                (Part::Grade, PanelID::ColorInspector),
                (Part::Steps, PanelID::Steps),
                (Part::Sources, PanelID::ColorClips),
            ] {
                match dock.content_frame(id) {
                    Some(f) => self.frames.insert(part, f),
                    None => self.frames.remove(&part),
                };
            }
        }
        self.strips.clear();
        for (sp, id) in STRIPS {
            if !self.tool_widths.contains_key(&sp) {
                continue;
            }
            if let Some(g) = dock.groups().iter().find(|g| g.selected == id && g.strip.height > 0.0) {
                self.strips.insert(sp, g.tools_strip());
            }
        }
    }

    /// Feeds the Scopes the newest frame of the monitor they follow, once per frame.
    fn feed_scopes(&mut self) {
        // The head says PROGRAM or SOURCE after the picture it measures.
        self.scopes.source = self.scope_source;
        let picture = match self.scope_source {
            ScopeSource::Program => self.picture.as_ref(),
            ScopeSource::Source => self.source_picture.as_ref(),
        };
        let Some(shot) = picture.map(|p| (p.get(), p.generation())) else { return };
        match shot {
            (Some(img), generation) => {
                self.scopes.update_nv12(&img.pixels, img.width, img.height, true, true, generation);
                self.scopes_clear = false;
            }
            (None, _) if !self.scopes_clear => {
                self.scopes.clear();
                self.scopes_clear = true;
            }
            _ => {}
        }
    }

    /// Draws the panels in their frames.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        // The Scopes follow their dock card on both pages; nothing is measured while the card is not shown.
        if self.frames.contains_key(&Part::Scopes) {
            self.feed_scopes();
        }
        if self.on_color_page {
            // Each tile shows the frame its first cut is about (`ColorSourcesLayout::frame_time`); the poster stands in
            // until that frame arrived.
            let items = self.source_list.items(cx.session);
            if self.source_names.len() != items.len()
                || self.source_names.iter().zip(items.iter()).any(|(a, b)| *a != b.name)
            {
                self.source_names = items.iter().map(|i| i.name.clone()).collect();
            }
            let timeline = cx.session.active_timeline();
            let wanted = items.iter().filter_map(|i| {
                Some((cx.session.project().media(i.media)?, ColorSourcesLayout::frame_time(i, timeline)))
            });
            self.posters.pump_frames(wanted, SOURCE_POSTER_HEIGHT);
        }
        let posters = &self.posters;
        let thumbnail = |id: Id, at: Option<sq_core_time::Time>| {
            posters.placed_frame(id, at).map(|p| SourceThumbnail {
                slot: ATLAS_SLOT,
                source: p.uv(),
                pixel_size: p.size(),
            })
        };
        let divider = self.split_divider();
        let controller = Self::controller(&mut self.controller, cx.session);
        for (&part, &f) in &self.frames {
            if f.width <= 0.0 || f.height <= 0.0 {
                continue;
            }
            if part == Part::Scopes {
                self.scopes.draw_card(c, t);
                continue;
            }
            c.save_gstate();
            c.clip_to(f);
            c.translate_by(f.x, f.y);
            match part {
                Part::Grade => self.grade.draw(c, t, controller, cx.ui),
                Part::Steps => {
                    let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
                    self.steps.draw(c, t, &mut host, cx.ui);
                }
                Part::Sources => self.sources.draw(c, t, controller, cx.session, &thumbnail),
                Part::Header => self.header.draw(c, t, controller),
                Part::Scopes => {}
            }
            c.restore_gstate();
        }
        for (sp, strip) in &self.strips {
            let reserved = self.tool_widths.get(sp).copied().unwrap_or(0.0);
            self.strip_tools.draw(c, t, controller, cx.session, &self.clipboard, *sp, *strip, reserved);
        }
        // Split: a 1 pt line over the split column of the picture with a soft shadow (Swift `SplitDividerView`).
        if let Some(r) = divider {
            c.fill(r.inset_by(-1.0, 0.0), t.on_picture_shadow());
            c.fill(r, t.on_picture_stroke());
        }
    }

    /// Pushes the accessibility nodes of the page's controls.
    pub fn a11y(&self, a: &mut sq_draw::A11y) {
        self.push_nodes(a);
    }

    /// Runs an accessibility action on a Color page control; false for foreign ids.
    pub fn a11y_action(&mut self, id: accesskit::NodeId, action: sq_app_shell::A11yAction, cx: &mut HostCx) -> bool {
        self.run_action(id, action, cx)
    }

    /// Window point of the right end (the number field) of the Simple page's `param` row, for tests that click through the root.
    #[cfg(test)]
    pub(crate) fn simple_field_point(
        &self,
        param: Option<sq_inspector_ui::color::color_inspector_model::ColorParam>,
    ) -> Option<(f32, f32)> {
        use sq_inspector_ui::color::color_grade_draw::{Control, Slider};
        let controller = self.controller.as_ref()?;
        let model = controller.model()?;
        let slider = match param {
            Some(p) => Slider::Param(model.effects().first()?.id, p),
            None => Slider::Sharpen,
        };
        let rows = self.grade.rows(model, controller.steps_shown());
        let (row_y, r) = rows.iter().find_map(|row| {
            row.controls.iter().find(|(c, _)| *c == Control::Slider(slider)).map(|(_, r)| (row.y, *r))
        })?;
        let f = self.frames.get(&Part::Grade)?;
        Some(((f.x + r.max_x() - 4.0) as f32, (f.y + row_y + r.mid_y() - self.grade.scroll_y()) as f32))
    }

    /// Window point of the middle of the white-balance eyedropper in the Simple page's Basic Correction header, for tests
    /// that click through the root.
    #[cfg(test)]
    pub(crate) fn eyedropper_point(&self) -> Option<(f32, f32)> {
        use sq_inspector_ui::color::color_grade_draw::Control;
        let controller = self.controller.as_ref()?;
        let model = controller.model()?;
        let rows = self.grade.rows(model, controller.steps_shown());
        let (row_y, r) = rows.iter().find_map(|row| {
            row.controls.iter().find(|(c, _)| matches!(c, Control::Eyedropper(_))).map(|(_, r)| (row.y, *r))
        })?;
        let f = self.frames.get(&Part::Grade)?;
        Some(((f.x + r.mid_x()) as f32, (f.y + row_y + r.mid_y() - self.grade.scroll_y()) as f32))
    }

    /// A press anywhere else in the window (the timeline, the monitor, a header: the root gives them the event first and
    /// the Color page never sees it) commits a value typed into a Grade field, like a press on another Color panel does.
    pub fn commit_typing_on_press(&mut self, x: f32, y: f32, cx: &mut HostCx) {
        if self.focus != Some(Part::Grade) || self.controller.is_none() {
            return;
        }
        let q = CGPoint::new(f64::from(x / cx.scale), f64::from(y / cx.scale));
        if part_at(&self.frames, q) == Some(Part::Grade) {
            return;
        }
        let controller = Self::controller(&mut self.controller, cx.session);
        let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
        self.grade.resign_focus(&mut host, cx.ui);
        self.collect(cx);
    }

    /// Routes one event; true when a Color panel took it.
    pub fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let scale = cx.scale;
        let measure = cx.measure();
        let Some(_) = &self.controller else { return false };
        let controller = Self::controller(&mut self.controller, cx.session);
        let at = |x: f32, y: f32| CGPoint::new(f64::from(x / scale), f64::from(y / scale));
        let frame = |part: Part, frames: &BTreeMap<Part, CGRect>| frames.get(&part).copied().unwrap_or_default();
        let taken = match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let q = at(x, y);
                if !modifiers.contains(InputModifiers::SECONDARY)
                    && let Some((&sp, &strip)) = self.strips.iter().find(|(_, r)| r.contains(q))
                    && self.strip_tools.mouse_down(sp, strip, q)
                {
                    self.pressed_tool = Some(sp);
                    return true;
                }
                let Some(part) = part_at(&self.frames, q) else {
                    self.focus = None;
                    return false;
                };
                if self.focus == Some(Part::Grade) && part != Part::Grade {
                    let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
                    self.grade.resign_focus(&mut host, cx.ui);
                }
                self.focus = Some(part);
                self.pressed = Some(part);
                let f = frame(part, &self.frames);
                let l = CGPoint::new(q.x - f.x, q.y - f.y);
                let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
                match part {
                    Part::Grade => self.grade.mouse_down(&mut host, cx.ui, l, modifiers, None),
                    Part::Steps => self.steps.mouse_down(&mut host, cx.ui, l, modifiers, None, None),
                    Part::Sources => {
                        let ColorGradeHost { controller, session, clipboard } = host;
                        self.sources.mouse_down(controller, session, clipboard, l, modifiers);
                        self.pressed = None;
                    }
                    Part::Header => {
                        let ColorGradeHost { controller, session, clipboard } = host;
                        self.header.mouse_down(controller, session, clipboard, l);
                        self.pressed = None;
                    }
                    Part::Scopes => {
                        self.pressed = None;
                        self.scopes.handle_event(e, Some(cx.ui));
                    }
                }
                true
            }
            InputEvent::MouseDragged { x, y, .. } => {
                let Some(part) = self.pressed else { return false };
                let l = local(frame(part, &self.frames), x, y, scale);
                let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
                match part {
                    Part::Grade => self.grade.mouse_dragged(&mut host, cx.ui, l, InputModifiers::default()),
                    Part::Steps => self.steps.mouse_dragged(&mut host, l),
                    _ => {}
                }
                true
            }
            InputEvent::MouseUp { x, y } => {
                if let Some(sp) = self.pressed_tool.take() {
                    let strip = self.strips.get(&sp).copied().unwrap_or_default();
                    let add =
                        (sp == StripPanel::Steps).then(|| self.steps.add_menu_items(controller.model())).flatten();
                    let more = if sp == StripPanel::ColorInspector {
                        controller.more_menu_items(cx.session, &self.clipboard, Vec::new())
                    } else {
                        Vec::new()
                    };
                    self.strip_tools.mouse_up(
                        controller,
                        cx.session,
                        &mut self.clipboard,
                        sp,
                        strip,
                        at(x, y),
                        add,
                        more,
                    );
                    for m in self.strip_tools.menus.drain(..) {
                        self.menus.push((m.items, m.anchor));
                    }
                    self.collect(cx);
                    return true;
                }
                let Some(part) = self.pressed.take() else { return false };
                let l = local(frame(part, &self.frames), x, y, scale);
                let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
                match part {
                    Part::Grade => self.grade.mouse_up(&mut host, cx.ui, l),
                    Part::Steps => {
                        self.steps.mouse_up(&mut host, cx.ui, l, &|s| measure.width(s, 11.0, 0));
                    }
                    _ => {}
                }
                true
            }
            InputEvent::MouseMoved { x, y } => {
                let q = at(x, y);
                let over = part_at(&self.frames, q);
                match self.strips.iter().find(|(_, r)| r.contains(q)) {
                    Some((&sp, &strip)) => self.strip_tools.mouse_moved(Some(sp), Some(strip), q),
                    None => self.strip_tools.mouse_moved(None, None, q),
                }
                let l = |part: Part| over.filter(|o| *o == part).map(|_| local(frame(part, &self.frames), x, y, scale));
                let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
                self.grade.mouse_moved(&mut host, cx.ui, l(Part::Grade));
                self.steps.mouse_moved(host.controller, cx.ui, l(Part::Steps));
                self.sources.mouse_moved(host.controller, host.session, l(Part::Sources));
                self.header.mouse_moved(l(Part::Header));
                self.scopes.handle_event(e, Some(cx.ui));
                return false;
            }
            InputEvent::Scroll { x, y, dx, dy, modifiers } => {
                let q = at(x, y);
                let Some(part) = part_at(&self.frames, q) else { return false };
                let l = local(frame(part, &self.frames), x, y, scale);
                let (ddx, ddy) = (f64::from(dx / scale), f64::from(dy / scale));
                match part {
                    Part::Grade => self.grade.scroll(controller, ddy),
                    Part::Steps => self.steps.scroll(controller, cx.ui, l, ddx, ddy, modifiers),
                    Part::Sources => self.sources.scroll(controller, cx.session, ddx, ddy),
                    Part::Header | Part::Scopes => return false,
                }
                true
            }
            InputEvent::KeyDown { key, modifiers } => {
                let Some(part) = self.focus else { return false };
                if !matches!(part, Part::Grade | Part::Steps | Part::Sources) {
                    return false;
                }
                if modifiers.contains(InputModifiers::COMMAND)
                    && let InputKey::Character(ch) = key
                {
                    let command = match ch.to_ascii_lowercase() {
                        'c' => Some(ColorMenuCommand::CopyGradeOrBeep),
                        'v' => Some(ColorMenuCommand::PasteGradeOrBeep),
                        _ => None,
                    };
                    if let Some(command) = command {
                        controller.run_menu_command(cx.session, &mut self.clipboard, command);
                        self.collect(cx);
                        return true;
                    }
                }
                let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
                match part {
                    Part::Grade => self.grade.key(&mut host, cx.ui, key, modifiers),
                    Part::Steps => self.steps.key(&mut host, cx.ui, key, modifiers),
                    _ => {
                        let ColorGradeHost { controller, session, .. } = host;
                        self.sources.key(controller, session, key, modifiers)
                    }
                }
            }
        };
        self.collect(cx);
        taken
    }

    /// The session changed: the controller follows (it skips playhead ticks while the page is hidden).
    pub fn on_change(&mut self, changes: Change, cx: &mut HostCx) {
        let controller = Self::controller(&mut self.controller, cx.session);
        controller.sync(cx.session, changes);
        self.collect(cx);
    }

    /// The panels' menus and the controller's events, taken after each call. Events the platform must answer (the
    /// eyedropper, the engine's Before | After) are dropped here; see the shortcut note on top.
    fn collect(&mut self, cx: &mut HostCx) {
        let Some(controller) = &mut self.controller else { return };
        let origin = |frames: &BTreeMap<Part, CGRect>, p: Part| frames.get(&p).map_or((0.0, 0.0), |f| (f.x, f.y));
        let (gx, gy) = origin(&self.frames, Part::Grade);
        for m in self.grade.menus.drain(..) {
            self.menus.push((m.items, CGRect::new(m.anchor.x + gx, m.anchor.y + gy, m.anchor.width, m.anchor.height)));
        }
        let (sx, sy) = origin(&self.frames, Part::Steps);
        for m in self.steps.menus.drain(..) {
            self.menus.push((m.items, CGRect::new(m.anchor.x + sx, m.anchor.y + sy, m.anchor.width, m.anchor.height)));
        }
        let (cx0, cy0) = origin(&self.frames, Part::Sources);
        for m in self.sources.menus.drain(..) {
            self.menus
                .push((m.items, CGRect::new(m.anchor.x + cx0, m.anchor.y + cy0, m.anchor.width, m.anchor.height)));
        }
        let (hx, hy) = origin(&self.frames, Part::Header);
        for m in self.header.menus.drain(..) {
            self.menus.push((m.items, CGRect::new(m.anchor.x + hx, m.anchor.y + hy, m.anchor.width, m.anchor.height)));
        }
        for m in self.scopes.menus.drain(..) {
            self.menus.push((m.items, m.anchor));
        }
        for e in controller.events.drain(..) {
            match e {
                ColorGradeEvent::Beep => cx.emit(AppEvent::Status("Nothing to do here".to_string())),
                ColorGradeEvent::Notice(line) => cx.emit(AppEvent::Status(line)),
                ColorGradeEvent::SetColorBypass(bypass) => cx.session.set_color_bypass(bypass),
                ColorGradeEvent::PickScreenColor { key, effect } => {
                    if let Some((dropper, armed)) = &mut self.eyedropper {
                        dropper.arm();
                        *armed = Some((key, effect));
                        cx.emit(AppEvent::Status("Click a neutral gray in the Program monitor picture.".to_string()));
                    }
                }
                _ => {}
            }
        }
        self.answer_file_requests(cx);
    }

    /// Opens the LUT and decision choosers the panels asked for and hands the picks back.
    fn answer_file_requests(&mut self, cx: &mut HostCx) {
        let Some(controller) = &mut self.controller else { return };
        let mut lut_jobs: Vec<(bool, LutJob)> = Vec::new();
        for r in self.grade.file_requests.drain(..) {
            let GradeFileRequest::LutFiles { multiple, then } = r;
            lut_jobs.push((multiple, LutJob::Grade(then)));
        }
        let selected = controller.model().and_then(|m| m.selected_step());
        for r in self.steps.requests.drain(..) {
            match r {
                StepsHostRequest::ChooseLutFile(target) => lut_jobs.push((false, LutJob::Step(target, selected))),
                StepsHostRequest::ImportDecision(id) => {
                    let ask = cx.services.files.choose_file("Choose a color decision", None);
                    self.decisions.push((ask, id));
                }
            }
        }
        let mut failed: Option<String> = None;
        for (multiple, job) in lut_jobs {
            let mut paths: Vec<String> = cx
                .services
                .panel_files
                .choose_luts(multiple)
                .iter()
                .map(|p| p.to_string_lossy().into_owned())
                .collect();
            // The library import checks its own files; every other pick (Choose File..., a step's LUT) is checked here, so a
            // broken file is never set on a clip.
            if !matches!(job, LutJob::Grade(LutFilesFor::ImportLuts(..))) {
                paths.retain(|p| match check_lut_file(Path::new(p)) {
                    Ok(()) => true,
                    Err(why) => {
                        failed = Some(format!("Could not use {}: {why}", file_name_of(p)));
                        false
                    }
                });
            }
            let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
            match job {
                LutJob::Grade(LutFilesFor::ImportLuts(effect, slot)) if self.luts.is_some() => {
                    // Swift ColorGradeDraw: copy into the library, then the first added LUT goes on the slot.
                    let Some((library, entries)) = &mut self.luts else { continue };
                    let result = library.import_luts(&paths.iter().map(std::path::PathBuf::from).collect::<Vec<_>>());
                    *entries = library.entries();
                    if let Some(m) = host.model_mut() {
                        m.lut_entries = entries.clone();
                    }
                    failed = result
                        .failures
                        .first()
                        .map(|(p, why)| format!("Could not import {}: {why}", file_name_of(&p.to_string_lossy())));
                    let first: Vec<String> = result.added.first().map(|e| e.path.clone()).into_iter().collect();
                    self.grade.files_chosen(&mut host, LutFilesFor::SetLut(effect, slot), first);
                }
                LutJob::Grade(then) => self.grade.files_chosen(&mut host, then, paths),
                LutJob::Step(target, step) => {
                    let (Some(path), Some(m)) = (paths.first(), host.model_mut()) else { continue };
                    let choice = LUTChoice::file(path);
                    match target {
                        LUTTarget::GraphInput => m.set_graph_lut(GraphLUTSlot::Input, Some(&choice)),
                        LUTTarget::GraphOutput => m.set_graph_lut(GraphLUTSlot::Output, Some(&choice)),
                        LUTTarget::Step => {
                            if let Some(id) = step {
                                m.set_step_lut(id, Some(&choice));
                            }
                        }
                    }
                    host.pump();
                }
            }
        }
        if let Some(status) = failed {
            cx.emit(AppEvent::Status(status));
        }
    }

    /// Takes the answers of the decision choosers that closed and sets the Step's primaries from the file's first
    /// decision (ASC CDL / CMX EDL), one undo step.
    fn poll_decisions(&mut self, cx: &mut HostCx) {
        let mut cx_poll = Context::from_waker(Waker::noop());
        let mut open = Vec::new();
        for (mut ask, id) in std::mem::take(&mut self.decisions) {
            match std::pin::Pin::new(&mut ask).poll(&mut cx_poll) {
                Poll::Pending => open.push((ask, id)),
                Poll::Ready(Some(path)) => {
                    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    let ext = path.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default();
                    let parsed = std::fs::read(&path)
                        .map_err(|e| e.to_string())
                        .and_then(|data| color_decision_import::parse(&data, &ext).map_err(|e| e.to_string()));
                    let status = match (parsed, &mut self.controller) {
                        (Ok(decisions), Some(controller)) => {
                            let mut host =
                                ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
                            match (decisions.first(), host.model_mut()) {
                                (Some(first), Some(m)) => {
                                    m.apply_color_decision(id, first.primaries());
                                    host.pump();
                                    format!("Applied color decision {}", first.id)
                                }
                                _ => format!("No grade to apply {name} to"),
                            }
                        }
                        (Ok(_), None) => format!("No grade to apply {name} to"),
                        (Err(e), _) => format!("Color decisions cannot be read: {name}: {e}"),
                    };
                    cx.emit(AppEvent::Status(status));
                }
                Poll::Ready(None) => {}
            }
        }
        self.decisions = open;
    }

    /// The windowed Step the monitor shows handles for (`None` off the Color page).
    pub fn window_edit_target(&self) -> Option<sq_inspector_ui::color::color_grade_controller::WindowEditTarget> {
        self.controller.as_ref()?.window_edit().cloned()
    }

    /// One drag of the Step window handles on the monitor: playback stops at the press, each drag is one undo step.
    pub fn apply_window_drag(
        &mut self,
        session: &mut EditorSession,
        phase: sq_draw_monitor::transform_overlay::Phase,
        window: &sq_core_model::StepWindow,
    ) {
        use sq_draw_monitor::transform_overlay::Phase;
        let Some(controller) = &mut self.controller else { return };
        match phase {
            Phase::Began => {
                session.stop_playback();
                controller.begin_window_edit();
            }
            Phase::Changed => controller.change_window_edit(window),
            Phase::Ended => {
                controller.change_window_edit(window);
                controller.end_window_edit();
            }
        }
    }

    /// The menus asked for since the last call.
    pub fn take_menus(&mut self) -> Vec<(Vec<SQMenuItem>, CGRect)> {
        std::mem::take(&mut self.menus)
    }

    /// Runs what the rows of a closed menu queued.
    pub fn pump(&mut self, cx: &mut HostCx) {
        self.poll_decisions(cx);
        self.finish_eyedropper(cx);
        self.run_lut_events(cx);
        let Some(controller) = &mut self.controller else { return };
        controller.can_pick_screen_color = self.eyedropper.is_some();
        controller.eyedropper_armed =
            self.eyedropper.as_ref().is_some_and(|(d, armed)| armed.is_some() && d.is_armed());
        self.scopes.pump();
        for c in controller.menu_sink.drain() {
            controller.run_menu_command(cx.session, &mut self.clipboard, c);
        }
        let measure = cx.measure();
        let mut host = ColorGradeHost { controller, session: cx.session, clipboard: &mut self.clipboard };
        for c in self.grade.take_menu_commands() {
            self.grade.run_menu_command(&mut host, c);
        }
        self.steps.run_menu_commands(&mut host, &|s| measure.width(s, 11.0, 0));
        self.collect(cx);
    }

    /// The id of the clip the panels grade, if any (tests).
    #[cfg(test)]
    fn target(&self, session: &EditorSession) -> Option<sq_core_time::Id> {
        self.controller.as_ref()?.target_clip(session).map(|c| c.id)
    }
}

mod access;

#[cfg(test)]
mod tests;

/// The last part of a path, for messages.
fn file_name_of(path: &str) -> String {
    Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

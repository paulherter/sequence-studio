// Swift: Color/ColorGradeController.swift
//! The logic of the Color page's Color panel. What is graded is picked by clicking a clip, an adjustment layer or the
//! sequence grade layer in the timeline, or a source tile in the Sources panel (a tile grades every use of its source
//! through the grade links). The target comes from `ColorTargetState` (strip pick and timeline selection kept in sync, see
//! there), not from the clip under the playhead; the eyedropper and Auto measure the target only when it is on screen.
//!
//! A view on the target's Color effects (`Clip::color_at_local`): shows the values at the playhead and writes through
//! `session.edit_clip_color` / `edit_sequence_grade` (one undo step per gesture; only the values an edit changed are
//! written, keyframed ones as a key at the playhead the gesture began at). The per-target model (keyed by the clip id, or
//! the sequence id for the sequence-wide grade, so it survives the layer being created mid-gesture) only holds UI state and
//! is reloaded on every session change outside a gesture.
//!
//! Mapping (docs/rust/session-ui-design.md section 2): the session is a `&mut EditorSession` parameter, the `on…` hooks are
//! [`ColorGradeEvent`]s in `events`, the model hooks come in through `pump`, the platform seams (beep, eyedropper, frame
//! readback, the stop-animating question) are events and fields the host fills in.

use super::color_clip_row::ColorClipRow;
use super::color_grade_target::{ColorGradeOutline, ColorSourceListItem, ColorTargetResolution, ColorTargetState};
use super::color_graph_menus::MenuSink;
use super::color_inspector_model::{
    ColorGradeAction, ColorInspectorEvent, ColorInspectorModel, ColorKeyAction, ColorKeyID, ColorKeyTarget,
};
use super::color_page_models::{
    ColorCompareMode, ColorPageFormat, ColorTargetBarContent, ColorUses, ColorViewerHeaderContent,
};
use super::color_sharpen::ClipSharpenExt;
use sq_core_color::{ActiveGrade, ClipEffectColorExt, ClipGradeExt, ClipGradeLinksExt, ColorBypass, ColorBypassMode};
use sq_core_edit::color_grade_targets::{ClipGradeTargetsExt, ProjectGradeTargetsExt, TimelineGradeTargetsExt};
use sq_core_effects::evaluation::{LayerHooks, TimelineEvaluation};
use sq_core_model::{Clip, ClipColor, ColorGraph, ColorSpaceID, Project, StepWindow, Timeline};
use sq_core_time::{Id, IdSource, Time};
use sq_editor_session::{Change, ColorClipboard, ColorMattePreview, EditorSession, MarkersPanelModel};
use sq_render::color::Vec3;
use sq_render::color::auto_tone::AutoTone;
use sq_render::color::white_balance::WhiteBalanceSolver;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

/// The window of the selected Step, to draw handles for over the Program monitor.
#[derive(Clone, Debug, PartialEq)]
pub struct WindowEditTarget {
    pub clip: Id,
    pub window: StepWindow,
}

/// What the Swift controller reported through its `on…` hooks and platform seams. The host drains `events`.
#[derive(Clone, Debug)]
pub enum ColorGradeEvent {
    /// `onChange`: a control changed (the scopes may need a refresh).
    Change,
    /// `onScreenHintChange`.
    OnScreenHintChange(Option<String>),
    /// `onGradeOutlineChange`.
    GradeOutlineChange(BTreeSet<Id>),
    /// `onHeaderDetailChange`.
    HeaderDetailChange(Option<String>),
    /// `onSplitShownChange`.
    SplitShownChange(bool),
    /// `onStepsDetailChange`.
    StepsDetailChange(String),
    /// `onTimelineDetailChange`.
    TimelineDetailChange(String),
    /// `onProShownChange`.
    ProShownChange(bool),
    /// `onUserChoseProGrade`.
    UserChoseProGrade,
    /// `onWindowEditChange`.
    WindowEditChange(Option<WindowEditTarget>),
    /// `onCompareChange`.
    CompareChange(ColorCompareMode),
    /// `onModelMade`: the page of the model with this key can be built.
    ModelMade(Id),
    /// `onModelsDropped`.
    ModelsDropped(BTreeSet<Id>),
    /// `onSynced`.
    Synced,
    /// `onGradeSwitchChange`.
    GradeSwitchChange,
    /// `onStepsPageChange`.
    StepsPageChange,
    /// `onHeaderRefresh`.
    HeaderRefresh,
    /// `session.engine.setColorBypass`: the host calls `ProgramEngine::set_color_bypass` with it.
    SetColorBypass(Option<ColorBypass>),
    /// The `beep` seam (refused action).
    Beep,
    /// A short status line for the status bar.
    Notice(String),
    /// `pickScreenColor`: wait for a click on the Program monitor, then call `finish_white_balance`. The edit time was
    /// pinned when the click came; the host calls `picked_screen_color` first.
    PickScreenColor { key: Id, effect: i64 },
    /// `sampleProgramFrame`: give the Program frame as shown, scaled to about `width` px, to `finish_auto_tone`.
    SampleProgramFrame { key: Id, effect: i64, width: i64 },
}

/// An entry of the Color panel header's menu (commands of `more_menu_items`).
#[derive(Clone, Debug, PartialEq)]
pub enum ColorMenuCommand {
    SetCompare(ColorCompareMode),
    ToggleMatte,
    CopyGrade,
    PasteGrade {
        on_top: bool,
    },
    /// Copy / Paste of the viewer menu and the strip tools: a refused one beeps.
    CopyGradeOrBeep,
    PasteGradeOrBeep,
    /// A refused strip tool (Add Step without a graph).
    Beep,
    SaveMemory(i64),
    LoadMemory(i64),
    ResetGrade,
    SendToPro,
    /// "Link All Cuts" of a Clips tile.
    LinkAllUses(ColorSourceListItem),
    PickWholeSequence,
    GradeAction(ColorGradeAction),
    /// An item of the host's `simple_extra` list was picked (its own closure runs in the host).
    Extra,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
struct EditTime {
    local: Option<Time>,
}

pub struct ColorGradeController {
    pub color_models: BTreeMap<Id, ColorInspectorModel>,
    /// Hook outputs, oldest first.
    pub events: Vec<ColorGradeEvent>,
    /// The clips the timeline outlines (the target and the clips sharing its grade); the shell shows it on the Color page.
    grade_outline: BTreeSet<Id>,
    /// What the panel header shows after "Color": "2 uses" for a clip, "Whole sequence" for the sequence-wide grade,
    /// nil when nothing is graded.
    header_detail: Option<String>,
    /// The Program monitor shows Split (a bypass in split mode is active): the shell draws the divider line.
    split_shown: bool,
    /// The quiet text in the header of the Steps panel ("Color Graph", "Color Graph · not active").
    steps_detail: String,
    timeline_detail: String,
    /// "Uses of <clip>": the legend of the yellow frames, at the right end of the lower strips.
    legend: Option<String>,
    /// The Pro page shows (the Color Graph, or its empty page): the shell shows the Scopes panel beside the monitor then.
    pro_shown: bool,

    /// Does this platform have an eyedropper / a frame readback? (nil seams of Swift: beep instead.)
    pub can_pick_screen_color: bool,
    pub can_sample_program_frame: bool,
    /// The white-balance picker waits for a click on the picture (the host sets it; the button draws pressed in the accent).
    pub eyedropper_armed: bool,
    /// The answer to "stop animating?" (Swift `confirmStopAnimating`); the host sets it before `keyframe` when it asks.
    pub confirm_stop_animating: bool,

    /// What the target is called, whether it is linked to its source, and what the monitor shows instead of it.
    target_content: ColorTargetBarContent,
    target: ColorTargetState,
    resolution: ColorTargetResolution,
    format: ColorPageFormat,
    /// The empty state of the current message (nil while something is graded).
    empty_state: Option<(String, String)>,
    /// Before | After | Split of the viewer header (monitor only, never stored).
    compare: ColorCompareMode,
    is_on_color_page: bool,
    steps_shown: bool,
    sources_shown: bool,
    strip_visible: bool,
    /// The model key of the target (clip id, or sequence id for the Timeline grade); nil = a message is shown.
    key: Option<Id>,

    is_active: bool,
    pending_while_inactive: Change,
    skipped_syncs: i64,

    last_hint: Option<Option<String>>,
    window_edit: Option<WindowEditTarget>,
    bar_base: Option<ColorTargetBarContent>,
    viewer_header_content: ColorViewerHeaderContent,

    gesture_depth: i64,
    gesture_has_edit: bool,
    /// The grade the model showed before its pending edit, per target: an edit writes only what differs from it.
    shown_color: BTreeMap<Id, ClipColor>,
    /// Clip-local edit time captured when a gesture began, or when an asynchronous edit (Auto, eyedropper) was asked for.
    pinned_edit_time: Option<EditTime>,
    /// Undo depth when the running gesture began (its edits are the steps above it).
    gesture_start_depth: usize,
    make_ids: Box<dyn Fn() -> Box<dyn IdSource>>,
    /// LUT library events of the models (recents, favorites, imports) the host handles.
    pub host_lut_events: Vec<ColorInspectorEvent>,
    /// The commands the header menu's rows queued; the host drains them with `run_menu_command`.
    pub menu_sink: MenuSink<ColorMenuCommand>,
}

impl ColorGradeController {
    /// What the header of the Timeline and Sources panels says a click does there.
    pub const TIMELINE_HINT: &'static str = "Click a clip or the adjustment layer to grade it";
    pub const SOURCES_HINT: &'static str = "Every source once \u{00B7} grading one grades every use in the sequence";

    /// `make_ids` makes the id source of each new per-target model.
    pub fn new(session: &EditorSession, make_ids: Box<dyn Fn() -> Box<dyn IdSource>>) -> ColorGradeController {
        let mut target = ColorTargetState::default();
        target.selection_changed(session.selection(), session.active_timeline());
        ColorGradeController {
            color_models: BTreeMap::new(),
            events: Vec::new(),
            grade_outline: BTreeSet::new(),
            header_detail: None,
            split_shown: false,
            steps_detail: "Color Graph".to_string(),
            timeline_detail: Self::TIMELINE_HINT.to_string(),
            legend: None,
            pro_shown: false,
            can_pick_screen_color: false,
            can_sample_program_frame: false,
            eyedropper_armed: false,
            confirm_stop_animating: true,
            target_content: ColorTargetBarContent::new(""),
            target,
            resolution: ColorTargetResolution::Message(String::new()),
            format: ColorPageFormat::Landscape,
            empty_state: None,
            compare: ColorCompareMode::After,
            is_on_color_page: false,
            steps_shown: false,
            sources_shown: false,
            strip_visible: true,
            key: None,
            is_active: true,
            pending_while_inactive: Change::empty(),
            skipped_syncs: 0,
            last_hint: None,
            window_edit: None,
            bar_base: None,
            viewer_header_content: ColorViewerHeaderContent::make(&ColorTargetResolution::Message(String::new()), None),
            gesture_depth: 0,
            gesture_has_edit: false,
            shown_color: BTreeMap::new(),
            pinned_edit_time: None,
            gesture_start_depth: 0,
            make_ids,
            host_lut_events: Vec::new(),
            menu_sink: MenuSink::new(),
        }
    }

    pub fn grade_outline(&self) -> &BTreeSet<Id> {
        &self.grade_outline
    }

    /// The file row at the top of the grade panel: the graded clip's name and what the grade covers ("Applies to all
    /// 11 uses"; the redesign moved this out of the panel header). None when nothing is graded.
    pub fn file_row(&self, session: &EditorSession) -> Option<(String, String)> {
        let name = self.target_clip(session)?.name.clone();
        let applies = match self.header_detail.as_deref() {
            Some("1 use") | None => "Applies to this clip".to_string(),
            Some(d) if d.ends_with("uses") => format!("Applies to all {d}"),
            Some(d) => d.to_string(),
        };
        Some((name, applies))
    }

    pub fn header_detail(&self) -> Option<&str> {
        self.header_detail.as_deref()
    }

    pub fn split_shown(&self) -> bool {
        self.split_shown
    }

    pub fn steps_detail(&self) -> &str {
        &self.steps_detail
    }

    /// The graded file's name while a clip is graded; the strips then say "Uses of <name>".
    pub fn set_legend(&mut self, name: Option<String>) {
        self.legend = name.map(|n| SQL10n::format("Uses of %@", &[&n]));
    }

    pub fn legend(&self) -> Option<&str> {
        self.legend.as_deref()
    }

    pub fn timeline_detail(&self) -> &str {
        &self.timeline_detail
    }

    pub fn pro_shown(&self) -> bool {
        self.pro_shown
    }

    /// The current "On screen: X" (what `OnScreenHintChange` last said), for hosts that read it each frame.
    pub fn on_screen_hint(&self) -> Option<&str> {
        self.target_content.on_screen.as_deref()
    }

    pub fn target_content(&self) -> &ColorTargetBarContent {
        &self.target_content
    }

    pub fn target(&self) -> &ColorTargetState {
        &self.target
    }

    pub fn resolution(&self) -> &ColorTargetResolution {
        &self.resolution
    }

    pub fn format(&self) -> ColorPageFormat {
        self.format
    }

    pub fn empty_state(&self) -> Option<&(String, String)> {
        self.empty_state.as_ref()
    }

    pub fn compare(&self) -> ColorCompareMode {
        self.compare
    }

    /// The Steps panel is the visible tab of its group.
    pub fn steps_shown(&self) -> bool {
        self.steps_shown
    }

    pub fn is_on_color_page(&self) -> bool {
        self.is_on_color_page
    }

    pub fn key(&self) -> Option<Id> {
        self.key
    }

    /// The model of the target (nil = a message is shown).
    pub fn model(&self) -> Option<&ColorInspectorModel> {
        self.key.and_then(|k| self.color_models.get(&k))
    }

    pub fn model_mut(&mut self) -> Option<&mut ColorInspectorModel> {
        let k = self.key?;
        self.color_models.get_mut(&k)
    }

    pub fn is_active(&self) -> bool {
        self.is_active
    }

    pub fn skipped_syncs(&self) -> i64 {
        self.skipped_syncs
    }

    pub fn pending_while_inactive(&self) -> Change {
        self.pending_while_inactive
    }

    pub fn window_edit(&self) -> Option<&WindowEditTarget> {
        self.window_edit.as_ref()
    }

    /// What the viewer header shows (name, "n of m", format), rebuilt on structural syncs.
    pub fn viewer_header_content(&self) -> &ColorViewerHeaderContent {
        &self.viewer_header_content
    }

    fn emit(&mut self, e: ColorGradeEvent) {
        self.events.push(e);
    }

    fn beep(&mut self) {
        self.emit(ColorGradeEvent::Beep);
    }

    // MARK: Switches the shell sets (Swift `didSet`s)

    /// False while the Color page is hidden (Edit page): playhead / transport ticks are not synced, they are collected
    /// and caught up once when the page shows. Edits (project, selection) always sync.
    pub fn set_is_active(&mut self, session: &mut EditorSession, on: bool) {
        let old = self.is_active;
        self.is_active = on;
        if !on || old || self.pending_while_inactive.is_empty() {
            return;
        }
        let pending = self.pending_while_inactive;
        self.pending_while_inactive = Change::empty();
        self.sync(session, pending);
    }

    /// The Color page is showing: only then does Before / Split reach the Program monitor (the shell sets it).
    pub fn set_is_on_color_page(&mut self, session: &mut EditorSession, on: bool) {
        let old = self.is_on_color_page;
        self.is_on_color_page = on;
        if old != on {
            self.update_compare(session);
        }
    }

    /// The Steps panel is the visible tab of its group (the shell sets it on every layout change): the Color panel then
    /// hides its own step strip, the graph is the step list.
    pub fn set_steps_shown(&mut self, on: bool) {
        let old = self.steps_shown;
        self.steps_shown = on;
        if old != on {
            self.update_lower_page();
        }
    }

    /// The Sources panel is the visible tab of its group: the monitor isolates the picked clip's source (`update_solo`).
    pub fn set_sources_shown(&mut self, session: &mut EditorSession, on: bool) {
        let old = self.sources_shown;
        self.sources_shown = on;
        if old != on {
            self.update_solo(session);
        }
    }

    /// The Clips strip is on screen (the Timeline group is shown on the Color page). The solo needs it: with the strip
    /// hidden the isolated clip would have no visible Clips UI to explain or end it. The shell sets it on every layout change.
    pub fn set_strip_visible(&mut self, session: &mut EditorSession, on: bool) {
        let old = self.strip_visible;
        self.strip_visible = on;
        if old != on {
            self.update_solo(session);
        }
    }

    /// The status bar's grade text: "Simple grade active", "No Simple grade", "Pro grade active, 4 steps · experimental",
    /// "No Pro grade · experimental" (the empty Pro page), "".
    pub fn grade_status(&self, session: &EditorSession) -> String {
        let Some(model) = self.model() else { return String::new() };
        if model.shown_grade() == ActiveGrade::Pro && model.graph().is_none() {
            return sq_draw::experimental::tooltip("No Pro grade");
        }
        if model.active_grade() == ActiveGrade::Pro {
            let n = model.graph().map_or(0, |g| g.steps().len());
            return sq_draw::experimental::tooltip(&format!(
                "Pro grade active, {n} {}",
                if n == 1 { "step" } else { "steps" }
            ));
        }
        if self.target_clip(session).is_none_or(|c| !c.has_color_grade()) {
            "No Simple grade".to_string()
        } else {
            "Simple grade active".to_string()
        }
    }

    // MARK: Simple | Pro and the Steps page

    /// The Simple | Pro control picked Pro (`pro`) or Simple.
    pub fn choose_grade(&mut self, session: &mut EditorSession, clipboard: &mut ColorClipboard, pro: bool) {
        if self.model().is_none() {
            self.emit(ColorGradeEvent::GradeSwitchChange);
            return;
        }
        if pro {
            self.emit(ColorGradeEvent::UserChoseProGrade);
        }
        if let Some(m) = self.model_mut() {
            m.set_active_grade(if pro { ActiveGrade::Pro } else { ActiveGrade::Simple });
        }
        self.pump(session, clipboard);
        self.emit(ColorGradeEvent::GradeSwitchChange);
    }

    fn apply_steps_page(&mut self) {
        if self.pro_shown {
            let detail = if self.model().is_some_and(|m| m.graph().is_some()) {
                "Color Graph"
            } else {
                "Color Graph \u{00B7} not active"
            };
            if detail != self.steps_detail {
                self.steps_detail = detail.to_string();
                self.emit(ColorGradeEvent::StepsDetailChange(detail.to_string()));
            }
        }
        self.emit(ColorGradeEvent::StepsPageChange);
    }

    /// Follows the target's grade: the Steps panel shows with the Pro grade (the shell reads `pro_shown`).
    fn update_lower_page(&mut self) {
        let pro = self.model().is_some_and(|m| m.shown_grade() == ActiveGrade::Pro);
        let changed = pro != self.pro_shown;
        self.pro_shown = pro;
        self.apply_steps_page();
        if changed {
            self.emit(ColorGradeEvent::ProShownChange(pro));
        }
    }

    /// The Color panel header's menu: the monitor layout, the grade's copy, paste and reset, and what else acts on the
    /// whole grade. `simple_extra` = the Simple page's own actions (shown while the Simple grade shows); the host runs
    /// their own actions. Picked rows queue a [`ColorMenuCommand`] in `menu_sink`; the host calls `run_menu_command`.
    pub fn more_menu_items(
        &self,
        session: &EditorSession,
        clipboard: &ColorClipboard,
        simple_extra: Vec<SQMenuItem>,
    ) -> Vec<SQMenuItem> {
        let model = self.model();
        let id = self.target_clip(session).map(|c| c.id);
        let row = |title: &str, c: ColorMenuCommand| -> SQMenuItem {
            let sink = self.menu_sink.clone();
            let mut i = SQMenuItem::new(title);
            i.action = Some(Rc::new(move || sink.push(c.clone())));
            i
        };
        let on = |mut i: SQMenuItem, e: bool| {
            i.is_enabled = e;
            i
        };
        let mut items: Vec<SQMenuItem> = vec![SQMenuItem::header("Layout")];
        for m in ColorCompareMode::ALL {
            let mut i = row(m.layout_title(), ColorMenuCommand::SetCompare(m));
            i.is_checked = self.compare == m;
            items.push(i);
        }
        if let Some(model) = model.filter(|m| m.active_grade() == ActiveGrade::Pro) {
            let mut i = row("Picture and matte", ColorMenuCommand::ToggleMatte);
            i.is_checked = model.shows_matte();
            items.push(i);
        }
        let mut copy = row("Copy Grade", ColorMenuCommand::CopyGrade);
        copy.shortcut = sq_uikit::key_binding_text::KeyBindingText::command_hint_here('c');
        let mut paste = row("Paste grade", ColorMenuCommand::PasteGrade { on_top: false });
        paste.shortcut = sq_uikit::key_binding_text::KeyBindingText::command_hint_here('v');
        let can_paste = self.can_paste_grade(session, clipboard);
        let mut save = SQMenuItem::new("Save grade to memory");
        save.submenu = Some(
            (1..=ColorClipboard::MEMORY_SLOTS)
                .map(|n| on(row(&format!("Memory {n}"), ColorMenuCommand::SaveMemory(n)), clipboard.has_color()))
                .collect(),
        );
        let mut load = SQMenuItem::new("Load grade from memory");
        load.submenu = Some(
            (1..=ColorClipboard::MEMORY_SLOTS)
                .map(|n| on(row(&format!("Memory {n}"), ColorMenuCommand::LoadMemory(n)), clipboard.has_memory(n)))
                .collect(),
        );
        items.push(SQMenuItem::separator());
        items.push(on(copy, self.can_copy_grade()));
        items.push(on(paste, can_paste));
        items.push(on(row("Paste grade on top", ColorMenuCommand::PasteGrade { on_top: true }), can_paste));
        items.push(save);
        items.push(load);
        items.push(on(row("Reset this grade", ColorMenuCommand::ResetGrade), model.is_some() && id.is_some()));
        items.push(SQMenuItem::separator());
        items.push(on(
            row("Send Simple grade into Pro (copy)", ColorMenuCommand::SendToPro),
            model.is_some_and(|m| m.can_send_to_pro()),
        ));
        items.push(SQMenuItem::separator());
        if model.is_some_and(|m| m.shown_grade() != ActiveGrade::Pro) && !simple_extra.is_empty() {
            items.extend(simple_extra);
            items.push(SQMenuItem::separator());
        }
        let ga = |a: ColorGradeAction| ColorMenuCommand::GradeAction(a);
        items.push(row("Grade Whole Sequence", ColorMenuCommand::PickWholeSequence));
        items.push(on(row("Link Grade to Selected Clips", ga(ColorGradeAction::LinkSelected)), id.is_some()));
        items.push(on(row("Link All Clips of This Source", ga(ColorGradeAction::LinkSource)), id.is_some()));
        items.push(on(
            row("Unlink Grade", ga(ColorGradeAction::Unlink)),
            model.is_some_and(|m| m.linked_clip_count > 1),
        ));
        items.push(on(row("Add Range Grade", ga(ColorGradeAction::AddRange)), id.is_some()));
        items
    }

    /// Runs one queued row of the header menu.
    pub fn run_menu_command(
        &mut self,
        session: &mut EditorSession,
        clipboard: &mut ColorClipboard,
        c: ColorMenuCommand,
    ) {
        match c {
            ColorMenuCommand::SetCompare(m) => self.set_compare(session, m),
            ColorMenuCommand::ToggleMatte => {
                if let Some(m) = self.model_mut() {
                    let on = !m.shows_matte();
                    m.set_shows_matte(on);
                }
                self.pump(session, clipboard);
            }
            ColorMenuCommand::CopyGrade => {
                self.copy_grade(session, clipboard);
            }
            ColorMenuCommand::PasteGrade { on_top } => {
                if !self.paste_grade(session, clipboard, on_top) {
                    self.beep();
                }
            }
            ColorMenuCommand::CopyGradeOrBeep => {
                if !self.copy_grade(session, clipboard) {
                    self.beep();
                }
            }
            ColorMenuCommand::PasteGradeOrBeep => {
                if !self.paste_grade(session, clipboard, false) {
                    self.beep();
                }
            }
            ColorMenuCommand::SaveMemory(n) => {
                clipboard.save_memory(n);
            }
            ColorMenuCommand::LoadMemory(n) => {
                clipboard.load_memory(n);
            }
            ColorMenuCommand::ResetGrade => {
                if let Some(id) = self.target_clip(session).map(|c| c.id) {
                    session.reset_color(id);
                }
            }
            ColorMenuCommand::SendToPro => {
                if let Some(m) = self.model_mut() {
                    m.send_to_pro();
                }
                self.pump(session, clipboard);
            }
            ColorMenuCommand::LinkAllUses(item) => self.link_all_uses(session, &item),
            ColorMenuCommand::PickWholeSequence => self.pick_whole_sequence(session),
            ColorMenuCommand::GradeAction(a) => {
                if let Some(id) = self.target_clip(session).map(|c| c.id) {
                    self.grade_action(session, a, id);
                }
            }
            ColorMenuCommand::Beep => self.beep(),
            ColorMenuCommand::Extra => {}
        }
    }

    // MARK: Target

    fn clip(session: &EditorSession, id: Id) -> Option<&Clip> {
        session.active_timeline()?.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == id)
    }

    /// The clip the panel edits now: the picked clip, or the Timeline grade layer (nil before it exists).
    pub fn target_clip<'a>(&self, session: &'a EditorSession) -> Option<&'a Clip> {
        match &self.resolution {
            ColorTargetResolution::Clip(id) => Self::clip(session, *id),
            ColorTargetResolution::Sequence { layer, .. } => layer.and_then(|l| Self::clip(session, l)),
            ColorTargetResolution::Message(_) => None,
        }
    }

    /// Grades clip `id`: selects it in the timeline and moves the playhead onto it when it is elsewhere, so the monitor
    /// and the scopes show what is graded.
    pub fn pick(&mut self, session: &mut EditorSession, id: Id) {
        self.target.list_picked(id);
        session.select(BTreeSet::from([id]), BTreeSet::new());
        if let Some(c) = Self::clip(session, id) {
            let (contains, start) = (c.timeline().contains(session.playhead()), c.start);
            if !contains {
                session.seek_sequence(start);
            }
        }
        self.update_solo(session);
        self.sync(session, Change::SELECTION | Change::PLAYHEAD);
    }

    /// Lower panel on Clips with a picture clip picked: the Program monitor shows that clip's whole source file
    /// (`EditorSession::color_source_view`; the clip alone when it has no file); otherwise the normal composite.
    pub fn update_solo(&mut self, session: &mut EditorSession) {
        let mut picked: Option<Id> = None;
        if let ColorTargetResolution::Clip(id) = &self.resolution
            && Self::clip(session, *id).is_some()
        {
            picked = Some(*id);
        }
        session.set_color_solo_clip(Self::solo_clip(self.sources_shown, self.strip_visible, picked));
    }

    /// A source tile: grades its picked cut, else its first linked cut (`clip_to_grade`); the uses of the source share
    /// that grade through the grade links.
    pub fn pick_source(&mut self, session: &mut EditorSession, item: &ColorSourceListItem) {
        let id = item.clip_to_grade(self.target.pick(), session.project());
        self.pick(session, id);
    }

    /// "Link all uses" of a source tile.
    pub fn link_all_uses(&mut self, session: &mut EditorSession, item: &ColorSourceListItem) {
        let id = item.clip_to_grade(self.target.pick(), session.project());
        self.grade_action(session, ColorGradeAction::LinkSource, id);
    }

    /// Grades the whole sequence (the sequence grade layer, created by the first edit) and selects the layer in the
    /// timeline when it exists.
    pub fn pick_whole_sequence(&mut self, session: &mut EditorSession) {
        self.target.whole_sequence_picked();
        let layer = session.active_timeline().and_then(|t| t.sequence_grade_clip()).map(|c| c.id);
        match layer {
            Some(g) => session.select(BTreeSet::from([g]), BTreeSet::new()),
            None => session.select(BTreeSet::new(), BTreeSet::new()),
        }
        self.sync(session, Change::SELECTION | Change::PROJECT);
    }

    /// The Sources list is on the whole sequence (no tile picked).
    pub fn is_whole_sequence(&self) -> bool {
        matches!(self.resolution, ColorTargetResolution::Sequence { .. })
    }

    /// The target is what the Program monitor shows at the playhead (a clip under it, or the sequence while inside it).
    fn on_screen(&self, session: &EditorSession) -> bool {
        match &self.resolution {
            ColorTargetResolution::Clip(id) => {
                Self::clip(session, *id).is_some_and(|c| c.timeline().contains(session.playhead()))
            }
            ColorTargetResolution::Sequence { .. } => {
                session.playhead() < session.active_timeline().map_or(Time::ZERO, |t| t.duration())
            }
            ColorTargetResolution::Message(_) => false,
        }
    }

    // MARK: Compare (Before | After | Split)

    /// Shows `mode` in the viewer header and applies it to the Program monitor.
    pub fn set_compare(&mut self, session: &mut EditorSession, mode: ColorCompareMode) {
        let changed = self.compare != mode;
        self.compare = mode;
        if changed {
            self.emit(ColorGradeEvent::CompareChange(mode));
        }
        self.update_compare(session);
    }

    /// Hands the engine what to draw ungraded: the target and the clips sharing its grade, while the page shows.
    pub fn update_compare(&mut self, session: &mut EditorSession) {
        self.refresh_sampling_block(session);
        let mut bypass: Option<ColorBypass> = None;
        if self.is_on_color_page {
            if let Some(id) = self.target_clip(session).map(|c| c.id) {
                bypass = Self::color_bypass(self.compare, Some(id), &session.grade_link_members(id));
            } else if matches!(self.resolution, ColorTargetResolution::Message(_)) && session.selection().len() == 1 {
                let nested =
                    session.selection().iter().next().and_then(|id| Self::clip(session, *id)).filter(|c| c.is_nested());
                if let Some(c) = nested {
                    // A nest is graded inside: compare everything in it (the panel shows the nested notice).
                    let inside = Self::nested_clips(c, session.project());
                    if let Some(first) = inside.iter().next().copied() {
                        let all: Vec<Id> = inside.iter().copied().collect();
                        bypass = Self::color_bypass(self.compare, Some(first), &all);
                    }
                }
            }
        }
        let split = bypass.as_ref().is_some_and(|b| b.mode == ColorBypassMode::Split);
        // The session gives no outside access to its engine: the host applies it.
        self.emit(ColorGradeEvent::SetColorBypass(bypass));
        self.update_viewer_aids(session);
        if split != self.split_shown {
            self.split_shown = split;
            self.emit(ColorGradeEvent::SplitShownChange(split));
        }
    }

    // MARK: Viewer aids (Pro grade: matte preview and window handles)

    /// Matte preview (`EditorSession::set_color_matte_preview`) and window handles follow the Color page, the Pro grade and
    /// the selected Step. Called after every sync, a Step selection and the matte toggle.
    pub fn update_viewer_aids(&mut self, session: &mut EditorSession) {
        let mut preview: Option<ColorMattePreview> = None;
        let mut edit: Option<WindowEditTarget> = None;
        if self.is_on_color_page
            && let (Some(model), Some(clip)) = (self.model(), self.target_clip(session))
            && model.active_grade() == ActiveGrade::Pro
            && let Some((id, step)) = model.selected_step().and_then(|id| model.step(id).map(|s| (id, s)))
        {
            if model.shows_matte() && (step.qualifier.is_some() || step.window.is_some()) {
                preview = Some(ColorMattePreview { clip: clip.id, step: id });
            }
            if let Some((_, w)) = model.window_edit_target() {
                edit = Some(WindowEditTarget { clip: clip.id, window: w });
            }
        }
        session.set_color_matte_preview(preview);
        if self.window_edit != edit {
            self.window_edit = edit.clone();
            self.emit(ColorGradeEvent::WindowEditChange(edit));
        }
    }

    /// A handle drag on the monitor: begin, change* with the dragged window, end. One "Color Graph" undo step.
    pub fn begin_window_edit(&mut self) {
        if let Some(m) = self.model_mut() {
            m.emit_gesture_began();
        }
    }

    pub fn change_window_edit(&mut self, w: &StepWindow) {
        let Some(m) = self.model_mut() else { return };
        let Some(id) = m.selected_step() else { return };
        m.set_step_window_geometry(id, w);
    }

    pub fn end_window_edit(&mut self) {
        if let Some(m) = self.model_mut() {
            m.emit_gesture_ended();
        }
    }

    // MARK: Sampling block

    fn refresh_sampling_block(&mut self, session: &EditorSession) {
        let (Some(_), Some(t)) = (self.model(), session.active_timeline()) else { return };
        let mut r: Option<String>;
        if let Some(clip) = self.target_clip(session) {
            r = Self::sampling_block_reason(t, clip, session.playhead());
        } else {
            r = if self.on_screen(session) {
                None
            } else {
                Some("Move the playhead into the sequence to measure it.".to_string())
            };
        }
        // Before / Split show the picture without (part of) the grade: measuring it would count the grade twice.
        if r.is_none() && self.is_on_color_page {
            r = Self::compare_block_reason(self.compare);
        }
        if let Some(m) = self.model_mut()
            && m.sampling_block != r
        {
            m.sampling_block = r;
        }
    }

    // MARK: Sync

    pub fn sync(&mut self, session: &mut EditorSession, change: Change) {
        if !self.is_active && !change.intersects(Change::PROJECT | Change::SELECTION) {
            if change.intersects(Change::PLAYHEAD) {
                self.pending_while_inactive |= Change::PLAYHEAD;
            }
            if change.intersects(Change::TRANSPORT) {
                self.pending_while_inactive |= Change::TRANSPORT;
            }
            self.skipped_syncs += 1;
            return;
        }
        self.sync_inner(session, change);
        // Swift's `defer` block, after the body.
        self.update_viewer_aids(session);
        if change.intersects(Change::PLAYHEAD | Change::PROJECT | Change::SELECTION | Change::TRANSPORT) {
            self.refresh_sampling_block(session);
            let structural = change.intersects(Change::PROJECT | Change::SELECTION) || self.bar_base.is_none();
            self.refresh_header(session, structural);
            self.refresh_keyframe_states(session);
        }
    }

    fn sync_inner(&mut self, session: &mut EditorSession, change: Change) {
        // A keyframed grade shows the values at the playhead: reloaded when they differ from what is shown, never while
        // a gesture runs (the drag keeps the values and the time it started with).
        let structural = change.intersects(Change::PROJECT | Change::SELECTION);
        if !structural {
            if !change.intersects(Change::PLAYHEAD) || self.gesture_depth != 0 {
                return;
            }
            let Some(k) = self.key else { return };
            let Some(clip) = self.target_clip(session) else { return };
            if !Self::has_animated_grade(clip) {
                return;
            }
            let Some(model) = self.color_models.get(&k) else { return };
            let now = clip.color_at_local(self.display_time(session, clip));
            if now == model.clip_color() {
                return;
            }
            let (media, info) = (clip.media, session.media().info(clip.media));
            if let Some(m) = self.color_models.get_mut(&k) {
                m.load(&now, Some(media), info.as_ref());
            }
            self.shown_color.insert(k, now);
            return;
        }
        if change.intersects(Change::SELECTION) {
            self.target.selection_changed(session.selection(), session.active_timeline());
        }
        let timeline = session.active_timeline();
        self.format = ColorPageFormat::from_format(timeline.map(|t| &t.format));
        self.resolution = self.target.resolve(timeline);
        let mut keep: BTreeSet<Id> = timeline
            .map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect())
            .unwrap_or_default();
        if let Some(t) = timeline {
            keep.insert(t.id);
        }
        let dropped: BTreeSet<Id> = self.color_models.keys().filter(|k| !keep.contains(k)).copied().collect();
        for k in &dropped {
            self.color_models.remove(k);
            self.shown_color.remove(k);
        }
        if !dropped.is_empty() {
            self.emit(ColorGradeEvent::ModelsDropped(dropped));
        }
        match self.resolution.clone() {
            ColorTargetResolution::Clip(id) => {
                self.key = Some(id);
                self.empty_state = None;
            }
            ColorTargetResolution::Sequence { timeline, .. } => {
                self.key = Some(timeline);
                self.empty_state = None;
            }
            ColorTargetResolution::Message(m) => {
                self.key = None;
                self.empty_state = Some(ColorTargetState::empty_state(&m));
            }
        }
        if let Some(k) = self.key
            && !self.color_models.contains_key(&k)
        {
            self.make_model(k);
        }
        // During a gesture the model keeps what it shows (its own edits come back here as project changes), unless
        // the history moved under it (undo or redo): then the open gesture starts over from the project's values.
        let moved = self.gesture_depth > 0 && self.history_moved_under_gesture(session);
        if moved {
            self.gesture_has_edit = false;
            self.gesture_start_depth = session.undo_depth();
        }
        if let Some(k) = self.key
            && self.color_models.contains_key(&k)
            && (self.gesture_depth == 0 || moved || !self.shown_color.contains_key(&k))
        {
            let clip = self.target_clip(session);
            let c = clip.map_or_else(ClipColor::default, |c| c.color_at_local(self.display_time(session, c)));
            let media = clip.map_or(k, |c| c.media);
            let info = clip.and_then(|c| session.media().info(c.media));
            let graph = clip.and_then(|c| c.color_graph());
            let sharpen = clip.map_or(0.0, |c| c.sharpen_amount());
            if let Some(m) = self.color_models.get_mut(&k) {
                m.load(&c, Some(media), info.as_ref());
                m.load_graph(graph.as_ref());
                m.load_sharpen(sharpen);
            }
            self.shown_color.insert(k, c);
        }
        self.emit(ColorGradeEvent::GradeSwitchChange);
        let clip_id = self.target_clip(session).map(|c| c.id);
        self.update_grade_info(session, clip_id);
        let project_input = session.project().input_color_space;
        if let Some(m) = self.model_mut()
            && m.project_input != project_input
        {
            m.project_input = project_input;
        }
        self.update_lower_page();
        self.emit(ColorGradeEvent::Synced);
    }

    /// An undo or redo (or any step that is not this gesture's own) happened while the gesture was open: the history
    /// is shallower than the gesture's single step, or deeper with the target no longer showing what the model wrote.
    fn history_moved_under_gesture(&self, session: &EditorSession) -> bool {
        let expected = self.gesture_start_depth + usize::from(self.gesture_has_edit);
        let depth = session.undo_depth();
        if depth < expected {
            return true;
        }
        depth > expected
            && self.key.is_some_and(|k| {
                self.target_clip(session).is_some_and(|c| {
                    self.shown_color
                        .get(&k)
                        .is_some_and(|shown| *shown != c.color_at_local(self.display_time(session, c)))
                })
            })
    }

    fn make_model(&mut self, k: Id) {
        let mut model = ColorInspectorModel::new((self.make_ids)());
        // Swift wired every hook here; the events come back through `pump`. The host's Reset (`onResetAll`) is always set.
        model.reset_all_hooked = true;
        self.color_models.insert(k, model);
        self.emit(ColorGradeEvent::ModelMade(k));
    }

    // MARK: Header

    /// The viewer header, the panel header detail, the lower panel's buttons and the Scopes hint. Playhead ticks only
    /// update the "On screen" line.
    fn refresh_header(&mut self, session: &mut EditorSession, structural: bool) {
        if structural {
            let t = session.active_timeline();
            self.bar_base = match &self.resolution {
                ColorTargetResolution::Clip(id) => {
                    Self::clip(session, *id).map(|c| ColorTargetBarContent::clip(c, session.project()))
                }
                ColorTargetResolution::Sequence { .. } => t.map(ColorTargetBarContent::whole_sequence),
                ColorTargetResolution::Message(_) => Some(ColorTargetBarContent::new("")),
            };
            self.viewer_header_content = ColorViewerHeaderContent::make(&self.resolution, t);
            let outline = ColorGradeOutline::clips(&self.resolution, session.project());
            if outline != self.grade_outline {
                self.grade_outline = outline.clone();
                self.emit(ColorGradeEvent::GradeOutlineChange(outline));
            }
            self.update_solo(session);
            self.update_compare(session);
            let detail = Self::header_detail_of(&self.resolution, session);
            if detail != self.header_detail {
                self.header_detail = detail.clone();
                self.emit(ColorGradeEvent::HeaderDetailChange(detail));
            }
            let tl_detail = Self::timeline_detail_for(&self.resolution);
            if tl_detail != self.timeline_detail {
                self.timeline_detail = tl_detail.clone();
                self.emit(ColorGradeEvent::TimelineDetailChange(tl_detail));
            }
            self.emit(ColorGradeEvent::HeaderRefresh);
        }
        let Some(mut c) = self.bar_base.clone() else { return };
        if matches!(self.resolution, ColorTargetResolution::Clip(_)) {
            c.on_screen =
                ColorTargetState::on_screen_hint(&self.resolution, session.active_timeline(), session.playhead());
        }
        let hint = c.on_screen.clone();
        self.target_content = c;
        if self.last_hint.as_ref() != Some(&hint) {
            self.last_hint = Some(hint.clone());
            self.emit(ColorGradeEvent::OnScreenHintChange(hint));
        }
    }

    // MARK: Measuring (eyedropper, Auto)

    /// White-balance eyedropper: the next click on the Program monitor samples the rendered frame; Temperature and Tint
    /// are set so the picked color becomes neutral (one undo step). The host answers a `PickScreenColor` event with
    /// `picked_screen_color` (the click) and `finish_white_balance` (the color).
    fn pick_white_balance(&mut self, k: Id, effect: i64) {
        let blocked = self.color_models.get(&k).is_none_or(|m| m.sampling_block.is_some());
        if blocked || !self.can_pick_screen_color {
            self.beep();
            return;
        }
        self.emit(ColorGradeEvent::PickScreenColor { key: k, effect });
    }

    /// The click of the eyedropper: pins the edit time of the frame that is sampled.
    pub fn picked_screen_color(&mut self, session: &EditorSession, key: Id) {
        self.pinned_edit_time = Some(self.edit_time(session, key));
    }

    /// The eyedropper's result: the mean linear RGB at the click (nil = canceled or unreadable).
    pub fn finish_white_balance(
        &mut self,
        session: &mut EditorSession,
        clipboard: &mut ColorClipboard,
        key: Id,
        effect: i64,
        rgb: Option<[f32; 3]>,
    ) {
        let at = self.pinned_edit_time.take();
        let solved = match (self.color_models.get(&key), rgb) {
            (Some(model), Some(rgb)) if model.sampling_block.is_none() => WhiteBalanceSolver::solve(
                Vec3::new(rgb[0], rgb[1], rgb[2]),
                model.value(effect, super::color_inspector_model::ColorParam::Temperature),
                model.value(effect, super::color_inspector_model::ColorParam::Tint),
            ),
            _ => None,
        };
        let Some(r) = solved else {
            self.beep();
            return;
        };
        let t = at.unwrap_or_else(|| self.edit_time(session, key));
        if r.clamped {
            self.emit(ColorGradeEvent::Notice("Picked color is too saturated to balance fully".to_string()));
        }
        self.with_edit_time(t, |s| {
            if let Some(m) = s.color_models.get_mut(&key) {
                m.set_white_balance(effect, r.temperature, r.tint);
            }
            s.pump(session, clipboard);
        });
    }

    /// Basic Correction Auto: analyzes the Program frame as shown (asynchronously; only when the target is alone there).
    fn auto_tone(&mut self, session: &EditorSession, k: Id, effect: i64) {
        let ok = self.color_models.get(&k).is_some_and(|m| m.auto_tone_block(effect).is_none());
        if !ok || !self.can_sample_program_frame {
            self.beep();
            return;
        }
        // The frame that is analyzed.
        self.pinned_edit_time = Some(self.edit_time(session, k));
        self.emit(ColorGradeEvent::SampleProgramFrame { key: k, effect, width: 96 });
    }

    /// Auto's result: the Program frame as linear RGB samples (nil = unreadable).
    pub fn finish_auto_tone(
        &mut self,
        session: &mut EditorSession,
        clipboard: &mut ColorClipboard,
        key: Id,
        effect: i64,
        linear: Option<Vec<[f32; 3]>>,
    ) {
        let at = self.pinned_edit_time.take();
        let solved = match (self.color_models.get(&key), linear) {
            (Some(model), Some(linear)) if model.auto_tone_block(effect).is_none() => {
                let v: Vec<Vec3> = linear.iter().map(|c| Vec3::new(c[0], c[1], c[2])).collect();
                model.effect_by_id(effect).and_then(|e| AutoTone::solve(&v, &e.basic))
            }
            _ => None,
        };
        let Some(b) = solved else {
            self.beep();
            return;
        };
        let t = at.unwrap_or_else(|| self.edit_time(session, key));
        self.with_edit_time(t, |s| {
            if let Some(m) = s.color_models.get_mut(&key) {
                m.set_auto_tone(effect, &b);
            }
            s.pump(session, clipboard);
        });
    }

    // MARK: Gestures and commits

    fn frame_duration(session: &EditorSession) -> Time {
        session.active_timeline().map_or(Time::new(1, 30), |t| t.frame_duration())
    }

    /// Clip-local time keyed values are edited at: the playhead on the target's frames, nil when it is not over it. The
    /// Timeline grade before its layer exists starts at zero (it will cover the sequence).
    fn edit_time(&self, session: &EditorSession, k: Id) -> EditTime {
        if Some(k) == session.active_timeline_id() && self.target_clip(session).is_none() {
            let over = session.playhead() < session.active_timeline().map_or(Time::ZERO, |t| t.duration());
            return EditTime { local: if over { Some(session.playhead()) } else { None } };
        }
        EditTime {
            local: self
                .target_clip(session)
                .and_then(|c| c.color_edit_time(session.playhead(), Self::frame_duration(session))),
        }
    }

    fn with_edit_time(&mut self, t: EditTime, body: impl FnOnce(&mut ColorGradeController)) {
        let saved = self.pinned_edit_time;
        self.pinned_edit_time = Some(t);
        body(self);
        self.pinned_edit_time = saved;
    }

    fn begin_gesture(&mut self, session: &EditorSession) {
        if self.gesture_depth == 0 {
            self.gesture_has_edit = false;
            self.gesture_start_depth = session.undo_depth();
            if self.pinned_edit_time.is_none()
                && let Some(k) = self.key
            {
                self.pinned_edit_time = Some(self.edit_time(session, k));
            }
        }
        self.gesture_depth += 1;
    }

    /// Esc during a drag: the gesture ends and every step it made is withdrawn (values, keys, a created Color effect or
    /// Timeline grade layer, clips that joined a link), so no undo step is left. The panel shows the target again.
    pub fn cancel_gesture(&mut self, session: &mut EditorSession) {
        if self.gesture_depth <= 0 {
            return;
        }
        let had_edit = self.gesture_has_edit;
        self.gesture_depth = 0;
        self.gesture_has_edit = false;
        self.pinned_edit_time = None;
        if had_edit {
            session.rewind_undo(self.gesture_start_depth);
        }
        self.sync(session, Change::PROJECT);
        if had_edit {
            self.emit(ColorGradeEvent::Change);
        }
    }

    fn end_gesture(&mut self) {
        self.gesture_depth = (self.gesture_depth - 1).max(0);
        if self.gesture_depth == 0 {
            self.pinned_edit_time = None;
        }
    }

    /// Runs `edit` on the target through the session (one `name` step; the Timeline grade layer is created by its first
    /// edit and then selected). Returns whether anything changed.
    fn edit_target(
        &mut self,
        session: &mut EditorSession,
        name: Option<&str>,
        continuing: bool,
        edit: impl FnOnce(&mut Clip) -> bool,
    ) -> Option<bool> {
        match self.resolution.clone() {
            ColorTargetResolution::Clip(id) => {
                Some(session.edit_clip_color(id, name.unwrap_or("Color"), continuing, edit))
            }
            ColorTargetResolution::Sequence { .. } => {
                let changed = session.edit_sequence_grade(name.unwrap_or("Timeline Grade"), continuing, edit);
                // The first edit created the layer: the timeline shows what is graded.
                if let Some(g) = session.active_timeline().and_then(|t| t.sequence_grade_clip()).map(|c| c.id)
                    && *session.selection() != BTreeSet::from([g])
                {
                    session.select(BTreeSet::from([g]), BTreeSet::new());
                }
                Some(changed)
            }
            ColorTargetResolution::Message(_) => None,
        }
    }

    /// Writes the model's edit to the target: only the values that changed against what the model showed, keyed values at
    /// the time the gesture began. Edits of one gesture merge into one undo step; unchanged values make no step. A keyed
    /// edit with the playhead outside the clip is refused (beep) and the panel shows the target again. A clip edit while
    /// "Linked" grades its source's clips too; the first Timeline edit creates the Timeline grade layer.
    fn commit(&mut self, session: &mut EditorSession, k: Id, color: ClipColor) {
        if Some(k) != self.key || !self.color_models.contains_key(&k) {
            return;
        }
        let before = self.shown_color.get(&k).cloned().unwrap_or_else(|| {
            self.target_clip(session)
                .map_or_else(ClipColor::default, |c| c.color_at_local(self.display_time(session, c)))
        });
        if color == before {
            return;
        }
        let t = self.pinned_edit_time.unwrap_or_else(|| self.edit_time(session, k));
        let mut refused = false;
        let continuing = self.gesture_depth > 0 && self.gesture_has_edit;
        let mut ids = (self.make_ids)();
        let c2 = color.clone();
        let b2 = before.clone();
        let changed = self.edit_target(session, None, continuing, |c| {
            if !c.set_color_edited_from(&c2, &b2, t.local, &mut *ids) {
                refused = true;
                return false;
            }
            true
        });
        let Some(changed) = changed else { return };
        if refused {
            self.beep();
            let (back, media, info) = match self.target_clip(session) {
                Some(c) => (c.color_at_local(self.display_time(session, c)), c.media, session.media().info(c.media)),
                None => (ClipColor::default(), k, None),
            };
            if let Some(m) = self.color_models.get_mut(&k) {
                m.load(&back, Some(media), info.as_ref());
            }
            self.shown_color.insert(k, back);
            return;
        }
        self.shown_color.insert(k, color.clone());
        if !changed {
            return;
        }
        // Interpret As on a selection of clips: the same space goes to every selected clip (one more undo step).
        if let ColorTargetResolution::Clip(id) = self.resolution.clone()
            && color.source != before.source
            && session.selection().len() > 1
            && session.selection().contains(&id)
        {
            let sel: Vec<Id> = session.selection().iter().copied().collect();
            session.set_interpretation(color.source, &sel);
        }
        if self.gesture_depth > 0 {
            self.gesture_has_edit = true;
        }
        self.emit(ColorGradeEvent::Change);
    }

    /// Writes the model's Color Graph to the target (one undo step per gesture, like `commit`). Not keyframed.
    fn commit_graph(&mut self, session: &mut EditorSession, k: Id, g: ColorGraph) {
        if Some(k) != self.key {
            return;
        }
        let continuing = self.gesture_depth > 0 && self.gesture_has_edit;
        let mut ids = (self.make_ids)();
        let changed = self.edit_target(session, Some("Color Graph"), continuing, |c| {
            if c.color_graph().as_ref() == Some(&g) {
                return false;
            }
            c.set_color_graph(Some(g), &mut *ids);
            true
        });
        if changed != Some(true) {
            return;
        }
        if self.gesture_depth > 0 {
            self.gesture_has_edit = true;
        }
        self.emit(ColorGradeEvent::GradeSwitchChange);
        self.update_lower_page();
        self.emit(ColorGradeEvent::Change);
    }

    /// Writes the Basic Sharpen row to the target's Sharpen effect (one undo step per gesture; the Timeline grade layer
    /// is created by the first non-zero value). known limit: only the target clip, a "Linked" source's other cuts keep their
    /// own Sharpen; upgrade when Sharpen joins the grade link (needs a ProjectFile change).
    fn commit_sharpen(&mut self, session: &mut EditorSession, k: Id, v: f32) {
        if Some(k) != self.key {
            return;
        }
        let continuing = self.gesture_depth > 0 && self.gesture_has_edit;
        let mut ids = (self.make_ids)();
        let changed = self.edit_target(session, Some("Sharpen"), continuing, |c| c.set_sharpen_amount(v, &mut *ids));
        if changed != Some(true) {
            return;
        }
        if self.gesture_depth > 0 {
            self.gesture_has_edit = true;
        }
        self.emit(ColorGradeEvent::Change);
    }

    // MARK: Model events (Swift's hooks)

    /// Handles the events the models queued, in order, until none are left. The host calls this after every call into a model.
    pub fn pump(&mut self, session: &mut EditorSession, clipboard: &mut ColorClipboard) {
        for _ in 0..64 {
            let keys: Vec<Id> = self.color_models.keys().copied().collect();
            let mut any = false;
            for k in keys {
                let events = self.color_models.get_mut(&k).map(|m| m.take_events()).unwrap_or_default();
                for e in events {
                    any = true;
                    self.handle_model_event(session, clipboard, k, e);
                }
            }
            if !any {
                break;
            }
        }
    }

    fn handle_model_event(
        &mut self,
        session: &mut EditorSession,
        clipboard: &mut ColorClipboard,
        k: Id,
        e: ColorInspectorEvent,
    ) {
        match e {
            ColorInspectorEvent::GestureBegan => self.begin_gesture(session),
            ColorInspectorEvent::GestureEnded => self.end_gesture(),
            ColorInspectorEvent::Change(c) => self.commit(session, k, c),
            ColorInspectorEvent::GraphChange(g) => self.commit_graph(session, k, g),
            ColorInspectorEvent::SharpenSet(v) => self.commit_sharpen(session, k, v),
            ColorInspectorEvent::GradeViewChange => {
                if Some(k) != self.key {
                    return;
                }
                self.emit(ColorGradeEvent::GradeSwitchChange);
                self.update_lower_page();
                self.emit(ColorGradeEvent::Change);
            }
            ColorInspectorEvent::ViewerAidChange => self.update_viewer_aids(session),
            ColorInspectorEvent::CopyColor => {
                self.copy_grade(session, clipboard);
            }
            ColorInspectorEvent::PasteColor => {
                if !self.paste_grade(session, clipboard, false) {
                    self.beep();
                }
            }
            ColorInspectorEvent::GradeAction(a) => match self.target_clip(session).map(|c| c.id) {
                Some(id) => self.grade_action(session, a, id),
                None => self.beep(),
            },
            ColorInspectorEvent::GradeWholeSequence => self.pick_whole_sequence(session),
            ColorInspectorEvent::ResetAll => {
                if let Some(id) = self.target_clip(session).map(|c| c.id) {
                    session.reset_color(id);
                }
            }
            ColorInspectorEvent::ProjectInputChange(space) => session.set_project_input_color_space(space),
            ColorInspectorEvent::AutoTone(effect) => self.auto_tone(session, k, effect),
            ColorInspectorEvent::PickWhiteBalance(effect) => self.pick_white_balance(k, effect),
            ColorInspectorEvent::Keyframe(action, id) => self.keyframe(session, action, id, k),
            // The LUT library belongs to the host (it owns the store and the persisted recents).
            ColorInspectorEvent::RecentLut(_)
            | ColorInspectorEvent::ToggleFavouriteLut(_)
            | ColorInspectorEvent::ImportLuts(_) => self.host_lut_events.push(e),
        }
    }

    // MARK: Keyframes (INTERACTION-AUDIT rule 2)

    /// The keyframe rings and navigation of the target: the state of every animated control at the playhead.
    fn refresh_keyframe_states(&mut self, session: &EditorSession) {
        let Some(k) = self.key else { return };
        let clip = self.target_clip(session);
        let local = clip.map_or(Time::ZERO, |c| session.playhead() - c.start);
        let states = ColorKeyTarget::states(clip, local, self.edit_time(session, k).local.is_some());
        if let Some(m) = self.color_models.get_mut(&k)
            && m.keyframe_states != states
        {
            m.keyframe_states = states;
        }
    }

    /// A click on a color control's ring or navigation. Turning animation off removes every key of the control and asks
    /// first (`confirm_stop_animating`); a key is added or removed at the playhead (beep when it is not over the target).
    pub fn keyframe(&mut self, session: &mut EditorSession, action: ColorKeyAction, id: ColorKeyID, k: Id) {
        if Some(k) != self.key || self.gesture_depth != 0 {
            return;
        }
        let keys = id.target.parameter_keys();
        let n = id.effect as usize;
        let name = id.target.name();
        match action {
            ColorKeyAction::Previous | ColorKeyAction::Next => {
                let Some(clip) = self.target_clip(session) else {
                    self.beep();
                    return;
                };
                let local = session.playhead() - clip.start;
                let times = ColorKeyTarget::navigable_times(clip, n, id.target);
                let t = if action == ColorKeyAction::Previous {
                    times.iter().rev().find(|t| **t < local).copied()
                } else {
                    times.iter().find(|t| **t > local).copied()
                };
                let Some(t) = t else {
                    self.beep();
                    return;
                };
                let to = clip.start + t;
                session.seek(to);
                self.sync(session, Change::PLAYHEAD);
            }
            ColorKeyAction::ToggleAnimation => {
                let animated = self.target_clip(session).is_some_and(|c| c.is_color_animated(n, &keys));
                if animated {
                    if !self.confirm_stop_animating {
                        return;
                    }
                    let at = self.target_clip(session).map_or(Time::ZERO, |c| self.display_time(session, c));
                    let mut ids = (self.make_ids)();
                    self.edit_keys(session, &format!("Stop Animating {name}"), |c| {
                        c.set_color_animated(false, n, &keys, Some(at), &mut *ids)
                    });
                } else {
                    let Some(at) = self.edit_time(session, k).local else {
                        self.beep();
                        return;
                    };
                    let mut ids = (self.make_ids)();
                    self.edit_keys(session, &format!("Animate {name}"), |c| {
                        c.set_color_animated(true, n, &keys, Some(at), &mut *ids)
                    });
                }
            }
            ColorKeyAction::ToggleKey => {
                let Some(at) = self.edit_time(session, k).local else {
                    self.beep();
                    return;
                };
                let has = self.target_clip(session).is_some_and(|c| c.has_color_key(n, &keys, at));
                let title = if has { format!("Remove {name} Keyframe") } else { format!("Add {name} Keyframe") };
                let mut ids = (self.make_ids)();
                self.edit_keys(session, &title, |c| c.toggle_color_key(n, &keys, at, &mut *ids));
            }
        }
    }

    /// One undo step `name` on the target (the Timeline grade layer is created by its first edit).
    fn edit_keys(&mut self, session: &mut EditorSession, name: &str, body: impl FnOnce(&mut Clip) -> bool) {
        let name = SQL10n::undo_name(name);
        let Some(changed) = self.edit_target(session, Some(&name), false, body) else { return };
        if !changed {
            self.beep();
            return;
        }
        self.sync(session, Change::PROJECT);
        self.emit(ColorGradeEvent::Change);
    }

    /// Clip-local time the panel shows: the playhead, kept on the clip's frames (outside it, the first or last frame).
    fn display_time(&self, session: &EditorSession, clip: &Clip) -> Time {
        Self::local(clip, session.playhead(), Self::frame_duration(session))
    }

    // MARK: Grades: copy/paste, links, ranges (COLOR-GRADE-LINKS)

    /// Copies the target's grade (Copy while the Color panel has focus). False when nothing is shown.
    pub fn copy_grade(&mut self, session: &EditorSession, clipboard: &mut ColorClipboard) -> bool {
        if self.key.is_none() {
            return false;
        }
        let clip = self.target_clip(session);
        clipboard.copy(clip.map(|c| c.color_grade_effects()).unwrap_or_default(), clip.and_then(|c| c.color_graph()));
        true
    }

    /// Pastes the copied grade: for "Whole sequence" onto the Timeline grade, else onto every selected picture clip (the
    /// picked clip when nothing is selected). One undo step. False when nothing changed.
    pub fn paste_grade(&mut self, session: &mut EditorSession, clipboard: &ColorClipboard, on_top: bool) -> bool {
        let Some(fx) = clipboard.effects().map(|e| e.to_vec()) else { return false };
        let g = clipboard.graph().cloned();
        if matches!(self.resolution, ColorTargetResolution::Sequence { .. }) {
            return session.paste_sequence_grade(fx, Some(g), on_top);
        }
        if session.selection().is_empty()
            && let Some(p) = self.target.pick()
        {
            return session.paste_color(fx, Some(g), Some(&BTreeSet::from([p])), on_top) > 0;
        }
        session.paste_color(fx, Some(g), None, on_top) > 0
    }

    pub fn can_copy_grade(&self) -> bool {
        self.key.is_some()
    }

    pub fn can_paste_grade(&self, session: &EditorSession, clipboard: &ColorClipboard) -> bool {
        if !clipboard.has_color() {
            return false;
        }
        if matches!(self.resolution, ColorTargetResolution::Sequence { .. }) {
            return true;
        }
        !session.selection().is_empty() || self.target.pick().is_some()
    }

    pub fn grade_action(&mut self, session: &mut EditorSession, a: ColorGradeAction, id: Id) {
        let ok = match a {
            ColorGradeAction::LinkSelected => session.link_grades(id, None).is_some(),
            ColorGradeAction::LinkSource => session.link_all_clips_of_source(id).is_some(),
            ColorGradeAction::Unlink => session.set_grade_linked_to_source(id, false),
            ColorGradeAction::AddRange => session.add_range_grade(id).is_some(),
            ColorGradeAction::SetRangeToInOut(n) | ColorGradeAction::WholeClip(n) => {
                let all = Self::clip(session, id).map(|c| c.color_grade_effects()).unwrap_or_default();
                match usize::try_from(n - 1).ok().and_then(|i| all.get(i)) {
                    None => false,
                    Some(fx) => {
                        let whole = matches!(a, ColorGradeAction::WholeClip(_));
                        session.set_color_range(fx.id, id, whole)
                    }
                }
            }
        };
        if !ok {
            self.beep();
        }
    }

    /// Range texts and the link size for the panel titles.
    fn update_grade_info(&mut self, session: &EditorSession, clip_id: Option<Id>) {
        let fd = Self::frame_duration(session);
        let clip = clip_id.and_then(|id| Self::clip(session, id));
        let mut labels: BTreeMap<i64, String> = BTreeMap::new();
        for (n, e) in clip.map(|c| c.color_grade_effects()).unwrap_or_default().iter().enumerate() {
            let Some(r) = e.color_range else { continue };
            labels.insert(
                n as i64 + 1,
                format!(
                    "{}\u{2013}{}",
                    MarkersPanelModel::timecode(r.start, fd),
                    MarkersPanelModel::timecode(r.end(), fd)
                ),
            );
        }
        let n = clip.map_or(0, |c| session.grade_link_members(c.id).len()) as i64;
        if let Some(m) = self.model_mut() {
            if m.effect_range_labels != labels {
                m.effect_range_labels = labels;
            }
            if m.linked_clip_count != n {
                m.linked_clip_count = n;
            }
        }
    }

    // MARK: Rules (pure, shared by both platforms and the tests)

    /// The Timeline panel's header text: the hint only while nothing gradable is picked.
    pub fn timeline_detail_for(resolution: &ColorTargetResolution) -> String {
        if matches!(resolution, ColorTargetResolution::Message(_)) {
            Self::TIMELINE_HINT.to_string()
        } else {
            String::new()
        }
    }

    /// Every clip inside nested clip `c`'s sequence, deeper nests included (empty for a plain clip). Cycles are cut.
    pub fn nested_clips(c: &Clip, project: &Project) -> BTreeSet<Id> {
        let mut out = BTreeSet::new();
        let mut seen: BTreeSet<Id> = BTreeSet::new();
        let mut queue: Vec<Id> = c.sequence.into_iter().collect();
        while let Some(tid) = queue.pop() {
            if !seen.insert(tid) {
                continue;
            }
            let Some(t) = project.timeline(tid) else { continue };
            for clip in t.tracks.iter().flat_map(|tr| tr.clips()) {
                out.insert(clip.id);
                if let Some(s) = clip.sequence {
                    queue.push(s);
                }
            }
        }
        out
    }

    /// Before = the target (and every clip sharing its grade) ungraded; Split = the same on the left half; After or no
    /// target = nil (graded).
    pub fn color_bypass(mode: ColorCompareMode, target: Option<Id>, linked: &[Id]) -> Option<ColorBypass> {
        let target = target?;
        let mut clips: BTreeSet<Id> = linked.iter().copied().collect();
        clips.insert(target);
        match mode {
            ColorCompareMode::After => None,
            ColorCompareMode::Before => Some(ColorBypass { clips, mode: ColorBypassMode::Before }),
            ColorCompareMode::Split => Some(ColorBypass { clips, mode: ColorBypassMode::Split }),
        }
    }

    /// Which clip the monitor isolates: only while the lower panel is on Clips, the strip is visible and a clip is picked.
    pub fn solo_clip(clips_mode: bool, strip_visible: bool, picked: Option<Id>) -> Option<Id> {
        if clips_mode && strip_visible { picked } else { None }
    }

    /// Why the eyedropper and Auto cannot measure the selected clip alone right now (nil = they can). They read the
    /// Program monitor's composite, so anything else visible there, or later Color effects, would be measured too.
    pub fn sampling_block_reason(timeline: &Timeline, clip: &Clip, playhead: Time) -> Option<String> {
        if !clip.timeline().contains(playhead) {
            return Some("Move the playhead over the clip to measure it.".to_string());
        }
        // Auto and the eyedropper set Simple values; the Pro grade on screen would be measured with them.
        if clip.active_grade() == ActiveGrade::Pro {
            return Some(
                "The Pro grade is on; the measurement would include its Color Graph. Switch to Simple to measure."
                    .to_string(),
            );
        }
        // The Timeline grade measures the finished picture: everything below it is its input.
        if clip.is_sequence_grade() {
            return None;
        }
        let none = |_: Id| -> Option<&Timeline> { None };
        let layers: Vec<_> = timeline
            .video_layers(playhead, &none, &LayerHooks::plain(), None)
            .into_iter()
            .filter(|l| l.matte_for.is_none())
            .collect();
        if layers.len() > 1 {
            let others = layers.iter().filter(|l| l.clip != clip.id);
            if let Some(g) = timeline.sequence_grade_clip()
                && others.clone().all(|l| l.clip == g.id)
            {
                return Some(
                        "The Timeline grade is on screen too; the measurement would include it. Turn its track off to measure the clip."
                            .to_string(),
                    );
            }
            return Some(
                "Other layers are visible at the playhead; the measurement would include them. Hide the other tracks or move the playhead."
                    .to_string(),
            );
        }
        if clip.effects.iter().filter(|e| e.is_color() && e.enabled).count() > 1 {
            return Some(
                "This clip has more than one Color effect; the measurement would include the later ones.".to_string(),
            );
        }
        None
    }

    /// Why the eyedropper and Auto cannot measure while the viewer compares (nil on After).
    pub fn compare_block_reason(mode: ColorCompareMode) -> Option<String> {
        match mode {
            ColorCompareMode::After => None,
            ColorCompareMode::Before => Some(
                "The viewer shows Before; the measurement would miss the grade. Switch the viewer to After to measure.".to_string(),
            ),
            ColorCompareMode::Split => Some(
                "The viewer shows Split; the measurement would miss part of the grade. Switch the viewer to After to measure."
                    .to_string(),
            ),
        }
    }

    /// "n uses" for a clip: the clips that share its grade (itself alone when it is not linked).
    pub fn header_detail_of(r: &ColorTargetResolution, session: &EditorSession) -> Option<String> {
        match r {
            ColorTargetResolution::Clip(id) => {
                let p = session.project();
                let mut n = session.grade_link_members(*id).len() as i64;
                // Uses of a source share its grade before the first edit writes the link.
                if p.is_grade_linked_to_source(*id) {
                    let media = p
                        .timelines
                        .iter()
                        .flat_map(|t| t.tracks.iter())
                        .flat_map(|tr| tr.clips())
                        .find(|c| c.id == *id)
                        .map(|c| c.media);
                    if let Some(media) = media {
                        let mut uses = 0;
                        for t in p.timelines.iter() {
                            for tr in t.tracks.iter() {
                                uses += tr
                                    .clips()
                                    .iter()
                                    .filter(|c| {
                                        c.media == media && c.is_source_gradeable() && p.is_grade_linked_to_source(c.id)
                                    })
                                    .count() as i64;
                            }
                        }
                        n = n.max(uses);
                    }
                }
                Some(ColorUses::text(n.max(1)))
            }
            ColorTargetResolution::Sequence { .. } => Some("Whole sequence".to_string()),
            ColorTargetResolution::Message(_) => None,
        }
    }

    pub fn local(clip: &Clip, playhead: Time, frame_duration: Time) -> Time {
        (playhead - clip.start).max(Time::ZERO).min((clip.duration() - frame_duration).max(Time::ZERO))
    }

    pub fn has_animated_grade(clip: &Clip) -> bool {
        clip.effects.iter().any(|e| e.is_color() && e.parameters.values().any(|p| p.is_animated()))
    }
}

/// Keeps `ColorClipRow` and `ColorSpaceID` reachable for hosts that build the Sources tiles from this controller.
pub type SourceRows = Vec<ColorClipRow>;
pub type ProjectInput = Option<ColorSpaceID>;

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    #[test]
    fn bypass_follows_the_compare_mode() {
        assert!(ColorGradeController::color_bypass(ColorCompareMode::After, Some(id(1)), &[id(2)]).is_none());
        assert!(ColorGradeController::color_bypass(ColorCompareMode::Before, None, &[]).is_none());
        let b = ColorGradeController::color_bypass(ColorCompareMode::Before, Some(id(1)), &[id(2)]);
        assert_eq!(b.as_ref().map(|b| b.mode), Some(ColorBypassMode::Before));
        assert_eq!(b.map(|b| b.clips), Some(BTreeSet::from([id(1), id(2)])));
        let s = ColorGradeController::color_bypass(ColorCompareMode::Split, Some(id(1)), &[]);
        assert_eq!(s.map(|b| b.mode), Some(ColorBypassMode::Split));
    }

    #[test]
    fn the_solo_needs_the_clips_panel_and_the_strip() {
        assert_eq!(ColorGradeController::solo_clip(true, true, Some(id(1))), Some(id(1)));
        assert_eq!(ColorGradeController::solo_clip(false, true, Some(id(1))), None);
        assert_eq!(ColorGradeController::solo_clip(true, false, Some(id(1))), None);
        assert_eq!(ColorGradeController::solo_clip(true, true, None), None);
    }

    #[test]
    fn compare_blocks_the_measurement_except_on_after() {
        assert!(ColorGradeController::compare_block_reason(ColorCompareMode::After).is_none());
        assert!(
            ColorGradeController::compare_block_reason(ColorCompareMode::Before).is_some_and(|s| s.contains("Before"))
        );
        assert!(
            ColorGradeController::compare_block_reason(ColorCompareMode::Split).is_some_and(|s| s.contains("Split"))
        );
    }

    #[test]
    fn the_timeline_hint_shows_only_without_a_target() {
        let m = ColorTargetResolution::Message(String::new());
        assert_eq!(ColorGradeController::timeline_detail_for(&m), ColorGradeController::TIMELINE_HINT);
        assert_eq!(ColorGradeController::timeline_detail_for(&ColorTargetResolution::Clip(id(1))), "");
    }

    #[test]
    fn local_time_stays_on_the_clips_frames() {
        use sq_core_model::TrackKind;
        use sq_core_time::TimeRange;
        let fd = Time::new(1, 30);
        let c = Clip::new(
            id(1),
            "c",
            id(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(2, 1)),
            Time::new(10, 1),
        );
        assert_eq!(ColorGradeController::local(&c, Time::new(5, 1), fd), Time::ZERO);
        assert_eq!(ColorGradeController::local(&c, Time::new(11, 1), fd), Time::new(1, 1));
        assert_eq!(ColorGradeController::local(&c, Time::new(99, 1), fd), Time::new(2, 1) - fd);
    }

    #[test]
    fn a_clip_without_color_effects_has_no_animated_grade() {
        use sq_core_model::TrackKind;
        use sq_core_time::TimeRange;
        let c = Clip::new(id(1), "c", id(2), TrackKind::Video, TimeRange::new(Time::ZERO, Time::new(1, 1)), Time::ZERO);
        assert!(!ColorGradeController::has_animated_grade(&c));
        let _ = TrackKind::Audio;
    }

    #[test]
    fn nested_clips_of_a_plain_clip_are_empty() {
        use sq_core_model::TrackKind;
        use sq_core_time::TimeRange;
        let c = Clip::new(id(1), "c", id(2), TrackKind::Video, TimeRange::new(Time::ZERO, Time::new(1, 1)), Time::ZERO);
        let p = Project::new(id(9), "p", Vec::new(), Vec::new());
        assert!(ColorGradeController::nested_clips(&c, &p).is_empty());
    }
}

// Swift: MonitorPanelModel.swift, MonitorPanelModel+Options.swift, MonitorPanelModel+Variants.swift
//! The Program / Source monitor's state, menus and command routing. The Swift hooks (`onSeek`, `onAction`, ...) are
//! [`MonitorEvent`]s the model pushes to `events`; the owner drains them with [`MonitorPanelModel::take_events`] and
//! sets [`MonitorWiring`] for the hooks whose mere presence changes what the model offers. Menu rows push
//! [`MenuCommand`]s into the shared [`MenuQueue`]; the panel applies them in `sync` (a row's closure cannot hold the
//! model).

use crate::monitor_drop_indicator::{DropIndicator, SourceViewerMode};
use crate::monitor_menus::{MonitorMenus, OptionMenuActions, OptionMenuState};
use crate::safe_zone_choice::SafeZoneChoice;
use crate::{angle_tile::AngleTile, memory_defaults::MemoryDefaults};
use sq_core_effects::sequence_conform::{AspectPreset, SequenceConform};
use sq_core_time::{Id, Time};
use sq_draw::monitor::monitor_footer::{MonitorFooter, ScrubHit};
use sq_draw::monitor::monitor_guides::MonitorGuides;
use sq_draw::monitor::monitor_modes::{MonitorAction, MonitorMode, MonitorZoom};
use sq_draw::monitor::viewer_frame_guides::{AspectFrame, SafeMarginSizes};
use sq_editor_session::EditorSession;
use sq_editor_session::es01_session_core::{AutoQualityGovernor, MonitorQuality};
use sq_media::waveform_data::WaveformData;
use sq_playback::engine::preview_rate::PreviewRate;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::command_map::CommandMap;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;
use sq_uikit::timecode::Timecode;
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

/// Source monitor: a clip opened earlier (title popup, most recent first).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SourceItem {
    /// The clip.
    pub id: Id,
    /// Shown name.
    pub name: String,
}

/// Program monitor: a frame format of the active sequence (a variant).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct FormatItem {
    /// The variant.
    pub id: Id,
    /// Shown name.
    pub name: String,
}

/// Program monitor: an open sequence (title popup, most recent tab last).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SequenceItem {
    /// The sequence.
    pub id: Id,
    /// Shown name.
    pub name: String,
}

/// What the Program monitor's empty layer shows: nothing, the no-sequence state, or the empty-timeline state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProgramEmptyKind {
    /// A normal picture.
    None,
    /// No sequence is open.
    NoSequence,
    /// The sequence has no clip and no caption.
    EmptyTimeline,
}

impl ProgramEmptyKind {
    /// The Program monitor's empty-state line.
    pub fn hint(self) -> &'static str {
        if self == ProgramEmptyKind::EmptyTimeline {
            "Nothing on the timeline yet. Drop a clip here"
        } else {
            "Create a sequence or drop a clip here"
        }
    }
}

/// What the Swift model's `on*` hooks reported; the model's owner turns them into session calls and engine commands.
#[derive(Clone, Debug, PartialEq)]
pub enum MonitorEvent {
    /// `onNewSequence`.
    NewSequence,
    /// `onTransparencyGridChange`.
    TransparencyGridChange(bool),
    /// `onPreviewRateChange`.
    PreviewRateChange(PreviewRate),
    /// `onFullScreen`.
    FullScreen,
    /// `onShowScopes`.
    ShowScopes,
    /// `onPickAngle`: tile index, 0-based.
    PickAngle(usize),
    /// `onPickSource`.
    PickSource(Id),
    /// `onPickSequence`: connected by `sync_formats`.
    PickSequence(Id),
    /// `onPickFormat`: connected by `sync_formats`.
    PickFormat(Option<Id>),
    /// `onAddFormat`: connected by `sync_formats`.
    AddFormat(AspectPreset),
    /// `onRemoveFormat`: connected by `sync_formats`.
    RemoveFormat(Id),
    /// `onCloseSource`.
    CloseSource,
    /// `onCloseAllSources`.
    CloseAllSources,
    /// `onDropMedia`.
    DropMedia(Vec<Id>),
    /// `onDropFiles`.
    DropFiles(Vec<PathBuf>),
    /// `onSeek`.
    Seek(Time),
    /// `onAction`.
    Action(MonitorAction),
    /// `onZoomChange`.
    ZoomChange(MonitorZoom),
    /// `onQualityChange`.
    QualityChange(MonitorQuality),
    /// `onScrubBegan`.
    ScrubBegan,
    /// `onScrub` (only while [`MonitorWiring::scrub`] is set, else a `Seek`).
    Scrub(Time),
    /// `onScrubEnded`.
    ScrubEnded,
    /// `onDragEnded`.
    DragEnded,
    /// `onMarkEdit`: the new In, or the new stored Out.
    MarkEdit(ScrubHit, Time),
    /// `onSafeZoneChange`.
    SafeZoneChange(SafeZoneChoice),
    /// A row of the Program monitor's right-click menu that the app root runs.
    ProgramMenu(ProgramMenuAction),
}

/// What a Program right-click row asks of the app root (Swift ran these closures in `MonitorHost.programMenuItems`).
#[derive(Clone, Debug, PartialEq)]
pub enum ProgramMenuAction {
    /// An editor command, run like its key.
    Command(sq_uikit::editor_command::EditorCommand),
    /// Add Rectangle / Ellipse Mask on the shown clip.
    AddMask(sq_core_model::MaskShapeKind),
    /// Add Picture Mask reading this track.
    AddPictureMask(Option<Id>),
    /// Add Color Range Mask.
    AddColorRangeMask,
    /// Delete Masks.
    DeleteMasks,
    /// Subject Mask Edges: the choice at this index of `ProgramMenuState::subject_edges`.
    SetSubjectMaskEdges(usize),
}

/// Which optional Swift hooks the owner consumes. The model offers a menu row, a button or a route only for these
/// (Swift tested `hook != nil`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MonitorWiring {
    /// `onNewSequence`: the empty Program monitor offers the New Sequence button.
    pub new_sequence: bool,
    /// `onPreviewRateChange`: the options menu offers Preview Speed.
    pub preview_rate: bool,
    /// `onShowScopes`: the options menu offers Scopes.
    pub show_scopes: bool,
    /// `onFullScreen`: the options menu offers Full Screen.
    pub full_screen: bool,
    /// `onMarkEdit`: the grips are editable.
    pub mark_edit: bool,
    /// `onScrub`: scrubbing reports `Scrub` instead of `Seek`.
    pub scrub: bool,
}

/// What a menu row asks of the model (rows hold no reference to it).
#[derive(Clone, Debug, PartialEq)]
pub enum MenuCommand {
    /// Zoom popup.
    SetZoom(MonitorZoom),
    /// Quality popup.
    SetQuality(MonitorQuality),
    /// An action row.
    Perform(MonitorAction),
    /// Show Overlays.
    ToggleOverlays,
    /// Platform Safe Zone popup.
    SetSafeZone(SafeZoneChoice),
    /// Show platform UI.
    SetShowsPlatformMock(bool),
    /// Action Safe size.
    SetSafeAction(i64),
    /// Title Safe size.
    SetSafeTitle(i64),
    /// Transparency Grid.
    SetShowsTransparencyGrid(bool),
    /// Mask Tint (the evaluated Magic mattes over the picture).
    SetShowsMaskTint(bool),
    /// Rulers.
    ToggleRulers,
    /// Clear Guides.
    ClearGuides,
    /// Resolution Badge.
    SetShowsResolutionBadge(bool),
    /// Preview Speed.
    SetPreviewRate(PreviewRate),
    /// Aspect Frame.
    SetAspectFrame(AspectFrame),
    /// Scopes.
    ShowScopes,
    /// Full Screen.
    FullScreen,
    /// A hook-bound row (source, sequence and format popups): becomes the event as it is.
    Event(MonitorEvent),
}

/// The rows' way back to their owner. Single thread (the UI thread), owned by the model (or the Source core), cloned into
/// every row closure of the menus it builds; drained by [`MonitorPanelModel::apply_menu_commands`].
#[derive(Debug)]
pub struct MenuQueue<T = MenuCommand>(Rc<RefCell<Vec<T>>>);

impl<T> Default for MenuQueue<T> {
    fn default() -> Self {
        MenuQueue(Rc::new(RefCell::new(Vec::new())))
    }
}

impl<T> Clone for MenuQueue<T> {
    fn clone(&self) -> Self {
        MenuQueue(Rc::clone(&self.0))
    }
}

impl<T> MenuQueue<T> {
    /// Queues `c`.
    pub fn push(&self, c: T) {
        self.0.borrow_mut().push(c);
    }
    /// Takes everything queued, oldest first.
    pub fn take(&self) -> Vec<T> {
        std::mem::take(&mut *self.0.borrow_mut())
    }
}

/// Swift `AspectFrame.rawValue` (sq-draw's port has no raw values; the remembered setting stores them).
fn aspect_frame_raw(f: AspectFrame) -> &'static str {
    match f {
        AspectFrame::Off => "off",
        AspectFrame::Vertical9x16 => "vertical9x16",
        AspectFrame::Portrait4x5 => "portrait4x5",
        AspectFrame::Square1x1 => "square1x1",
        AspectFrame::Wide16x9 => "wide16x9",
    }
}

/// The Program / Source monitor's state.
pub struct MonitorPanelModel {
    /// Program or Source.
    pub mode: MonitorMode,
    /// The playhead.
    pub current_time: Time,
    /// The shown length.
    pub duration: Time,
    /// Mark In.
    pub mark_in: Option<Time>,
    /// Stored Mark Out (one frame past the Out frame).
    pub mark_out: Option<Time>,
    /// Playing.
    pub is_playing: bool,
    /// Program monitor: false shows the "no sequence open" state.
    pub has_sequence: bool,
    /// Program monitor: the open sequence has no clip and no caption (a fresh project).
    pub timeline_is_empty: bool,
    zoom: MonitorZoom,
    quality: MonitorQuality,
    /// One frame.
    pub frame_duration: Time,
    /// Drop-frame timecode.
    pub drop_frame: bool,
    /// Loop toggle (wrench menu).
    pub is_looping: bool,
    safe_margins: bool,
    /// Debug HUD line (scrub latency); `None` = hidden.
    pub latency_text: Option<String>,
    /// Program monitor: the dropped-frame dot (off by Preferences).
    pub drop_indicator_enabled: bool,
    drop_amber: bool,
    drop_tooltip: String,
    drop_badge_text: Option<String>,
    drop_realtime_not_achieved: bool,
    effective_quality: MonitorQuality,
    governor: AutoQualityGovernor,
    /// Picture size of the shown sequence (resolution badge).
    pub picture_size: Option<(i64, i64)>,
    shows_resolution_badge: bool,
    shows_transparency_grid: bool,
    shows_mask_tint: bool,
    shows_rulers: bool,
    overlays_hidden: bool,
    /// The guides pulled from the rulers (session-only).
    pub guides: MonitorGuides,
    aspect_frame: AspectFrame,
    safe_margin_sizes: SafeMarginSizes,
    preview_rate: PreviewRate,
    /// File name of the offline media under the playhead; non-nil shows the "Media offline" card over the picture.
    pub offline_file_name: Option<String>,
    /// The engine cannot draw (compositor creation failed): the card says so instead of showing a silent black picture.
    pub engine_failure: Option<String>,
    drops: DropIndicator,
    /// Source monitor: picture, or the waveform of audio-only media.
    pub viewer_mode: SourceViewerMode,
    /// Source monitor: every angle of the Angles clip at the playhead (multi-angle view); `None` = the normal viewer.
    pub angle_tiles: Option<Vec<AngleTile>>,
    /// The Source player's waveform for audio-only media.
    pub source_waveform: Option<WaveformData>,
    /// Source monitor: the clips opened earlier (title popup, most recent first).
    pub source_items: Vec<SourceItem>,
    /// The clip shown.
    pub source_current: Option<Id>,
    /// Markers of the shown clip (M).
    pub marker_times: Vec<Time>,
    /// The active sequence's own format label (first item of the format popup).
    pub format_base_name: String,
    /// Name of the active sequence: the format popup's title while the sequence's own format is shown.
    pub sequence_name: String,
    /// The open sequences (title popup of the Program monitor) and the shown one.
    pub sequence_items: Vec<SequenceItem>,
    /// The shown sequence.
    pub sequence_current: Option<Id>,
    /// The active sequence's variants.
    pub format_items: Vec<FormatItem>,
    /// The variant shown (`None` = the sequence's own format).
    pub format_current: Option<Id>,
    /// Program monitor on the Color page: showing a clip's whole source file (own time axis). Locks the marks.
    pub source_file_view: bool,
    /// Sequence Settings: the timecode of time zero.
    pub timecode_origin: Time,
    /// Sequence Settings: the frame-count display.
    pub timecode_frames_only: bool,
    safe_zone: SafeZoneChoice,
    shows_platform_mock: bool,
    /// Fills the right-click menu of the picture area (the owner sets it before a right click reaches the panel).
    pub context_menu: Vec<SQMenuItem>,
    /// Which optional hooks the owner consumes.
    pub wired: MonitorWiring,
    events: Vec<MonitorEvent>,
    menu_queue: MenuQueue,
    defaults: Box<dyn UiDefaults>,
}

impl MonitorPanelModel {
    /// Defaults key of Safe Margins.
    pub const SAFE_MARGINS_KEY: &'static str = "sq.showSafeAreas";
    /// Defaults key of the rulers.
    pub const RULERS_KEY: &'static str = "sq.monitor.rulers";
    /// Defaults key of the hidden overlays.
    pub const OVERLAYS_HIDDEN_KEY: &'static str = "sq.monitor.overlaysHidden";
    /// Defaults key of the aspect frame.
    pub const ASPECT_FRAME_KEY: &'static str = "sq.monitor.aspectFrame";
    /// Defaults key of the Action Safe size.
    pub const SAFE_MARGIN_ACTION_KEY: &'static str = "sq.monitor.safeMarginAction";
    /// Defaults key of the Title Safe size.
    pub const SAFE_MARGIN_TITLE_KEY: &'static str = "sq.monitor.safeMarginTitle";
    const RESOLUTION_BADGE_KEY: &'static str = "sq.monitor.resolutionBadge";
    const TRANSPARENCY_GRID_KEY: &'static str = "sq.monitor.transparencyGrid";
    /// Defaults key of Mask Tint (on by default: the key only exists once the user turned it off).
    pub const MASK_TINT_KEY: &'static str = "sq.showMaskTint";

    /// A model over an in-memory settings store.
    pub fn new(frame_duration: Time, mode: MonitorMode) -> MonitorPanelModel {
        Self::with_defaults(frame_duration, mode, Box::new(MemoryDefaults::default()))
    }

    /// A model over `defaults` (the host's settings store). The Program monitor reads its remembered settings.
    pub fn with_defaults(frame_duration: Time, mode: MonitorMode, defaults: Box<dyn UiDefaults>) -> MonitorPanelModel {
        let flag = |k: &str| defaults.integer(k).is_some_and(|v| v != 0);
        let program = mode == MonitorMode::Program;
        let drops = DropIndicator::default();
        let mut m = MonitorPanelModel {
            mode,
            current_time: Time::ZERO,
            duration: Time::ZERO,
            mark_in: None,
            mark_out: None,
            is_playing: false,
            has_sequence: true,
            timeline_is_empty: false,
            zoom: MonitorZoom::Fit,
            quality: MonitorQuality::Full,
            frame_duration,
            drop_frame: false,
            is_looping: false,
            safe_margins: false,
            latency_text: None,
            drop_indicator_enabled: true,
            drop_amber: false,
            drop_tooltip: drops.tooltip(),
            drop_badge_text: None,
            drop_realtime_not_achieved: false,
            effective_quality: MonitorQuality::Full,
            governor: AutoQualityGovernor::new(MonitorQuality::Full),
            picture_size: None,
            shows_resolution_badge: flag(Self::RESOLUTION_BADGE_KEY),
            shows_transparency_grid: flag(Self::TRANSPARENCY_GRID_KEY),
            shows_mask_tint: defaults.integer(Self::MASK_TINT_KEY).is_none_or(|v| v != 0),
            shows_rulers: false,
            overlays_hidden: false,
            guides: MonitorGuides::new(),
            aspect_frame: AspectFrame::Off,
            safe_margin_sizes: SafeMarginSizes::DEFAULT,
            preview_rate: PreviewRate::NORMAL,
            offline_file_name: None,
            engine_failure: None,
            drops,
            viewer_mode: SourceViewerMode::Picture,
            angle_tiles: None,
            source_waveform: None,
            source_items: Vec::new(),
            source_current: None,
            marker_times: Vec::new(),
            format_base_name: String::new(),
            sequence_name: String::new(),
            sequence_items: Vec::new(),
            sequence_current: None,
            format_items: Vec::new(),
            format_current: None,
            source_file_view: false,
            timecode_origin: Time::ZERO,
            timecode_frames_only: false,
            safe_zone: SafeZoneChoice::stored(defaults.as_ref()),
            shows_platform_mock: SafeZoneChoice::stored_mock(defaults.as_ref()),
            context_menu: Vec::new(),
            wired: MonitorWiring::default(),
            events: Vec::new(),
            menu_queue: MenuQueue::default(),
            defaults: Box::new(MemoryDefaults::default()),
        };
        if program {
            m.safe_margins = flag(Self::SAFE_MARGINS_KEY);
            m.shows_rulers = flag(Self::RULERS_KEY);
            m.overlays_hidden = flag(Self::OVERLAYS_HIDDEN_KEY);
            m.aspect_frame = defaults
                .string(Self::ASPECT_FRAME_KEY)
                .and_then(|s| AspectFrame::ALL.into_iter().find(|f| aspect_frame_raw(*f) == s))
                .unwrap_or(AspectFrame::Off);
            if defaults.integer(Self::SAFE_MARGIN_ACTION_KEY).is_some() {
                m.safe_margin_sizes = SafeMarginSizes::new(
                    defaults.integer(Self::SAFE_MARGIN_ACTION_KEY).unwrap_or(0),
                    defaults.integer(Self::SAFE_MARGIN_TITLE_KEY).unwrap_or(0),
                );
            }
        }
        m.defaults = defaults;
        m
    }

    /// Takes the hook calls since the last take, in the order Swift made them.
    pub fn take_events(&mut self) -> Vec<MonitorEvent> {
        std::mem::take(&mut self.events)
    }

    /// Pushes a hook call (also used by the panel for its own hooks).
    pub fn emit(&mut self, e: MonitorEvent) {
        self.events.push(e);
    }

    /// The settings store (the panel writes its own remembered values through it).
    pub fn defaults_mut(&mut self) -> &mut dyn UiDefaults {
        self.defaults.as_mut()
    }

    // MARK: Observable settings (the Swift `didSet`s write the store)

    /// The zoom shown.
    pub fn zoom(&self) -> MonitorZoom {
        self.zoom
    }
    /// The playback quality choice.
    pub fn quality(&self) -> MonitorQuality {
        self.quality
    }
    /// What the Program monitor's empty layer shows.
    pub fn program_empty_state(&self) -> ProgramEmptyKind {
        if !self.has_sequence {
            ProgramEmptyKind::NoSequence
        } else if self.timeline_is_empty {
            ProgramEmptyKind::EmptyTimeline
        } else {
            ProgramEmptyKind::None
        }
    }
    /// The one stored Safe Margins value (monitor menu and View > Safe Margins).
    pub fn safe_margins(&self) -> bool {
        self.safe_margins
    }
    /// Sets Safe Margins; the Program monitor remembers it.
    pub fn set_safe_margins(&mut self, on: bool) {
        if self.mode == MonitorMode::Program && on != self.safe_margins {
            self.defaults.set_integer(Self::SAFE_MARGINS_KEY, i64::from(on));
        }
        self.safe_margins = on;
    }
    /// Safe Margins as remembered between launches.
    pub fn stored_safe_margins(d: &dyn UiDefaults) -> bool {
        d.integer(Self::SAFE_MARGINS_KEY).is_some_and(|v| v != 0)
    }
    /// The dropped-frame dot is amber (a drop in the last 2 s while playing).
    pub fn drop_amber(&self) -> bool {
        self.drop_amber
    }
    /// The dot's tooltip.
    pub fn drop_tooltip(&self) -> &str {
        &self.drop_tooltip
    }
    /// Pill text next to the dot.
    pub fn drop_badge_text(&self) -> Option<&str> {
        self.drop_badge_text.as_deref()
    }
    /// The last run passed the drop threshold.
    pub fn drop_realtime_not_achieved(&self) -> bool {
        self.drop_realtime_not_achieved
    }
    /// Playback quality Auto: the quality the governor currently resolved to.
    pub fn effective_quality(&self) -> MonitorQuality {
        self.effective_quality
    }
    /// The resolution badge is on (off by default, remembered app-wide).
    pub fn shows_resolution_badge(&self) -> bool {
        self.shows_resolution_badge
    }
    /// Turns the resolution badge on or off.
    pub fn set_shows_resolution_badge(&mut self, on: bool) {
        self.shows_resolution_badge = on;
        self.defaults.set_integer(Self::RESOLUTION_BADGE_KEY, i64::from(on));
    }
    /// "1920 × 1080" while the badge is on and the size is known.
    pub fn resolution_badge_text(&self) -> Option<String> {
        let (w, h) = self.picture_size?;
        self.shows_resolution_badge.then(|| format!("{w} × {h}"))
    }
    /// Mask Tint is on (default on, `sq.showMaskTint`).
    pub fn shows_mask_tint(&self) -> bool {
        self.shows_mask_tint
    }
    /// Turns Mask Tint on or off (`sq.showMaskTint`).
    pub fn set_shows_mask_tint(&mut self, on: bool) {
        self.shows_mask_tint = on;
        self.defaults.set_integer(Self::MASK_TINT_KEY, i64::from(on));
    }
    /// Program monitor transparency checkerboard behind the picture.
    pub fn shows_transparency_grid(&self) -> bool {
        self.shows_transparency_grid
    }
    /// Turns the checkerboard on or off.
    pub fn set_shows_transparency_grid(&mut self, on: bool) {
        self.shows_transparency_grid = on;
        self.defaults.set_integer(Self::TRANSPARENCY_GRID_KEY, i64::from(on));
        self.emit(MonitorEvent::TransparencyGridChange(on));
    }
    /// Program monitor rulers (percent of the picture).
    pub fn shows_rulers(&self) -> bool {
        self.shows_rulers
    }
    /// Shows or hides the rulers; the Program monitor remembers it.
    pub fn set_shows_rulers(&mut self, on: bool) {
        if self.mode == MonitorMode::Program && on != self.shows_rulers {
            self.defaults.set_integer(Self::RULERS_KEY, i64::from(on));
        }
        self.shows_rulers = on;
    }
    /// Program monitor: hides every guide layer without changing their settings.
    pub fn overlays_hidden(&self) -> bool {
        self.overlays_hidden
    }
    /// Hides or shows every guide layer; the Program monitor remembers it.
    pub fn set_overlays_hidden(&mut self, hidden: bool) {
        if self.mode == MonitorMode::Program && hidden != self.overlays_hidden {
            self.defaults.set_integer(Self::OVERLAYS_HIDDEN_KEY, i64::from(hidden));
        }
        self.overlays_hidden = hidden;
    }
    /// Entry point for a key: hide or show every guide layer.
    pub fn toggle_overlays(&mut self) {
        self.set_overlays_hidden(!self.overlays_hidden);
    }
    /// Program monitor: aspect frame (9:16, 4:5, 1:1, 16:9).
    pub fn aspect_frame(&self) -> AspectFrame {
        self.aspect_frame
    }
    /// Sets the aspect frame; the Program monitor remembers it.
    pub fn set_aspect_frame(&mut self, f: AspectFrame) {
        if self.mode == MonitorMode::Program && f != self.aspect_frame {
            self.defaults.set_string(Self::ASPECT_FRAME_KEY, aspect_frame_raw(f));
        }
        self.aspect_frame = f;
    }
    /// The sizes of the safe-margin rectangles.
    pub fn safe_margin_sizes(&self) -> SafeMarginSizes {
        self.safe_margin_sizes
    }
    /// Sets the safe-margin sizes; the Program monitor remembers them.
    pub fn set_safe_margin_sizes(&mut self, s: SafeMarginSizes) {
        if self.mode == MonitorMode::Program && s != self.safe_margin_sizes {
            self.defaults.set_integer(Self::SAFE_MARGIN_ACTION_KEY, s.action());
            self.defaults.set_integer(Self::SAFE_MARGIN_TITLE_KEY, s.title());
        }
        self.safe_margin_sizes = s;
    }
    /// Preview speed of Play (0.5x to 10x). Preview only; the host plays the engine at `preview_rate().rate`.
    pub fn preview_rate(&self) -> PreviewRate {
        self.preview_rate
    }
    /// Picks the preview speed.
    pub fn set_preview_rate(&mut self, r: PreviewRate) {
        if r == self.preview_rate {
            return;
        }
        self.preview_rate = r;
        self.emit(MonitorEvent::PreviewRateChange(r));
    }
    /// Title of the "Media offline" card.
    pub fn offline_card_title(&self) -> String {
        SQL10n::string(if self.offline_file_name.is_none() && self.engine_failure.is_some() {
            "Preview unavailable"
        } else {
            "Media offline"
        })
    }
    /// Detail line of the "Media offline" card.
    pub fn offline_card_detail(&self) -> Option<String> {
        match (&self.offline_file_name, &self.engine_failure) {
            (Some(n), _) => Some(format!("{n} was moved or renamed")),
            (None, Some(e)) => Some(e.clone()),
            (None, None) => None,
        }
    }
    /// [`Self::offline_card_detail`] cut to `max_width` by `measure`: a long file name shrinks to a word boundary with an
    /// ellipsis and the "was moved or renamed" tail stays whole; any other detail is cut at its end.
    pub fn offline_card_detail_fitted(&self, max_width: f64, measure: impl Fn(&str) -> f64) -> String {
        let Some(full) = self.offline_card_detail() else { return String::new() };
        let fit = |text: &str, tail: &str| {
            sq_draw::glyph_atlas::fit_with_ellipsis(text, |t| measure(&format!("{t}{tail}")) <= max_width)
                .filter(|t| t != "\u{2026}")
        };
        match (&self.offline_file_name, full.strip_prefix(self.offline_file_name.as_deref().unwrap_or("\u{0}"))) {
            (Some(name), Some(tail)) => match fit(name, tail) {
                Some(n) => format!("{n}{tail}"),
                None => fit(&full, "").unwrap_or_default(),
            },
            _ => fit(&full, "").unwrap_or_default(),
        }
    }
    /// The marks can be dragged (the owner edits them and the view is not a source file).
    pub fn marks_editable(&self) -> bool {
        self.wired.mark_edit && !self.source_file_view
    }
    /// The platform whose UI zone is overlaid.
    pub fn safe_zone(&self) -> SafeZoneChoice {
        self.safe_zone
    }
    /// Picks the zone, remembers it and reports it.
    pub fn set_safe_zone(&mut self, c: SafeZoneChoice) {
        self.safe_zone = c;
        c.remember(self.defaults.as_mut());
        self.emit(MonitorEvent::SafeZoneChange(c));
    }
    /// Light mock of the platform's own UI over the dimmed zone; preview only, never exported.
    pub fn shows_platform_mock(&self) -> bool {
        self.shows_platform_mock
    }
    /// Turns the platform mock on or off.
    pub fn set_shows_platform_mock(&mut self, on: bool) {
        self.shows_platform_mock = on;
        SafeZoneChoice::remember_mock(on, self.defaults.as_mut());
        let zone = self.safe_zone;
        self.emit(MonitorEvent::SafeZoneChange(zone));
    }

    /// Polled by the host (a few times a second) with the engine's running drop total.
    pub fn update_drops(&mut self, dropped: i64, is_playing: bool, now: f64) {
        self.drops.update(dropped, is_playing, now);
        self.drop_amber = self.drops.is_amber(now);
        self.drop_tooltip = self.drops.tooltip();
        self.drop_badge_text = self.drops.badge_text();
        self.drop_realtime_not_achieved = self.drops.realtime_not_achieved();
        if self.quality == MonitorQuality::Auto {
            self.governor.update(dropped, is_playing);
            if self.governor.current() != self.effective_quality {
                self.effective_quality = self.governor.current();
                self.emit(MonitorEvent::QualityChange(self.effective_quality));
            }
        }
    }

    /// The timecode format of the monitor.
    pub fn timecode(&self) -> Timecode {
        let mut tc = Timecode::new(self.frame_duration, self.drop_frame);
        tc.origin = self.timecode_origin;
        tc.frames_only = self.timecode_frames_only;
        tc
    }
    /// The whole length as timecode.
    pub fn duration_text(&self) -> String {
        self.timecode().format(self.duration)
    }

    /// Length between In and Out (Out defaults to the end, In to the start); `None` when neither is set.
    pub fn in_out_duration_text(&self) -> Option<String> {
        if self.mark_in.is_none() && self.mark_out.is_none() {
            return None;
        }
        let len = self.mark_out.unwrap_or(self.duration) - self.mark_in.unwrap_or(Time::ZERO);
        Some(self.timecode().format(if len < Time::ZERO { Time::ZERO } else { len }))
    }

    /// The actions this monitor offers.
    pub fn available_actions(&self) -> Vec<MonitorAction> {
        use MonitorAction as A;
        MonitorAction::ALL
            .into_iter()
            .filter(|a| match a {
                A::Insert | A::Overwrite | A::Replace | A::FitToFill => self.mode == MonitorMode::Source,
                A::Lift | A::Extract | A::ToggleSafeMargins => self.mode == MonitorMode::Program,
                _ => true,
            })
            .collect()
    }

    /// Zoom popup in the monitor header ("Fit", "150 %"). Playback quality has its own popup next to it.
    pub fn badge_text(&self) -> String {
        SQL10n::string(&self.zoom.title())
    }
    /// Playback quality popup next to the zoom popup ("Full", "1/2", "1/4").
    pub fn quality_badge_text(&self) -> String {
        if self.quality != MonitorQuality::Auto {
            return SQL10n::string(self.quality.title());
        }
        if self.effective_quality == MonitorQuality::Full {
            SQL10n::string("Auto")
        } else {
            format!("{} · {}", SQL10n::string("Auto"), SQL10n::string(self.effective_quality.title()))
        }
    }

    pub(crate) fn command_row(&self, title: &str, checked: bool, c: MenuCommand) -> SQMenuItem {
        let q = self.menu_queue.clone();
        let mut i = SQMenuItem::new(title);
        i.is_checked = checked;
        i.action = Some(Rc::new(move || q.push(c.clone())));
        i
    }

    fn command_sink<T: 'static>(&self, make: impl Fn(T) -> MenuCommand + 'static) -> Rc<dyn Fn(T)> {
        let q = self.menu_queue.clone();
        Rc::new(move |v| q.push(make(v)))
    }

    /// Rows of the zoom popup (checked = current). Actions run on the model.
    pub fn zoom_menu(&self) -> Vec<SQMenuItem> {
        MonitorMenus::zoom_items(self.zoom, self.command_sink(MenuCommand::SetZoom))
    }

    /// Rows of the playback quality popup (checked = current). The choice is the app-wide remembered preference.
    pub fn quality_menu(&self) -> Vec<SQMenuItem> {
        let mut rows = vec![SQMenuItem::header("Playback quality")];
        rows.extend(MonitorMenus::quality_items(
            self.quality,
            Some(self.effective_quality),
            self.command_sink(MenuCommand::SetQuality),
        ));
        rows
    }

    /// Time `frames` frames away from `t` (never before zero), for dragging the timecode.
    pub fn time_offset_from(&self, t: Time, frames: i64) -> Time {
        Time::ZERO.max((t + self.frame_duration * frames).snapped(self.frame_duration))
    }

    /// Runs a monitor action (the owner decides what it does).
    pub fn perform(&mut self, action: MonitorAction) {
        if !self.available_actions().contains(&action) {
            return;
        }
        self.emit(MonitorEvent::Action(action));
    }

    /// Returns false (and does not seek) when the text is not a valid timecode. `+10` / `-5` move relative to the
    /// current time (frames; `+1:00` is a timecode amount), never before 0 or past the last frame.
    pub fn commit_timecode_text(&mut self, text: &str) -> bool {
        let tc = self.timecode();
        let last =
            if self.duration > Time::ZERO { Some(Time::ZERO.max(self.duration - self.frame_duration)) } else { None };
        if let Some(off) = tc.parse_relative(text) {
            let target = Time::ZERO.max(self.current_time + off);
            self.emit(MonitorEvent::Seek(last.map_or(target, |l| target.min(l))));
            return true;
        }
        let Some(t) = tc.parse_position(text) else { return false };
        self.emit(MonitorEvent::Seek(last.map_or(Time::ZERO.max(t), |l| Time::ZERO.max(t).min(l))));
        true
    }

    /// SQ hint for text the timecode field rejected (replaces the beep); empty for blank input.
    pub fn timecode_hint(text: &str) -> String {
        let t = text.trim();
        if t.is_empty() {
            return String::new();
        }
        format!("“{t}” is not a timecode. Try 123, +10, -10 or 01:00:00:00.")
    }

    // MARK: Mark grips (drag In / Out on the strip)

    /// Drag preview: moves the In or Out to the frame `frame` (`Playhead` is ignored). Out is stored one frame past it.
    pub fn preview_mark(&mut self, end: ScrubHit, frame: Time) {
        match end {
            ScrubHit::MarkIn => {
                self.mark_in = Some(frame);
                if self.mark_out.is_some_and(|o| o <= frame) {
                    self.mark_out = None;
                }
            }
            ScrubHit::MarkOut => {
                let out = frame + self.frame_duration;
                self.mark_out = Some(out);
                if self.mark_in.is_some_and(|i| i >= out) {
                    self.mark_in = None;
                }
            }
            ScrubHit::Playhead => {}
        }
    }

    /// Duration shown at the footer's right: In to Out when a range is set, else the whole length.
    pub fn footer_duration_text(&self) -> String {
        self.in_out_duration_text().unwrap_or_else(|| self.duration_text())
    }
    /// An In or Out mark is set.
    pub fn has_range(&self) -> bool {
        self.mark_in.is_some() || self.mark_out.is_some()
    }

    /// Right-click menu of the scrub bar and its In/Out range: the same commands as the main menu's Mark menu.
    pub fn mark_menu(&self) -> Vec<SQMenuItem> {
        let editable = !self.source_file_view;
        let map = CommandMap::current();
        let row = |title: &str, a: MonitorAction, on: bool| {
            let mut i = self.command_row(title, false, MenuCommand::Perform(a));
            i.shortcut = MonitorMenus::shortcut_of(a, &map);
            i.is_enabled = on;
            i
        };
        vec![
            row("Remove In", MonitorAction::ClearIn, editable && self.mark_in.is_some()),
            row("Remove Out", MonitorAction::ClearOut, editable && self.mark_out.is_some()),
            row("Remove In and Out", MonitorAction::ClearInOut, editable && self.has_range()),
            SQMenuItem::separator(),
            row("Go to In", MonitorAction::GoToIn, self.has_range()),
            row("Go to Out", MonitorAction::GoToOut, self.has_range()),
        ]
    }

    /// Drop: hands the final mark to the host.
    pub fn commit_mark(&mut self, end: ScrubHit) {
        match end {
            ScrubHit::MarkIn => {
                if let Some(i) = self.mark_in {
                    self.emit(MonitorEvent::MarkEdit(ScrubHit::MarkIn, i));
                }
            }
            ScrubHit::MarkOut => {
                if let Some(o) = self.mark_out {
                    self.emit(MonitorEvent::MarkEdit(ScrubHit::MarkOut, o));
                }
            }
            ScrubHit::Playhead => {}
        }
    }

    /// Picks a zoom and reports it.
    pub fn set_zoom(&mut self, z: MonitorZoom) {
        self.zoom = z;
        self.emit(MonitorEvent::ZoomChange(z));
    }
    /// Shows a zoom that a gesture produced (Hand tool, pinch) without reporting it back.
    pub fn display_zoom(&mut self, z: MonitorZoom) {
        self.zoom = z;
    }
    /// Picks the playback quality and reports the level in effect.
    pub fn set_quality(&mut self, q: MonitorQuality) {
        self.quality = q;
        if q == MonitorQuality::Auto {
            self.governor.set_base(self.governor.base());
            self.effective_quality = self.governor.current();
            self.emit(MonitorEvent::QualityChange(self.effective_quality));
        } else {
            self.effective_quality = q;
            self.emit(MonitorEvent::QualityChange(q));
        }
    }
    /// Auto's starting quality (the Mac's memory-budget pick).
    pub fn set_auto_base(&mut self, q: MonitorQuality) {
        self.governor.set_base(q);
        if self.quality == MonitorQuality::Auto && self.governor.current() != self.effective_quality {
            self.effective_quality = self.governor.current();
            self.emit(MonitorEvent::QualityChange(self.effective_quality));
        }
    }

    /// The Platform Safe Zone popup.
    pub fn safe_zone_menu(&self) -> Vec<SQMenuItem> {
        let mut rows = MonitorMenus::safe_zone_items(self.safe_zone, self.command_sink(MenuCommand::SetSafeZone));
        rows.extend(MonitorMenus::platform_mock_items(
            self.shows_platform_mock,
            self.safe_zone.has_ui_mock(),
            self.command_sink(MenuCommand::SetShowsPlatformMock),
        ));
        rows
    }

    /// Applies what the menu rows queued since the last call (the panel calls this in `sync` and after each event).
    pub fn apply_menu_commands(&mut self) {
        for c in self.menu_queue.take() {
            match c {
                MenuCommand::SetZoom(z) => self.set_zoom(z),
                MenuCommand::SetQuality(q) => self.set_quality(q),
                MenuCommand::Perform(a) => self.perform(a),
                MenuCommand::ToggleOverlays => self.toggle_overlays(),
                MenuCommand::SetSafeZone(z) => self.set_safe_zone(z),
                MenuCommand::SetShowsPlatformMock(on) => self.set_shows_platform_mock(on),
                MenuCommand::SetSafeAction(v) => self.set_safe_margin_sizes(self.safe_margin_sizes.setting_action(v)),
                MenuCommand::SetSafeTitle(v) => self.set_safe_margin_sizes(self.safe_margin_sizes.setting_title(v)),
                MenuCommand::SetShowsTransparencyGrid(on) => self.set_shows_transparency_grid(on),
                MenuCommand::SetShowsMaskTint(on) => self.set_shows_mask_tint(on),
                MenuCommand::ToggleRulers => self.set_shows_rulers(!self.shows_rulers),
                MenuCommand::ClearGuides => self.guides.clear(),
                MenuCommand::SetShowsResolutionBadge(on) => self.set_shows_resolution_badge(on),
                MenuCommand::SetPreviewRate(r) => self.set_preview_rate(r),
                MenuCommand::SetAspectFrame(f) => self.set_aspect_frame(f),
                MenuCommand::ShowScopes => self.emit(MonitorEvent::ShowScopes),
                MenuCommand::FullScreen => self.emit(MonitorEvent::FullScreen),
                MenuCommand::Event(e) => self.emit(e),
            }
        }
    }

    /// The sink the popups of this model's panel use for hook-bound rows (source, sequence and format popups).
    pub fn event_sink<T: 'static>(&self, make: impl Fn(T) -> MonitorEvent + 'static) -> Rc<dyn Fn(T)> {
        self.command_sink(move |v| MenuCommand::Event(make(v)))
    }

    /// The same for a row without a value (Close, Close All).
    pub fn event_action(&self, e: MonitorEvent) -> Rc<dyn Fn()> {
        let q = self.menu_queue.clone();
        Rc::new(move || q.push(MenuCommand::Event(e.clone())))
    }

    /// The monitor menu ("..." of the header): SQ rows built when it opens. `view_items`: the View Gamma / Display View
    /// rows of the Mac renderer, appended to the playback group (none on Windows).
    pub fn option_items(&self, view_items: Vec<SQMenuItem>) -> Vec<SQMenuItem> {
        let map = CommandMap::current();
        let title = |a: MonitorAction| {
            MonitorFooter::symbol(a)
                .map(|s| s.1.to_string())
                .or_else(|| a.menu_title().map(str::to_string))
                .unwrap_or_default()
        };
        let shortcut = |a: MonitorAction| MonitorMenus::shortcut_of(a, &map);
        let available = self.available_actions();
        let base = MonitorMenus::option_items(
            &OptionMenuState {
                mode: self.mode,
                available: &available,
                is_looping: self.is_looping,
                safe_margins: self.safe_margins,
                zoom: self.zoom,
                quality: self.quality,
                auto_level: Some(self.effective_quality),
            },
            &OptionMenuActions {
                title: &title,
                shortcut: &shortcut,
                perform: self.command_sink(MenuCommand::Perform),
                set_zoom: self.command_sink(MenuCommand::SetZoom),
                set_quality: self.command_sink(MenuCommand::SetQuality),
            },
        );
        let program = self.mode == MonitorMode::Program;
        // Overlays: what is drawn over the picture.
        let mut overlays: Vec<SQMenuItem> = Vec::new();
        if program {
            overlays.push(self.command_row("Show Overlays", !self.overlays_hidden, MenuCommand::ToggleOverlays));
            let mut zone = SQMenuItem::new("Platform Safe Zone");
            zone.submenu = Some(self.safe_zone_menu());
            overlays.push(zone);
            let mut action = SQMenuItem::new("Action Safe");
            action.submenu = Some(
                SafeMarginSizes::ACTION_PRESETS
                    .iter()
                    .map(|v| {
                        self.command_row(
                            &format!("{v}%"),
                            *v == self.safe_margin_sizes.action(),
                            MenuCommand::SetSafeAction(*v),
                        )
                    })
                    .collect(),
            );
            let mut title = SQMenuItem::new("Title Safe");
            title.submenu = Some(
                SafeMarginSizes::TITLE_PRESETS
                    .iter()
                    .map(|v| {
                        self.command_row(
                            &format!("{v}%"),
                            *v == self.safe_margin_sizes.title(),
                            MenuCommand::SetSafeTitle(*v),
                        )
                    })
                    .collect(),
            );
            let mut sizes = SQMenuItem::new("Safe Margin Sizes");
            sizes.submenu = Some(vec![action, title]);
            overlays.push(sizes);
            overlays.push(self.command_row(
                "Transparency Grid",
                self.shows_transparency_grid,
                MenuCommand::SetShowsTransparencyGrid(!self.shows_transparency_grid),
            ));
            overlays.push(self.command_row(
                "Mask Tint",
                self.shows_mask_tint,
                MenuCommand::SetShowsMaskTint(!self.shows_mask_tint),
            ));
            overlays.push(self.command_row("Rulers", self.shows_rulers, MenuCommand::ToggleRulers));
            if !self.guides.is_empty() {
                overlays.push(self.command_row("Clear Guides", false, MenuCommand::ClearGuides));
            }
        }
        overlays.push(self.command_row(
            "Resolution Badge",
            self.shows_resolution_badge,
            MenuCommand::SetShowsResolutionBadge(!self.shows_resolution_badge),
        ));
        // Playback: how the picture is played and looked at.
        let mut playback: Vec<SQMenuItem> = Vec::new();
        if self.wired.preview_rate {
            let mut speed = SQMenuItem::new("Preview Speed");
            speed.submenu = Some(
                PreviewRate::presets()
                    .into_iter()
                    .map(|r| self.command_row(&r.title(), r == self.preview_rate, MenuCommand::SetPreviewRate(r)))
                    .collect(),
            );
            playback.push(speed);
        }
        playback.extend(view_items);
        // Compare: other frames and formats of the same picture.
        let mut compare: Vec<SQMenuItem> = Vec::new();
        if program {
            let mut format = SQMenuItem::new("Frame Format");
            format.submenu = Some(self.format_menu());
            compare.push(format);
            let mut aspect = SQMenuItem::new("Aspect Frame");
            aspect.submenu = Some(
                AspectFrame::ALL
                    .into_iter()
                    .map(|f| self.command_row(f.title(), f == self.aspect_frame, MenuCommand::SetAspectFrame(f)))
                    .collect(),
            );
            compare.push(aspect);
        }
        let mut tail: Vec<SQMenuItem> = Vec::new();
        if program && self.wired.show_scopes {
            tail.push(self.command_row("Scopes", false, MenuCommand::ShowScopes));
        }
        // Both monitors can play full screen (Swift offered it on Program only).
        if self.wired.full_screen {
            tail.push(self.command_row("Full Screen", false, MenuCommand::FullScreen));
        }
        MonitorMenus::grouped(base, overlays, playback, compare, tail)
    }

    /// The Frame Format rows (Compare menu and the Program title popup).
    pub fn format_menu(&self) -> Vec<SQMenuItem> {
        MonitorMenus::format_items(
            &self.format_base_name,
            &self.format_items,
            self.format_current,
            self.event_sink(MonitorEvent::PickFormat),
            self.event_sink(MonitorEvent::AddFormat),
            self.event_sink(MonitorEvent::RemoveFormat),
        )
    }

    /// Program monitor transport state follows the session: playhead, length, play state and frame rate.
    pub fn sync_transport(&mut self, session: &EditorSession) {
        self.current_time = session.playhead();
        self.is_playing = session.is_playing();
        if let Some(t) = session.active_timeline() {
            self.duration = t.duration();
            self.frame_duration = t.frame_duration();
            self.drop_frame =
                self.frame_duration == Time::new(1001, 30000) || self.frame_duration == Time::new(1001, 60000);
        }
    }

    /// The strip's In, Out and markers follow the sequence (`MonitorHost.syncSequence`): a key, a menu row or an undo
    /// that changes them shows on the strip at once, and Remove In and Out clears it.
    pub fn sync_marks(&mut self, session: &EditorSession) {
        let Some(t) = session.active_timeline() else {
            self.mark_in = None;
            self.mark_out = None;
            self.marker_times.clear();
            return;
        };
        self.mark_in = t.in_out.map(|r| r.start);
        self.mark_out = t.in_out.map(|r| r.end());
        if !self.marker_times.iter().eq(t.markers.iter().map(|m| &m.time)) {
            self.marker_times = t.markers.iter().map(|m| m.time).collect();
        }
    }

    /// Program monitor format switcher follows the session (cheap; writes only what changed).
    pub fn sync_formats(&mut self, session: &EditorSession) {
        let t = session.active_timeline();
        let base =
            t.map(|t| SequenceConform::aspect_label(t.format.display_width(), t.format.height)).unwrap_or_default();
        let items: Vec<FormatItem> = t
            .map(|t| t.variants.iter().map(|v| FormatItem { id: v.id, name: v.name.clone() }).collect())
            .unwrap_or_default();
        let current = session.active_variant_id();
        // Title popup: the open sequences (tabs), the shown one checked. Picking one makes it the active sequence.
        let open: Vec<SequenceItem> = session
            .sequence_tabs()
            .tabs()
            .iter()
            .filter_map(|tab| {
                session.project().timeline(tab.root()).map(|t| SequenceItem { id: tab.root(), name: t.name.clone() })
            })
            .collect();
        let shown = session
            .sequence_tabs()
            .tabs()
            .iter()
            .find(|tab| Some(tab.shown()) == session.active_timeline_id())
            .map(|tab| tab.root())
            .or(session.active_timeline_id());
        if self.sequence_items != open {
            self.sequence_items = open;
        }
        if self.sequence_current != shown {
            self.sequence_current = shown;
        }
        if self.format_base_name != base {
            self.format_base_name = base;
        }
        let name = t.map(|t| t.name.clone()).unwrap_or_default();
        if self.sequence_name != name {
            self.sequence_name = name;
        }
        if self.format_items != items {
            self.format_items = items;
        }
        if self.format_current != current {
            self.format_current = current;
        }
    }

    /// Applies the switcher events `sync_formats` connected in Swift (Compare > Frame Format and the title popup) to
    /// the session, leaving every other event in the queue.
    pub fn apply_format_events(&mut self, session: &mut EditorSession) {
        let events = std::mem::take(&mut self.events);
        for e in events {
            match e {
                MonitorEvent::PickFormat(id) => session.set_active_variant(id),
                MonitorEvent::AddFormat(p) => {
                    session.add_variant_preset(&p);
                }
                MonitorEvent::RemoveFormat(id) => session.remove_variant(id),
                MonitorEvent::PickSequence(id) => session.select_sequence_tab(id),
                other => self.events.push(other),
            }
        }
    }
}

// Swift: TimelineHeaderStrip.swift, TimelineTips.swift
//! The header bar above the timeline and the Fast Cut strip under it, translated from the Mac `TimelineHeaderBar`,
//! `SequenceTabsView`, `TimelineModeChip` and `FastCutStrip` (geometry: `TimelineHeaderLayout`, shared with the Mac).
//! Hover tips: the Mac `Tooltip.text` strings (`TimelineTips`), offered to `UiCx.hover` on every move the bars handle.
//!
//! Not ported here: `TimelineHeaderState.make(session:panel:)` and `TimelinePanel+Header.swift` need the panel struct and
//! the session's tab, timecode and Fast Cut queries; the host fills `TimelineHeaderState` (see `PANEL-FIELDS-DT3-4.md`).

use crate::panel::TimelinePanel;
use sq_core_model::{TimecodeDisplay, TimelineEditMode, Track, TrackKind};
use sq_core_time::Id;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::{Canvas, Color, DrawTheme, GlyphAtlas, InputEvent, TextAlign, UiCx};
use sq_editor_session::TimelineTool;
use sq_editor_session::ToolState;
use sq_editor_session::{EditorSession, TimecodeFormat};
use sq_os::Platform;
use sq_timeline_ui::{FastCutVerb, TimelineHeaderLayout, TimelineModeMenu, ToolStripTools};
use sq_timeline_ui::{HeaderFrames, TimelineGeometry};
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::radius;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::keyboard_listing::KeyboardListing;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::rc::Rc;

/// A menu the header bar asks the host to open (built with `TimelineHeaderStrip::items`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TimelineHeaderMenu {
    /// The Fit popup: zoom, track height, Place Sequences as Clips.
    Fit,
    /// Normal | Fast Cut.
    EditMode,
    /// The "..." menu: tracks and view.
    More,
    /// The open sequences: a row switches to that tab (the Color page's dock strip, where the tab pills are gone).
    Sequence,
}

#[derive(Clone, Debug, PartialEq)]
pub enum TimelineHeaderAction {
    /// Run through the host's command path (the same as the key): Snapping, Linked Selection, Add Marker, Fast Cut verbs.
    Command(EditorCommand),
    SelectTab(Id),
    CloseTab(Id),
    MoveTab(Id, usize),
    /// Open `menu` with its top-left at `at` (window points).
    Menu(TimelineHeaderMenu, CGPoint),
}

/// One sequence tab.
#[derive(Clone, Debug, PartialEq)]
pub struct HeaderTab {
    pub root: Id,
    /// "Main" or "Main > Inner".
    pub title: String,
    pub active: bool,
}

/// What the header bar shows; the host builds it from the session and the panel once per frame.
#[derive(Clone, Debug, PartialEq)]
pub struct TimelineHeaderState {
    pub tabs: Vec<HeaderTab>,
    pub edit_mode: TimelineEditMode,
    pub timecode: String,
    pub snapping: bool,
    pub linked_selection: bool,
    /// Fast Cut verbs that can run on the selection, in `FastCutVerb::all()` order.
    pub verbs_enabled: Vec<bool>,
}

impl Default for TimelineHeaderState {
    fn default() -> Self {
        TimelineHeaderState {
            tabs: Vec::new(),
            edit_mode: TimelineEditMode::Normal,
            timecode: String::new(),
            snapping: true,
            linked_selection: true,
            verbs_enabled: Vec::new(),
        }
    }
}

impl TimelineHeaderState {
    /// The Mac `EditorPanels.syncSequenceTabs` / `syncEditMode` / `syncFastCutStrip` and the header's timecode.
    pub fn make(s: &EditorSession, panel: &TimelinePanel) -> TimelineHeaderState {
        let mut st = TimelineHeaderState::default();
        let tabs = s.sequence_tabs();
        st.tabs = tabs
            .tabs()
            .iter()
            .enumerate()
            .map(|(i, tab)| HeaderTab {
                root: tab.root(),
                title: tab
                    .path
                    .iter()
                    .map(|id| s.project().timeline(*id).map_or("?".to_string(), |t| t.name.clone()))
                    .collect::<Vec<_>>()
                    .join(" > "),
                active: Some(i) == tabs.active_index(),
            })
            .collect();
        let t = s.active_timeline();
        st.edit_mode = t.map_or(TimelineEditMode::Normal, |t| t.edit_mode());
        if let Some(t) = t {
            // Formats the playhead like the Mac header (drop-frame only where the rate has it, the sequence's start).
            let fd = t.frame_duration();
            let mut f = TimecodeFormat::new(fd, true);
            f.start_frame = t.timecode_start().frame_index(fd);
            f.frames_only = t.timecode_display() == TimecodeDisplay::Frames;
            st.timecode = f.string_for_time(s.playhead(), fd);
        }
        st.snapping = panel.tool_state().snapping;
        st.linked_selection = panel.tool_state().linked_selection;
        if st.edit_mode == TimelineEditMode::Magnetic {
            st.verbs_enabled = FastCutVerb::all().iter().map(|v| s.fast_cut_command_enabled(v.command)).collect();
        }
        st
    }
}

/// A control of the bars.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeaderControl {
    Tab(usize),
    TabClose(usize),
    EditMode,
    Snap,
    Link,
    Marker,
    Fit,
    More,
    Verb(usize),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Press {
    Control(HeaderControl),
    Tab(usize, usize),
}

/// The hover tips of the drawn timeline bars, the Mac strings.
pub struct TimelineTips;

impl TimelineTips {
    /// "Snapping (S)": the title with the command's key from the key map; the bare title when it has none.
    pub fn text(title: &str, command: &EditorCommand, map: &CommandMap) -> String {
        match map.shown_binding_here(command) {
            Some(b) => format!("{title} ({})", KeyBindingText::text(&b, Platform::current())),
            None => title.to_string(),
        }
    }

    pub fn header(c: HeaderControl, state: &TimelineHeaderState, map: &CommandMap) -> Option<String> {
        Some(match c {
            HeaderControl::Tab(i) => return state.tabs.get(i).map(|t| t.title.clone()),
            HeaderControl::TabClose(_) => "Close Sequence".to_string(),
            HeaderControl::EditMode => {
                if state.edit_mode == TimelineEditMode::Magnetic {
                    Self::text("Fast Cut", &EditorCommand::ToggleMagnetic, map)
                        + " · The main track closes gaps by itself; clips above and below stay attached. Click to change the mode."
                } else {
                    "Normal · Classic tracks, every edit stays where you put it. Click to change the mode.".to_string()
                }
            }
            HeaderControl::Snap => {
                Self::text("Snapping", &EditorCommand::ToggleSnapping, map)
                    + " · Clips snap to edits, markers and the playhead."
            }
            HeaderControl::Link => {
                Self::text("Linked selection", &EditorCommand::ToggleLinkedSelection, map)
                    + " · Video and its audio select together."
            }
            HeaderControl::Marker => Self::text("Add marker", &EditorCommand::AddMarker, map),
            HeaderControl::More => "More · Tracks and view".to_string(),
            HeaderControl::Fit => Self::text("Zoom", &EditorCommand::ZoomFit, map) + " · Fit the whole sequence.",
            HeaderControl::Verb(i) => {
                let all = FastCutVerb::all();
                let v = all.get(i)?;
                Self::text(v.title, &v.command, map) + " · " + v.help
            }
        })
    }

    /// The Mac `ToolStripView.sync` tips: "Name (Key) · what it does", the Create, Mask and Slip slots with their mode.
    pub fn tool(t: TimelineTool, s: &ToolState, map: &CommandMap) -> String {
        let head = match t {
            TimelineTool::Type => Self::text(
                &format!("Create: {}", s.create_mode.title()),
                &EditorCommand::Tool(s.create_mode.editor_tool()),
                map,
            ),
            TimelineTool::Mask => Self::text(
                &format!("Mask: {}", s.mask_mode.title()),
                &EditorCommand::Tool(sq_uikit::editor_command::EditorTool::Mask),
                map,
            ),
            TimelineTool::Slip => Self::text(
                if s.slip_keyframes_stay { "Slip (Keyframes Stay)" } else { "Slip" },
                &EditorCommand::Tool(sq_uikit::editor_command::EditorTool::Slip),
                map,
            ),
            _ => {
                let title = ToolStripTools::symbol(t).map_or("", |s| s.1);
                match ToolStripTools::editor_tool(t) {
                    Some(et) => Self::text(title, &EditorCommand::Tool(et), map),
                    None => title.to_string(),
                }
            }
        };
        match ToolStripTools::help(t) {
            Some(h) => format!("{head} · {h}"),
            None => head,
        }
    }
}

// MARK: Track headers (Swift: TimelinePanel+Header.swift, the layout part)

/// `TrackHeaderView.Slots` in header-local coordinates (`None` / zero = not shown).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HeaderSlots {
    pub lock: CGRect,
    pub sync: CGRect,
    pub eye: Option<CGRect>,
    pub mute: Option<CGRect>,
    pub solo: Option<CGRect>,
    pub name_right: f64,
}

/// Track headers, translated from `TrackHeaderView`: the target chip, the name, and the button slots (eye + lock on video,
/// S + M (+ lock) on audio, sync lock when off or hovered), with the Mac's slot math. The drawing and hit test of a header
/// need the panel (`TimelinePanel+Header` draw functions, `headerHit`) and follow with it.
pub struct TrackHeaderLayout;

impl TrackHeaderLayout {
    pub const CHIP_WIDTH: f64 = 26.0;
    pub const CHIP_HEIGHT: f64 = sq_uikit::redesign_tokens::size::BOX as f64;
    pub const BUTTON_SIZE: f64 = 24.0;
    pub const BUTTON_GAP: f64 = 4.0;
    pub const LEFT_PADDING: f64 = 12.0;
    pub const RIGHT_PADDING: f64 = 4.0;
    /// The track name starts this far right of the chip (x 46 in a header).
    pub const NAME_GAP: f64 = 8.0;
    /// Gap and right padding of the video buttons (lock, eye) and of the audio M / S boxes.
    const VIDEO_PAD: (f64, f64) = (3.0, 0.0);
    const AUDIO_PAD: (f64, f64) = (10.0, 4.0);
    /// An M / S box.
    const LETTER_BOX: (f64, f64) = (20.0, 18.0);

    pub fn button_size(row_height: f64) -> f64 {
        if row_height >= 30.0 { Self::BUTTON_SIZE } else { 14.0_f64.max(Self::BUTTON_SIZE.min(row_height - 4.0)) }
    }

    /// `TrackHeaderView.slots`: right to left eye, lock (video) or S, M (audio), then lock, then sync lock.
    pub fn slots(width: f64, height: f64, kind: TrackKind, shows_sync: bool, shows_lock: Option<bool>) -> HeaderSlots {
        let s = Self::button_size(height);
        let (pad, gap) = if kind == TrackKind::Video { Self::VIDEO_PAD } else { Self::AUDIO_PAD };
        let mut right = width - pad;
        let mut take = |w: f64, h: f64, gap: f64| {
            let r = CGRect::new(right - w, ((height - h) / 2.0).round(), w, h);
            right -= w + gap;
            r
        };
        let (mut eye, mut mute, mut solo) = (None, None, None);
        if kind == TrackKind::Video {
            eye = Some(take(s, s, gap));
        } else {
            let (w, h) = (Self::LETTER_BOX.0, Self::LETTER_BOX.1.min(s));
            solo = Some(take(w, h, gap));
            mute = Some(take(w, h, gap));
        }
        let gap = if kind == TrackKind::Video { Self::VIDEO_PAD.1 } else { Self::BUTTON_GAP };
        let lock = if shows_lock.unwrap_or(kind == TrackKind::Video) { take(s, s, gap) } else { ZERO };
        let sync = if shows_sync { take(s, s, gap) } else { ZERO };
        HeaderSlots { lock, sync, eye, mute, solo, name_right: right }
    }

    pub fn chip_rect(height: f64) -> CGRect {
        let h = Self::CHIP_HEIGHT.min((height - 4.0).max(12.0));
        CGRect::new(Self::LEFT_PADDING, ((height - h) / 2.0).round(), Self::CHIP_WIDTH, h)
    }

    /// `TrackHeaderView.displayName`: the typed name, else "Video N" / "Audio N" from the chip.
    pub fn display_name(name: &str, label: &str, kind: TrackKind) -> String {
        // `.whitespaces`: space-like characters, no line breaks.
        let blank = |c: char| {
            c == '\t'
                || (c.is_whitespace()
                    && !matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'))
        };
        let typed = name.trim_matches(blank);
        if !(typed.is_empty() || typed.to_lowercase() == label.to_lowercase()) {
            return typed.to_string();
        }
        let number: String = label.chars().skip_while(|c| !c.is_numeric()).collect();
        if number.is_empty() {
            return String::new();
        }
        format!("{} {number}", if kind == TrackKind::Video { "Video" } else { "Audio" })
    }

    /// Which buttons a header shows as `(sync lock, lock)`: the redesign head is chip, name, lock, eye on video and chip,
    /// name, M, S on audio. Sync lock is never a head button (it lives in the track's right-click menu), and the audio
    /// lock is menu-only too.
    pub fn shows(track: &Track, _hovered: bool) -> (bool, bool) {
        (false, track.kind == TrackKind::Video)
    }

    /// The head's slots and the name's right end.
    pub fn layout(track: &Track, width: f64, height: f64, hovered: bool) -> HeaderSlots {
        let (show_sync, show_lock) = Self::shows(track, hovered);
        let mut sl = Self::slots(width, height, track.kind, show_sync, Some(show_lock));
        let first = [show_sync.then_some(sl.sync), show_lock.then_some(sl.lock), sl.mute, sl.eye]
            .into_iter()
            .flatten()
            .map(|r| r.min_x())
            .reduce(|a, b| if b < a { b } else { a });
        sl.name_right = first.unwrap_or(width) - Self::BUTTON_GAP;
        sl
    }
}

const TAB_HEIGHT: f64 = 24.0;
const TAB_FONT: f64 = 12.0;
const TAB_MAX_WIDTH: f64 = 240.0;
const CLOSE_SIZE: f64 = 12.0;
const GLYPH: f64 = 16.0;
const BODY_FONT: f64 = 11.0;
const VERB_HEIGHT: f64 = 22.0;

const ZERO: CGRect = CGRect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };

fn accent_tint(theme: &DrawTheme) -> Color {
    theme.accent_tint()
}

/// What the header menus run: commands, the Place Sequences toggle and the edit mode pick.
pub struct HeaderMenuHandlers {
    pub run: Rc<dyn Fn(EditorCommand)>,
    pub toggle_place_clips: Rc<dyn Fn()>,
    pub pick_mode: Rc<dyn Fn(TimelineEditMode)>,
    pub select_tab: Rc<dyn Fn(Id)>,
}

/// The header bar and the Fast Cut strip.
pub struct TimelineHeaderStrip<'a> {
    pub theme: DrawTheme,
    /// Text widths for the layout (tab pills, the capsule, the verbs); `None` = an estimate (tests).
    pub atlas: Option<&'a GlyphAtlas>,
    /// False hides the bar (the Color page shows its own header).
    pub visible: bool,
    /// True drops the bar (tabs, Normal, Fit, "...") and the Fast Cut strip and keeps the row with the timecode and the
    /// toggles at the top of the area (the Color page: the dock strip carries the dropdowns).
    pub compact: bool,
    state: TimelineHeaderState,
    scale: f32,
    /// Bar and Fast Cut strip in window points (strip zero in Normal).
    bar: CGRect,
    strip: CGRect,
    /// The cell above the track heads (190 x 26): timecode, Snapping, Linked Selection and Marker (window points).
    cell: CGRect,
    frames: HeaderFrames,
    tab_rects: Vec<(CGRect, CGRect)>,
    verb_rects: Vec<CGRect>,
    badge_rect: CGRect,
    hovered: Option<HeaderControl>,
    press: Option<Press>,
}

impl<'a> TimelineHeaderStrip<'a> {
    /// The narrowest a shrunk sequence tab gets (padding, a letter and the ellipsis).
    const TAB_MIN_WIDTH: f64 = 44.0;

    pub fn new(theme: DrawTheme) -> Self {
        TimelineHeaderStrip {
            theme,
            atlas: None,
            visible: true,
            compact: false,
            state: TimelineHeaderState::default(),
            scale: 1.0,
            bar: ZERO,
            strip: ZERO,
            cell: ZERO,
            frames: HeaderFrames {
                tabs: ZERO,
                timecode: ZERO,
                snap: ZERO,
                link: ZERO,
                marker: ZERO,
                fit: ZERO,
                edit_mode: ZERO,
                more: ZERO,
            },
            tab_rects: Vec::new(),
            verb_rects: Vec::new(),
            badge_rect: ZERO,
            hovered: None,
            press: None,
        }
    }

    /// The same bar measuring text with `atlas`: a host keeps the bar between frames while the atlas is only borrowed
    /// for one frame, so it swaps the atlas in around `layout` and takes it out again with `None`.
    pub fn with_atlas<'b>(self, atlas: Option<&'b GlyphAtlas>) -> TimelineHeaderStrip<'b> {
        TimelineHeaderStrip {
            theme: self.theme,
            atlas,
            visible: self.visible,
            compact: self.compact,
            state: self.state,
            scale: self.scale,
            bar: self.bar,
            strip: self.strip,
            cell: self.cell,
            frames: self.frames,
            tab_rects: self.tab_rects,
            verb_rects: self.verb_rects,
            badge_rect: self.badge_rect,
            hovered: self.hovered,
            press: self.press,
        }
    }

    pub fn state(&self) -> &TimelineHeaderState {
        &self.state
    }

    pub fn bar(&self) -> CGRect {
        self.bar
    }

    pub fn strip(&self) -> CGRect {
        self.strip
    }

    pub fn frames(&self) -> &HeaderFrames {
        &self.frames
    }

    pub fn tab_rects(&self) -> &[(CGRect, CGRect)] {
        &self.tab_rects
    }

    pub fn verb_rects(&self) -> &[CGRect] {
        &self.verb_rects
    }

    pub fn hovered(&self) -> Option<HeaderControl> {
        self.hovered
    }

    pub fn is_dragging(&self) -> bool {
        self.press.is_some()
    }

    fn text_width(&self, s: &str, size: f64, face: usize) -> f64 {
        match self.atlas {
            None => s.chars().count() as f64 * size * 0.55,
            Some(a) => f64::from(a.width_of(s, size as f32 * self.scale, face) / self.scale),
        }
    }

    // MARK: Layout

    /// Lays the bar (and in Fast Cut the strip) out at the top of `rect` (device pixels); returns what is left below.
    pub fn layout(&mut self, rect: sq_draw::Rect, scale: f32, state: TimelineHeaderState) -> sq_draw::Rect {
        self.scale = scale;
        self.state = state;
        if !self.visible {
            self.bar = ZERO;
            self.strip = ZERO;
            return rect;
        }
        let k = f64::from(scale);
        let area =
            CGRect::new(f64::from(rect.x) / k, f64::from(rect.y) / k, f64::from(rect.w) / k, f64::from(rect.h) / k);
        if self.compact {
            self.bar = ZERO;
            self.strip = ZERO;
            self.tab_rects.clear();
            self.verb_rects.clear();
            self.badge_rect = ZERO;
            let none = HeaderFrames {
                tabs: ZERO,
                timecode: ZERO,
                snap: ZERO,
                link: ZERO,
                marker: ZERO,
                fit: ZERO,
                edit_mode: ZERO,
                more: ZERO,
            };
            self.frames = none;
            self.set_cell_origin(area.min_x(), area.min_y());
            // The cell sits on the lanes' own ruler row: the lanes keep the whole area.
            return rect;
        }
        let h = TimelineHeaderLayout::HEIGHT;
        self.bar = CGRect::new(area.min_x(), area.min_y(), area.width, h.min(area.height));
        let fast = self.state.edit_mode == TimelineEditMode::Magnetic;
        self.strip = if fast {
            CGRect::new(area.min_x(), self.bar.max_y(), area.width, h.min((area.height - self.bar.height).max(0.0)))
        } else {
            ZERO
        };
        let mode_width = TimelineModeMenu::chip_width(|s| self.text_width(s, BODY_FONT, 0));
        let fit_width = TimelineHeaderLayout::fit_width(self.text_width(&SQL10n::string("Fit"), BODY_FONT, 0));
        let f = TimelineHeaderLayout::frames(self.bar.width, self.bar.height, mode_width, fit_width, true);
        let shift = |r: CGRect| {
            if r == ZERO { r } else { CGRect::new(r.x + self.bar.min_x(), r.y + self.bar.min_y(), r.width, r.height) }
        };
        self.frames = HeaderFrames {
            tabs: shift(f.tabs),
            timecode: shift(f.timecode),
            snap: shift(f.snap),
            link: shift(f.link),
            marker: shift(f.marker),
            fit: shift(f.fit),
            edit_mode: shift(f.edit_mode),
            more: shift(f.more),
        };
        self.layout_tabs();
        self.layout_strip();
        let below = if self.strip == ZERO { self.bar.max_y() } else { self.strip.max_y() };
        self.set_cell_origin(area.min_x(), below);
        let used = (f64::from(if self.strip == ZERO { self.bar.max_y() } else { self.strip.max_y() } as f32 * scale))
            .round() as f32;
        sq_draw::Rect { x: rect.x, y: used, w: rect.w, h: (rect.y + rect.h - used).max(0.0) }
    }

    /// Puts the cell above the track heads at (`x`, `y`) points (the left edge and top of the timeline's lanes) and its
    /// controls in it: the timecode from x 12, then Snapping, Linked Selection and Marker (22 x 20, 4 apart) at the
    /// right, 8 from the edge (spec 9, Timeline).
    pub fn set_cell_origin(&mut self, x: f64, y: f64) {
        if !self.visible {
            self.cell = ZERO;
            return;
        }
        let cell = CGRect::new(x, y, TimelineGeometry::HEADER_WIDTH, TimelineGeometry::RULER_HEIGHT);
        let (w, h, gap) = (22.0, 20.0, 4.0);
        let top = cell.min_y() + ((cell.height - h) / 2.0).round();
        let marker_x = cell.max_x() - 8.0 - w;
        let link_x = marker_x - gap - w;
        let snap_x = link_x - gap - w;
        self.frames.marker = CGRect::new(marker_x, top, w, h);
        self.frames.link = CGRect::new(link_x, top, w, h);
        self.frames.snap = CGRect::new(snap_x, top, w, h);
        self.frames.timecode =
            CGRect::new(cell.min_x() + 12.0, cell.min_y(), (snap_x - 4.0 - cell.min_x() - 12.0).max(0.0), cell.height);
        self.cell = cell;
    }

    /// `SequenceTabsView.layoutTabs`: pills 24 high, text + 20 (+ the close mark with more than one tab), at most 240.
    fn layout_tabs(&mut self) {
        self.tab_rects.clear();
        let mut x = self.frames.tabs.min_x();
        let y = (self.frames.tabs.min_y() + (self.frames.tabs.height - TAB_HEIGHT) / 2.0).round();
        let extra = if self.state.tabs.len() > 1 { CLOSE_SIZE + 4.0 } else { 0.0 };
        let medium = self.atlas.map_or(0, |a| a.medium_face());
        let natural: Vec<f64> = self
            .state
            .tabs
            .iter()
            .map(|t| (self.text_width(&t.title, TAB_FONT, medium).ceil() + 20.0 + extra).min(TAB_MAX_WIDTH))
            .collect();
        let cap = Self::tab_width_cap(&natural, self.frames.tabs.width);
        for w in natural.into_iter().map(|w| w.min(cap)) {
            let r = CGRect::new(x, y, w, TAB_HEIGHT);
            let close = CGRect::new(
                r.max_x() - 8.0 - CLOSE_SIZE,
                r.min_y() + (r.height - CLOSE_SIZE) / 2.0,
                CLOSE_SIZE,
                CLOSE_SIZE,
            );
            self.tab_rects.push((r, close));
            x = r.max_x();
        }
    }

    /// The widest a tab may be so that all of them fit `available` (longest titles shrink first, none below
    /// [`Self::TAB_MIN_WIDTH`]; the drawing ends a shortened title with an ellipsis at a word boundary).
    pub(crate) fn tab_width_cap(natural: &[f64], available: f64) -> f64 {
        let widest = natural.iter().copied().fold(0.0, f64::max);
        if natural.iter().sum::<f64>() <= available {
            return widest;
        }
        let (mut lo, mut hi) = (Self::TAB_MIN_WIDTH, widest);
        for _ in 0..24 {
            let mid = (lo + hi) / 2.0;
            if natural.iter().map(|w| w.min(mid)).sum::<f64>() <= available {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        lo
    }

    /// `FastCutStrip.layout`: the badge 8 pt in, 12 pt to the first verb, 4 pt between verbs (icon + title buttons).
    fn layout_strip(&mut self) {
        self.verb_rects.clear();
        if self.strip == ZERO {
            self.badge_rect = ZERO;
            return;
        }
        let bw = self.text_width("Fast Cut", BODY_FONT, 0).ceil();
        self.badge_rect = CGRect::new(self.strip.min_x() + 8.0, self.strip.min_y(), bw, self.strip.height);
        let mut x = self.badge_rect.max_x() + 12.0;
        let y = (self.strip.min_y() + (self.strip.height - VERB_HEIGHT) / 2.0).round();
        for v in FastCutVerb::all() {
            let w = (10.0 + 14.0 + 4.0 + self.text_width(v.title, BODY_FONT, 0) + 10.0).ceil();
            self.verb_rects.push(CGRect::new(x, y, w, VERB_HEIGHT));
            x += w + 4.0;
        }
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        let p = CGPoint { x: f64::from(x / self.scale), y: f64::from(y / self.scale) };
        self.visible && (self.bar.contains(p) || self.strip.contains(p) || self.cell.contains(p))
    }

    fn pt(&self, x: f32, y: f32) -> CGPoint {
        let k = f64::from(self.scale);
        CGPoint { x: f64::from(x) / k, y: f64::from(y) / k }
    }

    fn close_hit(&self, i: usize, p: CGPoint) -> bool {
        self.tab_rects.get(i).is_some_and(|r| r.1.inset_by(-3.0, -3.0).contains(p))
    }

    pub fn control_at(&self, p: CGPoint) -> Option<HeaderControl> {
        for (i, r) in self.tab_rects.iter().enumerate() {
            if r.0.contains(p) && r.0.min_x() < self.frames.tabs.max_x() {
                if self.state.tabs.len() > 1
                    && (self.hovered == Some(HeaderControl::Tab(i)) || self.hovered == Some(HeaderControl::TabClose(i)))
                    && self.close_hit(i, p)
                {
                    return Some(HeaderControl::TabClose(i));
                }
                return Some(HeaderControl::Tab(i));
            }
        }
        if self.frames.edit_mode.contains(p) {
            return Some(HeaderControl::EditMode);
        }
        if self.frames.snap.contains(p) {
            return Some(HeaderControl::Snap);
        }
        if self.frames.link.contains(p) {
            return Some(HeaderControl::Link);
        }
        if self.frames.marker.contains(p) {
            return Some(HeaderControl::Marker);
        }
        if self.frames.fit.contains(p) {
            return Some(HeaderControl::Fit);
        }
        if self.frames.more.contains(p) {
            return Some(HeaderControl::More);
        }
        self.verb_rects.iter().position(|r| r.contains(p)).map(HeaderControl::Verb)
    }

    /// The tip of the control at window point `p`.
    pub fn tip_at(&self, p: CGPoint, map: &CommandMap) -> Option<String> {
        self.control_at(p).and_then(|c| TimelineTips::header(c, &self.state, map))
    }

    // MARK: Drawing

    pub fn draw(&self, cv: &mut Canvas) {
        if !self.visible || (self.bar.width <= 0.0 && !self.compact) {
            return;
        }
        let t = &self.theme;
        if !self.compact {
            cv.fill(self.bar, t.token(sq_uikit::redesign_tokens::color::LANE)); // kit: the header strip is the lane color
            cv.fill(CGRect::new(self.bar.min_x(), self.bar.max_y() - 1.0, self.bar.width, 1.0), t.separator());
            self.draw_tabs(cv);
            self.draw_mode(cv);
        }
        // Timecode above the track heads: 13 pt, 500, text color, left-aligned.
        cv.draw_text_in(&self.state.timecode, self.frames.timecode, 13.0, t.label(), TextAlign::Left, 0.0, cv.medium());
        self.draw_toggle(cv, HeaderControl::Snap, SQIcon::Snap, Some(self.state.snapping));
        self.draw_toggle(cv, HeaderControl::Link, SQIcon::Link, Some(self.state.linked_selection));
        self.draw_toggle(cv, HeaderControl::Marker, SQIcon::Bookmark, None);
        if self.compact {
            return;
        }
        // v9 flat popup: no fill until hovered, 11 pt label 10 pt in, 12 pt chevron 8 pt from the right.
        let fit = self.frames.fit;
        let fit_hot =
            self.hovered == Some(HeaderControl::Fit) || self.press == Some(Press::Control(HeaderControl::Fit));
        cv.stone_button(fit, ButtonKind::Quiet, Touch { hovering: fit_hot, ..Touch::default() }, t);
        // The label never runs under the chevron (8 + 12 + 8 pt on the right).
        // (`draw_text_in` takes the 10 pt inset off both sides: the rect reaches 8 + 12 + 8 pt short of the right edge.)
        let label = CGRect::new(fit.min_x(), fit.min_y(), (fit.width - 28.0 + 10.0).max(0.0), fit.height);
        cv.draw_text_in(&SQL10n::string("Fit"), label, BODY_FONT, t.label(), TextAlign::Left, 10.0, 0);
        cv.draw_icon(
            SQIcon::ChevronDown,
            CGPoint { x: fit.max_x() - 8.0 - 12.0, y: fit.mid_y() - 6.0 },
            12.0,
            t.label3(),
            None,
        );
        self.draw_more(cv);
        self.draw_strip(cv);
    }

    /// The "..." button: three dots, flat until hovered (the panel menu of the spec).
    fn draw_more(&self, cv: &mut Canvas) {
        let t = &self.theme;
        let r = self.frames.more;
        let hot = self.hovered == Some(HeaderControl::More) || self.press == Some(Press::Control(HeaderControl::More));
        cv.stone_button(r, ButtonKind::Quiet, Touch { hovering: hot, ..Touch::default() }, t);
        for dx in [-4.0, 0.0, 4.0] {
            cv.fill_ellipse(
                CGRect::new(r.mid_x() + dx - 1.0, r.mid_y() - 1.0, 2.0, 2.0),
                if hot { t.label() } else { t.label3() },
            );
        }
    }

    /// Snap / Linked Selection on = raised box with label glyph, off = dim glyph; hover fill only.
    fn draw_toggle(&self, cv: &mut Canvas, c: HeaderControl, icon: SQIcon, on: Option<bool>) {
        let t = &self.theme;
        let r = match c {
            HeaderControl::Snap => self.frames.snap,
            HeaderControl::Link => self.frames.link,
            _ => self.frames.marker,
        };
        let hot = self.hovered == Some(c) || self.press == Some(Press::Control(c));
        // On = raised stone with a bright glyph; off = flat with the hover fill only.
        let kind = if on == Some(true) { ButtonKind::Raised } else { ButtonKind::Quiet };
        let pressed = self.press == Some(Press::Control(c));
        cv.stone_button(r, kind, Touch { hovering: hot, pressed, ..Touch::default() }, t);
        cv.draw_icon(
            icon,
            CGPoint { x: r.mid_x() - GLYPH / 2.0, y: r.mid_y() - GLYPH / 2.0 },
            GLYPH,
            if on == Some(true) { t.label() } else { t.label3() },
            None,
        );
    }

    /// `SequenceTabsView.draw`: the active tab in label color over a 2 pt accent line (10 pt in), others label3 (label2
    /// on hover); the close mark on the hovered tab when there is more than one.
    fn draw_tabs(&self, cv: &mut Canvas) {
        let t = &self.theme;
        cv.save_gstate();
        cv.clip_to(self.frames.tabs);
        let many = self.state.tabs.len() > 1;
        for (i, tab) in self.state.tabs.iter().enumerate() {
            let Some((r, close)) = self.tab_rects.get(i) else { continue };
            let hover = self.hovered == Some(HeaderControl::Tab(i)) || self.hovered == Some(HeaderControl::TabClose(i));
            // Gray underline, 8 pt in from each side; blue is only the panel focus frame.
            cv.stone_tab_underline(CGRect::new(r.min_x(), self.bar.min_y(), r.width, self.bar.height), tab.active, t);
            let reserve = if many { CLOSE_SIZE + 4.0 } else { 0.0 };
            let color = if tab.active {
                t.label()
            } else if hover {
                t.label2()
            } else {
                t.label3()
            };
            let room = (r.width - 16.0 - reserve).max(0.0);
            let title = cv.ellipsized(&tab.title, TAB_FONT, cv.medium(), room);
            cv.draw_text_in(
                &title,
                CGRect::new(r.min_x() + 8.0, r.min_y(), room, r.height),
                TAB_FONT,
                color,
                TextAlign::Left,
                0.0,
                cv.medium(),
            );
            if many && hover {
                let c = if self.hovered == Some(HeaderControl::TabClose(i)) { t.label() } else { t.label3() };
                cv.draw_icon(SQIcon::Close, CGPoint { x: close.x, y: close.y }, CLOSE_SIZE, c, None);
            }
        }
        cv.restore_gstate();
    }

    /// `TimelineModeChip.draw`: a capsule, accent tint for Fast Cut, quiet fill (hover lighter) for Normal.
    fn draw_mode(&self, cv: &mut Canvas) {
        let t = &self.theme;
        let r = self.frames.edit_mode;
        if r == ZERO {
            return;
        }
        let fast = self.state.edit_mode == TimelineEditMode::Magnetic;
        let tint = if fast { t.accent() } else { t.label2() };
        if fast {
            cv.fill_rounded(r, f64::from(radius::SMALL), accent_tint(t));
        } else {
            let touch = Touch { hovering: self.hovered == Some(HeaderControl::EditMode), ..Touch::default() };
            cv.stone_button(r, ButtonKind::Quiet, touch, t);
        }
        let s = TimelineModeMenu::ICON_SIZE;
        cv.draw_icon(
            TimelineModeMenu::icon(self.state.edit_mode),
            CGPoint { x: r.min_x() + TimelineModeMenu::LEFT_PADDING, y: r.mid_y() - s / 2.0 },
            s,
            tint,
            None,
        );
        let lx = r.min_x() + TimelineModeMenu::LEFT_PADDING + s + TimelineModeMenu::ICON_TO_LABEL;
        cv.draw_text_in(
            TimelineModeMenu::chip_label(self.state.edit_mode),
            CGRect::new(lx, r.min_y(), r.max_x() - lx, r.height),
            BODY_FONT,
            tint,
            TextAlign::Left,
            0.0,
            0,
        );
    }

    /// `FastCutStrip`: the "Fast Cut" badge in accent, then one quiet button per verb (dim when it cannot run).
    fn draw_strip(&self, cv: &mut Canvas) {
        let t = &self.theme;
        if self.strip == ZERO {
            return;
        }
        cv.fill(self.strip, t.panel());
        cv.fill(CGRect::new(self.strip.min_x(), self.strip.max_y() - 1.0, self.strip.width, 1.0), t.separator());
        cv.draw_text_in("Fast Cut", self.badge_rect, BODY_FONT, t.accent(), TextAlign::Left, 0.0, 0);
        for (i, v) in FastCutVerb::all().iter().enumerate() {
            let Some(r) = self.verb_rects.get(i).copied() else { continue };
            let on = self.state.verbs_enabled.get(i).copied().unwrap_or(false);
            let pressed = self.press == Some(Press::Control(HeaderControl::Verb(i)));
            let fill = if on && pressed {
                t.fill_pressed()
            } else if on && self.hovered == Some(HeaderControl::Verb(i)) {
                t.fill_hover()
            } else {
                t.fill()
            };
            cv.fill_rounded(r, f64::from(radius::CONTROL), fill);
            let tint = if on { t.label() } else { t.label3() };
            cv.draw_icon(v.icon, CGPoint { x: r.min_x() + 10.0, y: r.mid_y() - 7.0 }, 14.0, tint, None);
            cv.draw_text_in(
                v.title,
                CGRect::new(r.min_x() + 28.0, r.min_y(), r.width - 28.0, r.height),
                BODY_FONT,
                tint,
                TextAlign::Left,
                0.0,
                0,
            );
        }
    }

    // MARK: Input

    /// Handles one host event (device pixels); `None` = not the bar's (the host passes it on).
    pub fn handle(&mut self, e: &InputEvent, cx: &mut UiCx, map: &CommandMap) -> Option<Vec<TimelineHeaderAction>> {
        match *e {
            InputEvent::MouseDown { x, y, .. } => {
                if !self.contains(x, y) {
                    return None;
                }
                Some(self.mouse_down(self.pt(x, y)))
            }
            InputEvent::MouseDragged { x, y, .. } => {
                self.press?;
                Some(self.mouse_dragged(self.pt(x, y)))
            }
            InputEvent::MouseUp { x, y } => {
                self.press?;
                Some(self.mouse_up(self.pt(x, y)))
            }
            InputEvent::MouseMoved { x, y } => {
                let p = self.pt(x, y);
                self.hovered = if self.contains(x, y) { self.control_at(p) } else { None };
                // The close mark shows on hover: a second look finds it under the pointer.
                if let Some(HeaderControl::Tab(i)) = self.hovered
                    && self.state.tabs.len() > 1
                    && self.close_hit(i, p)
                {
                    self.hovered = Some(HeaderControl::TabClose(i));
                }
                if !self.contains(x, y) {
                    return None;
                }
                let tip = self.hovered.and_then(|c| TimelineTips::header(c, &self.state, map));
                cx.hover.offer_tip(tip.as_deref());
                Some(Vec::new())
            }
            InputEvent::Scroll { x, y, .. } => self.contains(x, y).then(Vec::new),
            _ => None,
        }
    }

    fn mouse_down(&mut self, p: CGPoint) -> Vec<TimelineHeaderAction> {
        let Some(c) = self.control_at(p) else { return Vec::new() };
        match c {
            HeaderControl::Tab(i) => {
                // A tab selects at the press (the Mac `mouseDown`), then a drag reorders it.
                self.press = Some(Press::Tab(i, i));
                self.state.tabs.get(i).map(|t| TimelineHeaderAction::SelectTab(t.root)).into_iter().collect()
            }
            // The capsule opens its menu at the press, under it.
            HeaderControl::EditMode => vec![TimelineHeaderAction::Menu(
                TimelineHeaderMenu::EditMode,
                CGPoint { x: self.frames.edit_mode.min_x(), y: self.frames.edit_mode.max_y() },
            )],
            HeaderControl::Fit => vec![TimelineHeaderAction::Menu(
                TimelineHeaderMenu::Fit,
                CGPoint { x: self.frames.fit.min_x(), y: self.frames.fit.max_y() },
            )],
            HeaderControl::More => vec![TimelineHeaderAction::Menu(
                TimelineHeaderMenu::More,
                CGPoint { x: self.frames.more.max_x(), y: self.frames.more.max_y() },
            )],
            _ => {
                self.press = Some(Press::Control(c));
                Vec::new()
            }
        }
    }

    fn mouse_dragged(&mut self, p: CGPoint) -> Vec<TimelineHeaderAction> {
        let Some(Press::Tab(i, index)) = self.press else { return Vec::new() };
        // Drag to reorder: the tab follows the pointer over its neighbors' centers.
        let target =
            self.tab_rects.iter().position(|r| p.x < r.0.mid_x()).unwrap_or(self.tab_rects.len().saturating_sub(1));
        if target == index {
            return Vec::new();
        }
        self.press = Some(Press::Tab(i, target));
        self.state.tabs.get(i).map(|t| TimelineHeaderAction::MoveTab(t.root, target)).into_iter().collect()
    }

    fn mouse_up(&mut self, p: CGPoint) -> Vec<TimelineHeaderAction> {
        let press = self.press.take();
        let Some(Press::Control(c)) = press else { return Vec::new() };
        if self.control_at(p) != Some(c) {
            return Vec::new();
        }
        match c {
            HeaderControl::TabClose(i) if self.state.tabs.len() > 1 => {
                self.state.tabs.get(i).map(|t| TimelineHeaderAction::CloseTab(t.root)).into_iter().collect()
            }
            HeaderControl::Snap => vec![TimelineHeaderAction::Command(EditorCommand::ToggleSnapping)],
            HeaderControl::Link => vec![TimelineHeaderAction::Command(EditorCommand::ToggleLinkedSelection)],
            HeaderControl::Marker => vec![TimelineHeaderAction::Command(EditorCommand::AddMarker)],
            HeaderControl::Verb(i) => {
                if !self.state.verbs_enabled.get(i).copied().unwrap_or(false) {
                    return Vec::new();
                }
                FastCutVerb::all().get(i).map(|v| TimelineHeaderAction::Command(v.command)).into_iter().collect()
            }
            _ => Vec::new(),
        }
    }

    // MARK: Menus

    /// The rows of `menu`. The Fit popup: Fit first, then what the bar shows no buttons for (the Mac `fitItems`); rows
    /// run commands through `run`. The capsule: Normal | Fast Cut, the pick goes to `pick_mode`.
    pub fn items(
        &self,
        menu: TimelineHeaderMenu,
        tool_state: &ToolState,
        fits_tracks: bool,
        map: &CommandMap,
        h: HeaderMenuHandlers,
    ) -> Vec<SQMenuItem> {
        let HeaderMenuHandlers { run, toggle_place_clips, pick_mode, select_tab } = h;
        match menu {
            TimelineHeaderMenu::Sequence => self
                .state
                .tabs
                .iter()
                .map(|t| {
                    let mut i = SQMenuItem::new(&t.title);
                    i.is_checked = t.active;
                    let (root, select) = (t.root, Rc::clone(&select_tab));
                    i.action = Some(Rc::new(move || select(root)));
                    i
                })
                .collect(),
            TimelineHeaderMenu::EditMode => {
                let current = self.state.edit_mode;
                TimelineModeMenu::items(
                    current,
                    Rc::new(move |m| {
                        if m != current {
                            pick_mode(m);
                        }
                    }),
                )
            }
            TimelineHeaderMenu::More | TimelineHeaderMenu::Fit => {
                let key = |c: &EditorCommand| {
                    map.shown_binding_here(c).map(|b| KeyboardListing::text_for(&b)).unwrap_or_default()
                };
                let row = |title: &str, c: EditorCommand, checked: bool| {
                    let mut i = SQMenuItem::new(title);
                    i.shortcut = key(&c);
                    i.is_checked = checked;
                    let run = Rc::clone(&run);
                    i.action = Some(Rc::new(move || run(c)));
                    i
                };
                let mut place = SQMenuItem::new("Place Sequences as Clips");
                place.is_checked = tool_state.place_sequences_as_clips;
                place.help = Some(SQL10n::string(
                    "A sequence dropped or inserted lands as its own clips, not one combined clip",
                ));
                place.action = Some(toggle_place_clips);
                if menu == TimelineHeaderMenu::More {
                    let (snapping, linked) = (self.state.snapping, self.state.linked_selection);
                    return vec![
                        SQMenuItem::header("Tracks"),
                        row("Add Video Track", EditorCommand::AddVideoTrack, false),
                        row("Add Audio Track", EditorCommand::AddAudioTrack, false),
                        row("Remove Empty Tracks", EditorCommand::RemoveEmptyTracks, false),
                        SQMenuItem::separator(),
                        SQMenuItem::header("View"),
                        row("Minimize All Tracks", EditorCommand::MinimizeAllTracks, false),
                        row("Expand All Tracks", EditorCommand::ExpandAllTracks, false),
                        SQMenuItem::separator(),
                        row("Snapping", EditorCommand::ToggleSnapping, snapping),
                        row("Linked Selection", EditorCommand::ToggleLinkedSelection, linked),
                    ];
                }
                vec![
                    SQMenuItem::header("Zoom"),
                    row("Fit Sequence", EditorCommand::ZoomFit, false),
                    row("Zoom In", EditorCommand::ZoomIn, false),
                    row("Zoom Out", EditorCommand::ZoomOut, false),
                    SQMenuItem::separator(),
                    SQMenuItem::header("Track Height"),
                    row("Taller Tracks", EditorCommand::AllTracksTaller, false),
                    row("Shorter Tracks", EditorCommand::AllTracksShorter, false),
                    row("Fit All Tracks to Height", EditorCommand::ToggleFitTracks, fits_tracks),
                    SQMenuItem::separator(),
                    place,
                ]
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_draw::InputModifiers;

    fn state(tabs: usize, mode: TimelineEditMode) -> TimelineHeaderState {
        TimelineHeaderState {
            tabs: (0..tabs)
                .map(|i| HeaderTab { root: Id::from_u128(i as u128 + 1), title: format!("Seq {i}"), active: i == 0 })
                .collect(),
            edit_mode: mode,
            timecode: "00:00:01:00".to_string(),
            verbs_enabled: vec![true; FastCutVerb::all().len()],
            ..TimelineHeaderState::default()
        }
    }

    fn strip(tabs: usize, mode: TimelineEditMode) -> TimelineHeaderStrip<'static> {
        let mut s = TimelineHeaderStrip::new(DrawTheme::default());
        s.layout(sq_draw::Rect { x: 0.0, y: 0.0, w: 1200.0, h: 400.0 }, 1.0, state(tabs, mode));
        s
    }

    fn center(r: CGRect) -> (f32, f32) {
        (r.mid_x() as f32, r.mid_y() as f32)
    }

    fn click(s: &mut TimelineHeaderStrip, at: (f32, f32)) -> Vec<TimelineHeaderAction> {
        let mut cx = UiCx::new();
        let map = CommandMap::current();
        s.handle(&InputEvent::MouseDown { x: at.0, y: at.1, modifiers: InputModifiers::NONE }, &mut cx, &map);
        s.handle(&InputEvent::MouseUp { x: at.0, y: at.1 }, &mut cx, &map).unwrap_or_default()
    }

    #[test]
    fn snap_link_and_marker_sit_in_the_cell_above_the_track_heads() {
        let s = strip(1, TimelineEditMode::Normal);
        let f = s.frames();
        let cell = CGRect::new(
            0.0,
            TimelineHeaderLayout::HEIGHT,
            TimelineGeometry::HEADER_WIDTH,
            TimelineGeometry::RULER_HEIGHT,
        );
        for r in [f.snap, f.link, f.marker] {
            assert_eq!((r.width, r.height), (22.0, 20.0));
            assert!(r.min_x() >= cell.min_x() && r.max_x() <= cell.max_x());
            assert!(r.min_y() >= cell.min_y() && r.max_y() <= cell.max_y());
        }
        assert_eq!(f.link.min_x() - f.snap.max_x(), 4.0);
        assert_eq!(f.marker.min_x() - f.link.max_x(), 4.0);
        assert_eq!(f.timecode.min_x(), 12.0);
        assert!(s.contains(f.marker.mid_x() as f32, f.marker.mid_y() as f32));
    }

    #[test]
    fn layout_takes_one_bar_in_normal_and_two_rows_in_fast_cut() {
        let mut s = TimelineHeaderStrip::new(DrawTheme::default());
        let rest =
            s.layout(sq_draw::Rect { x: 0.0, y: 10.0, w: 1200.0, h: 400.0 }, 2.0, state(1, TimelineEditMode::Normal));
        assert_eq!(rest.y, 10.0 + (2.0 * TimelineHeaderLayout::HEIGHT) as f32);
        let mut f = TimelineHeaderStrip::new(DrawTheme::default());
        let rest2 =
            f.layout(sq_draw::Rect { x: 0.0, y: 0.0, w: 1200.0, h: 400.0 }, 1.0, state(1, TimelineEditMode::Magnetic));
        assert_eq!(rest2.y, 60.0);
        assert_eq!(f.verb_rects().len(), FastCutVerb::all().len());
        assert!(f.strip().height > 0.0);
    }

    #[test]
    fn hidden_bar_leaves_the_rect_alone() {
        let mut s = TimelineHeaderStrip::new(DrawTheme::default());
        s.visible = false;
        let r = sq_draw::Rect { x: 1.0, y: 2.0, w: 3.0, h: 4.0 };
        assert_eq!(s.layout(r, 1.0, state(1, TimelineEditMode::Normal)), r);
        assert!(!s.contains(1.0, 2.0));
    }

    #[test]
    fn controls_answer_clicks() {
        let mut s = strip(2, TimelineEditMode::Normal);
        let snap = center(s.frames().snap);
        assert_eq!(click(&mut s, snap), vec![TimelineHeaderAction::Command(EditorCommand::ToggleSnapping)]);
        let link = center(s.frames().link);
        assert_eq!(click(&mut s, link), vec![TimelineHeaderAction::Command(EditorCommand::ToggleLinkedSelection)]);
        let marker = center(s.frames().marker);
        assert_eq!(click(&mut s, marker), vec![TimelineHeaderAction::Command(EditorCommand::AddMarker)]);
        let fit = s.frames().fit;
        let at = center(fit);
        let mut cx = UiCx::new();
        let down = s.handle(
            &InputEvent::MouseDown { x: at.0, y: at.1, modifiers: InputModifiers::NONE },
            &mut cx,
            &CommandMap::current(),
        );
        assert_eq!(
            down,
            Some(vec![TimelineHeaderAction::Menu(TimelineHeaderMenu::Fit, CGPoint { x: fit.min_x(), y: fit.max_y() })])
        );
    }

    #[test]
    fn a_tab_selects_on_the_press_and_the_close_mark_closes_after_hover() {
        let mut s = strip(2, TimelineEditMode::Normal);
        let tab0 = s.tab_rects()[0].0;
        let mut cx = UiCx::new();
        let map = CommandMap::current();
        let at = center(tab0);
        let down =
            s.handle(&InputEvent::MouseDown { x: at.0, y: at.1, modifiers: InputModifiers::NONE }, &mut cx, &map);
        assert_eq!(down, Some(vec![TimelineHeaderAction::SelectTab(Id::from_u128(1))]));
        s.handle(&InputEvent::MouseUp { x: at.0, y: at.1 }, &mut cx, &map);
        // Hover the close mark first, then press it.
        let close = center(s.tab_rects()[0].1);
        s.handle(&InputEvent::MouseMoved { x: at.0, y: at.1 }, &mut cx, &map);
        s.handle(&InputEvent::MouseMoved { x: close.0, y: close.1 }, &mut cx, &map);
        assert_eq!(s.hovered(), Some(HeaderControl::TabClose(0)));
        assert_eq!(click(&mut s, close), vec![TimelineHeaderAction::CloseTab(Id::from_u128(1))]);
    }

    /// Windows check at 640x400: the tab "Sequence 01" was cut mid-word by the clip. Tabs shrink into their frame.
    #[test]
    fn long_tabs_shrink_to_the_frame_at_every_width() {
        for w in (400..=1200).step_by(20) {
            let mut st = state(3, TimelineEditMode::Normal);
            st.tabs[0].title = "Sequence of the Interview 01".to_string();
            st.tabs[1].title = "Sequence".to_string();
            let mut s = TimelineHeaderStrip::new(DrawTheme::default());
            s.layout(sq_draw::Rect { x: 0.0, y: 0.0, w: w as f32, h: 400.0 }, 1.0, st);
            let frame = s.frames().tabs;
            for (r, _) in s.tab_rects() {
                assert!(r.max_x() <= frame.max_x() + 0.5, "tab {r:?} leaves {frame:?} at {w}");
            }
        }
    }

    #[test]
    fn the_tab_cap_shrinks_the_longest_first() {
        type S<'a> = TimelineHeaderStrip<'a>;
        assert_eq!(S::tab_width_cap(&[100.0, 60.0], 200.0), 100.0);
        let cap = S::tab_width_cap(&[200.0, 60.0], 160.0);
        assert!((cap - 100.0).abs() < 0.1, "{cap}");
        assert_eq!(S::tab_width_cap(&[200.0, 200.0], 10.0), S::TAB_MIN_WIDTH);
    }

    #[test]
    fn a_single_tab_has_no_close_mark() {
        let mut s = strip(1, TimelineEditMode::Normal);
        let r = s.tab_rects()[0];
        let close = center(r.1);
        let mut cx = UiCx::new();
        s.handle(&InputEvent::MouseMoved { x: close.0, y: close.1 }, &mut cx, &CommandMap::current());
        assert_eq!(s.hovered(), Some(HeaderControl::Tab(0)));
    }

    #[test]
    fn dragging_a_tab_reorders_once_per_slot() {
        let mut s = strip(3, TimelineEditMode::Normal);
        let mut cx = UiCx::new();
        let map = CommandMap::current();
        let a = center(s.tab_rects()[0].0);
        s.handle(&InputEvent::MouseDown { x: a.0, y: a.1, modifiers: InputModifiers::NONE }, &mut cx, &map);
        let far = s.tab_rects()[2].0.max_x() as f32 + 50.0;
        let moved = s.handle(&InputEvent::dragged(far, a.1), &mut cx, &map);
        assert_eq!(moved, Some(vec![TimelineHeaderAction::MoveTab(Id::from_u128(1), 2)]));
        assert_eq!(s.handle(&InputEvent::dragged(far, a.1), &mut cx, &map), Some(Vec::new()));
    }

    #[test]
    fn fast_cut_verbs_run_only_when_enabled() {
        let mut s = strip(1, TimelineEditMode::Magnetic);
        let first = center(s.verb_rects()[0]);
        let want = FastCutVerb::all()[0].command;
        assert_eq!(click(&mut s, first), vec![TimelineHeaderAction::Command(want)]);
        let mut st = state(1, TimelineEditMode::Magnetic);
        st.verbs_enabled = vec![false; FastCutVerb::all().len()];
        s.layout(sq_draw::Rect { x: 0.0, y: 0.0, w: 1200.0, h: 400.0 }, 1.0, st);
        assert!(click(&mut s, first).is_empty());
    }

    #[test]
    fn tips_carry_the_key_and_the_explanation() {
        let map = CommandMap::current();
        let st = state(1, TimelineEditMode::Normal);
        let snap = TimelineTips::header(HeaderControl::Snap, &st, &map).unwrap_or_default();
        assert!(snap.starts_with("Snapping"));
        assert!(snap.ends_with(" · Clips snap to edits, markers and the playhead."));
        assert_eq!(TimelineTips::header(HeaderControl::Tab(0), &st, &map), Some("Seq 0".to_string()));
        assert_eq!(TimelineTips::header(HeaderControl::Tab(5), &st, &map), None);
        assert_eq!(TimelineTips::header(HeaderControl::TabClose(0), &st, &map), Some("Close Sequence".to_string()));
        let normal = TimelineTips::header(HeaderControl::EditMode, &st, &map).unwrap_or_default();
        assert!(normal.starts_with("Normal · Classic tracks"));
        let fast = TimelineTips::header(HeaderControl::EditMode, &state(1, TimelineEditMode::Magnetic), &map)
            .unwrap_or_default();
        assert!(fast.starts_with("Fast Cut") && fast.contains("Click to change the mode."));
        assert_eq!(
            TimelineTips::text("Nope", &EditorCommand::AddMarkersOnDownbeats, &CommandMap::new(Vec::new())),
            "Nope"
        );
    }

    #[test]
    fn tool_tips_name_the_mode_and_the_help() {
        let map = CommandMap::current();
        let mut ts = ToolState::default();
        let create = TimelineTips::tool(TimelineTool::Type, &ts, &map);
        assert!(create.starts_with("Create: "));
        ts.slip_keyframes_stay = true;
        assert!(TimelineTips::tool(TimelineTool::Slip, &ts, &map).starts_with("Slip (Keyframes Stay)"));
        let sel = TimelineTips::tool(TimelineTool::Selection, &ts, &map);
        assert!(sel.starts_with("Select") && sel.ends_with("Select, move and trim clips."));
    }

    #[test]
    fn the_more_button_opens_the_tracks_and_view_menu() {
        let mut s = strip(1, TimelineEditMode::Normal);
        let more = s.frames().more;
        let (x, y) = center(more);
        let down = s.handle(
            &InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE },
            &mut UiCx::new(),
            &CommandMap::current(),
        );
        assert_eq!(
            down,
            Some(vec![TimelineHeaderAction::Menu(
                TimelineHeaderMenu::More,
                CGPoint { x: more.max_x(), y: more.max_y() }
            )])
        );
        let ran = Rc::new(std::cell::RefCell::new(Vec::<EditorCommand>::new()));
        let r2 = Rc::clone(&ran);
        let items = s.items(
            TimelineHeaderMenu::More,
            &ToolState::default(),
            false,
            &CommandMap::current(),
            HeaderMenuHandlers {
                run: Rc::new(move |c| r2.borrow_mut().push(c)),
                toggle_place_clips: Rc::new(|| {}),
                pick_mode: Rc::new(|_| {}),
                select_tab: Rc::new(|_| {}),
            },
        );
        let add = items.iter().find(|i| i.title == "Add Video Track").expect("a row");
        (add.action.as_ref().expect("an action"))();
        assert_eq!(*ran.borrow(), [EditorCommand::AddVideoTrack]);
    }

    /// Every header popup that shows a shortcut spells it like the menu bar does on this system: no Mac glyphs off the Mac.
    #[test]
    fn header_popups_spell_shortcuts_in_the_platform_wording() {
        let s = strip(1, TimelineEditMode::Normal);
        let mut seen = 0;
        for menu in [TimelineHeaderMenu::More, TimelineHeaderMenu::Fit, TimelineHeaderMenu::EditMode] {
            let rows = s.items(
                menu,
                &ToolState::default(),
                false,
                &CommandMap::current(),
                HeaderMenuHandlers {
                    run: Rc::new(|_| {}),
                    toggle_place_clips: Rc::new(|| {}),
                    pick_mode: Rc::new(|_| {}),
                    select_tab: Rc::new(|_| {}),
                },
            );
            for r in rows.iter().filter(|r| !r.shortcut.is_empty()) {
                seen += 1;
                // A bare key ("S") reads the same everywhere; only modifiers differ: glyphs on the Mac, words elsewhere.
                let glyphs = r.shortcut.chars().any(|c| "⌘⌥⇧⌃".contains(c));
                let words = ["Ctrl+", "Alt+", "Shift+"].iter().any(|w| r.shortcut.contains(w));
                let wrong = if sq_os::Platform::current() == sq_os::Platform::Mac { words } else { glyphs };
                assert!(!wrong, "{menu:?} > {}: {}", r.title, r.shortcut);
            }
        }
        assert!(seen > 3, "the popups show shortcuts");
    }

    #[test]
    fn fit_menu_lists_zoom_height_and_the_place_toggle() {
        let s = strip(1, TimelineEditMode::Normal);
        let ran = Rc::new(std::cell::RefCell::new(Vec::new()));
        let sink = Rc::clone(&ran);
        let rows = s.items(
            TimelineHeaderMenu::Fit,
            &ToolState::default(),
            true,
            &CommandMap::current(),
            HeaderMenuHandlers {
                run: Rc::new(move |c| sink.borrow_mut().push(c)),
                toggle_place_clips: Rc::new(|| {}),
                pick_mode: Rc::new(|_| {}),
                select_tab: Rc::new(|_| {}),
            },
        );
        assert_eq!(rows.len(), 11);
        assert!(rows[8].is_checked);
        if let Some(a) = &rows[1].action {
            a();
        }
        assert_eq!(*ran.borrow(), [EditorCommand::ZoomFit]);
    }

    #[test]
    fn edit_mode_menu_only_reports_a_change() {
        let s = strip(1, TimelineEditMode::Normal);
        let picked = Rc::new(std::cell::RefCell::new(Vec::new()));
        let sink = Rc::clone(&picked);
        let rows = s.items(
            TimelineHeaderMenu::EditMode,
            &ToolState::default(),
            false,
            &CommandMap::current(),
            HeaderMenuHandlers {
                run: Rc::new(|_| {}),
                toggle_place_clips: Rc::new(|| {}),
                pick_mode: Rc::new(move |m| sink.borrow_mut().push(m)),
                select_tab: Rc::new(|_| {}),
            },
        );
        for r in &rows {
            if let Some(a) = &r.action {
                a();
            }
        }
        assert_eq!(*picked.borrow(), [TimelineEditMode::Magnetic]);
    }

    // Track header layout.

    fn track(kind: TrackKind) -> Track {
        Track::new(Id::from_u128(1), kind)
    }

    #[test]
    fn video_slots_run_right_to_left_eye_then_lock_then_sync() {
        let s = TrackHeaderLayout::slots(190.0, 40.0, TrackKind::Video, true, None);
        assert_eq!(s.eye, Some(CGRect::new(163.0, 8.0, 24.0, 24.0)));
        assert_eq!(s.lock, CGRect::new(139.0, 8.0, 24.0, 24.0));
        assert_eq!(s.sync, CGRect::new(115.0, 8.0, 24.0, 24.0));
        assert_eq!((s.mute, s.solo), (None, None));
        assert_eq!(s.name_right, 115.0);
    }

    #[test]
    fn audio_slots_put_solo_first_then_mute_and_no_lock_unless_asked() {
        let s = TrackHeaderLayout::slots(190.0, 40.0, TrackKind::Audio, false, None);
        assert_eq!(s.solo, Some(CGRect::new(160.0, 11.0, 20.0, 18.0)));
        assert_eq!(s.mute, Some(CGRect::new(136.0, 11.0, 20.0, 18.0)));
        assert_eq!((s.lock, s.sync, s.eye), (ZERO, ZERO, None));
        let with_lock = TrackHeaderLayout::slots(190.0, 40.0, TrackKind::Audio, false, Some(true));
        assert_eq!(with_lock.lock.x, 108.0);
    }

    #[test]
    fn low_rows_shrink_the_buttons_but_never_below_14() {
        assert_eq!(TrackHeaderLayout::button_size(40.0), 24.0);
        assert_eq!(TrackHeaderLayout::button_size(20.0), 16.0);
        assert_eq!(TrackHeaderLayout::button_size(10.0), 14.0);
    }

    #[test]
    fn chip_is_centered_and_clamped_in_low_rows() {
        assert_eq!(TrackHeaderLayout::chip_rect(40.0), CGRect::new(12.0, 11.0, 26.0, 18.0));
        assert_eq!(TrackHeaderLayout::chip_rect(20.0), CGRect::new(12.0, 2.0, 26.0, 16.0));
        assert_eq!(TrackHeaderLayout::chip_rect(10.0).height, 12.0);
    }

    #[test]
    fn display_name_falls_back_to_the_chip_number() {
        assert_eq!(TrackHeaderLayout::display_name("  Music  ", "A2", TrackKind::Audio), "Music");
        assert_eq!(TrackHeaderLayout::display_name("", "V1", TrackKind::Video), "Video 1");
        assert_eq!(TrackHeaderLayout::display_name("a2", "A2", TrackKind::Audio), "Audio 2");
        assert_eq!(TrackHeaderLayout::display_name("", "X", TrackKind::Video), "");
    }

    #[test]
    fn heads_never_show_sync_lock_and_audio_shows_only_m_and_s() {
        let audio = track(TrackKind::Audio);
        for hovered in [false, true] {
            assert_eq!(TrackHeaderLayout::shows(&audio, hovered), (false, false));
            assert_eq!(TrackHeaderLayout::shows(&track(TrackKind::Video), hovered), (false, true));
        }
        let a = TrackHeaderLayout::layout(&audio, 190.0, 40.0, true);
        // Only S and M are shown: the name ends before M (x 136).
        assert_eq!(a.name_right, 132.0);
        assert_eq!((a.lock, a.sync), (ZERO, ZERO));
        let v = TrackHeaderLayout::layout(&track(TrackKind::Video), 190.0, 40.0, true);
        assert_eq!(v.sync, ZERO);
        assert_eq!(v.lock, CGRect::new(139.0, 8.0, 24.0, 24.0));
    }

    #[test]
    fn a_compact_bar_keeps_only_the_cell_row_and_gives_the_lanes_the_whole_area() {
        let mut s = TimelineHeaderStrip::new(DrawTheme::default());
        s.compact = true;
        let area = sq_draw::Rect { x: 0.0, y: 100.0, w: 1200.0, h: 300.0 };
        let below = s.layout(area, 1.0, state(2, TimelineEditMode::Normal));
        assert_eq!((below.y, below.h), (100.0, 300.0));
        assert_eq!(s.bar(), ZERO);
        assert!(s.tab_rects().is_empty());
        let (snap, fit) = (s.frames().snap, s.frames().fit);
        assert!(snap.min_y() >= 100.0 && snap.max_y() <= 100.0 + TimelineGeometry::RULER_HEIGHT);
        assert_eq!(fit, ZERO);
        assert_eq!(s.control_at(CGPoint { x: snap.mid_x(), y: snap.mid_y() }), Some(HeaderControl::Snap));
        assert_eq!(s.control_at(CGPoint { x: 5.0, y: 105.0 }), None);
    }

    #[test]
    fn the_sequence_menu_lists_the_tabs_and_a_row_selects_one() {
        let s = strip(2, TimelineEditMode::Normal);
        let picked = Rc::new(std::cell::RefCell::new(Vec::new()));
        let sink = Rc::clone(&picked);
        let rows = s.items(
            TimelineHeaderMenu::Sequence,
            &ToolState::default(),
            false,
            &CommandMap::current(),
            HeaderMenuHandlers {
                run: Rc::new(|_| {}),
                toggle_place_clips: Rc::new(|| {}),
                pick_mode: Rc::new(|_| {}),
                select_tab: Rc::new(move |id| sink.borrow_mut().push(id)),
            },
        );
        assert_eq!(rows.len(), 2);
        assert!(rows[0].is_checked && !rows[1].is_checked);
        (rows[1].action.as_ref().expect("an action"))();
        assert_eq!(*picked.borrow(), [Id::from_u128(2)]);
    }
}

#[cfg(test)]
mod slot_tests {
    use super::*;

    #[test]
    fn header_buttons_never_overlap_hovered_or_not() {
        for kind in [TrackKind::Video, TrackKind::Audio] {
            for h in [20.0, 24.0, 30.0, 48.0] {
                let sl = TrackHeaderLayout::slots(220.0, h, kind, true, Some(true));
                let rects: Vec<CGRect> =
                    [Some(sl.lock), Some(sl.sync), sl.eye, sl.mute, sl.solo].into_iter().flatten().collect();
                for (i, a) in rects.iter().enumerate() {
                    for b in &rects[i + 1..] {
                        assert!(a.max_x() <= b.min_x() || b.max_x() <= a.min_x(), "{kind:?} {h}: {a:?} overlaps {b:?}");
                    }
                }
            }
        }
    }
}

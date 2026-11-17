// Swift: MonitorFooter.swift
//! The footer of the Program and Source monitors (Mac SQMonitorUI `MonitorPanelView` footer and `MonitorScrubBar`),
//! translated to the portable canvas: the same scrub math, the same gesture rules, the same look. The Mac view keeps
//! its AppKit shell and uses `MonitorScrubMath` from here.

use super::monitor_modes::{MonitorAction, MonitorMode};
use crate::canvas::Canvas;
use crate::glyph_atlas::TextAlign;
use crate::input::{InputKey, InputModifiers};
use crate::inspector::text_edit_state::{Outcome, TextEditState};
use crate::stone::{ButtonKind, Touch};
use crate::theme::DrawTheme;
use crate::ui_cx::UiCx;
use sq_core_edit::timeline_source_edit::SourceStreams;
use sq_core_time::Time;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqicon::SQIcon;
use sq_uikit::timecode::Timecode;

/// Maths of the strip under a monitor's picture: x position <-> time over the whole duration.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MonitorScrubMath {
    /// The whole duration.
    pub duration: Time,
    /// One frame.
    pub frame_duration: Time,
    /// Strip width in points.
    pub width: f64,
    /// Space on both sides (v9 `.mtr` padding: track from 12 to width - 12).
    pub inset: f64,
}

/// What a mouse-down grabs: the In or Out grip, else the playhead (scrubbing).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrubHit {
    /// The In grip.
    MarkIn,
    /// The Out grip.
    MarkOut,
    /// The playhead.
    Playhead,
}

impl MonitorScrubMath {
    /// Grab distance of a grip, points.
    pub const HIT_SLOP: f64 = 6.0;

    /// Scrub math with the default inset of 12.
    pub fn new(duration: Time, frame_duration: Time, width: f64) -> MonitorScrubMath {
        MonitorScrubMath { duration, frame_duration, width, inset: 12.0 }
    }

    fn span(&self) -> f64 {
        (self.width - 2.0 * self.inset).max(1.0)
    }

    /// Frame-snapped time under `x`, clamped to the first and last frame.
    pub fn time_at_x(&self, x: f64) -> Time {
        if self.duration <= Time::ZERO {
            return Time::ZERO;
        }
        let f = ((x - self.inset) / self.span()).clamp(0.0, 1.0);
        let scale: i64 = 100_000;
        let raw =
            Time::new((f * scale as f64).round() as i64 * self.duration.value(), scale * self.duration.timescale());
        raw.snapped(self.frame_duration).min(Time::ZERO.max(self.duration - self.frame_duration))
    }

    /// What a mouse-down at `x` grabs: the In or Out grip (when marks are given and within `slop` points), else the playhead
    /// (scrubbing). The nearest grip wins; a tie goes to the grip so a mark just set at the playhead can still be dragged.
    pub fn hit(&self, x: f64, mark_in: Option<Time>, mark_out: Option<Time>, slop: f64) -> ScrubHit {
        let mut best: Option<(ScrubHit, f64)> = None;
        for (hit, mark) in [(ScrubHit::MarkIn, mark_in), (ScrubHit::MarkOut, mark_out)] {
            let Some(m) = mark else { continue };
            let d = (self.x_for(m) - x).abs();
            if d <= slop && best.is_none_or(|b| d < b.1) {
                best = Some((hit, d));
            }
        }
        best.map(|b| b.0).unwrap_or(ScrubHit::Playhead)
    }

    /// The x of a time.
    pub fn x_for(&self, t: Time) -> f64 {
        if self.duration <= Time::ZERO {
            return self.inset;
        }
        let f =
            t.value() as f64 / t.timescale() as f64 / (self.duration.value() as f64 / self.duration.timescale() as f64);
        self.inset + self.span() * f.clamp(0.0, 1.0)
    }
}

/// The marks state the footer draws and edits (MonitorPanelModel's fields the scrub bar and row read).
#[derive(Clone, Debug, PartialEq)]
pub struct MonitorFooterState {
    /// Program or Source.
    pub mode: MonitorMode,
    /// The playhead.
    pub current_time: Time,
    /// The whole duration.
    pub duration: Time,
    /// One frame.
    pub frame_duration: Time,
    /// Mark In.
    pub mark_in: Option<Time>,
    /// Stored Mark Out.
    pub mark_out: Option<Time>,
    /// Marker flags on the bar.
    pub marker_times: Vec<Time>,
    /// Playing.
    pub is_playing: bool,
    /// The host edits marks (MonitorPanelModel.marksEditable: an `onMarkEdit` and not a source file view).
    pub marks_editable: bool,
    /// Source monitor showing a file: marks are locked, dragging the empty track scrubs.
    pub source_file_view: bool,
    /// The timecode format.
    pub timecode: Timecode,
}

impl MonitorFooterState {
    /// A state at time zero.
    pub fn new(mode: MonitorMode, frame_duration: Time, drop_frame: bool) -> MonitorFooterState {
        MonitorFooterState {
            mode,
            current_time: Time::ZERO,
            duration: Time::ZERO,
            frame_duration,
            mark_in: None,
            mark_out: None,
            marker_times: vec![],
            is_playing: false,
            marks_editable: true,
            source_file_view: false,
            timecode: Timecode::new(frame_duration, drop_frame),
        }
    }

    /// An In or Out mark is set.
    pub fn has_range(&self) -> bool {
        self.mark_in.is_some() || self.mark_out.is_some()
    }
    /// The whole duration as text.
    pub fn duration_text(&self) -> String {
        self.timecode.format(self.duration)
    }
    /// Length between In and Out (Out defaults to the end, In to the start); `None` when neither is set.
    pub fn in_out_duration_text(&self) -> Option<String> {
        if !self.has_range() {
            return None;
        }
        let len = self.mark_out.unwrap_or(self.duration) - self.mark_in.unwrap_or(Time::ZERO);
        Some(self.timecode.format(if len < Time::ZERO { Time::ZERO } else { len }))
    }
    /// The one duration the footer shows.
    pub fn footer_duration_text(&self) -> String {
        self.in_out_duration_text().unwrap_or_else(|| self.duration_text())
    }

    /// Drag preview: moves the In or Out to the frame `frame` (`Playhead` is ignored). Out is stored one frame past it.
    /// (MonitorPanelModel.previewMark.)
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
}

/// What the footer asks the host for (MonitorPanelModel's callbacks: perform, onScrub/onSeek, previewMark, commit).
#[derive(Clone, Debug, PartialEq)]
pub enum MonitorFooterEvent {
    /// A button fired.
    Action(MonitorAction),
    /// A scrub began.
    ScrubBegan,
    /// Seek here.
    Scrub(Time),
    /// The scrub ended.
    ScrubEnded,
    /// A drag preview of one mark (the host draws it, nothing is stored yet).
    PreviewMark(ScrubHit, Time),
    /// Mouse-up: store the previewed mark as one undo step.
    CommitMark(ScrubHit),
    /// Right-click on the strip: the host opens `MonitorFooter::mark_menu` at this point.
    MarkMenu {
        /// Pointer x.
        x: f64,
        /// Pointer y.
        y: f64,
    },
    /// Return in the timecode field (the Mac `commitTimecode`): the host parses and seeks.
    CommitTimecode(String),
}

/// Hover cursor over the strip.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrubCursor {
    /// Plain.
    Arrow,
    /// Resize at a grip.
    ResizeLeftRight,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Drag {
    Scrub,
    Grip(ScrubHit),
}

/// The scrub strip gesture (MonitorScrubBar's mouse handling, minus its range drags). A press anywhere scrubs: the playhead
/// jumps there and follows the drag. Only a press on an In or Out grip moves that mark. Marks are never made or moved
/// by dragging the bar itself: they come from their keys, buttons and menu rows (an accidental scrub used to mark a range).
#[derive(Clone, Copy, Debug, Default)]
pub struct MonitorScrubGesture {
    drag: Option<Drag>,
}

impl MonitorScrubGesture {
    /// An idle gesture.
    pub fn new() -> MonitorScrubGesture {
        MonitorScrubGesture::default()
    }

    /// A drag is running.
    pub fn is_active(&self) -> bool {
        self.drag.is_some()
    }

    /// What a press at `x` picks up: an In or Out grip when marks are editable and one is in reach, else the scrub.
    fn target(x: f64, s: &MonitorFooterState, m: &MonitorScrubMath) -> Drag {
        if s.marks_editable {
            let grip = m.hit(x, s.mark_in, s.mark_out, MonitorScrubMath::HIT_SLOP);
            if grip != ScrubHit::Playhead {
                return Drag::Grip(grip);
            }
        }
        Drag::Scrub
    }

    /// Hover cursor: resize at a grip, open hand inside the range, else arrow.
    pub fn cursor(x: f64, s: &MonitorFooterState, m: &MonitorScrubMath) -> ScrubCursor {
        match Self::target(x, s, m) {
            Drag::Grip(_) => ScrubCursor::ResizeLeftRight,
            Drag::Scrub => ScrubCursor::Arrow,
        }
    }

    /// A press at `x` (strip coordinates).
    pub fn down(&mut self, x: f64, s: &MonitorFooterState, m: &MonitorScrubMath) -> Vec<MonitorFooterEvent> {
        if s.duration <= Time::ZERO {
            return vec![];
        }
        let d = Self::target(x, s, m);
        self.drag = Some(d);
        match d {
            Drag::Grip(h) => vec![MonitorFooterEvent::PreviewMark(h, m.time_at_x(x))],
            Drag::Scrub => vec![MonitorFooterEvent::ScrubBegan, MonitorFooterEvent::Scrub(m.time_at_x(x))],
        }
    }

    /// The pointer moved with the button down.
    pub fn dragged(&mut self, x: f64, m: &MonitorScrubMath) -> Vec<MonitorFooterEvent> {
        let Some(d) = self.drag else { return vec![] };
        match d {
            Drag::Scrub => vec![MonitorFooterEvent::Scrub(m.time_at_x(x))],
            Drag::Grip(h) => vec![MonitorFooterEvent::PreviewMark(h, m.time_at_x(x))],
        }
    }

    /// The button went up.
    pub fn up(&mut self) -> Vec<MonitorFooterEvent> {
        let d = self.drag.take();
        match d {
            Some(Drag::Grip(h)) => vec![MonitorFooterEvent::CommitMark(h)],
            Some(Drag::Scrub) => vec![MonitorFooterEvent::ScrubEnded],
            None => vec![],
        }
    }
}

/// A press on the timecode: where it began and the time then; past 3 pt it is a scrub (the Mac `TimecodeField`).
#[derive(Clone, Copy, Debug)]
struct TimecodePress {
    x: f64,
    start: Time,
    dragging: bool,
}

/// One row of the scrub bar's right-click menu.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MarkMenuRow {
    /// Row title.
    pub title: &'static str,
    /// What it does.
    pub action: MonitorAction,
    /// Whether it can run.
    pub enabled: bool,
}

/// The monitor footer (v9 `.mtr`): scrub bar on top, then one row: timecode left | five buttons centered | In/Out icon
/// + the one duration (+ Source: Insert / Overwrite) right. Sizes in points; the canvas scales.
#[derive(Clone, Debug, Default)]
pub struct MonitorFooter {
    frame: CGRect,
    scrub_rect: CGRect,
    timecode_rect: CGRect,
    duration_rect: CGRect,
    in_out_icon_rect: CGRect,
    buttons: Vec<(MonitorAction, CGRect)>,
    stream_handles: Vec<(SourceStreams, CGRect)>,
    /// The button under the pointer.
    pub hovered: Option<MonitorAction>,
    /// The button being pressed.
    pub pressed: Option<MonitorAction>,
    gesture: MonitorScrubGesture,
    timecode_edit: Option<TextEditState>,
    timecode_press: Option<TimecodePress>,
}

impl MonitorFooter {
    /// Theme.Metrics.monitorFooter
    pub const HEIGHT: f64 = 66.0;
    /// Theme.Metrics.scrubBar
    pub const SCRUB_HEIGHT: f64 = 16.0;
    const ROW_HEIGHT: f64 = 28.0;
    const SMALL_GLYPH: f64 = 16.0;
    const PLAY_GLYPH: f64 = 16.0;
    /// Theme.Row.controlLarge
    const SMALL_BOX: f64 = 24.0;
    /// The Program/Source timecode: 15 pt medium, as in the kit (audit A8; it was 12 pt regular).
    const TIMECODE_SIZE: f64 = 15.0;
    const TIMECODE_WIDTH: f64 = 104.0;
    const GRIP_WIDTH: f64 = 3.0;
    /// Theme.Spacing.xxs
    const BUTTON_GAP: f64 = 2.0;
    const ICON_TO_LABEL: f64 = 6.0;
    /// Board `.hdl`: 26 x 22 capsule, 2 pt between the two.
    const HANDLE_SIZE: CGSize = CGSize::new(26.0, 22.0);
    const HANDLE_GAP: f64 = 2.0;

    /// Icon and title per footer action (MonitorPanelView.symbols).
    pub fn symbol(a: MonitorAction) -> Option<(SQIcon, &'static str)> {
        Some(match a {
            MonitorAction::MarkIn => (SQIcon::MarkIn, "Mark In"),
            MonitorAction::MarkOut => (SQIcon::MarkOut, "Mark Out"),
            MonitorAction::GoToIn => (SQIcon::GoToStart, "Go to In"),
            MonitorAction::GoToOut => (SQIcon::GoToEnd, "Go to Out"),
            MonitorAction::StepBack => (SQIcon::GoToStart, "Step Back"),
            MonitorAction::StepForward => (SQIcon::GoToEnd, "Step Forward"),
            MonitorAction::PlayPause => (SQIcon::Play, "Play"),
            MonitorAction::AddMarker => (SQIcon::Marker, "Add Marker"),
            MonitorAction::Insert => (SQIcon::InsertEdit, "Insert"),
            MonitorAction::Overwrite => (SQIcon::OverwriteEdit, "Overwrite"),
            MonitorAction::Lift => (SQIcon::ArrowUpFromLine, "Clear Range"),
            MonitorAction::Extract => (SQIcon::ArrowUpToLine, "Delete Range"),
            MonitorAction::ExportFrame => (SQIcon::Camera, "Export Frame"),
            _ => return None,
        })
    }

    /// A footer not yet laid out.
    pub fn new() -> MonitorFooter {
        MonitorFooter::default()
    }

    /// The footer's frame.
    pub fn frame(&self) -> CGRect {
        self.frame
    }
    /// The scrub strip.
    pub fn scrub_rect(&self) -> CGRect {
        self.scrub_rect
    }
    /// The timecode field.
    pub fn timecode_rect(&self) -> CGRect {
        self.timecode_rect
    }
    /// The duration text.
    pub fn duration_rect(&self) -> CGRect {
        self.duration_rect
    }
    /// The "TOTAL" caption left of the In/Out icon: only the Program footer showing the whole sequence length, and only when
    /// it clears the transport.
    pub fn total_label_rect(&self, s: &MonitorFooterState) -> Option<CGRect> {
        const WIDTH: f64 = 40.0;
        if s.mode != MonitorMode::Program || s.has_range() || self.duration_rect.width <= 0.0 {
            return None;
        }
        let r = CGRect::new(
            self.duration_rect.x - Self::ICON_TO_LABEL - WIDTH,
            self.duration_rect.y,
            WIDTH,
            self.duration_rect.height,
        );
        let transport_end = self.buttons.iter().map(|b| b.1.max_x()).fold(0.0, f64::max);
        (r.x >= transport_end + 8.0).then_some(r)
    }
    /// Whether the In/Out mark is drawn: only while the duration shown is that of an In/Out range.
    pub fn shows_in_out_icon(&self, s: &MonitorFooterState) -> bool {
        s.has_range()
    }
    /// The In/Out icon.
    pub fn in_out_icon_rect(&self) -> CGRect {
        self.in_out_icon_rect
    }
    /// Footer buttons in drawing order (transport, then the Source edit buttons).
    pub fn buttons(&self) -> &[(MonitorAction, CGRect)] {
        &self.buttons
    }
    /// Source monitor: the Drag Video Only / Drag Audio Only handles at the right end (the Mac `StreamDragView` pair);
    /// a press starts a drag of that stream onto the timeline (the panel runs it). Dropped first when narrow.
    pub fn stream_handles(&self) -> &[(SourceStreams, CGRect)] {
        &self.stream_handles
    }
    /// The strip gesture.
    pub fn gesture(&self) -> &MonitorScrubGesture {
        &self.gesture
    }
    /// The timecode field while it is edited (Go to Timecode or a click on it); `None` = it shows the time.
    pub fn timecode_edit(&self) -> Option<&TextEditState> {
        self.timecode_edit.as_ref()
    }

    /// The strip's math for `s`.
    pub fn scrub_math(&self, s: &MonitorFooterState) -> MonitorScrubMath {
        MonitorScrubMath::new(s.duration, s.frame_duration, self.scrub_rect.width)
    }

    /// The width to reserve for a duration text measured as `measured` points: a rounding margin so the drawn text fits at
    /// every display scale (the rect is multiplied back to pixels and compared with the pixel width of the text).
    pub fn duration_slot(measured: f64) -> f64 {
        measured.ceil() + 1.0
    }

    /// Lays the footer out in `r` (its full width, `HEIGHT` tall). Narrow panels drop the edit buttons, then the
    /// duration (MonitorPanelView.layout's order of loss); timecode and the five buttons always stay.
    pub fn layout(&mut self, r: CGRect, s: &MonitorFooterState, duration_width: f64) {
        self.frame = r;
        self.scrub_rect = CGRect::new(r.min_x(), r.min_y() + 8.0, r.width, Self::SCRUB_HEIGHT);
        let row_mid = r.max_y() - 8.0 - Self::ROW_HEIGHT / 2.0;
        self.timecode_rect = CGRect::new(
            r.min_x() + 12.0 - 2.0,
            row_mid - Self::ROW_HEIGHT / 2.0,
            Self::TIMECODE_WIDTH,
            Self::ROW_HEIGHT,
        );
        let w = |a: MonitorAction| if a == MonitorAction::PlayPause { Self::ROW_HEIGHT } else { Self::SMALL_BOX };
        let width_of = |bar: &[MonitorAction]| {
            bar.iter().map(|a| w(*a)).fold(0.0, |a, b| a + b) + Self::BUTTON_GAP * bar.len().saturating_sub(1) as f64
        };
        // A footer too narrow for the whole bar drops the outer buttons first (Mark In / Out stay on I and O), then the
        // step buttons: the bar never runs past the right edge.
        let fit_room = r.max_x() - 12.0 - self.timecode_rect.max_x();
        let full = MonitorAction::button_bar(s.mode);
        let no_marks: Vec<MonitorAction> =
            full.iter().copied().filter(|a| !matches!(a, MonitorAction::MarkIn | MonitorAction::MarkOut)).collect();
        let only_play = vec![MonitorAction::PlayPause];
        let bar =
            [full, no_marks, only_play.clone()].into_iter().find(|b| width_of(b) <= fit_room).unwrap_or(only_play);
        let transport_w = width_of(&bar);
        let edits: Vec<MonitorAction> =
            if s.mode == MonitorMode::Source { vec![MonitorAction::Insert, MonitorAction::Overwrite] } else { vec![] };
        let icon_w = 14.0;
        let edits_w = if edits.is_empty() { 0.0 } else { edits.len() as f64 * (Self::SMALL_BOX + Self::ICON_TO_LABEL) };
        let handles: Vec<SourceStreams> = if s.mode == MonitorMode::Source {
            vec![SourceStreams::VideoOnly, SourceStreams::AudioOnly]
        } else {
            vec![]
        };
        let handles_w = if handles.is_empty() {
            0.0
        } else {
            2.0 * Self::HANDLE_SIZE.width + Self::HANDLE_GAP + Self::ICON_TO_LABEL
        };
        // Transport centered on the footer, never left of the timecode; the right group (marks, duration, edits, handles)
        // must start after where the transport really ends, so it drops pieces from the outside in instead of overlapping.
        let transport_start = (r.mid_x() - transport_w / 2.0).round().max(self.timecode_rect.max_x());
        let room = r.max_x() - 12.0 - (transport_start + transport_w + 4.0);
        let base = icon_w + Self::ICON_TO_LABEL + duration_width;
        let mut show_edits = !edits.is_empty();
        let mut show_duration = true;
        let show_handles = !handles.is_empty() && room >= base + edits_w + handles_w;
        if room < base + edits_w {
            show_edits = false;
        }
        if room < base {
            show_duration = false;
        }
        let mut x = (r.mid_x() - transport_w / 2.0).round().max(self.timecode_rect.max_x());
        self.buttons = vec![];
        for a in &bar {
            let bw = w(*a);
            self.buttons.push((*a, CGRect::new(x, row_mid - bw / 2.0, bw, bw)));
            x += bw + Self::BUTTON_GAP;
        }
        let mut right = r.max_x() - 12.0;
        self.stream_handles = vec![];
        if show_handles {
            for h in handles.iter().rev() {
                right -= Self::HANDLE_SIZE.width;
                self.stream_handles.insert(
                    0,
                    (
                        *h,
                        CGRect::new(
                            right,
                            row_mid - Self::HANDLE_SIZE.height / 2.0,
                            Self::HANDLE_SIZE.width,
                            Self::HANDLE_SIZE.height,
                        ),
                    ),
                );
                right -= Self::HANDLE_GAP;
            }
            right += Self::HANDLE_GAP - Self::ICON_TO_LABEL;
        }
        if show_edits {
            for a in edits.iter().rev() {
                right -= Self::SMALL_BOX;
                self.buttons
                    .push((*a, CGRect::new(right, row_mid - Self::SMALL_BOX / 2.0, Self::SMALL_BOX, Self::SMALL_BOX)));
                right -= Self::ICON_TO_LABEL;
            }
        }
        self.duration_rect = if show_duration {
            CGRect::new(right - duration_width, row_mid - Self::ROW_HEIGHT / 2.0, duration_width, Self::ROW_HEIGHT)
        } else {
            CGRect::default()
        };
        if show_duration {
            right -= duration_width + Self::ICON_TO_LABEL;
        }
        self.in_out_icon_rect = CGRect::new(right - icon_w, row_mid - icon_w / 2.0, icon_w, icon_w);
    }

    /// The button under `p`.
    pub fn button_at(&self, p: CGPoint) -> Option<MonitorAction> {
        self.buttons.iter().find(|b| b.1.contains(p)).map(|b| b.0)
    }
    /// The stream handle under `p` (Source monitor).
    pub fn stream_handle_at(&self, p: CGPoint) -> Option<SourceStreams> {
        self.stream_handles.iter().find(|b| b.1.contains(p)).map(|b| b.0)
    }

    /// The handle's icon (and the ghost's): film for video, waveform for audio, sequence for both.
    pub fn drag_icon(streams: SourceStreams) -> SQIcon {
        match streams {
            SourceStreams::AudioOnly => SQIcon::Waveform,
            SourceStreams::VideoOnly => SQIcon::Film,
            SourceStreams::Both => SQIcon::Sequence,
        }
    }

    // Drawing

    /// Draws the footer.
    pub fn draw(&self, c: &mut Canvas, s: &MonitorFooterState, t: &DrawTheme, cx: &mut UiCx) {
        self.draw_scrub_bar(c, s, t);
        let size = 12.0; // Theme.Typography.shell / shellStrong
        if self.timecode_edit.is_some() {
            self.draw_timecode_edit(c, t, cx);
        } else {
            c.draw_text_in(
                &s.timecode.format(s.current_time),
                self.timecode_rect,
                Self::TIMECODE_SIZE,
                t.label(),
                TextAlign::Left,
                0.0,
                c.medium(),
            );
        }
        for (a, r) in &self.buttons {
            let is_play = *a == MonitorAction::PlayPause;
            let touch =
                Touch { hovering: self.hovered == Some(*a), pressed: self.pressed == Some(*a), ..Touch::default() };
            c.stone_button(*r, ButtonKind::Quiet, touch, t);
            let glyph = if is_play { Self::PLAY_GLYPH } else { Self::SMALL_GLYPH };
            let icon = if is_play {
                Some(if s.is_playing { SQIcon::Pause } else { SQIcon::Play })
            } else {
                Self::symbol(*a).map(|x| x.0)
            };
            let Some(icon) = icon else { continue };
            let color = if s.duration > Time::ZERO {
                if is_play { t.label() } else { t.label2() }
            } else {
                t.label3().with_alpha(0.5)
            };
            c.draw_icon(icon, CGPoint { x: r.mid_x() - glyph / 2.0, y: r.mid_y() - glyph / 2.0 }, glyph, color, None);
        }
        for (h, r) in &self.stream_handles {
            // StreamDragView.draw: fill2 capsule with a hairline edge, the 14 pt icon in label2.
            c.fill_rounded(*r, r.height / 2.0, t.fill());
            c.stroke_rounded(r.inset_by(0.25, 0.25), r.height / 2.0, 0.5, t.separator());
            c.draw_icon(
                Self::drag_icon(*h),
                CGPoint { x: r.mid_x() - 7.0, y: r.mid_y() - 7.0 },
                14.0,
                t.label2(),
                None,
            );
        }
        // The In/Out mark belongs to a ranged duration; the whole length reads "TOTAL 00:00:44:10" with nothing between.
        if self.shows_in_out_icon(s) {
            c.draw_icon(
                SQIcon::MarkInOut,
                CGPoint { x: self.in_out_icon_rect.x, y: self.in_out_icon_rect.y },
                self.in_out_icon_rect.width,
                t.label3(),
                None,
            );
        }
        if let Some(r) = self.total_label_rect(s) {
            c.draw_text_in("TOTAL", r, size - 2.0, t.label3(), TextAlign::Right, 0.0, 0);
        }
        if self.duration_rect.width > 0.0 {
            c.draw_text_in(&s.footer_duration_text(), self.duration_rect, size, t.label2(), TextAlign::Right, 0.0, 0);
        }
    }

    /// MonitorScrubBar.draw: 2 pt bar at y 7, In to Out as a 6 pt tinted band at y 5, 3 x 12 accent grips, yellow
    /// marker triangles above the track, playhead 2 x 14 at y 1.
    pub fn draw_scrub_bar(&self, c: &mut Canvas, s: &MonitorFooterState, t: &DrawTheme) {
        let m = self.scrub_math(s);
        c.save_gstate();
        c.translate_by(self.scrub_rect.min_x(), self.scrub_rect.min_y());
        // The kit's `Scrub`: a 4 pt sunken stone well (inset 3D), centered on the 16 pt strip.
        let track = CGRect::new(m.inset, 6.0, (self.scrub_rect.width - 2.0 * m.inset).max(0.0), 4.0);
        c.stone_track(track, t);
        if s.has_range() {
            let a = m.x_for(s.mark_in.unwrap_or(Time::ZERO));
            let b = m.x_for(s.mark_out.unwrap_or(s.duration));
            if b > a {
                let band = CGRect::new(a, 7.0, b - a, 2.0); // a thin range line inside the well, not a band
                c.fill_rounded(band, band.height / 2.0, t.accent());
            }
        }
        for (mark, is_in) in [(s.mark_in, true), (s.mark_out, false)] {
            let Some(mark) = mark else { continue };
            let hx = m.x_for(mark);
            let grip = CGRect::new(if is_in { hx } else { hx - Self::GRIP_WIDTH }, 2.0, Self::GRIP_WIDTH, 12.0);
            c.fill_rounded(grip, grip.width / 2.0, t.accent());
        }
        for time in &s.marker_times {
            let mx = m.x_for(*time);
            // pentagon flag like the ruler
            c.fill_polygon(
                &[
                    CGPoint { x: mx - 3.0, y: 0.0 },
                    CGPoint { x: mx + 3.0, y: 0.0 },
                    CGPoint { x: mx + 3.0, y: 3.0 },
                    CGPoint { x: mx, y: 6.0 },
                    CGPoint { x: mx - 3.0, y: 3.0 },
                ],
                t.label3(),
            );
        }
        let x = m.x_for(s.current_time);
        if s.duration > Time::ZERO {
            c.fill_rounded(CGRect::new(x - 1.0, 1.0, 2.0, 14.0), 1.0, t.playhead());
        }
        c.restore_gstate();
    }

    // Input (points, footer coordinates of the canvas)

    /// A press at `p`. `caret_index` maps an x offset in the open timecode field to a caret index.
    pub fn mouse_down(
        &mut self,
        p: CGPoint,
        s: &MonitorFooterState,
        right: bool,
        caret_index: Option<&dyn Fn(f64) -> usize>,
    ) -> Vec<MonitorFooterEvent> {
        if !right && self.timecode_rect.contains(p) {
            if let Some(e) = self.timecode_edit.as_mut() {
                // a click in the open field moves the caret
                match caret_index {
                    Some(f) => e.place(f(p.x - self.timecode_rect.min_x()), false),
                    None => e.select_all(),
                }
            } else {
                self.timecode_press = Some(TimecodePress { x: p.x, start: s.current_time, dragging: false });
            }
            return vec![];
        }
        self.timecode_edit = None; // a press elsewhere ends the edit; the field shows the time again
        if self.scrub_rect.contains(p) {
            if right {
                return if s.duration > Time::ZERO {
                    vec![MonitorFooterEvent::MarkMenu { x: p.x, y: p.y }]
                } else {
                    vec![]
                };
            }
            let m = self.scrub_math(s);
            return self.gesture.down(p.x - self.scrub_rect.min_x(), s, &m);
        }
        if !right && let Some(a) = self.button_at(p) {
            self.pressed = Some(a);
        }
        vec![]
    }

    /// The pointer moved with the button down.
    pub fn mouse_dragged(&mut self, p: CGPoint, s: &MonitorFooterState) -> Vec<MonitorFooterEvent> {
        if let Some(mut tp) = self.timecode_press {
            let dx = p.x - tp.x;
            let mut out = vec![];
            if !tp.dragging && dx.abs() > 3.0 {
                tp.dragging = true;
                out.push(MonitorFooterEvent::ScrubBegan);
            }
            self.timecode_press = Some(tp);
            if !tp.dragging {
                return out;
            }
            // `MonitorPanelModel.time(offsetFrom:frames:)`: 1 frame per 2 pt, never before 0, on the frame grid.
            let frames = (dx / 2.0).round() as i64;
            out.push(MonitorFooterEvent::Scrub(
                Time::ZERO.max((tp.start + s.frame_duration * frames).snapped(s.frame_duration)),
            ));
            return out;
        }
        let m = self.scrub_math(s);
        self.gesture.dragged(p.x - self.scrub_rect.min_x(), &m)
    }

    /// The button went up at `p`.
    pub fn mouse_up(&mut self, p: CGPoint, s: &MonitorFooterState) -> Vec<MonitorFooterEvent> {
        if let Some(tp) = self.timecode_press.take() {
            if tp.dragging {
                return vec![MonitorFooterEvent::ScrubEnded];
            }
            self.begin_timecode_edit(s); // a click opens the field with its text selected
            return vec![];
        }
        if self.gesture.is_active() {
            return self.gesture.up();
        }
        let pressed = self.pressed.take();
        match pressed {
            Some(a) if self.button_at(p) == Some(a) => vec![MonitorFooterEvent::Action(a)],
            _ => vec![],
        }
    }

    /// The pointer moved.
    pub fn mouse_moved(&mut self, p: CGPoint) {
        self.hovered = self.button_at(p);
    }

    // Timecode field (the Mac `MonitorPanelView.timecodeField`)

    /// Whether the timecode field is open.
    pub fn is_editing_timecode(&self) -> bool {
        self.timecode_edit.is_some()
    }

    /// Go to Timecode and a click on the timecode: the position text, all selected.
    pub fn begin_timecode_edit(&mut self, s: &MonitorFooterState) {
        self.timecode_edit = Some(TextEditState::new(&s.timecode.position(s.current_time)));
    }

    /// Closes the field.
    pub fn end_timecode_edit(&mut self) {
        self.timecode_edit = None;
    }

    /// A key while the field is open (`None` = not editing): Return commits, Esc puts the time back.
    pub fn timecode_key(
        &mut self,
        k: InputKey,
        modifiers: InputModifiers,
        cx: &mut UiCx,
    ) -> Option<Vec<MonitorFooterEvent>> {
        let e = self.timecode_edit.as_mut()?;
        let out = e.handle(k, modifiers, cx);
        let text = e.string();
        Some(match out {
            Outcome::Commit => {
                self.timecode_edit = None;
                vec![MonitorFooterEvent::CommitTimecode(text)]
            }
            Outcome::Cancel => {
                self.timecode_edit = None;
                vec![]
            }
            _ => vec![],
        })
    }

    /// The caret offsets of the field's text from its left edge (12 pt glyphs as drawn); a click maps through them.
    pub fn timecode_carets(text: &str, measure: impl Fn(&str) -> f64) -> Vec<f64> {
        let chars: Vec<char> = text.chars().collect();
        (0..=chars.len()).map(|i| measure(&chars[..i].iter().collect::<String>())).collect()
    }

    /// Index of the caret nearest to `x` (offset from the field's left edge).
    pub fn caret_index(x: f64, carets: &[f64]) -> usize {
        // Swift min(by:) keeps the first of equal elements, like Iterator::min_by.
        (0..carets.len()).min_by(|a, b| (carets[*a] - x).abs().total_cmp(&(carets[*b] - x).abs())).unwrap_or(0)
    }

    fn draw_timecode_edit(&self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        let Some(e) = &self.timecode_edit else { return };
        let r = self.timecode_rect;
        let size = Self::TIMECODE_SIZE;
        let semibold = c.semibold();
        let xs = Self::timecode_carets(&e.string(), |s| c.size_of(s, size, semibold).width);
        let line_h = 19.0;
        let top = (r.mid_y() - line_h / 2.0).round();
        if e.has_selection() {
            let sel = e.selection();
            let (x0, x1) = (xs[sel.start], xs[sel.end]);
            c.fill(CGRect::new(r.min_x() + x0, top, x1 - x0, line_h), t.accent().with_alpha(0.3));
        }
        c.draw_text_in(&e.string(), r, size, t.accent(), TextAlign::Left, 0.0, semibold);
        let x = r.min_x() + xs[e.caret().min(xs.len() - 1)];
        c.stroke_line(CGPoint { x, y: top }, CGPoint { x, y: top + line_h }, 1.0, t.accent());
        cx.requests.caret = Some(c.px(CGRect::new(x, top, 0.0, line_h)));
    }

    /// The scrub bar's right-click menu (MonitorPanelModel.markMenu): title, action, enabled; `None` is a separator.
    pub fn mark_menu(s: &MonitorFooterState) -> Vec<Option<MarkMenuRow>> {
        let editable = !s.source_file_view;
        let row = |title, action, enabled| Some(MarkMenuRow { title, action, enabled });
        vec![
            row("Remove In", MonitorAction::ClearIn, editable && s.mark_in.is_some()),
            row("Remove Out", MonitorAction::ClearOut, editable && s.mark_out.is_some()),
            row("Remove In and Out", MonitorAction::ClearInOut, editable && s.has_range()),
            None,
            row("Go to In", MonitorAction::GoToIn, s.has_range()),
            row("Go to Out", MonitorAction::GoToOut, s.has_range()),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::monitor::monitor_footer::MonitorFooterEvent as E;
    use crate::software::{SoftwareRenderer, Sources};

    fn fd() -> Time {
        Time::new(1, 25)
    }
    /// 100 frames over a 224 pt strip: track 12...212, 2 pt per frame.
    fn state(i: Option<i64>, o: Option<i64>, at: i64) -> MonitorFooterState {
        let mut s = MonitorFooterState::new(MonitorMode::Program, fd(), false);
        s.duration = fd() * 100;
        s.current_time = fd() * at;
        s.mark_in = i.map(|v| fd() * v);
        s.mark_out = o.map(|v| fd() * v);
        s
    }
    fn footer(s: &MonitorFooterState, width: f64) -> MonitorFooter {
        let mut f = MonitorFooter::new();
        f.layout(CGRect::new(0.0, 0.0, width, MonitorFooter::HEIGHT), s, 70.0);
        f
    }
    fn y(f: &MonitorFooter) -> f64 {
        f.scrub_rect().mid_y()
    }
    fn pt(x: f64, y: f64) -> CGPoint {
        CGPoint { x, y }
    }

    #[test]
    fn a_drag_on_empty_track_scrubs_and_never_marks_a_range() {
        // No marks, a playhead far from the press: the old strip marked a new range here.
        let s = state(None, None, 90);
        let mut f = footer(&s, 224.0);
        let yy = y(&f);
        assert_eq!(f.mouse_down(pt(32.0, yy), &s, false, None), vec![E::ScrubBegan, E::Scrub(fd() * 10)]);
        assert_eq!(f.mouse_dragged(pt(34.0, yy), &s), vec![E::Scrub(fd() * 11)]);
        assert_eq!(f.mouse_dragged(pt(52.0, yy), &s), vec![E::Scrub(fd() * 20)]);
        assert_eq!(f.mouse_up(pt(52.0, yy), &s), vec![E::ScrubEnded]);
    }

    #[test]
    fn a_drag_inside_an_existing_range_scrubs_and_leaves_the_range_alone() {
        let s = state(Some(20), Some(60), 90);
        let mut f = footer(&s, 224.0);
        let yy = y(&f);
        assert_eq!(f.mouse_down(pt(92.0, yy), &s, false, None), vec![E::ScrubBegan, E::Scrub(fd() * 40)]);
        let moved = f.mouse_dragged(pt(102.0, yy), &s);
        assert_eq!(moved, vec![E::Scrub(fd() * 45)]);
        assert_eq!(f.mouse_up(pt(102.0, yy), &s), vec![E::ScrubEnded]);
    }

    #[test]
    fn grip_drag_previews_that_mark_and_click_seeks() {
        let s = state(Some(20), Some(60), 90);
        let mut f = footer(&s, 224.0);
        let yy = y(&f);
        assert_eq!(f.mouse_down(pt(53.0, yy), &s, false, None), vec![E::PreviewMark(ScrubHit::MarkIn, fd() * 21)]);
        assert_eq!(f.mouse_dragged(pt(62.0, yy), &s), vec![E::PreviewMark(ScrubHit::MarkIn, fd() * 25)]);
        assert_eq!(f.mouse_up(pt(62.0, yy), &s), vec![E::CommitMark(ScrubHit::MarkIn)]);
        // A click on empty track outside the range seeks there.
        assert_eq!(f.mouse_down(pt(172.0, yy), &s, false, None), vec![E::ScrubBegan, E::Scrub(fd() * 80)]);
        assert_eq!(f.mouse_up(pt(172.0, yy), &s), vec![E::ScrubEnded]);
    }

    #[test]
    fn source_file_view_drag_scrubs_instead_of_marking() {
        let mut s = state(None, None, 0);
        s.source_file_view = true;
        s.marks_editable = false;
        let mut f = footer(&s, 224.0);
        let yy = y(&f);
        assert_eq!(f.mouse_down(pt(112.0, yy), &s, false, None), vec![E::ScrubBegan, E::Scrub(fd() * 50)]);
        assert_eq!(f.mouse_dragged(pt(122.0, yy), &s), vec![E::Scrub(fd() * 55)]);
        assert_eq!(f.mouse_up(pt(122.0, yy), &s), vec![E::ScrubEnded]);
        assert!(!MonitorFooter::mark_menu(&s)[0].is_some_and(|r| r.enabled));
    }

    #[test]
    fn the_measured_duration_width_never_cuts_an_hour_plus_timecode() {
        // Canvas::size_of divides the atlas width by the scale, Canvas::px multiplies the rect back; the text must fit.
        let a = crate::glyph_atlas::tests::atlas();
        let mut s = state(None, None, 0);
        s.duration = fd() * 90_150; // 25 min+ of frames: hours, minutes, seconds and frames all show
        let text = s.footer_duration_text();
        for scale in [0.8f32, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0] {
            let w = f64::from(a.width_of(&text, 12.0 * scale, 0) / scale);
            let mut f = footer(&s, 600.0);
            f.layout(CGRect::new(0.0, 0.0, 600.0, 56.0), &s, MonitorFooter::duration_slot(w));
            let px_width = (f.duration_rect().width * f64::from(scale)) as f32;
            assert!(a.width_of(&text, 12.0 * scale, 0) <= px_width, "cut at scale {scale}: {text}");
        }
    }

    #[test]
    fn total_label_shows_only_for_the_whole_program_length_and_clears_the_transport() {
        let s = state(None, None, 0);
        let f = footer(&s, 600.0);
        let r = f.total_label_rect(&s).expect("TOTAL fits at 600");
        assert!(r.max_x() <= f.duration_rect().min_x(), "TOTAL sits right before the time");
        assert!(!f.shows_in_out_icon(&s), "no stray In/Out mark between TOTAL and the time");
        assert_eq!(footer(&s, 300.0).total_label_rect(&s), None);
        let ranged = state(Some(5), None, 0);
        assert_eq!(footer(&ranged, 600.0).total_label_rect(&ranged), None);
        assert!(footer(&ranged, 600.0).shows_in_out_icon(&ranged), "a ranged duration keeps its In/Out mark");
        let src = MonitorFooterState::new(MonitorMode::Source, fd(), false);
        assert_eq!(footer(&src, 600.0).total_label_rect(&src), None);
    }

    #[test]
    fn transport_centered_buttons_fire_on_release_and_narrow_drops_duration() {
        let s = state(None, None, 0);
        let mut f = footer(&s, 600.0);
        assert_eq!(
            f.buttons().iter().map(|b| b.0).collect::<Vec<_>>(),
            MonitorAction::button_bar(MonitorMode::Program)
        );
        let play = f.buttons().iter().find(|b| b.0 == MonitorAction::PlayPause).map(|b| b.1).unwrap_or_default();
        assert!((play.mid_x() - 300.0).abs() <= 1.0);
        let p = pt(play.mid_x(), play.mid_y());
        f.mouse_down(p, &s, false, None);
        assert_eq!(f.mouse_up(p, &s), vec![E::Action(MonitorAction::PlayPause)]);
        assert_eq!(f.duration_rect().width, 70.0);
        assert_eq!(footer(&s, 300.0).duration_rect().width, 0.0);
        let mut src = MonitorFooterState::new(MonitorMode::Source, fd(), false);
        src.duration = fd() * 10;
        let sf = footer(&src, 600.0);
        let n = sf.buttons().len();
        let last: Vec<MonitorAction> = sf.buttons()[n - 2..].iter().map(|b| b.0).collect();
        assert!(last.contains(&MonitorAction::Insert) && last.contains(&MonitorAction::Overwrite));
        assert_eq!(src.footer_duration_text(), src.timecode.format(fd() * 10));
    }

    #[test]
    fn a_narrow_footer_drops_the_outer_transport_buttons_instead_of_cutting_them() {
        let s = state(None, None, 0);
        for width in [200.0, 240.0, 256.0, 270.0, 330.0, 600.0] {
            let f = footer(&s, width);
            assert!(!f.buttons().is_empty(), "{width}: play stays");
            for (a, r) in f.buttons() {
                assert!(r.max_x() <= width - 12.0 + 0.5, "{width}: {a:?} ends at {}", r.max_x());
                assert!(r.min_x() >= f.timecode_rect().max_x() - 0.5, "{width}: {a:?} starts under the timecode");
            }
        }
        assert_eq!(footer(&s, 600.0).buttons().len(), 5);
        assert_eq!(footer(&s, 240.0).buttons().len(), 3, "no marks at 240");
        assert_eq!(footer(&s, 200.0).buttons().len(), 1, "only play at 200");
    }

    #[test]
    fn draws_playhead_band_and_grips() {
        let s = state(Some(20), Some(60), 90);
        let f = footer(&s, 224.0);
        let t = DrawTheme::default();
        let mut c = Canvas::with_size(224.0, MonitorFooter::HEIGHT as f32, None, 1.0);
        f.draw_scrub_bar(&mut c, &s, &t);
        let img = SoftwareRenderer::render(&c.list, 224, 66, crate::draw_list::Color::BLACK, &Sources::default());
        let px = |x: usize, y: usize| img.pixels[(y * 224 + x) * 4..(y * 224 + x) * 4 + 3].to_vec();
        assert!(px(192, 8 + 8)[0] > 200);
        assert_ne!(px(100, 8 + 7), vec![0, 0, 0]);
        assert_eq!(px(5, 8 + 8), vec![0, 0, 0]);
    }

    /// The kit's `Scrub`: a 4 pt sunken stone well (rows 6...9 of the strip), not a bright 2 pt line.
    #[test]
    fn the_scrub_track_is_a_four_point_stone_well() {
        let s = state(None, None, 90);
        let f = footer(&s, 224.0);
        let t = DrawTheme::default();
        let mut c = Canvas::with_size(224.0, MonitorFooter::HEIGHT as f32, None, 1.0);
        f.draw_scrub_bar(&mut c, &s, &t);
        let img = SoftwareRenderer::render(&c.list, 224, 66, crate::draw_list::Color::BLACK, &Sources::default());
        let px = |x: usize, y: usize| img.pixels[(y * 224 + x) * 4..(y * 224 + x) * 4 + 3].to_vec();
        for row in [6, 7, 8, 9] {
            assert_ne!(px(100, 8 + row), vec![0, 0, 0], "row {row} is inside the well");
        }
        assert_eq!(px(100, 8 + 4), vec![0, 0, 0], "above the well");
    }

    /// The Mac `TimecodeField`: a drag past 3 pt scrubs 1 frame per 2 pt from the time at the press; a click opens the
    /// field with the position selected, Return answers the typed text, Esc closes it without an answer.
    #[test]
    fn the_timecode_drags_to_scrub_and_a_click_opens_the_field() {
        let mut cx = UiCx::new();
        let s = state(None, None, 50);
        let mut f = footer(&s, 224.0);
        let tc = pt(f.timecode_rect().mid_x(), f.timecode_rect().mid_y());
        assert!(f.mouse_down(tc, &s, false, None).is_empty());
        assert!(f.mouse_dragged(pt(tc.x + 2.0, tc.y), &s).is_empty());
        assert_eq!(f.mouse_dragged(pt(tc.x + 20.0, tc.y), &s), vec![E::ScrubBegan, E::Scrub(fd() * 60)]);
        assert_eq!(f.mouse_dragged(pt(tc.x - 200.0, tc.y), &s), vec![E::Scrub(Time::ZERO)]);
        assert_eq!(f.mouse_up(pt(tc.x - 200.0, tc.y), &s), vec![E::ScrubEnded]);
        assert!(!f.is_editing_timecode());
        f.mouse_down(tc, &s, false, None);
        assert!(f.mouse_up(tc, &s).is_empty());
        let n = f.timecode_edit().map(|e| e.text().len()).unwrap_or(0);
        assert_eq!(f.timecode_edit().map(|e| e.string()), Some(s.timecode.position(s.current_time)));
        assert_eq!(f.timecode_edit().map(|e| e.selection()), Some(0..n));
        let none = InputModifiers::NONE;
        assert_eq!(f.timecode_key(InputKey::Character('1'), none, &mut cx), Some(vec![]));
        assert_eq!(f.timecode_key(InputKey::Character('0'), none, &mut cx), Some(vec![]));
        assert_eq!(f.timecode_key(InputKey::Enter, none, &mut cx), Some(vec![E::CommitTimecode("10".to_string())]));
        assert!(!f.is_editing_timecode());
        assert_eq!(f.timecode_key(InputKey::Enter, none, &mut cx), None);
        f.begin_timecode_edit(&s);
        assert_eq!(f.timecode_key(InputKey::Escape, none, &mut cx), Some(vec![]));
        assert!(!f.is_editing_timecode());
    }

    #[test]
    fn a_click_in_the_open_field_places_the_caret_and_a_press_elsewhere_closes_it() {
        let mut cx = UiCx::new();
        let s = state(None, None, 50);
        let mut f = footer(&s, 224.0);
        f.begin_timecode_edit(&s);
        let text = f.timecode_edit().map(|e| e.string()).unwrap_or_default();
        let carets = MonitorFooter::timecode_carets(&text, |s| (s.chars().count() * 7) as f64);
        let pick = |x: f64| MonitorFooter::caret_index(x, &carets);
        f.mouse_down(pt(f.timecode_rect().min_x() + 15.0, f.timecode_rect().mid_y()), &s, false, Some(&pick));
        assert!(f.timecode_edit().is_some_and(|e| e.caret() == 2 && !e.has_selection()));
        let mut c = Canvas::with_size(300.0, 100.0, None, 1.0);
        f.draw(&mut c, &s, &DrawTheme::default(), &mut cx);
        let yy = y(&f);
        f.mouse_down(pt(f.scrub_rect().mid_x(), yy), &s, false, None);
        assert!(!f.is_editing_timecode());
    }

    #[test]
    fn source_footer_right_group_never_overlaps_transport() {
        let mut s = state(None, None, 0);
        s.mode = MonitorMode::Source;
        let transport = [
            MonitorAction::PlayPause,
            MonitorAction::StepBack,
            MonitorAction::StepForward,
            MonitorAction::MarkIn,
            MonitorAction::MarkOut,
            MonitorAction::GoToIn,
            MonitorAction::GoToOut,
        ];
        let mut width = 330.0;
        while width <= 700.0 {
            let f = footer(&s, width);
            let end = f.buttons().iter().filter(|b| transport.contains(&b.0)).map(|b| b.1.max_x()).fold(0.0, f64::max);
            if f.duration_rect() != CGRect::default() {
                assert!(f.duration_rect().min_x() >= end, "duration overlaps transport at {width}");
            }
            width += 10.0;
        }
    }

    #[test]
    fn scrub_math_snaps_to_frames_and_clamps() {
        let m = MonitorScrubMath::new(fd() * 100, fd(), 224.0);
        assert_eq!(m.time_at_x(0.0), Time::ZERO);
        assert_eq!(m.time_at_x(1000.0), fd() * 99);
        assert_eq!(m.time_at_x(112.0), fd() * 50);
        assert_eq!(m.x_for(fd() * 50), 112.0);
        assert_eq!(m.hit(113.0, Some(fd() * 50), None, 6.0), ScrubHit::MarkIn);
        assert_eq!(m.hit(150.0, Some(fd() * 50), None, 6.0), ScrubHit::Playhead);
    }
    #[test]
    fn transport_buttons_are_quiet_stone_buttons() {
        use sq_uikit::redesign_tokens::color as tk;
        crate::motion::set_reduce_motion(true);
        let s = state(None, None, 10);
        let mut f = footer(&s, 224.0);
        let t = DrawTheme::default();
        let (a, r) = f.buttons[0];
        f.hovered = Some(a);
        let mut c = Canvas::with_size(224.0, MonitorFooter::HEIGHT as f32, None, 1.0);
        f.draw(&mut c, &s, &t, &mut UiCx::new());
        let hover = t.token(tk::HOVER);
        let hit = c
            .list
            .quads()
            .iter()
            .any(|q| (q.rect.x, q.rect.w) == (r.x as f32, r.width as f32) && q.radius == 4.0 && q.color == hover);
        assert!(hit, "the hovered button paints the stone quiet hover fill");
        crate::motion::set_reduce_motion(false);
    }
}

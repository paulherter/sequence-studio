// Swift: ShellImportReportContent.swift
//! The rows of the import report card (the Mac `ImportReportSheet` body): an inset well of 38 pt rows, each a status dot,
//! a strong name over a label3 detail line and, in checklist mode, a Show / Reconnect… button on the rows that can act.

use crate::shell_dialog::{PopupRequest, ShellDialogContent};
use sq_core_model::MarkerColor;
use sq_draw::scroll::ScrollBody;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::{Canvas, Color, DrawTheme, InputEvent, TextAlign, TextMeasure};
use sq_premiere_import::primport_checklist::{Item, Kind, PRImportChecklist};
use sq_premiere_import::primport_report::{PRImportReport, Status};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::SQDialogResponse;
use std::cell::RefCell;
use std::rc::Rc;
use std::time::Instant;

mod m {
    pub(super) const SIDE_PAD: f64 = 20.0;
    /// art.html 34: 40 per item, the list inset 8.
    pub(super) const ROW_HEIGHT: f64 = 40.0;
    pub(super) const WELL_PAD: f64 = 8.0;
    /// `Theme.Dialog.reportWellRadius`.
    pub(super) const WELL_RADIUS: f64 = 6.0;
    pub(super) const MIN_HEIGHT: f64 = 46.0;
    pub(super) const MAX_HEIGHT: f64 = 300.0;
    pub(super) const DOT: f64 = 8.0;
    pub(super) const DOT_X: f64 = 12.0;
    pub(super) const TEXT_X: f64 = 30.0;
    pub(super) const TRAILING: f64 = 12.0;
    pub(super) const BUTTON_HEIGHT: f64 = 24.0;
    pub(super) const BUTTON_PADDING: f64 = 10.0;
    pub(super) const BODY_SIZE: f64 = 11.0;
    pub(super) const BUTTON_SIZE: f64 = 12.0;
}

/// A row's status color.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReportTone {
    /// Came over.
    Green,
    /// Approximated (checklist mode: orange).
    Yellow,
    /// Approximated.
    Orange,
    /// Left out or missing.
    Red,
}

/// One row: status color, headline, detail and (checklist mode) the item behind it with its button title.
#[derive(Clone, Debug, PartialEq)]
pub struct ReportRow {
    /// Status color.
    pub tone: ReportTone,
    /// Headline.
    pub head: String,
    /// Detail line.
    pub detail: String,
    /// The checklist item behind the row.
    pub item: Option<Item>,
    /// The button title.
    pub action: Option<String>,
}

/// The import report card body (Swift `ShellImportReportContent`).
pub struct ShellImportReportContent {
    rows: Vec<ReportRow>,
    /// A row's button was pressed: the item to act on (the host closes the dialog and acts).
    pub pressed_item: Option<Item>,
    /// Where a pressed row's item goes for the flow that shows the card (Swift `onAction`); the card then closes with
    /// the first button.
    pub sink: Option<Rc<RefCell<Option<Item>>>>,
    close: bool,
    well: CGRect,
    scroll_body: ScrollBody,
    born: Instant,
    hovered: Option<usize>,
    pressed: Option<usize>,
    /// Text widths of the last layout (the button frames).
    button_widths: Vec<f64>,
}

impl ShellImportReportContent {
    /// Checklist mode: a row per checklist item, "Show" where clips can be visited, "Reconnect…" for missing files.
    pub fn rows_for_checklist(checklist: &PRImportChecklist, can_reconnect: bool) -> Vec<ReportRow> {
        checklist
            .items()
            .iter()
            .map(|i| {
                let tone = match i.kind {
                    Kind::CameOver => ReportTone::Green,
                    Kind::Approximated => ReportTone::Orange, // art.html 34: orange for approximated, red for left out
                    Kind::LeftOut | Kind::MissingFiles => ReportTone::Red,
                };
                let head = if matches!(i.kind, Kind::Approximated | Kind::LeftOut) {
                    format!("{}\u{00D7} {}", i.count, i.title)
                } else {
                    i.title.clone()
                };
                let action = match i.kind {
                    Kind::CameOver => None,
                    Kind::MissingFiles => can_reconnect.then(|| "Reconnect…".to_string()),
                    Kind::Approximated | Kind::LeftOut => (!i.locations.is_empty()).then(|| "Show".to_string()),
                };
                ReportRow { tone, head, detail: i.detail.clone(), item: Some(i.clone()), action }
            })
            .collect()
    }

    /// Report mode (no checklist): worst first, dropped red, approximated orange, mapped green.
    pub fn rows_for_report(report: &PRImportReport) -> Vec<ReportRow> {
        let mut entries: Vec<_> = report.entries().iter().collect();
        // Swift: `sorted { ($0.status, $1.count, $0.feature) > ($1.status, $0.count, $1.feature) }`: status worst first,
        // then the count ascending and the feature descending (kept as written).
        entries.sort_by(|a, b| {
            (b.status.raw_value(), a.count, &b.feature).cmp(&(a.status.raw_value(), b.count, &a.feature))
        });
        entries
            .into_iter()
            .map(|e| {
                let tone = match e.status {
                    Status::Dropped => ReportTone::Red,
                    Status::Approximated => ReportTone::Orange,
                    Status::Mapped => ReportTone::Green,
                };
                let label = e.status.label();
                let mut chars = label.chars();
                let status: String = chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default();
                ReportRow {
                    tone,
                    head: format!("{}\u{00D7} {}", e.count, e.feature),
                    detail: if e.note.is_empty() { status } else { format!("{status}: {}", e.note) },
                    item: None,
                    action: None,
                }
            })
            .collect()
    }

    /// A card body over `rows`.
    pub fn new(rows: Vec<ReportRow>) -> ShellImportReportContent {
        ShellImportReportContent {
            rows,
            pressed_item: None,
            sink: None,
            close: false,
            well: CGRect::default(),
            scroll_body: ScrollBody::new(0.0),
            born: Instant::now(),
            hovered: None,
            pressed: None,
            button_widths: Vec::new(),
        }
    }

    /// The rows.
    pub fn rows(&self) -> &[ReportRow] {
        &self.rows
    }

    fn list_height(&self) -> f64 {
        self.rows.len() as f64 * m::ROW_HEIGHT + 2.0 * m::WELL_PAD
    }

    fn well_height(&self) -> f64 {
        self.list_height().clamp(m::MIN_HEIGHT, m::MAX_HEIGHT)
    }

    fn row_frame(&mut self, i: usize) -> CGRect {
        let scroll = self.scroll_body.position();
        CGRect::new(
            self.well.min_x(),
            self.well.min_y() + m::WELL_PAD + i as f64 * m::ROW_HEIGHT - scroll,
            self.well.width,
            m::ROW_HEIGHT,
        )
    }

    fn button_frame(&mut self, i: usize) -> Option<CGRect> {
        self.rows[i].action.as_ref()?;
        let w = self.button_widths.get(i).copied().unwrap_or(0.0);
        let r = self.row_frame(i);
        Some(CGRect::new(r.max_x() - 12.0 - w, r.mid_y() - m::BUTTON_HEIGHT / 2.0, w, m::BUTTON_HEIGHT))
    }

    fn button_at(&mut self, p: CGPoint) -> Option<usize> {
        if !self.well.contains(p) {
            return None;
        }
        (0..self.rows.len()).find(|i| self.button_frame(*i).is_some_and(|b| b.contains(p)))
    }

    fn color(t: ReportTone, th: &DrawTheme) -> Color {
        match t {
            ReportTone::Green => DrawTheme::marker(MarkerColor::Green),
            ReportTone::Yellow => DrawTheme::marker(MarkerColor::Yellow),
            ReportTone::Orange => DrawTheme::marker(MarkerColor::Orange),
            ReportTone::Red => {
                let r = th.palette.red;
                Color::new((r.r / 255.0) as f32, (r.g / 255.0) as f32, (r.b / 255.0) as f32, r.a as f32)
            }
        }
    }
}

impl ShellDialogContent for ShellImportReportContent {
    fn height(&mut self, _width: f64) -> f64 {
        self.well_height()
    }

    fn layout(&mut self, frame: CGRect, measure: &TextMeasure) {
        self.well =
            CGRect::new(frame.min_x() + m::SIDE_PAD, frame.min_y(), frame.width - 2.0 * m::SIDE_PAD, frame.height);
        self.button_widths = self
            .rows
            .iter()
            .map(|r| {
                r.action.as_ref().map_or(0.0, |t| {
                    measure.width(&SQL10n::string(t), m::BUTTON_SIZE, measure.medium()).ceil() + 2.0 * m::BUTTON_PADDING
                })
            })
            .collect();
        let max = (self.list_height() - self.well.height).max(0.0);
        let clamped = self.scroll_body.position().max(0.0).min(max);
        self.scroll_body.assign(clamped);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme) {
        let measure = TextMeasure::new(c.atlas(), c.scale);
        c.fill_rounded(self.well, m::WELL_RADIUS, t.content());
        c.save_gstate();
        c.clip_to(self.well);
        for i in 0..self.rows.len() {
            let f = self.row_frame(i);
            if f.max_y() <= self.well.min_y() || f.min_y() >= self.well.max_y() {
                continue;
            }
            let r = self.rows[i].clone();
            c.fill_ellipse(
                CGRect::new(f.min_x() + m::DOT_X, f.mid_y() - m::DOT / 2.0, m::DOT, m::DOT),
                Self::color(r.tone, t),
            );
            let b = self.button_frame(i);
            let right = b.map_or(f.max_x(), |b| b.min_x()) - m::TRAILING;
            let x = f.min_x() + m::TEXT_X;
            let w = (right - x).max(0.0);
            let line = measure.line_height(m::BODY_SIZE) + 2.0;
            let top = f.mid_y() - line;
            c.draw_text_in(
                &r.head,
                CGRect::new(x, top, w, line),
                m::BODY_SIZE,
                t.label(),
                TextAlign::Left,
                0.0,
                c.semibold(),
            );
            c.draw_text_in(
                &SQL10n::string(&r.detail),
                CGRect::new(x, top + line, w, line),
                m::BODY_SIZE,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
            if let (Some(b), Some(title)) = (b, &r.action) {
                // art.html 34: Show is a plain label3 text on the row (a fill only while hovered or pressed).
                let down = self.pressed == Some(i);
                let over = self.hovered == Some(i);
                c.stone_button(b, ButtonKind::Quiet, Touch { hovering: over, pressed: down, ..Touch::default() }, t);
                c.draw_text_in(
                    &SQL10n::string(title),
                    b,
                    m::BODY_SIZE,
                    if over || down { t.label() } else { t.label3() },
                    TextAlign::Center,
                    0.0,
                    0,
                );
            }
        }
        c.restore_gstate();
    }

    fn handle(&mut self, e: &InputEvent, scale: f32) -> bool {
        let k = f64::from(scale);
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x) / k, f64::from(y) / k);
        match *e {
            InputEvent::MouseMoved { x, y } => {
                self.hovered = self.button_at(pt(x, y));
                false
            }
            InputEvent::MouseDown { x, y, .. } => {
                self.pressed = self.button_at(pt(x, y));
                self.pressed.is_some()
            }
            InputEvent::MouseDragged { x, y, .. } => {
                self.hovered = self.button_at(pt(x, y));
                self.pressed.is_some()
            }
            InputEvent::MouseUp { x, y } => {
                let Some(p) = self.pressed.take() else { return false };
                if self.button_at(pt(x, y)) == Some(p)
                    && let Some(item) = self.rows[p].item.clone()
                {
                    if let Some(sink) = &self.sink {
                        *sink.borrow_mut() = Some(item.clone());
                        self.close = true;
                    }
                    self.pressed_item = Some(item);
                }
                true
            }
            InputEvent::Scroll { x, y, dy, .. } => {
                if !self.well.contains(pt(x, y)) || self.list_height() <= self.well.height {
                    return false;
                }
                let now = self.born.elapsed().as_secs_f64();
                self.scroll_body.wheel(None, 0.0, dy, k, self.list_height() - self.well.height, self.well.height, now);
                true
            }
            _ => false,
        }
    }

    fn take_popup(&mut self) -> Option<PopupRequest> {
        None
    }

    fn take_close(&mut self) -> Option<SQDialogResponse> {
        std::mem::take(&mut self.close).then_some(SQDialogResponse(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_premiere_import::primport_report::Location;

    fn item(kind: Kind, with_location: bool) -> Item {
        Item {
            id: "x".into(),
            kind,
            title: "Title".into(),
            detail: "Detail".into(),
            count: 3,
            locations: if with_location {
                vec![Location { timeline: sq_core_time::Id::from_u128(1), clip: sq_core_time::Id::from_u128(2) }]
            } else {
                Vec::new()
            },
        }
    }

    #[test]
    fn the_height_is_clamped_between_the_minimum_and_the_maximum() {
        let row = ReportRow { tone: ReportTone::Green, head: "a".into(), detail: "b".into(), item: None, action: None };
        assert_eq!(ShellImportReportContent::new(vec![]).well_height(), m::MIN_HEIGHT);
        assert_eq!(ShellImportReportContent::new(vec![row.clone(); 3]).well_height(), 3.0 * 40.0 + 16.0);
        assert_eq!(ShellImportReportContent::new(vec![row; 20]).well_height(), m::MAX_HEIGHT);
    }

    #[test]
    fn a_button_press_on_a_row_hands_its_item_over() {
        let mut c = ShellImportReportContent::new(vec![ReportRow {
            tone: ReportTone::Orange,
            head: "3× Title".into(),
            detail: "Detail".into(),
            item: Some(item(Kind::Approximated, true)),
            action: Some("Show".into()),
        }]);
        c.layout(CGRect::new(0.0, 0.0, 400.0, 62.0), &TextMeasure::new(None, 1.0));
        let b = c.button_frame(0).expect("button");
        let (x, y) = (b.mid_x() as f32, b.mid_y() as f32);
        assert!(c.handle(&InputEvent::MouseDown { x, y, modifiers: sq_draw::InputModifiers::NONE }, 1.0));
        assert!(c.handle(&InputEvent::MouseUp { x, y }, 1.0));
        assert_eq!(c.pressed_item.map(|i| i.id), Some("x".to_string()));
    }

    #[test]
    fn the_report_rows_list_the_worst_first() {
        let mut r = PRImportReport::default();
        r.note("Mapped thing", Status::Mapped, "");
        r.note("Dropped thing", Status::Dropped, "gone");
        r.note("Approximate thing", Status::Approximated, "close");
        let rows = ShellImportReportContent::rows_for_report(&r);
        let tones: Vec<ReportTone> = rows.iter().map(|r| r.tone).collect();
        assert_eq!(tones, [ReportTone::Red, ReportTone::Orange, ReportTone::Green]);
        assert_eq!(rows[0].detail, "Dropped: gone");
        assert_eq!(rows[2].detail, "Mapped");
    }
}

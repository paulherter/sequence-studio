// Swift: LoudnessMeter.swift
//! The loudness meter (Mac SQMonitorUI `LoudnessMeterView`) on the portable canvas: reading, scale, target and peak hold
//! moved here as they were; the meter state and its rows / columns drawing translated line by line.

use super::loudness_range::LoudnessRangeTracker;
use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::theme::{self, DrawTheme};
use sq_core_model::DeliveryTarget;
use sq_uikit::controls_grid::{CGPoint, CGRect};

/// One snapshot of the R128 meter (values from the engine; `None` LUFS = not enough signal yet).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LoudnessReading {
    /// Momentary loudness.
    pub momentary_lufs: Option<f64>,
    /// Short-term loudness.
    pub short_term_lufs: Option<f64>,
    /// Integrated loudness.
    pub integrated_lufs: Option<f64>,
    /// True peak in dBTP.
    pub true_peak_db: f64,
}

impl Default for LoudnessReading {
    fn default() -> Self {
        LoudnessReading {
            momentary_lufs: None,
            short_term_lufs: None,
            integrated_lufs: None,
            true_peak_db: f64::NEG_INFINITY,
        }
    }
}

impl LoudnessReading {
    /// Above 0 dBTP.
    pub fn true_peak_over(&self) -> bool {
        self.true_peak_db > 0.0
    }
    /// Nothing measured.
    pub const SILENT: LoudnessReading = LoudnessReading {
        momentary_lufs: None,
        short_term_lufs: None,
        integrated_lufs: None,
        true_peak_db: f64::NEG_INFINITY,
    };
}

/// The LUFS scale of the bars.
pub enum LoudnessScale {}

impl LoudnessScale {
    /// Bottom of the scale.
    pub const MIN_LUFS: f64 = -40.0;
    /// Top of the scale.
    pub const MAX_LUFS: f64 = 0.0;
    /// The default target.
    pub const TARGET_LUFS: f64 = -14.0;

    /// 0...1 position on the -40...0 LUFS scale.
    pub fn fraction(lufs: Option<f64>) -> f64 {
        let Some(l) = lufs.filter(|l| l.is_finite()) else { return 0.0 };
        ((l - Self::MIN_LUFS) / (Self::MAX_LUFS - Self::MIN_LUFS)).clamp(0.0, 1.0)
    }

    /// One decimal, "-inf" without a signal.
    pub fn text(lufs: Option<f64>) -> String {
        match lufs.filter(|l| l.is_finite() && *l > -100.0) {
            Some(l) => format!("{l:.1}"),
            None => "-inf".to_string(),
        }
    }
}

/// What the meter measures against: the sequence's delivery target (LUFS integrated, dBTP ceiling), -14 / -1 without one.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LoudnessTarget {
    /// Integrated target.
    pub lufs: f64,
    /// True-peak ceiling.
    pub true_peak_db: f64,
}

impl Default for LoudnessTarget {
    fn default() -> Self {
        LoudnessTarget { lufs: LoudnessScale::TARGET_LUFS, true_peak_db: -1.0 }
    }
}

impl LoudnessTarget {
    /// The target of a delivery preset, the default without one.
    pub fn from_delivery(delivery: Option<&DeliveryTarget>) -> LoudnessTarget {
        delivery.map(|d| LoudnessTarget { lufs: d.target_lufs, true_peak_db: d.true_peak_db }).unwrap_or_default()
    }

    /// "Target -14 LUFS / -1 dBTP".
    pub fn label(&self) -> String {
        format!("Target {} LUFS / {} dBTP", Self::number(self.lufs), Self::number(self.true_peak_db))
    }

    /// More than 1 LU above the target (the bar turns yellow).
    pub fn is_over_target(&self, value: Option<f64>) -> bool {
        value.unwrap_or(-100.0) > self.lufs + 1.0
    }
    /// True peak above the ceiling (the bar turns red).
    pub fn is_over_ceiling(&self, true_peak_db: f64) -> bool {
        true_peak_db.is_finite() && true_peak_db > self.true_peak_db
    }

    fn number(v: f64) -> String {
        if v == v.round() { format!("{v:.0}") } else { format!("{v:.1}") }
    }
}

/// Peak indicator that holds the maximum for `hold_seconds`, then falls at `fall_db_per_second`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PeakHold {
    /// Seconds the peak stays.
    pub hold_seconds: f64,
    /// dB per second after the hold.
    pub fall_db_per_second: f64,
    value_db: f64,
    held_for: f64,
}

impl Default for PeakHold {
    fn default() -> Self {
        PeakHold::new(2.0, 20.0)
    }
}

impl PeakHold {
    /// A hold with these settings.
    pub fn new(hold_seconds: f64, fall_db_per_second: f64) -> PeakHold {
        PeakHold { hold_seconds, fall_db_per_second, value_db: f64::NEG_INFINITY, held_for: 0.0 }
    }

    /// The held peak.
    pub fn value_db(&self) -> f64 {
        self.value_db
    }

    /// A new peak after `dt` seconds.
    pub fn update(&mut self, peak_db: f64, dt: f64) {
        if peak_db >= self.value_db {
            self.value_db = peak_db;
            self.held_for = 0.0;
            return;
        }
        self.held_for += dt;
        let fall_time = dt.min((self.held_for - self.hold_seconds).max(0.0));
        self.value_db = peak_db.max(self.value_db - fall_time * self.fall_db_per_second);
    }

    /// Drops the held peak.
    pub fn reset(&mut self) {
        self.value_db = f64::NEG_INFINITY;
        self.held_for = 0.0;
    }
}

/// How the meter lays out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    /// Horizontal M / S / I / TP bars with numbers (wide panels).
    Rows,
    /// Four thin vertical bars on the LUFS scale with the target line across M / S / I and the integrated value on top (the narrow Audio Meters strip).
    Columns,
}

/// Momentary / short-term / integrated bars with numbers, true-peak with hold, target line and label at the sequence's
/// delivery target (`target`, -14 LUFS / -1 dBTP by default). True peak turns red above the target's ceiling.
#[derive(Clone, Debug, PartialEq)]
pub struct LoudnessMeter {
    reading: LoudnessReading,
    range: LoudnessRangeTracker,
    /// The delivery target.
    pub target: LoudnessTarget,
    peak_hold: PeakHold,
    last_peak_update: Option<f64>,
    /// Rows or columns.
    pub style: Style,
}

impl LoudnessMeter {
    /// Width of the narrow layout.
    pub const COLUMNS_WIDTH: f64 = 40.0;
    const FONT_SIZE: f64 = 11.0; // Theme.Typography.body

    /// A meter in `style`.
    pub fn new(style: Style) -> LoudnessMeter {
        LoudnessMeter {
            reading: LoudnessReading::SILENT,
            range: LoudnessRangeTracker::new(),
            target: LoudnessTarget::default(),
            peak_hold: PeakHold::default(),
            last_peak_update: None,
            style,
        }
    }

    /// The last reading.
    pub fn reading(&self) -> &LoudnessReading {
        &self.reading
    }
    /// Loudness range over what was measured so far; grayed out and "--" under 60 s (Tech 3342).
    pub fn range(&self) -> &LoudnessRangeTracker {
        &self.range
    }
    /// The true-peak hold.
    pub fn peak_hold(&self) -> &PeakHold {
        &self.peak_hold
    }

    /// A new reading at `time` (seconds, monotonic): advances the range clock (only when the reading moved) and the hold.
    pub fn update(&mut self, r: LoudnessReading, time: f64) {
        let changed = r != self.reading;
        self.reading = r;
        let dt = self.last_peak_update.map(|l| time - l).unwrap_or(0.0);
        self.last_peak_update = Some(time);
        // Only a moving signal advances the range clock (a paused meter repeats the same reading).
        if changed {
            self.range.add(self.reading.short_term_lufs, dt.min(1.0));
        }
        self.peak_hold.update(self.reading.true_peak_db, dt);
    }

    /// Drops momentary and short-term (playback stopped) without touching the hold.
    pub fn clear_live(&mut self) {
        self.reading.momentary_lufs = None;
        self.reading.short_term_lufs = None;
    }

    /// Click: restart integrated and true-peak hold.
    pub fn reset_peak(&mut self) {
        self.peak_hold.reset();
        self.range.reset();
        self.last_peak_update = None;
    }

    fn field(t: &DrawTheme) -> Color {
        Color::new(0.0, 0.0, 0.0, if t.palette.is_dark() { 0.28 } else { 0.05 }) // Theme.Colors.field
    }
    fn green() -> Color {
        Color::hex(0x30D158, 1.0) // Theme.Colors.green
    }
    fn tp_fraction(db: f64) -> f64 {
        if db.is_finite() { ((db + 60.0) / 60.0).clamp(0.0, 1.0) } else { 0.0 }
    }

    fn text(c: &mut Canvas, s: &str, x: f64, y: f64, color: Color) {
        c.draw_text(s, CGPoint { x, y }, Self::FONT_SIZE, color, f64::INFINITY, 0);
    }

    /// Draws the meter in `b`.
    pub fn draw(&self, c: &mut Canvas, b: CGRect, t: &DrawTheme) {
        if self.style == Style::Columns {
            self.draw_columns(c, b, t);
            return;
        }
        let red = t.red();
        let rows: [(&str, Option<f64>); 3] = [
            ("M", self.reading.momentary_lufs),
            ("S", self.reading.short_term_lufs),
            ("I", self.reading.integrated_lufs),
        ];
        let (label_w, num_w, gap) = (14.0, 40.0, 8.0); // Theme.Spacing.sm
        let bar_x = b.min_x() + label_w + gap;
        let bar_w = (b.width - label_w - gap - num_w - gap).max(0.0);
        let (row_h, row_gap) = (14.0, 6.0); // Theme.Spacing.iconToLabel

        let bar = |c: &mut Canvas, y: f64, fill: f64, color: Color| {
            let track = CGRect::new(bar_x, y, bar_w, row_h);
            c.fill_rounded(track, theme::radius::SMALL as f64, Self::field(t)); // Theme.Radius.small
            let mut f = track;
            f.width = track.width * fill;
            c.fill_rounded(f, 4.0_f64.min(f.width / 2.0), color);
        };

        let mut y = b.min_y();
        for (name, value) in rows {
            Self::text(c, name, b.min_x(), y + 1.0, t.label2());
            bar(
                c,
                y,
                LoudnessScale::fraction(value),
                if self.target.is_over_target(value) { t.yellow() } else { t.accent() },
            );
            Self::text(c, &LoudnessScale::text(value), bar_x + bar_w + gap, y + 1.0, t.label());
            y += row_h + row_gap;
        }
        // True peak: bar over -60...0 dBTP mapped like a short scale, with hold tick.
        Self::text(c, "TP", b.min_x(), y + 1.0, t.label2());
        let tp_color = if self.target.is_over_ceiling(self.reading.true_peak_db) { red } else { Self::green() };
        bar(c, y, Self::tp_fraction(self.reading.true_peak_db), tp_color);
        let hold = self.peak_hold.value_db();
        if hold.is_finite() {
            let hx = bar_x + bar_w * Self::tp_fraction(hold);
            c.fill(CGRect::new(hx.min(bar_x + bar_w - 1.5), y, 1.5, row_h), t.label());
        }
        let tp = self.reading.true_peak_db;
        let tp_text = if tp.is_finite() && tp > -100.0 { format!("{tp:.1}") } else { "-inf".to_string() };
        Self::text(c, &tp_text, bar_x + bar_w + gap, y + 1.0, t.label());

        // Target line across the three LUFS rows.
        let tx = (bar_x + bar_w * LoudnessScale::fraction(Some(self.target.lufs))).round() + 0.5;
        c.fill(CGRect::new(tx - 0.5, b.min_y() - 2.0, 1.0, 3.0 * (row_h + row_gap) - row_gap + 4.0), t.yellow());
        // Target label under the true-peak row.
        Self::text(c, &self.target.label(), bar_x, y + row_h + row_gap, t.label3());
        // Loudness range: dim until a minute of signal was measured.
        let lra = self.range.text();
        let lw = c.size_of(&lra, Self::FONT_SIZE, 0).width;
        let lra_color = if self.range.is_reliable() { t.label2() } else { t.label3().with_alpha(t.label3().a * 0.5) };
        Self::text(c, &lra, b.max_x() - lw, y + row_h + row_gap, lra_color);
    }

    /// Narrow layout: integrated LUFS on top, then M S I TP columns (bottom = -40 LUFS / -60 dBTP), a target line across
    /// M S I, and the column letters at the bottom.
    pub(crate) fn draw_columns(&self, c: &mut Canvas, b: CGRect, t: &DrawTheme) {
        let (text_h, col_w, gap) = (14.0, 6.0, 3.0);
        let total = 4.0 * col_w + 3.0 * gap;
        let x0 = b.min_x() + ((b.width - total) / 2.0).round();
        let top = b.min_y() + text_h + 2.0;
        let bottom = b.max_y() - text_h - 2.0;
        let h = (bottom - top).max(0.0);
        let integ = LoudnessScale::text(self.reading.integrated_lufs);
        let iw = c.size_of(&integ, Self::FONT_SIZE, 0).width;
        Self::text(c, &integ, b.min_x() + ((b.width - iw) / 2.0).round(), b.min_y(), t.label());
        let red = t.red();
        let over = |v: Option<f64>| if self.target.is_over_target(v) { t.yellow() } else { t.accent() };
        let r = &self.reading;
        let cols: [(&str, f64, Color); 4] = [
            ("M", LoudnessScale::fraction(r.momentary_lufs), over(r.momentary_lufs)),
            ("S", LoudnessScale::fraction(r.short_term_lufs), over(r.short_term_lufs)),
            ("I", LoudnessScale::fraction(r.integrated_lufs), over(r.integrated_lufs)),
            (
                "T",
                Self::tp_fraction(r.true_peak_db),
                if self.target.is_over_ceiling(r.true_peak_db) { red } else { Self::green() },
            ),
        ];
        for (i, (name, fill, color)) in cols.iter().enumerate() {
            let x = x0 + i as f64 * (col_w + gap);
            c.fill(CGRect::new(x, top, col_w, h), Self::field(t));
            let fh = h * fill;
            c.fill(CGRect::new(x, top + h - fh, col_w, fh), *color);
            let nw = c.size_of(name, Self::FONT_SIZE, 0).width;
            Self::text(c, name, x + (col_w - nw) / 2.0, bottom + 2.0, t.label2());
        }
        let hold = self.peak_hold.value_db();
        if hold.is_finite() {
            c.fill(CGRect::new(x0 + 3.0 * (col_w + gap), top + h - h * Self::tp_fraction(hold), col_w, 1.5), t.label());
        }
        // Target line across M S I.
        let ty = (top + h - h * LoudnessScale::fraction(Some(self.target.lufs))).round() + 0.5;
        c.fill(CGRect::new(x0 - 2.0, ty - 0.5, 3.0 * col_w + 2.0 * gap + 4.0, 1.0), t.yellow());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hold_keeps_peak_and_reset_clears_it() {
        let mut m = LoudnessMeter::new(Style::Rows);
        m.update(LoudnessReading { short_term_lufs: Some(-14.0), true_peak_db: -3.0, ..Default::default() }, 0.0);
        m.update(LoudnessReading { short_term_lufs: Some(-15.0), true_peak_db: -20.0, ..Default::default() }, 0.5);
        assert_eq!(m.peak_hold().value_db(), -3.0);
        m.reset_peak();
        assert_eq!(m.peak_hold().value_db(), f64::NEG_INFINITY);
    }

    #[test]
    fn clear_live_keeps_integrated() {
        let mut m = LoudnessMeter::new(Style::Rows);
        let r = LoudnessReading {
            momentary_lufs: Some(-10.0),
            short_term_lufs: Some(-12.0),
            integrated_lufs: Some(-16.0),
            ..Default::default()
        };
        m.update(r, 0.0);
        m.clear_live();
        assert!(
            m.reading().momentary_lufs.is_none()
                && m.reading().short_term_lufs.is_none()
                && m.reading().integrated_lufs == Some(-16.0)
        );
    }

    #[test]
    fn over_target_bars_turn_yellow_in_both_styles() {
        let t = DrawTheme::default();
        for style in [Style::Rows, Style::Columns] {
            let mut m = LoudnessMeter::new(style);
            let r = LoudnessReading {
                momentary_lufs: Some(-6.0),
                short_term_lufs: Some(-20.0),
                integrated_lufs: Some(-20.0),
                true_peak_db: 0.5,
            };
            m.update(r, 0.0);
            let mut c = Canvas::with_size(300.0, 200.0, None, 1.0);
            let w = if style == Style::Rows { 300.0 } else { LoudnessMeter::COLUMNS_WIDTH };
            m.draw(&mut c, CGRect::new(0.0, 0.0, w, 200.0), &t);
            let has = |col: Color| c.list.quads().iter().any(|q| q.color == col);
            assert!(has(t.yellow()) && has(t.accent()) && has(t.red()), "{style:?}");
        }
    }

    #[test]
    fn the_target_label_drops_zero_decimals() {
        assert_eq!(LoudnessTarget::default().label(), "Target -14 LUFS / -1 dBTP");
        assert_eq!(LoudnessTarget { lufs: -16.5, true_peak_db: -1.0 }.label(), "Target -16.5 LUFS / -1 dBTP");
    }
}

// Swift: AudioMeter.swift
//! The audio meter (Mac SQMonitorUI `AudioMeterView`) on the portable canvas: the pure meter math moved here as it was,
//! the view state (channels, Mono, readout, clicks) and the drawing translated line by line.

use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::theme::DrawTheme;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect};

/// Pure meter math: dBFS mapping, color zones and ballistics (peak hold, fall, latched clip). No AppKit state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MeterZone {
    /// Up to -8 dBFS.
    Green,
    /// -8 to -3 dBFS.
    Yellow,
    /// Above -3 dBFS.
    Red,
}

/// Meter response preset (Settings > Audio, `sq.audio.meterBallistics`): how fast the bar falls and how long the peak holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MeterStyle {
    /// Slow.
    Smooth,
    /// Default.
    Standard,
    /// Quick.
    Fast,
}

/// Corner of a meter trough and its level (no radius token has this value).
const TROUGH_RADIUS: f64 = 2.0;

impl MeterStyle {
    /// Every preset, in declaration order.
    pub const ALL: [MeterStyle; 3] = [MeterStyle::Smooth, MeterStyle::Standard, MeterStyle::Fast];
    /// The defaults key.
    pub const DEFAULTS_KEY: &'static str = "sq.audio.meterBallistics";

    /// The stored text.
    pub fn raw_value(self) -> &'static str {
        match self {
            MeterStyle::Smooth => "smooth",
            MeterStyle::Standard => "standard",
            MeterStyle::Fast => "fast",
        }
    }

    /// The preset of a stored text.
    pub fn from_raw(s: &str) -> Option<MeterStyle> {
        MeterStyle::ALL.into_iter().find(|m| m.raw_value() == s)
    }

    /// The stored preset, `Standard` when unset.
    pub fn current(defaults: &dyn UiDefaults) -> MeterStyle {
        defaults.string(Self::DEFAULTS_KEY).and_then(|s| MeterStyle::from_raw(&s)).unwrap_or(MeterStyle::Standard)
    }

    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            MeterStyle::Smooth => "Smooth",
            MeterStyle::Standard => "Standard",
            MeterStyle::Fast => "Fast",
        }
    }
    /// Seconds the peak marker stays before it falls.
    pub fn hold_seconds(self) -> f64 {
        match self {
            MeterStyle::Smooth => 3.0,
            MeterStyle::Standard => MeterBallistics::HOLD_SECONDS,
            MeterStyle::Fast => 0.5,
        }
    }
    /// dB per second the bar falls (the hold marker falls at the same rate once released).
    pub fn fall_db_per_second(self) -> f32 {
        match self {
            MeterStyle::Smooth => 12.0,
            MeterStyle::Standard => MeterBallistics::BAR_FALL_DB_PER_SECOND,
            MeterStyle::Fast => 60.0,
        }
    }
}

/// Ballistics of one bar.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MeterBallistics {
    level_db: f32,
    hold_db: f32,
    clipped: bool,
    hold_set_at: f64,
    last_time: Option<f64>,
    /// The response preset.
    pub style: MeterStyle,
}

impl MeterBallistics {
    /// Bottom of the scale.
    pub const FLOOR_DB: f32 = -60.0;
    /// Top of the scale.
    pub const CEILING_DB: f32 = 0.0;
    /// Board `.meter .bar i`: green up to 78 % of the bar, yellow to 92 %, red above. On the board scale that is -8 and -3 dBFS.
    pub const YELLOW_START_DB: f32 = -8.0;
    /// Red starts here.
    pub const RED_START_DB: f32 = -3.0;
    /// Standard peak hold.
    pub const HOLD_SECONDS: f64 = 1.5;
    /// Fall rate of the bar and of the hold marker after the hold expired, in dB per second.
    pub const BAR_FALL_DB_PER_SECOND: f32 = 24.0;
    /// Digital silence (below the floor) counts as "no sound": the bar drops at once, no slow fall.
    pub const SILENCE_LINEAR: f32 = 0.001;

    /// A bar at rest.
    pub fn new(style: MeterStyle) -> MeterBallistics {
        MeterBallistics {
            level_db: Self::FLOOR_DB,
            hold_db: Self::FLOOR_DB,
            clipped: false,
            hold_set_at: 0.0,
            last_time: None,
            style,
        }
    }

    /// Current bar level in dBFS (rises instantly, falls at `BAR_FALL_DB_PER_SECOND`).
    pub fn level_db(&self) -> f32 {
        self.level_db
    }
    /// Peak-hold marker in dBFS.
    pub fn hold_db(&self) -> f32 {
        self.hold_db
    }
    /// Latched until `reset_clip()`.
    pub fn clipped(&self) -> bool {
        self.clipped
    }

    /// dBFS of a linear peak.
    pub fn db_from_linear(v: f32) -> f32 {
        if !(v > 0.0 && v.is_finite()) {
            return if v.is_nan() {
                Self::FLOOR_DB
            } else if v > 0.0 {
                Self::CEILING_DB
            } else {
                Self::FLOOR_DB
            };
        }
        Self::FLOOR_DB.max(20.0 * v.log10())
    }

    /// 0...1 position along the scale (floor to 0 dBFS), clamped.
    pub fn position(db: f32) -> f32 {
        if db.is_nan() || db <= Self::FLOOR_DB {
            return 0.0;
        }
        if db >= Self::CEILING_DB {
            return 1.0;
        }
        // Kit (APP-AENDERUNGEN H12): linear, a label every 6 dB from 0 down to -60.
        (db - Self::FLOOR_DB) / (Self::CEILING_DB - Self::FLOOR_DB)
    }

    /// The color zone of a level.
    pub fn zone(db: f32) -> MeterZone {
        if db > Self::RED_START_DB {
            MeterZone::Red
        } else if db >= Self::YELLOW_START_DB {
            MeterZone::Yellow
        } else {
            MeterZone::Green
        }
    }

    /// Feeds a new linear peak (0...1+, 1.0 = 0 dBFS) at `time` (seconds, monotonic). Pass 0 to only advance time.
    pub fn update(&mut self, peak: f32, time: f64, is_signal: bool) {
        if is_signal && peak < Self::SILENCE_LINEAR {
            self.silence();
            self.last_time = Some(time);
            return;
        }
        let dt = self.last_time.map(|l| (time - l).max(0.0)).unwrap_or(0.0);
        self.last_time = Some(time);
        let db = Self::db_from_linear(peak);
        // Bar: instant attack, linear-in-dB release.
        self.level_db = db.max(self.level_db - self.style.fall_db_per_second() * dt as f32);
        self.level_db = Self::FLOOR_DB.max(self.level_db);
        // Hold: new maximum restarts the 1.5 s hold, then falls.
        if db >= self.hold_db {
            self.hold_db = db;
            self.hold_set_at = time;
        } else if time - self.hold_set_at > self.style.hold_seconds() {
            let fallen = dt.min(time - self.hold_set_at - self.style.hold_seconds());
            self.hold_db = self.level_db.max(self.hold_db - self.style.fall_db_per_second() * fallen as f32);
        }
        if peak >= 1.0 {
            self.clipped = true;
        }
    }

    /// Level and hold to the floor at once (playback stopped or silent). The clip latch stays.
    pub fn silence(&mut self) {
        self.level_db = Self::FLOOR_DB;
        self.hold_db = Self::FLOOR_DB;
    }

    /// Clears the clip latch.
    pub fn reset_clip(&mut self) {
        self.clipped = false;
    }

    /// True when nothing is moving any more (timer can stop).
    pub fn is_settled(&self) -> bool {
        self.level_db <= Self::FLOOR_DB && self.hold_db <= Self::FLOOR_DB
    }
}

/// An engine meter reading: the engine it came from, its buffer counter and the linear peaks per channel.
#[derive(Clone, Debug, PartialEq)]
pub struct MeterReading {
    /// Identifies the engine (Swift `ObjectIdentifier`).
    pub source: usize,
    /// The buffer counter.
    pub sequence: i64,
    /// Linear peaks per channel.
    pub peaks: Vec<f32>,
}

/// Decides which engine meter readings reach the bars: a reading is fed once (by its buffer counter), so a stopped
/// engine lets the bars fall instead of holding the last peak.
#[derive(Clone, Copy, Debug, Default)]
pub struct MeterFeed {
    last: Option<(usize, i64)>,
}

impl MeterFeed {
    /// A feed that has seen nothing.
    pub fn new() -> MeterFeed {
        MeterFeed::default()
    }

    /// `source` identifies the engine the reading came from: a new engine restarts its buffer counter, so the same
    /// sequence number from another source is a new buffer.
    pub fn peaks(&mut self, reading: Option<&MeterReading>) -> Option<Vec<f32>> {
        let reading = reading?;
        if self.last == Some((reading.source, reading.sequence)) {
            return None;
        }
        self.last = Some((reading.source, reading.sequence));
        Some(reading.peaks.clone())
    }
}

/// What the label under a bar shows (the Mac view's `labelColor(bar:)`): accent = soloed, red = muted, dim red =
/// silenced by another channel's solo.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MeterChannelLabel {
    /// Plain.
    Normal,
    /// Soloed.
    Soloed,
    /// Muted.
    Muted,
    /// Silenced by another channel's solo.
    Silenced,
}

/// Where a click on the meter lands (the Mac view's `mouseDown`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioMeterHit {
    /// The readout on top: clears the clip latch.
    ResetClip,
    /// A channel label: Solo (Option / Alt: Mute) that bar.
    Channel(usize),
    /// The bars: swallowed (inside the Source waveform a click on the bars must not scrub).
    None,
}

/// Stereo (or n-channel) peak meter state: feed it `update` from the engine tap (linear peaks per channel),
/// advance it with `tick` while not settled, draw it with `draw`.
#[derive(Clone, Debug, PartialEq)]
pub struct AudioMeter {
    channels: Vec<MeterBallistics>,
    style: MeterStyle,
    is_mono: bool,
}

impl AudioMeter {
    /// Design v9 `.tlmeter`: 54 wide; the peak readout on top, two 6 pt bars 4 pt apart, the scale right of them, "L R" below.
    pub const WIDTH: f64 = 54.0;
    const BAR_WIDTH: f64 = 6.0;
    const GAP: f64 = 4.0;
    const BARS_X: f64 = 8.0;
    const SCALE_RIGHT: f64 = 46.0;
    const TOP_INSET: f64 = 22.0;
    const BOTTOM_INSET: f64 = 22.0;
    const EDGE_INSET: f64 = 8.0;
    /// A label every 6 dB down to the floor; the ones that would touch the previous label are skipped when the meter is short.
    const SCALE_TICKS: [f32; 11] = [0.0, -6.0, -12.0, -18.0, -24.0, -30.0, -36.0, -42.0, -48.0, -54.0, -60.0];
    /// Theme.Typography 9.5 regular.
    const FONT_SIZE: f64 = 9.5;

    /// A stereo meter.
    pub fn new(style: MeterStyle) -> AudioMeter {
        AudioMeter { channels: vec![MeterBallistics::new(style), MeterBallistics::new(style)], style, is_mono: false }
    }

    /// The bars.
    pub fn channels(&self) -> &[MeterBallistics] {
        &self.channels
    }
    /// The response preset.
    pub fn style(&self) -> MeterStyle {
        self.style
    }
    /// Sets the preset on every bar.
    pub fn set_style(&mut self, style: MeterStyle) {
        self.style = style;
        for c in &mut self.channels {
            c.style = style;
        }
    }
    /// Mono sequence (Sequence Settings > Channels): one bar, labeled "M", for the single folded channel.
    pub fn is_mono(&self) -> bool {
        self.is_mono
    }
    /// Switches Mono; a change restarts the bars.
    pub fn set_mono(&mut self, mono: bool) {
        if mono == self.is_mono {
            return;
        }
        self.is_mono = mono;
        self.channels = vec![MeterBallistics::new(self.style); if mono { 1 } else { 2 }];
    }

    /// Bar labels under the bars.
    pub fn channel_names(&self) -> Vec<&'static str> {
        const NUMBERED: [&str; 8] = ["1", "2", "3", "4", "5", "6", "7", "8"];
        match self.channels.len() {
            _ if self.is_mono => vec!["M"],
            // More than a pair is a surround source: numbered bars, never a forced L / R.
            n @ 3..=8 => NUMBERED[..n].to_vec(),
            _ => vec!["L", "R"],
        }
    }

    /// Bar width and gap: the stereo pair as designed; a surround source packs its bars into the same strip.
    fn bar_metrics(&self) -> (f64, f64) {
        if !self.is_mono && self.channels.len() > 2 { (4.0, 1.0) } else { (Self::BAR_WIDTH, Self::GAP) }
    }

    /// Output channels a bar stands for (of `channel_count`): the Mono bar is both.
    pub fn channels_for_bar(&self, i: i64, channel_count: i64) -> Vec<usize> {
        if self.is_mono { vec![0, 1] } else { vec![i.max(0).min(channel_count - 1) as usize] }
    }

    /// One bar (Mono) sits where the pair's middle is.
    fn bar_x(&self, i: usize) -> f64 {
        let (w, g) = self.bar_metrics();
        Self::BARS_X + i as f64 * (w + g) + if self.is_mono { (w + g) / 2.0 } else { 0.0 }
    }

    /// Bar index whose label column is at `x`, `None` between the columns.
    pub fn bar_at_x(&self, x: f64) -> Option<usize> {
        (0..if self.is_mono { 1 } else { 2 }).find(|&i| {
            let bx = self.bar_x(i);
            x >= bx - self.bar_metrics().1 && x <= bx + self.bar_metrics().0 + self.bar_metrics().1
        })
    }

    /// A click at `p` in a meter `height` high.
    pub fn hit(&self, p: CGPoint, height: f64) -> AudioMeterHit {
        if p.y <= Self::TOP_INSET {
            return AudioMeterHit::ResetClip;
        }
        if p.y >= height - Self::BOTTOM_INSET
            && let Some(bar) = self.bar_at_x(p.x)
        {
            return AudioMeterHit::Channel(bar);
        }
        AudioMeterHit::None
    }

    /// Linear peaks per channel for the last audio block (1.0 = 0 dBFS) at `time`. A Mono sequence shows one bar: the
    /// loudest side.
    pub fn update(&mut self, input: &[f32], time: f64) {
        let folded;
        let peaks: &[f32] = if self.is_mono {
            folded = [input.iter().copied().reduce(f32::max).unwrap_or(0.0)];
            &folded
        } else {
            input
        };
        if peaks.len() != self.channels.len() {
            self.channels = vec![MeterBallistics::new(self.style); peaks.len().max(1)];
        }
        for (i, p) in peaks.iter().enumerate() {
            self.channels[i].update(*p, time, true);
        }
    }

    /// The 30 Hz tick between buffers: the bars fall. Returns whether the meter settled (the timer can stop).
    pub fn tick(&mut self, time: f64) -> bool {
        for c in &mut self.channels {
            c.update(0.0, time, false);
        }
        self.is_settled()
    }
    /// Whether every bar settled.
    pub fn is_settled(&self) -> bool {
        self.channels.iter().all(|c| c.is_settled())
    }

    /// Clears every clip latch.
    pub fn reset_clip(&mut self) {
        for c in &mut self.channels {
            c.reset_clip();
        }
    }
    /// Level and hold to zero at once (no new audio arrives: stopped or paused). Clip latch stays.
    pub fn silence(&mut self) {
        for c in &mut self.channels {
            c.silence();
        }
    }
    /// Clears level and hold (e.g. on stop). Clip latch stays until clicked.
    pub fn reset(&mut self) {
        let style = self.style;
        self.channels = self
            .channels
            .iter()
            .map(|c| {
                let mut b = MeterBallistics::new(style);
                if c.clipped {
                    b.update(1.0, 0.0, false);
                    b.update(0.0, 100.0, false);
                }
                b
            })
            .collect();
    }

    /// The readout on top: the highest held peak in dB ("-12.3"), the head "dB" while silent.
    pub fn readout(&self) -> String {
        let peak = self.channels.iter().map(|c| c.hold_db).reduce(f32::max).unwrap_or(MeterBallistics::FLOOR_DB);
        if peak <= MeterBallistics::FLOOR_DB {
            return "dB".to_string();
        }
        let v = (peak as f64 * 10.0).round() / 10.0;
        if v < 0.0 { format!("\u{2212}{:.1}", -v) } else { format!("{v:.1}") }
    }

    fn zone_color(zone: MeterZone, t: &DrawTheme) -> Color {
        match zone {
            MeterZone::Green => t.token(sq_uikit::tokens::color::status::SUCCESS),
            MeterZone::Yellow => t.yellow(),
            MeterZone::Red => t.red(),
        }
    }

    fn label_color(l: MeterChannelLabel, t: &DrawTheme) -> Color {
        match l {
            MeterChannelLabel::Normal => t.label2(),
            MeterChannelLabel::Soloed => t.accent(),
            MeterChannelLabel::Muted => t.red(),
            MeterChannelLabel::Silenced => t.red().with_alpha(0.6),
        }
    }

    /// Draws the meter into `r` (48 wide by design). `labels` per bar (Solo / Mute state), `Normal` when absent.
    pub fn draw(&self, c: &mut Canvas, r: CGRect, t: &DrawTheme, labels: &[MeterChannelLabel]) {
        let meter_top = r.min_y() + Self::TOP_INSET;
        let h = r.height - Self::TOP_INSET - Self::BOTTOM_INSET;
        if h <= 0.0 {
            return;
        }
        let y = |db: f32| meter_top + h * (1.0 - MeterBallistics::position(db) as f64);
        let font = Self::FONT_SIZE;
        // Peak readout; red once a channel clipped (click it to clear).
        let clipped = self.channels.iter().any(|c| c.clipped);
        let readout = self.readout();
        let top_size = c.size_of(&readout, font, 0);
        c.draw_text(
            &readout,
            CGPoint {
                x: r.min_x() + ((r.width - top_size.width) / 2.0).round(),
                y: r.min_y() + Self::EDGE_INSET - 1.0,
            },
            font,
            if clipped { t.red() } else { t.label3() },
            f64::INFINITY,
            0,
        );
        // Scale labels (dB, no unit), right-aligned beside the bars.
        let mut last_py = f64::NEG_INFINITY;
        let floor_tick = MeterBallistics::FLOOR_DB;
        for tick in Self::SCALE_TICKS {
            let s = if tick == 0.0 { "0".to_string() } else { format!("\u{2212}{}", (-tick) as i64) };
            let size = c.size_of(&s, font, 0);
            let py = (y(tick) - size.height / 2.0).max(meter_top - 1.0).min(meter_top + h - size.height + 1.0);
            // The scale always ends on its floor (-60, as in the kit): the label before it gives way, not the floor.
            let floor_py =
                (y(floor_tick) - size.height / 2.0).max(meter_top - 1.0).min(meter_top + h - size.height + 1.0);
            let is_floor = tick == floor_tick;
            if (!is_floor && floor_py - py < size.height + 1.0) || (!is_floor && py - last_py < size.height + 1.0) {
                continue;
            }
            last_py = py;
            c.draw_text(
                &s,
                CGPoint { x: r.min_x() + Self::SCALE_RIGHT - size.width, y: py },
                font,
                t.label3(),
                f64::INFINITY,
                0,
            );
        }
        // "L R" under the bars.
        for (i, name) in self.channel_names().iter().enumerate() {
            let size = c.size_of(name, font, 0);
            let label = labels.get(i).copied().unwrap_or(MeterChannelLabel::Normal);
            c.draw_text(
                name,
                CGPoint { x: r.min_x() + self.bar_x(i) + (self.bar_metrics().0 - size.width) / 2.0, y: meter_top + h + 4.0 },
                font,
                Self::label_color(label, t),
                f64::INFINITY,
                0,
            );
        }
        // Bars.
        let segments = [
            (MeterBallistics::FLOOR_DB, MeterBallistics::YELLOW_START_DB, MeterZone::Green),
            (MeterBallistics::YELLOW_START_DB, MeterBallistics::RED_START_DB, MeterZone::Yellow),
            (MeterBallistics::RED_START_DB, MeterBallistics::CEILING_DB, MeterZone::Red),
        ];
        for (i, ch) in self.channels.iter().enumerate() {
            let x = r.min_x() + self.bar_x(i);
            let track = CGRect::new(x, meter_top, self.bar_metrics().0, h);
            c.save_gstate();
            c.clip_to(track);
            // r8 trough: `surface-control` (light: `surface-raised`) with a 1 px `border-row` edge.
            c.fill_rounded(track, TROUGH_RADIUS, if t.dark() { t.well() } else { t.raised() });
            let level_top = y(ch.level_db);
            for (lo, hi, zone) in segments {
                let top = y(hi).max(level_top);
                let bottom = y(lo);
                if bottom > top {
                    // The Mac clips the level to the 2 pt rounded track: a segment at the track's end takes its corners.
                    let seg = CGRect::new(x, top, self.bar_metrics().0, bottom - top);
                    let color = Self::zone_color(zone, t);
                    let at_top = top <= meter_top;
                    let at_bottom = bottom >= meter_top + h;
                    if at_top || at_bottom {
                        c.fill_rounded(seg, TROUGH_RADIUS, color);
                        // Square the corners on the side that is not the track's end.
                        let half = seg.height / 2.0;
                        let square = if at_top {
                            CGRect::new(x, top + half, seg.width, half)
                        } else {
                            CGRect::new(x, top, seg.width, half)
                        };
                        c.fill(square, color);
                    } else {
                        c.fill(seg, color);
                    }
                }
            }
            c.restore_gstate();
            c.stroke_rounded(track.inset_by(0.5, 0.5), TROUGH_RADIUS, 1.0, t.row_line());
            if ch.hold_db > MeterBallistics::FLOOR_DB {
                // r8 peak hold: 4 x 1 in `text-secondary`, drawn only while there is signal.
                let hy = y(ch.hold_db).max(meter_top).min(meter_top + h - 1.0);
                c.fill(
                    CGRect::new(x + (self.bar_metrics().0 - 4.0) / 2.0, hy, 4.0, 1.0),
                    t.label2(),
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readout_follows_held_peak() {
        let mut m = AudioMeter::new(MeterStyle::Standard);
        assert_eq!(m.readout(), "dB");
        m.update(&[0.5, 0.25], 0.0);
        assert_eq!(m.readout(), "\u{2212}6.0");
        m.silence();
        assert_eq!(m.readout(), "dB");
    }

    #[test]
    fn scale_runs_every_6_db_down_to_the_floor() {
        let t = AudioMeter::SCALE_TICKS;
        assert_eq!((t[0], t[t.len() - 1]), (0.0, MeterBallistics::FLOOR_DB));
        assert!(t.windows(2).all(|w| w[0] - w[1] == 6.0));
    }

    #[test]
    fn mono_folds_to_loudest_side() {
        let mut m = AudioMeter::new(MeterStyle::Standard);
        m.set_mono(true);
        m.update(&[0.1, 1.0], 0.0);
        assert!(m.channels().len() == 1 && m.channels()[0].clipped());
        assert!(m.channel_names() == ["M"] && m.channels_for_bar(0, 2) == [0, 1]);
    }

    #[test]
    fn a_surround_source_is_not_labeled_l_r() {
        let mut m = AudioMeter::new(MeterStyle::Standard);
        assert_eq!(m.channel_names(), ["L", "R"]);
        m.update(&[0.1; 6], 0.0);
        assert_eq!(m.channel_names(), ["1", "2", "3", "4", "5", "6"]);
    }

    #[test]
    fn trough_edge_and_peak_hold_follow_r8() {
        let mut m = AudioMeter::new(MeterStyle::Standard);
        m.update(&[0.5, 0.5], 0.0);
        let mut c = Canvas::with_size(54.0, 300.0, None, 1.0);
        let t = DrawTheme::default();
        m.draw(&mut c, CGRect::new(0.0, 0.0, 54.0, 300.0), &t, &[]);
        assert!(c.list.quads().iter().any(|q| q.color == t.label2() && q.rect.w == 4.0 && q.rect.h == 1.0));
    }

    #[test]
    fn bars_fall_until_settled() {
        let mut m = AudioMeter::new(MeterStyle::Standard);
        m.update(&[1.0, 1.0], 0.0);
        let early = m.tick(1.0);
        let late = m.tick(10.0);
        assert!(!early && late);
        assert!(m.channels()[0].clipped());
        m.reset_clip();
        assert!(!m.channels()[0].clipped());
    }

    #[test]
    fn clicks_match_mac_zones() {
        let m = AudioMeter::new(MeterStyle::Standard);
        assert_eq!(m.hit(CGPoint { x: 20.0, y: 10.0 }, 300.0), AudioMeterHit::ResetClip);
        assert_eq!(m.hit(CGPoint { x: 10.0, y: 290.0 }, 300.0), AudioMeterHit::Channel(0));
        assert_eq!(m.hit(CGPoint { x: 21.0, y: 290.0 }, 300.0), AudioMeterHit::Channel(1));
        assert_eq!(m.hit(CGPoint { x: 10.0, y: 150.0 }, 300.0), AudioMeterHit::None);
    }

    #[test]
    fn draws_green_level_and_red_readout_when_clipped() {
        let mut m = AudioMeter::new(MeterStyle::Standard);
        m.update(&[1.0, 0.1], 0.0);
        let mut c = Canvas::with_size(48.0, 300.0, None, 1.0);
        let t = DrawTheme::default();
        m.draw(&mut c, CGRect::new(0.0, 0.0, 48.0, 300.0), &t, &[MeterChannelLabel::Soloed, MeterChannelLabel::Muted]);
        let has = |col: Color| c.list.quads().iter().any(|q| q.color == col);
        assert!(has(Color::hex(0x30D158, 1.0)));
        assert!(has(t.red()));
    }

    #[test]
    fn the_level_ends_follow_the_rounded_track() {
        let mut m = AudioMeter::new(MeterStyle::Standard);
        m.update(&[1.0, 0.1], 0.0);
        let mut c = Canvas::with_size(48.0, 300.0, None, 1.0);
        let t = DrawTheme::default();
        m.draw(&mut c, CGRect::new(0.0, 0.0, 48.0, 300.0), &t, &[MeterChannelLabel::Normal, MeterChannelLabel::Normal]);
        let rounded = |col: Color| c.list.quads().iter().any(|q| q.color == col && q.radius > 0.0);
        assert!(rounded(Color::hex(0x30D158, 1.0)), "the bottom end of the green level is rounded");
        assert!(rounded(t.red()), "a level at the ceiling has a rounded top end");
    }

    #[test]
    fn the_feed_passes_each_buffer_once() {
        let mut f = MeterFeed::new();
        let r = MeterReading { source: 1, sequence: 7, peaks: vec![0.5] };
        assert_eq!(f.peaks(Some(&r)), Some(vec![0.5]));
        assert_eq!(f.peaks(Some(&r)), None);
        assert!(f.peaks(Some(&MeterReading { source: 2, ..r.clone() })).is_some());
        assert_eq!(f.peaks(None), None);
    }

    #[test]
    fn the_scale_is_linear_in_db_with_a_label_every_6_db() {
        assert_eq!(MeterBallistics::position(-60.0), 0.0);
        assert_eq!(MeterBallistics::position(-30.0), 0.5);
        assert_eq!(MeterBallistics::position(0.0), 1.0);
        let step = MeterBallistics::position(-6.0) - MeterBallistics::position(-12.0);
        assert!((step - 0.1).abs() < 1e-6, "every 6 dB is a tenth of the bar");
    }
}

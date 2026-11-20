// Swift: MeterPanel.swift
//! The audio meter panel on the canvas (the Mac `AudioMeterPanelView` translated): the slim L/R peak bars and the
//! M / S / I / TP loudness columns beside them, polled from the engine's meter feed, a click on the loudness columns
//! restarts integrated and true-peak hold, a click on a channel label solos it (Alt: mutes it), the listening volume
//! strip (slider and Dim) under the meter when the card is tall and wide enough, a right click opens the meter menu
//! (listening steps, channel Solo / Mute, Dim, reset). Listening level and Dim are the `sq.monitor.*` preference
//! (`MonitorGain`); the host applies them and Solo / Mute to the audio output (speakers only, never the meter).
//!
//! The hooks are [`MeterPanelEvent`]s; the readings the Swift closures returned are fields the owner fills before `poll`.

use crate::monitor_panel_model::MenuQueue;
use sq_app_shell::{AppHost, HostCx};
use sq_audiofx::channel_monitor::ChannelMonitor;
use sq_audiofx::monitor_gain::{MonitorDefaults, MonitorGain, MonitorSetting};
use sq_draw::canvas::Canvas;
use sq_draw::monitor::audio_meter::{
    AudioMeter, AudioMeterHit, MeterChannelLabel, MeterFeed, MeterReading, MeterStyle,
};
use sq_draw::monitor::loudness_meter::{LoudnessMeter, LoudnessReading, LoudnessTarget, Style as LoudnessStyle};
use sq_draw::stone::Touch;
use sq_draw::theme::{DrawTheme, metrics, spacing};
use sq_draw::{InputEvent, InputModifiers, InspectorDraw, Rect};
use sq_playback::audio::LoudnessLevels;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::rc::Rc;

/// The settings store of the meter panel: the listening level (`MonitorDefaults`) and the meter ballistics (`UiDefaults`).
pub trait MeterDefaults: MonitorDefaults + UiDefaults {}
impl<T: MonitorDefaults + UiDefaults> MeterDefaults for T {}

/// Swift `LoudnessReading.init(_ l: LoudnessLevels)`: the engine's meter snapshot as a reading (same BS.1770 numbers the
/// export normalizer measures).
pub fn loudness_reading(l: &LoudnessLevels) -> LoudnessReading {
    LoudnessReading {
        momentary_lufs: l.momentary,
        short_term_lufs: l.short_term,
        integrated_lufs: l.integrated,
        true_peak_db: l.true_peak_db,
    }
}

/// What the Swift panel's hooks reported.
#[derive(Clone, Debug)]
pub enum MeterPanelEvent {
    /// `onResetLoudness`.
    ResetLoudness,
    /// `onMenu`: rows and where they open (window points).
    Menu(Vec<SQMenuItem>, CGPoint),
    /// `onChannelMonitorChange`: Solo / Mute changed, the host hands it to the audio output.
    ChannelMonitorChange(ChannelMonitor),
    /// `onMonitorGainChange`: the listening level or Dim changed (already stored): the host applies it to the output.
    MonitorGainChange(MonitorSetting),
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum MeterMenuCommand {
    Level(f64),
    Solo(usize),
    Mute(usize),
    ClearChannels,
    Dim(bool),
    Reset,
}

/// The meter card.
pub struct MeterPanel {
    /// The peak bars.
    pub meter: AudioMeter,
    /// The loudness columns.
    pub loudness: LoudnessMeter,
    /// The theme (set from `draw`).
    pub theme: DrawTheme,
    frame: CGRect,
    meter_rect: CGRect,
    loudness_rect: CGRect,
    strip_rect: CGRect,
    slider_rect: CGRect,
    dim_rect: CGRect,
    channel_monitor: ChannelMonitor,
    dragging_slider: bool,
    hover_dim: bool,
    monitor_defaults: Box<dyn MeterDefaults>,
    scale: f32,
    feed: MeterFeed,
    last_buffer_time: f64,
    /// The engine's newest meter reading (the Swift `reading` closure).
    pub reading: Option<MeterReading>,
    /// The engine's loudness snapshot (`loudnessReading`).
    pub loudness_reading: Option<LoudnessReading>,
    /// The delivery target the columns measure against (`loudnessTargetProvider`).
    pub loudness_target: Option<LoudnessTarget>,
    /// The sequence is Mono (`monoProvider`).
    pub mono: Option<bool>,
    /// What the hooks reported since the owner last took it.
    pub events: Vec<MeterPanelEvent>,
    menu: MenuQueue<MeterMenuCommand>,
}

impl MeterPanel {
    /// No new audio buffer for this long means playback stopped: the bars go to zero at once.
    const STALE_SECONDS: f64 = 0.15;
    /// The strip shows from this card width on (AudioMeterPanelView.monitorStripMinWidth) and 100 pt of height.
    pub const MONITOR_STRIP_MIN_WIDTH: f64 = 72.0;

    /// A panel over the settings store `monitor_defaults`.
    pub fn new(mut monitor_defaults: Box<dyn MeterDefaults>) -> MeterPanel {
        MonitorGain::apply_launch_rules_once(monitor_defaults.as_mut()); // before the strip reads its state
        MeterPanel {
            meter: AudioMeter::new(MeterStyle::Standard),
            loudness: LoudnessMeter::new(LoudnessStyle::Columns),
            theme: DrawTheme::default(),
            frame: CGRect::default(),
            meter_rect: CGRect::default(),
            loudness_rect: CGRect::default(),
            strip_rect: CGRect::default(),
            slider_rect: CGRect::default(),
            dim_rect: CGRect::default(),
            channel_monitor: ChannelMonitor::new(),
            dragging_slider: false,
            hover_dim: false,
            monitor_defaults,
            scale: 1.0,
            feed: MeterFeed::new(),
            last_buffer_time: 0.0,
            reading: None,
            loudness_reading: None,
            loudness_target: None,
            mono: None,
            events: Vec::new(),
            menu: MenuQueue::default(),
        }
    }

    /// Takes the hook calls since the last take.
    pub fn take_events(&mut self) -> Vec<MeterPanelEvent> {
        std::mem::take(&mut self.events)
    }

    /// The card in points.
    pub fn frame(&self) -> CGRect {
        self.frame
    }
    /// The peak bars.
    pub fn meter_rect(&self) -> CGRect {
        self.meter_rect
    }
    /// The loudness columns (zero when the card is too narrow).
    pub fn loudness_rect(&self) -> CGRect {
        self.loudness_rect
    }
    /// The listening strip (zero when the card is too small, as on the Mac).
    pub fn strip_rect(&self) -> CGRect {
        self.strip_rect
    }
    /// The listening slider.
    pub fn slider_rect(&self) -> CGRect {
        self.slider_rect
    }
    /// The Dim button.
    pub fn dim_rect(&self) -> CGRect {
        self.dim_rect
    }
    /// Monitoring-only Solo / Mute of the output channels (the meter keeps showing every channel).
    pub fn channel_monitor(&self) -> ChannelMonitor {
        self.channel_monitor
    }

    /// The listening level and Dim now (the preference).
    pub fn monitor_setting(&self) -> MonitorSetting {
        MonitorSetting::current(self.monitor_defaults.as_ref())
    }

    /// Writes the listening level and / or Dim and reports it (AudioMeterPanelView.setMonitor).
    pub fn set_monitor(&mut self, level_db: Option<f64>, dim: Option<bool>) {
        let mut s = self.monitor_setting();
        if let Some(l) = level_db {
            s.level_db = l.clamp(MonitorGain::MIN_DB, MonitorGain::MAX_DB);
        }
        if let Some(d) = dim {
            s.dim = d;
        }
        MonitorGain::store(&s, self.monitor_defaults.as_mut());
        self.events.push(MeterPanelEvent::MonitorGainChange(s));
    }

    // MARK: Solo / Mute (AudioMeterView.toggleSolo / toggleMute)

    fn bar_channels(&self, bar: usize) -> Vec<i64> {
        self.meter.channels_for_bar(bar as i64, ChannelMonitor::CHANNEL_COUNT).into_iter().map(|c| c as i64).collect()
    }

    /// Solo the channels of `bar`.
    pub fn toggle_solo(&mut self, bar: usize) {
        let chs = self.bar_channels(bar);
        self.channel_monitor.toggle_solo(&chs);
        self.events.push(MeterPanelEvent::ChannelMonitorChange(self.channel_monitor));
    }
    /// Mute the channels of `bar`.
    pub fn toggle_mute(&mut self, bar: usize) {
        let chs = self.bar_channels(bar);
        self.channel_monitor.toggle_mute(&chs);
        self.events.push(MeterPanelEvent::ChannelMonitorChange(self.channel_monitor));
    }
    /// Clears Solo and Mute.
    pub fn clear_channel_monitor(&mut self) {
        if self.channel_monitor.is_neutral() {
            return;
        }
        self.channel_monitor.clear();
        self.events.push(MeterPanelEvent::ChannelMonitorChange(self.channel_monitor));
    }

    /// What each bar's label shows: soloed (accent), muted (red), silenced by another channel's solo (dim red).
    pub fn channel_labels(&self) -> Vec<MeterChannelLabel> {
        (0..self.meter.channel_names().len())
            .map(|i| {
                let chs = self.bar_channels(i);
                let cm = &self.channel_monitor;
                if chs.iter().all(|c| cm.is_muted(*c)) {
                    return MeterChannelLabel::Muted;
                }
                if chs.iter().all(|c| cm.is_soloed(*c)) {
                    return MeterChannelLabel::Soloed;
                }
                if !chs.iter().any(|c| cm.is_audible(*c)) {
                    return MeterChannelLabel::Silenced;
                }
                MeterChannelLabel::Normal
            })
            .collect()
    }

    /// AudioMeterPanelView.layout: the meter (48 pt) and, when it fits, the loudness columns, centered. `r` in pixels.
    pub fn layout_px(&mut self, r: Rect, scale: f32) {
        self.scale = scale.max(0.01);
        let k = self.scale as f64;
        self.layout_frame(CGRect::new(r.x as f64 / k, r.y as f64 / k, r.w as f64 / k, r.h as f64 / k));
    }

    /// The same in window points.
    pub fn layout_frame(&mut self, frame: CGRect) {
        self.frame = frame;
        let gap = spacing::SM as f64;
        let show_loudness = frame.width >= AudioMeter::WIDTH + gap + LoudnessMeter::COLUMNS_WIDTH;
        let lw = if show_loudness { LoudnessMeter::COLUMNS_WIDTH } else { 0.0 };
        let w = AudioMeter::WIDTH.min(frame.width);
        let total = w + if show_loudness { gap + lw } else { 0.0 };
        let x = frame.min_x() + ((frame.width - total) / 2.0).round();
        let fits = frame.height >= 100.0 && frame.width >= Self::MONITOR_STRIP_MIN_WIDTH;
        let strip = if fits { metrics::MONITOR_STRIP as f64 } else { 0.0 };
        let meter_h = frame.height - strip;
        self.meter_rect = CGRect::new(x, frame.min_y(), w, meter_h);
        self.loudness_rect =
            if show_loudness { CGRect::new(x + w + gap, frame.min_y(), lw, meter_h) } else { CGRect::default() };
        if !fits {
            self.strip_rect = CGRect::default();
            self.slider_rect = CGRect::default();
            self.dim_rect = CGRect::default();
            return;
        }
        self.strip_rect = CGRect::new(frame.min_x(), frame.min_y() + meter_h, frame.width, strip);
        let sw = (frame.width - 2.0 * gap).min(metrics::MONITOR_SLIDER_MAX_WIDTH as f64).max(0.0);
        let sh = metrics::MONITOR_SLIDER_HEIGHT as f64;
        self.slider_rect =
            CGRect::new(frame.min_x() + ((frame.width - sw) / 2.0).round(), self.strip_rect.min_y() + gap, sw, sh);
        let dw = metrics::MONITOR_DIM_WIDTH as f64;
        let dh = metrics::MONITOR_DIM_HEIGHT as f64;
        self.dim_rect = CGRect::new(
            frame.min_x() + ((frame.width - dw) / 2.0).round(),
            self.slider_rect.max_y() + gap / 2.0,
            dw,
            dh,
        );
    }

    /// The tooltip at `p`: while the panel is too small for the volume strip, the card says where the volume went
    /// (the right-click menu keeps its Listening Volume steps).
    pub fn hint_at(&self, p: CGPoint) -> Option<&'static str> {
        if !self.frame.contains(p) {
            return None;
        }
        if self.strip_rect.height <= 0.0 {
            return Some("Listening volume hidden: make the panel taller, or right-click for the volume steps");
        }
        self.dim_rect.contains(p).then_some("Dim Monitor")
    }

    /// Slider position of a level: linear in dB between the floor (mute) and 0 dB, as the Mac SQSlider.
    pub fn slider_fraction(level_db: f64) -> f64 {
        (level_db.clamp(MonitorGain::MIN_DB, MonitorGain::MAX_DB) - MonitorGain::MIN_DB)
            / (MonitorGain::MAX_DB - MonitorGain::MIN_DB)
    }

    /// The level of a slider position.
    pub fn level_db(slider_fraction: f64) -> f64 {
        MonitorGain::MIN_DB + slider_fraction.clamp(0.0, 1.0) * (MonitorGain::MAX_DB - MonitorGain::MIN_DB)
    }

    /// One poll (AudioMeterPanelView.poll; the host calls it every frame).
    pub fn poll(&mut self, now: f64) {
        if let Some(mono) = self.mono
            && mono != self.meter.is_mono()
        {
            self.meter.set_mono(mono);
        }
        if let Some(t) = self.loudness_target {
            self.loudness.target = t;
        }
        if let Some(peaks) = self.feed.peaks(self.reading.as_ref()) {
            self.last_buffer_time = now;
            let wanted = MeterStyle::current(self.monitor_defaults.as_ref()); // the Settings page changed it
            if wanted != self.meter.style() {
                self.meter.set_style(wanted);
            }
            self.meter.update(&peaks, now);
            if let Some(l) = self.loudness_reading {
                self.loudness.update(l, now);
            }
        } else if now - self.last_buffer_time > Self::STALE_SECONDS {
            if !self.meter.is_settled() {
                self.meter.silence();
            }
            self.loudness.clear_live();
        }
        self.meter.tick(now);
    }

    /// Draws the card.
    pub fn draw_card(&mut self, c: &mut Canvas, t: &DrawTheme) {
        self.theme = *t;
        self.scale = c.scale;
        if self.frame.width <= 0.0 || self.frame.height <= 0.0 {
            return;
        }
        c.fill_rounded(self.frame, t.panel_radius(), t.panel());
        self.meter.draw(c, self.meter_rect, t, &self.channel_labels());
        if self.loudness_rect.width > 0.0 {
            self.loudness.draw(c, self.loudness_rect, t);
        }
        if self.strip_rect.height <= 0.0 {
            return;
        }
        let s = self.monitor_setting();
        InspectorDraw::slider(c, Self::slider_fraction(s.level_db), 0.0, self.slider_rect, true, t);
        c.stone_chip(self.dim_rect, s.dim, false, Touch { hovering: self.hover_dim, ..Touch::default() }, t);
        let icon = 12.0;
        c.draw_icon(
            SQIcon::VolumeLow,
            CGPoint::new(self.dim_rect.mid_x() - icon / 2.0, self.dim_rect.mid_y() - icon / 2.0),
            icon,
            // r8: dim is shown by the chip state and a brighter glyph, never by the accent.
            if s.dim { t.label() } else { t.label2() },
            None,
        );
    }

    /// The meter menu (AudioMeterPanelView.monitorItems): listening volume steps, channel Solo / Mute, Dim and the reset.
    /// The rows queue their commands; `pump` runs them.
    pub fn menu_items(&self) -> Vec<SQMenuItem> {
        let s = self.monitor_setting();
        let row = |title: &str, checked: bool, c: MeterMenuCommand| {
            let q = self.menu.clone();
            let mut i = SQMenuItem::new(title);
            i.is_checked = checked;
            i.action = Some(Rc::new(move || q.push(c)));
            i
        };
        let mut rows: Vec<SQMenuItem> = vec![SQMenuItem::header("Listening Volume")];
        for db in [0.0, -6.0, -12.0, -18.0, -24.0, -36.0] {
            let title = if db == 0.0 { "Full (0 dB)".to_string() } else { format!("\u{2212}{} dB", -db as i64) };
            rows.push(row(&title, s.level_db == db, MeterMenuCommand::Level(db)));
        }
        rows.push(SQMenuItem::separator());
        rows.push(SQMenuItem::header("Channels"));
        let cm = self.channel_monitor;
        for (i, name) in self.meter.channel_names().iter().enumerate() {
            let chs = self.bar_channels(i);
            rows.push(row(&format!("Solo {name}"), chs.iter().all(|c| cm.is_soloed(*c)), MeterMenuCommand::Solo(i)));
            rows.push(row(&format!("Mute {name}"), chs.iter().all(|c| cm.is_muted(*c)), MeterMenuCommand::Mute(i)));
        }
        rows.push(row("Clear Solo and Mute", false, MeterMenuCommand::ClearChannels));
        rows.push(SQMenuItem::separator());
        rows.push(row("Dim Monitor", s.dim, MeterMenuCommand::Dim(!s.dim)));
        rows.push(row("Reset Peak and Loudness", false, MeterMenuCommand::Reset));
        rows
    }

    /// Runs the commands the menu rows queued.
    pub fn pump(&mut self) {
        for c in self.menu.take() {
            match c {
                MeterMenuCommand::Level(db) => self.set_monitor(Some(db), None),
                MeterMenuCommand::Solo(i) => self.toggle_solo(i),
                MeterMenuCommand::Mute(i) => self.toggle_mute(i),
                MeterMenuCommand::ClearChannels => self.clear_channel_monitor(),
                MeterMenuCommand::Dim(on) => self.set_monitor(None, Some(on)),
                MeterMenuCommand::Reset => {
                    self.meter.reset_clip();
                    self.loudness.reset_peak();
                    self.events.push(MeterPanelEvent::ResetLoudness);
                }
            }
        }
    }

    /// An event in pixels; true when the panel took it (a press on the card, the slider drag that followed it).
    pub fn handle_event(&mut self, e: &InputEvent) -> bool {
        let k = self.scale as f64;
        match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = CGPoint::new(x as f64 / k, y as f64 / k);
                if !self.frame.contains(p) {
                    return false;
                }
                if modifiers.contains(InputModifiers::SECONDARY) {
                    self.events.push(MeterPanelEvent::Menu(self.menu_items(), p));
                    return true;
                }
                if self.loudness_rect.contains(p) {
                    self.loudness.reset_peak();
                    self.events.push(MeterPanelEvent::ResetLoudness);
                    return true;
                }
                if self.dim_rect.contains(p) {
                    let dim = !self.monitor_setting().dim;
                    self.set_monitor(None, Some(dim));
                    return true;
                }
                if self.slider_rect.inset_by(0.0, -4.0).contains(p) {
                    self.dragging_slider = true;
                    let f = InspectorDraw::slider_fraction(p.x, self.slider_rect);
                    self.set_monitor(Some(Self::level_db(f)), None);
                    return true;
                }
                if self.meter_rect.contains(p) {
                    let at = CGPoint::new(p.x - self.meter_rect.min_x(), p.y - self.meter_rect.min_y());
                    match self.meter.hit(at, self.meter_rect.height) {
                        AudioMeterHit::ResetClip => self.meter.reset_clip(),
                        AudioMeterHit::Channel(bar) => {
                            if modifiers.contains(InputModifiers::OPTION) {
                                self.toggle_mute(bar);
                            } else {
                                self.toggle_solo(bar);
                            }
                        }
                        AudioMeterHit::None => {}
                    }
                }
                true
            }
            InputEvent::MouseDragged { x, .. } => {
                if !self.dragging_slider {
                    return false;
                }
                let f = InspectorDraw::slider_fraction(x as f64 / k, self.slider_rect);
                self.set_monitor(Some(Self::level_db(f)), None);
                true
            }
            InputEvent::MouseUp { .. } => {
                if !self.dragging_slider {
                    return false;
                }
                self.dragging_slider = false;
                true
            }
            InputEvent::MouseMoved { x, y } => {
                self.hover_dim = self.dim_rect.contains(CGPoint::new(x as f64 / k, y as f64 / k));
                false
            }
            _ => false,
        }
    }
}

impl AppHost for MeterPanel {
    fn layout(&mut self, frame: CGRect, _cx: &mut HostCx) {
        self.layout_frame(frame);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, _cx: &mut HostCx) {
        self.draw_card(c, t);
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        if let InputEvent::MouseMoved { x, y } = e {
            let k = self.scale as f64;
            cx.ui.hover.offer_tip(self.hint_at(CGPoint::new(*x as f64 / k, *y as f64 / k)));
        }
        let taken = self.handle_event(e);
        self.pump();
        taken
    }
}

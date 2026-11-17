// Swift: MonitorPanel+Source.swift
//! The Program | Source tab strip of the monitor card and the Source monitor's waveform view for audio-only media
//! (SourceWaveformView translated): the whole file's peaks, the In-Out range behind them and the playhead; a press scrubs.

use crate::monitor_drop_indicator::SourceViewerMode;
use crate::monitor_panel::MonitorPanel;
use crate::monitor_panel_model::MonitorEvent;
use sq_core_time::{Time, TimeRange};
use sq_draw::canvas::Canvas;
use sq_draw::monitor::monitor_footer::MonitorScrubMath;
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_draw::theme::spacing;
use sq_draw::{Color, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect};

impl MonitorPanel {
    /// Horizontal inset of the waveform in the slot.
    pub(crate) const WAVE_INSET: f64 = 8.0;
    /// Vertical inset of the waveform in the slot.
    pub(crate) const WAVE_VERTICAL_INSET: f64 = 24.0;

    /// Draws the title or the tabs at `x`; returns the width taken. Fills `tab_rects`.
    pub(crate) fn draw_title_or_tabs(&mut self, c: &mut Canvas, x: f64, font_size: f64) -> f64 {
        let t = self.theme;
        self.tab_rects = Vec::new();
        if self.tabs.is_empty() {
            return c.draw_text_in(
                &self.title,
                CGRect::new(x, self.header_rect.min_y(), self.header_rect.width / 2.0, self.header_rect.height),
                font_size,
                t.label(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
        // The dock's tab strip (`ShellDock.layout` / `draw`): medium labels with 10 pt padding, 2 pt apart, a 2 pt line under
        // the selected tab (accent while the monitor has focus).
        let pad = 10.0;
        let height = 22.0;
        let start = self.header_rect.min_x() + spacing::SM as f64 - 2.0;
        let mut cursor = start;
        let y = (self.header_rect.min_y() + (self.header_rect.height - 1.0 - height) / 2.0).round();
        let medium = c.medium();
        for (i, label) in self.tabs.clone().iter().enumerate() {
            let w = c.size_of(label, font_size, medium).width.ceil() + 2.0 * pad;
            let r = CGRect::new(cursor, y, w, height);
            self.tab_rects.push(r);
            c.draw_text_in(
                label,
                r,
                font_size,
                if i == self.selected_tab { t.label() } else { t.label3() },
                TextAlign::Center,
                0.0,
                medium,
            );
            if i == self.selected_tab {
                let u =
                    CGRect::new(r.min_x() + pad, self.header_rect.max_y() - 2.0, (r.width - 2.0 * pad).max(0.0), 2.0);
                c.fill_rounded(u, 1.0, if self.is_focused { t.accent() } else { t.label3() });
            }
            cursor += w + 2.0;
        }
        cursor - 2.0 - x
    }

    /// The tab under `p` (window points), if any.
    pub fn tab_at(&self, p: CGPoint) -> Option<usize> {
        self.tab_rects.iter().position(|r| r.inset_by(-1.0, 0.0).contains(p))
    }

    /// Audio-only media in the Source monitor: the waveform replaces the picture.
    pub fn shows_waveform(&self) -> bool {
        self.model.mode == MonitorMode::Source
            && self.model.viewer_mode == SourceViewerMode::Waveform
            && self.empty_text().is_none()
    }

    pub(crate) fn wave_math(&self) -> MonitorScrubMath {
        let mut m = MonitorScrubMath::new(self.model.duration, self.model.frame_duration, self.wave_content_width());
        m.inset = Self::WAVE_INSET;
        m
    }

    pub(crate) fn draw_waveform(&self, c: &mut Canvas) {
        let t = self.theme;
        let slot = self.slot;
        let wave = CGRect::new(
            slot.min_x() + Self::WAVE_INSET,
            slot.min_y() + Self::WAVE_VERTICAL_INSET,
            (self.wave_content_width() - 2.0 * Self::WAVE_INSET).max(1.0),
            (slot.height - 2.0 * Self::WAVE_VERTICAL_INSET).max(1.0),
        );
        let m = self.wave_math();
        let total = self.model.duration;
        if (self.model.mark_in.is_some() || self.model.mark_out.is_some()) && total > Time::ZERO {
            let a = m.x_for(self.model.mark_in.unwrap_or(Time::ZERO));
            let b = m.x_for(self.model.mark_out.unwrap_or(total));
            if b > a {
                c.fill(
                    CGRect::new(slot.min_x() + a, wave.min_y() - 8.0, b - a, wave.height + 16.0),
                    t.accent().with_alpha(if t.palette.is_dark() { 0.22 } else { 0.16 }),
                );
            }
        }
        if let Some(data) = self.model.source_waveform.as_ref().filter(|_| total > Time::ZERO) {
            let buckets = (wave.width.round() as i64).max(1) as usize;
            let channels = data.peaks(TimeRange::from_end(Time::ZERO, total), buckets);
            let n = channels.len().max(1);
            let lane_h = wave.height / n as f64;
            let ink = Color::WHITE.with_alpha(0.62);
            let clip = Self::color(t.palette.red);
            for (ci, peaks) in channels.iter().enumerate() {
                let mid = wave.min_y() + lane_h * (ci as f64 + 0.5);
                let half = lane_h / 2.0 - 1.0;
                for (i, p) in peaks.iter().enumerate() {
                    let hi = (p.max as f64).clamp(-1.0, 1.0);
                    let lo = (p.min as f64).clamp(-1.0, 1.0);
                    let top = mid - hi * half;
                    let h = ((hi - lo) * half).max(1.0);
                    c.fill(
                        CGRect::new(wave.min_x() + i as f64, top, 1.0, h),
                        if p.max >= 1.0 || p.min <= -1.0 { clip } else { ink },
                    );
                }
            }
        } else if total > Time::ZERO {
            c.draw_text_in(
                "Building waveform\u{2026}",
                CGRect::new(slot.min_x(), slot.mid_y() - 9.0, slot.width, 18.0),
                13.0,
                t.label3(),
                TextAlign::Center,
                0.0,
                0,
            );
        }
        if total <= Time::ZERO {
            return;
        }
        c.fill(
            CGRect::new(slot.min_x() + m.x_for(self.model.current_time) - 0.5, slot.min_y(), 1.0, slot.height),
            t.playhead(),
        );
    }

    /// A press or drag on the waveform scrubs (the first call of a gesture begins the scrub).
    pub(crate) fn scrub_waveform(&mut self, began: bool, p: CGPoint) {
        if self.model.duration <= Time::ZERO {
            return;
        }
        if began {
            self.model.emit(MonitorEvent::ScrubBegan);
        }
        let t = self.wave_math().time_at_x(p.x - self.slot.min_x());
        self.scrub(t);
    }
}

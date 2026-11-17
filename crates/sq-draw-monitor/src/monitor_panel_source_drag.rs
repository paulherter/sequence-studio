// Swift: MonitorPanel+SourceDrag.swift
//! The Source monitor's drag sources (the Mac `StreamDragView`): the picture drags both streams, the footer's film and
//! waveform handles drag one. The drag starts after 4 pt of movement and reports window pixels, so the host can hover
//! and drop on the timeline as it does for Project list drags.

use crate::monitor_panel::{MonitorPanel, PanelEvent};
use crate::monitor_panel_model::MonitorEvent;
use sq_audiofx::channel_monitor::ChannelMonitor;
use sq_core_edit::timeline_source_edit::SourceStreams;
use sq_draw::TextAlign;
use sq_draw::canvas::Canvas;
use sq_draw::monitor::audio_meter::{
    AudioMeter, AudioMeterHit, MeterChannelLabel, MeterFeed, MeterReading, MeterStyle,
};
use sq_draw::theme::{DrawTheme, radius, type_size};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqicon::SQIcon;

/// Where a Source drag is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MonitorDragPhase {
    /// The pointer moved.
    Moved,
    /// Dropped.
    Ended,
    /// Esc.
    Canceled,
}

/// The level meter beside the Source waveform (SourceWaveformView's `meter`): the Source player's own output,
/// the same ballistics as the Program meter; the readout click clears the clip latch, a label click solos (Alt: mutes).
#[derive(Clone, Debug)]
pub struct SourceWaveMeter {
    /// The bars.
    pub meter: AudioMeter,
    channel_monitor: ChannelMonitor,
    feed: MeterFeed,
    last_buffer_time: f64,
}

impl Default for SourceWaveMeter {
    fn default() -> Self {
        Self::new()
    }
}

impl SourceWaveMeter {
    /// No new buffer for this long = stopped: the bars fall to zero at once (SourceWaveformView.staleSeconds).
    const STALE_SECONDS: f64 = 0.15;

    /// A meter at rest.
    pub fn new() -> SourceWaveMeter {
        SourceWaveMeter {
            meter: AudioMeter::new(MeterStyle::Standard),
            channel_monitor: ChannelMonitor::new(),
            feed: MeterFeed::new(),
            last_buffer_time: 0.0,
        }
    }

    /// Solo / Mute from the labels.
    pub fn channel_monitor(&self) -> ChannelMonitor {
        self.channel_monitor
    }

    /// One poll: `reading` is the Source engine's meter feed with its identity.
    pub fn poll(&mut self, reading: Option<&MeterReading>, now: f64) {
        if let Some(peaks) = self.feed.peaks(reading) {
            self.last_buffer_time = now;
            self.meter.update(&peaks, now);
        } else if now - self.last_buffer_time > Self::STALE_SECONDS && !self.meter.is_settled() {
            self.meter.silence();
        }
        self.meter.tick(now);
    }

    /// The label state of every bar.
    pub fn labels(&self) -> Vec<MeterChannelLabel> {
        (0..self.meter.channel_names().len())
            .map(|i| {
                let chs: Vec<i64> = self
                    .meter
                    .channels_for_bar(i as i64, ChannelMonitor::CHANNEL_COUNT)
                    .into_iter()
                    .map(|c| c as i64)
                    .collect();
                if chs.iter().all(|c| self.channel_monitor.is_muted(*c)) {
                    return MeterChannelLabel::Muted;
                }
                if chs.iter().all(|c| self.channel_monitor.is_soloed(*c)) {
                    return MeterChannelLabel::Soloed;
                }
                if !chs.iter().any(|c| self.channel_monitor.is_audible(*c)) {
                    return MeterChannelLabel::Silenced;
                }
                MeterChannelLabel::Normal
            })
            .collect()
    }

    /// A click at `p` (meter coordinates, `height` tall); true when Solo / Mute changed.
    pub fn click(&mut self, p: CGPoint, height: f64, alt: bool) -> bool {
        match self.meter.hit(p, height) {
            AudioMeterHit::ResetClip => {
                self.meter.reset_clip();
                false
            }
            AudioMeterHit::Channel(bar) => {
                let chs: Vec<i64> = self
                    .meter
                    .channels_for_bar(bar as i64, ChannelMonitor::CHANNEL_COUNT)
                    .into_iter()
                    .map(|c| c as i64)
                    .collect();
                if alt {
                    self.channel_monitor.toggle_mute(&chs);
                } else {
                    self.channel_monitor.toggle_solo(&chs);
                }
                true
            }
            AudioMeterHit::None => false,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct SourceDragState {
    pub streams: SourceStreams,
    pub start: CGPoint,
    pub active: bool,
}

impl MonitorPanel {
    /// The meter column right of the Source waveform (zero when no meter feed is set or the waveform is not shown).
    pub fn wave_meter_rect(&self) -> CGRect {
        if !self.shows_waveform() || !self.has_wave_meter {
            return CGRect::default();
        }
        CGRect::new(
            self.slot.max_x() - AudioMeter::WIDTH - Self::WAVE_INSET / 2.0,
            self.slot.min_y(),
            AudioMeter::WIDTH,
            self.slot.height,
        )
    }

    /// Width the waveform and its scrub map use: the meter column is not part of it.
    pub(crate) fn wave_content_width(&self) -> f64 {
        if self.wave_meter_rect().width > 0.0 {
            (self.slot.width - AudioMeter::WIDTH - Self::WAVE_INSET).max(1.0)
        } else {
            self.slot.width
        }
    }

    /// Per frame while the Source tab shows (the Mac 30 Hz timer).
    pub fn poll_wave_meter(&mut self, now: f64) {
        if !self.shows_waveform() || !self.has_wave_meter {
            return;
        }
        self.wave_meter.poll(self.wave_meter_reading.as_ref(), now);
    }

    pub(crate) fn draw_wave_meter(&self, c: &mut Canvas) {
        let r = self.wave_meter_rect();
        if r.width <= 0.0 {
            return;
        }
        self.wave_meter.meter.draw(c, r, &self.theme, &self.wave_meter.labels());
    }

    /// Press on the Source picture or a stream handle: a drag may start (the 4 pt threshold runs in `source_drag_moved`).
    /// False when there is nothing to drag (no clip, no host hook).
    pub(crate) fn begin_source_drag_press(&mut self, streams: SourceStreams, p: CGPoint) -> bool {
        if !(self.model.mode == sq_draw::monitor::monitor_modes::MonitorMode::Source
            && self.wiring.source_drag
            && self.empty_text().is_none())
        {
            return false;
        }
        self.source_drag = Some(SourceDragState { streams, start: p, active: false });
        true
    }

    /// A pointer move with a press pending or a drag running; `x`, `y` in window pixels.
    pub(crate) fn source_drag_moved(&mut self, p: CGPoint, x: f32, y: f32) {
        let Some(mut d) = self.source_drag else { return };
        if !d.active {
            if (p.x - d.start.x).hypot(p.y - d.start.y) <= 4.0 {
                return;
            }
            d.active = true;
            self.source_drag = Some(d);
        }
        self.events.push(PanelEvent::SourceDrag { streams: d.streams, phase: MonitorDragPhase::Moved, x, y });
    }

    /// The press ended: drops when the drag ran (a plain click does nothing, as on the Mac).
    pub(crate) fn source_drag_ended(&mut self, x: f32, y: f32, canceled: bool) {
        let Some(d) = self.source_drag.take() else { return };
        if !d.active {
            return;
        }
        let phase = if canceled { MonitorDragPhase::Canceled } else { MonitorDragPhase::Ended };
        self.events.push(PanelEvent::SourceDrag { streams: d.streams, phase, x, y });
        self.model.emit(MonitorEvent::DragEnded);
    }

    /// The drag running now (its streams), for the host's ghost; `None` while only pressed.
    pub fn active_source_drag(&self) -> Option<SourceStreams> {
        self.source_drag.filter(|d| d.active).map(|d| d.streams)
    }
}

/// The tile that follows the pointer during a Source drag (the Mac `StreamDragView.ghostImage` drag image): a 60 x 106
/// tile with the streams' icon and a tip box under it, the tile centered on the pointer.
pub enum SourceDragGhost {}

impl SourceDragGhost {
    /// The tile.
    pub const TILE: CGSize = CGSize::new(60.0, 106.0);
    const GAP: f64 = 6.0;
    const PAD: f64 = 4.0;

    /// The tip under the tile.
    pub fn tip_text(streams: SourceStreams) -> &'static str {
        match streams {
            SourceStreams::Both => "Video and audio",
            SourceStreams::VideoOnly => "Video only",
            SourceStreams::AudioOnly => "Audio only",
        }
    }

    /// Tile and tip box for the pointer `p` (points) and a tip `tip_width` wide; the Mac drag frame's placement.
    pub fn layout(p: CGPoint, tip_width: f64) -> (CGRect, CGRect) {
        let tip_box = CGSize::new(tip_width.ceil() + 12.0, 20.0);
        let width = Self::TILE.width.max(tip_box.width) + 2.0 * Self::PAD;
        let origin = CGPoint::new(p.x - Self::TILE.width / 2.0, p.y - Self::TILE.height / 2.0);
        let t = CGRect::new(
            origin.x + (width - Self::TILE.width) / 2.0,
            origin.y + Self::PAD,
            Self::TILE.width,
            Self::TILE.height,
        );
        let box_ =
            CGRect::new(origin.x + (width - tip_box.width) / 2.0, t.max_y() + Self::GAP, tip_box.width, tip_box.height);
        (t, box_)
    }

    /// Draws the ghost at `p`.
    pub fn draw(c: &mut Canvas, streams: SourceStreams, p: CGPoint, t: &DrawTheme) {
        let tip = Self::tip_text(streams);
        let size = type_size::CAPTION as f64;
        let (tile, tip_rect) = Self::layout(p, c.size_of(tip, size, 0).width);
        let rad = radius::CONTROL as f64;
        c.fill_rounded(tile, rad, t.fill());
        c.stroke_rounded(tile, rad, 1.5, t.yellow());
        let icon = match streams {
            SourceStreams::AudioOnly => SQIcon::Waveform,
            SourceStreams::VideoOnly => SQIcon::Film,
            SourceStreams::Both => SQIcon::Sequence,
        };
        c.draw_icon(icon, CGPoint::new(tile.mid_x() - 11.0, tile.mid_y() - 11.0), 22.0, t.label2(), None);
        c.fill_rounded(tip_rect, rad, t.overlay());
        c.draw_text_in(tip, tip_rect.inset_by(6.0, 0.0), size, t.label(), TextAlign::Left, 0.0, 0);
    }
}

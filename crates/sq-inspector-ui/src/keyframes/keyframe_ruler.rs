// Swift: KeyframeRuler.swift
//! Pure tick layout of the Effect Controls ruler and the texts of the clip line.

use sq_core_model::TrackKind;
use sq_core_time::Time;
use sq_editor_session::{RulerScale, TimecodeFormat};

use crate::ec::effect_controls_model::lane_geometry::KeyframeLaneGeometry;

/// One tick of the ruler.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyframeRulerTick {
    /// Clip-local time.
    pub local: Time,
    pub major: bool,
}

/// Pure tick layout of the Effect Controls ruler (same x mapping as the keyframe lanes, zoom included).
pub enum KeyframeRulerLayout {}

impl KeyframeRulerLayout {
    /// Ticks over the whole clip range 0...duration for the given lane width.
    pub fn ticks_for_width(
        width: f64,
        duration: Time,
        frame_duration: Time,
        nominal_fps: i64,
    ) -> Vec<KeyframeRulerTick> {
        Self::ticks(&KeyframeLaneGeometry::new(width, duration), frame_duration, nominal_fps)
    }

    /// Ticks inside the visible window only (a long clip zoomed to a few frames must not produce a tick per frame of the clip).
    pub fn ticks(geo: &KeyframeLaneGeometry, frame_duration: Time, nominal_fps: i64) -> Vec<KeyframeRulerTick> {
        let frames = geo.duration.frame_index(frame_duration);
        if frames <= 0 {
            return Vec::new();
        }
        let fd_secs = frame_duration.value() as f64 / frame_duration.timescale() as f64;
        let ppf = geo.points_per_second() * fd_secs;
        if ppf <= 0.0 {
            return Vec::new();
        }
        let scale = RulerScale::scale(ppf, nominal_fps, 48.0, 6.0);
        let minor = scale.minor_frames.max(1);
        let major = scale.major_frames.max(1);
        // Visible frames, with one tick of slack on each side (the lane inset is 10 pt).
        let pps = geo.points_per_second().max(1e-9);
        let first = (((geo.view_start() - 12.0 / pps) / fd_secs).floor() as i64).max(0);
        let last = (((geo.view_start() + geo.view_span() + 12.0 / pps) / fd_secs).ceil() as i64).min(frames);
        if first > last {
            return Vec::new();
        }
        let mut out = Vec::new();
        let mut f = (first / minor) * minor;
        while f <= last {
            out.push(KeyframeRulerTick { local: Time::frames(f, frame_duration), major: f % major == 0 });
            f += minor;
        }
        out
    }

    /// Timeline time for a pointer x in the ruler, frame-snapped and clamped to the clip.
    pub fn seek_time(x: f64, width: f64, clip_start: Time, duration: Time, frame_duration: Time) -> Time {
        clip_start + KeyframeLaneGeometry::new(width, duration).time(x, frame_duration)
    }

    /// "00:00:15:00" -> "15:00", "00:01:05:12" -> "1:05:12": the mini ruler drops the leading zero groups (v9 `.kruler`).
    pub fn short_label(timecode: &str) -> String {
        let mut parts: Vec<String> = timecode.split([':', ';']).filter(|p| !p.is_empty()).map(str::to_string).collect();
        if parts.len() <= 2 {
            return timecode.to_string();
        }
        while parts.len() > 2 && parts[0].parse::<i64>().is_ok_and(|n| n == 0) {
            parts.remove(0);
        }
        if parts.len() > 2
            && let Ok(n) = parts[0].parse::<i64>()
        {
            parts[0] = n.to_string();
        }
        parts.join(":")
    }
}

/// The clip line of Effect Controls (v9 `.clhead`): its texts, shared by the Mac view and the shared-toolkit panel.
pub enum EffectControlsHeaderText {}

impl EffectControlsHeaderText {
    /// "Video · 00:00:02:00": the clip line's tooltip (kind and duration).
    pub fn clip_info(kind: TrackKind, duration: Time, frame_duration: Time, kind_name: Option<&str>) -> String {
        let tc = TimecodeFormat::new(frame_duration, false);
        let name = kind_name.unwrap_or(if kind == TrackKind::Audio { "Audio" } else { "Video" });
        format!("{name} \u{00B7} {}", tc.string_for_time(duration, frame_duration))
    }

    /// "Main · V1 · 00:00:15:00 – 00:00:17:00" (v9 `.clhead .m`): sequence, track and the clip's range in the sequence.
    /// `kind_name` (Text, Shape, Graphic ...) leads when the clip is not plain video or audio.
    pub fn clip_meta(
        sequence: Option<&str>,
        track: Option<&str>,
        start: Time,
        end: Time,
        frame_duration: Time,
        kind_name: Option<&str>,
    ) -> String {
        let tc = TimecodeFormat::new(frame_duration, false);
        let range = format!(
            "{} \u{2013} {}",
            tc.string_for_time(start, frame_duration),
            tc.string_for_time(end, frame_duration)
        );
        let mut parts: Vec<String> =
            [kind_name, sequence, track].iter().flatten().filter(|s| !s.is_empty()).map(|s| (*s).to_string()).collect();
        parts.push(range);
        parts.join(" \u{00B7} ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_label_drops_leading_zero_groups() {
        assert_eq!(KeyframeRulerLayout::short_label("00:00:15:00"), "15:00");
        assert_eq!(KeyframeRulerLayout::short_label("00:01:05:12"), "1:05:12");
        assert_eq!(KeyframeRulerLayout::short_label("15:00"), "15:00");
        assert_eq!(KeyframeRulerLayout::short_label("00:00:15;00"), "15:00");
    }

    #[test]
    fn ticks_cover_the_clip_and_major_ticks_sit_on_the_major_grid() {
        let fd = Time::new(1, 30);
        let ticks = KeyframeRulerLayout::ticks_for_width(520.0, Time::seconds(10), fd, 30);
        assert!(!ticks.is_empty());
        assert_eq!(ticks[0].local, Time::ZERO);
        assert!(ticks[0].major);
        assert!(ticks.windows(2).all(|w| w[0].local < w[1].local));
        assert!(KeyframeRulerLayout::ticks_for_width(520.0, Time::ZERO, fd, 30).is_empty());
    }

    #[test]
    fn header_texts_join_with_a_middle_dot() {
        let fd = Time::new(1, 30);
        assert_eq!(
            EffectControlsHeaderText::clip_info(TrackKind::Video, Time::seconds(2), fd, None),
            "Video \u{00B7} 00:00:02:00"
        );
        assert_eq!(
            EffectControlsHeaderText::clip_meta(
                Some("Main"),
                Some("V1"),
                Time::seconds(15),
                Time::seconds(17),
                fd,
                None
            ),
            "Main \u{00B7} V1 \u{00B7} 00:00:15:00 \u{2013} 00:00:17:00"
        );
    }
}

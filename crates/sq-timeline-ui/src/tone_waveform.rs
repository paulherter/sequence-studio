// Swift: ToneWaveform.swift
//! The waveform of a tone clip: a constant signal, so the peaks are made from the spec (no file, no cache). One bucket per
//! second at a 1 kHz nominal rate, which keeps the data tiny for any clip length; the outline is a flat band at the tone's level.

use sq_core_audio::tone_generator::ToneSpec;
use sq_core_time::Time;
use sq_media::waveform_data::WaveformData;

pub struct ToneWaveform;

impl ToneWaveform {
    pub fn data(spec: &ToneSpec, source_end: Time) -> WaveformData {
        let seconds = (source_end.value() as f64 / source_end.timescale() as f64).max(1.0);
        let buckets = seconds.ceil() as usize + 1;
        let peak = 10f64.powf(spec.level_centi_db() as f64 / 2000.0) as f32;
        let mut levels = vec![0.0f32; buckets * 2];
        for i in 0..buckets {
            levels[2 * i] = -peak;
            levels[2 * i + 1] = peak;
        }
        WaveformData::new(1000, 1, buckets * 1000, 1000, vec![levels])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_bucket_per_second_plus_one() {
        let d = ToneWaveform::data(&ToneSpec::new(1_000_000, 0), Time::new(5, 1));
        assert_eq!(d.levels[0].len(), 12);
        assert_eq!(d.total_frames, 6000);
        assert_eq!(d.levels[0][1], 1.0);
        assert_eq!(d.levels[0][0], -1.0);
    }

    #[test]
    fn short_sources_count_as_one_second_and_level_follows_centi_db() {
        let d = ToneWaveform::data(&ToneSpec::new(1_000_000, -2000), Time::new(1, 10));
        assert_eq!(d.levels[0].len(), 4);
        assert!((d.levels[0][1] - 0.1).abs() < 1e-6);
    }

    /// The waveform is a plain linear picture of the peak: Swift `WaveformPath.yRange` is `maxY - hi * height` and
    /// `WaveformPath.columns` only clamps to 0...1, so no dB, log or normalized scale exists. A quiet tone is therefore
    /// small at the default audio row, exactly as in the Swift app; a change of this scale is a design decision.
    #[test]
    fn quiet_tones_draw_linear_bands_like_the_swift_app() {
        use crate::clip_body_metrics::ClipBodyMetrics;
        use crate::timeline_geometry::TimelineGeometry;
        use sq_core_model::TrackKind;
        use sq_core_time::TimeRange;
        use sq_uikit::keyframe_graph_geometry::Rect;
        use sq_uikit::waveform_drawing::{WaveformInput, WaveformPath, WaveformStyle};
        use std::sync::Arc;

        let row = Rect::new(0.0, 0.0, 120.0, TimelineGeometry::default_height(TrackKind::Audio, 0));
        let wave = ClipBodyMetrics::waveform_rect(&row);
        // (level in dBFS, band height as a share of the waveform area): 0.5, 0.1259, 0.0316.
        for (centi_db, share) in [(-600, 0.5012), (-1800, 0.1259), (-3000, 0.0316)] {
            let end = Time::new(2, 1);
            let data = Arc::new(ToneWaveform::data(&ToneSpec::new(1_000_000, centi_db), end));
            let input = WaveformInput::new(data, TimeRange::new(Time::ZERO, end), wave.width, 0..wave.width as i64);
            let bars = WaveformPath::bars(&WaveformPath::columns(&input), wave, WaveformStyle::default(), 0);
            let want = share * wave.height;
            if want < 0.5 {
                assert!(bars.is_empty(), "{centi_db}: a band under half a point is not drawn (Swift `bars`)");
            } else {
                assert!(bars.iter().all(|b| (b.height - want).abs() < 0.01), "{centi_db}: want {want}");
                assert!(bars.iter().all(|b| (b.max_y() - wave.max_y()).abs() < 1e-9), "bands grow from the bottom");
            }
        }
    }
}

// Swift: WaveformClipping.swift
//! Clipping indication on a timeline waveform: the part of a column between -1 dBFS and full scale is drawn yellow
//! ("near"); a column that reaches 0 dBFS or goes over it (the waveform shows the level after Volume and Audio Gain)
//! is drawn red over the same band. Pure geometry on the columns the waveform is drawn from.

use sq_uikit::keyframe_graph_geometry::Rect;
use sq_uikit::waveform_drawing::{WaveformColumn, WaveformPath, WaveformShape, WaveformStyle};

/// -1 dBFS as linear amplitude: from here on a peak counts as near clipping.
const NEAR_THRESHOLD: f32 = 0.891_25;
/// Columns this close to full scale count as reaching 0 dBFS (columns are clamped to 1).
const OVER_THRESHOLD: f32 = 0.999;

/// How close a column is to full scale.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClippingLevel {
    Clear,
    Near,
    Over,
}

/// The rectangles to fill, per level.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClippingBands {
    pub near: Vec<Rect>,
    pub over: Vec<Rect>,
}

pub struct WaveformClipping;

impl WaveformClipping {
    /// The level of one column.
    pub fn level(c: &WaveformColumn) -> ClippingLevel {
        let peak = c.lo.abs().max(c.hi.abs());
        if c.clipped || peak >= OVER_THRESHOLD {
            return ClippingLevel::Over;
        }
        if peak >= NEAR_THRESHOLD { ClippingLevel::Near } else { ClippingLevel::Clear }
    }

    /// Bands to fill, in the coordinates of `rect` (same as `WaveformPath::bars`): `near` and `over` as rectangles.
    pub fn band_rects(
        columns: &[Vec<WaveformColumn>],
        rect: Rect,
        style: WaveformStyle,
        first_column: i64,
    ) -> ClippingBands {
        let mut out = ClippingBands::default();
        let t = f64::from(NEAR_THRESHOLD);
        for (lane, lane_rect) in WaveformPath::lane_rects(rect, columns.len()).into_iter().enumerate() {
            let Some(cols) = columns.get(lane) else { continue };
            // y of the -1 dBFS line: from the bottom up (rectified) or either side of the center (bipolar).
            let cut = if style.shape == WaveformShape::Rectified {
                (lane_rect.max_y() - t * lane_rect.height, lane_rect.max_y())
            } else {
                (lane_rect.mid_y() - t * lane_rect.height / 2.0, lane_rect.mid_y() + t * lane_rect.height / 2.0)
            };
            for (i, c) in cols.iter().enumerate() {
                let level = Self::level(c);
                if level == ClippingLevel::Clear {
                    continue;
                }
                let x = rect.min_x() + (first_column + i as i64) as f64;
                if !(x >= rect.min_x() && x + 1.0 <= rect.max_x() + 0.001) {
                    continue;
                }
                let (top, bottom) = WaveformPath::y_range(c, lane_rect, style);
                let mut add = vec![Rect { x, y: top, width: 1.0, height: (cut.0 - top).max(1.0) }];
                if style.shape == WaveformShape::Bipolar {
                    let y = cut.1.min(bottom - 1.0);
                    add.push(Rect { x, y, width: 1.0, height: (bottom - y).max(1.0) });
                }
                if level == ClippingLevel::Over { out.over.extend(add) } else { out.near.extend(add) }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_uikit::waveform_drawing::WaveformChannels;

    fn col(lo: f32, hi: f32, clipped: bool) -> WaveformColumn {
        WaveformColumn { lo, hi, clipped }
    }

    #[test]
    fn levels_split_at_minus_one_dbfs_and_full_scale() {
        assert_eq!(WaveformClipping::level(&col(-0.5, 0.5, false)), ClippingLevel::Clear);
        assert_eq!(WaveformClipping::level(&col(-0.9, 0.2, false)), ClippingLevel::Near);
        assert_eq!(WaveformClipping::level(&col(-0.1, 0.999, false)), ClippingLevel::Over);
        assert_eq!(WaveformClipping::level(&col(-0.1, 0.1, true)), ClippingLevel::Over);
    }

    #[test]
    fn rectified_band_runs_from_peak_down_to_the_minus_one_line() {
        let style = WaveformStyle { shape: WaveformShape::Rectified, channels: WaveformChannels::Mixed };
        let rect = Rect { x: 10.0, y: 0.0, width: 4.0, height: 100.0 };
        let cols = vec![vec![col(0.0, 0.3, false), col(0.0, 0.95, false), col(0.0, 1.0, false)]];
        let b = WaveformClipping::band_rects(&cols, rect, style, 0);
        assert_eq!(b.near.len(), 1);
        assert_eq!(b.over.len(), 1);
        assert_eq!(b.near[0].x, 11.0);
        assert!((b.near[0].y - 5.0).abs() < 1e-5);
        assert!((b.near[0].height - (100.0 - 89.125 - 5.0)).abs() < 1e-3);
        assert_eq!(b.over[0].x, 12.0);
    }

    #[test]
    fn bipolar_adds_a_second_band_below_the_center() {
        let style = WaveformStyle { shape: WaveformShape::Bipolar, channels: WaveformChannels::Mixed };
        let rect = Rect { x: 0.0, y: 0.0, width: 2.0, height: 100.0 };
        let b = WaveformClipping::band_rects(&[vec![col(-0.95, 0.95, false)]], rect, style, 0);
        assert_eq!(b.near.len(), 2);
    }

    #[test]
    fn columns_outside_the_rect_are_skipped() {
        let style = WaveformStyle::default();
        let rect = Rect { x: 0.0, y: 0.0, width: 1.0, height: 10.0 };
        let b = WaveformClipping::band_rects(&[vec![col(0.0, 1.0, true), col(0.0, 1.0, true)]], rect, style, 0);
        assert_eq!(b.over.len(), 1);
    }
}

//! The compressor's transfer curve and gain-reduction meter geometry (pure). Input level on the x axis, output on the y
//! axis, both -60..0 dB; the straight line is "no compression", the bent one is what the band does. Built from the band's
//! existing Threshold, Ratio and the overall Makeup gain: no DSP of its own.

use sq_uikit::controls_grid::{CGPoint, CGRect};

/// The plotted level range in dB.
pub const FLOOR_DB: f64 = -60.0;
/// The meter's full scale in dB of reduction (same as the band strip).
pub const METER_FULL_SCALE_DB: f64 = 24.0;

/// Output level for an input level: unchanged up to the threshold, then 1/ratio of the rest.
pub fn output_db(input_db: f64, threshold_db: f64, ratio: f64) -> f64 {
    if input_db <= threshold_db { input_db } else { threshold_db + (input_db - threshold_db) / ratio.max(1.0) }
}

/// How far the compressor pulls this input level down.
pub fn reduction_db(input_db: f64, threshold_db: f64, ratio: f64) -> f64 {
    (input_db - output_db(input_db, threshold_db, ratio)).max(0.0)
}

fn x_of(db: f64, plot: CGRect) -> f64 {
    plot.min_x() + (db.clamp(FLOOR_DB, 0.0) - FLOOR_DB) / -FLOOR_DB * plot.width
}

fn y_of(db: f64, plot: CGRect) -> f64 {
    plot.max_y() - (db.clamp(FLOOR_DB, 0.0) - FLOOR_DB) / -FLOOR_DB * plot.height
}

/// The curve as a polyline: three points are enough (start, knee, end), the makeup lifts the whole line.
pub fn curve_points(threshold_db: f64, ratio: f64, makeup_db: f64, plot: CGRect) -> Vec<CGPoint> {
    [FLOOR_DB, threshold_db.clamp(FLOOR_DB, 0.0), 0.0]
        .into_iter()
        .map(|i| CGPoint::new(x_of(i, plot), y_of(output_db(i, threshold_db, ratio) + makeup_db, plot)))
        .collect()
}

/// The identity line from the bottom left to the top right.
pub fn identity_points(plot: CGRect) -> [CGPoint; 2] {
    [CGPoint::new(x_of(FLOOR_DB, plot), y_of(FLOOR_DB, plot)), CGPoint::new(x_of(0.0, plot), y_of(0.0, plot))]
}

/// The x of the threshold line.
pub fn threshold_x(threshold_db: f64, plot: CGRect) -> f64 {
    x_of(threshold_db, plot)
}

/// The reduction the meter shows for one reading of the track tap: the picked band's, or 0 when no audio ran since the last
/// reading (`seen` is the sequence of that one: stopped, so the meter falls back). Returns the new `seen` too.
pub fn live_reduction(seen: Option<u64>, sequence: u64, reduction_db: [f32; 4], band: usize) -> (Option<u64>, f64) {
    let db = if seen == Some(sequence) { 0.0 } else { f64::from(reduction_db[band.min(3)]).max(0.0) };
    (Some(sequence), db)
}

/// The filled height of the gain-reduction meter (from the top).
pub fn meter_height(reduction_db: f64, meter_height: f64) -> f64 {
    (reduction_db.max(0.0) / METER_FULL_SCALE_DB).min(1.0) * meter_height
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn below_the_threshold_nothing_changes_above_it_the_ratio_bends() {
        assert_eq!(output_db(-30.0, -18.0, 3.0), -30.0);
        assert_eq!(output_db(-18.0, -18.0, 3.0), -18.0);
        assert!((output_db(0.0, -18.0, 3.0) - -12.0).abs() < 1e-9);
        assert!((reduction_db(0.0, -18.0, 3.0) - 12.0).abs() < 1e-9);
        assert_eq!(reduction_db(-40.0, -18.0, 3.0), 0.0);
    }

    #[test]
    fn a_ratio_of_one_is_the_straight_line() {
        assert_eq!(output_db(-6.0, -18.0, 1.0), -6.0);
    }

    #[test]
    fn the_curve_starts_on_the_diagonal_and_bends_at_the_threshold_line() {
        let plot = CGRect::new(10.0, 20.0, 120.0, 80.0);
        let p = curve_points(-30.0, 2.0, 0.0, plot);
        assert_eq!((p[0].x, p[0].y), (10.0, 100.0));
        assert_eq!(p[1].x, threshold_x(-30.0, plot));
        assert_eq!(p[1].x, 70.0);
        assert_eq!(p[1].y, 60.0);
        assert_eq!((p[2].x, p[2].y), (130.0, 20.0 + 80.0 * 0.25));
    }

    #[test]
    fn makeup_lifts_the_curve_and_stays_in_the_plot() {
        let plot = CGRect::new(0.0, 0.0, 120.0, 60.0);
        let up = curve_points(-30.0, 2.0, 6.0, plot);
        assert!(up[1].y < curve_points(-30.0, 2.0, 0.0, plot)[1].y);
        assert!(up.iter().all(|p| p.y >= 0.0 && p.y <= 60.0));
    }

    #[test]
    fn the_live_meter_shows_the_picked_band_and_falls_back_when_no_audio_runs() {
        let gr = [1.0, 4.5, 0.0, 2.0];
        assert_eq!(live_reduction(None, 7, gr, 1), (Some(7), 4.5));
        assert_eq!(live_reduction(Some(7), 8, gr, 3), (Some(8), 2.0));
        assert_eq!(live_reduction(Some(8), 8, gr, 1), (Some(8), 0.0), "same sequence: stopped");
        assert_eq!(live_reduction(None, 1, [-1.0; 4], 9).1, 0.0, "never negative, band clamped");
    }

    #[test]
    fn the_meter_fills_from_the_top_up_to_full_scale() {
        assert_eq!(meter_height(0.0, 80.0), 0.0);
        assert_eq!(meter_height(12.0, 80.0), 40.0);
        assert_eq!(meter_height(60.0, 80.0), 80.0);
    }
}

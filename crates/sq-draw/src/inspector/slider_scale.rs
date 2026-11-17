//! How a slider's value maps to its track. A frequency from 20 Hz to 20 kHz spans three decades: on a linear track 120, 200 and
//! 300 Hz sit on the same pixels, so a frequency slider is logarithmic (the Swift app's EQ curve plot uses the same 20 Hz to
//! 20 kHz log axis; its slider rows were linear, which is the unusable part).

/// True for a slider that spans decades and has to read on a log scale: a frequency range of at least a factor of ten.
pub fn is_logarithmic(unit: &str, lo: f64, hi: f64) -> bool {
    unit == "Hz" && lo > 0.0 && hi / lo >= 10.0
}

/// The track fraction (0...1) of `value` in `lo...hi`; `log` maps on a log scale.
pub fn fraction(value: f64, lo: f64, hi: f64, log: bool) -> f64 {
    if log {
        let (lo, hi, v) = (lo.max(f64::MIN_POSITIVE), hi.max(f64::MIN_POSITIVE), value.max(f64::MIN_POSITIVE));
        return ((v / lo).ln() / (hi / lo).ln().max(1e-9)).clamp(0.0, 1.0);
    }
    ((value - lo) / (hi - lo).max(1e-9)).clamp(0.0, 1.0)
}

/// The value at track fraction `f` (0...1) of `lo...hi`; the inverse of [`fraction`].
pub fn value(f: f64, lo: f64, hi: f64, log: bool) -> f64 {
    let f = f.clamp(0.0, 1.0);
    if log {
        let lo = lo.max(f64::MIN_POSITIVE);
        return lo * (hi.max(lo) / lo).powf(f);
    }
    lo + f * (hi - lo)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_frequency_over_decades_is_logarithmic() {
        assert!(is_logarithmic("Hz", 20.0, 20_000.0));
        assert!(!is_logarithmic("Hz", 20.0, 100.0), "less than a decade stays linear");
        assert!(!is_logarithmic("dB", 1.0, 1000.0));
        assert!(!is_logarithmic("Hz", 0.0, 20_000.0), "a log scale needs a positive start");
    }

    #[test]
    fn the_log_mapping_puts_each_octave_the_same_distance_apart() {
        let (lo, hi) = (20.0, 20_000.0);
        assert_eq!(fraction(20.0, lo, hi, true), 0.0);
        assert!((fraction(20_000.0, lo, hi, true) - 1.0).abs() < 1e-12);
        // 632 Hz is the geometric middle of 20 Hz and 20 kHz.
        assert!((fraction(632.455_532, lo, hi, true) - 0.5).abs() < 1e-6);
        // 120, 200 and 300 Hz are far apart on the track (on a linear track all three sit within 1.5 %).
        let (a, b, c) = (fraction(120.0, lo, hi, true), fraction(200.0, lo, hi, true), fraction(300.0, lo, hi, true));
        assert!(b - a > 0.07 && c - b > 0.05, "{a} {b} {c}");
        assert!(fraction(300.0, lo, hi, false) < 0.015);
    }

    #[test]
    fn value_inverts_fraction_on_both_scales() {
        for log in [false, true] {
            for v in [20.0, 55.0, 120.0, 1_000.0, 8_000.0, 20_000.0] {
                let back = value(fraction(v, 20.0, 20_000.0, log), 20.0, 20_000.0, log);
                assert!((back - v).abs() < v * 1e-9, "log {log}: {v} came back as {back}");
            }
        }
        assert_eq!(value(2.0, 20.0, 20_000.0, true), 20_000.0, "a fraction past the end clamps");
    }
}

//! The track's "Effects" tab: EQ, Noise Gate, Noise Reduction, Warmth and Multiband as cards. The EQ card is the four
//! band gains the track's compressor already carries (`MultibandBand::gain_db`, "EQ = per-band gain") with the crossovers
//! as the frequencies; every other card edits the settings the track model already has. No DSP of its own. This file
//! holds the pure part (tab names, EQ curve geometry); the rows and the drawing are in `track_audio_draw`.

use sq_audiofx::presets::MultibandBand;
use sq_uikit::controls_grid::{CGPoint, CGRect};

/// The two tabs of the audio block.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum Tab {
    /// Role, preset and the compressor.
    #[default]
    Track,
    /// The effect cards.
    Effects,
}

impl Tab {
    pub const ALL: [Tab; 2] = [Tab::Track, Tab::Effects];

    pub fn title(self) -> &'static str {
        match self {
            Tab::Track => "Track",
            Tab::Effects => "Effects",
        }
    }
}

/// The EQ chips' names, low to high.
pub const EQ_CHIPS: [&str; 4] = ["1 Low shelf", "2 Bell", "3 Bell", "4 High shelf"];
/// The compressor band names the Multiband card uses.
pub const BAND_NAMES: [&str; 4] = ["Low", "Low mid", "High mid", "High"];
/// The EQ plot's gain range: plus and minus.
pub const EQ_RANGE_DB: f64 = 12.0;
const MIN_HZ: f64 = 20.0;
const MAX_HZ: f64 = 20_000.0;

/// The frequency of EQ band `i`: its upper crossover (the top band shows the one below it).
pub fn eq_frequency_index(i: usize) -> usize {
    i.min(2)
}

/// Where band `i` sits on the frequency axis: the middle (in octaves) of its range between the crossovers.
pub fn eq_center_hz(i: usize, crossovers: &[f64]) -> f64 {
    let lo = if i == 0 { MIN_HZ } else { crossovers.get(i - 1).copied().unwrap_or(MIN_HZ) };
    let hi = crossovers.get(i).copied().unwrap_or(MAX_HZ);
    (lo.max(MIN_HZ) * hi.min(MAX_HZ)).sqrt()
}

/// The EQ width as a Q.
pub const EQ_Q_RANGE: std::ops::RangeInclusive<f64> = 0.3..=10.0;

/// The span of EQ band `i` in octaves: between its crossovers (20 Hz and 20 kHz at the ends).
fn eq_octaves(i: usize, crossovers: &[f64]) -> f64 {
    let lo = if i == 0 { MIN_HZ } else { crossovers.get(i - 1).copied().unwrap_or(MIN_HZ) };
    let hi = crossovers.get(i).copied().unwrap_or(MAX_HZ);
    (hi.max(lo) / lo).log2()
}

/// The Q of EQ band `i`, derived from the octave span n of the band: Q = 2^(n/2) / (2^n - 1). The model has no filter Q
/// (the EQ is the compressor's band gain), so the width the user sees is the width the band really has.
pub fn eq_q(i: usize, crossovers: &[f64]) -> f64 {
    let x = eq_octaves(i, crossovers).exp2();
    if x <= 1.0 {
        return *EQ_Q_RANGE.end();
    }
    (x.sqrt() / (x - 1.0)).clamp(*EQ_Q_RANGE.start(), *EQ_Q_RANGE.end())
}

/// The span in octaves that gives an EQ band the width `q` (the inverse of `eq_q`).
fn q_octaves(q: f64) -> f64 {
    let q = q.clamp(*EQ_Q_RANGE.start(), *EQ_Q_RANGE.end());
    let y = (1.0 + (1.0 + 4.0 * q * q).sqrt()) / (2.0 * q);
    2.0 * y.log2()
}

/// The crossover that gives band `i` the width `q`: the upper edge moves (the top band, which has none, moves its lower
/// edge). Returns the crossover index and the new frequency. Used by the shelves; a bell keeps its middle (`bell_edges`).
pub fn eq_edge_for_q(i: usize, q: f64, crossovers: &[f64]) -> (usize, f64) {
    let octaves = q_octaves(q);
    if i < crossovers.len() {
        let lo = if i == 0 { MIN_HZ } else { crossovers[i - 1] };
        (i, lo * octaves.exp2())
    } else {
        let idx = crossovers.len().saturating_sub(1);
        (idx, MAX_HZ / octaves.exp2())
    }
}

/// Whether EQ band `i` is a bell (bands 2 and 3): its frequency is its middle, where its dot sits. Bands 1 and 4 are
/// shelves: their frequency is the corner, the crossover they end or begin at.
pub fn eq_is_bell(i: usize) -> bool {
    matches!(i, 1 | 2)
}

/// The frequency the Frequency row shows for band `i`: a bell's middle, a shelf's corner.
pub fn eq_frequency(i: usize, crossovers: &[f64]) -> f64 {
    if eq_is_bell(i) {
        eq_center_hz(i, crossovers)
    } else {
        crossovers.get(eq_frequency_index(i)).copied().unwrap_or(1000.0)
    }
}

/// The two crossovers of bell `i` when its middle sits at `center_hz` and it spans `octaves`: the index of the lower
/// one and the two new frequencies (the model keeps them ordered and apart).
fn bell_edges(i: usize, center_hz: f64, octaves: f64) -> (usize, f64, f64) {
    let half = (octaves / 2.0).exp2();
    (i.saturating_sub(1), center_hz / half, center_hz * half)
}

/// Bell `i` moved so that its middle is `hz`; its width stays. A typed 200 Hz puts the band's middle at 200 Hz, so a tone
/// there gets the full gain (the band's edge would give it only about half of it).
pub fn bell_for_frequency(i: usize, hz: f64, crossovers: &[f64]) -> (usize, f64, f64) {
    bell_edges(i, hz.clamp(MIN_HZ, MAX_HZ), eq_octaves(i, crossovers))
}

/// Bell `i` with the width `q`; its middle stays where it is.
pub fn bell_for_q(i: usize, q: f64, crossovers: &[f64]) -> (usize, f64, f64) {
    bell_edges(i, eq_center_hz(i, crossovers), q_octaves(q))
}

fn log_t(hz: f64) -> f64 {
    (hz.clamp(MIN_HZ, MAX_HZ) / MIN_HZ).log10() / (MAX_HZ / MIN_HZ).log10()
}

/// The x of `hz` in `plot` (20 Hz to 20 kHz, log).
pub fn eq_x(hz: f64, plot: CGRect) -> f64 {
    plot.min_x() + log_t(hz) * plot.width
}

/// The y of `db` in `plot`.
pub fn eq_y(db: f64, plot: CGRect) -> f64 {
    plot.mid_y() - db.clamp(-EQ_RANGE_DB, EQ_RANGE_DB) / EQ_RANGE_DB * plot.height / 2.0
}

/// The gain at height `y` in `plot`, to half a dB: the inverse of `eq_y`, for dragging a band's dot up and down.
pub fn eq_db_at(y: f64, plot: CGRect) -> f64 {
    let db = (plot.mid_y() - y) / (plot.height / 2.0) * EQ_RANGE_DB;
    ((db * 2.0).round() / 2.0).clamp(-EQ_RANGE_DB, EQ_RANGE_DB)
}

/// The band gains joined by straight lines between the band centers (flat beyond the first and last).
pub fn eq_curve(crossovers: &[f64], bands: &[MultibandBand], plot: CGRect) -> Vec<CGPoint> {
    let n = bands.len().min(4);
    if n == 0 {
        return Vec::new();
    }
    let centers: Vec<f64> = (0..n).map(|i| eq_center_hz(i, crossovers)).collect();
    let mut pts = vec![CGPoint::new(plot.min_x(), eq_y(bands[0].gain_db, plot))];
    pts.extend(centers.iter().zip(bands).map(|(hz, b)| CGPoint::new(eq_x(*hz, plot), eq_y(b.gain_db, plot))));
    pts.push(CGPoint::new(plot.max_x(), eq_y(bands[n - 1].gain_db, plot)));
    pts
}

/// The band whose dot is nearest to `x` in `plot`.
pub fn nearest_band(x: f64, crossovers: &[f64], plot: CGRect) -> usize {
    (0..4)
        .min_by(|a, b| {
            let da = (eq_x(eq_center_hz(*a, crossovers), plot) - x).abs();
            let db = (eq_x(eq_center_hz(*b, crossovers), plot) - x).abs();
            da.total_cmp(&db)
        })
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bands(g: [f64; 4]) -> Vec<MultibandBand> {
        g.iter().map(|g| MultibandBand::with_gain(-20.0, 3.0, 10.0, 120.0, *g)).collect()
    }

    #[test]
    fn q_follows_the_octave_span_and_the_edge_round_trips() {
        let x = [120.0, 900.0, 4500.0];
        let q = eq_q(1, &x);
        assert!((0.3..=10.0).contains(&q));
        // 120 to 900 Hz is 2.9 octaves: Q about 0.4; a narrower band has a higher Q.
        assert!(eq_q(2, &x) > q || (eq_q(2, &x) - q).abs() < 1.0);
        let (i, hz) = eq_edge_for_q(1, q, &x);
        assert_eq!(i, 1);
        assert!((hz - 900.0).abs() < 2.0, "{hz}");
        let (_, narrow) = eq_edge_for_q(1, 4.0, &x);
        assert!(narrow < 900.0 && narrow > 120.0, "{narrow}");
        let (top, hz) = eq_edge_for_q(3, 1.0, &x);
        assert_eq!(top, 2);
        assert!(hz > 4500.0 / 4.0 && hz < 20_000.0);
    }

    #[test]
    fn band_centers_lie_between_their_crossovers_in_order() {
        let x = [120.0, 900.0, 4500.0];
        let c: Vec<f64> = (0..4).map(|i| eq_center_hz(i, &x)).collect();
        assert!(c[0] < 120.0 && c[1] > 120.0 && c[1] < 900.0 && c[2] > 900.0 && c[2] < 4500.0 && c[3] > 4500.0);
        assert!(c.windows(2).all(|w| w[0] < w[1]));
    }

    #[test]
    fn the_curve_follows_the_band_gains_and_is_flat_at_the_ends() {
        let plot = CGRect::new(0.0, 0.0, 400.0, 100.0);
        let p = eq_curve(&[120.0, 900.0, 4500.0], &bands([-6.0, 0.0, 3.0, 1.0]), plot);
        assert_eq!(p.len(), 6);
        assert_eq!(p[0].y, p[1].y, "flat before the first dot");
        assert_eq!(p[4].y, p[5].y, "flat after the last dot");
        assert!(p[1].y > p[2].y && p[3].y < p[2].y, "-6 dB lies lower than 0 dB, +3 dB higher");
        assert_eq!(eq_y(0.0, plot), 50.0);
        assert_eq!(eq_y(99.0, plot), 0.0, "clamped to the plot");
    }

    #[test]
    fn a_click_picks_the_nearest_dot() {
        let plot = CGRect::new(0.0, 0.0, 400.0, 100.0);
        let x = [120.0, 900.0, 4500.0];
        assert_eq!(nearest_band(0.0, &x, plot), 0);
        assert_eq!(nearest_band(400.0, &x, plot), 3);
        let mid = eq_x(eq_center_hz(2, &x), plot);
        assert_eq!(nearest_band(mid + 2.0, &x, plot), 2);
    }

    #[test]
    fn the_top_band_shows_the_crossover_below_it() {
        assert_eq!((0..4).map(eq_frequency_index).collect::<Vec<_>>(), [0, 1, 2, 2]);
    }
}

// Swift: TransferFunctions.swift, TransferFunctions+Vendor.swift
//! Transfer functions (CPU reference for the shaders). Scalar forms, `f32` like the Swift code; the `Vec3` helpers map
//! them per channel.
//!
//! `*_legal` wrappers take the range-expanded value the compositor delivers (64...940 of 10 bit) for the camera codes;
//! the curves defined on floating-point signals (Log3G10, ACEScct, Apple Log) take the value directly.

#![allow(clippy::excessive_precision)] // vendor constants are written as published

use std::sync::LazyLock;

use super::vec::Vec3;

// MARK: S-Log3

const SLOG3_CUT_ENCODED: f32 = 171.210_294_692_9 / 1023.0;
const SLOG3_CUT_LINEAR: f32 = 0.01125;

/// Sony S-Log3 decode. `x` = CV / 1023. Returns scene linear (18 % gray = 0.18).
pub fn slog3_decode(x: f32) -> f32 {
    if x >= SLOG3_CUT_ENCODED {
        return 10f32.powf((x * 1023.0 - 420.0) / 261.5) * (0.18 + 0.01) - 0.01;
    }
    (x * 1023.0 - 95.0) * 0.01125 / (171.210_294_692_9 - 95.0)
}

/// Sony S-Log3 encode. Returns CV / 1023.
pub fn slog3_encode(y: f32) -> f32 {
    if y >= SLOG3_CUT_LINEAR {
        return (420.0 + ((y + 0.01) / (0.18 + 0.01)).log10() * 261.5) / 1023.0;
    }
    (y * (171.210_294_692_9 - 95.0) / 0.01125 + 95.0) / 1023.0
}

/// Legal-range (64...940 of 10 bit) range-expanded value `v` (0...1) to the full-range code fraction CV/1023.
pub fn legal_to_code_fraction(v: f32) -> f32 {
    (v * 876.0 + 64.0) / 1023.0
}

/// Inverse of [`legal_to_code_fraction`].
pub fn code_fraction_to_legal(x: f32) -> f32 {
    (x * 1023.0 - 64.0) / 876.0
}

/// Range-expanded S-Log3 to scene linear.
pub fn slog3_decode_legal(v: f32) -> f32 {
    slog3_decode(legal_to_code_fraction(v))
}
/// Scene linear to range-expanded S-Log3.
pub fn slog3_encode_legal(y: f32) -> f32 {
    code_fraction_to_legal(slog3_encode(y))
}

// MARK: HLG (BT.2100)

const HLG_A: f32 = 0.17883277;
const HLG_B: f32 = 0.28466892;
const HLG_C: f32 = 0.55991073;
/// BT.2100 system gamma for a 1000 nit display.
const HLG_GAMMA: f32 = 1.2;
/// BT.2100 luminance weights (BT.2020 primaries).
const HLG_LUMA: Vec3 = Vec3::new(0.2627, 0.6780, 0.0593);
/// Normalization so HLG reference white (signal 0.75) maps to 1.0. Derived, not hardcoded.
pub static HLG_SCALE: LazyLock<f32> = LazyLock::new(|| {
    let e = hlg_inverse_oetf(0.75);
    1.0 / (e * e.powf(HLG_GAMMA - 1.0))
});

/// BT.2100 inverse OETF: signal 0...1 to scene light 0...1 (unscaled).
pub fn hlg_inverse_oetf(e: f32) -> f32 {
    let e = e.max(0.0);
    if e <= 0.5 {
        return e * e / 3.0;
    }
    (((e - HLG_C) / HLG_A).exp() + HLG_B) / 12.0
}

/// BT.2100 OETF: scene light 0...1 (unscaled) to signal.
pub fn hlg_oetf(s: f32) -> f32 {
    let s = s.max(0.0);
    if s <= 1.0 / 12.0 {
        return (3.0 * s).sqrt();
    }
    HLG_A * (12.0 * s - HLG_B).ln() + HLG_C
}

/// HLG signal (BT.2020 R'G'B') to display-referred linear, reference white = 1.0 (peak about 4.93): inverse OETF per
/// channel, then the luminance-based OOTF `Fd = Ys^(g-1) * E`, times the scale. Needs all three channels.
pub fn hlg_decode(v: Vec3) -> Vec3 {
    let e = Vec3::new(hlg_inverse_oetf(v.x), hlg_inverse_oetf(v.y), hlg_inverse_oetf(v.z));
    let ys = HLG_LUMA.dot(e);
    let gain = if ys > 0.0 { ys.powf(HLG_GAMMA - 1.0) } else { 0.0 };
    e * gain * *HLG_SCALE
}

/// Exact inverse of [`hlg_decode`].
pub fn hlg_encode(v: Vec3) -> Vec3 {
    let fd = v / *HLG_SCALE;
    let yd = HLG_LUMA.dot(fd);
    if yd <= 0.0 {
        let z = hlg_oetf(0.0);
        return Vec3::new(z, z, z);
    }
    let ys = yd.powf(1.0 / HLG_GAMMA);
    let e = fd / ys.powf(HLG_GAMMA - 1.0);
    Vec3::new(hlg_oetf(e.x), hlg_oetf(e.y), hlg_oetf(e.z))
}

// MARK: BT.709

/// BT.709 OETF alpha.
pub const BT709_ALPHA: f32 = 1.09929682680944;
/// BT.709 OETF beta.
pub const BT709_BETA: f32 = 0.018053968510807;

/// BT.709 OETF: linear to signal.
pub fn bt709_oetf(l: f32) -> f32 {
    if l < BT709_BETA {
        return 4.5 * l;
    }
    BT709_ALPHA * l.powf(0.45) - (BT709_ALPHA - 1.0)
}

/// BT.709 inverse OETF: signal to linear.
pub fn bt709_inverse_oetf(v: f32) -> f32 {
    if v < 4.5 * BT709_BETA {
        return v / 4.5;
    }
    ((v + BT709_ALPHA - 1.0) / BT709_ALPHA).powf(1.0 / 0.45)
}

// MARK: Panasonic V-Log

const VLOG_CUT1: f32 = 0.01;
const VLOG_CUT2: f32 = 0.181;
const VLOG_B: f32 = 0.00873;
const VLOG_C: f32 = 0.241514;
const VLOG_D: f32 = 0.598206;

/// V-Log decode. `x` = CV / 1023. Returns scene linear.
pub fn vlog_decode(x: f32) -> f32 {
    if x < VLOG_CUT2 { (x - 0.125) / 5.6 } else { 10f32.powf((x - VLOG_D) / VLOG_C) - VLOG_B }
}
/// V-Log encode. Returns CV / 1023.
pub fn vlog_encode(y: f32) -> f32 {
    if y < VLOG_CUT1 { 5.6 * y + 0.125 } else { VLOG_C * (y + VLOG_B).log10() + VLOG_D }
}
/// Range-expanded V-Log to scene linear.
pub fn vlog_decode_legal(v: f32) -> f32 {
    vlog_decode(legal_to_code_fraction(v))
}
/// Scene linear to range-expanded V-Log.
pub fn vlog_encode_legal(y: f32) -> f32 {
    code_fraction_to_legal(vlog_encode(y))
}

// MARK: DJI D-Log

/// D-Log decode. `x` = CV / 1023. Returns scene linear.
pub fn dlog_decode(x: f32) -> f32 {
    if x <= 0.14 { (x - 0.0929) / 6.025 } else { (10f32.powf(3.89616 * x - 2.27752) - 0.0108) / 0.9892 }
}
/// D-Log encode. Returns CV / 1023.
pub fn dlog_encode(y: f32) -> f32 {
    if y <= 0.0078 { 6.025 * y + 0.0929 } else { (y * 0.9892 + 0.0108).log10() * 0.256663 + 0.584555 }
}
/// Range-expanded D-Log to scene linear.
pub fn dlog_decode_legal(v: f32) -> f32 {
    dlog_decode(legal_to_code_fraction(v))
}
/// Scene linear to range-expanded D-Log.
pub fn dlog_encode_legal(y: f32) -> f32 {
    code_fraction_to_legal(dlog_encode(y))
}

// MARK: Canon Log, Canon Log 2, Canon Log 3
// Canon white paper "Canon Log Gamma Curves", code-value form: CV / 1023 of the 10-bit signal, linear input = scene
// reflection divided by 0.9 (90 % white = 1.0). All three curves continue below black.

const CANON_WHITE: f32 = 0.9;
const CANON_LOG_A: f32 = 0.45310179;
const CANON_LOG_K: f32 = 10.1596;
const CANON_LOG_C: f32 = 0.12512248;
const CANON_LOG2_A: f32 = 0.24136077;
const CANON_LOG2_K: f32 = 87.09937546;
const CANON_LOG2_C: f32 = 0.092864125;
const CANON_LOG3_A: f32 = 0.36726845;
const CANON_LOG3_K: f32 = 14.98325;
const CANON_LOG3_C_NEG: f32 = 0.12783901;
const CANON_LOG3_C_POS: f32 = 0.12240537;
const CANON_LOG3_SLOPE: f32 = 1.9754798;
const CANON_LOG3_OFFSET: f32 = 0.12512219;
const CANON_LOG3_CUT_LOW: f32 = 0.097465473;
const CANON_LOG3_CUT_HIGH: f32 = 0.15277891;
const CANON_LOG3_CUT_LINEAR: f32 = 0.014;

fn canon_mirrored_decode(x: f32, a: f32, k: f32, c: f32) -> f32 {
    (if x < c { -(10f32.powf((c - x) / a) - 1.0) / k } else { (10f32.powf((x - c) / a) - 1.0) / k }) * CANON_WHITE
}

fn canon_mirrored_encode(y: f32, a: f32, k: f32, c: f32) -> f32 {
    let l = y / CANON_WHITE;
    if l < 0.0 { -(a * (-l * k + 1.0).log10() - c) } else { a * (l * k + 1.0).log10() + c }
}

/// Canon Log decode (CV / 1023 to scene linear).
pub fn canon_log_decode(x: f32) -> f32 {
    canon_mirrored_decode(x, CANON_LOG_A, CANON_LOG_K, CANON_LOG_C)
}
/// Canon Log encode.
pub fn canon_log_encode(y: f32) -> f32 {
    canon_mirrored_encode(y, CANON_LOG_A, CANON_LOG_K, CANON_LOG_C)
}
/// Canon Log 2 decode.
pub fn canon_log2_decode(x: f32) -> f32 {
    canon_mirrored_decode(x, CANON_LOG2_A, CANON_LOG2_K, CANON_LOG2_C)
}
/// Canon Log 2 encode.
pub fn canon_log2_encode(y: f32) -> f32 {
    canon_mirrored_encode(y, CANON_LOG2_A, CANON_LOG2_K, CANON_LOG2_C)
}
/// Canon Log 3 decode.
pub fn canon_log3_decode(x: f32) -> f32 {
    let l = if x < CANON_LOG3_CUT_LOW {
        -(10f32.powf((CANON_LOG3_C_NEG - x) / CANON_LOG3_A) - 1.0) / CANON_LOG3_K
    } else if x <= CANON_LOG3_CUT_HIGH {
        (x - CANON_LOG3_OFFSET) / CANON_LOG3_SLOPE
    } else {
        (10f32.powf((x - CANON_LOG3_C_POS) / CANON_LOG3_A) - 1.0) / CANON_LOG3_K
    };
    l * CANON_WHITE
}
/// Canon Log 3 encode.
pub fn canon_log3_encode(y: f32) -> f32 {
    let l = y / CANON_WHITE;
    if l < -CANON_LOG3_CUT_LINEAR {
        return -CANON_LOG3_A * (-l * CANON_LOG3_K + 1.0).log10() + CANON_LOG3_C_NEG;
    }
    if l <= CANON_LOG3_CUT_LINEAR {
        return CANON_LOG3_SLOPE * l + CANON_LOG3_OFFSET;
    }
    CANON_LOG3_A * (l * CANON_LOG3_K + 1.0).log10() + CANON_LOG3_C_POS
}
/// Range-expanded Canon Log to scene linear.
pub fn canon_log_decode_legal(v: f32) -> f32 {
    canon_log_decode(legal_to_code_fraction(v))
}
/// Scene linear to range-expanded Canon Log.
pub fn canon_log_encode_legal(y: f32) -> f32 {
    code_fraction_to_legal(canon_log_encode(y))
}
/// Range-expanded Canon Log 2 to scene linear.
pub fn canon_log2_decode_legal(v: f32) -> f32 {
    canon_log2_decode(legal_to_code_fraction(v))
}
/// Scene linear to range-expanded Canon Log 2.
pub fn canon_log2_encode_legal(y: f32) -> f32 {
    code_fraction_to_legal(canon_log2_encode(y))
}
/// Range-expanded Canon Log 3 to scene linear.
pub fn canon_log3_decode_legal(v: f32) -> f32 {
    canon_log3_decode(legal_to_code_fraction(v))
}
/// Scene linear to range-expanded Canon Log 3.
pub fn canon_log3_encode_legal(y: f32) -> f32 {
    code_fraction_to_legal(canon_log3_encode(y))
}

// MARK: Apple Log

const APPLE_R0: f32 = -0.05641088;
const APPLE_RT: f32 = 0.01;
const APPLE_C: f32 = 47.28711236;
const APPLE_BETA: f32 = 0.00964052;
const APPLE_GAMMA: f32 = 0.08550479;
const APPLE_DELTA: f32 = 0.69336945;
/// Encoded value at `APPLE_RT` (where the quadratic toe meets the log part).
const APPLE_PT: f32 = APPLE_C * (APPLE_RT - APPLE_R0) * (APPLE_RT - APPLE_R0);

/// Apple Log decode: the range-expanded value is used directly. Returns scene linear.
pub fn apple_log_decode(p: f32) -> f32 {
    if p >= APPLE_PT {
        return 2f32.powf((p - APPLE_DELTA) / APPLE_GAMMA) - APPLE_BETA;
    }
    if p >= 0.0 {
        return (p / APPLE_C).sqrt() + APPLE_R0;
    }
    APPLE_R0
}
/// Apple Log encode.
pub fn apple_log_encode(x: f32) -> f32 {
    if x >= APPLE_RT {
        return APPLE_GAMMA * (x + APPLE_BETA).log2() + APPLE_DELTA;
    }
    if x >= APPLE_R0 {
        return APPLE_C * (x - APPLE_R0) * (x - APPLE_R0);
    }
    0.0
}

// MARK: PQ (SMPTE ST 2084)

const PQ_M1: f32 = 2610.0 / 16384.0;
const PQ_M2: f32 = 2523.0 / 4096.0 * 128.0;
const PQ_C1: f32 = 3424.0 / 4096.0;
const PQ_C2: f32 = 2413.0 / 4096.0 * 32.0;
const PQ_C3: f32 = 2392.0 / 4096.0 * 32.0;
/// Nits that map to 1.0 (BT.2408 HDR reference white, same normalization as HLG).
pub const PQ_REFERENCE_WHITE: f32 = 203.0;

/// PQ signal to display linear, reference white (203 nits) = 1.0, peak 10000 nits about 49.3.
pub fn pq_decode(e: f32) -> f32 {
    let p = e.max(0.0).powf(1.0 / PQ_M2);
    let y = ((p - PQ_C1).max(0.0) / (PQ_C2 - PQ_C3 * p)).powf(1.0 / PQ_M1);
    y * 10000.0 / PQ_REFERENCE_WHITE
}
/// Display linear (1.0 = 203 nits) to PQ signal.
pub fn pq_encode(l: f32) -> f32 {
    let y = (l.max(0.0) * PQ_REFERENCE_WHITE / 10000.0).powf(PQ_M1);
    ((PQ_C1 + PQ_C2 * y) / (1.0 + PQ_C3 * y)).powf(PQ_M2)
}

// MARK: SQ Intermediate (the published DaVinci Intermediate constants)

const SQ_LOG_A: f32 = 0.0075;
const SQ_LOG_B: f32 = 7.0;
const SQ_LOG_C: f32 = 0.07329248;
const SQ_LOG_M: f32 = 10.44426855;
const SQ_LOG_LIN_CUT: f32 = 0.00262409;
const SQ_LOG_LOG_CUT: f32 = 0.02740668;

/// SQ Intermediate decode (encoded to scene linear). The linear toe is unbounded.
pub fn sq_log_decode(y: f32) -> f32 {
    if y > SQ_LOG_LOG_CUT { 2f32.powf(y / SQ_LOG_C - SQ_LOG_B) - SQ_LOG_A } else { y / SQ_LOG_M }
}
/// SQ Intermediate encode.
pub fn sq_log_encode(x: f32) -> f32 {
    if x > SQ_LOG_LIN_CUT { ((x + SQ_LOG_A).log2() + SQ_LOG_B) * SQ_LOG_C } else { x * SQ_LOG_M }
}

// MARK: ARRI LogC3 (EI 800)

const LOGC3_CUT: f32 = 0.010591;
const LOGC3_A: f32 = 5.555556;
const LOGC3_B: f32 = 0.052272;
const LOGC3_C: f32 = 0.247190;
const LOGC3_D: f32 = 0.385537;
const LOGC3_E: f32 = 5.367655;
const LOGC3_F: f32 = 0.092809;

/// LogC3 EI 800 decode (CV / 1023 to scene linear).
pub fn log_c3_decode(x: f32) -> f32 {
    if x > LOGC3_E * LOGC3_CUT + LOGC3_F {
        (10f32.powf((x - LOGC3_D) / LOGC3_C) - LOGC3_B) / LOGC3_A
    } else {
        (x - LOGC3_F) / LOGC3_E
    }
}
/// LogC3 EI 800 encode.
pub fn log_c3_encode(y: f32) -> f32 {
    if y > LOGC3_CUT { LOGC3_C * (LOGC3_A * y + LOGC3_B).log10() + LOGC3_D } else { LOGC3_E * y + LOGC3_F }
}

// MARK: ARRI LogC4 (constants in f64 like the Swift code)

struct LogC4 {
    a: f64,
    b: f64,
    c: f64,
    s: f64,
    t: f64,
}

static LOGC4: LazyLock<LogC4> = LazyLock::new(|| {
    let a = (262144.0 - 16.0) / 117.45;
    let b = (1023.0 - 95.0) / 1023.0;
    let c = 95.0 / 1023.0;
    let s = (7.0 * 2f64.ln() * 2f64.powf(7.0 - 14.0 * c / b)) / (a * b);
    let t = (2f64.powf(14.0 * (-c / b) + 6.0) - 64.0) / a;
    LogC4 { a, b, c, s, t }
});

/// LogC4 decode. `x` = signal 0...1. Below signal 0 the curve continues linearly.
pub fn log_c4_decode(x: f32) -> f32 {
    let k = &*LOGC4;
    let v = f64::from(x);
    if v >= 0.0 {
        return ((2f64.powf(14.0 * (v - k.c) / k.b + 6.0) - 64.0) / k.a) as f32;
    }
    (v * k.s + k.t) as f32
}
/// LogC4 encode.
pub fn log_c4_encode(y: f32) -> f32 {
    let k = &*LOGC4;
    let v = f64::from(y);
    if v >= k.t {
        return (((k.a * v + 64.0).log2() - 6.0) / 14.0 * k.b + k.c) as f32;
    }
    ((v - k.t) / k.s) as f32
}

// MARK: RED Log3G10

const LOG3G10_A: f32 = 0.224282;
const LOG3G10_B: f32 = 155.975327;
const LOG3G10_C: f32 = 0.01;
const LOG3G10_G: f32 = 15.1927;

/// Log3G10 decode. Negative signals continue linearly.
pub fn log3g10_decode(y: f32) -> f32 {
    if y < 0.0 { y / LOG3G10_G - LOG3G10_C } else { (10f32.powf(y / LOG3G10_A) - 1.0) / LOG3G10_B - LOG3G10_C }
}
/// Log3G10 encode.
pub fn log3g10_encode(x: f32) -> f32 {
    let s = x + LOG3G10_C;
    if s < 0.0 { s * LOG3G10_G } else { LOG3G10_A * (s * LOG3G10_B + 1.0).log10() }
}

// MARK: Blackmagic Film Generation 5

const BMD_A: f32 = 0.08692876065491224;
const BMD_B: f32 = 0.005494072432257808;
const BMD_C: f32 = 0.5300133392291939;
const BMD_D: f32 = 8.283605932402494;
const BMD_E: f32 = 0.09246575342465753;
const BMD_LIN_CUT: f32 = 0.005;
const BMD_LOG_CUT: f32 = BMD_D * BMD_LIN_CUT + BMD_E;

/// Film Gen 5 decode.
pub fn bmd_film_gen5_decode(y: f32) -> f32 {
    if y < BMD_LOG_CUT { (y - BMD_E) / BMD_D } else { ((y - BMD_C) / BMD_A).exp() - BMD_B }
}
/// Film Gen 5 encode.
pub fn bmd_film_gen5_encode(x: f32) -> f32 {
    if x < BMD_LIN_CUT { BMD_D * x + BMD_E } else { BMD_A * (x + BMD_B).ln() + BMD_C }
}

// MARK: Nikon N-Log

const NLOG_CUT: f32 = 0.328;

/// N-Log decode. `x` = CV / 1023. Cube-root toe below linear 0.328, natural log above.
pub fn n_log_decode(x: f32) -> f32 {
    let cv = x * 1023.0;
    let split = 150.0 * NLOG_CUT.ln() + 619.0;
    if cv < split {
        return (cv / 650.0).powf(3.0) - 0.0075;
    }
    ((cv - 619.0) / 150.0).exp()
}
/// N-Log encode.
pub fn n_log_encode(y: f32) -> f32 {
    if y < NLOG_CUT {
        return 650.0 * (y + 0.0075).max(0.0).cbrt() / 1023.0;
    }
    (150.0 * y.ln() + 619.0) / 1023.0
}

// MARK: Fujifilm F-Log2

const FLOG2_CUT1: f32 = 0.000889;
const FLOG2_CUT2: f32 = 0.100686685370811;
const FLOG2_A: f32 = 5.555556;
const FLOG2_B: f32 = 0.064829;
const FLOG2_C: f32 = 0.245281;
const FLOG2_D: f32 = 0.384316;
const FLOG2_E: f32 = 8.799461;
const FLOG2_F: f32 = 0.092864;

/// F-Log2 decode (CV / 1023).
pub fn f_log2_decode(x: f32) -> f32 {
    if x >= FLOG2_CUT2 { (10f32.powf((x - FLOG2_D) / FLOG2_C) - FLOG2_B) / FLOG2_A } else { (x - FLOG2_F) / FLOG2_E }
}
/// F-Log2 encode.
pub fn f_log2_encode(y: f32) -> f32 {
    if y >= FLOG2_CUT1 { FLOG2_C * (FLOG2_A * y + FLOG2_B).log10() + FLOG2_D } else { FLOG2_E * y + FLOG2_F }
}

// MARK: ACEScct

const ACES_CCT_A: f32 = 10.5402377416545;
const ACES_CCT_B: f32 = 0.0729055341958355;
const ACES_CCT_LIN_CUT: f32 = 0.0078125;
const ACES_CCT_LOG_CUT: f32 = 0.155251141552511;

/// ACEScct decode.
pub fn aces_cct_decode(y: f32) -> f32 {
    if y <= ACES_CCT_LOG_CUT { (y - ACES_CCT_B) / ACES_CCT_A } else { 2f32.powf(y * 17.52 - 9.72) }
}
/// ACEScct encode.
pub fn aces_cct_encode(x: f32) -> f32 {
    if x <= ACES_CCT_LIN_CUT { ACES_CCT_A * x + ACES_CCT_B } else { (x.log2() + 9.72) / 17.52 }
}

// MARK: Legal-range wrappers of the vendor curves

macro_rules! legal_pair {
    ($dec:ident, $enc:ident, $d:ident, $e:ident) => {
        /// Range-expanded code to scene linear.
        pub fn $dec(v: f32) -> f32 {
            $d(legal_to_code_fraction(v))
        }
        /// Scene linear to range-expanded code.
        pub fn $enc(y: f32) -> f32 {
            code_fraction_to_legal($e(y))
        }
    };
}
legal_pair!(log_c3_decode_legal, log_c3_encode_legal, log_c3_decode, log_c3_encode);
legal_pair!(log_c4_decode_legal, log_c4_encode_legal, log_c4_decode, log_c4_encode);
legal_pair!(bmd_film_gen5_decode_legal, bmd_film_gen5_encode_legal, bmd_film_gen5_decode, bmd_film_gen5_encode);
legal_pair!(n_log_decode_legal, n_log_encode_legal, n_log_decode, n_log_encode);
legal_pair!(f_log2_decode_legal, f_log2_encode_legal, f_log2_decode, f_log2_encode);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_hold_for_every_curve() {
        type Pair = (&'static str, fn(f32) -> f32, fn(f32) -> f32);
        let pairs: [Pair; 17] = [
            ("slog3", slog3_decode_legal, slog3_encode_legal),
            ("vlog", vlog_decode_legal, vlog_encode_legal),
            ("dlog", dlog_decode_legal, dlog_encode_legal),
            ("canon1", canon_log_decode_legal, canon_log_encode_legal),
            ("canon2", canon_log2_decode_legal, canon_log2_encode_legal),
            ("canon3", canon_log3_decode_legal, canon_log3_encode_legal),
            ("apple", apple_log_decode, apple_log_encode),
            ("pq", pq_decode, pq_encode),
            ("sqlog", sq_log_decode, sq_log_encode),
            ("logc3", log_c3_decode_legal, log_c3_encode_legal),
            ("logc4", log_c4_decode_legal, log_c4_encode_legal),
            ("log3g10", log3g10_decode, log3g10_encode),
            ("bmd", bmd_film_gen5_decode_legal, bmd_film_gen5_encode_legal),
            ("nlog", n_log_decode_legal, n_log_encode_legal),
            ("flog2", f_log2_decode_legal, f_log2_encode_legal),
            ("aces", aces_cct_decode, aces_cct_encode),
            ("bt709", bt709_inverse_oetf, bt709_oetf),
        ];
        for (name, dec, enc) in pairs {
            for i in 1..=40 {
                let lin = i as f32 / 40.0;
                // Decode of the encoded value returns the linear value (the curves are mutual inverses).
                let back = dec(enc(lin));
                assert!((back - lin).abs() < 2e-3 * lin.max(1.0), "{name}: {lin} -> {back}");
            }
        }
    }

    #[test]
    fn gray_reference_codes() {
        // 18 % gray encodes to the published code values (VendorLogCurvesTests / TransferAndGamutTests).
        assert!((log_c3_encode(0.18) - 0.391007).abs() < 1e-5);
        assert!((log_c4_encode(0.18) - 0.278396).abs() < 1e-5);
        assert!((log3g10_encode(0.18) - 1.0 / 3.0).abs() < 1e-3);
        assert!((bmd_film_gen5_encode(0.18) - 0.383581).abs() < 1e-4);
        assert!((f_log2_encode(0.18) - 0.391).abs() < 1e-3);
        assert!((slog3_encode(0.18) * 1023.0 - 420.0).abs() < 0.5);
    }

    #[test]
    fn hlg_reference_white_and_peak() {
        let white = hlg_decode(Vec3::splat(0.75));
        assert!((white.x - 1.0).abs() < 1e-5, "{white:?}");
        let peak = hlg_decode(Vec3::splat(1.0)).x;
        assert!((peak - 4.93).abs() < 0.05, "{peak}");
        let back = hlg_encode(hlg_decode(Vec3::new(0.3, 0.6, 0.9)));
        assert!((back.y - 0.6).abs() < 1e-4);
    }
}

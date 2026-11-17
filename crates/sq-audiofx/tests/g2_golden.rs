//! Group g2 stages against the Swift output (`oracle/sq-audiofx/golden/g2.tsv`).

use sq_audiofx::graphic_eqstage::GraphicEQStage;
use sq_audiofx::limiter::MasterLimiter;
use sq_audiofx::lookahead_limiter::LookaheadLimiter;
use sq_audiofx::multiband::MultibandCompressor;
use sq_audiofx::notch_stage::{NotchParams, NotchStage};
use sq_audiofx::pitch_shift::{DisguiseVoiceStage, PitchShiftStage};
use sq_audiofx::presets::TrackAudioPreset;
use sq_audiofx::repair_stages::{DeHumParams, DeHumStage, DialogueLevelerStage, HighCutStage, LowCutStage};
use sq_audiofx::role_chain::DeEsser;
use sq_audiofx::space_and_gate_stages::{DelayStage, NoiseGateStage, ReverbStage};
use sq_core_audio::{AudioGraphicEQValues, AudioLevelerValues};
use sq_core_time::{Id, Time};
use std::collections::BTreeMap;

const PI: f64 = std::f64::consts::PI;

fn noise(amp: f32, count: usize, seed: u64) -> Vec<f32> {
    let mut s = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
    (0..count)
        .map(|_| {
            s = s.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            let u = ((s >> 40) & 0xFF_FFFF) as f32 / 0xFF_FFFF as f32;
            (u * 2.0 - 1.0) * amp
        })
        .collect()
}

fn sine(f: f64, db: f64, n: usize) -> Vec<f32> {
    let a = 10.0_f64.powf(db / 20.0);
    (0..n).map(|i| (a * (2.0 * PI * f * i as f64 / 48_000.0).sin()) as f32).collect()
}

/// Runs `f(views, frames, block_index)` over `x` in blocks.
fn blocks(x: &[Vec<f32>], block: usize, mut f: impl FnMut(&mut [&mut [f32]], usize, usize)) -> Vec<Vec<f32>> {
    let mut out = x.to_vec();
    let (mut pos, mut k) = (0, 0);
    while pos < x[0].len() {
        let n = block.min(x[0].len() - pos);
        let mut views: Vec<&mut [f32]> = out.iter_mut().map(|c| &mut c[pos..pos + n]).collect();
        f(&mut views, n, k);
        pos += n;
        k += 1;
    }
    out
}

fn fnv(y: &[Vec<f32>]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for v in y.iter().flatten() {
        for b in v.to_bits().to_le_bytes() {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x100_0000_01b3);
        }
    }
    h
}

fn samples(y: &[Vec<f32>]) -> Vec<f32> {
    let mut vals = vec![];
    for c in y {
        let mut idx: Vec<usize> = (0..c.len().min(8)).collect();
        idx.extend((1013..c.len()).step_by(1013));
        vals.extend(idx.into_iter().map(|i| c[i]));
    }
    vals
}

struct Row {
    hash: u64,
    shape: String,
    values: Vec<f32>,
}

fn golden() -> BTreeMap<String, Row> {
    let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../oracle/sq-audiofx/golden/g2.tsv"))
        .unwrap_or_default();
    text.lines()
        .filter_map(|line| {
            let mut f = line.split('\t');
            let (name, hash, shape, values) = (f.next()?, f.next()?, f.next()?, f.next()?);
            let row = Row {
                hash: u64::from_str_radix(hash, 16).ok()?,
                shape: shape.to_string(),
                values: values.split(' ').filter_map(|v| v.parse().ok()).collect(),
            };
            Some((name.to_string(), row))
        })
        .collect()
}

#[test]
fn g2_stages_match_the_swift_output() {
    let n2 = vec![noise(0.4, 48_000, 7), noise(0.4, 48_000, 8)];
    let hot = vec![noise(1.5, 48_000, 3), noise(1.5, 48_000, 4)];
    let tone: Vec<Vec<f32>> = (0..2)
        .map(|c| {
            sine(220.0, -12.0, 48_000)
                .iter()
                .zip(sine(3100.0 + 100.0 * f64::from(c), -18.0, 48_000))
                .map(|(a, b)| a + b)
                .collect()
        })
        .collect();
    let harm: Vec<f32> = (0..96_000)
        .map(|i| {
            let mut v = 0.0_f64;
            for h in 1..=10 {
                let h = f64::from(h);
                v += (2.0 * PI * 140.0 * h * i as f64 / 48_000.0 + h * 0.7).sin() / h;
            }
            (0.2 * v) as f32
        })
        .collect();

    let mut cases: Vec<(&str, Vec<Vec<f32>>, f32)> = vec![];
    let mut y = n2.clone();
    MultibandCompressor::new(&TrackAudioPreset::voice().compressor, 48_000.0, 2).process_planar(&mut y);
    cases.push(("multiband_voice", y, 1e-6));
    let mut y = tone.clone();
    MultibandCompressor::new(&TrackAudioPreset::music().compressor, 44_100.0, 2).process_planar(&mut y);
    cases.push(("multiband_music_44k", y, 1e-6));

    let mut la = LookaheadLimiter::new(48_000.0, 2);
    cases.push(("lookahead", blocks(&hot, 480, |b, n, _| la.process(b, n, true)), 1e-6));
    let mut ml = MasterLimiter::with_times(48_000, -3.0, 100.0, 5.0, 2.0);
    let (mut l, mut r) = (hot[0].clone(), hot[1].clone());
    ml.process(&mut l, &mut r);
    cases.push(("master_limiter", vec![l, r], 1e-6));

    let mut gate = NoiseGateStage::new(48_000.0);
    cases.push((
        "noise_gate",
        blocks(&tone, 480, |b, n, k| {
            gate.process(b, n, (-30.0 + (k % 3) as f64, -34.0), (2.0, 80.0, 30.0), (40.0, 46.0))
        }),
        1e-6,
    ));
    let mut dl = DelayStage::new(48_000.0, 2);
    cases.push((
        "delay",
        blocks(&n2, 480, |b, n, k| dl.process(b, n, (120.0 + k as f64, 121.0 + k as f64), (0.4, 0.45), (0.3, 0.35))),
        1e-6,
    ));
    let mut rv = ReverbStage::new(48_000.0, 2);
    cases.push(("reverb", blocks(&n2, 480, |b, n, _| rv.process(b, n, 0.6, 0.4, (0.3, 0.4))), 1e-6));

    let mut dh = DeHumStage::new(48_000.0, 2);
    let hum = DeHumParams { frequency_hz: 220.0, q: 8.0, gain_db: -24.0, harmonics: 3, slope: 0.6, listen: false };
    cases.push(("dehum", blocks(&tone, 480, |b, n, _| dh.process(b, n, hum)), 1e-6));
    let mut lc = LowCutStage::new(48_000.0, 2);
    cases.push(("lowcut3", blocks(&n2, 480, |b, n, _| lc.process(b, n, 180.0, 3)), 1e-6));
    let mut hc = HighCutStage::new(48_000.0, 2);
    cases.push(("highcut2", blocks(&n2, 480, |b, n, _| hc.process(b, n, 5000.0, 2)), 1e-6));
    let mut lev = DialogueLevelerStage::new(48_000.0);
    let lv =
        AudioLevelerValues { preset: 3, reduce_loud: true, lift_soft: true, background: true, output_gain_db: 2.0 };
    cases.push(("leveler", blocks(&tone, 480, |b, n, _| lev.process(b, n, &lv, 0.8)), 1e-6));
    let mut nt = NotchStage::new(48_000.0, 2);
    cases.push((
        "notch",
        blocks(&tone, 480, |b, n, k| {
            let d = 10.0 * (k % 5) as f64;
            nt.process(
                b,
                n,
                NotchParams { hz: 900.0 + d, q: 12.0, depth_db: 30.0 },
                NotchParams { hz: 910.0 + d, q: 14.0, depth_db: 28.0 },
            );
        }),
        1e-6,
    ));
    let mut ge = GraphicEQStage::new(2);
    let mut gv = AudioGraphicEQValues::default();
    gv.set(2, 6.0);
    gv.set(5, -4.0);
    gv.set(8, 3.0);
    let mut gv2 = gv;
    gv2.set(5, -8.0);
    gv2.output_db = 1.5;
    cases.push((
        "graphic_eq",
        blocks(&n2, 480, |b, n, k| {
            if k % 2 == 0 { ge.process(b, n, &gv, &gv2, 48_000.0) } else { ge.process(b, n, &gv2, &gv, 48_000.0) }
        }),
        1e-6,
    ));
    let mut de = DeEsser::new(48_000, 2);
    de.configure(6500.0, 0);
    de.set_speed(0);
    let ess = sine(6500.0, -15.0, 48_000);
    let mut dy: Vec<Vec<f32>> = tone.iter().map(|c| c.iter().zip(&ess).map(|(a, b)| a + b).collect()).collect();
    de.process_planar(&mut dy);
    cases.push(("deesser_narrow", dy, 1e-6));

    // Accelerate's FFT against the portable radix-2 one: close, not identical.
    let mut ps = PitchShiftStage::new(1);
    cases.push((
        "pitch_up5",
        blocks(std::slice::from_ref(&harm), 512, |b, n, _| ps.process(b, n, 5.0, 5.0, true, true)),
        2e-3,
    ));
    let mut ps2 = PitchShiftStage::new(1);
    cases.push((
        "pitch_down7_free",
        blocks(std::slice::from_ref(&harm), 512, |b, n, _| ps2.process(b, n, -7.0, -7.0, false, true)),
        2e-3,
    ));
    let id = Id::parse("5B0C1E7A-2A4D-4F0B-9C55-0E6F3A1D7B21").unwrap_or(Id::NIL);
    let mut dv = DisguiseVoiceStage::new(48_000.0, 1, id);
    let mut pos = 0_i64;
    cases.push((
        "disguise_low",
        blocks(std::slice::from_ref(&harm), 512, |b, n, _| {
            dv.process(b, n, 0, Time::new(pos, 48_000), true);
            pos += n as i64;
        }),
        2e-3,
    ));

    let gold = golden();
    assert!(!gold.is_empty(), "golden file missing");
    for (name, y, tol) in &cases {
        let Some(row) = gold.get(*name) else { panic!("{name}: no golden row") };
        assert_eq!(row.shape, format!("{}x{}", y.len(), y[0].len()), "{name}: shape");
        if fnv(y) == row.hash {
            eprintln!("{name}: bit-exact");
            continue;
        }
        let got = samples(y);
        assert_eq!(got.len(), row.values.len(), "{name}: sample count");
        let worst = got.iter().zip(&row.values).map(|(a, b)| (a - b).abs() / (1.0 + b.abs())).fold(0.0_f32, f32::max);
        eprintln!("{name}: worst relative difference {worst:e} (tolerance {tol:e})");
        assert!(worst <= *tol, "{name}: {worst}");
    }
}

//! Multiband Compressor and Parametric EQ through the mapper. Swift: VoiceChainImportTests.swift (values from a real project).
#![allow(clippy::unwrap_used, reason = "helpers of integration tests; clippy.toml only covers test functions")]

mod common;

use common::{ItemSpec, PRFixture, SECOND as S, Source};
use sq_core_audio::audio_effects as ae;
use sq_core_model::{ClipEffect, TrackKind};
use sq_core_time::SequentialIds;
use sq_premiere_import::prdocument::PRReader;
use sq_premiere_import::primport_report::Status;
use sq_premiere_import::prmapper::{PRImportResult, PRMapper};
use std::collections::BTreeMap;

const MULTIBAND: &str = "3981e750-c8ae-40a2-889f-41a01c7efa03";
const PEQ: &str = "8edcd326-33de-4a4d-985b-f1bf48ed1427";

/// Imports one audio clip with a component of `count` params (everything but `values` is 0) and returns the effect of `kind`.
fn import(
    match_name: &str,
    name: &str,
    count: usize,
    values: &[(usize, &str)],
    kind: &str,
) -> (ClipEffect, PRImportResult) {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let ps: Vec<String> = (0..count)
        .map(|i| {
            let v = values.iter().find(|(p, _)| *p == i).map_or("0.", |(_, v)| *v);
            f.param(None, v, None, "AudioComponentParam")
        })
        .collect();
    let comp = f.audio_component(name, match_name, &ps);
    let a = f.item(ItemSpec::new(0, S, 0, S, Source::Media(m)).components(&[&comp]).audio());
    let at = f.audio_track(&[a]);
    f.sequence("Main", &[], &[at]);
    let r =
        PRMapper::map(&PRReader::read(&f.data()).unwrap(), "T", &BTreeMap::new(), false, &mut SequentialIds::default());
    let clip = r.project.timelines[0]
        .tracks
        .iter()
        .filter(|t| t.kind == TrackKind::Audio)
        .flat_map(|t| t.clips().to_vec())
        .next()
        .unwrap();
    let e = clip.effects.iter().find(|e| e.kind == kind).cloned().unwrap();
    (e, r)
}

fn v(e: &ClipEffect, k: &str) -> f64 {
    e.parameters.get(k).map_or(-999.0, |p| p.value)
}

fn near(a: f64, b: f64, tol: f64) -> bool {
    (a - b).abs() < tol
}

#[test]
fn multiband_maps_the_documented_formulas() {
    // Rode NTG Indoor values.
    let vals = [
        (1, "0.5"),
        (2, "0.75"),
        (3, "0.816666662693"),
        (4, "0.716666638851"),
        (5, "0.75"),
        (6, "0.068965516984"),
        (7, "0.034482758492"),
        (8, "0.034482758492"),
        (9, "0.068965516984"),
        (10, "0.002"),
        (11, "0.002"),
        (12, "0.002"),
        (13, "0.002"),
        (14, "0.02"),
        (15, "0.02"),
        (16, "0.02"),
        (17, "0.02"),
        (18, "0.611111104488"),
        (19, "0.444444447756"),
        (20, "0.388888895512"),
        (21, "0.444444447756"),
        (34, "0.005855855998"),
        (35, "0.056406404823"),
        (36, "0.344844847918"),
    ];
    let (e, r) = import(MULTIBAND, "Multiband", 41, &vals, ae::AUDIO_MULTIBAND_KIND);
    assert!(near(v(&e, ae::MB_OUTPUT_GAIN_KEY), 0.0, 1e-6));
    assert!(near(v(&e, &ae::mb_threshold_key(1)), -15.0, 1e-6) && near(v(&e, &ae::mb_threshold_key(2)), -11.0, 1e-6));
    assert!(near(v(&e, &ae::mb_ratio_key(1)), 3.0, 1e-6) && near(v(&e, &ae::mb_ratio_key(2)), 2.0, 1e-6));
    assert!(near(v(&e, &ae::mb_attack_key(3)), 1.0, 1e-6) && near(v(&e, &ae::mb_release_key(3)), 100.0, 1e-6));
    assert!(near(v(&e, &ae::mb_gain_key(1)), 4.0, 1e-6) && near(v(&e, &ae::mb_gain_key(3)), -4.0, 1e-6));
    assert!(near(v(&e, &ae::mb_crossover_key(1)), 137.0, 0.5));
    assert!(near(v(&e, &ae::mb_crossover_key(2)), 1147.0, 0.5));
    assert!(near(v(&e, &ae::mb_crossover_key(3)), 6910.0, 0.5));
    assert_eq!(v(&e, ae::MB_LIMITER_ON_KEY), 0.0, "a component without the LMAX params has no limiter");
    assert!(e.enabled);
    assert_eq!(r.report.status_of("Multiband"), Some(Status::Approximated));
}

#[test]
fn multiband_limiter_maps_from_the_lmax_params() {
    let imported = |bypass: &str| {
        let vals = [(1, "0.5"), (48, "0.85"), (49, "0.497222222"), (51, "0.008"), (52, "0.1"), (53, bypass)];
        import(MULTIBAND, "Multiband", 60, &vals, ae::AUDIO_MULTIBAND_KIND).0
    };
    let e = imported("0.");
    assert_eq!(v(&e, ae::MB_LIMITER_ON_KEY), 1.0);
    assert!(near(v(&e, ae::MB_LIMITER_THRESHOLD_KEY), -9.0, 1e-6));
    assert!(near(v(&e, ae::MB_LIMITER_MARGIN_KEY), -0.1, 1e-4));
    assert!(near(v(&e, ae::MB_LIMITER_RELEASE_KEY), 500.0, 1e-6));
    assert!(near(v(&e, ae::MB_LIMITER_ATTACK_KEY), 4.0, 1e-6));
    assert_eq!(v(&imported("1"), ae::MB_LIMITER_ON_KEY), 0.0);
}

#[test]
fn parametric_eq_maps_gain_frequency_and_enable_flags() {
    // Band 4: freq .105947 gain .424342 (about -3.6 dB), band 1 switched off with "0.", HP on at .002493.
    let vals = [
        (1, "0.000834"),
        (2, "0.5"),
        (3, "0.749791"),
        (4, "0.520833"),
        (5, "0.001251"),
        (6, "0.000199989998"),
        (7, "0.544407"),
        (8, "0."),
        (17, "0.105947375298"),
        (18, "0.0002"),
        (19, "0.42434206605"),
        (20, "1"),
        (30, "1"),
        (31, "1"),
        (32, "0.25"),
        (38, "1"),
        (39, "0.002493"),
        (41, "0."),
        (42, "0.749791"),
    ];
    let (e, _) = import(PEQ, "EQ", 46, &vals, ae::AUDIO_PARAMETRIC_EQ_KIND);
    let k = ae::peq_key;
    assert!(near(v(&e, &k("b4", "Gain")), -3.63, 0.01) && near(v(&e, &k("b4", "Freq")), 2560.6, 0.5));
    assert!(near(v(&e, &k("b4", "Q")), 1.0, 0.01));
    assert!(near(v(&e, &k("b1", "Freq")), 50.0, 0.1) && near(v(&e, &k("ls", "Freq")), 40.0, 0.1));
    assert!(v(&e, &k("b1", "On")) == 0.0 && v(&e, &k("b4", "On")) == 1.0);
    assert!(near(v(&e, &k("hs", "Gain")), 1.0, 0.001) && near(v(&e, &k("hs", "Freq")), 18_000.0, 1.0));
    assert!(v(&e, &k("hp", "On")) == 1.0 && near(v(&e, &k("hp", "Freq")), 79.8, 0.1));
    assert_eq!(v(&e, &k("lp", "On")), 0.0);
}

//! Premiere effect presets (.prfpset) -> SQ effect presets. Fixture: a synthetic preset file with the structure of a real
//! Premiere export (invented preset names and parameter values). Swift: PresetImportTests.swift (reader, listing, skipping,
//! and the Basic cases; the audio voice-chain cases need `sq-audiofx`, see NOTES.md).
#![allow(clippy::unwrap_used, reason = "helpers of integration tests; clippy.toml only covers test functions")]

use sq_core_effects::effect_preset::{Anchor, ApplyMode, ClipEffectPresetExt};
use sq_core_model::{COLOR_KIND, Clip, ClipAnimation, ClipEffect, TrackKind};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use sq_premiere_import::prcontainer::PRTicks;
use sq_premiere_import::prdocument::PRComponent;
use sq_premiere_import::prpreset::{PRMappedPreset, PRPreset, PRPresetImport, PRPresetMapper, PRPresetReader};
use std::collections::BTreeSet;

const TICKS_PER_FRAME: i64 = 8_475_667_200; // 29.97 fps

fn fixture() -> Vec<PRPreset> {
    let data = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/presets.prfpset.gz")).unwrap();
    PRPresetReader::read(&data).unwrap()
}

fn imported() -> PRPresetImport {
    PRPresetMapper::map(&fixture(), (1080, 1920), &PRPresetMapper::ignored_folders(), &mut SequentialIds::default())
}

fn preset(name: &str) -> PRMappedPreset {
    imported().presets.into_iter().find(|p| p.name == name).unwrap_or_else(|| panic!("{name} not imported"))
}

/// A clip of `seconds` with the preset applied.
fn applied(name: &str, seconds: i64) -> Clip {
    let mut ids = SequentialIds::default();
    let mut c = Clip::new(
        Id::from_u128(1),
        "c",
        Id::from_u128(2),
        TrackKind::Video,
        TimeRange::new(Time::ZERO, Time::new(seconds, 1)),
        Time::ZERO,
    );
    c.apply_preset(&preset(name).preset, ApplyMode::Absolute, None, &mut ids);
    c
}

fn frames(n: i64) -> Time {
    PRTicks::time(n * TICKS_PER_FRAME)
}

fn effect<'a>(c: &'a Clip, kind: &str) -> &'a ClipEffect {
    c.effects.iter().find(|e| e.kind == kind).unwrap()
}

#[test]
fn reader_finds_the_tree_and_skips_nothing_silently() {
    let ps = fixture();
    let paths: Vec<String> = ps.iter().map(PRPreset::path).collect();
    assert!(paths.contains(&"Presets / Voice Clean (v1)".to_string()));
    assert!(paths.contains(&"Demo Presets / Start & End / Outro IN".to_string()));
    let ntg = ps.iter().find(|p| p.name == "Voice Clean (v1)").unwrap();
    // One instance per channel type (mono, stereo, 5.1) of each of the three effects.
    let channels: BTreeSet<i64> = ntg.filters.iter().filter_map(|f| f.channel_type).collect();
    assert!(ntg.filters.len() == 9 && channels == BTreeSet::from([0, 1, 2]));
    let end = ps.iter().find(|p| p.name == "Outro IN").unwrap();
    assert_eq!(end.filters.iter().map(|f| f.kind).collect::<Vec<_>>(), vec![2, 2]);
    assert_eq!(
        end.filters.iter().map(|f| f.component.match_name.as_str()).collect::<Vec<_>>(),
        vec!["AE.ADBE Geometry2", "AE.ADBE Gaussian Blur 2"]
    );
}

#[test]
fn import_lists_every_preset_once_with_its_anchor() {
    let r = imported();
    let names: Vec<&str> = r.presets.iter().map(|p| p.name.as_str()).collect();
    let want = [
        "Voice Clean (v1)",
        "Backdrop Blur",
        "Backdrop Blur - Fade In",
        "Mono",
        "Caption Pop",
        "Soft Fade In",
        "Soft Fade Out",
        "Soft Shadow",
        "Outro IN",
        "Outro OUT",
        "Intro IN",
        "Intro OUT",
    ];
    assert_eq!(names.iter().copied().collect::<BTreeSet<_>>(), want.iter().copied().collect::<BTreeSet<_>>());
    assert_eq!(
        names.len(),
        names.iter().collect::<BTreeSet<_>>().len(),
        "the two identical Shadow presets import once"
    );
    let anchor = |n: &str| r.presets.iter().find(|p| p.name == n).map(|p| p.preset.anchor);
    assert!(
        anchor("Soft Fade In") == Some(Anchor::Start)
            && anchor("Soft Fade Out") == Some(Anchor::End)
            && anchor("Outro IN") == Some(Anchor::End)
    );
    assert!(
        anchor("Outro OUT") == Some(Anchor::End)
            && anchor("Intro OUT") == Some(Anchor::Start)
            && anchor("Caption Pop") == Some(Anchor::Start)
    );
    // Saved as "Scale" in Premiere: stretches with the clip.
    assert!(anchor("Intro IN") == Some(Anchor::Stretch) && anchor("Backdrop Blur") == Some(Anchor::Stretch));
}

#[test]
fn ignored_folders_and_unmappable_effects_are_skipped_with_a_reason() {
    let blur = fixture().into_iter().find(|p| p.name == "Backdrop Blur").unwrap();
    let mut zoom = blur.clone();
    zoom.name = "BOT".into();
    zoom.folders = vec!["Presets".into()];
    zoom.alias_folders = vec![vec!["Demo".into(), "Skipped Folder".into(), "Zoom In & Out".into()]];
    let mut lens = blur.clone();
    lens.name = "Lens".into();
    lens.filters[0].component = PRComponent {
        match_name: "PR.ADBE Lens Distortion".into(),
        display_name: "Lens Distortion".into(),
        params: Vec::new(),
        is_audio: false,
    };
    let ignored = BTreeSet::from(["Skipped Folder".to_string()]);
    let r = PRPresetMapper::map(&[zoom, lens, blur], (1080, 1920), &ignored, &mut SequentialIds::default());
    assert_eq!(r.presets.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), vec!["Backdrop Blur"]);
    assert_eq!(
        r.skipped.iter().map(|s| s.reason.as_str()).collect::<Vec<_>>(),
        vec!["ignored folder", "no SQ equivalent: PR.ADBE Lens Distortion (Lens Distortion)"]
    );
}

/// Swift PRPreset.swift:126: a preset whose effects map to nothing is skipped as "nothing to import" (the app only logs
/// the skipped count, Swift LibraryImports.swift:91; the reasons stay in the result).
#[test]
fn a_preset_with_no_effects_is_skipped_as_nothing_to_import() {
    let mut empty = fixture().into_iter().find(|p| p.name == "Backdrop Blur").unwrap();
    empty.name = "Empty".into();
    empty.filters.clear();
    let r = PRPresetMapper::map(&[empty], (1080, 1920), &BTreeSet::new(), &mut SequentialIds::default());
    assert!(r.presets.is_empty());
    assert_eq!(r.skipped.iter().map(|s| s.reason.as_str()).collect::<Vec<_>>(), vec!["nothing to import"]);
}

#[test]
fn backdrop_blur_is_a_static_blur_with_repeated_edges() {
    let c = applied("Backdrop Blur", 10);
    let e = effect(&c, ClipEffect::GAUSSIAN_BLUR_KIND);
    let b = &e.parameters[ClipEffect::BLURRINESS_KEY];
    assert!(b.value == 150.0 && !b.is_animated());
    assert_eq!(e.parameters[ClipEffect::REPEAT_EDGE_PIXELS_KEY].value, 1.0);
    assert_eq!(c.animation, ClipAnimation::default(), "no Motion change");
}

#[test]
fn backdrop_blur_fade_in_ramps_from_0_to_150_at_the_start() {
    for seconds in [3, 30] {
        let c = applied("Backdrop Blur - Fade In", seconds);
        let k: Vec<(Time, f64)> = effect(&c, ClipEffect::GAUSSIAN_BLUR_KIND).parameters[ClipEffect::BLURRINESS_KEY]
            .track
            .keys
            .iter()
            .map(|k| (k.time, k.value))
            .collect();
        assert_eq!(k.iter().map(|k| k.0).collect::<Vec<_>>(), vec![frames(1), frames(17)]);
        assert_eq!(k.iter().map(|k| k.1).collect::<Vec<_>>(), vec![0.0, 150.0]);
    }
}

#[test]
fn black_and_white_sets_saturation_to_zero() {
    use sq_core_color::ClipEffectColorExt;
    let c = applied("Mono", 10);
    let grade = effect(&c, COLOR_KIND).color_effect(None, 1);
    assert!(grade.basic.saturation == 0.0 && grade.basic.exposure == 0.0 && grade.basic.contrast == 0.0);
    assert!(!c.effects.iter().any(|e| e.kind == ClipEffect::SHARPEN_KIND), "Lumetri sharpen 0 adds nothing");
}

#[test]
fn fade_in_anchors_to_the_clip_start() {
    for seconds in [2, 20] {
        let c = applied("Soft Fade In", seconds);
        let k: Vec<(Time, f64)> = c.animation.opacity.track.keys.iter().map(|k| (k.time, k.value)).collect();
        assert_eq!(k.iter().map(|k| k.0).collect::<Vec<_>>(), vec![Time::ZERO, frames(7)]);
        assert_eq!(k.iter().map(|k| k.1).collect::<Vec<_>>(), vec![0.0, 1.0]);
    }
}

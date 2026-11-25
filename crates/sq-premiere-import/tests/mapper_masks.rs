//! Premiere masks, Impact dissolve, stabilizers and the Impact effects through the mapper. Mask blobs are copied from the
//! maintainer's real projects (2026-11-25): AEMask2 rectangle (Apple Event Fold), AEMask rectangle and 9-point shape and a
//! tracked (keyed) AEMask path (16 Aug 2025, iPhone 17 Event).
#![allow(clippy::unwrap_used, reason = "helpers of integration tests; clippy.toml only covers test functions")]

mod common;

use common::{ItemSpec, PRFixture, SECOND as S, Source};
use sq_core_masks::ClipMasksExt;
use sq_core_model::{Clip, ClipEffect, TrackKind, TransitionKind};
use sq_core_time::SequentialIds;
use sq_premiere_import::prdocument::PRReader;
use sq_premiere_import::primport_report::Status;
use sq_premiere_import::prmapper::{PRImportResult, PRMapper};
use std::collections::BTreeMap;

const V2_RECT: &str = "AgAAAAEAAABWeQAAAAIAAAAEAAAAAAAAAMEbZT5gvmk8wRtlPmC+aTzBG2U+YL5pPAAAAABgs0k/YL5pPGCzST9gvmk8YLNJP2C+aTwAAAAAYLNJP3qHfT9gs0k/eod9P2CzST96h30/AAAAAMEbZT56h30/wRtlPnqHfT/BG2U+eod9PwE=";
const V1_RECT: &str = "MmNpbgIAAAAAAAAABAAAAAAAAAAszEy830mfvCzMTLzfSZ+8LMxMvN9Jn7wBAAAAAAAAAK2qgT8otJe8raqBPyi0l7ytqoE/KLSXvAEAAAAAAAAA4N2BP4xRgz/g3YE/jFGDP+DdgT+MUYM/AQAAAAAAAACUmZm8Ln2CP5SZmbwufYI/lJmZvC59gj8BAAAA";
const V1_NINE: &str = "MmNpbgIAAAAAAAAACQAAAAEAAACkDcg+lv6TPi3Nxz7I74w+Hk7IPmYNmz4BAAAAAAAAAP4NgT42mOc+/g2BPjaY5z7+DYE+NpjnPgEAAAAAAAAAHvYIPqknSz8e9gg+qSdLPx72CD6pJ0s/AQAAAAAAAAByb2s+2BhgP3Jvaz7YGGA/cm9rPtgYYD8BAAAAAAAAAMmyGz//lGY/ybIbP/+UZj/Jshs//5RmPwEAAAAAAAAA3kFcP0l3Mz/eQVw/SXczP95BXD9JdzM/AQAAAAAAAACt114/kUsFP63XXj+RSwU/rddeP5FLBT8BAAAAAAAAABh7RD8zV5k+GHtEPzNXmT4Ye0Q/M1eZPgEAAAAAAAAAEb4DP0v2aj4RvgM/S/ZqPhG+Az9L9mo+AQAAAA==";
const V1_KEYS: &str = "0,MmNpbgIAAAAAAAAABAAAAAAAAAAxZy2/XUJQvzFnLb9dQlC/MWctv11CUL8BAAAAAAAAAGMFBD9ldkq/YwUEP2V2Sr9jBQQ/ZXZKvwEAAAAAAAAAWUAwP322hL5ZQDA/fbaEvllAMD99toS+AQAAAAAAAADgKiC/DAaQPuAqIL8MBpA+4CogvwwGkD4BAAAA;245794348800,MmNpbgIAAAAAAAAABAAAAAAAAABLOKq9oOiRvUs4qr2g6JG9SziqvaDokb0BAAAAAAAAAMMSjj/BEUe9wxKOP8ERR73DEo4/wRFHvQEAAAAAAAAA+/uMP52JhT/7+4w/nYmFP/v7jD+diYU/AQAAAAAAAACQqwC9JwSDP5CrAL0nBIM/kKsAvScEgz8BAAAA;364453689600,MmNpbgIAAAAAAAAABAAAAAAAAABlS4I+Sep2P2VLgj5J6nY/ZUuCPknqdj8BAAAAAAAAAOYduz82/DM/5h27Pzb8Mz/mHbs/NvwzPwEAAAAAAAAAHge6P0DA5T8eB7o/QMDlPx4Huj9AwOU/AQAAAAAAAAAGF6Q+yjrjPwYXpD7KOuM/BhekPso64z8BAAAA;";

fn map(f: &PRFixture) -> PRImportResult {
    PRMapper::map(&PRReader::read(&f.data()).unwrap(), "Test", &BTreeMap::new(), false, &mut SequentialIds::default())
}

fn video(r: &PRImportResult) -> Vec<Clip> {
    r.project.timelines[0]
        .tracks
        .iter()
        .filter(|t| t.kind == TrackKind::Video)
        .flat_map(|t| t.clips().to_vec())
        .collect()
}

/// One clip with `components`, mapped.
fn one_clip(f: &mut PRFixture, components: &[String]) -> PRImportResult {
    let m = f.media("/f/a.mov", "a.mov");
    let refs: Vec<&str> = components.iter().map(String::as_str).collect();
    let it = f.item(ItemSpec::new(0, S, 0, S, Source::Media(m)).components(&refs));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    map(f)
}

/// An AEMask component object (`v2` = AEMask2) with its path param and the three number params.
fn mask(
    f: &mut PRFixture,
    v2: bool,
    blob: &str,
    keys: Option<&str>,
    feather: &str,
    expansion: &str,
    inverted: &str,
) -> String {
    let (path, fe, op, ex, inv, name) =
        if v2 { (7, 14, 15, 16, 17, "AE.ADBE AEMask2") } else { (6, 7, 8, 9, 10, "AE.ADBE AEMask") };
    let ps =
        [f.path_param(path, blob, keys), f.p(fe, feather), f.p(op, "100."), f.p(ex, expansion), f.p(inv, inverted)];
    f.component(name, &ps)
}

#[test]
fn an_opacity_mask_of_aemask2_becomes_a_clip_mask() {
    let mut f = PRFixture::new();
    let mk = mask(&mut f, true, V2_RECT, None, "80.62860107421875", "-43.", "false");
    let opacity = f.component_with_subs("AE.ADBE Opacity", &[], &[mk]);
    let r = one_clip(&mut f, &[opacity]);
    let c = &video(&r)[0];
    assert_eq!(c.masks().len(), 1);
    let m = &c.masks()[0];
    assert!(m.used_by_opacity() && !m.inverted && m.enabled);
    assert_eq!(m.path.value.vertices.len(), 4);
    let v = m.path.value.vertices[0];
    assert!((v.point.x - 0.2237).abs() < 1e-3 && (v.point.y - 0.0143).abs() < 1e-3);
    assert_eq!((v.in_tangent.x, v.out_tangent.y), (0.0, 0.0), "a rectangle has no handles");
    assert!((m.feather.value - 80.6286).abs() < 1e-3 && m.expansion.value == -43.0 && m.opacity.value == 100.0);
    assert_eq!(r.report.status_of("Mask"), Some(Status::Mapped));
}

/// A mask with Transform params next to the real AEMask2 path (Position, Anchor, Scale Height / Width, Rotation).
fn moved_mask(f: &mut PRFixture, pos: &str, anchor: &str, scale: &str, rot: &str) -> String {
    let ps =
        [f.path_param(7, V2_RECT, None), f.pt(9, pos), f.pt(10, anchor), f.p(26, scale), f.p(27, scale), f.p(12, rot)];
    f.component("AE.ADBE AEMask2", &ps)
}

#[test]
fn the_mask_transform_moves_scales_and_rotates_the_real_path() {
    // Sequence 1920x1080 (fixture default): the real rectangle spans x 0.2237..0.7879, y 0.0143..0.9903.
    let corner = |pos: &str, anchor: &str, scale: &str, rot: &str| {
        let mut f = PRFixture::new();
        let mk = moved_mask(&mut f, pos, anchor, scale, rot);
        let opacity = f.component_with_subs("AE.ADBE Opacity", &[], &[mk]);
        let r = one_clip(&mut f, &[opacity]);
        video(&r)[0].masks()[0].path.value.vertices[0].point
    };
    // Position moved 0.1 right of the anchor: the whole path shifts.
    let p = corner("0.6:0.5", "0.5:0.5", "100.", "0.");
    assert!((p.x - 0.3237).abs() < 1e-3 && (p.y - 0.0143).abs() < 1e-3);
    // 50 % about the anchor.
    let p = corner("0.5:0.5", "0.5:0.5", "50.", "0.");
    assert!((p.x - (0.5 + (0.2237 - 0.5) * 0.5)).abs() < 1e-3 && (p.y - (0.5 + (0.0143 - 0.5) * 0.5)).abs() < 1e-3);
    // 180 degrees about the anchor mirrors the corner through it.
    let p = corner("0.5:0.5", "0.5:0.5", "100.", "180.");
    assert!((p.x - (1.0 - 0.2237)).abs() < 1e-3 && (p.y - (1.0 - 0.0143)).abs() < 1e-3);
}

#[test]
fn a_tracked_mask_transform_becomes_path_keys() {
    let mut f = PRFixture::new();
    let ps = [
        f.path_param(7, V2_RECT, None),
        f.param(
            Some(9),
            "0.5:0.5",
            Some("0,0.5:0.5,0,0,0,0,0,0;254016000000,0.6:0.5,0,0,0,0,0,0;"),
            "PointComponentParam",
        ),
        f.pt(10, "0.5:0.5"),
    ];
    let mk = f.component("AE.ADBE AEMask2", &ps);
    let opacity = f.component_with_subs("AE.ADBE Opacity", &[], &[mk]);
    let r = one_clip(&mut f, &[opacity]);
    let clip = video(&r).remove(0);
    let keys = &clip.masks()[0].path.track.keys;
    assert_eq!(keys.len(), 2);
    assert!((keys[1].value.vertices[0].point.x - keys[0].value.vertices[0].point.x - 0.1).abs() < 1e-6);
}

#[test]
fn basic_3d_becomes_the_clip_tilt() {
    let mut f = PRFixture::new();
    let ps = [f.p(1, "20."), f.p(2, "-10."), f.p(3, "0."), f.p(4, "false")];
    let b3 = f.component("AE.ADBE Basic 3D", &ps);
    let r = one_clip(&mut f, &[b3]);
    let c = &video(&r)[0];
    assert_eq!((c.animation.tilt_y.value, c.animation.tilt_x.value), (20.0, -10.0));
    assert_eq!(r.report.status_of("AE.ADBE Basic 3D"), Some(Status::Mapped));
    let mut f = PRFixture::new();
    let ps = [f.p(1, "0."), f.p(2, "0."), f.p(3, "50."), f.p(4, "false")];
    let b3 = f.component("AE.ADBE Basic 3D", &ps);
    assert_eq!(one_clip(&mut f, &[b3]).report.status_of("AE.ADBE Basic 3D"), Some(Status::Approximated));
}

#[test]
fn an_effect_mask_limits_that_effect_and_keeps_its_curve_handles() {
    let mut f = PRFixture::new();
    let mk = mask(&mut f, false, V1_NINE, None, "10.", "0.", "true");
    let ps = [f.p(1, "10."), f.p(2, "10.")];
    let mosaic = f.component_with_subs("AE.ADBE Mosaic", &ps, &[mk]);
    let r = one_clip(&mut f, &[mosaic]);
    let c = &video(&r)[0];
    let e = c.effects.iter().find(|e| e.kind == ClipEffect::MOSAIC_KIND).unwrap();
    assert_eq!(c.masks().len(), 1);
    let m = &c.masks()[0];
    assert_eq!(e.mask_input, vec![m.id]);
    assert!(!m.used_by_opacity() && m.inverted);
    assert_eq!(m.path.value.vertices.len(), 9);
    // Vertex 0 of the real mask: point (0.3907, 0.2891), in handle above, out handle below (offsets from the point).
    let v = m.path.value.vertices[0];
    assert!(v.in_tangent.y < 0.0 && v.out_tangent.y > 0.0 && (v.out_tangent.y - 0.0137).abs() < 1e-3);
}

#[test]
fn a_tracked_mask_path_keeps_its_keys_and_an_empty_one_is_reported() {
    let mut f = PRFixture::new();
    let tracked = mask(&mut f, false, V1_RECT, Some(V1_KEYS), "0.", "0.", "false");
    let empty = mask(&mut f, true, "AgAAAAAAAAA=", None, "0.", "0.", "false");
    let opacity = f.component_with_subs("AE.ADBE Opacity", &[], &[tracked, empty]);
    let r = one_clip(&mut f, &[opacity]);
    let c = &video(&r)[0];
    assert_eq!(c.masks().len(), 1, "the empty mask is dropped");
    let keys = &c.masks()[0].path.track.keys;
    assert_eq!(keys.len(), 3);
    assert!(keys[0].time < keys[1].time && keys[1].time < keys[2].time);
    assert_eq!(r.report.status_of("Mask"), Some(Status::Dropped));
}

#[test]
fn a_mask_of_a_dropped_effect_is_reported_not_attached() {
    let mut f = PRFixture::new();
    let mk = mask(&mut f, true, V2_RECT, None, "0.", "0.", "false");
    let wave = f.component_with_subs("AE.ADBE Wave Warp", &[], &[mk]);
    let r = one_clip(&mut f, &[wave]);
    assert!(video(&r)[0].masks().is_empty());
    assert_eq!(r.report.status_of("Mask"), Some(Status::Dropped));
}

#[test]
fn impact_dissolve_is_a_plain_cross_dissolve() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let a = f.item(ItemSpec::new(0, 2 * S, 0, 2 * S, Source::Media(m.clone())));
    let b = f.item(ItemSpec::new(2 * S, 4 * S, 5 * S, 7 * S, Source::Media(m)));
    let tr = f.transition(2 * S - S / 2, 2 * S + S / 2, "AE.AE_Impact_Dissolve");
    let t = f.track_with(&[a, b], &[tr], false, false);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    assert_eq!(r.project.timelines[0].tracks[0].transitions[0].kind, TransitionKind::CrossDissolve);
    assert_eq!(r.report.status_of("Transition AE.AE_Impact_Dissolve"), None);
}

fn named(f: &mut PRFixture, pid: i64, name: &str, value: &str) -> String {
    let id = f.p(pid, value);
    f.rename_last_param(&id, name);
    id
}

#[test]
fn warp_stabilizer_and_gyroflow_become_the_sq_stabilizer() {
    let mut f = PRFixture::new();
    let ps = [f.p(19, "1"), f.p(20, "30."), f.p(22, "2"), f.p(4, "150.")];
    let warp = f.component("AE.ADBE SubspaceStabilizer", &ps);
    let r = one_clip(&mut f, &[warp]);
    let e = video(&r)[0].effects.iter().find(|e| e.kind == ClipEffect::STABILIZE_KIND).cloned().unwrap();
    let v = |k: &str| e.parameters.get(k).map(|p| p.value);
    assert_eq!(v(ClipEffect::STABILIZE_METHOD_KEY), Some(0.0));
    assert_eq!(v(ClipEffect::STABILIZE_MODE_KEY), Some(1.0), "No Motion = Locked");
    assert!((v(ClipEffect::STABILIZE_SMOOTHNESS_KEY).unwrap() - 0.3).abs() < 1e-9);
    assert!((v(ClipEffect::STABILIZE_MAX_CROP_KEY).unwrap() - 100.0 / 3.0).abs() < 1e-6);

    let mut f = PRFixture::new();
    let ps = [
        named(&mut f, 1405383900, "Smoothness", "40."),
        named(&mut f, 1449269018, "Lens correction", "80."),
        named(&mut f, 1571104264, "FOV", "1.2"),
    ];
    let gyro = f.component("AE.Gyroflow", &ps);
    let r = one_clip(&mut f, &[gyro]);
    let e = video(&r)[0].effects.iter().find(|e| e.kind == ClipEffect::STABILIZE_KIND).cloned().unwrap();
    let v = |k: &str| e.parameters.get(k).map(|p| p.value);
    assert_eq!(v(ClipEffect::STABILIZE_METHOD_KEY), Some(1.0));
    assert_eq!(v(ClipEffect::GYRO_SMOOTHNESS_KEY), Some(40.0));
    assert_eq!(v(ClipEffect::GYRO_LENS_CORRECTION_KEY), Some(80.0));
    assert!((v(ClipEffect::GYRO_FIELD_OF_VIEW_KEY).unwrap() - 120.0).abs() < 1e-9);
    assert_eq!(r.report.status_of("AE.Gyroflow"), Some(Status::Approximated));
}

#[test]
fn impact_effects_map_to_the_nearest_sq_effect() {
    let mut f = PRFixture::new();
    let mosaic = {
        let ps = [f.p(4, "64.")];
        f.component("AE.Impact_Mosaic_FX", &ps)
    };
    let blur = {
        let ps = [f.p(2, "45."), f.p(3, "20.")];
        f.component("AE.Impact_Blur_FX", &ps)
    };
    let shake = f.component("AE.Impact_Camera_Shake_FX", &[]);
    let r = one_clip(&mut f, &[mosaic, blur, shake]);
    let c = &video(&r)[0];
    let kinds: Vec<&str> = c.effects.iter().map(|e| e.kind.as_str()).collect();
    assert_eq!(kinds, [ClipEffect::MOSAIC_KIND, ClipEffect::DIRECTIONAL_BLUR_KIND, ClipEffect::SHAKE_KIND]);
    assert_eq!(c.effects[0].parameters[ClipEffect::MOSAIC_COLUMNS_KEY].value, 64.0);
    assert_eq!(c.effects[1].parameters[ClipEffect::BLUR_DIRECTION_KEY].value, 45.0);
    assert_eq!(c.effects[1].parameters[ClipEffect::BLUR_LENGTH_KEY].value, 20.0);
    assert_eq!(r.report.status_of("AE.Impact_Mosaic_FX"), Some(Status::Approximated));
}

/// Headless import of real projects: `SQ_PRPROJ_DIR=<folder of copies> SQ_IMPORT_OUT=<file> cargo test ... real_projects`.
/// Skipped without the variable. Writes one line per report entry (summed over the projects).
#[test]
fn real_projects_report() {
    let Ok(dir) = std::env::var("SQ_PRPROJ_DIR") else { return };
    let mut totals: BTreeMap<(String, i64), (i64, String)> = BTreeMap::new();
    let mut files = 0;
    let mut masks = 0;
    for e in std::fs::read_dir(&dir).unwrap() {
        let path = e.unwrap().path();
        if path.extension().and_then(|x| x.to_str()) != Some("prproj") {
            continue;
        }
        let doc = PRReader::read(&std::fs::read(&path).unwrap()).unwrap();
        let r = PRMapper::map(&doc, "Real", &BTreeMap::new(), false, &mut SequentialIds::default());
        files += 1;
        masks += r
            .project
            .timelines
            .iter()
            .flat_map(|t| &t.tracks)
            .flat_map(|t| t.clips())
            .map(|c| c.masks().len())
            .sum::<usize>();
        for en in r.report.entries() {
            let t = totals.entry((en.feature.clone(), en.status.raw_value())).or_default();
            t.0 += en.count;
            t.1.clone_from(&en.note);
        }
    }
    let mut out = format!("projects {files}, clip masks {masks}\n");
    for ((feature, status), (count, note)) in &totals {
        let label = ["mapped", "approximated", "dropped"][*status as usize];
        out += &format!("{label}\t{count}\t{feature}\t{note}\n");
    }
    std::fs::write(std::env::var("SQ_IMPORT_OUT").unwrap_or_else(|_| format!("{dir}/import-report.txt")), out).unwrap();
}

//! Compares the plan functions with the floats the Swift code dumped (`oracle/sq-render/gpu-effects/golden/gpu-effects.tsv`,
//! made by `oracle/sq-render/gpu-effects/run.sh` from the real EffectChainPlan, FilmLookPlan, MaskData and OutlineFilters).

use super::effect_chain_plan::{effect_chain_factor, pixel_budget, repeat_edge_rect, works_at_reduced_size};
use super::look_passes::LookUniforms;
use super::mask_data::{MaskInputs, Placement, ScreenMap, mask_entries, mode_id};
use super::outline_filters::{jump_steps, shadow_plane_size, shadow_steps};
use sq_core_color::{Aged, ChromaBleed, FilmLook, Grain, Scanlines, Tracking};
use sq_core_effects::effects_evaluation::{EffectSegment, ImageFilter, OutlinePosition};
use sq_core_masks::MaskShape;
use sq_core_model::{MaskMode, MaskSource, MatteChannel};
use sq_core_time::Vec2;
use std::collections::HashMap;

struct Golden {
    rows: HashMap<String, Vec<f32>>,
    checked: usize,
    bad: Vec<String>,
}

impl Golden {
    fn load() -> Option<Golden> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../oracle/sq-render/gpu-effects/golden/gpu-effects.tsv");
        let text = std::fs::read_to_string(path).ok()?;
        let rows = text
            .lines()
            .filter_map(|l| {
                let (key, values) = l.rsplit_once('\t')?;
                Some((key.to_string(), values.split_whitespace().filter_map(|v| v.parse().ok()).collect()))
            })
            .collect();
        Some(Golden { rows, checked: 0, bad: Vec::new() })
    }

    fn check(&mut self, key: &str, got: &[f32]) {
        self.checked += 1;
        let Some(want) = self.rows.get(key) else {
            self.bad.push(format!("{key}: no golden row"));
            return;
        };
        if want.len() != got.len() {
            self.bad.push(format!("{key}: {} values, golden has {}: {got:?} vs {want:?}", got.len(), want.len()));
            return;
        }
        for (i, (g, w)) in got.iter().zip(want).enumerate() {
            let bits_equal = g.to_bits() == w.to_bits();
            if !bits_equal && (g - w).abs() > 1e-6 * w.abs().max(1.0) {
                self.bad.push(format!("{key}[{i}]: got {g}, golden {w}"));
            }
        }
    }
}

fn f(v: &[i32]) -> Vec<f32> {
    v.iter().map(|x| *x as f32).collect()
}

fn square(lo: f64, hi: f64) -> Vec<Vec2> {
    vec![Vec2::new(lo, lo), Vec2::new(hi, lo), Vec2::new(hi, hi), Vec2::new(lo, hi)]
}

fn flat(e: &[[f32; 2]]) -> Vec<f32> {
    e.iter().flatten().copied().collect()
}

fn seg(blur: f64, filter: Option<ImageFilter>) -> EffectSegment {
    EffectSegment { blur_after: blur, filter, ..EffectSegment::default() }
}

#[test]
fn plans_match_the_swift_dump() {
    let Some(mut g) = Golden::load() else {
        sq_os::errln!("skipping: run oracle/sq-render/gpu-effects/run.sh to make the golden file");
        return;
    };
    for reach in [0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 17.0, 33.0, 100.0, 1000.0] {
        g.check(&format!("jump\t{reach:?}"), &f(&jump_steps(reach)));
    }
    for (w, h) in [(1920u32, 1080u32), (4096, 4096), (4097, 4096), (8192, 4608), (3, 20000)] {
        let (pw, ph) = shadow_plane_size(w, h);
        g.check(&format!("plane\t{w}\t{h}"), &[pw as f32, ph as f32]);
    }
    for length in [0.0, 0.5, 1.0, 2.0, 7.0, 10.0, 37.5, 100.0, 1234.5] {
        let steps: Vec<f32> = shadow_steps(length).iter().map(|s| *s as f32).collect();
        g.check(&format!("steps\t{length:?}"), &steps);
    }

    let filters = [
        None,
        Some(ImageFilter::Sharpen { amount: 1.0 }),
        Some(ImageFilter::DirectionalBlur { dx: 4.0, dy: 0.0 }),
        Some(ImageFilter::Glow { threshold: 0.5, sigma: 3.0, intensity: 1.0, color: None }),
        Some(ImageFilter::Mosaic { columns: 4, rows: 4, sharp: false }),
        Some(ImageFilter::Flip { horizontal: true, vertical: false }),
        Some(ImageFilter::Outline {
            width: 4.0,
            color: [1.0, 0.0, 0.0],
            softness: 1.0,
            position: OutlinePosition::Outside,
        }),
        Some(ImageFilter::LongShadow { angle: 90.0, length: 30.0, color: [0.0; 3], fade: 0.2, opacity: 1.0 }),
    ];
    for (i, filter) in filters.iter().enumerate() {
        let s = seg(if filter.is_none() { 4.0 } else { 0.0 }, filter.clone());
        let budget = if pixel_budget(&s) == i64::MAX { -1.0 } else { pixel_budget(&s) as f32 };
        g.check(&format!("budget\t{i}"), &[budget, f32::from(u8::from(works_at_reduced_size(&s)))]);
    }
    let chains = [
        vec![seg(2.0, None), seg(0.0, None)],
        vec![seg(3.0, None), seg(0.0, None)],
        vec![seg(9.0, None), seg(0.0, Some(ImageFilter::Sharpen { amount: 1.0 })), seg(0.0, None)],
        vec![seg(0.0, Some(ImageFilter::DirectionalBlur { dx: 4.0, dy: 0.0 })), seg(0.0, None)],
        vec![seg(0.0, None)],
        vec![
            seg(5.0, None),
            seg(0.0, Some(ImageFilter::Glow { threshold: 0.5, sigma: 3.0, intensity: 1.0, color: None })),
            seg(0.0, None),
        ],
    ];
    for (i, chain) in chains.iter().enumerate() {
        for display in [1, 2, 4] {
            for strong in [true, false] {
                let factor = effect_chain_factor(chain, display, strong);
                g.check(&format!("chain\t{i}\t{display}\t{}", i32::from(strong)), &[factor as f32]);
            }
        }
    }
    for (fw, fh, tw, th) in [
        (10.0f32, 6.0f32, 16, 12),
        (16.0, 12.0, 16, 12),
        (15.5, 11.5, 16, 12),
        (100.0, 50.0, 128, 64),
        (0.0, 0.0, 8, 8),
        (3.0, 3.0, 4, 4),
    ] {
        let (lo, hi) = repeat_edge_rect([fw, fh], [tw, th]);
        g.check(&format!("edge\t{fw:?}\t{fh:?}\t{tw}\t{th}"), &f(&[lo[0], lo[1], hi[0], hi[1]]));
    }

    let look_row = |look: &FilmLook, w, h| {
        let u = LookUniforms::new(look, w, h);
        let mut v: Vec<f32> = u.dims.to_vec();
        v.extend(u.ids.iter().map(|b| f32::from_bits(*b)));
        for row in [u.grain, u.scan, u.chroma, u.track, u.aged] {
            v.extend(row);
        }
        v
    };
    let mut look = FilmLook::default();
    g.check("look\tnone", &look_row(&look, 1920, 1080));
    look.grain = Some(Grain { amount: 0.3, size: 1.5, softness: 0.4, luma_weight: 0.7, color: 0.25, seed: 1234 });
    g.check("look\tgrain", &look_row(&look, 1920, 1080));
    look.scanlines = Some(Scanlines { intensity: 0.5, spacing: 4.0, thickness: 0.25 });
    look.chroma_bleed = Some(ChromaBleed { bleed: 0.6, shift: 2.0 });
    look.tracking = Some(Tracking { amount: 0.4, band_height: 30.0, phase: 0.125, seed: 77 });
    look.aged = Some(Aged { dust: 0.2, scratches: 0.3, flicker: 0.1, seed: 99 });
    g.check("look\tall", &look_row(&look, 960, 540));

    let mut path = MaskShape::new(square(0.25, 0.75));
    (path.feather, path.expansion, path.opacity, path.inverted, path.mode) = (4.0, -2.0, 0.5, true, MaskMode::Subtract);
    let plain = MaskShape::new(vec![Vec2::new(0.1, 0.2), Vec2::new(0.9, 0.3), Vec2::new(0.5, 0.95)]);
    let mut range = MaskShape::new(Vec::new());
    range.source = MaskSource::ColorRange;
    (range.color_range.red, range.color_range.green, range.color_range.blue) = (0.2, 0.4, 0.6);
    (range.color_range.tolerance, range.color_range.softness) = (0.3, 0.1);
    let mut subject = MaskShape::new(square(0.0, 1.0));
    subject.source = MaskSource::Subject;
    let mut picture = MaskShape::new(Vec::new());
    picture.source = MaskSource::Picture;
    picture.picture_channel = MatteChannel::Brightness;
    let screen = ScreenMap::from_placement(&Placement {
        canvas: [1920.0, 1080.0],
        position: [40.0, -30.0],
        anchor: [5.0, -7.0],
        scale: [1.25, 0.75],
        rot_cos: 0.8,
        rot_sin: 0.6,
        tilt: [0.1, -0.2, 900.0],
    });
    let sm = |s: &ScreenMap| {
        vec![
            s.row0[0],
            s.row0[1],
            s.row1[0],
            s.row1[1],
            s.translation[0],
            s.translation[1],
            s.canvas[0],
            s.canvas[1],
            s.tilt[0],
            s.tilt[1],
            s.tilt[2],
            s.center[0],
            s.center[1],
        ]
    };
    g.check("screen", &sm(&screen));
    let half = screen.scaled(0.5);
    g.check(
        "screenScaled",
        &[half.row0[0], half.row0[1], half.row1[0], half.row1[1], half.translation[0], half.canvas[0], half.center[0]],
    );

    let slots = |v: &[i32]| -> Vec<Option<usize>> { v.iter().map(|i| usize::try_from(*i).ok()).collect() };
    let mut run = |name: &str,
                   masks: &[MaskShape],
                   edge: f32,
                   screen: Option<&ScreenMap>,
                   picture_slot: &[i32],
                   matte: &[i32],
                   has: bool| {
        let (ps, ms) = (slots(picture_slot), slots(matte));
        let inputs = MaskInputs {
            frame: [200.0, 100.0],
            edge_scale: edge,
            screen,
            picture_slot: &ps,
            matte_slot: &ms,
            has_matte: has,
        };
        g.check(&format!("masks\t{name}"), &flat(&mask_entries(masks, &inputs)));
    };
    run("path", &[path.clone(), plain], 0.5, None, &[-1, -1], &[-1, -1], false);
    run("range", &[range, path.clone()], 1.0, None, &[-1, -1], &[-1, -1], false);
    run("matte", &[subject.clone(), path.clone()], 1.0, None, &[-1, -1], &[2, -1], true);
    run("nomatte", &[subject], 1.0, None, &[-1], &[2], false);
    run("picture", &[picture.clone(), path], 1.0, Some(&screen), &[1, -1], &[-1, -1], false);
    run("picturemissing", &[picture], 1.0, Some(&screen), &[-1], &[-1], false);

    assert!(g.rows.len() > 50, "golden file missing: run oracle/sq-render/gpu-effects/run.sh");
    for m in [MaskMode::Add, MaskMode::Subtract, MaskMode::Intersect, MaskMode::Difference] {
        g.check(&format!("mode\t{}", format!("{m:?}").to_lowercase()), &[mode_id(m)]);
    }

    assert_eq!(g.checked, g.rows.len(), "every golden row has a Rust case");
    assert!(
        g.bad.is_empty(),
        "{} of {} golden rows differ:\n{}",
        g.bad.len(),
        g.checked,
        g.bad.iter().take(20).cloned().collect::<Vec<_>>().join("\n")
    );
}

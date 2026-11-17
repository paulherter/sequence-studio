//! Proof of the Shutter Angle on a text clip through the app's own monitor path (`video_layers` -> `LayerRasters` ->
//! `ProgramCompositor`): the same mid-animation frame with the shutter closed and open must differ. Cases: A the title's
//! In animation, B Motion's Scale keys + Motion's Shutter Angle (the Transform section of the inspector, key
//! `shutterAngle` -> `ClipAnimation::shutter_angle`), C the Transform effect's Scale keys + its Shutter Angle.
//! Skips without a GPU adapter. `SQ_PROOF_DIR=<dir>` also writes the frames as PNG and the diff numbers as text.

use super::handle::RasterProvider;
use super::layer_rasters::LayerRasters;
use super::testkit::{clip, id, timeline};
use sq_core_effects::evaluation::{LayerHooks, LayerRequest, TimelineEvaluation};
use sq_core_model::anchored_animation::{AnimationAnchor, AnimationSet, AnimationTrack, KeyframeTemplate};
use sq_core_model::{AnimatedProperty, Clip, ClipEffect, GeneratorRef, SequenceFormat};
use sq_core_time::{IdSource, Keyframe, KeyframeTrack, KeyframeValue, SequentialIds, Time, Vec2};
use sq_gpu::gpu::Gpu;
use sq_render::program::{Inputs, LayerSource, ProgramCompositor, RenderOptions};
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::TextStyle;
use sq_text::text_template::TextTemplate;
use std::path::Path;

fn keys<T: KeyframeValue>(from: T, to: T) -> AnimatedProperty<T> {
    let mut ids = SequentialIds::default();
    let t = KeyframeTrack::with_keys(vec![
        Keyframe::new(ids.next_id(), Time::ZERO, from.clone()),
        Keyframe::new(ids.next_id(), Time::new(10, 25), to),
    ]);
    AnimatedProperty { value: from, track: t }
}

fn text_ref(animation: Option<&KeyframeTemplate>) -> GeneratorRef {
    let template = TextTemplate::new("t", "SHUTTER", TextStyle::default());
    TextGenerator::make_ref(&template, AnimationSet::single(animation).as_ref()).expect("ref")
}

fn text_clip() -> Clip {
    let mut c = clip(10, id(100), 0, 0, 4);
    c.generator = Some(text_ref(None));
    c
}

fn in_animation() -> KeyframeTemplate {
    let k = keys(4.0, 1.0);
    let mut a = KeyframeTemplate::none();
    a.tracks = vec![AnimationTrack::new("scale".into(), k.track)];
    a.duration = Time::new(10, 25);
    a.anchor = AnimationAnchor::Start;
    a
}

fn render(gpu: &std::sync::Arc<Gpu>, c: &Clip) -> (Vec<u8>, u32, u32) {
    let mut tl = timeline(vec![vec![c.clone()]]);
    tl.format = SequenceFormat { width: 640, height: 360, ..tl.format };
    let t = Time::new(5, 25);
    let requests = tl.video_layers(t, &|_| None, &LayerHooks::plain(), None);
    let rasters = LayerRasters::new();
    let canvas = tl.format.clone();
    let source = |l: &LayerRequest| {
        let mut l = l.clone();
        l.clip_duration = Some(Time::seconds(4));
        rasters.layer(&l, &canvas).map_or(LayerSource::Hidden, LayerSource::Raster)
    };
    let grade = |_: &LayerRequest| None;
    let inputs = Inputs { grade: &grade, split: None, mattes: None, source: &source };
    let mut comp = ProgramCompositor::new(gpu).expect("compositor");
    let frame = comp
        .render(&requests, &tl.format, &RenderOptions { readback: true, ..RenderOptions::default() }, &inputs)
        .expect("render");
    (comp.download_rgba8(frame).expect("download"), 640, 360)
}

fn diff(a: &[u8], b: &[u8]) -> (usize, u32) {
    let n = a.iter().zip(b).filter(|(x, y)| x != y).count();
    let m = a.iter().zip(b).map(|(x, y)| u32::from(x.abs_diff(*y))).max().unwrap_or(0);
    (n, m)
}

fn save(dir: &Path, name: &str, px: &[u8], w: u32, h: u32) {
    let file = std::fs::File::create(dir.join(name)).expect("file");
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w, h);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().expect("header").write_image_data(px).expect("png");
}

#[test]
fn an_open_shutter_blurs_a_text_clips_scale_in_the_monitor_path() {
    let Ok(gpu) = Gpu::new() else {
        eprintln!("skipped: no GPU adapter");
        return;
    };
    let mut report = String::new();
    let mut failed = Vec::new();
    for case in ["A-title-in-animation", "B-motion-scale", "C-transform-effect"] {
        let build = |angle: f64| -> Clip {
            let mut c = text_clip();
            match case.chars().next() {
                Some('A') => {
                    c.generator = Some(text_ref(Some(&in_animation())));
                    c.animation.shutter_angle = AnimatedProperty::new(angle);
                }
                Some('B') => {
                    c.animation.scale = keys(Vec2::new(4.0, 4.0), Vec2::new(1.0, 1.0));
                    c.animation.shutter_angle = AnimatedProperty::new(angle);
                }
                _ => {
                    let mut e = ClipEffect::make(id(7), ClipEffect::TRANSFORM_KIND).expect("transform");
                    e.parameters.insert(ClipEffect::STAGE_SCALE_KEY.into(), keys(400.0, 100.0));
                    e.parameters.insert(ClipEffect::STAGE_SHUTTER_ANGLE_KEY.into(), AnimatedProperty::new(angle));
                    c.effects = vec![e];
                }
            }
            c
        };
        let (sharp, w, h) = render(&gpu, &build(0.0));
        let (blur, _, _) = render(&gpu, &build(360.0));
        let (n, m) = diff(&sharp, &blur);
        report.push_str(&format!("{case}: differing bytes {n} of {}, max channel diff {m}\n", sharp.len()));
        if n == 0 {
            failed.push(case);
        }
        if let Some(dir) = std::env::var_os("SQ_PROOF_DIR") {
            let dir = Path::new(&dir);
            std::fs::create_dir_all(dir).expect("dir");
            save(dir, &format!("{case}-shutter0.png"), &sharp, w, h);
            save(dir, &format!("{case}-shutter360.png"), &blur, w, h);
        }
    }
    eprintln!("{report}");
    if let Some(dir) = std::env::var_os("SQ_PROOF_DIR") {
        std::fs::write(Path::new(&dir).join("diff.txt"), &report).expect("report");
    }
    assert!(failed.is_empty(), "no blur in: {failed:?}\n{report}");
}

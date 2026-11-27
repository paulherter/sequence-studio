//! Proof frames of the zoom layer (`addZoomCut{asLayer}`): the same two-picture scene through the program compositor (the
//! path playback and export share) without and with an Adjustment Layer whose Motion scale is the mid-zoom value of the
//! op's curve (outgoing move frame 38 of 42: 1.05635, see sq-edit-api zoom_layer_tests). `SQ_PROOF_DIR=<dir>` writes
//! `without-layer.png` and `with-layer.png`.

use super::{Inputs, LayerSource, ProgramCompositor, RenderOptions};
use crate::compositor::gpu_test_support::gpu;
use sq_core_effects::adjustment_clip::ADJUSTMENT_KIND;
use sq_core_effects::evaluation::LayerRequest;
use sq_core_model::{GeneratorRef, SequenceFormat};
use sq_core_time::{Id, Time, Vec2};
use std::path::Path;

const W: usize = 480;
const H: usize = 270;

fn layer(n: u128, rgb: [u8; 3], scale: f64, at: Vec2) -> LayerRequest {
    let mut r = LayerRequest::new(Id::from_u128(n), Id::from_u128(100 + n), Id::from_u128(200), Time::ZERO);
    r.generator = Some(GeneratorRef { kind: "solid".into(), payload: rgb.to_vec(), payload_version: 1 });
    r.transform.scale = Vec2::new(scale, scale);
    r.transform.position = at;
    r
}

fn render(pc: &mut ProgramCompositor, zoom: Option<f64>) -> Vec<u8> {
    let f = SequenceFormat {
        width: W as i64,
        height: H as i64,
        frame_duration: Time::new(1, 25),
        audio_sample_rate: 48_000,
        pixel_aspect_store: None,
        unknown: sq_core_model::UnknownKeys::default(),
    };
    let mut reqs = vec![
        layer(1, [20, 40, 120], 1.0, Vec2::new(0.0, 0.0)),
        layer(2, [235, 235, 235], 0.55, Vec2::new(0.0, 0.0)),
        layer(3, [220, 40, 40], 0.18, Vec2::new(0.0, 0.0)),
    ];
    if let Some(s) = zoom {
        let mut adj = LayerRequest::new(Id::from_u128(4), Id::from_u128(104), Id::from_u128(200), Time::ZERO);
        adj.generator = Some(GeneratorRef { kind: ADJUSTMENT_KIND.into(), payload: Vec::new(), payload_version: 1 });
        adj.transform.scale = Vec2::new(s, s);
        reqs.push(adj);
    }
    let nothing = |_: &LayerRequest| LayerSource::Hidden;
    let no_grade = |_: &LayerRequest| None;
    let inputs = Inputs { grade: &no_grade, split: None, mattes: None, source: &nothing };
    let frame =
        pc.render(&reqs, &f, &RenderOptions { readback: true, ..RenderOptions::default() }, &inputs).expect("render");
    pc.download_rgba8(frame).expect("download")
}

fn write_png(path: &Path, rgba: &[u8]) {
    let file = std::fs::File::create(path).expect("create png");
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), W as u32, H as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().expect("header").write_image_data(rgba).expect("data");
}

#[test]
fn a_zoom_layer_enlarges_everything_below_it() {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let plain = render(&mut pc, None);
    let zoomed = render(&mut pc, Some(1.05635));
    let at = |px: &[u8], x: usize, y: usize| px[(y * W + x) * 4];
    // The white square's left edge sits at x = 0.225 W without the layer; 5.6 % larger it moves outward by ~7 px.
    let edge = |px: &[u8]| (0..W / 2).find(|&x| at(px, x, H / 4) > 150).expect("edge");
    let (a, b) = (edge(&plain), edge(&zoomed));
    assert!(b + 5 < a, "the edge moved outward: {a} -> {b}");
    if let Ok(dir) = std::env::var("SQ_PROOF_DIR") {
        std::fs::create_dir_all(&dir).expect("proof dir");
        write_png(&Path::new(&dir).join("without-layer.png"), &plain);
        write_png(&Path::new(&dir).join("with-layer.png"), &zoomed);
    }
}

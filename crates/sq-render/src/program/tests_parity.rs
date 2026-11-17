//! Cross-platform parity harness: fixed inputs through the real program render path to PNG, no window. Run with
//! `SQ_PARITY_OUT=<dir> cargo test -p sq-render parity_dump -- --nocapture` (see docs/rust/PARITY-HARNESS.md); the same
//! command on Mac and Windows, then `scripts/parity-compare <dirA> <dirB>`. Without SQ_PARITY_OUT the test only checks
//! that the card renders. Inputs: a synthetic Rec.709 limited-range NV12 test card and, when `SQ_PARITY_NV12=<file>`
//! (raw NV12, 640x360, see the doc) is set, one real frame.

use super::{Inputs, LayerSource, ProgramCompositor, RenderOptions, Source};
use crate::compositor::gpu_test_support::gpu;
use crate::program::CpuPlanes;
use sq_core_effects::evaluation::LayerRequest;
use sq_core_model::{PixelAspect, SequenceFormat, VideoTrackInfo};
use sq_core_time::{Id, Time};
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat};
use std::path::PathBuf;
use std::sync::Arc;

const W: usize = 640;
const H: usize = 360;

/// Full-range RGB (0...255, as the card is authored: display code values) to BT.709 limited-range Y'CbCr.
fn rgb_to_ycbcr(rgb: [u8; 3]) -> [u8; 3] {
    let [r, g, b] = rgb.map(|v| f64::from(v) / 255.0);
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    let cb = (b - y) / 1.8556;
    let cr = (r - y) / 1.5748;
    let q = |v: f64| v.round().clamp(0.0, 255.0) as u8;
    [q(16.0 + 219.0 * y), q(128.0 + 224.0 * cb), q(128.0 + 224.0 * cr)]
}

/// 5x7 glyphs of "SQ 709 TEXT" (rows, MSB = left column of 5).
fn glyph(c: char) -> [u8; 7] {
    match c {
        'S' => [0x0e, 0x11, 0x10, 0x0e, 0x01, 0x11, 0x0e],
        'Q' => [0x0e, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0d],
        '7' => [0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        '0' => [0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e],
        '9' => [0x0e, 0x11, 0x11, 0x0f, 0x01, 0x11, 0x0e],
        'T' => [0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        'E' => [0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f],
        'X' => [0x11, 0x11, 0x0a, 0x04, 0x0a, 0x11, 0x11],
        _ => [0; 7],
    }
}

/// Patch list (name, rect x, y, w, h, display RGB) of the card; also written to `card-patches.tsv` for the comparator.
fn patches() -> Vec<(String, usize, usize, usize, usize, [u8; 3])> {
    let mut v = Vec::new();
    // 17-step gray ramp, 0...255 (step 16, last 255), top row.
    for i in 0..17 {
        let g = if i == 16 { 255 } else { (i * 16) as u8 };
        v.push((format!("gray{g}"), i * 36 + 14, 8, 36, 100, [g, g, g]));
    }
    let colors: [(&str, [u8; 3]); 8] = [
        ("red", [255, 0, 0]),
        ("green", [0, 255, 0]),
        ("blue", [0, 0, 255]),
        ("cyan", [0, 255, 255]),
        ("magenta", [255, 0, 255]),
        ("yellow", [255, 255, 0]),
        ("skin", [224, 172, 140]),
        ("skin_dark", [141, 85, 60]),
    ];
    for (i, (n, c)) in colors.iter().enumerate() {
        v.push(((*n).to_string(), 16 + i * 76, 124, 72, 96, *c));
    }
    v
}

/// The card as straight display RGB (full range), then converted to NV12 with 4:2:0 box-averaged chroma.
fn card_nv12() -> Vec<u8> {
    let mut rgb = vec![[96u8, 96, 96]; W * H];
    for (_, x, y, w, h, c) in patches() {
        for yy in y..y + h {
            for xx in x..x + w {
                rgb[yy * W + xx] = c;
            }
        }
    }
    // Text on gray: white on the left half, black on the right, scale 6.
    let mut put = |text: &str, x0: usize, y0: usize, c: [u8; 3]| {
        for (i, ch) in text.chars().enumerate() {
            for (row, bits) in glyph(ch).iter().enumerate() {
                for col in 0..5 {
                    if bits >> (4 - col) & 1 == 1 {
                        for dy in 0..6 {
                            for dx in 0..6 {
                                rgb[(y0 + row * 6 + dy) * W + x0 + (i * 6 + col) * 6 + dx] = c;
                            }
                        }
                    }
                }
            }
        }
    };
    put("SQ 709", 20, 250, [255, 255, 255]);
    put("TEXT", 380, 250, [0, 0, 0]);
    let mut out = vec![0u8; W * H * 3 / 2];
    for i in 0..W * H {
        out[i] = rgb_to_ycbcr(rgb[i])[0];
    }
    for cy in 0..H / 2 {
        for cx in 0..W / 2 {
            let (mut cb, mut cr) = (0u32, 0u32);
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let p = rgb_to_ycbcr(rgb[(cy * 2 + dy) * W + cx * 2 + dx]);
                cb += u32::from(p[1]);
                cr += u32::from(p[2]);
            }
            out[W * H + cy * W + cx * 2] = ((cb + 2) / 4) as u8;
            out[W * H + cy * W + cx * 2 + 1] = ((cr + 2) / 4) as u8;
        }
    }
    out
}

fn info() -> VideoTrackInfo {
    VideoTrackInfo {
        width: W as i64,
        height: H as i64,
        codec: "h264".into(),
        bit_depth: 8,
        chroma: "4:2:0".into(),
        nominal_frame_duration: Time::new(1, 25),
        is_variable_frame_rate: false,
        color_primaries: None,
        transfer: None,
        matrix: None,
        rotation: 0,
        pixel_aspect: PixelAspect::square(),
        pixel_aspect_override: None,
        field_order: None,
        deinterlace_off: false,
    }
}

fn render_nv12(name: &str, bytes: Vec<u8>, out: Option<&PathBuf>) {
    let Some(gpu) = gpu() else { return };
    let mut pc = ProgramCompositor::new(&gpu).expect("compositor");
    let f = SequenceFormat {
        width: W as i64,
        height: H as i64,
        frame_duration: Time::new(1, 25),
        audio_sample_rate: 48_000,
        pixel_aspect_store: None,
        unknown: sq_core_model::UnknownKeys::default(),
    };
    let frame = SQFrame::new(
        W,
        H,
        SQFramePixelFormat::Nv12,
        SQFrameColorSpace::Rec709,
        Time::ZERO,
        Arc::new(CpuPlanes { bytes: bytes.into() }),
    );
    let req = LayerRequest::new(Id::from_u128(1), Id::from_u128(101), Id::from_u128(200), Time::ZERO);
    let source = |l: &LayerRequest| {
        LayerSource::Media(Source {
            media: l.media,
            index: 0,
            frame: frame.clone(),
            info: info(),
            proxy: false,
            divisor: 1,
            gyro: None,
        })
    };
    let grade = |_: &LayerRequest| None;
    let inputs = Inputs { grade: &grade, split: None, mattes: None, source: &source };
    let opts = RenderOptions { readback: true, ..RenderOptions::default() };
    let rendered = pc.render(&[req], &f, &opts, &inputs).expect("render");
    let px = pc.download_rgba8(rendered).expect("download");
    assert_eq!(px.len(), W * H * 4);
    if let Some(dir) = out {
        std::fs::create_dir_all(dir).expect("dir");
        let file = std::fs::File::create(dir.join(format!("{name}.png"))).expect("png file");
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), W as u32, H as u32);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        enc.write_header().expect("header").write_image_data(&px).expect("png data");
        let info = gpu.info();
        std::fs::write(dir.join("adapter.txt"), format!("{} ({:?})\n", info.name, info.backend)).expect("adapter");
        let tsv: String = patches().iter().map(|(n, x, y, w, h, _)| format!("{n}\t{x}\t{y}\t{w}\t{h}\n")).collect();
        std::fs::write(dir.join("card-patches.tsv"), tsv).expect("patches");
    }
}

#[test]
fn parity_dump() {
    let out = std::env::var("SQ_PARITY_OUT").ok().map(PathBuf::from);
    render_nv12("card", card_nv12(), out.as_ref());
    if let Ok(path) = std::env::var("SQ_PARITY_NV12") {
        let bytes = std::fs::read(&path).expect("SQ_PARITY_NV12 file");
        assert_eq!(bytes.len(), W * H * 3 / 2, "raw NV12 {W}x{H}");
        render_nv12("clip", bytes, out.as_ref());
    }
}

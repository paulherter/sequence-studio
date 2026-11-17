//! Premiere text layers through the mapper. Swift: MapperTests.swift (textGraphicBecomesTextClip,
//! twoLineTextWithASecondStyleKeepsBothLines, textBackground*, textShadow*, multiTextGraphicBecomesOneGraphicsClip...).
#![allow(clippy::unwrap_used, reason = "helpers of integration tests; clippy.toml only covers test functions")]

mod common;

use common::{BackgroundSpec, FlatBlob, ItemSpec, PRFixture, SECOND as S, ShadowSpec, Source};
use sq_core_model::{Clip, TrackKind};
use sq_core_time::{SequentialIds, Time};
use sq_premiere_import::prdocument::PRReader;
use sq_premiere_import::primport_report::Status;
use sq_premiere_import::prmapper::{PRImportResult, PRMapper};
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::{BoxPadding, FontWeight, RGBAColor, TextAlignment};
use std::collections::BTreeMap;

/// Layout needs the bundled fonts (the Swift package folder, as sq-text's own tests use).
fn fonts() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    sq_text::portable_font_match::set_fonts_root(&root);
}

fn map(f: &PRFixture) -> PRImportResult {
    fonts();
    let doc = PRReader::read(&f.data()).unwrap();
    PRMapper::map(&doc, "Test", &BTreeMap::new(), false, &mut SequentialIds::default())
}

fn clips(r: &PRImportResult) -> Vec<Clip> {
    let tl = r.project.timelines.iter().find(|t| t.name == "Main").unwrap();
    tl.tracks.iter().filter(|t| t.kind == TrackKind::Video).flat_map(|t| t.clips().to_vec()).collect()
}

fn graphic(start: i64, end: i64, comps: &[&str]) -> ItemSpec {
    ItemSpec::new(start, end, 3600 * S, 3601 * S, Source::Graphic).components(comps).name("Graphic")
}

/// One text graphic from a blob, mapped; the text clip's decoded template.
fn one_text(blob: &[u8]) -> (PRImportResult, sq_text::text_template::TextTemplate) {
    let mut f = PRFixture::new();
    let p = f.blob_param(1, &sq_core_time::base64::encode(blob), "h");
    let text = f.component("AE.ADBE Text", &[p]);
    let it = f.item(graphic(0, S, &[&text]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let c = clips(&r).remove(0);
    let (template, _) = TextGenerator::decode(c.generator.as_ref().unwrap()).unwrap();
    (r, template)
}

fn near(a: f64, b: f64, e: f64) -> bool {
    (a - b).abs() < e
}

#[test]
fn text_graphic_becomes_text_clip() {
    let mut f = PRFixture::new();
    let blob =
        sq_core_time::base64::encode(&FlatBlob::premiere_text("hier sind", "Inter-Bold", 73.144, -44.0, None, None));
    let bp = f.blob_param(1, &blob, "h");
    let pos = f.pt(3, "0.5:0.5");
    let text = f.component("AE.ADBE Text", &[bp, pos]);
    let (a, b, c) = (f.pt(1, "0.5:0.7"), f.pt(2, "0.5:0.7"), f.p(3, "100."));
    let geo = f.component("AE.ADBE Geometry2", &[a, b, c]);
    let it = f.item(graphic(2 * S, 3 * S, &[&geo, &text]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let c = clips(&r).remove(0);
    assert!(c.start == Time::new(2, 1) && c.duration() == Time::new(1, 1));
    let (template, _) = TextGenerator::decode(c.generator.as_ref().unwrap()).unwrap();
    assert_eq!(template.text, "hier sind");
    assert_eq!(template.style.font_name, "Inter-Bold");
    let size = 73.144 * 1.02;
    assert!(near(template.style.size, size, 0.001));
    assert!(near(template.style.tracking, -44.0 / 1000.0 * size * 0.6, 1e-3));
    assert_eq!(template.style.alignment, TextAlignment::Center);
    // Centered at the Geometry2 point (0.7 * 1920 - 960 = 384 below center) plus the glyph-center calibration (29).
    assert_eq!(c.animation.position.value.x, 0.0);
    assert_eq!(c.animation.position.value.y, 0.0);
    assert!(near(c.animation.anchor.value.y + 384.0 + 29.0, 0.0, 1e-6) && c.animation.anchor.value.x == 0.0);
    assert_eq!(r.report.status_of("Text"), Some(Status::Approximated));
}

#[test]
fn two_line_text_with_a_second_style_keeps_both_lines() {
    let blob = FlatBlob::premiere_runs(
        &[("Bis zu\r", 0, 136.0), ("3.200", 1, 195.0)],
        &["BasicSans-Regular", "BasicSans-Bold"],
    );
    let (_, template) = one_text(&blob);
    assert_eq!(template.text, "Bis zu\n3.200");
    assert!(template.style.font_name == "BasicSans-Regular" && template.style.weight == FontWeight::Regular);
    assert!(near(template.style.size, 136.0 * 1.02, 1e-3));
    let second = template.style.second_line.unwrap();
    assert!(second.font_name == "BasicSans-Bold" && second.weight == FontWeight::Bold);
    assert!(near(second.size, 195.0 * 1.02, 1e-3));
}

#[test]
fn text_background_off_keeps_white_fill() {
    let bg = BackgroundSpec { rgb: (75, 203, 214), on: false, opacity: 100.0, size: 9.0, radius: 0.0 };
    let (_, template) = one_text(&FlatBlob::premiere_text("Aa", "Inter-Bold", 80.0, 0.0, None, Some(bg)));
    assert_eq!(template.style.color, RGBAColor::WHITE);
    assert!(template.style.background.is_none());
}

#[test]
fn text_background_on_carries_over() {
    let bg = BackgroundSpec { rgb: (0xEE, 0x4A, 0x4A), on: true, opacity: 50.0, size: 10.0, radius: 4.0 };
    let (_, template) = one_text(&FlatBlob::premiere_text("Aa", "Inter-Bold", 80.0, 0.0, None, Some(bg)));
    assert_eq!(template.style.color, RGBAColor::WHITE);
    let bg = template.style.background.unwrap();
    let (r, g, b) = (f64::from(0xEE_u8) / 255.0, f64::from(0x4A_u8) / 255.0, 0.5);
    assert!(
        near(bg.color.red, r, 1e-9)
            && near(bg.color.green, g, 1e-9)
            && near(bg.color.blue, g, 1e-9)
            && bg.color.alpha == b
    );
    assert!(bg.padding == BoxPadding { horizontal: 10.0, vertical: 10.0 } && bg.corner_radius == 4.0);
}

#[test]
fn text_shadow_carries_over() {
    let sh = ShadowSpec {
        rgb: (0, 0, 0),
        on: true,
        opacity: 90.781,
        distance: 17.764,
        angle: 19.255,
        size: 20.461,
        blur: 178.612,
    };
    let (_, template) = one_text(&FlatBlob::premiere_text("auf Audio", "Inter-Bold", 90.0, 0.0, Some(sh), None));
    let s = template.style.shadow.unwrap();
    assert!(s.color.red == 0.0 && near(s.color.alpha, 0.90781, 1e-4));
    // Fields 20/34 are style constants, not angle / distance.
    assert!(s.distance() == 0.0 && s.offset_x == 0.0 && s.offset_y == 0.0);
    // Size becomes the spread (x 0.28), Blur is scaled (x 0.26).
    assert!(near(s.spread, 20.461 * 0.28, 0.01) && near(s.blur, 178.612 * 0.26, 0.01));
    assert!(s.spread > 5.0 && s.blur > 40.0);
}

#[test]
fn text_shadow_size_and_blur_land_in_their_own_fields() {
    let sh = ShadowSpec { rgb: (0, 0, 0), on: true, opacity: 90.0, distance: 0.0, angle: 0.0, size: 25.3, blur: 151.0 };
    let (_, template) = one_text(&FlatBlob::premiere_text("Bottom", "Inter-Bold", 90.0, -30.0, Some(sh), None));
    let s = template.style.shadow.unwrap();
    assert!(s.angle() == 0.0 && s.distance() == 0.0);
    assert!(near(s.spread, 25.3 * 0.28, 0.01) && near(s.blur, 151.0 * 0.26, 0.01));
}

/// Point text (layer position off center): the layer Scale multiplies the size, alignment is kept, the text center is
/// the first line's baseline position moved to the canvas center.
#[test]
fn point_text_uses_layer_scale_and_alignment() {
    let mut f = PRFixture::new();
    let blob = sq_core_time::base64::encode(&FlatBlob::premiere_text("one", "Inter-Bold", 60.0, 0.0, None, None));
    let (bp, pos, scale) = (f.blob_param(1, &blob, "h"), f.pt(3, "0.3:0.4"), f.p(4, "150."));
    let text = f.component("AE.ADBE Text", &[bp, pos, scale]);
    let it = f.item(graphic(0, S, &[&text]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let c = clips(&r).remove(0);
    let (template, _) = TextGenerator::decode(c.generator.as_ref().unwrap()).unwrap();
    assert!(near(template.style.size, 60.0 * 1.5 * 1.02, 1e-6));
    assert_eq!(template.style.alignment, TextAlignment::Left);
    assert_eq!(r.report.status_of("Point text"), Some(Status::Approximated));
}

/// Two text layers become one Graphics clip, a text layer each (Swift multiTextGraphicBecomesOneGraphicsClip...).
#[test]
fn multi_text_graphic_becomes_one_graphics_clip() {
    let mut f = PRFixture::new();
    let mut comps = Vec::new();
    for (s, pos) in [("one", "0.3:0.4"), ("two", "0.6:0.7")] {
        let blob = sq_core_time::base64::encode(&FlatBlob::premiere_text(s, "Inter-Bold", 60.0, 0.0, None, None));
        let (bp, p, sc) = (f.blob_param(1, &blob, "h"), f.pt(3, pos), f.p(4, "150."));
        comps.push(f.component("AE.ADBE Text", &[bp, p, sc]));
    }
    let refs: Vec<&str> = comps.iter().map(String::as_str).collect();
    let it = f.item(graphic(0, S, &refs));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let cs = clips(&r);
    assert_eq!(cs.len(), 1);
    assert!(cs[0].is_graphics());
    let doc = cs[0].graphics().unwrap();
    assert!(doc.layers.len() == 2 && doc.layers.iter().all(|l| l.is_text()));
    assert_eq!(r.report.status_of("Second text layer in a graphic"), Some(Status::Mapped));
}

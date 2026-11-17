// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MogrtImportTests.swift (the cases that need no text mapping; text layers are skipped until the text generator is ported)
#![allow(clippy::unwrap_used, reason = "helpers of integration tests; clippy.toml only covers test functions")]

mod common;

use common::{ItemSpec, PRFixture, SECOND as S, Source};
use sq_core_time::SequentialIds;
use sq_premiere_import::mogrt::{MogrtImportError, MogrtImporter};

fn crc32(data: &[u8]) -> u32 {
    let mut c = !0u32;
    for b in data {
        c ^= u32::from(*b);
        for _ in 0..8 {
            c = if c & 1 != 0 { (c >> 1) ^ 0xEDB8_8320 } else { c >> 1 };
        }
    }
    !c
}

/// A ZIP with stored (uncompressed) entries.
fn zip(files: &[(&str, &[u8])]) -> Vec<u8> {
    let (mut out, mut central) = (Vec::new(), Vec::new());
    for (name, data) in files {
        let offset = out.len() as u32;
        let head = |v: &mut Vec<u8>, sig: &[u8], central: bool| {
            v.extend_from_slice(sig);
            if central {
                v.extend_from_slice(&20u16.to_le_bytes());
            }
            v.extend_from_slice(&20u16.to_le_bytes());
            v.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0]);
            v.extend_from_slice(&crc32(data).to_le_bytes());
            v.extend_from_slice(&(data.len() as u32).to_le_bytes());
            v.extend_from_slice(&(data.len() as u32).to_le_bytes());
            v.extend_from_slice(&(name.len() as u16).to_le_bytes());
            v.extend_from_slice(&0u16.to_le_bytes());
        };
        head(&mut out, &[0x50, 0x4b, 3, 4], false);
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(data);
        head(&mut central, &[0x50, 0x4b, 1, 2], true);
        central.extend_from_slice(&[0; 10]);
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(name.as_bytes());
    }
    let cd_offset = out.len() as u32;
    out.extend_from_slice(&central);
    out.extend_from_slice(&[0x50, 0x4b, 5, 6, 0, 0, 0, 0]);
    out.extend_from_slice(&(files.len() as u16).to_le_bytes());
    out.extend_from_slice(&(files.len() as u16).to_le_bytes());
    out.extend_from_slice(&(central.len() as u32).to_le_bytes());
    out.extend_from_slice(&cd_offset.to_le_bytes());
    out.extend_from_slice(&[0, 0]);
    out
}

fn definition(name: &str, author: Option<&str>, controls: &str) -> Vec<u8> {
    let author = author.map_or(String::new(), |a| format!(r#""authorApp":"{a}","#));
    format!(
        r#"{{{author}"capsuleName":"{name}","capsuleNameLocalized":{{"strDB":[{{"localeString":"en_US","str":"{name}"}}]}},
        "clientControls":[{controls}],"sourceInfoLocalized":{{"en_US":{{"duration":{{"scale":1,"value":5}},
        "framesize":{{"size":{{"x":1920,"y":1080}}}}}}}},"usedFontsLocalized":{{"en_US":["Inter-Bold"]}}}}"#
    )
    .into_bytes()
}

fn read(data: &[u8], file_name: &str) -> Result<sq_premiere_import::mogrt::MogrtImportResult, MogrtImportError> {
    MogrtImporter::read(data, file_name, &mut SequentialIds::default())
}

#[test]
fn after_effects_template_is_refused_with_a_clear_message() {
    let aep = zip(&[("comp.aep", b"RIFX")]);
    let by_author = zip(&[("project.aegraphic", &aep), ("definition.json", &definition("Testo", Some("aefx"), ""))]);
    assert_eq!(read(&by_author, "x").unwrap_err(), MogrtImportError::NeedsAfterEffects { name: "Testo".into() });
    // No author key: the composition file decides, and an empty name takes the file name.
    let by_file = zip(&[("project.aegraphic", &aep), ("definition.json", &definition("", None, ""))]);
    assert_eq!(
        read(&by_file, "Fallback").unwrap_err(),
        MogrtImportError::NeedsAfterEffects { name: "Fallback".into() }
    );
    let message = MogrtImportError::NeedsAfterEffects { name: "Testo".into() }.to_string();
    assert!(message.contains("Testo") && message.contains("needs After Effects to render"));
    assert_eq!(read(b"not a zip", "x").unwrap_err(), MogrtImportError::NotATemplate);
}

#[test]
fn template_without_text_reports_nothing_importable_and_lists_the_controls() {
    let mut f = PRFixture::new();
    let point = f.pt(4, "0.5:0.5");
    let shape = f.component("AE.ADBE Shape", &[point]);
    let item = f.item(ItemSpec::new(0, S, 0, S, Source::Graphic).components(&[&shape]));
    let track = f.track(&[item]);
    f.sequence("T", &[track], &[]);
    let slider = r#"{"id":"9","type":2,"uiName":{"strDB":[{"localeString":"en_US","str":"Bar Width"}]},"value":40}"#;
    let graphic = zip(&[("lower third.prproj", &f.data())]);
    let pkg = zip(&[("project.prgraphic", &graphic), ("definition.json", &definition("Bar", Some("ppro"), slider))]);
    match read(&pkg, "x").unwrap_err() {
        MogrtImportError::NothingImportable { name, dropped } => assert!(name == "Bar" && dropped >= 1, "{dropped}"),
        other => panic!("{other:?}"),
    }
}

#[test]
fn control_feature_names_the_control_and_its_type() {
    let def = sq_premiere_import::mogrt::MogrtDefinition::parse(&definition(
        "T",
        Some("ppro"),
        r#"{"id":"9","type":2,"uiName":{"strDB":[{"localeString":"en_US","str":"Bar Width"}]},"value":40}"#,
    ))
    .unwrap();
    assert_eq!(MogrtImporter::control_feature(&def.controls[0]), "Control \u{201c}Bar Width\u{201d} (slider)");
}

// MARK: Shapes, text fill and alignment, point form (Swift MogrtShapeTests.swift)

use sq_core_model::{ClipEffect, GraphicsContent, GraphicsLayer, ShapeKind};
use sq_premiere_import::primport_report::Status;
use sq_premiere_import::prtext_blob::PRTextBlob;
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::TextAlignment;

type Pt = ((f64, f64), Option<(f64, f64)>, Option<(f64, f64)>);

fn header(json: &str) -> String {
    let mut b = vec![0u8; 8];
    for u in json.encode_utf16() {
        b.extend_from_slice(&u.to_le_bytes());
    }
    sq_core_time::base64::encode(&b)
}

/// The legacy text blob of real templates: 8-byte header, UTF-16LE JSON.
fn legacy_text(s: &str, fill: Option<i64>, alignment: Option<i64>) -> String {
    let v = |x: String| format!("{{\"mParamValues\":[[0,{x}]]}}");
    let mut sheet = format!(
        "\"mText\":\"{s}\",\"mFontName\":{},\"mFontSize\":{},\"mTracking\":{}",
        v("\"Inter-Bold\"".into()),
        v("60".into()),
        v("0".into())
    );
    if let Some(f) = fill {
        sheet += &format!(",\"mFillVisible\":{},\"mFillColor\":{}", v("true".into()), v(f.to_string()));
    }
    let align = alignment.map(|a| format!("\"mAlignment\":{a},")).unwrap_or_default();
    header(&format!("{{\"mTextParam\":{{{align}\"mStyleSheet\":{{{sheet}}}}}}}"))
}

/// A path blob: u32 2, u32 count, per point a zero float and vertex / in / out handle (x, y); one closing byte.
fn path(points: &[Pt]) -> String {
    let mut d: Vec<u8> = Vec::new();
    d.extend_from_slice(&2u32.to_le_bytes());
    d.extend_from_slice(&(points.len() as u32).to_le_bytes());
    for (v, tin, tout) in points {
        let (i, o) = (tin.unwrap_or(*v), tout.unwrap_or(*v));
        for x in [0.0, v.0, v.1, i.0, i.1, o.0, o.1] {
            d.extend_from_slice(&(x as f32).to_bits().to_le_bytes());
        }
    }
    d.push(1);
    sq_core_time::base64::encode(&d)
}

fn rect(x0: f64, y0: f64, x1: f64, y1: f64) -> String {
    path(&[((x0, y0), None, None), ((x1, y0), None, None), ((x1, y1), None, None), ((x0, y1), None, None)])
}

fn appearance(fill: Option<i64>, stroke: Option<i64>, stroke_width: f64) -> String {
    header(&format!(
        "{{\"mStyle\":{{\"mFillColor\":{},\"mFillVisible\":{},\"mStrokeColor\":{},\"mStrokeVisible\":{},\"mStrokeWidth\":{stroke_width},\"mShadowVisible\":false}},\"mVersion\":1}}",
        fill.unwrap_or(0),
        fill.is_some(),
        stroke.unwrap_or(0),
        stroke.is_some()
    ))
}

struct ShapeSpec<'a> {
    blob: String,
    appearance: String,
    position: &'a str,
    anchor: &'a str,
    scale: &'a str,
    rotation: &'a str,
    opacity: &'a str,
}

fn shape_spec(blob: String) -> ShapeSpec<'static> {
    ShapeSpec {
        blob,
        appearance: appearance(Some(0), None, 1.0),
        position: "0.5:0.5",
        anchor: "0:0",
        scale: "100.",
        rotation: "0.",
        opacity: "100.",
    }
}

fn shape_component(f: &mut PRFixture, s: &ShapeSpec) -> String {
    let ps = [
        f.blob_param(1, &s.blob, "h1"),
        f.blob_param(2, &s.appearance, "h2"),
        f.pt(4, s.position),
        f.p(5, s.scale),
        f.p(6, s.scale),
        f.p(7, "true"),
        f.p(8, s.rotation),
        f.p(9, s.opacity),
        f.pt(10, s.anchor),
    ];
    f.component("AE.ADBE Shape", &ps)
}

fn text_component(f: &mut PRFixture, s: &str, fill: Option<i64>, alignment: Option<i64>) -> String {
    let ps = [f.blob_param(1, &legacy_text(s, fill, alignment), "ht"), f.pt(3, "0.3:0.8"), f.p(4, "100.")];
    f.component("AE.ADBE Text", &ps)
}

fn package(f: &mut PRFixture, components: &[String]) -> Vec<u8> {
    let refs: Vec<&str> = components.iter().map(String::as_str).collect();
    let item = f.item(ItemSpec::new(0, 3 * S, 0, 3 * S, Source::Graphic).components(&refs));
    let track = f.track(&[item]);
    f.sequence_with("T", 8_467_200_000, 1920, 1080, &[track], &[], None, &[]);
    let graphic = zip(&[("lower third.prproj", &f.data())]);
    zip(&[("project.prgraphic", &graphic), ("definition.json", &definition("T", Some("ppro"), ""))])
}

/// Layout needs the bundled fonts (the Swift package folder, as sq-text's own tests use).
fn fonts() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    sq_text::portable_font_match::set_fonts_root(&root);
}

fn read_components(f: &mut PRFixture, components: &[String]) -> sq_premiere_import::mogrt::MogrtImportResult {
    fonts();
    let pkg = package(f, components);
    read(&pkg, "x").unwrap()
}

fn layers(r: &sq_premiere_import::mogrt::MogrtImportResult) -> Vec<GraphicsLayer> {
    let clip = r.template.content.tracks.iter().flat_map(|t| t.clips()).next().unwrap();
    clip.graphics().unwrap().layers.clone()
}

fn first_clip(r: &sq_premiere_import::mogrt::MogrtImportResult) -> &sq_core_model::Clip {
    r.template.content.tracks.iter().flat_map(|t| t.clips()).next().unwrap()
}

fn num(e: &ClipEffect, key: &str) -> f64 {
    e.parameters[key].value
}

#[test]
fn legacy_blob_alignment_maps_the_nstext_order() {
    for (raw, expected) in [(0, 0), (1, 1), (2, 2), (3, 0), (4, 1), (5, 2)] {
        let t = PRTextBlob::decode_base64(&legacy_text("A", Some(0xFF0000), Some(raw))).unwrap();
        assert_eq!(t.alignment, Some(expected), "raw {raw}");
    }
    assert_eq!(PRTextBlob::decode_base64(&legacy_text("A", None, None)).unwrap().alignment, None);
    assert_eq!(PRTextBlob::decode_base64(&legacy_text("A", None, Some(9))).unwrap().alignment, None);
}

#[test]
fn text_keeps_its_real_fill_and_alignment() {
    let mut f = PRFixture::new();
    let t = text_component(&mut f, "Right Cyan", Some(0x00B5E2), Some(1));
    let r = read_components(&mut f, &[t]);
    let layer = &r.description.text_layers[0];
    assert_eq!(layer.alignment, Some(1));
    let c = layer.color.unwrap();
    assert!(c.red.abs() < 0.01 && (c.green - 181.0 / 255.0).abs() < 0.01 && (c.blue - 226.0 / 255.0).abs() < 0.01);
    let (tpl, _) = TextGenerator::decode(first_clip(&r).generator.as_ref().unwrap()).unwrap();
    assert_eq!(tpl.style.alignment, TextAlignment::Right);
    assert!((tpl.style.color.green - 181.0 / 255.0).abs() < 0.01);
}

#[test]
fn left_aligned_point_text_is_left_and_center_stays_center() {
    for (raw, expected) in [(0, TextAlignment::Left), (2, TextAlignment::Center)] {
        let mut f = PRFixture::new();
        let t = text_component(&mut f, "Name", Some(0xFFFFFF), Some(raw));
        let r = read_components(&mut f, &[t]);
        let (tpl, _) = TextGenerator::decode(first_clip(&r).generator.as_ref().unwrap()).unwrap();
        assert_eq!(tpl.style.alignment, expected, "raw {raw}");
    }
}

#[test]
fn rectangle_shape_becomes_a_filled_rectangle_layer_below_the_text() {
    let mut f = PRFixture::new();
    let mut spec = shape_spec(rect(0.0, 0.0, 400.0, 100.0));
    spec.appearance = appearance(Some(0xFF0000), Some(0xFFFFFF), 4.0);
    spec.anchor = "0.104166:0.0925926";
    let s = shape_component(&mut f, &spec);
    let t = text_component(&mut f, "Name", Some(0xFFFFFF), Some(2));
    let r = read_components(&mut f, &[t, s]);
    let ls = layers(&r);
    assert!(ls.len() == 2 && !ls[0].is_text() && ls[1].is_text(), "bottom first");
    let l = &ls[0];
    assert!(matches!(l.content, GraphicsContent::Shape { kind: ShapeKind::Rectangle }));
    let e = l.shape_effect().unwrap();
    assert!(num(e, ClipEffect::SHAPE_WIDTH_KEY) == 400.0 && num(e, ClipEffect::SHAPE_HEIGHT_KEY) == 100.0);
    assert!(num(e, ClipEffect::SHAPE_FILL_KEY) == 1.0 && num(e, ClipEffect::SHAPE_STROKE_KEY) == 1.0);
    assert_eq!(num(e, ClipEffect::SHAPE_STROKE_WIDTH_KEY), 4.0);
    let fill = e.colors[ClipEffect::SHAPE_FILL_COLOR_KEY].value;
    assert!(fill.red == 1.0 && fill.green == 0.0 && fill.blue == 0.0);
    // Box center (200, 50) minus the anchor (200, 100) lands the center 50 px above the frame center.
    let p = l.animation.position.value;
    assert!(p.x.abs() < 0.5 && (p.y + 50.0).abs() < 0.5, "{p:?}");
    assert_eq!(r.report.status_of("Shape layer"), Some(Status::Mapped));
    assert_eq!(r.template.slots.len(), 1);
}

#[test]
fn scale_rotation_and_opacity_of_a_shape_carry_over() {
    let mut f = PRFixture::new();
    let mut spec = shape_spec(rect(0.0, 0.0, 200.0, 100.0));
    (spec.position, spec.scale, spec.rotation, spec.opacity) = ("0.25:0.5", "50.", "10.", "40.");
    let s = shape_component(&mut f, &spec);
    let t = text_component(&mut f, "A", Some(0xFFFFFF), Some(2));
    let l = layers(&read_components(&mut f, &[t, s])).remove(0);
    let e = l.shape_effect().unwrap();
    assert!(num(e, ClipEffect::SHAPE_WIDTH_KEY) == 100.0 && num(e, ClipEffect::SHAPE_HEIGHT_KEY) == 50.0);
    assert!(l.animation.rotation.value == 10.0 && (l.animation.opacity.value - 0.4).abs() < 1e-9);
    // Local center (100, 50) scaled by 0.5 = (50, 25), rotated 10 degrees, on the position (480, 540) from frame center (960, 540).
    let (c, s) = (10f64.to_radians().cos(), 10f64.to_radians().sin());
    let p = l.animation.position.value;
    assert!((p.x - (480.0 + 50.0 * c - 25.0 * s - 960.0)).abs() < 0.5, "{p:?}");
    assert!((p.y - (50.0 * s + 25.0 * c)).abs() < 0.5, "{p:?}");
}

#[test]
fn ellipse_shape_is_an_ellipse_layer() {
    let mut f = PRFixture::new();
    let k = 0.5523;
    let pts: [Pt; 4] = [
        ((100.0, 0.0), Some((100.0 - 100.0 * k, 0.0)), Some((100.0 + 100.0 * k, 0.0))),
        ((200.0, 50.0), Some((200.0, 50.0 - 50.0 * k)), Some((200.0, 50.0 + 50.0 * k))),
        ((100.0, 100.0), Some((100.0 + 100.0 * k, 100.0)), Some((100.0 - 100.0 * k, 100.0))),
        ((0.0, 50.0), Some((0.0, 50.0 + 50.0 * k)), Some((0.0, 50.0 - 50.0 * k))),
    ];
    let s = shape_component(&mut f, &shape_spec(path(&pts)));
    let t = text_component(&mut f, "A", Some(0xFFFFFF), Some(2));
    let l = layers(&read_components(&mut f, &[t, s])).remove(0);
    assert!(matches!(l.content, GraphicsContent::Shape { kind: ShapeKind::Ellipse }), "{:?}", l.content);
    assert_eq!(num(l.shape_effect().unwrap(), ClipEffect::SHAPE_WIDTH_KEY), 200.0);
}

#[test]
fn rounded_rectangle_keeps_its_corner_radius() {
    let mut f = PRFixture::new();
    let r12 = 12.0;
    let p = |x: f64, y: f64| ((x, y), None, None);
    let pts: [Pt; 8] = [
        p(r12, 0.0),
        p(300.0 - r12, 0.0),
        p(300.0, r12),
        p(300.0, 80.0 - r12),
        p(300.0 - r12, 80.0),
        p(r12, 80.0),
        p(0.0, 80.0 - r12),
        p(0.0, r12),
    ];
    let s = shape_component(&mut f, &shape_spec(path(&pts)));
    let t = text_component(&mut f, "A", Some(0xFFFFFF), Some(2));
    let l = layers(&read_components(&mut f, &[t, s])).remove(0);
    assert_eq!(num(l.shape_effect().unwrap(), ClipEffect::SHAPE_CORNER_RADIUS_KEY), 12.0);
}

#[test]
fn straight_polygon_becomes_a_closed_path() {
    let mut f = PRFixture::new();
    let tri = path(&[((0.0, 100.0), None, None), ((100.0, 0.0), None, None), ((200.0, 100.0), None, None)]);
    let s = shape_component(&mut f, &shape_spec(tri));
    let t = text_component(&mut f, "A", Some(0xFFFFFF), Some(2));
    let r = read_components(&mut f, &[t, s]);
    let GraphicsContent::Path { points, closed } = &layers(&r)[0].content else { panic!("not a path") };
    assert!(*closed && points.len() == 3);
    assert_eq!(r.report.status_of("Shape layer"), Some(Status::Mapped));
}

#[test]
fn pen_path_with_curves_stays_out_but_is_listed() {
    let mut f = PRFixture::new();
    let curved = path(&[
        ((0.0, 0.0), Some((0.0, 0.0)), Some((30.0, -40.0))),
        ((100.0, 0.0), Some((70.0, -40.0)), Some((100.0, 0.0))),
        ((100.0, 100.0), None, None),
        ((0.0, 100.0), None, None),
        ((50.0, 130.0), Some((20.0, 130.0)), Some((80.0, 130.0))),
    ]);
    let s = shape_component(&mut f, &shape_spec(curved));
    let t = text_component(&mut f, "A", Some(0xFFFFFF), Some(2));
    let r = read_components(&mut f, &[t, s]);
    assert_eq!(r.report.status_of("Shape layer"), Some(Status::Dropped));
    assert_eq!(r.report.count_of("Shape layer"), 1);
    assert!(r.report.entries().iter().any(|e| e.feature == "Shape layer" && e.note.contains("pen path")));
    assert_eq!(r.description.shape_layer_count, 1);
    // Only the text layer is left: a plain text clip.
    assert!(first_clip(&r).graphics().is_none());
}

#[test]
fn shape_opacity_keys_and_real_point_form_carry_over() {
    let mut f = PRFixture::new();
    let ps = [
        f.blob_param(1, &rect(0.0, 0.0, 100.0, 100.0), "h1"),
        f.blob_param(2, &appearance(Some(0), None, 1.0), "h2"),
        f.pt(4, "0.75,0.5,0,0,0,0,0,0,5,4,0"),
        f.p(5, "100."),
        f.p(6, "100."),
        f.p(7, "true"),
        f.p(8, "0."),
        f.pk(9, "0.", &format!("0,0.,0,0,0,0,0,0;{},100.,0,0,0,0,0,0", S)),
    ];
    let s = f.component("AE.ADBE Shape", &ps);
    let t = text_component(&mut f, "A", Some(0xFFFFFF), Some(2));
    let l = layers(&read_components(&mut f, &[t, s])).remove(0);
    // Position 0.75 of 1920 = 1440, box center (50, 50), default anchor 0: center at 1440 + 50 - 960 = 530, y 50.
    let p = l.animation.position.value;
    assert!((p.x - 530.0).abs() < 0.5 && (p.y - 50.0).abs() < 0.5, "{p:?}");
    assert!(l.animation.opacity.is_animated());
}

#[test]
fn shape_only_template_still_reports_nothing_editable() {
    let mut f = PRFixture::new();
    let s = shape_component(&mut f, &shape_spec(rect(0.0, 0.0, 10.0, 10.0)));
    let pkg = package(&mut f, &[s]);
    assert!(matches!(read(&pkg, "x"), Err(MogrtImportError::NothingImportable { .. })));
}

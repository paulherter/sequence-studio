//! Container values, parameters, sequences and the text blob decoder. Swift: ReaderTests.swift.
#![allow(clippy::unwrap_used, reason = "helpers of integration tests; clippy.toml only covers test functions")]

mod common;

use common::{BackgroundSpec, FlatBlob, ItemSpec, PRFixture, SECOND as S, ShadowSpec, Source};
use sq_core_model::EffectColor;
use sq_core_time::{Time, Vec2};
use sq_premiere_import::prcontainer::{NodeExt, ObjectTable, PRTicks, safe_int};
use sq_premiere_import::prdocument::{PRParamValue, PRReader, PRSource};
use sq_premiere_import::prtext_blob::{PRTextBlob, Rgb, Stroke};
use sq_prproj_reader::inflate::{MAX_PROJECT_SIZE, gzip_inflate};

#[test]
fn ticks_become_rational_time() {
    assert_eq!(PRTicks::time(S), Time::new(1, 1));
    assert_eq!(PRTicks::time(8_467_200_000), Time::new(1, 30));
    assert_eq!(PRTicks::time(8_475_667_200), Time::new(1001, 30000));
    assert_eq!(PRTicks::time(S * 3 / 2), Time::new(3, 2));
    assert_eq!(PRTicks::frame_duration(8_475_667_200), Time::new(1001, 30000));
    // 48 kHz samples stay exact.
    assert_eq!(PRTicks::time(S / 48000), Time::new(1, 48000));
}

#[test]
fn hostile_ticks_never_trap() {
    let _ = PRTicks::time(i64::MAX);
    let _ = PRTicks::time(i64::MIN);
    assert_eq!(PRTicks::sub(i64::MAX, -5), i64::MAX);
    assert_eq!(PRTicks::sub(i64::MIN, 5), i64::MIN + 1);
    assert_eq!(PRTicks::sub(10, 4), 6);
    assert_eq!(safe_int(Some(f64::NAN)), None);
    assert_eq!(safe_int(Some(f64::INFINITY)), None);
    assert_eq!(safe_int(Some(1e300)), None);
    assert_eq!(safe_int(Some(7.9)), Some(7));
}

#[test]
fn gzip_extra_field_length_is_little_endian() {
    // FEXTRA of 511 bytes (0x01FF): the old precedence read 2 + 255 | 1 << 8 = 257 and landed inside the extra field.
    let mut gz = vec![0x1f, 0x8b, 8, 0x04, 0, 0, 0, 0, 0, 3, 0xFF, 0x01];
    gz.extend(std::iter::repeat_n(0x41, 511));
    gz.extend_from_slice(&[179, 73, 212, 183, 3, 0]);
    gz.extend_from_slice(&[0; 8]);
    assert_eq!(gzip_inflate(&gz, MAX_PROJECT_SIZE).unwrap(), b"<a/>");
}

#[test]
fn gunzips_and_passes_plain_xml_through() {
    let plain = "<PremiereData Version=\"3\"></PremiereData>\n".repeat(2000).into_bytes();
    // gzip = 10-byte header (with FNAME) + raw deflate + crc32 + isize.
    let mut gz = vec![0x1f, 0x8b, 8, 0x08, 0, 0, 0, 0, 0, 3];
    gz.extend_from_slice(b"x.xml\0");
    gz.extend(common::stored_deflate(&plain));
    gz.extend_from_slice(&[0; 8]);
    assert_eq!(gzip_inflate(&gz, MAX_PROJECT_SIZE).unwrap(), plain);
    assert_eq!(gzip_inflate(&plain, MAX_PROJECT_SIZE).unwrap(), plain);
}

#[test]
fn object_table_follows_refs() {
    let xml = "<PremiereData Version=\"3\"><A ObjectID=\"1\"><Ref ObjectRef=\"2\"/><U ObjectURef=\"abc\"/><Name>first</Name></A>\
        <B ObjectID=\"2\"><Name>second</Name></B><C ObjectUID=\"abc\"><Inner><Name>third</Name></Inner></C></PremiereData>";
    let table = ObjectTable::new(xml.as_bytes()).unwrap();
    let a = table.get("1").unwrap();
    assert_eq!(a.text_at("Name"), Some("first"));
    assert_eq!(table.deref(a.child("Ref")).and_then(|n| n.text_at("Name")), Some("second"));
    assert_eq!(table.deref(a.child("U")).and_then(|n| n.text_at("Inner/Name")), Some("third"));
    assert_eq!(sq_premiere_import::prcontainer::all_named(&table, "B").len(), 1);
}

#[test]
fn parses_static_values_and_keyframes() {
    let p = PRParamValue::parse(
        Some("-91445760000000000,100.,0,0,0,0,0,0"),
        Some(
            "254016000000,50.,0,0,0,0.16666666666666666,0,0.16666666666666666;508032000000,0.5:0.25,5,0,10,0.3333,-2,0.5;",
        ),
    );
    assert_eq!(p.static_value.as_deref(), Some("100."));
    assert_eq!(p.keys.len(), 2);
    assert!(p.keys[0].ticks == S && p.keys[0].value == "50." && p.keys[0].interpolation == 0);
    assert!(p.keys[1].interpolation == 5 && p.keys[1].in_slope == 10.0 && p.keys[1].in_influence == 0.3333);
    assert!(p.keys[1].out_slope == -2.0 && p.keys[1].out_influence == 0.5);
    assert_eq!(PRParamValue::double(Some("100.")), Some(100.0));
    assert_eq!(PRParamValue::double(Some("-3.25")), Some(-3.25));
    assert_eq!(PRParamValue::point(Some("0.5:0.25")), Some(Vec2::new(0.5, 0.25)));
    assert_eq!(PRParamValue::bool(Some("true")), Some(true));
    assert_eq!(PRParamValue::bool(Some("false")), Some(false));
    // Packed color, 16 bit per channel ARGB: opaque black, then opaque white.
    assert_eq!(
        PRParamValue::color(Some("18374686479671623680")),
        Some(EffectColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0 })
    );
    assert_eq!(
        PRParamValue::color(Some(&u64::MAX.to_string())),
        Some(EffectColor { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 })
    );
}

#[test]
fn reads_sequences_tracks_items_and_effects() {
    let mut f = PRFixture::new();
    let m = f.media("/footage/a.mov", "a.mov");
    let pos = f.pt(1, "0.5:0.5");
    let motion = f.component("AE.ADBE Motion", &[pos]);
    let v = f.item(
        ItemSpec::new(0, 2 * S, 10 * S, 12 * S, Source::Media(m.clone())).no_start().components(&[&motion]).name("A"),
    );
    let a = f.item(ItemSpec::new(S, 2 * S, 0, S * 8 / 5, Source::Media(m)).speed(1.6).audio());
    let (vt, at) = (f.track(&[v]), f.audio_track(&[a]));
    f.sequence_with("Main", 8_475_667_200, 1080, 1920, &[vt], &[at], None, &[]);
    let doc = PRReader::read(&f.data()).unwrap();
    assert_eq!(doc.sequences.len(), 1);
    let s = &doc.sequences[0];
    assert!(s.name == "Main" && s.width == 1080 && s.height == 1920);
    assert_eq!(s.frame_duration, Time::new(1001, 30000));
    assert!(s.video_tracks.len() == 1 && s.audio_tracks.len() == 1);
    let vi = &s.video_tracks[0].items[0];
    assert!(vi.start == 0 && vi.end == 2 * S && vi.in_point == 10 * S && vi.out_point == 12 * S && vi.speed == 1.0);
    assert_eq!(vi.name, "A");
    let PRSource::Media(media) = &vi.source else { panic!("not media") };
    assert!(media.path.as_deref() == Some("/footage/a.mov") && media.title == "a.mov");
    assert_eq!(vi.components.iter().map(|c| c.match_name.as_str()).collect::<Vec<_>>(), vec!["AE.ADBE Motion"]);
    assert_eq!(vi.components[0].param(1).and_then(|p| p.static_value.as_deref()), Some("0.5:0.5"));
    let ai = &s.audio_tracks[0].items[0];
    assert!(ai.is_audio && ai.speed == 1.6 && ai.start == S);
}

#[test]
fn shared_binary_blobs_resolve_by_hash() {
    let mut f = PRFixture::new();
    let blob = sq_core_time::base64::encode(&FlatBlob::premiere_text("Hi", "Inter-Bold", 50.0, 0.0, None, None));
    let m = f.media("/f/a.mov", "a.mov");
    let (pa, pb) = (f.blob_param(1, &blob, "h1"), f.blob_param(1, "", "h1"));
    let a = f.component("AE.ADBE Text", &[pa]);
    let b = f.component("AE.ADBE Text", &[pb]);
    let it = f.item(ItemSpec::new(0, S, 0, S, Source::Media(m)).components(&[&a, &b]));
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let doc = PRReader::read(&f.data()).unwrap();
    let item = &doc.sequences[0].video_tracks[0].items[0];
    assert_eq!(item.components[1].param(1).and_then(|p| p.blob.as_deref()), Some(blob.as_str()));
}

fn near(a: f64, b: f64, eps: f64) -> bool {
    (a - b).abs() < eps
}

#[test]
fn decodes_flat_buffer_text_blob() {
    let blob = FlatBlob::premiere_text("hier sind", "Inter-Bold", 73.144, -44.0, None, None);
    let t = PRTextBlob::decode(&blob).unwrap();
    assert_eq!(t.text, "hier sind");
    assert_eq!(t.font_name.as_deref(), Some("Inter-Bold"));
    assert!(near(t.size.unwrap_or(0.0), 73.144, 0.001));
    assert_eq!(t.tracking, Some(-44.0));
    assert!(t.shadow.is_none());
}

/// TCL C8L 'Bis zu\r3.200': Premiere ends a paragraph with CR; the second line is another run in another font and size.
#[test]
fn decodes_runs_and_carriage_return_line_breaks() {
    let blob = FlatBlob::premiere_runs(
        &[("Bis zu\r", 0, 136.0), ("3.200", 1, 195.0)],
        &["BasicSans-Regular", "BasicSans-Bold"],
    );
    let t = PRTextBlob::decode(&blob).unwrap();
    assert_eq!(t.text, "Bis zu\n3.200");
    assert!(t.font_name.as_deref() == Some("BasicSans-Regular") && t.size == Some(136.0));
    assert_eq!(t.runs.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(), vec!["Bis zu\n", "3.200"]);
    assert_eq!(
        t.runs.iter().map(|r| r.font_name.as_deref()).collect::<Vec<_>>(),
        vec![Some("BasicSans-Regular"), Some("BasicSans-Bold")]
    );
    assert_eq!(t.runs.iter().map(|r| r.size).collect::<Vec<_>>(), vec![Some(136.0), Some(195.0)]);
    let second = t.second_line.as_ref().unwrap();
    assert!(second.font_name.as_deref() == Some("BasicSans-Bold") && second.size == Some(195.0));
    assert!(!t.mixed_styles);
    // CRLF is one break; one style throughout has no second line.
    let plain = PRTextBlob::decode(&FlatBlob::premiere_runs(&[("a\r\nb", 0, 50.0)], &["Inter-Bold"])).unwrap();
    assert!(plain.text == "a\nb" && plain.second_line.is_none() && !plain.mixed_styles);
    // A style change inside the first line cannot be shown with two line styles: reported, first style kept.
    let mixed =
        PRTextBlob::decode(&FlatBlob::premiere_runs(&[("a", 0, 50.0), ("b", 1, 80.0)], &["X-Regular", "X-Bold"]))
            .unwrap();
    assert!(mixed.second_line.is_none() && mixed.mixed_styles);
}

#[test]
fn decodes_flat_buffer_text_shadow() {
    let shadow = ShadowSpec {
        rgb: (0, 0, 0),
        on: true,
        opacity: 90.781,
        distance: 17.764,
        angle: 19.255,
        size: 20.461,
        blur: 178.612,
    };
    let blob = FlatBlob::premiere_text("auf Audio", "Inter-Bold", 90.0, 0.0, Some(shadow), None);
    let t = PRTextBlob::decode(&blob).unwrap();
    assert!(t.text == "auf Audio" && t.font_name.as_deref() == Some("Inter-Bold"));
    let s = t.shadow.unwrap();
    assert!(s.red == 0.0 && s.green == 0.0 && s.blue == 0.0);
    // fields 20/34 (here 19.255 / 17.764) are not the shadow angle / distance
    assert!(near(s.opacity, 0.90781, 1e-5) && s.distance == 0.0 && s.angle == 0.0);
    assert!(near(s.size, 20.461, 1e-3) && near(s.blur, 178.612, 1e-3));
    let off =
        ShadowSpec { rgb: (0, 0, 0), on: false, opacity: 90.0, distance: 20.0, angle: 178.0, size: 19.0, blur: 17.0 };
    assert!(
        PRTextBlob::decode(&FlatBlob::premiere_text("x", "Inter-Bold", 90.0, 0.0, Some(off), None))
            .unwrap()
            .shadow
            .is_none()
    );
}

/// Main table field 17 is the Background color (18 on, 19 opacity), not the fill: the maintainer's captions store cyan
/// 75/203/214 there with the background off and render white in Premiere (S112 x2, TCL C8L).
#[test]
fn flat_field_17_is_the_background_not_the_fill() {
    let off = BackgroundSpec { rgb: (75, 203, 214), on: false, opacity: 100.0, size: 9.26, radius: 0.0 };
    let off = PRTextBlob::decode(&FlatBlob::premiere_text("x", "Inter-Bold", 90.0, 0.0, None, Some(off))).unwrap();
    assert!(off.fill.is_none() && off.background.is_none());
    let on = BackgroundSpec { rgb: (0xEE, 0x4A, 0x4A), on: true, opacity: 80.0, size: 12.0, radius: 6.0 };
    let on = PRTextBlob::decode(&FlatBlob::premiere_text("x", "Inter-Bold", 90.0, 0.0, None, Some(on))).unwrap();
    assert!(on.fill.is_none());
    let bg = on.background.unwrap();
    assert_eq!(
        bg.color,
        Rgb { red: f64::from(0xEE) / 255.0, green: f64::from(0x4A) / 255.0, blue: f64::from(0x4A) / 255.0 }
    );
    assert!(near(bg.opacity, 0.8, 1e-6) && near(bg.size, 12.0, 1e-6) && near(bg.corner_radius, 6.0, 1e-6));
}

/// Shadow color channels are one-byte fields too.
#[test]
fn shadow_colour_reads_bytes() {
    let sh =
        ShadowSpec { rgb: (10, 20, 30), on: true, opacity: 50.0, distance: 4.0, angle: 135.0, size: 2.0, blur: 3.0 };
    let t = PRTextBlob::decode(&FlatBlob::premiere_text("x", "Inter-Bold", 90.0, 0.0, Some(sh), None)).unwrap();
    let s = t.shadow.unwrap();
    assert!(s.red == 10.0 / 255.0 && s.green == 20.0 / 255.0 && s.blue == 30.0 / 255.0);
}

fn utf16_blob(json: &str) -> Vec<u8> {
    let mut b = vec![0u8; 8];
    for u in json.encode_utf16() {
        b.extend_from_slice(&u.to_le_bytes());
    }
    b
}

#[test]
fn decodes_legacy_json_fill_and_stroke() {
    let blob = |fill: i64, fill_visible: bool, stroke: i64, stroke_visible: bool, width: i64| {
        let p = |v: String| format!("{{\"mParamValues\":[[0,{v}]]}}");
        utf16_blob(&format!(
            "{{\"mTextParam\":{{\"mStyleSheet\":{{\"mText\":\"Hi\",\"mFillColor\":{},\"mFillVisible\":{},\"mStrokeColor\":{},\"mStrokeVisible\":{},\"mStrokeWidth\":{}}}}}}}\0",
            p(fill.to_string()),
            p(fill_visible.to_string()),
            p(stroke.to_string()),
            p(stroke_visible.to_string()),
            p(width.to_string())
        ))
    };
    let t = PRTextBlob::decode(&blob(0xFF8000, true, 0x000080, true, 4)).unwrap();
    assert_eq!(t.fill, Some(Rgb { red: 1.0, green: 128.0 / 255.0, blue: 0.0 }));
    assert_eq!(t.stroke, Some(Stroke { color: Rgb { red: 0.0, green: 0.0, blue: 128.0 / 255.0 }, width: 4.0 }));
    let off = PRTextBlob::decode(&blob(0x606060, false, 0xFFFFFF, false, 1)).unwrap();
    assert!(off.fill.is_none() && off.stroke.is_none());
}

#[test]
fn decodes_legacy_json_text_blob() {
    let json = r#"{"mTextParam":{"mAlignment":0,"mStyleSheet":{"mFontName":{"mParamValues":[[0,"BasicSans-Bold"]]},"mFontSize":{"mParamValues":[[0,81.5]]},"mFillColor":{"mParamValues":[[0,16777215]]},"mText":"Hello","mTracking":{"mParamValues":[[0,0]]}}}}"#;
    let t = PRTextBlob::decode(&utf16_blob(json)).unwrap();
    assert_eq!(t.text, "Hello");
    assert_eq!(t.font_name.as_deref(), Some("BasicSans-Bold"));
    assert_eq!(t.size, Some(81.5));
}

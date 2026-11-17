//! The mapper on synthetic projects. Swift: MapperTests.swift (the cases that do not need the text generator) and
//! ImportChecklistTests.swift. The canonical-digest differential (MapperGolden) is Swift-only: its digests hash Foundation's
//! JSON text.
#![allow(clippy::unwrap_used, reason = "helpers of integration tests; clippy.toml only covers test functions")]

mod common;

use common::{ItemSpec, MediaSpec, PRFixture, SECOND as S, Source};
use sq_core_color::{ClipEffectColorExt, NeutralExt};
use sq_core_edit::clip_markers::ClipMarkersExt;
use sq_core_model::{COLOR_KIND, Clip, ClipSpeed, MarkerColor, MediaFingerprint, MediaRef, RGBCurves, TrackKind};
use sq_core_time::{Id, SequentialIds, Time, TimeRange, Vec2};
use sq_premiere_import::prcontainer::PRTicks;
use sq_premiere_import::prdocument::PRReader;
use sq_premiere_import::primport_checklist::{Kind, PRImportChecklist};
use sq_premiere_import::primport_report::{Location, PRImportReport, Status};
use sq_premiere_import::prmapper::{PRImportResult, PRMapper};
use std::collections::BTreeMap;

fn map_with(f: &PRFixture, media: &BTreeMap<String, MediaRef>) -> PRImportResult {
    let doc = PRReader::read(&f.data()).unwrap();
    PRMapper::map(&doc, "Test", media, false, &mut SequentialIds::default())
}

fn map(f: &PRFixture) -> PRImportResult {
    map_with(f, &BTreeMap::new())
}

fn clips(r: &PRImportResult, seq: &str, kind: TrackKind) -> Vec<Clip> {
    let tl = r.project.timelines.iter().find(|t| t.name == seq).unwrap();
    tl.tracks.iter().filter(|t| t.kind == kind).flat_map(|t| t.clips().to_vec()).collect()
}

fn video(r: &PRImportResult) -> Vec<Clip> {
    clips(r, "Main", TrackKind::Video)
}

/// A probed 4K clip so the mapper knows the source frame size.
fn uhd(path: &str) -> MediaRef {
    let info: sq_core_model::MediaInfo = serde_json::from_value(serde_json::json!({
        "duration": {"value": 60, "timescale": 1},
        "video": {"width": 3840, "height": 2160, "codec": "hvc1", "bitDepth": 10, "chroma": "4:2:0",
                  "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false}
    }))
    .unwrap();
    let mut r = MediaRef::new(Id::from_u128(0x77), "a", path, MediaFingerprint::new(1));
    r.duration = Some(Time::new(60, 1));
    r.info = Some(info);
    r
}

fn item(start: i64, end: i64, in_point: i64, out_point: i64, source: Source) -> ItemSpec {
    ItemSpec::new(start, end, in_point, out_point, source)
}

fn one_clip_sequence(f: &mut PRFixture, spec: ItemSpec) {
    let it = f.item(spec);
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
}

#[test]
fn muted_track_stays_muted() {
    let mut f = PRFixture::new();
    let (a, b) = (f.track_with(&[], &[], true, true), f.track_with(&[], &[], true, false));
    f.sequence("Main", &[], &[a, b]);
    let r = map(&f);
    let audio: Vec<bool> =
        r.project.timelines[0].tracks.iter().filter(|t| t.kind == TrackKind::Audio).map(|t| t.is_muted).collect();
    assert_eq!(audio, vec![true, false]);
}

#[test]
fn muted_video_track_becomes_hidden() {
    let mut f = PRFixture::new();
    let (a, b) = (f.track_with(&[], &[], false, true), f.track(&[]));
    f.sequence("Main", &[a, b], &[]);
    let r = map(&f);
    let video: Vec<bool> =
        r.project.timelines[0].tracks.iter().filter(|t| t.kind == TrackKind::Video).map(|t| t.is_visible).collect();
    assert_eq!(video, vec![false, true]);
    assert_eq!(r.report.status_of("Video track output off"), Some(Status::Mapped));
}

#[test]
fn sequence_markers_import() {
    let mut f = PRFixture::new();
    let json = |t: i64, d: i64, name: &str, color: i64| {
        format!(
            "{{&quot;DVAMarker&quot;:{{&quot;mMarkerID&quot;:&quot;x&quot;,&quot;mStartTime&quot;:{{&quot;ticks&quot;:{t}}},&quot;mDuration&quot;:{{&quot;ticks&quot;:{d}}},&quot;mName&quot;:&quot;{name}&quot;,&quot;mColorIndex&quot;:{color},&quot;mType&quot;:&quot;Comment&quot;}}}}"
        )
    };
    f.sequence_with(
        "Main",
        8_467_200_000,
        1080,
        1920,
        &[],
        &[],
        None,
        &[json(2 * S, S, "Beat", 1), json(S, 0, "Intro", 0)],
    );
    let m = &map(&f).project.timelines[0].markers;
    assert_eq!(m.iter().map(|m| m.name.as_str()).collect::<Vec<_>>(), vec!["Intro", "Beat"]);
    assert!(m[0].time == Time::new(1, 1) && m[0].duration == Time::ZERO && m[0].color == MarkerColor::Green);
    assert!(m[1].time == Time::new(2, 1) && m[1].duration == Time::new(1, 1) && m[1].color == MarkerColor::Red);
}

/// Lumetri curves blob (param 39): four blocks of 520 bytes; master with the white point pulled to x 0.9 here.
fn curves_blob(master_white: f64, red_mid: Option<f64>) -> String {
    let block = |pts: &[(f64, f64)]| {
        let mut b = vec![0u8; 520];
        b[4] = pts.len() as u8;
        for (i, p) in pts.iter().enumerate() {
            for (k, v) in [p.0, p.1].iter().enumerate() {
                b[8 + 16 * i + 8 * k..8 + 16 * i + 8 * k + 8].copy_from_slice(&v.to_le_bytes());
            }
        }
        b
    };
    let diag = [(0.0, 0.0), (1.0, 1.0)];
    let red: Vec<(f64, f64)> = red_mid.map_or(diag.to_vec(), |m| vec![(0.0, 0.0), (0.5, m), (1.0, 1.0)]);
    let all = [block(&[(0.0, 0.0), (master_white, 1.0)]), block(&red), block(&diag), block(&diag)].concat();
    sq_core_time::base64::encode(&all)
}

fn lumetri_clip(f: &mut PRFixture, params: &[String], start: i64) -> String {
    let lum = f.component("AE.ADBE Lumetri", params);
    f.item(item(start, start + S, 0, S, Source::Graphic).components(&[&lum]).adjustment())
}

fn color_effect_of(c: &Clip) -> sq_core_model::ColorEffect {
    c.effects.iter().find(|e| e.kind == COLOR_KIND).unwrap().color_effect(None, 1)
}

#[test]
fn lumetri_curves_and_vignette_import() {
    let mut f = PRFixture::new();
    let blob = curves_blob(0.9, Some(0.6));
    let params = [
        f.p(3, "true"),
        f.p(28, "12."),
        f.p(31, "130."),
        f.p(37, "true"),
        f.blob_param(39, &blob, ""),
        f.p(50, "true"),
        f.p(51, "-1.5"),
        f.p(52, "40."),
        f.p(53, "10."),
        f.p(54, "70."),
    ];
    let it = lumetri_clip(&mut f, &params, 0);
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let e = color_effect_of(&video(&r)[0]);
    let pts = |v: &[(f32, f32)]| v.iter().map(|&(x, y)| sq_core_model::CurvePoint { x, y }).collect::<Vec<_>>();
    assert_eq!(e.curves.master, pts(&[(0.0, 0.0), (0.9, 1.0)]));
    assert_eq!(e.curves.red, pts(&[(0.0, 0.0), (0.5, 0.6), (1.0, 1.0)]));
    assert_eq!(e.curves.green, RGBCurves::default().green);
    assert!(e.creative.faded_film == 12.0 && e.creative.saturation == 130.0);
    assert!(
        e.vignette.amount == -1.5
            && e.vignette.midpoint == 40.0
            && e.vignette.roundness == 10.0
            && e.vignette.feather == 70.0
    );
    assert_eq!(r.report.status_of("Lumetri RGB curves"), Some(Status::Mapped));
    assert_eq!(r.report.status_of("Lumetri vignette"), Some(Status::Mapped));
}

#[test]
fn disabled_curves_section_and_neutral_blob_map_nothing() {
    let mut f = PRFixture::new();
    let (b1, b2) = (curves_blob(0.9, None), curves_blob(1.0, None));
    let off_params = [f.p(3, "true"), f.p(37, "false"), f.blob_param(39, &b1, "")];
    let neutral_params = [f.p(3, "true"), f.p(37, "true"), f.blob_param(39, &b2, "")];
    let a = lumetri_clip(&mut f, &off_params, 0);
    let b = lumetri_clip(&mut f, &neutral_params, S);
    let t = f.track(&[a, b]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    for c in video(&r) {
        assert!(color_effect_of(&c).curves.is_neutral());
    }
    assert_eq!(r.report.status_of("Lumetri RGB curves"), None);
}

/// Lumetri Color Wheels blob (param 47): little-endian doubles, three per wheel.
fn wheels_blob(v: &[f64]) -> String {
    sq_core_time::base64::encode(&v.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>())
}

fn lumetri_wheels(blob: &str, on: bool) -> (sq_core_model::ColorEffect, PRImportReport) {
    let mut f = PRFixture::new();
    let params = [f.p(3, "true"), f.p(46, if on { "true" } else { "false" }), f.blob_param(47, blob, "")];
    let it = lumetri_clip(&mut f, &params, 0);
    let t = f.track(&[it]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    (color_effect_of(&video(&r)[0]), r.report)
}

/// The one edited wheel blob in the maintainer's projects: only luma sliders moved. The sliders are decoded but NOT
/// applied, so the grade stays untouched and the loss is reported.
#[test]
fn colour_wheel_luma_sliders_are_decoded_but_not_applied() {
    let (e, report) =
        lumetri_wheels(&wheels_blob(&[0.0, 0.4977, 0.0, 0.0, 0.4388, 0.0, 0.0, 0.5, 0.0, 0.0, 0.5, 0.0]), true);
    assert!(e.wheels.is_neutral());
    assert_eq!(report.status_of("Lumetri color wheels"), Some(Status::Dropped));
    assert!(
        report
            .entries()
            .iter()
            .find(|e| e.feature == "Lumetri color wheels")
            .is_some_and(|e| e.note.contains("luma sliders decoded, not applied"))
    );
}

/// Swift threeWheelBlobDecodesLuma: the older 72-byte blob (three wheels) decodes like the 96-byte one.
#[test]
fn three_wheel_blob_decodes_its_luma_slider() {
    let (e, report) = lumetri_wheels(&wheels_blob(&[0.0, 0.5, 0.0, 0.0, 0.5, 0.0, 0.0, 0.6, 0.0]), true);
    assert!(e.wheels.is_neutral());
    assert!(
        report
            .entries()
            .iter()
            .find(|e| e.feature == "Lumetri color wheels")
            .is_some_and(|e| e.note.contains("luma sliders decoded, not applied")),
        "{:?}",
        report.entries()
    );
}

#[test]
fn colour_wheels_switched_off_or_neutral_say_nothing() {
    let (e, report) =
        lumetri_wheels(&wheels_blob(&[0.0, 0.4977, 0.0, 0.0, 0.4388, 0.0, 0.0, 0.5, 0.0, 0.0, 0.5, 0.0]), false);
    assert!(e.wheels.is_neutral());
    assert_eq!(report.status_of("Lumetri color wheels"), None);
    let (_, neutral) =
        lumetri_wheels(&wheels_blob(&[0.0, 0.5, 0.0, 0.0, 0.5, 0.0, 0.0, 0.5, 0.0, 0.0, 0.5, 0.0]), true);
    assert_eq!(neutral.status_of("Lumetri color wheels"), None);
}

/// No sample has a moved puck, so its two values cannot be mapped yet: counted as dropped, never silent.
#[test]
fn edited_wheel_colours_and_specular_are_reported_as_dropped() {
    let (e, report) = lumetri_wheels(&wheels_blob(&[0.0, 0.5, 0.0, 0.3, 0.5, 0.1, 0.0, 0.5, 0.0, 0.0, 0.5, 0.0]), true);
    assert!(e.wheels.is_neutral());
    assert_eq!(report.status_of("Lumetri color wheels"), Some(Status::Dropped));
    let (_, spec) = lumetri_wheels(&wheels_blob(&[0.0, 0.5, 0.0, 0.0, 0.5, 0.0, 0.0, 0.5, 0.0, 0.0, 0.7, 0.0]), true);
    assert_eq!(spec.status_of("Lumetri HDR specular wheel"), Some(Status::Dropped));
}

/// A wheel blob that does not read as wheel values (out of range, non-finite, unknown length) is reported, never ignored.
#[test]
fn unreadable_wheel_blob_is_reported_as_dropped() {
    let cases: [&[f64]; 3] = [
        &[0.0, 0.5, 0.0, 0.0, 5.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.5, 0.0],
        &[0.0, 0.5, 0.0, 0.0, f64::NAN, 0.0, 0.0, 0.5, 0.0, 0.0, 0.5, 0.0],
        &[0.0, 0.5, 0.0, 0.0, 0.5],
    ];
    for values in cases {
        let (e, report) = lumetri_wheels(&wheels_blob(values), true);
        assert!(e.wheels.is_neutral());
        assert_eq!(report.status_of("Lumetri color wheels"), Some(Status::Dropped));
    }
}

/// Hue Saturation Curves blobs: 520 bytes, UInt32 axis kind, UInt32 point count, 32 (x, y) doubles.
fn hue_curve_blob(kind: u32, points: &[(f64, f64)]) -> String {
    let mut b = vec![0u8; 520];
    b[0..4].copy_from_slice(&kind.to_le_bytes());
    b[4..8].copy_from_slice(&(points.len() as u32).to_le_bytes());
    // Flat blobs still carry Premiere's stale default points (0, 0), (1, 1) after the zero count.
    let stored: Vec<(f64, f64)> = if points.is_empty() { vec![(0.0, 0.0), (1.0, 1.0)] } else { points.to_vec() };
    for (i, p) in stored.iter().enumerate() {
        for (k, v) in [p.0, p.1].iter().enumerate() {
            b[8 + 16 * i + 8 * k..8 + 16 * i + 8 * k + 8].copy_from_slice(&v.to_le_bytes());
        }
    }
    sq_core_time::base64::encode(&b)
}

#[test]
fn flat_hue_curves_say_nothing_and_edited_ones_are_reported() {
    let mut f = PRFixture::new();
    let (b42, b110) = (hue_curve_blob(3, &[]), hue_curve_blob(2, &[]));
    let b106 = hue_curve_blob(3, &[(0.1, 0.5), (0.2, 0.7), (0.3, 0.5)]);
    let flat_params = [f.p(3, "true"), f.blob_param(42, &b42, ""), f.blob_param(110, &b110, "")];
    let edited_params = [f.p(3, "true"), f.blob_param(106, &b106, "")];
    let a = lumetri_clip(&mut f, &flat_params, 0);
    let b = lumetri_clip(&mut f, &edited_params, 0);
    let (ta, tb) = (f.track(&[a]), f.track(&[b]));
    f.sequence("Main", &[ta, tb], &[]);
    let r = map(&f);
    assert_eq!(r.report.count_of("Lumetri hue saturation curves"), 1);
    assert_eq!(r.report.status_of("Lumetri hue saturation curves"), Some(Status::Dropped));
    for c in video(&r) {
        assert!(color_effect_of(&c).hue_curves.is_neutral());
    }
}

/// Clip markers are in media ticks, like the in point. Only the ones inside the used range are kept, as SQ source time.
#[test]
fn clip_markers_import_in_source_time() {
    let mut f = PRFixture::new();
    let m = f.media("/v/a.mov", "a.mov");
    let marks: Vec<String> = [9 * S, 11 * S, 14 * S, 20 * S].iter().map(|&t| PRFixture::plain_marker(t)).collect();
    let a = f.item(item(0, 4 * S, 10 * S, 14 * S, Source::Media(m.clone())).markers(&marks));
    let b = f.item(
        item(4 * S, 6 * S, 10 * S, 14 * S, Source::Media(m)).speed(2.0).markers(&[PRFixture::plain_marker(12 * S)]),
    );
    let t = f.track(&[a, b]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let cs = video(&r);
    let a = cs[0].markers.as_ref().unwrap();
    assert_eq!(a.iter().map(|m| m.time).collect::<Vec<_>>(), vec![Time::new(11, 1)]);
    assert!(a[0].name.is_empty() && a[0].color == MarkerColor::Green && a[0].duration == Time::ZERO);
    let fd = r.project.timelines[0].format.frame_duration;
    assert_eq!(cs[0].visible_markers(fd).iter().map(|m| m.time).collect::<Vec<_>>(), vec![Time::new(1, 1)]);
    assert_eq!(cs[1].visible_markers(fd).iter().map(|m| m.time).collect::<Vec<_>>(), vec![Time::new(1, 1)]);
    assert_eq!(r.report.count_of("Clip markers"), 2);
    assert_eq!(r.report.status_of("Clip markers outside the used range"), Some(Status::Dropped));
}

/// Markers are snapped where they show: on the sequence frame of the clip-local time, then mapped back to source time. At
/// 200 % the source moves two frames per sequence frame, so an odd source frame lands on the frame playing across it.
#[test]
fn clip_markers_snap_to_the_sequence_frame_in_clip_time() {
    let mut f = PRFixture::new();
    let m = f.media("/v/a.mov", "a.mov");
    let frame: i64 = 8_467_200_000;
    one_clip_sequence(
        &mut f,
        item(0, 2 * S, 10 * S, 14 * S, Source::Media(m))
            .speed(2.0)
            .markers(&[PRFixture::plain_marker(10 * S + 3 * frame + 1000)]),
    );
    let r = map(&f);
    let c = &video(&r)[0];
    let fd = r.project.timelines[0].format.frame_duration;
    let mk = &c.markers.as_ref().unwrap()[0];
    // Source frame 3 at 200 % = clip-local 1.5 frames -> frame 2 (ties round up) -> source frame 4.
    assert_eq!(mk.time, Time::new(10, 1) + fd * 4);
    assert_eq!(c.visible_markers(fd).iter().map(|m| m.time).collect::<Vec<_>>(), vec![fd * 2]);
}

/// Generators (graphics, mattes, adjustment layers) start their source at 0: the marker keeps its distance to the in point.
#[test]
fn clip_markers_on_adjustment_layer_are_clip_local() {
    let mut f = PRFixture::new();
    one_clip_sequence(
        &mut f,
        item(0, 2 * S, 5 * S, 7 * S, Source::Graphic).adjustment().markers(&[PRFixture::plain_marker(6 * S)]),
    );
    let r = map(&f);
    assert_eq!(
        video(&r)[0].markers.as_ref().map(|m| m.iter().map(|m| m.time).collect::<Vec<_>>()),
        Some(vec![Time::new(1, 1)])
    );
}

#[test]
fn offline_media_gets_unknown_size_and_reports_it() {
    let mut f = PRFixture::new();
    let m = f.media("/gone/a.mov", "a.mov");
    one_clip_sequence(&mut f, item(0, S, 0, S, Source::Media(m)));
    let r = map(&f);
    assert_eq!(r.project.media[0].fingerprint.size, 0);
    assert_eq!(r.report.count_of("Offline media"), 1);
}

/// A still missing at import (no probe info) is still mapped as a still: source from 0, not Premiere's huge in point.
#[test]
fn offline_still_image_stays_a_still() {
    let mut f = PRFixture::new();
    let m = f.media("/gone/sun.PNG", "sun.PNG");
    one_clip_sequence(&mut f, item(0, S, 3600 * S, 3601 * S, Source::Media(m)));
    let c = &video(&map(&f))[0];
    assert!(c.is_still && c.source.start == Time::ZERO && c.source.duration == PRTicks::time(S));
}

#[test]
fn cuts_trims_and_format() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let a = f.item(item(S, 3 * S, 10 * S, 12 * S, Source::Media(m.clone())));
    let b = f.item(item(3 * S, 4 * S, 0, S, Source::Media(m)));
    let t = f.track(&[a, b]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let t = &r.project.timelines[0];
    assert!(t.format.width == 1080 && t.format.height == 1920 && t.format.frame_duration == Time::new(1, 30));
    let c = video(&r);
    assert_eq!(c.len(), 2);
    assert!(c[0].start == Time::new(1, 1) && c[0].source == TimeRange::new(Time::new(10, 1), Time::new(2, 1)));
    assert!(c[1].start == Time::new(3, 1) && c[1].duration() == Time::new(1, 1));
    assert!(r.project.media.len() == 1 && r.project.media[0].path == "/f/a.mov");
    assert_eq!(c[0].media, r.project.media[0].id);
    assert_eq!(r.project.active_timeline, Some(t.id));
    assert_eq!(PRMapper::media_paths(&PRReader::read(&f.data()).unwrap()), vec!["/f/a.mov"]);
}

#[test]
fn uses_probed_media_ref() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    one_clip_sequence(&mut f, item(0, S, 0, S, Source::Media(m)));
    let reference = uhd("/f/a.mov");
    let r = map_with(&f, &BTreeMap::from([("/f/a.mov".to_string(), reference.clone())]));
    assert_eq!(r.project.media, vec![reference.clone()]);
    assert!(video(&r)[0].media == reference.id && video(&r)[0].media_duration == Some(Time::new(60, 1)));
}

#[test]
fn speed_keeps_timeline_length() {
    let mut f = PRFixture::new();
    let m = f.media("/f/w.wav", "w.wav");
    let a = f.item(item(0, S, 0, S * 8 / 5, Source::Media(m)).speed(1.6).audio());
    let t = f.audio_track(&[a]);
    f.sequence("Main", &[], &[t]);
    let c = clips(&map(&f), "Main", TrackKind::Audio);
    assert_eq!(c[0].speed, ClipSpeed::new(8, 5));
    assert_eq!(c[0].duration(), Time::new(1, 1));
    assert_eq!(c[0].source.duration, Time::new(8, 5));
}

#[test]
fn nested_sequence_becomes_nested_clip() {
    let mut f = PRFixture::new();
    let inner = f.reserve_uid();
    let m = f.media("/f/a.mov", "a.mov");
    let n = f.item(item(0, 2 * S, S, 3 * S, Source::Sequence(inner.clone())).name("Nest"));
    let t = f.track(&[n]);
    f.sequence("Main", &[t], &[]);
    let it = f.item(item(0, 5 * S, 0, 5 * S, Source::Media(m)));
    let it_track = f.track(&[it]);
    f.sequence_with("Inner", 8_467_200_000, 1080, 1920, &[it_track], &[], Some(&inner), &[]);
    let r = map(&f);
    let inner_tl = r.project.timelines.iter().find(|t| t.name == "Inner").unwrap();
    let c = &video(&r)[0];
    assert!(c.sequence == Some(inner_tl.id) && c.media == inner_tl.id);
    assert_eq!(c.source, TimeRange::new(Time::new(1, 1), Time::new(2, 1)));
    // The top-level sequence is the active one, not the nested one.
    assert_eq!(r.project.active_timeline, r.project.timelines.iter().find(|t| t.name == "Main").map(|t| t.id));
}

#[test]
fn cyclic_nested_sequences_are_reported() {
    let mut f = PRFixture::new();
    let (a, b) = (f.reserve_uid(), f.reserve_uid());
    let ia = f.item(item(0, S, 0, S, Source::Sequence(b.clone())).name("toB"));
    let ta = f.track(&[ia]);
    f.sequence_with("A", 8_467_200_000, 1080, 1920, &[ta], &[], Some(&a), &[]);
    let ib = f.item(item(0, S, 0, S, Source::Sequence(a)).name("toA"));
    let tb = f.track(&[ib]);
    f.sequence_with("B", 8_467_200_000, 1080, 1920, &[tb], &[], Some(&b), &[]);
    let r = map(&f);
    assert!(
        r.report
            .entries()
            .iter()
            .any(|e| e.feature == "Nested sequence" && e.status == Status::Dropped && e.note == "cyclic nesting")
    );
    let nested = r
        .project
        .timelines
        .iter()
        .flat_map(|t| t.tracks.iter())
        .flat_map(|t| t.clips())
        .filter(|c| c.sequence.is_some())
        .count();
    assert_eq!(nested, 1);
    assert!(r.project.active_timeline.is_some());
}

#[test]
fn motion_maps_to_clip_animation() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let params = [f.pt(1, "0.5:0.25"), f.p(2, "55."), f.p(3, "80."), f.p(4, "true"), f.p(5, "12."), f.pt(6, "0:0")];
    let motion = f.component("AE.ADBE Motion", &params);
    let op = f.p(1, "50.");
    let opacity = f.component("AE.ADBE Opacity", &[op]);
    one_clip_sequence(&mut f, item(0, S, 0, S, Source::Media(m)).components(&[&motion, &opacity]));
    let r = map_with(&f, &BTreeMap::from([("/f/a.mov".to_string(), uhd("/f/a.mov"))]));
    let a = &video(&r)[0].animation;
    assert_eq!(a.position.value, Vec2::new(0.0, -480.0));
    assert_eq!(a.scale.value, Vec2::new(0.55, 0.55));
    assert_eq!(a.rotation.value, 12.0);
    assert_eq!(a.anchor.value, Vec2::new(-1920.0, -1080.0));
    assert_eq!(a.opacity.value, 0.5);
}

#[test]
fn non_uniform_scale_uses_width_param() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let params = [f.p(2, "50."), f.p(3, "80."), f.p(4, "false")];
    let motion = f.component("AE.ADBE Motion", &params);
    one_clip_sequence(&mut f, item(0, S, 0, S, Source::Media(m)).components(&[&motion]));
    assert_eq!(video(&map(&f))[0].animation.scale.value, Vec2::new(0.8, 0.5));
}

#[test]
fn pixel_aspect_becomes_horizontal_scale() {
    let mut f = PRFixture::new();
    let m = f.media_with("/f/a.mov", "a.mov", &MediaSpec { par: Some("160,121"), ..MediaSpec::default() });
    let params = [f.p(2, "50."), f.p(4, "true")];
    let motion = f.component("AE.ADBE Motion", &params);
    one_clip_sequence(&mut f, item(0, S, 0, S, Source::Media(m)).components(&[&motion]));
    let s = video(&map(&f))[0].animation.scale.value;
    assert!((s.x - 0.5 * 160.0 / 121.0).abs() < 1e-9 && s.y == 0.5);
}

fn tagged_4_3(path: &str) -> MediaRef {
    let mut r = uhd(path);
    if let Some(v) = r.info.as_mut().and_then(|i| i.video.as_mut()) {
        v.pixel_aspect = sq_core_model::PixelAspect::new(4, 3).unwrap();
    }
    r
}

/// A file whose own tag already carries the pixel aspect is desqueezed by the media item, not a second time by Scale.
#[test]
fn tagged_pixel_aspect_is_not_applied_twice() {
    let mut f = PRFixture::new();
    let m = f.media_with("/f/a.mov", "a.mov", &MediaSpec { par: Some("4,3"), ..MediaSpec::default() });
    let params = [f.p(2, "50."), f.p(4, "true")];
    let motion = f.component("AE.ADBE Motion", &params);
    one_clip_sequence(&mut f, item(0, S, 0, S, Source::Media(m)).components(&[&motion]));
    let s = video(&map_with(&f, &BTreeMap::from([("/f/a.mov".to_string(), tagged_4_3("/f/a.mov"))])))[0]
        .animation
        .scale
        .value;
    assert!((s.x - s.y).abs() < 1e-9);
}

/// A project without `OriginalPAR` says nothing about the pixels. The file's own 4:3 tag stands; no residual 0.75 squeezes
/// the picture back.
#[test]
fn missing_pixel_aspect_in_the_project_adds_no_scale() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    let params = [f.p(2, "50."), f.p(4, "true")];
    let motion = f.component("AE.ADBE Motion", &params);
    one_clip_sequence(&mut f, item(0, S, 0, S, Source::Media(m)).components(&[&motion]));
    let s = video(&map_with(&f, &BTreeMap::from([("/f/a.mov".to_string(), tagged_4_3("/f/a.mov"))])))[0]
        .animation
        .scale
        .value;
    assert!((s.x - s.y).abs() < 1e-9 && s.y == 0.5);
}

#[test]
fn display_referred_709_gets_gamma_curve() {
    let mut f = PRFixture::new();
    let dr = f.media_with(
        "/f/a.mov",
        "a.mov",
        &MediaSpec { color_profile: Some("BT.709,8-bit,Display-Referred"), ..MediaSpec::default() },
    );
    let rgb = f.media_with(
        "/f/b.png",
        "b.png",
        &MediaSpec { color_profile: Some("BT.709 RGB Full"), ..MediaSpec::default() },
    );
    let a = f.item(item(0, S, 0, S, Source::Media(dr)));
    let b = f.item(item(S, 2 * S, 0, S, Source::Media(rgb)));
    let t = f.track(&[a, b]);
    f.sequence("Main", &[t], &[]);
    let c = video(&map(&f));
    let fx = c[0].effects.iter().find(|e| e.is_color()).unwrap();
    let curve = fx.color_effect(None, 1).curves.master;
    // The power law 2.4 / 1.961 as 11 master-curve points (denser at the dark end).
    assert_eq!(curve.len(), 11);
    assert!(curve.iter().all(|p| (f64::from(p.y) - f64::from(p.x).powf(2.4 / 1.961)).abs() < 1e-6));
    assert!(!c[1].effects.iter().any(|e| e.is_color()));
}

#[test]
fn keyframes_are_clip_local_after_in_point_and_speed() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    // Keys sit at absolute source time: In = 10 s, keys at 10.5 s and 11 s, speed 2 -> local 0.25 s and 0.5 s.
    let keys = format!("{},90.,0,0,0,0.1667,0,0.1667;{},100.,4,0,0,0.1667,0,0.1667", 10 * S + S / 2, 11 * S);
    let params = [f.pk(2, "100.", &keys), f.p(4, "true")];
    let motion = f.component("AE.ADBE Motion", &params);
    one_clip_sequence(&mut f, item(0, S, 10 * S, 12 * S, Source::Media(m)).speed(2.0).components(&[&motion]));
    let c = &video(&map(&f))[0];
    let k = &c.animation.scale.track.keys;
    assert_eq!(k.len(), 2);
    assert!(
        k[0].time == Time::new(1, 4)
            && k[0].value == Vec2::new(0.9, 0.9)
            && k[0].interpolation == sq_core_time::Interpolation::Linear
    );
    assert!(
        k[1].time == Time::new(1, 2)
            && k[1].value == Vec2::new(1.0, 1.0)
            && k[1].interpolation == sq_core_time::Interpolation::Hold
    );
}

#[test]
fn bezier_keys_get_ease_handles() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    // 0 -> 100 over 1 s, both sides flat (slope 0) with 1/3 influence: an ease in/out.
    let keys = format!("0,0.,5,0,0,0.33333,0,0.33333;{S},100.,5,0,0,0.33333,0,0.33333");
    let p = f.pk(1, "100.", &keys);
    let opacity = f.component("AE.ADBE Opacity", &[p]);
    one_clip_sequence(&mut f, item(0, 2 * S, 0, 2 * S, Source::Media(m)).components(&[&opacity]));
    let k = &video(&map(&f))[0].animation.opacity.track.keys;
    assert_eq!(k[0].interpolation, sq_core_time::Interpolation::Bezier);
    assert!((k[0].out_handle.dx - 0.33333).abs() < 1e-6 && k[0].out_handle.dy == 0.0);
    assert!((k[1].in_handle.dx - 0.33333).abs() < 1e-6 && k[1].in_handle.dy == 0.0);
}

#[test]
fn linear_key_after_bezier_keeps_its_in_handle() {
    let mut f = PRFixture::new();
    let m = f.media("/f/a.mov", "a.mov");
    // Bezier key -> linear key: the segment is a curve and the linear key's stored in-slope (100/s = straight, 1/6) shapes it.
    let keys = format!("0,0.,5,0,0,0.33333,0,1;{S},100.,0,0,100,0.16667,0,0.16667");
    let p = f.pk(1, "100.", &keys);
    let opacity = f.component("AE.ADBE Opacity", &[p]);
    one_clip_sequence(&mut f, item(0, 2 * S, 0, 2 * S, Source::Media(m)).components(&[&opacity]));
    let k = &video(&map(&f))[0].animation.opacity.track.keys;
    assert!(
        k[0].interpolation == sq_core_time::Interpolation::Bezier
            && k[0].out_handle.dx == 1.0
            && k[0].out_handle.dy == 0.0
    );
    assert!((k[1].in_handle.dx - 0.16667).abs() < 1e-6 && (k[1].in_handle.dy - 0.16667).abs() < 1e-6);
}

// ImportChecklistTests.swift

fn loc(a: u128, b: u128) -> Location {
    Location { timeline: Id::from_u128(a), clip: Id::from_u128(b) }
}

#[test]
fn collect_ties_approximated_notes_to_the_clip() {
    let mut r = PRImportReport::default();
    let l = loc(1, 2);
    r.begin_collect();
    r.note("Text", Status::Approximated, "n");
    r.note("Video clip", Status::Mapped, "");
    r.end_collect(Some(l));
    assert_eq!(r.entries().iter().find(|e| e.feature == "Text").map(|e| e.locations.clone()), Some(vec![l]));
    assert_eq!(r.entries().iter().find(|e| e.feature == "Video clip").map(|e| e.locations.len()), Some(0));
}

#[test]
fn locations_are_not_encoded() {
    let mut r = PRImportReport::default();
    r.begin_collect();
    r.note("Text", Status::Dropped, "");
    r.end_collect(Some(loc(1, 2)));
    let json = serde_json::to_string(&r).unwrap();
    assert!(!json.contains("locations") && !json.contains("collecting"));
}

#[test]
fn offline_media_lists_every_clip_that_uses_it() {
    let mut f = PRFixture::new();
    let m = f.media("/gone/a.mov", "a.mov");
    let a = f.item(item(0, S, 0, S, Source::Media(m.clone())));
    let b = f.item(item(S, 2 * S, 0, S, Source::Media(m)));
    let t = f.track(&[a, b]);
    f.sequence("Main", &[t], &[]);
    let r = map(&f);
    let list = PRImportChecklist::new(&r.report, &r.project);
    let missing = list.items().iter().find(|i| i.kind == Kind::MissingFiles).unwrap();
    assert_eq!(missing.count, 1);
    assert_eq!(missing.locations.len(), 2);
    let ids: Vec<Id> =
        r.project.timelines.iter().flat_map(|t| t.tracks.iter()).flat_map(|t| t.clips()).map(|c| c.id).collect();
    assert!(missing.locations.iter().all(|l| ids.contains(&l.clip)));
    assert!(list.needs_attention());
}

#[test]
fn came_over_counts_clips_and_sequences() {
    let mut f = PRFixture::new();
    let m = f.media("/gone/a.mov", "a.mov");
    one_clip_sequence(&mut f, item(0, S, 0, S, Source::Media(m)));
    let r = map(&f);
    let list = PRImportChecklist::new(&r.report, &r.project);
    assert_eq!(list.items()[0].kind, Kind::CameOver);
    assert_eq!(list.items()[0].title, "1 clip, 1 sequence");
}

#[test]
fn order_and_offline_split_from_approximated() {
    let mut r = PRImportReport::default();
    r.note("Offline media", Status::Approximated, "x");
    r.note("Offline media", Status::Approximated, "x");
    r.note("AE.ADBE Lumetri", Status::Dropped, "no counterpart");
    r.note("Text", Status::Approximated, "close");
    let project = sq_core_model::Project::new(Id::from_u128(9), "p", vec![], vec![]);
    let list = PRImportChecklist::new(&r, &project);
    assert_eq!(
        list.items().iter().map(|i| i.kind).collect::<Vec<_>>(),
        vec![Kind::CameOver, Kind::Approximated, Kind::LeftOut, Kind::MissingFiles]
    );
    assert_eq!(list.items().iter().find(|i| i.kind == Kind::LeftOut).map(|i| i.title.as_str()), Some("Lumetri"));
    assert_eq!(
        list.items().iter().find(|i| i.kind == Kind::MissingFiles).map(|i| i.title.as_str()),
        Some("2 files missing")
    );
}

#[test]
fn nothing_to_check_when_all_mapped() {
    let mut r = PRImportReport::default();
    r.note("Video clip", Status::Mapped, "");
    let project = sq_core_model::Project::new(Id::from_u128(9), "p", vec![], vec![]);
    assert!(!PRImportChecklist::new(&r, &project).needs_attention());
}

#[test]
fn negative_playback_speed_is_a_reversed_clip_and_slow_motion_scales_the_source() {
    let mut f = PRFixture::new();
    let m = f.media("/f/w.wav", "w.wav");
    let back = f.item(item(0, S, 0, S, Source::Media(m.clone())).speed(-1.0).audio());
    let slow = f.item(item(S, 3 * S, 0, S, Source::Media(m)).speed(0.5).audio());
    let t = f.audio_track(&[back, slow]);
    f.sequence("Main", &[], &[t]);
    let r = map(&f);
    let c = clips(&r, "Main", TrackKind::Audio);
    assert!(c[0].reversed && c[0].speed.is_normal() && c[0].duration() == Time::new(1, 1));
    assert!(!c[1].reversed && c[1].speed == ClipSpeed::new(1, 2) && c[1].duration() == Time::new(2, 1));
    assert_eq!(c[1].source.duration, Time::new(1, 1));
    assert_eq!(r.report.status_of("Speed"), Some(Status::Mapped));
}

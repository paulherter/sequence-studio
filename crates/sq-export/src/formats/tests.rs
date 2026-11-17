// SPDX-License-Identifier: GPL-3.0-or-later
//! Tests of the interchange writers. The scenarios mirror `oracle/sq-export/formats/swift-dump/main.swift`; the golden files
//! are what the Swift writers produce for them (byte for byte). The Swift unit tests of the same files follow below.

use super::marker_csv::cell;
use super::*;
use sq_core_model::{
    Clip, ClipSpeed, GeneratorRef, Marker, MarkerColor, MediaFingerprint, MediaInfo, MediaRef, SequenceFormat,
    Timeline, Track, TrackKind, Transition, TransitionAlignment, TransitionKind,
};
use sq_core_time::{Id, Time, TimeRange};
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::{FontWeight, RGBAColor, TextAlignment, TextStyle};
use sq_text::text_template::TextTemplate;
use std::path::PathBuf;

fn t(v: i64, s: i64) -> Time {
    Time::new(v, s)
}

fn fd25() -> Time {
    t(1, 25)
}

fn ntsc() -> Time {
    t(1001, 30_000)
}

fn id(n: u64) -> Id {
    Id::fixed(n)
}

fn media(n: u64, name: &str, path: &str) -> MediaRef {
    MediaRef::new(id(n), name, path, MediaFingerprint::new(1))
}

fn media_a() -> MediaRef {
    media(1, "A001.mov", "/Volumes/Shoot/A001.mov")
}

fn media_b() -> MediaRef {
    media(2, "B & C.mov", "/Volumes/Shoot/B & C.mov")
}

/// A clip with source and position in frames of `f`.
fn clip(m: &MediaRef, kind: TrackKind, src: i64, dur: i64, at: i64, cid: u64, f: Time) -> Clip {
    Clip::new(id(cid), &m.name, m.id, kind, TimeRange::new(f * src, f * dur), f * at)
}

fn track(n: u64, kind: TrackKind, clips: Vec<Clip>) -> Track {
    let mut t = Track::new(id(n), kind);
    t.set_clips(clips);
    t
}

fn timeline(name: &str, tracks: Vec<Track>, fd: Time) -> Timeline {
    Timeline::new(id(900), name, SequenceFormat::new(fd), tracks)
}

fn transition(
    n: u64,
    kind: TransitionKind,
    dur: Time,
    alignment: TransitionAlignment,
    before: Time,
    out: Option<Id>,
    inc: Option<Id>,
) -> Transition {
    Transition {
        id: id(n),
        kind,
        duration: dur,
        alignment,
        custom_before: before,
        outgoing: out,
        incoming: inc,
        easing: None,
        direction: None,
        reversed: None,
        softness: None,
        motion_blur: None,
        stinger: None,
        params: None,
        color: None,
        border_width: None,
        border_color: None,
    }
}

fn marker(n: u64, time: Time, name: &str, color: MarkerColor, comment: &str, duration: Time) -> Marker {
    Marker { id: id(n), time, name: name.to_string(), color, comment: comment.to_string(), duration }
}

fn point(n: u64, time: Time, name: &str) -> Marker {
    marker(n, time, name, MarkerColor::Green, "", Time::ZERO)
}

fn golden(file: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../oracle/sq-export/formats/golden").join(file);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// The export equals the Swift golden: text, warnings and no failure.
fn check(name: &str, e: &InterchangeExport) {
    assert_eq!(e.failure, None, "{name}");
    assert_eq!(e.text, golden(&format!("{name}.out")), "{name} text");
    assert_eq!(e.warnings.join("\n"), golden(&format!("{name}.warn")), "{name} warnings");
}

fn all(prefix: &str, tl: &Timeline, media: &[MediaRef]) {
    check(&format!("{prefix}-edl"), &EdlWriter::render(tl, media));
    for (label, e) in layer_files(tl, media) {
        check(&format!("{prefix}-edl-{label}"), &e);
    }
    check(&format!("{prefix}-xmeml"), &XmemlWriter::render(tl, media));
    check(&format!("{prefix}-fcpxml"), &FcpxmlWriter::render(tl, media));
    check(
        &format!("{prefix}-fcpxml-fcp110"),
        &FcpxmlWriter::render_as(tl, media, FcpxmlVersion::V1_10, FcpxmlTarget::FinalCut),
    );
    check(&format!("{prefix}-otio"), &OtioWriter::render(tl, media));
}

fn audio_info(duration: Time, channels: i64, map: (&[i64], &[i64])) -> MediaInfo {
    let json = serde_json::json!({
        "duration": {"value": duration.value(), "timescale": duration.timescale()},
        "audio": {"sampleRate": 48000, "channels": channels, "codec": "AAC", "channelMap": {"left": map.0, "right": map.1}}
    });
    serde_json::from_value(json).expect("media info json")
}

#[test]
fn golden_basic() {
    let (a, b) = (media_a(), media_b());
    let link = id(800);
    let f = fd25();
    let mut c1 = clip(&a, TrackKind::Video, 250, 125, 0, 101, f);
    c1.link = Some(link);
    let mut c2 = clip(&b, TrackKind::Video, 0, 100, 125, 102, f);
    c2.speed = ClipSpeed::new(2, 1);
    c2.name = "Fast & Loud".to_string();
    let v1 = track(11, TrackKind::Video, vec![c1, c2]);
    let v2 = track(12, TrackKind::Video, vec![clip(&b, TrackKind::Video, 25, 25, 10, 103, f)]);
    let mut ca = clip(&a, TrackKind::Audio, 250, 125, 0, 104, f);
    ca.link = Some(link);
    let a1 = track(13, TrackKind::Audio, vec![ca]);
    let a2 = track(14, TrackKind::Audio, vec![clip(&b, TrackKind::Audio, 0, 25, 0, 105, f)]);
    let mut tl = timeline("Cut & \"Co\"", vec![v1, v2, a1, a2], f);
    tl.markers = vec![
        marker(201, f * 25, "Beat", MarkerColor::Green, "drum", Time::ZERO),
        marker(202, f * 50, "Range <x>", MarkerColor::Red, "two", f * 20),
    ];
    all("basic", &tl, &[a, b]);
}

#[test]
fn golden_dissolves_and_fades() {
    let (a, b) = (media_a(), media_b());
    let f = fd25();
    let c1 = clip(&a, TrackKind::Video, 0, 50, 0, 111, f);
    let c2 = clip(&a, TrackKind::Video, 100, 50, 50, 112, f);
    let c3 = clip(&b, TrackKind::Video, 0, 25, 100, 113, f);
    let mut v = track(21, TrackKind::Video, vec![c1.clone(), c2.clone(), c3.clone()]);
    v.transitions = vec![
        transition(
            301,
            TransitionKind::CrossDissolve,
            f * 10,
            TransitionAlignment::Center,
            Time::ZERO,
            Some(c1.id),
            Some(c2.id),
        ),
        transition(
            302,
            TransitionKind::Push,
            f * 5,
            TransitionAlignment::EndAtCut,
            Time::ZERO,
            Some(c2.id),
            Some(c3.id),
        ),
        transition(
            303,
            TransitionKind::DipToBlack,
            f * 8,
            TransitionAlignment::StartAtCut,
            Time::ZERO,
            Some(c3.id),
            None,
        ),
    ];
    let d1 = clip(&a, TrackKind::Audio, 0, 50, 0, 114, f);
    let d2 = clip(&b, TrackKind::Audio, 0, 50, 50, 115, f);
    let mut au = track(22, TrackKind::Audio, vec![d1.clone(), d2.clone()]);
    au.transitions = vec![
        transition(
            304,
            TransitionKind::ConstantGain,
            f * 10,
            TransitionAlignment::Custom,
            f * 4,
            Some(d1.id),
            Some(d2.id),
        ),
        transition(
            305,
            TransitionKind::ConstantPower,
            f * 6,
            TransitionAlignment::Center,
            Time::ZERO,
            None,
            Some(d1.id),
        ),
    ];
    all("dissolve", &timeline("Dissolves", vec![v, au], f), &[a, b]);
}

#[test]
fn golden_ntsc_drop_frame_reverse_hold_markers_channels() {
    let (a, b) = (media_a(), media_b());
    let n = ntsc();
    let mut m = a.clone();
    m.info = Some(audio_info(n * 5000, 2, (&[1], &[1])));
    m.duration = Some(n * 5000);
    let mut dual = b.clone();
    dual.info = Some(audio_info(n * 900, 4, (&[0, 2], &[0, 2])));
    let mut rev = clip(&a, TrackKind::Video, 100, 30, 1800, 121, n);
    rev.reversed = true;
    rev.markers = Some(vec![
        marker(211, n * 110, "Inside", MarkerColor::Cyan, "c,1", Time::ZERO),
        point(212, n * 500, "Outside"),
    ]);
    let mut held = clip(&b, TrackKind::Video, 20, 15, 1830, 122, n);
    held.hold_frame = Some(n * 24);
    let mut slow = clip(&a, TrackKind::Video, 0, 30, 1845, 123, n);
    slow.speed = ClipSpeed::new(1, 3);
    let mut odd = clip(&b, TrackKind::Video, 0, 30, 1900, 124, n);
    odd.speed = ClipSpeed::new(3, 2);
    odd.reversed = true;
    let v = track(31, TrackKind::Video, vec![rev, held, slow, odd]);
    let au = track(
        32,
        TrackKind::Audio,
        vec![clip(&m, TrackKind::Audio, 0, 60, 1800, 125, n), clip(&dual, TrackKind::Audio, 0, 60, 1900, 126, n)],
    );
    let mut tl = timeline("DF 29.97", vec![v, au], n);
    tl.set_timecode_start(n * 107_892);
    tl.markers = vec![
        marker(213, n * 1830, "Hit", MarkerColor::Red, "", Time::ZERO),
        marker(214, n * 1850, "Soft", MarkerColor::Orange, "", n * 12),
    ];
    all("ntsc", &tl, &[m, dual]);
}

#[test]
fn golden_what_cannot_be_carried_missing_media_odd_names() {
    let (a, b) = (media_a(), media_b());
    let tricky = media(3, "T\u{EB}st <x>.mov", "/Volumes/My Disk/T\u{4E2D}st #1 [a]%20;b'c\"d?e|f\\g^h`i{j}k.mov");
    let f = fd25();
    let mut off = clip(&a, TrackKind::Video, 0, 25, 0, 131, f);
    off.name = "Off\tline\nname".to_string();
    off.is_enabled = false;
    let mut text = Clip::new(id(132), "Title", id(132), TrackKind::Video, TimeRange::new(Time::ZERO, f * 25), f * 25);
    text.generator = Some(GeneratorRef { kind: "solid".to_string(), payload: Vec::new(), payload_version: 1 });
    let mut nested = Clip::new(id(133), "Nest", id(133), TrackKind::Video, TimeRange::new(Time::ZERO, f * 25), f * 50);
    nested.sequence = Some(id(901));
    let missing = clip(&a, TrackKind::Video, 5, 25, 75, 134, f);
    let mut t1 = clip(&tricky, TrackKind::Video, 5, 25, 100, 135, f);
    t1.name = "  T\u{EB}st\u{A0}\u{2003}".to_string();
    let ta = clip(&tricky, TrackKind::Audio, 5, 25, 100, 136, f);
    let mut v2 = track(42, TrackKind::Video, vec![clip(&b, TrackKind::Video, 0, 10, 0, 137, f)]);
    v2.name = "Over \"2\"".to_string();
    let tl = timeline(
        "Odd / name\u{1}\u{2028}\u{7F}",
        vec![
            track(41, TrackKind::Video, vec![off, text, nested, missing, t1]),
            v2,
            track(43, TrackKind::Audio, vec![ta]),
        ],
        f,
    );
    all("odd", &tl, &[tricky, b]);
    all("empty", &timeline("Empty", Vec::new(), f), &[]);
}

fn style(size: f64, bold: bool, italic: bool, alignment: TextAlignment) -> TextStyle {
    TextStyle {
        font_name: "Helvetica Neue".to_string(),
        size,
        weight: if bold { FontWeight::Bold } else { FontWeight::Medium },
        color: RGBAColor::new(1.0, 0.5, 0.3333333, 1.0),
        alignment,
        italic,
        ..TextStyle::default()
    }
}

fn title(cid: u64, text: &str, at: i64, dur: i64, st: TextStyle) -> Clip {
    let f = fd25();
    let reference = TextGenerator::make_ref(&TextTemplate::new("T", text, st), None).expect("text ref");
    let mut c =
        Clip::new(id(cid), "Lower & Third", id(cid), TrackKind::Video, TimeRange::new(Time::ZERO, f * dur), f * at);
    c.generator = Some(reference);
    c
}

#[test]
fn golden_titles() {
    let a = media_a();
    let f = fd25();
    let c1 = clip(&a, TrackKind::Video, 0, 50, 0, 141, f);
    let sp = title(142, "Hello\nWorld <3 & \"q\"\r\nCRLF", 50, 25, style(72.0, true, false, TextAlignment::Center));
    let over = title(143, "Over", 10, 20, style(36.5, false, true, TextAlignment::Left));
    let tl =
        timeline("Titles", vec![track(51, TrackKind::Video, vec![c1, sp]), track(52, TrackKind::Video, vec![over])], f);
    check("title-fcpxml", &FcpxmlWriter::render(&tl, std::slice::from_ref(&a)));
    check("title-fcpxml-fcp113", &FcpxmlWriter::render_as(&tl, &[a], FcpxmlVersion::V1_13, FcpxmlTarget::FinalCut));
}

#[test]
fn golden_otio_collections_and_numbers() {
    let (a, b) = (media_a(), media_b());
    let n = ntsc();
    let t1 =
        timeline("One", vec![track(61, TrackKind::Video, vec![clip(&a, TrackKind::Video, 3, 30, 1799, 151, n)])], n);
    let mut c = clip(&b, TrackKind::Video, 1, 7, 3, 152, fd25());
    c.speed = ClipSpeed::new(7, 3);
    let mut t2 = timeline("Two", vec![track(62, TrackKind::Video, vec![c])], fd25());
    t2.set_timecode_start(t(3600, 1));
    let media = [a, b];
    check("collection-otio", &OtioWriter::render_all(&[&t1, &t2], &media));
    check("none-otio", &OtioWriter::render_all(&[], &[]));
    let mut t3 = timeline("Numbers", Vec::new(), fd25());
    t3.markers = vec![
        point(240, t(1, 3), "third"),
        point(241, t(1, 10_000_000), "tiny"),
        point(242, t(1_000_000_000_000_000, 1), "huge15"),
        point(243, t(100_000_000_000_000_000, 1), "huge17"),
        marker(244, t(-2, 7), "negative", MarkerColor::Green, "", t(-1, 1)),
        marker(245, t(7, 1000), "ms", MarkerColor::Green, "", t(123_456_789, 1000)),
        point(246, t(1, 1_000_000_000_000), "e-14"),
        marker(247, t(4, 1), "four", MarkerColor::Green, "", t(1, 8)),
    ];
    check("numbers-otio", &OtioWriter::render(&t3, &[]));
}

fn cue(lines: &[&str], s: Time, e: Time) -> SrtCue {
    SrtCue { lines: lines.iter().map(|l| l.to_string()).collect(), range: TimeRange::new(s, e - s) }
}

#[test]
fn golden_subtitles() {
    let cues = vec![
        cue(&["Second & <b>", "line --> two"], t(5, 2), t(7, 1)),
        cue(&["First"], t(1, 3), t(2, 1)),
        cue(&["", "  ", "\t"], t(1, 1), t(2, 1)),
        cue(&["Same start A"], t(10, 1), t(11, 1)),
        cue(&["Same start B", "", "tail > x"], t(10, 1), t(12, 1)),
        cue(&["Tiny"], t(20, 1), t(20_001, 1000)),
        cue(&["Rounds to nothing"], t(30, 1), t(30, 1) + t(1, 4000)),
        cue(&["Late"], t(3600 + 61, 1) + t(1, 1000), t(3600 + 65, 1)),
        cue(&["Half ms"], t(1, 4000) * 3, t(1, 2) + t(1, 4000) * 3),
    ];
    let window = RangeSelection::InOut(TimeRange::new(t(3, 2), t(9, 1)));
    let all = RangeSelection::EntireSequence;
    assert_eq!(SrtWriter::render(&cues, all), golden("subs-srt.out"));
    assert_eq!(SrtWriter::render(&cues, window), golden("subs-srt-window.out"));
    assert_eq!(VttWriter::render(&cues, all), golden("subs-vtt.out"));
    assert_eq!(VttWriter::render(&cues, window), golden("subs-vtt-window.out"));
    assert_eq!(IttWriter::render(&cues, "en-US&<\">", all), golden("subs-itt.out"));
    assert_eq!(IttWriter::render(&cues, "de", window), golden("subs-itt-window.out"));
    assert_eq!(SrtWriter::render(&[], all), golden("subs-empty-srt.out"));
}

#[test]
fn golden_marker_csv() {
    let a = media_a();
    let f = fd25();
    let mut c = clip(&a, TrackKind::Video, 50, 100, 25, 161, f);
    c.name = "Clip, \"one\"".to_string();
    c.markers = Some(vec![
        marker(221, f * 60, "=SUM(A1)", MarkerColor::Red, "line\nbreak", Time::ZERO),
        point(222, f * 10, "BeforeIn"),
        marker(223, f * 70, "+plus", MarkerColor::Green, "crlf\r\nbreak", f * 5),
    ]);
    let mut tl = timeline("CSV", vec![track(71, TrackKind::Video, vec![c])], f);
    tl.markers = vec![
        marker(224, f * 85, "Same time", MarkerColor::Green, "say \"hi\", ok", Time::ZERO),
        marker(225, f * 5, "@at", MarkerColor::Purple, "-minus", Time::ZERO),
        marker(226, f * 85, "\tTab", MarkerColor::White, "\rCR", f * 12),
    ];
    tl.set_timecode_start(t(3600, 1));
    check("csv-ndf", &MarkerCsv::export(&tl));
    let n = ntsc();
    let mut tl2 = timeline("CSV DF", vec![track(72, TrackKind::Video, Vec::new())], n);
    tl2.markers = vec![marker(227, n * 1800, "Minute", MarkerColor::Green, "", n * 1800)];
    tl2.set_timecode_start(n * 107_892);
    check("csv-df", &MarkerCsv::export(&tl2));
}

#[test]
fn golden_youtube_chapters() {
    let mk = |s: i64, n: &str, d: i64| point(230, t(s, d), n);
    let ms = [
        mk(0, "Start", 1),
        mk(75, " Second\nline ", 1),
        mk(75, "dup", 1),
        mk(4000, "Long", 1),
        mk(3, "  ", 1),
        mk(8090, "Late", 1),
        mk(9, "Short", 2),
        mk(12, "Out", 1),
    ];
    let mut out = String::new();
    let mut show = |title: &str, r: YouTubeChaptersResult| {
        out += &format!("== {title}\n{}\n-- warnings\n{}\n", r.text, r.warnings.join("\n"));
    };
    show("all", YouTubeChapters::make(&ms, Time::ZERO, None));
    show("range", YouTubeChapters::make(&ms, t(60, 1), Some(t(4100, 1))));
    show("none", YouTubeChapters::make(&[], Time::ZERO, None));
    show("short", YouTubeChapters::make(&[mk(0, "A", 1), mk(5, "B", 1), mk(30, "C", 1)], Time::ZERO, Some(t(33, 1))));
    assert_eq!(out, golden("chapters.out"));
}

#[test]
fn file_urls_match_foundation() {
    for line in golden("urls.tsv").lines() {
        let (key, url) = line.split_once('\t').expect("tsv row");
        let path = if key == "u" {
            "/x/\u{E9}\u{4E2D}\u{1F600}.mov".to_string()
        } else {
            let c = char::from(key.parse::<u8>().expect("ascii code"));
            format!("/x/a{c}b")
        };
        if key == "u" {
            // Foundation decomposes the e-acute (see the shortcut note on `file_url`); everything else is the same.
            assert_eq!(file_url(&path), url.replace("e%CC%81", "%C3%A9"));
        } else {
            assert_eq!(file_url(&path), url, "char {key}");
        }
    }
    assert_eq!(file_url("C:\\Users\\a b.mov"), "file:///C:/Users/a%20b.mov");
}

// MARK: ports of the Swift tests (InterchangeWriterTests, InterchangeFidelityTests, SRTTests, ITTWriterTests, MarkerCSVTests)

fn lines_of(s: &str) -> Vec<String> {
    s.split('\n').map(str::to_string).collect()
}

fn has(lines: &[String], s: &str) -> bool {
    lines.iter().any(|l| l == s)
}

#[test]
fn edl_cuts_speed_names_and_paths() {
    let (a, b) = (media_a(), media_b());
    let f = fd25();
    let link = id(800);
    let mut c1 = clip(&a, TrackKind::Video, 250, 125, 0, 1, f);
    c1.link = Some(link);
    let mut c2 = clip(&b, TrackKind::Video, 0, 100, 125, 2, f);
    c2.speed = ClipSpeed::new(2, 1); // 2 s at 200 % plays 4 s of source
    let v = track(1, TrackKind::Video, vec![c1, c2]);
    let mut ca = clip(&a, TrackKind::Audio, 250, 125, 0, 3, f);
    ca.link = Some(link);
    let au = track(2, TrackKind::Audio, vec![ca]);
    let out = EdlWriter::render(&timeline("Cut", vec![v, au], f), &[a, b]);
    let lines = lines_of(&out.text);
    assert_eq!(lines[0], "TITLE: Cut");
    assert_eq!(lines[1], "FCM: NON-DROP FRAME");
    assert!(has(&lines, "001  AX       V     C        00:00:10:00 00:00:15:00 00:00:00:00 00:00:05:00"));
    assert!(has(&lines, "* FROM CLIP NAME: A001.mov"));
    assert!(has(&lines, "* SOURCE FILE: /Volumes/Shoot/A001.mov"));
    assert!(has(&lines, "002  AX       V     C        00:00:00:00 00:00:04:00 00:00:05:00 00:00:07:00"));
    assert!(lines.iter().any(|l| l.starts_with("M2   AX       050.0 ") && l.ends_with(" 00:00:00:00")));
    assert!(has(&lines, "003  AX       A     C        00:00:10:00 00:00:15:00 00:00:00:00 00:00:05:00"));
    assert!(out.warnings.is_empty());
}

#[test]
fn edl_layers_above_v1_get_their_own_file() {
    let (a, b) = (media_a(), media_b());
    let f = fd25();
    let v1 = track(1, TrackKind::Video, vec![clip(&a, TrackKind::Video, 0, 50, 0, 1, f)]);
    let v2 = track(2, TrackKind::Video, vec![clip(&b, TrackKind::Video, 25, 25, 10, 2, f)]);
    let au = track(3, TrackKind::Audio, vec![clip(&a, TrackKind::Audio, 0, 50, 0, 3, f)]);
    let empty = track(4, TrackKind::Video, Vec::new());
    let tl = timeline("Cut", vec![v1, v2, au, empty], f);
    let main = EdlWriter::render(&tl, &[a.clone(), b.clone()]);
    assert!(!main.text.contains("B & C.mov"));
    assert!(main.warnings.iter().any(|w| w.contains("above V1")));
    let layers = layer_files(&tl, &[a, b]);
    assert_eq!(layers.iter().map(|l| l.0.as_str()).collect::<Vec<_>>(), ["V2"]); // the empty V3 gets no file
    let lines = lines_of(&layers[0].1.text);
    assert_eq!(lines[0], "TITLE: Cut V2");
    assert!(has(&lines, "001  AX       V     C        00:00:01:00 00:00:02:00 00:00:00:10 00:00:01:10"));
    assert!(has(&lines, "* FROM CLIP NAME: B & C.mov"));
    assert!(!lines.iter().any(|l| l.contains("  A  ") || l.contains("A001.mov")));
    assert!(layers[0].1.warnings.is_empty());
}

#[test]
fn edl_dissolve_is_zero_length_cut_plus_d_event() {
    let (a, b) = (media_a(), media_b());
    let f = fd25();
    let first = clip(&a, TrackKind::Video, 250, 125, 0, 1, f);
    let second = clip(&b, TrackKind::Video, 500, 75, 125, 2, f);
    let mut v = track(1, TrackKind::Video, vec![first.clone(), second.clone()]);
    v.transitions = vec![transition(
        1,
        TransitionKind::CrossDissolve,
        f * 25,
        TransitionAlignment::StartAtCut,
        Time::ZERO,
        Some(first.id),
        Some(second.id),
    )];
    let lines = lines_of(&EdlWriter::render(&timeline("Cut", vec![v], f), &[a, b]).text);
    assert!(has(&lines, "002  AX       V     C        00:00:15:00 00:00:15:00 00:00:05:00 00:00:05:00"));
    assert!(has(&lines, "002  AX       V     D    025 00:00:20:00 00:00:23:00 00:00:05:00 00:00:08:00"));
    assert!(has(&lines, "* TO CLIP NAME: B & C.mov"));
}

#[test]
fn edl_drop_frame_start_timecode_reverse_and_markers() {
    let a = media_a();
    let n = ntsc();
    let mut c = clip(&a, TrackKind::Video, 100, 30, 1800, 1, n);
    c.reversed = true;
    let mut tl = timeline("Cut", vec![track(1, TrackKind::Video, vec![c])], n);
    tl.markers = vec![marker(1, n * 1830, "Hit", MarkerColor::Red, "", Time::ZERO)];
    let lines = lines_of(&EdlWriter::render(&tl, &[a]).text);
    assert_eq!(lines[1], "FCM: DROP FRAME");
    assert!(has(&lines, "001  AX       V     C        00:00:04;10 00:00:03;10 00:01:00;02 00:01:01;02"));
    assert!(lines.iter().any(|l| l.starts_with("M2   AX       -029.97003 ") && l.ends_with(" 00:00:04;10")));
    assert!(has(&lines, "* LOC: 00:01:01;02 RED Hit"));
}

#[test]
fn edl_record_base_follows_sequence_timecode_start() {
    let a = media_a();
    let mut tl = timeline(
        "Cut",
        vec![track(1, TrackKind::Video, vec![clip(&a, TrackKind::Video, 0, 25, 0, 1, fd25())])],
        fd25(),
    );
    tl.set_timecode_start(t(3600, 1));
    assert!(EdlWriter::render(&tl, &[a]).text.contains("00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00"));
}

#[test]
fn edl_skips_what_it_cannot_carry() {
    let (a, b) = (media_a(), media_b());
    let f = fd25();
    let mut off = clip(&a, TrackKind::Video, 0, 25, 0, 1, f);
    off.is_enabled = false;
    let mut text = Clip::new(id(2), "Title", id(2), TrackKind::Video, TimeRange::new(Time::ZERO, f * 25), f * 25);
    text.generator = Some(GeneratorRef { kind: "text".to_string(), payload: Vec::new(), payload_version: 1 });
    let upper = track(2, TrackKind::Video, vec![clip(&b, TrackKind::Video, 0, 25, 0, 3, f)]);
    let tl = timeline(
        "Cut",
        vec![track(1, TrackKind::Video, vec![off, text, clip(&a, TrackKind::Video, 5, 25, 50, 4, f)]), upper],
        f,
    );
    let out = EdlWriter::render(&tl, &[a, b]);
    assert!(!out.text.contains("B & C"));
    assert_eq!(out.warnings.len(), 3);
    assert!(out.text.contains("001  AX       V     C"));
    assert!(!out.text.contains("002  AX       V"));
}

#[test]
fn fcpxml_spine_gap_connected_speed_transition_and_marker() {
    let (a, b) = (media_a(), media_b());
    let f = fd25();
    let link = id(800);
    let mut c1 = clip(&a, TrackKind::Video, 50, 50, 25, 1, f);
    c1.link = Some(link);
    let mut c2 = clip(&b, TrackKind::Video, 0, 100, 100, 2, f);
    c2.speed = ClipSpeed::new(2, 1); // 2 s, 4 s of source
    c2.name = "Fast & Loud".to_string();
    let mut v1 = track(1, TrackKind::Video, vec![c1.clone(), c2.clone()]);
    v1.transitions = vec![transition(
        1,
        TransitionKind::CrossDissolve,
        f * 10,
        TransitionAlignment::Center,
        Time::ZERO,
        Some(c1.id),
        Some(c2.id),
    )];
    let over = clip(&b, TrackKind::Video, 0, 25, 50, 3, f);
    let mut ca = clip(&a, TrackKind::Audio, 50, 50, 25, 4, f);
    ca.link = Some(link);
    let a1 = track(2, TrackKind::Audio, vec![ca]);
    let a2 = track(3, TrackKind::Audio, vec![clip(&b, TrackKind::Audio, 0, 25, 0, 5, f)]);
    let mut tl = timeline("Cut", vec![v1, track(4, TrackKind::Video, vec![over]), a1, a2], f);
    tl.markers = vec![marker(1, f * 25, "Beat", MarkerColor::Green, "drum", Time::ZERO)];
    let x = FcpxmlWriter::render(&tl, &[a, b]).text;
    assert!(x.contains("<fcpxml version=\"1.8\">"));
    assert!(x.contains("<format id=\"r1\" frameDuration=\"1/25s\" width=\"1920\" height=\"1080\"/>"));
    assert!(x.contains("src=\"file:///Volumes/Shoot/A001.mov\""));
    assert!(x.contains("src=\"file:///Volumes/Shoot/B%20&amp;%20C.mov\""));
    assert!(x.contains("<gap name=\"Gap\" offset=\"0s\" start=\"0s\" duration=\"1s\">"));
    assert!(x.contains("<asset-clip ref=\"r2\" offset=\"1s\" name=\"A001.mov\" start=\"2s\" duration=\"2s\""));
    assert!(x.contains("name=\"Fast &amp; Loud\""));
    assert!(x.contains("<timept time=\"0s\" value=\"0s\" interp=\"linear\"/>"));
    assert!(x.contains("<timept time=\"2s\" value=\"4s\" interp=\"linear\"/>"));
    assert!(x.contains("lane=\"1\" offset=\"3s\""));
    assert!(x.contains("<audio ref=\"r3\" lane=\"-2\""));
    assert!(x.contains("<marker start=\"2s\" duration=\"1/25s\" value=\"Beat\" note=\"drum\"/>"));
    assert!(!x.contains("<transition"));
}

#[test]
fn fcpxml_cross_dissolve_between_adjacent_spine_clips() {
    let a = media_a();
    let f = fd25();
    let c1 = clip(&a, TrackKind::Video, 0, 50, 0, 1, f);
    let c2 = clip(&a, TrackKind::Video, 100, 50, 50, 2, f);
    let mut v = track(1, TrackKind::Video, vec![c1.clone(), c2.clone()]);
    v.transitions = vec![transition(
        1,
        TransitionKind::CrossDissolve,
        f * 10,
        TransitionAlignment::Center,
        Time::ZERO,
        Some(c1.id),
        Some(c2.id),
    )];
    let x = FcpxmlWriter::render(&timeline("Cut", vec![v], f), &[a]).text;
    assert!(x.contains("<transition name=\"Cross Dissolve\" offset=\"9/5s\" duration=\"2/5s\""));
    assert!(x.contains("tcFormat=\"NDF\""));
}

#[test]
fn fcpxml_drop_frame_timecode_and_offsets() {
    let a = media_a();
    let n = ntsc();
    let mut tl = timeline("Cut", vec![track(1, TrackKind::Video, vec![clip(&a, TrackKind::Video, 0, 30, 0, 1, n)])], n);
    tl.set_timecode_start(n * 107_892);
    let x = FcpxmlWriter::render(&tl, &[a]).text;
    assert!(x.contains("tcFormat=\"DF\""));
    assert!(x.contains("frameDuration=\"1001/30000s\""));
    let start = fcpxml::time_string(tl.timecode_start());
    assert!(x.contains(&format!("tcStart=\"{start}\"")));
    assert!(x.contains(&format!("offset=\"{start}\"")));
}

#[test]
fn fcpxml_writes_text_clips_as_titles() {
    let a = media_a();
    let f = fd25();
    let c1 = clip(&a, TrackKind::Video, 0, 50, 0, 1, f);
    let spine_title = title(2, "Hello\nWorld <3", 50, 25, style(72.0, true, false, TextAlignment::Center));
    let over = title(3, "Over", 10, 20, style(72.0, true, false, TextAlignment::Center));
    let tl = timeline(
        "Cut",
        vec![track(1, TrackKind::Video, vec![c1, spine_title]), track(2, TrackKind::Video, vec![over])],
        f,
    );
    let out = FcpxmlWriter::render(&tl, &[a]);
    let x = &out.text;
    assert!(out.warnings.is_empty());
    assert!(x.contains("<effect id=\"r3\" name=\"Basic Title\" uid=\".../Titles.localized/"));
    assert!(x.contains("<title ref=\"r3\" offset=\"2s\" name=\"Lower &amp; Third\" start=\"0s\" duration=\"1s\">"));
    assert!(x.contains(
        "<title ref=\"r3\" lane=\"1\" offset=\"2/5s\" name=\"Lower &amp; Third\" start=\"0s\" duration=\"4/5s\">"
    ));
    assert!(x.contains("<text-style ref=\"ts2\">Hello&#10;World &lt;3</text-style>"));
    assert!(x.contains("<text-style ref=\"ts1\">Over</text-style>"));
    assert!(x.contains("fontSize=\"72\""));
    assert!(x.contains("fontColor=\"1 0.5 0.333333 1\""));
    assert!(x.contains("bold=\"1\""));
    assert!(x.contains("alignment=\"center\""));
    assert!(!x.contains("<gap"), "the title in the spine closes the sequence, no gap needed");
}

#[test]
fn fcpxml_still_skips_other_generators_and_warns() {
    let f = fd25();
    let mut solid = Clip::new(id(1), "Dip", id(1), TrackKind::Video, TimeRange::new(Time::ZERO, f * 25), Time::ZERO);
    solid.generator = Some(GeneratorRef { kind: "solid".to_string(), payload: Vec::new(), payload_version: 1 });
    let out = FcpxmlWriter::render(&timeline("Cut", vec![track(1, TrackKind::Video, vec![solid])], f), &[]);
    assert!(out.warnings.iter().any(|w| w.contains("Generator")));
    assert!(!out.text.contains("<title"));
}

#[test]
fn fcpxml_split_channel_writes_channel_source() {
    let f = fd25();
    let mut m = media_a();
    m.info = Some(audio_info(f * 500, 2, (&[1], &[1])));
    let tl = timeline("S", vec![track(1, TrackKind::Audio, vec![clip(&m, TrackKind::Audio, 0, 50, 0, 1, f)])], f);
    assert!(
        FcpxmlWriter::render(&tl, std::slice::from_ref(&m))
            .text
            .contains("<audio-channel-source srcCh=\"2\" outCh=\"L, R\" active=\"1\"/>")
    );
    // A plain stereo file writes no channel source.
    let mut st = media_a();
    st.info = Some(audio_info(f * 500, 2, (&[0], &[1])));
    let tl2 = timeline("S", vec![track(1, TrackKind::Audio, vec![clip(&st, TrackKind::Audio, 0, 50, 0, 1, f)])], f);
    assert!(!FcpxmlWriter::render(&tl2, &[st]).text.contains("audio-channel-source"));
}

#[test]
fn xmeml_split_channel_and_first_channel_track_index() {
    let f = fd25();
    let mut m = media_a();
    m.info = Some(audio_info(f * 500, 2, (&[1], &[1])));
    let tl = timeline("S", vec![track(1, TrackKind::Audio, vec![clip(&m, TrackKind::Audio, 0, 50, 0, 1, f)])], f);
    let out = XmemlWriter::render(&tl, &[m]);
    assert!(out.text.contains("<trackindex>2</trackindex></sourcetrack>"));
    assert!(out.text.contains("<channelcount>2</channelcount>"));
    let a = media_a();
    let tl = timeline("S", vec![track(1, TrackKind::Audio, vec![clip(&a, TrackKind::Audio, 0, 50, 0, 1, f)])], f);
    assert!(XmemlWriter::render(&tl, &[a]).text.contains("<trackindex>1</trackindex></sourcetrack>"));
}

#[test]
fn edl_writes_an_audio_d_event() {
    let (a, b) = (media_a(), media_b());
    let f = fd25();
    let c1 = clip(&a, TrackKind::Audio, 0, 50, 0, 1, f);
    let c2 = clip(&b, TrackKind::Audio, 0, 50, 50, 2, f);
    let mut au = track(1, TrackKind::Audio, vec![c1.clone(), c2.clone()]);
    au.transitions = vec![transition(
        1,
        TransitionKind::ConstantPower,
        f * 10,
        TransitionAlignment::StartAtCut,
        Time::ZERO,
        Some(c1.id),
        Some(c2.id),
    )];
    let out = EdlWriter::render(&timeline("AD", vec![au], f), &[a, b]);
    assert!(out.text.contains("D    010"));
    assert!(!out.warnings.iter().any(|w| w.contains("Audio transitions")));
}

#[test]
fn xmeml_links_survive_when_ranges_differ() {
    let (a, b) = (media_a(), media_b());
    let f = fd25();
    let group = id(800);
    let mut v = clip(&a, TrackKind::Video, 50, 50, 25, 1, f);
    let mut s = clip(&a, TrackKind::Audio, 25, 75, 0, 2, f);
    v.link = Some(group);
    s.link = Some(group);
    let other = clip(&b, TrackKind::Audio, 0, 25, 100, 3, f);
    let tl = timeline("L", vec![track(1, TrackKind::Video, vec![v]), track(2, TrackKind::Audio, vec![s, other])], f);
    let out = XmemlWriter::render(&tl, &[a, b]);
    assert!(out.text.contains("<linkclipref>clipitem-1</linkclipref>"));
    assert!(out.text.contains("<linkclipref>clipitem-2</linkclipref>"));
}

#[test]
fn fcpxml_version_ten_writes_media_rep_and_targets_encode_frame_times_differently() {
    let a = media_a();
    let f = fd25();
    let tl = timeline("V", vec![track(1, TrackKind::Video, vec![clip(&a, TrackKind::Video, 0, 50, 0, 1, f)])], f);
    let old = FcpxmlWriter::render(&tl, std::slice::from_ref(&a));
    assert!(
        old.text.contains("<fcpxml version=\"1.8\">") && old.text.contains(" src=\"file:///Volumes/Shoot/A001.mov\"")
    );
    for v in [FcpxmlVersion::V1_10, FcpxmlVersion::V1_13] {
        let out = FcpxmlWriter::render_as(&tl, std::slice::from_ref(&a), v, FcpxmlTarget::FinalCut);
        assert!(out.text.contains(&format!("<fcpxml version=\"{}\">", v.raw())));
        assert!(out.text.contains("<media-rep kind=\"original-media\" src=\"file:///Volumes/Shoot/A001.mov\"/>"));
        assert!(out.text.contains("colorSpace="));
    }
    let n = ntsc();
    let tl = timeline("V", vec![track(1, TrackKind::Video, vec![clip(&a, TrackKind::Video, 0, 10, 0, 1, n)])], n);
    let resolve =
        FcpxmlWriter::render_as(&tl, std::slice::from_ref(&a), FcpxmlVersion::V1_8, FcpxmlTarget::Resolve).text;
    let fcp = FcpxmlWriter::render_as(&tl, &[a], FcpxmlVersion::V1_10, FcpxmlTarget::FinalCut).text;
    assert!(resolve.contains("duration=\"1001/3000s\""));
    assert!(fcp.contains("duration=\"10010/30000s\""));
    assert!(!fcp.contains("1001/3000s"));
}

#[test]
fn frame_aligned_string_keeps_off_grid_times_reduced() {
    let n = ntsc();
    assert_eq!(fcpxml::frame_aligned_string(Time::ZERO, n), "0s");
    assert_eq!(fcpxml::frame_aligned_string(n * 3, n), "3003/30000s");
    assert_eq!(fcpxml::frame_aligned_string(t(1, 2), n), "1/2s");
    assert_eq!(fcpxml::frame_aligned_string(t(4, 1), t(1, 25)), "100/25s");
}

#[test]
fn edl_header_says_drop_frame_at_ntsc() {
    let a = media_a();
    let n = ntsc();
    let tl = timeline("DF", vec![track(1, TrackKind::Video, vec![clip(&a, TrackKind::Video, 0, 30, 17_982, 1, n)])], n);
    let text = EdlWriter::render(&tl, &[a]).text;
    assert!(text.contains("FCM: DROP FRAME"));
    assert!(text.contains("00:10:00;00"));
}

#[test]
fn write_throws_when_the_file_cannot_be_written_and_failed_render_does_not_write() {
    let out = EdlWriter::render(&timeline("x", Vec::new(), fd25()), &[]);
    let dir = std::env::temp_dir().join(format!("sq-x2-{}", std::process::id()));
    assert!(matches!(out.write_to(&dir.join("none/a.edl")), Err(InterchangeExportError::WriteFailed(..))));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let ok = dir.join("a.edl");
    out.write_to(&ok).expect("write");
    assert_eq!(std::fs::read(&ok).expect("read"), out.text.as_bytes());
    let bad = InterchangeExport { text: String::new(), warnings: Vec::new(), failure: Some("boom".to_string()) };
    let missing = dir.join("b.otio");
    assert_eq!(bad.write_to(&missing), Err(InterchangeExportError::Failed("boom".to_string())));
    assert!(!missing.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

fn cue_ms(lines: &[&str], s: i64, e: i64) -> SrtCue {
    cue(lines, t(s, 1000), t(e, 1000))
}

#[test]
fn srt_timecode_format_and_rounding() {
    assert_eq!(SrtWriter::timecode(Time::ZERO), "00:00:00,000");
    assert_eq!(SrtWriter::timecode(t(3_661_005, 1000)), "01:01:01,005");
    assert_eq!(SrtWriter::timecode(t(1, 3)), "00:00:00,333");
    assert_eq!(SrtWriter::timecode(t(2, 3)), "00:00:00,667");
    assert_eq!(SrtWriter::timecode(t(1, 2000)), "00:00:00,001");
    assert_eq!(SrtWriter::timecode(t(1001, 30000) * 30), "00:00:01,001");
    assert_eq!(SrtWriter::timecode(t(-5, 1)), "00:00:00,000");
    assert_eq!(SrtWriter::timecode(t(360_000, 1)), "100:00:00,000");
}

#[test]
fn srt_cues_come_out_in_time_order_with_crlf() {
    let out = SrtWriter::render(
        &[cue_ms(&["Late"], 5000, 6000), cue_ms(&["Early"], 1000, 2000), cue_ms(&["Middle"], 3000, 4000)],
        RangeSelection::EntireSequence,
    );
    assert_eq!(
        out,
        "1\r\n00:00:01,000 --> 00:00:02,000\r\nEarly\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nMiddle\r\n\r\n3\r\n00:00:05,000 --> 00:00:06,000\r\nLate\r\n\r\n"
    );
    let out = SrtWriter::render(
        &[cue_ms(&["Hello", "world"], 0, 1500), cue_ms(&["Bye"], 2000, 2500)],
        RangeSelection::EntireSequence,
    );
    assert_eq!(
        out,
        "1\r\n00:00:00,000 --> 00:00:01,500\r\nHello\r\nworld\r\n\r\n2\r\n00:00:02,000 --> 00:00:02,500\r\nBye\r\n\r\n"
    );
}

#[test]
fn srt_offsets_and_clips_to_range() {
    let r = RangeSelection::InOut(TimeRange::from_end(t(10, 1), t(20, 1)));
    let cues = [
        cue_ms(&["before"], 1000, 9000),
        cue_ms(&["straddle in"], 9000, 11000),
        cue_ms(&["inside"], 12000, 14000),
        cue_ms(&["touch end"], 20000, 21000),
        cue_ms(&["straddle out"], 19000, 25000),
    ];
    let out = SrtWriter::render(&cues, r);
    assert!(out.contains("1\r\n00:00:00,000 --> 00:00:01,000\r\nstraddle in"));
    assert!(out.contains("2\r\n00:00:02,000 --> 00:00:04,000\r\ninside"));
    assert!(out.contains("3\r\n00:00:09,000 --> 00:00:10,000\r\nstraddle out"));
    assert!(!out.contains("before") && !out.contains("touch end"));
}

#[test]
fn srt_skips_empty_cues_and_blank_lines() {
    let cues = [
        cue_ms(&[], 0, 1000),
        cue_ms(&["  ", ""], 0, 1000),
        cue_ms(&["a", "", "b"], 1000, 2000),
        cue_ms(&["zero length"], 3000, 3000),
        cue(&["tiny"], t(1, 3), t(1, 3) + t(1, 10_000)),
    ];
    assert_eq!(
        SrtWriter::render(&cues, RangeSelection::EntireSequence),
        "1\r\n00:00:01,000 --> 00:00:02,000\r\na\r\nb\r\n\r\n"
    );
    assert!(SrtWriter::render(&[], RangeSelection::EntireSequence).is_empty());
}

#[test]
fn itt_renders_language_sorted_cues_and_escapes() {
    let out = IttWriter::render(
        &[cue_ms(&["B & <i>", "second"], 3000, 4000), cue_ms(&["A"], 1000, 2500)],
        "de-DE",
        RangeSelection::EntireSequence,
    );
    assert!(out.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tt "));
    assert!(out.contains("xml:lang=\"de-DE\""));
    assert!(out.contains("ttp:timeBase=\"media\""));
    assert!(out.contains("<p begin=\"00:00:01.000\" end=\"00:00:02.500\" region=\"bottom\" style=\"s1\">A</p>"));
    assert!(out.contains(">B &amp; &lt;i&gt;<br/>second</p>"));
    assert!(out.find(">A</p>") < out.find("second</p>"));
}

#[test]
fn itt_clips_to_the_range_and_drops_empty_cues() {
    let r = RangeSelection::InOut(TimeRange::from_end(t(10, 1), t(20, 1)));
    let out = IttWriter::render(
        &[
            cue_ms(&["Out"], 1000, 2000),
            cue_ms(&["Edge"], 9000, 11_000),
            cue_ms(&["  "], 12_000, 13_000),
            cue_ms(&["In"], 15_000, 16_000),
        ],
        "en",
        r,
    );
    assert!(out.contains("begin=\"00:00:00.000\" end=\"00:00:01.000\""));
    assert!(out.contains("begin=\"00:00:05.000\" end=\"00:00:06.000\""));
    assert!(!out.contains(">Out<"));
    assert_eq!(out.matches("<p ").count(), 2);
}

#[test]
fn marker_csv_header_rows_in_time_order_and_cells() {
    let n = t(1, 30);
    let mut tl = timeline("S", Vec::new(), n);
    tl.markers = vec![
        marker(1, t(60, 30), "B", MarkerColor::Red, "later", Time::ZERO),
        marker(2, t(30, 30), "A", MarkerColor::Green, "", t(15, 30)),
    ];
    assert_eq!(
        MarkerCsv::export(&tl).text,
        "Scope,Name,Color,In,Out,Duration,Comment\r\nSequence,A,green,00:00:01:00,00:00:01:15,00:00:00:15,\r\nSequence,B,red,00:00:02:00,00:00:02:00,00:00:00:00,later\r\n"
    );
    assert_eq!(cell("=SUM(A1)"), "'=SUM(A1)");
    assert_eq!(cell("+1"), "'+1");
    assert_eq!(cell("@x"), "'@x");
    assert_eq!(cell("-2"), "'-2");
    assert_eq!(cell("a,b"), "\"a,b\"");
    assert_eq!(cell("say \"hi\""), "\"say \"\"hi\"\"\"");
    assert_eq!(cell("two\nlines"), "\"two\nlines\"");
    assert_eq!(cell("plain"), "plain");
}

#[test]
fn marker_csv_timecode_start_shifts_positions_not_durations_and_drop_frame() {
    let mut tl = timeline("S", Vec::new(), t(1, 30));
    tl.markers = vec![marker(1, t(30, 30), "A", MarkerColor::Green, "", t(30, 30))];
    tl.set_timecode_start(t(3600, 1));
    let text = MarkerCsv::export(&tl).text;
    assert_eq!(text.split("\r\n").nth(1), Some("Sequence,A,green,01:00:01:00,01:00:02:00,00:00:01:00,"));
    let row = MarkerCsvRow {
        scope: "Sequence".into(),
        name: "M".into(),
        color: "red".into(),
        time: t(1001 * 1800, 30000),
        duration: Time::ZERO,
        comment: String::new(),
    };
    assert!(MarkerCsv::render(&[row], t(1001, 30000), Time::ZERO).contains("00:01:00;02"));
}

#[test]
fn youtube_chapters_basics() {
    let ms =
        [point(1, t(0, 1), "Start"), point(2, t(75, 1), "Middle"), point(3, t(3725, 1), "End"), point(4, t(80, 1), "")];
    let r = YouTubeChapters::make(&ms, Time::ZERO, None);
    assert_eq!(r.text, "0:00 Start\n1:15 Middle\n1:02:05 End");
    assert!(r.warnings.is_empty());
    let r2 = YouTubeChapters::make(&[point(1, t(20, 1), "A"), point(2, t(25, 1), "B")], Time::ZERO, None);
    assert!(r2.text.starts_with("0:00 Intro\n0:20 A"));
    assert!(r2.warnings.len() >= 2);
}

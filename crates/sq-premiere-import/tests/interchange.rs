//! EDL, Final Cut Pro 7 XML, FCPXML and OTIO readers and the interchange mapper (inline fixtures, no footage).
//! Swift: InterchangeTests.swift.
#![allow(clippy::unwrap_used, reason = "helpers of integration tests; clippy.toml only covers test functions")]

use sq_core_model::{ClipSpeed, TrackKind, TransitionAlignment};
use sq_core_time::{SequentialIds, Time};
use sq_premiere_import::edlreader::EDLReader;
use sq_premiere_import::fcpxmlreader::FCPXMLReader;
use sq_premiere_import::interchange_model::{
    IXMarker, IXTransition, InterchangeError, InterchangeFormat, InterchangeMapper, InterchangeReader,
};
use sq_premiere_import::primport_report::Status;
use sq_premiere_import::xmemlreader::XMEMLReader;

const EDL: &str = "TITLE: Cut One
FCM: NON-DROP FRAME

001  AX       V     C        00:00:10:00 00:00:15:00 01:00:00:00 01:00:05:00
* FROM CLIP NAME: A001.mov
* SOURCE FILE: /Volumes/Shoot/A001.mov
002  AX       AA/V  C        00:00:00:00 00:00:02:00 01:00:05:00 01:00:07:00
* FROM CLIP NAME: B002.mov
003  AX       V     C        00:00:20:00 00:00:20:00 01:00:07:00 01:00:07:00
003  AX       V     D    025 00:00:00:00 00:00:03:00 01:00:07:00 01:00:10:00
* TO CLIP NAME: C003.mov
004  AX       V     C        00:00:30:00 00:00:32:00 01:00:12:00 01:00:14:00
M2   AX       012.5                00:00:30:00
* FROM CLIP NAME: D004.mov
* LOC: 01:00:01:00 RED first
";

fn t(v: i64, s: i64) -> Time {
    Time::new(v, s)
}

#[test]
fn edl_events_tracks_speed_and_transition() {
    let s = EDLReader::read(EDL, "x", t(1, 25)).unwrap();
    assert_eq!(s.name, "Cut One");
    let video: Vec<_> = s.tracks.iter().filter(|t| t.kind == TrackKind::Video).collect();
    let audio: Vec<_> = s.tracks.iter().filter(|t| t.kind == TrackKind::Audio).collect();
    assert!(video.len() == 1 && video[0].clips.len() == 4);
    assert!(audio.len() == 2 && audio[0].clips.len() == 1 && audio[1].clips.len() == 1);
    let c = &video[0].clips;
    assert!(c[0].start == Time::ZERO && c[0].duration == t(5, 1) && c[0].source_in == t(10, 1));
    assert_eq!(c[0].media_key, "/Volumes/Shoot/A001.mov");
    assert!(c[1].start == t(5, 1) && c[1].media_key == "B002.mov");
    assert!(c[2].name == "C003.mov" && c[2].start == t(7, 1) && c[2].duration == t(3, 1));
    assert!(c[3].speed == ClipSpeed::new(1, 2) && c[3].start == t(12, 1));
    let mut tr = IXTransition::new(t(1, 1), Some(1), Some(2));
    tr.alignment = TransitionAlignment::StartAtCut;
    assert_eq!(video[0].transitions, vec![tr]);
    assert_eq!(s.markers, vec![IXMarker::new(t(1, 1), "first")]);
}

#[test]
fn edl_drop_frame_and_reverse() {
    let text = "FCM: DROP FRAME
001  AX  V  C  00:01:00;02 00:01:01;02 00:00:00;00 00:00:01;00
002  AX  V  C  00:00:10;00 00:00:08;00 00:00:01;00 00:00:02;00
M2   AX  -060.0  00:00:10;00
";
    let fd = t(1001, 30_000);
    let s = EDLReader::read(text, "d", fd).unwrap();
    let c = &s.tracks[0].clips;
    assert_eq!(c[0].source_in, fd * 1800); // 00:01:00;02 is frame 1800
    assert_eq!(c[0].duration, fd * 30);
    assert!(c[1].reversed && c[1].speed == ClipSpeed::new(2002, 1000)); // 60 fps on a 29.97 clock
    assert_eq!(c[1].start, fd * 30);
}

const XMEML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE xmeml>
<xmeml version="4"><sequence id="s1"><name>Seq A</name><duration>250</duration>
<rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate>
<media><video><format><samplecharacteristics><width>1280</width><height>720</height></samplecharacteristics></format>
<track>
<clipitem id="c1"><name>Shot 1</name><duration>500</duration><rate><timebase>25</timebase></rate>
  <start>0</start><end>-1</end><in>50</in><out>150</out>
  <file id="f1"><name>shot 1.mov</name><pathurl>file://localhost/Volumes/Media/shot%201.mov</pathurl>
    <rate><timebase>25</timebase></rate><duration>500</duration></file></clipitem>
<transitionitem><start>90</start><end>110</end><alignment>center</alignment><effect><name>Cross Dissolve</name></effect></transitionitem>
<clipitem id="c2"><name>Shot 2</name><rate><timebase>25</timebase></rate><start>-1</start><end>200</end><in>0</in><out>100</out>
  <file id="f2"><name>shot2.mov</name><pathurl>file:///C:/Footage/shot2.mov</pathurl></file></clipitem>
<clipitem id="c3"><name>Fast</name><rate><timebase>25</timebase></rate><start>200</start><end>225</end><in>0</in><out>50</out>
  <file id="f1"/>
  <filter><effect><effectid>timeremap</effectid>
    <parameter><parameterid>speed</parameterid><value>200</value></parameter>
    <parameter><parameterid>reverse</parameterid><value>FALSE</value></parameter></effect></filter></clipitem>
<generatoritem><name>Bars</name></generatoritem>
</track></video>
<audio><track>
<clipitem id="a1"><name>Shot 1</name><start>0</start><end>100</end><in>50</in><out>150</out><file id="f1"/></clipitem>
</track></audio></media>
<marker><name>Beat</name><comment>drum</comment><in>25</in><out>-1</out></marker>
</sequence></xmeml>"#;

#[test]
fn xmeml_clips_transitions_speed_markers() {
    let s = XMEMLReader::read(XMEML.as_bytes(), "x").unwrap();
    assert!(s.name == "Seq A" && s.width == 1280 && s.height == 720 && s.frame_duration == t(1, 25));
    let v = &s.tracks[0];
    assert_eq!(v.clips.len(), 3);
    assert_eq!(v.clips[0].media_key, "/Volumes/Media/shot 1.mov");
    assert!(v.clips[0].source_in == t(2, 1) && v.clips[0].duration == t(4, 1)); // end -1: the cut at 100
    assert!(v.clips[1].start == t(4, 1) && v.clips[1].media_key == "C:\\Footage\\shot2.mov");
    assert_eq!(v.clips[2].speed, ClipSpeed::new(2, 1));
    assert_eq!(v.clips[2].media_key, "/Volumes/Media/shot 1.mov"); // file id reference
    assert_eq!(v.transitions, vec![IXTransition::new(t(20, 25), Some(0), Some(1))]);
    assert!(s.tracks[1].kind == TrackKind::Audio && s.tracks[1].clips.len() == 1);
    let mut beat = IXMarker::new(t(1, 1), "Beat");
    beat.comment = "drum".into();
    assert_eq!(s.markers, vec![beat]);
    assert_eq!(s.report.status_of("Generator"), Some(Status::Dropped));
}

const FCPXML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<fcpxml version="1.9"><resources>
<format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
<asset id="r2" name="Wide" start="0s" duration="600600/30000s" hasVideo="1" hasAudio="1" format="r1">
  <media-rep kind="original-media" src="file:///Users/me/Wide%20Shot.mov"/></asset>
<asset id="r3" name="Music" start="0s" duration="30s" hasVideo="0" hasAudio="1" src="file:///Users/me/music.wav"/>
</resources><library><event name="E"><project name="My Cut">
<sequence format="r1" duration="210210/30000s" tcStart="0s" tcFormat="NDF"><spine>
  <asset-clip ref="r2" offset="0s" name="Wide" start="30030/30000s" duration="150150/30000s">
    <marker start="45045/30000s" duration="1001/30000s" value="Hit"/>
    <asset-clip ref="r3" lane="-1" offset="30030/30000s" name="Music" duration="60060/30000s"/>
  </asset-clip>
  <transition name="Cross Dissolve" offset="120120/30000s" duration="30030/30000s"/>
  <asset-clip ref="r2" offset="150150/30000s" name="Fast" start="0s" duration="60060/30000s">
    <timeMap><timept time="0s" value="0s"/><timept time="60060/30000s" value="120120/30000s"/></timeMap>
  </asset-clip>
  <title ref="r9" offset="210210/30000s" duration="1s"/>
</spine></sequence></project></event></library></fcpxml>"#;

#[test]
fn fcpxml_spine_connected_speed_and_markers() {
    let s = FCPXMLReader::read(FCPXML.as_bytes(), "x").unwrap();
    let fd = t(1001, 30_000);
    assert!(s.name == "My Cut" && s.frame_duration == fd && s.width == 1920);
    let video: Vec<_> = s.tracks.iter().filter(|t| t.kind == TrackKind::Video).collect();
    let audio: Vec<_> = s.tracks.iter().filter(|t| t.kind == TrackKind::Audio).collect();
    assert!(video.len() == 1 && video[0].clips.len() == 2);
    assert_eq!(video[0].clips[0].media_key, "/Users/me/Wide Shot.mov");
    assert!(video[0].clips[0].source_in == fd * 30 && video[0].clips[0].duration == fd * 150);
    assert!(video[0].clips[1].start == fd * 150 && video[0].clips[1].speed == ClipSpeed::new(2, 1));
    assert!(video[0].transitions.len() == 1 && video[0].transitions[0].duration == fd * 30);
    assert!(audio.len() == 2 && audio[0].clips.len() == 2 && audio[1].clips.len() == 1);
    // offset = parent's start: the parent's first frame
    assert!(audio[1].clips[0].media_key == "/Users/me/music.wav" && audio[1].clips[0].start == Time::ZERO);
    assert!(s.markers.len() == 1 && s.markers[0].time == fd * 15 && s.markers[0].name == "Hit");
    assert_eq!(s.report.status_of("Title"), Some(Status::Dropped));
}

#[test]
fn fcpxml_video_element_has_no_sound_and_transition_children_are_ignored() {
    let text = r#"<fcpxml version="1.8"><resources><format id="r1" frameDuration="1/25s" width="1280" height="720"/>
<asset id="r2" name="A" start="0s" duration="10s" hasVideo="1" hasAudio="1" format="r1" src="file:///v/a.mov"/>
<effect id="r3" name="Cross Dissolve" uid="FxPlug:x"/></resources>
<library><event name="E"><project name="P"><sequence format="r1" duration="4s" tcStart="3600s" tcFormat="NDF"><spine>
<video ref="r2" offset="3600s" name="A" start="0s" duration="2s"/>
<transition name="Cross Dissolve" offset="3601s" duration="1s"><filter-video ref="r3" name="Cross Dissolve"/></transition>
<video ref="r2" offset="3602s" name="A" start="5s" duration="2s"/>
</spine></sequence></project></event></library></fcpxml>"#;
    let s = FCPXMLReader::read(text.as_bytes(), "x").unwrap();
    assert!(s.tracks.iter().all(|t| t.kind != TrackKind::Audio));
    let v = &s.tracks[0];
    assert!(v.clips.len() == 2 && v.clips[0].start == Time::ZERO && v.clips[1].start == t(2, 1));
    assert_eq!(v.clips[1].source_in, t(5, 1));
    assert!(v.transitions.len() == 1 && v.transitions[0].duration == t(1, 1));
}

#[test]
fn mapper_builds_offline_project_with_links_and_transitions() {
    let s =
        InterchangeReader::read(FCPXML.as_bytes(), "fcpxml", "n", InterchangeReader::default_frame_duration()).unwrap();
    let r = InterchangeMapper::map(
        std::slice::from_ref(&s),
        Some("Imported"),
        &Default::default(),
        &mut SequentialIds::default(),
    );
    let tl = r.project.timelines.first().unwrap();
    assert!(r.project.name == "Imported" && r.project.active_timeline == Some(tl.id));
    assert_eq!(
        tl.tracks.iter().map(|t| t.kind).collect::<Vec<_>>(),
        vec![TrackKind::Video, TrackKind::Audio, TrackKind::Audio]
    );
    let (v, a) = (&tl.tracks[0], &tl.tracks[1]);
    assert!(v.clips().len() == 2 && v.transitions.len() == 1);
    assert!(v.transitions[0].outgoing == Some(v.clips()[0].id) && v.transitions[0].incoming == Some(v.clips()[1].id));
    assert!(v.clips()[0].link.is_some() && v.clips()[0].link == a.clips()[0].link);
    let c1 = &v.clips()[1];
    assert!(c1.speed == ClipSpeed::new(2, 1) && c1.source.duration == c1.speed.scale(c1.duration()));
    assert_eq!(r.project.media.len(), 2);
    assert_eq!(r.report.status_of("Offline media"), Some(Status::Approximated));
    assert_eq!(tl.markers.len(), 1);
    assert_eq!(InterchangeMapper::media_paths(&[s]), vec!["/Users/me/Wide Shot.mov", "/Users/me/music.wav"]);
}

#[test]
fn detects_formats_and_rejects_others() {
    assert_eq!(InterchangeFormat::detect(EDL.as_bytes(), "txt"), Some(InterchangeFormat::Edl));
    assert_eq!(InterchangeFormat::detect(XMEML.as_bytes(), "xml"), Some(InterchangeFormat::FinalCutXML));
    assert_eq!(InterchangeFormat::detect(FCPXML.as_bytes(), "xml"), Some(InterchangeFormat::Fcpxml));
    let fd = InterchangeReader::default_frame_duration();
    assert!(matches!(InterchangeReader::read(b"hello", "bin", "x", fd), Err(InterchangeError::Unsupported(_))));
    assert!(InterchangeReader::read(b"<xmeml><sequence><name>e</name></sequence></xmeml>", "xml", "x", fd).is_err());
}

fn fcpxml_project(project: &str, clips: &str) -> String {
    format!(
        r#"<project name="{project}"><sequence format="r1" duration="10s" tcStart="0s" tcFormat="NDF"><spine>{clips}</spine></sequence></project>"#
    )
}

fn fcpxml_file(projects: &str) -> String {
    format!(
        r#"<fcpxml version="1.9"><resources><format id="r1" frameDuration="1/25s" width="1280" height="720"/>
<asset id="r2" name="A" start="0s" duration="20s" hasVideo="1" hasAudio="1" format="r1" src="file:///v/a.mov"/>
<media id="r8" name="Compound"><sequence format="r1" duration="1s"><spine>
  <asset-clip ref="r2" offset="0s" duration="1s"/></spine></sequence></media>
</resources><library><event name="E">{projects}</event></library></fcpxml>"#
    )
}

#[test]
fn fcpxml_audio_channel_source_maps_one_channel() {
    let data = fcpxml_file(&fcpxml_project(
        "P",
        r#"<asset-clip ref="r2" offset="0s" name="Ch2" start="0s" duration="2s">
  <audio-channel-source srcCh="2" outCh="L, R" role="dialogue"/></asset-clip>
<asset-clip ref="r2" offset="2s" name="Both" start="0s" duration="2s">
  <audio-channel-source srcCh="1, 2" outCh="L, R"/></asset-clip>
<asset-clip ref="r2" offset="4s" name="Muted" start="0s" duration="2s">
  <audio-channel-source srcCh="1" outCh="L" active="0"/><audio-channel-source srcCh="2" outCh="R"/></asset-clip>"#,
    ));
    let s = FCPXMLReader::read(data.as_bytes(), "x").unwrap();
    let audio = s.tracks.iter().find(|t| t.kind == TrackKind::Audio).unwrap();
    assert_eq!(audio.clips.iter().map(|c| c.source_channel).collect::<Vec<_>>(), vec![Some(1), None, Some(1)]);
}

#[test]
fn fcpxml_every_project_imports_and_compound_resources_are_not_sequences() {
    let data = fcpxml_file(
        &(fcpxml_project("First", r#"<asset-clip ref="r2" offset="0s" name="A" start="0s" duration="2s"/>"#)
            + &fcpxml_project("Second", r#"<asset-clip ref="r2" offset="0s" name="B" start="5s" duration="3s"/>"#)),
    );
    let fd = InterchangeReader::default_frame_duration();
    let all = InterchangeReader::read_all(data.as_bytes(), "fcpxml", "x", fd).unwrap();
    assert_eq!(all.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), vec!["First", "Second"]);
    // read(...) stays the first project, not the compound clip in the resources.
    assert_eq!(InterchangeReader::read(data.as_bytes(), "fcpxml", "x", fd).unwrap().name, "First");
    let r = InterchangeMapper::map(&all, Some("Both"), &Default::default(), &mut SequentialIds::default());
    assert_eq!(r.project.timelines.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), vec!["First", "Second"]);
    assert_eq!(r.project.active_timeline, Some(r.project.timelines[0].id));
    assert_eq!(r.project.media.len(), 1); // one file, one media item for both sequences
    assert_eq!(r.project.timelines[1].tracks[0].clips()[0].source.start, t(5, 1));
}

#[test]
fn otio_collection_imports_every_timeline_and_bare_stack() {
    let clip = |n: &str, start: i64| {
        format!(
            r#"{{"OTIO_SCHEMA":"Clip.2","name":"{n}","source_range":{{"OTIO_SCHEMA":"TimeRange.1",
 "start_time":{{"OTIO_SCHEMA":"RationalTime.1","rate":25,"value":{start}}},
 "duration":{{"OTIO_SCHEMA":"RationalTime.1","rate":25,"value":50}}}},
 "media_reference":{{"OTIO_SCHEMA":"ExternalReference.1","target_url":"file:///v/a.mov"}}}}"#
        )
    };
    let track = |c: &str| format!(r#"{{"OTIO_SCHEMA":"Track.1","kind":"Video","children":[{c}]}}"#);
    let timeline = |n: &str, c: &str| {
        format!(
            r#"{{"OTIO_SCHEMA":"Timeline.1","name":"{n}","tracks":{{"OTIO_SCHEMA":"Stack.1","children":[{}]}}}}"#,
            track(c)
        )
    };
    let text = format!(
        r#"{{"OTIO_SCHEMA":"SerializableCollection.1","name":"all","children":[
  {},
  {{"OTIO_SCHEMA":"SerializableCollection.1","children":[{}]}},
  {{"OTIO_SCHEMA":"Stack.1","name":"Bare","children":[{}]}}
]}}"#,
        timeline("One", &clip("A", 0)),
        timeline("Two", &clip("B", 10)),
        track(&clip("C", 20))
    );
    let fd = InterchangeReader::default_frame_duration();
    let all = InterchangeReader::read_all(text.as_bytes(), "otio", "x", fd).unwrap();
    assert_eq!(all.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), vec!["One", "Two", "Bare"]);
    assert_eq!(all[1].tracks[0].clips[0].source_in, t(10, 25));
    assert_eq!(InterchangeReader::read(text.as_bytes(), "otio", "x", fd).unwrap().name, "One");
    let r = InterchangeMapper::map(&all, Some("Both"), &Default::default(), &mut SequentialIds::default());
    assert!(r.project.timelines.len() == 3 && r.project.media.len() == 1);
}

#[test]
fn xmeml_every_sequence_imports_but_nested_ones_do_not() {
    let text = r#"<xmeml version="4"><project><children>
<sequence id="s1"><name>One</name><rate><timebase>25</timebase></rate><media><video><track>
  <clipitem id="c1"><name>N</name><start>0</start><end>50</end><in>0</in><out>50</out>
    <sequence id="s3"><name>Inner</name></sequence></clipitem>
  <clipitem id="c2"><name>S</name><start>50</start><end>100</end><in>0</in><out>50</out><file id="f1"><name>a.mov</name><pathurl>file:///v/a.mov</pathurl></file></clipitem>
</track></video></media></sequence>
<sequence id="s2"><name>Two</name><rate><timebase>25</timebase></rate><media><video><track>
  <clipitem id="c4"><name>S</name><start>0</start><end>25</end><in>0</in><out>25</out><file id="f1"/></clipitem>
</track></video></media></sequence>
</children></project></xmeml>"#;
    let all =
        InterchangeReader::read_all(text.as_bytes(), "xml", "x", InterchangeReader::default_frame_duration()).unwrap();
    assert_eq!(all.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), vec!["One", "Two"]);
    assert_eq!(all[1].tracks[0].clips.len(), 1);
}

#[test]
fn fcpxml_speed_ramp_becomes_retime_keys() {
    let fd = t(1, 25);
    let data = fcpxml_file(&fcpxml_project(
        "Ramp",
        r#"<asset-clip ref="r2" offset="0s" name="Ramp" start="0s" duration="60/25s">
  <timeMap><timept time="0s" value="0s" interp="linear"/><timept time="30/25s" value="60/25s" interp="linear"/>
  <timept time="60/25s" value="90/25s" interp="linear"/></timeMap></asset-clip>"#,
    ));
    let s = FCPXMLReader::read(data.as_bytes(), "x").unwrap();
    let c = s.tracks[0].clips.first().unwrap();
    let keys = c.speed_keys.clone().unwrap();
    assert_eq!(keys.segments.iter().map(|s| s.from).collect::<Vec<_>>(), vec![ClipSpeed::new(2, 1), ClipSpeed::NORMAL]);
    assert_eq!(keys.segments.iter().map(|s| s.duration).collect::<Vec<_>>(), vec![fd * 30, fd * 30]);
    assert_eq!(keys.origin, Time::ZERO);
    assert_eq!(c.duration, fd * 60);
    assert_eq!(s.report.status_of("Speed"), Some(Status::Mapped));
    let r = InterchangeMapper::map(&[s], None, &Default::default(), &mut SequentialIds::default());
    let clip = r.project.timelines[0].tracks[0].clips().first().unwrap();
    assert!(clip.speed_keys.as_ref() == Some(&keys) && clip.duration() == fd * 60 && clip.source == keys.hull());
    assert_eq!(clip.source.duration, fd * 90);
}

#[test]
fn fcpxml_two_point_map_stays_constant_and_freeze_falls_back_to_average() {
    let data = fcpxml_file(&fcpxml_project(
        "P",
        r#"<asset-clip ref="r2" offset="0s" name="Hold" start="0s" duration="60/25s">
  <timeMap><timept time="0s" value="0s"/><timept time="30/25s" value="30/25s"/>
  <timept time="60/25s" value="30/25s"/></timeMap></asset-clip>"#,
    ));
    let s = FCPXMLReader::read(data.as_bytes(), "x").unwrap();
    let c = s.tracks[0].clips.first().unwrap();
    assert!(c.speed_keys.is_none());
    assert_eq!(c.speed, ClipSpeed::new(1, 2));
}

fn otio_clip_with(effect: &str) -> String {
    format!(
        r#"{{"OTIO_SCHEMA":"Timeline.1","name":"T","tracks":{{"OTIO_SCHEMA":"Stack.1","children":[
 {{"OTIO_SCHEMA":"Track.1","kind":"Video","children":[
  {{"OTIO_SCHEMA":"Clip.2","name":"C","effects":[{effect}],
   "source_range":{{"OTIO_SCHEMA":"TimeRange.1","start_time":{{"OTIO_SCHEMA":"RationalTime.1","rate":25,"value":10}},
    "duration":{{"OTIO_SCHEMA":"RationalTime.1","rate":25,"value":50}}}},
   "media_reference":{{"OTIO_SCHEMA":"ExternalReference.1","target_url":"file:///v/a.mov"}}}}]}}]}}}}"#
    )
}

#[test]
fn otio_freeze_frame_holds_the_first_source_frame() {
    let text = otio_clip_with(r#"{"OTIO_SCHEMA":"FreezeFrame.1","name":"Freeze"}"#);
    let fd = InterchangeReader::default_frame_duration();
    let s = InterchangeReader::read(text.as_bytes(), "otio", "x", fd).unwrap();
    let c = &s.tracks[0].clips[0];
    assert_eq!(c.hold_frame, Some(t(10, 25)));
    assert_eq!(s.report.status_of("Speed"), Some(Status::Mapped));
    let r = InterchangeMapper::map(&[s], None, &Default::default(), &mut SequentialIds::default());
    assert_eq!(r.project.timelines[0].tracks[0].clips()[0].hold_frame, Some(t(10, 25)));
}

#[test]
fn otio_time_warp_maps_forward_and_reverse_speed() {
    let fd = InterchangeReader::default_frame_duration();
    let read = |scalar: &str| {
        let text = otio_clip_with(&format!(r#"{{"OTIO_SCHEMA":"LinearTimeWarp.1","time_scalar":{scalar}}}"#));
        InterchangeReader::read(text.as_bytes(), "otio", "x", fd).unwrap()
    };
    let fast = read("2.0");
    let c = &fast.tracks[0].clips[0];
    assert!(c.speed == ClipSpeed::new(2, 1) && !c.reversed && c.hold_frame.is_none());
    let back = read("-1.0");
    let c = &back.tracks[0].clips[0];
    assert!(c.speed.is_normal() && c.reversed);
    assert_eq!(back.report.status_of("Speed"), Some(Status::Mapped));
}

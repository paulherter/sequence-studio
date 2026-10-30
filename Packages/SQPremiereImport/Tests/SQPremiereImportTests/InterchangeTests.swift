import Foundation
import Testing
import SQCore
@testable import SQPremiereImport

/// EDL, Final Cut Pro 7 XML and FCPXML readers + the mapper into the SQCore model (inline fixtures, no footage).
@Suite struct InterchangeTests {
    static let edl = """
    TITLE: Cut One
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
    """

    @Test func edlEventsTracksSpeedAndTransition() throws {
        let s = try EDLReader.read(Self.edl, name: "x", frameDuration: Time(1, 25))
        #expect(s.name == "Cut One")
        let video = s.tracks.filter { $0.kind == .video }, audio = s.tracks.filter { $0.kind == .audio }
        #expect(video.count == 1 && video[0].clips.count == 4)
        #expect(audio.count == 2 && audio[0].clips.count == 1 && audio[1].clips.count == 1)
        let c = video[0].clips
        #expect(c[0].start == .zero && c[0].duration == Time(5, 1) && c[0].sourceIn == Time(10, 1))
        #expect(c[0].mediaKey == "/Volumes/Shoot/A001.mov")
        #expect(c[1].start == Time(5, 1) && c[1].mediaKey == "B002.mov")
        #expect(c[2].name == "C003.mov" && c[2].start == Time(7, 1) && c[2].duration == Time(3, 1))
        #expect(c[3].speed == ClipSpeed(num: 1, den: 2) && c[3].start == Time(12, 1))
        #expect(video[0].transitions == [IXTransition(duration: Time(1, 1), alignment: .startAtCut, outgoing: 1, incoming: 2)])
        #expect(s.markers == [IXMarker(time: Time(1, 1), name: "first")])
    }

    @Test func edlDropFrameAndReverse() throws {
        let text = """
        FCM: DROP FRAME
        001  AX  V  C  00:01:00;02 00:01:01;02 00:00:00;00 00:00:01;00
        002  AX  V  C  00:00:10;00 00:00:08;00 00:00:01;00 00:00:02;00
        M2   AX  -060.0  00:00:10;00
        """
        let fd = Time(1001, 30_000)
        let s = try EDLReader.read(text, name: "d", frameDuration: fd)
        let c = s.tracks[0].clips
        #expect(c[0].sourceIn == fd * 1800)          // 00:01:00;02 is frame 1800
        #expect(c[0].duration == fd * 30)
        #expect(c[1].reversed && c[1].speed == ClipSpeed(num: 2002, den: 1000))   // 60 fps on a 29.97 clock
        #expect(c[1].start == fd * 30)
    }

    static let xmeml = """
    <?xml version="1.0" encoding="UTF-8"?>
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
    </sequence></xmeml>
    """

    @Test func xmemlClipsTransitionsSpeedMarkers() throws {
        let s = try XMEMLReader.read(Data(Self.xmeml.utf8), name: "x")
        #expect(s.name == "Seq A" && s.width == 1280 && s.height == 720 && s.frameDuration == Time(1, 25))
        let v = s.tracks[0]
        #expect(v.clips.count == 3)
        #expect(v.clips[0].mediaKey == "/Volumes/Media/shot 1.mov")
        #expect(v.clips[0].sourceIn == Time(2, 1) && v.clips[0].duration == Time(4, 1))   // end -1: the cut at 100
        #expect(v.clips[1].start == Time(4, 1) && v.clips[1].mediaKey == "C:\\Footage\\shot2.mov")
        #expect(v.clips[2].speed == ClipSpeed(num: 2, den: 1))
        #expect(v.clips[2].mediaKey == "/Volumes/Media/shot 1.mov")   // file id reference
        #expect(v.transitions == [IXTransition(duration: Time(20, 25), alignment: .center, outgoing: 0, incoming: 1)])
        #expect(s.tracks[1].kind == .audio && s.tracks[1].clips.count == 1)
        #expect(s.markers == [IXMarker(time: Time(1, 1), name: "Beat", comment: "drum")])
        #expect(s.report.status(of: "Generator") == .dropped)
    }

    static let fcpxml = """
    <?xml version="1.0" encoding="UTF-8"?>
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
    </spine></sequence></project></event></library></fcpxml>
    """

    @Test func fcpxmlSpineConnectedSpeedAndMarkers() throws {
        let s = try FCPXMLReader.read(Data(Self.fcpxml.utf8), name: "x")
        let fd = Time(1001, 30_000)
        #expect(s.name == "My Cut" && s.frameDuration == fd && s.width == 1920)
        let video = s.tracks.filter { $0.kind == .video }, audio = s.tracks.filter { $0.kind == .audio }
        #expect(video.count == 1 && video[0].clips.count == 2)
        #expect(video[0].clips[0].mediaKey == "/Users/me/Wide Shot.mov")
        #expect(video[0].clips[0].sourceIn == fd * 30 && video[0].clips[0].duration == fd * 150)
        #expect(video[0].clips[1].start == fd * 150 && video[0].clips[1].speed == ClipSpeed(num: 2, den: 1))
        #expect(video[0].transitions.count == 1 && video[0].transitions[0].duration == fd * 30)
        #expect(audio.count == 2 && audio[0].clips.count == 2 && audio[1].clips.count == 1)
        #expect(audio[1].clips[0].mediaKey == "/Users/me/music.wav" && audio[1].clips[0].start == .zero)   // offset = parent's start: the parent's first frame
        #expect(s.markers.count == 1 && s.markers[0].time == fd * 15 && s.markers[0].name == "Hit")
        #expect(s.report.status(of: "Title") == .dropped)
    }

    @Test func fcpxmlVideoElementHasNoSoundAndTransitionChildrenAreIgnored() throws {
        let text = """
        <fcpxml version="1.8"><resources><format id="r1" frameDuration="1/25s" width="1280" height="720"/>
        <asset id="r2" name="A" start="0s" duration="10s" hasVideo="1" hasAudio="1" format="r1" src="file:///v/a.mov"/>
        <effect id="r3" name="Cross Dissolve" uid="FxPlug:x"/></resources>
        <library><event name="E"><project name="P"><sequence format="r1" duration="4s" tcStart="3600s" tcFormat="NDF"><spine>
        <video ref="r2" offset="3600s" name="A" start="0s" duration="2s"/>
        <transition name="Cross Dissolve" offset="3601s" duration="1s"><filter-video ref="r3" name="Cross Dissolve"/></transition>
        <video ref="r2" offset="3602s" name="A" start="5s" duration="2s"/>
        </spine></sequence></project></event></library></fcpxml>
        """
        let s = try FCPXMLReader.read(Data(text.utf8), name: "x")
        #expect(s.tracks.filter { $0.kind == .audio }.isEmpty)
        let v = s.tracks[0]
        #expect(v.clips.count == 2 && v.clips[0].start == .zero && v.clips[1].start == Time(2, 1))
        #expect(v.clips[1].sourceIn == Time(5, 1))
        #expect(v.transitions.count == 1 && v.transitions[0].duration == Time(1, 1))
    }

    @Test func mapperBuildsOfflineProjectWithLinksAndTransitions() throws {
        let s = try InterchangeReader.read(data: Data(Self.fcpxml.utf8), fileExtension: "fcpxml", name: "n")
        let r = InterchangeMapper.map(s, name: "Imported")
        let tl = try #require(r.project.timelines.first)
        #expect(r.project.name == "Imported" && r.project.activeTimeline == tl.id)
        #expect(tl.tracks.map(\.kind) == [.video, .audio, .audio])
        let v = tl.tracks[0], a = tl.tracks[1]
        #expect(v.clips.count == 2 && v.transitions.count == 1)
        #expect(v.transitions[0].outgoing == v.clips[0].id && v.transitions[0].incoming == v.clips[1].id)
        #expect(v.clips[0].link != nil && v.clips[0].link == a.clips[0].link)
        #expect(v.clips[1].speed == ClipSpeed(num: 2, den: 1) && v.clips[1].source.duration == v.clips[1].speed.scale(v.clips[1].duration))
        #expect(r.project.media.count == 2)
        #expect(r.report.status(of: "Offline media") == .approximated)
        #expect(tl.markers.count == 1)
        #expect(InterchangeMapper.mediaPaths(s) == ["/Users/me/Wide Shot.mov", "/Users/me/music.wav"])
    }

    @Test func detectsFormatsAndRejectsOthers() throws {
        #expect(InterchangeFormat.detect(data: Data(Self.edl.utf8), fileExtension: "txt") == .edl)
        #expect(InterchangeFormat.detect(data: Data(Self.xmeml.utf8), fileExtension: "xml") == .finalCutXML)
        #expect(InterchangeFormat.detect(data: Data(Self.fcpxml.utf8), fileExtension: "xml") == .fcpxml)
        #expect(throws: InterchangeError.self) {
            try InterchangeReader.read(data: Data("hello".utf8), fileExtension: "bin", name: "x")
        }
        #expect(throws: InterchangeError.self) {
            try InterchangeReader.read(data: Data("<xmeml><sequence><name>e</name></sequence></xmeml>".utf8), fileExtension: "xml", name: "x")
        }
    }

    @Test func pathsFromFileURLs() {
        #expect(InterchangePath.path(fromURL: "file://localhost/Volumes/A%20B/c.mov") == "/Volumes/A B/c.mov")
        #expect(InterchangePath.path(fromURL: "file:///Users/x/c.mov") == "/Users/x/c.mov")
        #expect(InterchangePath.path(fromURL: "file://localhost/C%3a/Footage/c.mov") == "C:\\Footage\\c.mov")
    }

    // MARK: Interchange rest: channel source, several sequences, retime keys

    static func fcpxmlProject(_ project: String, clips: String) -> String {
        """
        <project name="\(project)"><sequence format="r1" duration="10s" tcStart="0s" tcFormat="NDF"><spine>\(clips)</spine></sequence></project>
        """
    }

    static func fcpxmlFile(_ projects: String) -> Data {
        Data("""
        <fcpxml version="1.9"><resources><format id="r1" frameDuration="1/25s" width="1280" height="720"/>
        <asset id="r2" name="A" start="0s" duration="20s" hasVideo="1" hasAudio="1" format="r1" src="file:///v/a.mov"/>
        <media id="r8" name="Compound"><sequence format="r1" duration="1s"><spine>
          <asset-clip ref="r2" offset="0s" duration="1s"/></spine></sequence></media>
        </resources><library><event name="E">\(projects)</event></library></fcpxml>
        """.utf8)
    }

    @Test func fcpxmlAudioChannelSourceMapsOneChannel() throws {
        let data = Self.fcpxmlFile(Self.fcpxmlProject("P", clips: """
        <asset-clip ref="r2" offset="0s" name="Ch2" start="0s" duration="2s">
          <audio-channel-source srcCh="2" outCh="L, R" role="dialogue"/></asset-clip>
        <asset-clip ref="r2" offset="2s" name="Both" start="0s" duration="2s">
          <audio-channel-source srcCh="1, 2" outCh="L, R"/></asset-clip>
        <asset-clip ref="r2" offset="4s" name="Muted" start="0s" duration="2s">
          <audio-channel-source srcCh="1" outCh="L" active="0"/><audio-channel-source srcCh="2" outCh="R"/></asset-clip>
        """))
        let s = try FCPXMLReader.read(data, name: "x")
        let audio = try #require(s.tracks.first { $0.kind == .audio })
        #expect(audio.clips.map(\.sourceChannel) == [1, nil, 1])
    }

    @Test func fcpxmlEveryProjectImportsAndCompoundResourcesAreNotSequences() throws {
        let data = Self.fcpxmlFile(
            Self.fcpxmlProject("First", clips: #"<asset-clip ref="r2" offset="0s" name="A" start="0s" duration="2s"/>"#)
            + Self.fcpxmlProject("Second", clips: #"<asset-clip ref="r2" offset="0s" name="B" start="5s" duration="3s"/>"#))
        let all = try InterchangeReader.readAll(data: data, fileExtension: "fcpxml", name: "x")
        #expect(all.map(\.name) == ["First", "Second"])
        // read(...) stays the first project, not the compound clip in the resources.
        #expect(try InterchangeReader.read(data: data, fileExtension: "fcpxml", name: "x").name == "First")
        let r = InterchangeMapper.map(all, name: "Both")
        #expect(r.project.timelines.map(\.name) == ["First", "Second"])
        #expect(r.project.activeTimeline == r.project.timelines[0].id)
        #expect(r.project.media.count == 1)   // one file, one media item for both sequences
        #expect(r.project.timelines[1].tracks[0].clips[0].source.start == Time(5, 1))
    }

    @Test func otioCollectionImportsEveryTimelineAndBareStack() throws {
        func clip(_ n: String, _ start: Int) -> String {
            """
            {"OTIO_SCHEMA":"Clip.2","name":"\(n)","source_range":{"OTIO_SCHEMA":"TimeRange.1",
             "start_time":{"OTIO_SCHEMA":"RationalTime.1","rate":25,"value":\(start)},
             "duration":{"OTIO_SCHEMA":"RationalTime.1","rate":25,"value":50}},
             "media_reference":{"OTIO_SCHEMA":"ExternalReference.1","target_url":"file:///v/a.mov"}}
            """
        }
        func track(_ c: String) -> String { #"{"OTIO_SCHEMA":"Track.1","kind":"Video","children":[\#(c)]}"# }
        func timeline(_ n: String, _ c: String) -> String {
            #"{"OTIO_SCHEMA":"Timeline.1","name":"\#(n)","tracks":{"OTIO_SCHEMA":"Stack.1","children":[\#(track(c))]}}"#
        }
        let text = """
        {"OTIO_SCHEMA":"SerializableCollection.1","name":"all","children":[
          \(timeline("One", clip("A", 0))),
          {"OTIO_SCHEMA":"SerializableCollection.1","children":[\(timeline("Two", clip("B", 10)))]},
          {"OTIO_SCHEMA":"Stack.1","name":"Bare","children":[\(track(clip("C", 20)))]}
        ]}
        """
        let all = try InterchangeReader.readAll(data: Data(text.utf8), fileExtension: "otio", name: "x")
        #expect(all.map(\.name) == ["One", "Two", "Bare"])
        #expect(all[1].tracks[0].clips[0].sourceIn == Time(10, 25))
        #expect(try InterchangeReader.read(data: Data(text.utf8), fileExtension: "otio", name: "x").name == "One")
        let r = InterchangeMapper.map(all, name: "Both")
        #expect(r.project.timelines.count == 3 && r.project.media.count == 1)
    }

    @Test func xmemlEverySequenceImportsButNestedOnesDoNot() throws {
        let text = """
        <xmeml version="4"><project><children>
        <sequence id="s1"><name>One</name><rate><timebase>25</timebase></rate><media><video><track>
          <clipitem id="c1"><name>N</name><start>0</start><end>50</end><in>0</in><out>50</out>
            <sequence id="s3"><name>Inner</name></sequence></clipitem>
          <clipitem id="c2"><name>S</name><start>50</start><end>100</end><in>0</in><out>50</out><file id="f1"><name>a.mov</name><pathurl>file:///v/a.mov</pathurl></file></clipitem>
        </track></video></media></sequence>
        <sequence id="s2"><name>Two</name><rate><timebase>25</timebase></rate><media><video><track>
          <clipitem id="c4"><name>S</name><start>0</start><end>25</end><in>0</in><out>25</out><file id="f1"/></clipitem>
        </track></video></media></sequence>
        </children></project></xmeml>
        """
        let all = try InterchangeReader.readAll(data: Data(text.utf8), fileExtension: "xml", name: "x")
        #expect(all.map(\.name) == ["One", "Two"])
        #expect(all[1].tracks[0].clips.count == 1)
    }

    @Test func fcpxmlSpeedRampBecomesRetimeKeys() throws {
        let fd = Time(1, 25)
        let data = Self.fcpxmlFile(Self.fcpxmlProject("Ramp", clips: """
        <asset-clip ref="r2" offset="0s" name="Ramp" start="0s" duration="60/25s">
          <timeMap><timept time="0s" value="0s" interp="linear"/><timept time="30/25s" value="60/25s" interp="linear"/>
          <timept time="60/25s" value="90/25s" interp="linear"/></timeMap></asset-clip>
        """))
        let s = try FCPXMLReader.read(data, name: "x")
        let c = try #require(s.tracks[0].clips.first)
        let keys = try #require(c.speedKeys)
        #expect(keys.segments.map(\.from) == [ClipSpeed(num: 2, den: 1), .normal])
        #expect(keys.segments.map(\.duration) == [fd * 30, fd * 30] && keys.origin == .zero)
        #expect(c.duration == fd * 60)
        #expect(s.report.status(of: "Speed") == .mapped)
        let r = InterchangeMapper.map(s)
        let clip = try #require(r.project.timelines[0].tracks[0].clips.first)
        #expect(clip.speedKeys == keys && clip.duration == fd * 60 && clip.source == keys.hull)
        #expect(clip.source.duration == fd * 90)
    }

    @Test func fcpxmlTwoPointMapStaysConstantAndFreezeFallsBackToAverage() throws {
        let data = Self.fcpxmlFile(Self.fcpxmlProject("P", clips: """
        <asset-clip ref="r2" offset="0s" name="Hold" start="0s" duration="60/25s">
          <timeMap><timept time="0s" value="0s"/><timept time="30/25s" value="30/25s"/>
          <timept time="60/25s" value="30/25s"/></timeMap></asset-clip>
        """))
        let c = try #require(FCPXMLReader.read(data, name: "x").tracks[0].clips.first)
        #expect(c.speedKeys == nil)
        #expect(c.speed == ClipSpeed(num: 1, den: 2))
    }
}


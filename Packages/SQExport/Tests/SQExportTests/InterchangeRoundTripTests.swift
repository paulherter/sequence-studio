import Testing
import Foundation
import SQCore
import SQPremiereImport
@testable import SQExport

/// Final Cut Pro 7 XML and OpenTimelineIO writers: text content, and write-then-read round trips through the
/// SQPremiereImport readers and mapper (synthetic timelines, no footage).
@Suite struct InterchangeRoundTripTests {
    let fd = Time(1, 25)
    let a = MediaRef(name: "A001.mov", path: "/Volumes/Shoot/A001.mov", fingerprint: MediaFingerprint(size: 1))
    let b = MediaRef(name: "B & C.mov", path: "/Volumes/Shoot/B & C.mov", fingerprint: MediaFingerprint(size: 1))

    private func clip(_ m: MediaRef, _ kind: TrackKind, src: Int64, dur: Int64, at: Int64, speed: ClipSpeed = .normal,
                      reversed: Bool = false, fd f: Time? = nil) -> Clip {
        let f = f ?? fd
        return Clip(name: m.name, media: m.id, kind: kind, source: TimeRange(start: f * src, duration: speed.scale(f * dur)),
                    start: f * at, speed: speed, reversed: reversed)
    }

    /// V1: A(0..5s) dissolve B(5..9s, 2x speed); A1: A under the first clip; one marker.
    private func sample() -> Timeline {
        let first = clip(a, .video, src: 50, dur: 125, at: 0)
        let second = clip(b, .video, src: 0, dur: 100, at: 125, speed: ClipSpeed(num: 2, den: 1))
        var v = Track(kind: .video, clips: [first, second])
        v.transitions = [Transition(kind: .crossDissolve, duration: fd * 10, alignment: .center,
                                    outgoing: first.id, incoming: second.id)]
        let au = Track(kind: .audio, clips: [clip(a, .audio, src: 50, dur: 125, at: 0)])
        var tl = Timeline(name: "Cut", format: SequenceFormat(width: 1280, height: 720, frameDuration: fd), tracks: [v, au])
        tl.markers = [Marker(time: fd * 25, name: "Beat", color: .red, comment: "drum", duration: fd * 5)]
        return tl
    }

    private func roundTrip(_ ext: String, _ out: InterchangeExport) throws -> Timeline {
        let seq = try InterchangeReader.read(data: Data(out.text.utf8), fileExtension: ext, name: "Cut")
        return try #require(InterchangeMapper.map(seq).project.timelines.first)
    }

    private func check(_ t: Timeline) throws {
        #expect(t.format.frameDuration == fd)
        let v = try #require(t.tracks.first { $0.kind == .video }), au = try #require(t.tracks.first { $0.kind == .audio })
        #expect(v.clips.count == 2 && au.clips.count == 1)
        #expect(v.clips[0].start == .zero && v.clips[0].duration == fd * 125 && v.clips[0].source.start == fd * 50)
        #expect(v.clips[1].start == fd * 125 && v.clips[1].duration == fd * 100)
        #expect(v.clips[1].speed == ClipSpeed(num: 2, den: 1) && !v.clips[1].reversed)
        #expect(v.clips[0].name == "A001.mov" && v.clips[1].name == "B & C.mov")
        #expect(au.clips[0].kind == .audio && au.clips[0].duration == fd * 125)
        #expect(v.clips[0].link != nil && v.clips[0].link == au.clips[0].link)
        #expect(v.transitions.count == 1 && v.transitions[0].duration == fd * 10 && v.transitions[0].alignment == .center)
        #expect(v.transitions[0].outgoing == v.clips[0].id && v.transitions[0].incoming == v.clips[1].id)
        #expect(t.markers.count == 1 && t.markers[0].time == fd * 25 && t.markers[0].name == "Beat")
        #expect(t.markers[0].comment == "drum" && t.markers[0].duration == fd * 5)
    }

    @Test func xmemlTextHasClipsFilesAndSpeed() {
        let out = XMEMLWriter.render(sample(), media: [a, b])
        let t = out.text
        #expect(t.contains("<xmeml version=\"4\">"))
        #expect(t.contains("<timebase>25</timebase><ntsc>FALSE</ntsc>"))
        #expect(t.contains("<start>0</start><end>125</end>"))
        #expect(t.contains("<in>50</in><out>175</out>"))
        #expect(t.contains("<pathurl>file:///Volumes/Shoot/B%20&amp;%20C.mov</pathurl>"))
        #expect(t.contains("<file id=\"file-1\"/>"))   // the audio clip refers to the file of the video clip
        #expect(t.contains("<value>200</value>"))
        #expect(t.contains("<alignment>center</alignment>"))
        #expect(out.warnings.isEmpty)
    }

    @Test func xmemlRoundTrip() throws {
        try check(roundTrip("xml", XMEMLWriter.render(sample(), media: [a, b])))
    }

    @Test func xmemlNtscReverseAndFades() throws {
        let ntsc = Time(1001, 30_000)
        let c1 = clip(a, .video, src: 100, dur: 60, at: 0, reversed: true, fd: ntsc)
        let c2 = clip(b, .video, src: 0, dur: 30, at: 60, speed: ClipSpeed(num: 1, den: 4), fd: ntsc)
        var v = Track(kind: .video, clips: [c1, c2])
        v.transitions = [Transition(kind: .dipToBlack, duration: ntsc * 12, alignment: .startAtCut, outgoing: nil, incoming: c1.id),
                         Transition(kind: .crossDissolve, duration: ntsc * 8, alignment: .endAtCut, outgoing: c1.id, incoming: c2.id)]
        let tl = Timeline(name: "N", format: SequenceFormat(width: 1920, height: 1080, frameDuration: ntsc), tracks: [v])
        let out = XMEMLWriter.render(tl, media: [a, b])
        #expect(out.text.contains("<timebase>30</timebase><ntsc>TRUE</ntsc>"))
        #expect(out.text.contains("<value>-100</value>"))
        #expect(out.text.contains("<value>25</value>"))
        let t = try roundTrip("xml", out)
        let tv = t.tracks[0]
        #expect(t.format.frameDuration == ntsc)
        #expect(tv.clips[0].reversed && tv.clips[0].speed.isNormal)
        #expect(tv.clips[1].speed == ClipSpeed(num: 1, den: 4))
        #expect(tv.transitions.count == 2)
        let fade = try #require(tv.transitions.first { $0.outgoing == nil })
        #expect(fade.kind == .dipToBlack && fade.incoming == tv.clips[0].id && fade.duration == ntsc * 12)
        let dis = try #require(tv.transitions.first { $0.outgoing != nil })
        #expect(dis.alignment == .endAtCut && dis.duration == ntsc * 8)
    }

    @Test func xmemlSkipsDisabledClips() {
        var off = clip(a, .video, src: 0, dur: 25, at: 0)
        off.isEnabled = false
        let ok = clip(b, .video, src: 0, dur: 25, at: 25)
        let tl = Timeline(name: "S", format: SequenceFormat(frameDuration: fd), tracks: [Track(kind: .video, clips: [off, ok])])
        let out = XMEMLWriter.render(tl, media: [a, b])
        #expect(out.warnings.contains { $0.contains("Disabled clip") })
        #expect(out.text.contains("clipitem-1") && !out.text.contains("clipitem-2"))
    }

    @Test func otioTextShape() throws {
        let out = OTIOWriter.render(sample(), media: [a, b])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any])
        #expect(json["OTIO_SCHEMA"] as? String == "Timeline.1")
        let stack = try #require(json["tracks"] as? [String: Any])
        let tracks = try #require(stack["children"] as? [[String: Any]])
        #expect(tracks.map { $0["kind"] as? String } == ["Video", "Audio"])
        let kinds = (tracks[0]["children"] as? [[String: Any]])?.compactMap { $0["OTIO_SCHEMA"] as? String }
        #expect(kinds == ["Clip.2", "Transition.1", "Clip.2"])
        #expect(out.text.contains("file:///Volumes/Shoot/A001.mov"))
        #expect(out.warnings.isEmpty)
    }

    @Test func otioSeveralSequencesWriteACollectionThatReadsBack() throws {
        var second = sample()
        second.name = "Second"
        let out = OTIOWriter.render([sample(), second], media: [a, b])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any])
        #expect(json["OTIO_SCHEMA"] as? String == "SerializableCollection.1")
        let all = try InterchangeReader.readAll(data: Data(out.text.utf8), fileExtension: "otio", name: "x")
        #expect(all.map(\.name) == ["Cut", "Second"])
        // One sequence stays a plain Timeline.
        let one = try JSONSerialization.jsonObject(with: Data(OTIOWriter.render([sample()], media: [a, b]).text.utf8)) as? [String: Any]
        #expect(one?["OTIO_SCHEMA"] as? String == "Timeline.1")
    }

    @Test func otioScopePicksActiveOrAllSequences() {
        var second = sample()
        second.name = "Second"
        let first = sample()
        let project = Project(name: "P", media: [a, b], timelines: [first, second], activeTimeline: second.id)
        #expect(OTIOWriter.Scope.activeSequence.timelines(in: project).map(\.name) == ["Second"])
        #expect(OTIOWriter.Scope.allSequences.timelines(in: project).map(\.name) == ["Cut", "Second"])
        let none = Project(name: "E")
        #expect(OTIOWriter.Scope.activeSequence.timelines(in: none).isEmpty)
        #expect(OTIOWriter.Scope.allSequences.timelines(in: none).isEmpty)
    }

    @Test func otioRoundTrip() throws {
        let t = try roundTrip("otio", OTIOWriter.render(sample(), media: [a, b]))
        try check(t)
        #expect(t.markers[0].color == .red)
    }

    @Test func otioRoundTripNtscGapsReverseAndHold() throws {
        let ntsc = Time(1001, 24_000)
        let c1 = clip(a, .video, src: 24, dur: 48, at: 24, reversed: true, fd: ntsc)
        var c2 = clip(b, .video, src: 10, dur: 24, at: 100, fd: ntsc)
        c2.holdFrame = ntsc * 10
        let tl = Timeline(name: "G", format: SequenceFormat(frameDuration: ntsc), tracks: [Track(kind: .video, clips: [c1, c2])])
        let t = try roundTrip("otio", OTIOWriter.render(tl, media: [a, b]))
        let v = t.tracks[0]
        #expect(t.format.frameDuration == ntsc)
        #expect(v.clips.count == 2)
        #expect(v.clips[0].start == ntsc * 24 && v.clips[0].duration == ntsc * 48 && v.clips[0].reversed)
        #expect(v.clips[0].source.start == ntsc * 24)
        #expect(v.clips[1].start == ntsc * 100 && v.clips[1].holdFrame == ntsc * 10)
    }

    @Test func otioReadsForeignFileWithWipeAndNestedStack() throws {
        let json = """
        {"OTIO_SCHEMA":"Timeline.1","name":"Foreign","tracks":{"OTIO_SCHEMA":"Stack.1","children":[
         {"OTIO_SCHEMA":"Track.1","kind":"Video","children":[
          {"OTIO_SCHEMA":"Clip.2","name":"one","media_reference":{"OTIO_SCHEMA":"MissingReference.1","name":"one.mov"},
           "source_range":{"OTIO_SCHEMA":"TimeRange.1","start_time":{"OTIO_SCHEMA":"RationalTime.1","value":0,"rate":24},
                           "duration":{"OTIO_SCHEMA":"RationalTime.1","value":48,"rate":24}},"effects":[],"markers":[]},
          {"OTIO_SCHEMA":"Transition.1","name":"Wipe","transition_type":"SMPTE_Wipe",
           "in_offset":{"OTIO_SCHEMA":"RationalTime.1","value":0,"rate":24},
           "out_offset":{"OTIO_SCHEMA":"RationalTime.1","value":12,"rate":24}},
          {"OTIO_SCHEMA":"Clip.2","name":"two","media_reference":{"OTIO_SCHEMA":"ExternalReference.1","target_url":"file:///a/two.mov"},
           "source_range":{"OTIO_SCHEMA":"TimeRange.1","start_time":{"OTIO_SCHEMA":"RationalTime.1","value":100,"rate":24},
                           "duration":{"OTIO_SCHEMA":"RationalTime.1","value":24,"rate":24}},"effects":[
             {"OTIO_SCHEMA":"LinearTimeWarp.1","time_scalar":2.0}],"markers":[]},
          {"OTIO_SCHEMA":"Stack.1","children":[]}
         ]}]}}
        """
        let seq = try InterchangeReader.read(data: Data(json.utf8), fileExtension: "otio", name: "x")
        #expect(seq.name == "Foreign" && seq.frameDuration == Time(1, 24))
        let t = seq.tracks[0]
        #expect(t.clips.count == 2 && t.clips[1].start == Time(48, 24) && t.clips[1].sourceIn == Time(100, 24))
        #expect(t.clips[1].mediaKey == "/a/two.mov" && t.clips[1].speed == ClipSpeed(num: 2, den: 1))
        #expect(t.transitions == [IXTransition(duration: Time(12, 24), alignment: .startAtCut, outgoing: 0, incoming: 1)])
        #expect(seq.report.status(of: "Nested sequence") == .dropped)
        #expect(seq.report.status(of: "Transition Wipe") == .approximated)
    }

    @Test func otioRejectsOtherJSON() {
        #expect(throws: InterchangeError.self) {
            try InterchangeReader.read(data: Data("{\"a\":1}".utf8), fileExtension: "otio", name: "x")
        }
    }
}

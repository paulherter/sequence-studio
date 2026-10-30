import Testing
import Foundation
import SQCore
import SQPremiereImport
@testable import SQExport

/// Interchange fidelity fixtures: markers, clip markers, split channels, audio dissolves, clip links, FCPXML 1.10+
/// value encoding, rational timecode origins and drop-frame partition edges, written then read back.
@Suite struct InterchangeFidelityTests {
    let fd = Time(1, 25)
    let a = MediaRef(name: "A001.mov", path: "/Volumes/Shoot/A001.mov", fingerprint: MediaFingerprint(size: 1))
    let b = MediaRef(name: "B002.mov", path: "/Volumes/Shoot/B002.mov", fingerprint: MediaFingerprint(size: 1))

    private func clip(_ m: MediaRef, _ kind: TrackKind, src: Int64, dur: Int64, at: Int64, fd f: Time? = nil) -> Clip {
        let f = f ?? fd
        return Clip(name: m.name, media: m.id, kind: kind, source: TimeRange(start: f * src, duration: f * dur), start: f * at)
    }

    private func read(_ ext: String, _ out: InterchangeExport, fd f: Time? = nil) throws -> Timeline {
        #expect(out.failure == nil)
        let seq = try InterchangeReader.read(data: Data(out.text.utf8), fileExtension: ext, name: "T", defaultFrameDuration: f ?? fd)
        return try #require(InterchangeMapper.map(seq).project.timelines.first)
    }

    private func render(_ ext: String, _ tl: Timeline, media: [MediaRef]) -> InterchangeExport {
        switch ext {
        case "edl": EDLWriter.render(tl, media: media)
        case "xml": XMEMLWriter.render(tl, media: media)
        case "fcpxml": FCPXMLWriter.render(tl, media: media)
        default: OTIOWriter.render(tl, media: media)
        }
    }

    // MARK: write failures

    @Test func writeThrowsWhenTheFileCannotBeWritten() throws {
        let out = EDLWriter.render(Timeline(name: "x", format: SequenceFormat(frameDuration: fd), tracks: []), media: [])
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString)/none/a.edl")
        #expect(throws: InterchangeExportError.self) { try out.write(to: missing) }
        let ok = FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).edl")
        defer { try? FileManager.default.removeItem(at: ok) }
        try out.write(to: ok)
        #expect(try Data(contentsOf: ok) == Data(out.text.utf8))
    }

    @Test func failedRenderThrowsInsteadOfWriting() {
        let bad = InterchangeExport(text: "", warnings: [], failure: "boom")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-\(UUID().uuidString).otio")
        #expect(throws: InterchangeExportError.failed("boom")) { try bad.write(to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: markers

    private func markerTimeline() -> Timeline {
        let v = Track(kind: .video, clips: [clip(a, .video, src: 0, dur: 100, at: 0)])
        var tl = Timeline(name: "M", format: SequenceFormat(frameDuration: fd), tracks: [v])
        tl.markers = [Marker(time: fd * 10, name: "Point", color: .blue, comment: "one"),
                      Marker(time: fd * 30, name: "Range", color: .red, comment: "two", duration: fd * 20)]
        return tl
    }

    @Test(arguments: ["xml", "fcpxml", "otio"]) func markersKeepTimeNameCommentAndPointVersusRange(_ ext: String) throws {
        let t = try read(ext, render(ext, markerTimeline(), media: [a]))
        let m = t.markers.sorted { $0.time < $1.time }
        #expect(m.count == 2)
        #expect(m[0].time == fd * 10 && m[0].name == "Point" && m[0].comment == "one" && m[0].duration == .zero)
        #expect(m[1].time == fd * 30 && m[1].name == "Range" && m[1].comment == "two" && m[1].duration == fd * 20)
    }

    @Test func edlMarkersKeepTimeAndName() throws {
        let t = try read("edl", render("edl", markerTimeline(), media: [a]))
        #expect(t.markers.map(\.time) == [fd * 10, fd * 30] && t.markers.map(\.name) == ["Point", "Range"])
    }

    @Test(arguments: ["xml", "fcpxml", "otio", "edl"]) func clipMarkersLandWhereTheClipShowsThem(_ ext: String) throws {
        var c = clip(a, .video, src: 50, dur: 100, at: 25)
        c.markers = [Marker(time: fd * 60, name: "Inside", color: .red),
                     Marker(time: fd * 10, name: "BeforeIn"), Marker(time: fd * 200, name: "AfterOut")]
        let tl = Timeline(name: "C", format: SequenceFormat(frameDuration: fd), tracks: [Track(kind: .video, clips: [c])])
        let t = try read(ext, render(ext, tl, media: [a]))
        #expect(t.markers.count == 1)
        #expect(t.markers.first?.name == "Inside")
        #expect(t.markers.first?.time == fd * 35)   // clip starts at 25, marker 10 frames after the source in point
    }

    // MARK: split channels

    @Test func xmemlSplitChannelRoundTrip() throws {
        var m = a
        m.info = MediaInfo(duration: fd * 500, video: nil,
                           audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "AAC", channelMap: AudioChannelMap.mono(1)))
        let tl = Timeline(name: "S", format: SequenceFormat(frameDuration: fd),
                          tracks: [Track(kind: .audio, clips: [clip(m, .audio, src: 0, dur: 50, at: 0)])])
        let out = XMEMLWriter.render(tl, media: [m])
        #expect(out.text.contains("<trackindex>2</trackindex></sourcetrack>"))
        #expect(out.text.contains("<channelcount>2</channelcount>"))
        // Read back against probed media: the channel choice returns on the media item.
        var probed = MediaRef(name: m.name, path: m.path, fingerprint: m.fingerprint)
        probed.info = MediaInfo(duration: fd * 500, audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "AAC"))
        let seq = try InterchangeReader.read(data: Data(out.text.utf8), fileExtension: "xml", name: "S")
        let result = InterchangeMapper.map(seq, media: [m.path: probed])
        #expect(result.project.media.first?.info?.audio?.channelMap == AudioChannelMap.mono(1))
    }

    @Test func fcpxmlSplitChannelWritesChannelSource() {
        var m = a
        m.info = MediaInfo(duration: fd * 500, video: nil,
                           audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "AAC", channelMap: AudioChannelMap.mono(1)))
        let tl = Timeline(name: "S", format: SequenceFormat(frameDuration: fd),
                          tracks: [Track(kind: .audio, clips: [clip(m, .audio, src: 0, dur: 50, at: 0)])])
        let t = FCPXMLWriter.render(tl, media: [m]).text
        #expect(t.contains("<audio-channel-source srcCh=\"2\" outCh=\"L, R\" active=\"1\"/>"))
        // A plain stereo file writes no channel source.
        var st = a
        st.info = MediaInfo(duration: fd * 500, video: nil,
                            audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "AAC", channelMap: AudioChannelMap.stereo(0, 1)))
        let tl2 = Timeline(name: "S", format: SequenceFormat(frameDuration: fd),
                           tracks: [Track(kind: .audio, clips: [clip(st, .audio, src: 0, dur: 50, at: 0)])])
        #expect(!FCPXMLWriter.render(tl2, media: [st]).text.contains("audio-channel-source"))
    }

    @Test func xmemlFirstChannelWritesTrackIndexOne() {
        let tl = Timeline(name: "S", format: SequenceFormat(frameDuration: fd),
                          tracks: [Track(kind: .audio, clips: [clip(a, .audio, src: 0, dur: 50, at: 0)])])
        #expect(XMEMLWriter.render(tl, media: [a]).text.contains("<trackindex>1</trackindex></sourcetrack>"))
    }

    // MARK: audio dissolves

    private func audioDissolve(_ kind: TransitionKind) -> Timeline {
        let c1 = clip(a, .audio, src: 0, dur: 50, at: 0), c2 = clip(b, .audio, src: 0, dur: 50, at: 50)
        var t = Track(kind: .audio, clips: [c1, c2])
        t.transitions = [Transition(kind: kind, duration: fd * 10, alignment: .startAtCut, outgoing: c1.id, incoming: c2.id)]
        return Timeline(name: "AD", format: SequenceFormat(frameDuration: fd), tracks: [t])
    }

    @Test(arguments: ["xml", "otio", "edl"]) func audioDissolveSurvives(_ ext: String) throws {
        let t = try read(ext, render(ext, audioDissolve(.constantPower), media: [a, b]))
        let track = try #require(t.tracks.first { $0.kind == .audio })
        #expect(track.clips.count == 2)
        let tr = try #require(track.transitions.first)
        #expect(tr.duration == fd * 10 && tr.outgoing == track.clips[0].id && tr.incoming == track.clips[1].id)
        #expect(tr.kind.trackKind == .audio)
    }

    @Test func xmemlAudioCrossFadeNamesKeepTheCurve() throws {
        let t = try read("xml", XMEMLWriter.render(audioDissolve(.constantGain), media: [a, b]))
        #expect(t.tracks[0].transitions.first?.kind == .constantGain)
    }

    @Test func edlWritesAnAudioDEvent() {
        let out = EDLWriter.render(audioDissolve(.constantPower), media: [a, b])
        #expect(out.text.contains("D    010"))
        #expect(!out.warnings.contains { $0.contains("Audio transitions") })
    }

    // MARK: clip links

    @Test func xmemlLinksSurviveWhenRangesDiffer() throws {
        // The sound starts 1 s earlier than the picture: no range match, only the link says they belong together.
        var v = clip(a, .video, src: 50, dur: 50, at: 25)
        var s = clip(a, .audio, src: 25, dur: 75, at: 0)
        let group = UUID()
        v.link = group; s.link = group
        let other = clip(b, .audio, src: 0, dur: 25, at: 100)   // not linked
        let tl = Timeline(name: "L", format: SequenceFormat(frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [v]), Track(kind: .audio, clips: [s, other])])
        let out = XMEMLWriter.render(tl, media: [a, b])
        #expect(out.text.contains("<linkclipref>clipitem-1</linkclipref>"))
        #expect(out.text.contains("<linkclipref>clipitem-2</linkclipref>"))
        let t = try read("xml", out)
        let vv = try #require(t.tracks.first { $0.kind == .video }?.clips.first)
        let aa = try #require(t.tracks.first { $0.kind == .audio }?.clips)
        #expect(vv.link != nil && vv.link == aa[0].link)
        #expect(aa[1].link == nil)
    }

    @Test func unlinkedVideoAndAudioOfSameRangeStayLinkedByTheOldRule() throws {
        let tl = Timeline(name: "L", format: SequenceFormat(frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [clip(a, .video, src: 0, dur: 50, at: 0)]),
                                   Track(kind: .audio, clips: [clip(a, .audio, src: 0, dur: 50, at: 0)])])
        let t = try read("xml", XMEMLWriter.render(tl, media: [a]))
        #expect(t.tracks[0].clips[0].link != nil && t.tracks[0].clips[0].link == t.tracks[1].clips[0].link)
    }

    // MARK: FCPXML 1.10+ and value encoding

    @Test func fcpxmlVersionTenWritesMediaRepAndReadsBack() throws {
        let c = clip(a, .video, src: 0, dur: 50, at: 0)
        let tl = Timeline(name: "V", format: SequenceFormat(frameDuration: fd), tracks: [Track(kind: .video, clips: [c])])
        let old = FCPXMLWriter.render(tl, media: [a])
        #expect(old.text.contains("<fcpxml version=\"1.8\">") && old.text.contains(" src=\"file:///Volumes/Shoot/A001.mov\""))
        for v in [FCPXMLWriter.Version.v1_10, .v1_13] {
            let out = FCPXMLWriter.render(tl, media: [a], version: v, target: .finalCut)
            #expect(out.text.contains("<fcpxml version=\"\(v.rawValue)\">"))
            #expect(out.text.contains("<media-rep kind=\"original-media\" src=\"file:///Volumes/Shoot/A001.mov\"/>"))
            #expect(out.text.contains("colorSpace="))
            let t = try read("fcpxml", out)
            #expect(t.tracks[0].clips.count == 1 && t.tracks[0].clips[0].duration == fd * 50)
            #expect(t.tracks[0].clips[0].name == "A001.mov")
        }
    }

    @Test func fcpxmlTargetsEncodeFrameTimesDifferently() throws {
        let ntsc = Time(1001, 30_000)
        let c = clip(a, .video, src: 0, dur: 10, at: 0, fd: ntsc)
        let tl = Timeline(name: "V", format: SequenceFormat(frameDuration: ntsc), tracks: [Track(kind: .video, clips: [c])])
        let resolve = FCPXMLWriter.render(tl, media: [a], target: .resolve).text
        let fcp = FCPXMLWriter.render(tl, media: [a], version: .v1_10, target: .finalCut).text
        #expect(resolve.contains("duration=\"1001/3000s\""))
        #expect(fcp.contains("duration=\"10010/30000s\""))
        #expect(!fcp.contains("1001/3000s"))
        for text in [resolve, fcp] {
            let t = try read("fcpxml", InterchangeExport(text: text, warnings: []), fd: ntsc)
            #expect(t.tracks[0].clips[0].duration == ntsc * 10 && t.format.frameDuration == ntsc)
        }
    }

    @Test func frameAlignedStringKeepsOffGridTimesReduced() {
        let ntsc = Time(1001, 30_000)
        #expect(FCPXMLWriter.frameAlignedString(.zero, fd: ntsc) == "0s")
        #expect(FCPXMLWriter.frameAlignedString(ntsc * 3, fd: ntsc) == "3003/30000s")
        #expect(FCPXMLWriter.frameAlignedString(Time(1, 2), fd: ntsc) == "1/2s")
        #expect(FCPXMLWriter.frameAlignedString(Time(4, 1), fd: Time(1, 25)) == "100/25s")
    }

    // MARK: rational origins, drop-frame partition

    @Test(arguments: ["xml", "fcpxml", "otio", "edl"]) func ntscDropFrameOriginKeepsClipPositions(_ ext: String) throws {
        let ntsc = Time(1001, 30_000)
        // 01:00:00;00 at 29.97 DF is frame 107892; the clip starts 1799 frames in (just before the minute drop).
        var tl = Timeline(name: "DF", format: SequenceFormat(frameDuration: ntsc),
                          tracks: [Track(kind: .video, clips: [clip(a, .video, src: 3, dur: 30, at: 1799, fd: ntsc)])])
        tl.timecodeStart = ntsc * 107_892
        let t = try read(ext, render(ext, tl, media: [a]), fd: ntsc)
        let c = try #require(t.tracks.first?.clips.first)
        #expect(c.start == ntsc * 1799 && c.duration == ntsc * 30)
    }

    @Test func dropFrameStampsAcrossPartitionEdges() {
        let tc = CMXTimecode(nominalRate: 30, dropFrame: true)
        #expect(tc.string(frames: 1799) == "00:00:59;29")
        #expect(tc.string(frames: 1800) == "00:01:00;02")
        #expect(tc.string(frames: 17_981) == "00:09:59;29")
        #expect(tc.string(frames: 17_982) == "00:10:00;00")
        #expect(tc.string(frames: 107_892) == "01:00:00;00")
        let hi = CMXTimecode(nominalRate: 60, dropFrame: true)
        #expect(hi.string(frames: 3599) == "00:00:59;59")
        #expect(hi.string(frames: 3600) == "00:01:00;04")
        for f in [Int64(0), 1, 1799, 1800, 1801, 17_981, 17_982, 17_983, 107_892, 1_078_920] {
            #expect(tc.frames(tc.string(frames: f)) == f)
            #expect(hi.frames(hi.string(frames: f)) == f)
        }
    }

    @Test func edlHeaderSaysDropFrameAtNtsc() {
        let ntsc = Time(1001, 30_000)
        let tl = Timeline(name: "DF", format: SequenceFormat(frameDuration: ntsc),
                          tracks: [Track(kind: .video, clips: [clip(a, .video, src: 0, dur: 30, at: 17_982, fd: ntsc)])])
        let text = EDLWriter.render(tl, media: [a]).text
        #expect(text.contains("FCM: DROP FRAME"))
        #expect(text.contains("00:10:00;00"))   // record in of the clip at frame 17982
    }
}

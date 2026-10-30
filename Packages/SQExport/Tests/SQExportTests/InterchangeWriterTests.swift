import Testing
import Foundation
import SQCore
import SQText
@testable import SQExport

/// EDL (CMX3600) and FCPXML writers: text content from small hand-built timelines (no footage).
@Suite struct InterchangeWriterTests {
    let fd = Time(1, 25)
    let a = MediaRef(name: "A001.mov", path: "/Volumes/Shoot/A001.mov", fingerprint: MediaFingerprint(size: 1))
    let b = MediaRef(name: "B & C.mov", path: "/Volumes/Shoot/B & C.mov", fingerprint: MediaFingerprint(size: 1))

    private func clip(_ m: MediaRef, _ kind: TrackKind, src: Int64, dur: Int64, at: Int64, speed: ClipSpeed = .normal,
                      reversed: Bool = false, link: UUID? = nil, name: String? = nil, fd: Time? = nil) -> Clip {
        let f = fd ?? self.fd
        return Clip(name: name ?? m.name, media: m.id, kind: kind, source: TimeRange(start: f * src, duration: f * dur),
                    start: f * at, link: link, speed: speed, reversed: reversed)
    }

    private func timeline(_ tracks: [Track], fd: Time? = nil) -> Timeline {
        Timeline(name: "Cut", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd ?? self.fd), tracks: tracks)
    }

    @Test func edlCutsSpeedNamesAndPaths() {
        let link = UUID()
        let v = Track(kind: .video, clips: [
            clip(a, .video, src: 250, dur: 125, at: 0, link: link),
            clip(b, .video, src: 0, dur: 100, at: 125, speed: ClipSpeed(num: 2, den: 1)),   // 2 s at 200 % plays 4 s of source
        ])
        let au = Track(kind: .audio, clips: [clip(a, .audio, src: 250, dur: 125, at: 0, link: link)])
        let out = EDLWriter.render(timeline([v, au]), media: [a, b])
        let lines = out.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "TITLE: Cut")
        #expect(lines[1] == "FCM: NON-DROP FRAME")
        #expect(lines.contains("001  AX       V     C        00:00:10:00 00:00:15:00 00:00:00:00 00:00:05:00"))
        #expect(lines.contains("* FROM CLIP NAME: A001.mov"))
        #expect(lines.contains("* SOURCE FILE: /Volumes/Shoot/A001.mov"))
        #expect(lines.contains("002  AX       V     C        00:00:00:00 00:00:04:00 00:00:05:00 00:00:07:00"))
        #expect(lines.contains { $0.hasPrefix("M2   AX       050.0 ") && $0.hasSuffix(" 00:00:00:00") })
        #expect(lines.contains("003  AX       A     C        00:00:10:00 00:00:15:00 00:00:00:00 00:00:05:00"))
        #expect(out.warnings.isEmpty)
    }

    @Test func edlLayersAboveV1GetTheirOwnFile() {
        let v1 = Track(kind: .video, clips: [clip(a, .video, src: 0, dur: 50, at: 0)])
        let v2 = Track(kind: .video, clips: [clip(b, .video, src: 25, dur: 25, at: 10)])
        let au = Track(kind: .audio, clips: [clip(a, .audio, src: 0, dur: 50, at: 0)])
        let empty = Track(kind: .video, clips: [])
        let tl = timeline([v1, v2, au, empty])
        let main = EDLWriter.render(tl, media: [a, b])
        #expect(!main.text.contains("B & C.mov"))
        #expect(main.warnings.contains { $0.contains("above V1") })
        let layers = EDLWriter.layerFiles(tl, media: [a, b])
        #expect(layers.map(\.label) == ["V2"])   // the empty V3 gets no file
        let lines = layers[0].export.text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "TITLE: Cut V2")
        #expect(lines.contains("001  AX       V     C        00:00:01:00 00:00:02:00 00:00:00:10 00:00:01:10"))
        #expect(lines.contains("* FROM CLIP NAME: B & C.mov"))
        #expect(!lines.contains { $0.contains("  A  ") || $0.contains("A001.mov") })
        #expect(layers[0].export.warnings.isEmpty)
    }

    @Test func edlDissolveIsZeroLengthCutPlusDEvent() {
        let first = clip(a, .video, src: 250, dur: 125, at: 0), second = clip(b, .video, src: 500, dur: 75, at: 125)
        var v = Track(kind: .video, clips: [first, second])
        v.transitions = [Transition(kind: .crossDissolve, duration: fd * 25, alignment: .startAtCut,
                                    outgoing: first.id, incoming: second.id)]
        let lines = EDLWriter.render(timeline([v]), media: [a, b]).text.split(separator: "\n").map(String.init)
        #expect(lines.contains("002  AX       V     C        00:00:15:00 00:00:15:00 00:00:05:00 00:00:05:00"))
        #expect(lines.contains("002  AX       V     D    025 00:00:20:00 00:00:23:00 00:00:05:00 00:00:08:00"))
        #expect(lines.contains("* TO CLIP NAME: B & C.mov"))
    }

    @Test func edlDropFrameStartTimecodeReverseAndMarkers() {
        let ntsc = Time(1001, 30_000)
        var tl = timeline([Track(kind: .video, clips: [
            clip(a, .video, src: 100, dur: 30, at: 1800, reversed: true, fd: ntsc),
        ])], fd: ntsc)
        tl.markers = [Marker(time: ntsc * 1830, name: "Hit", color: .red)]
        let lines = EDLWriter.render(tl, media: [a]).text.split(separator: "\n").map(String.init)
        #expect(lines[1] == "FCM: DROP FRAME")
        // Reversed: the In is the last frame shown (source end), speed is negative.
        #expect(lines.contains("001  AX       V     C        00:00:04;10 00:00:03;10 00:01:00;02 00:01:01;02"))
        #expect(lines.contains { $0.hasPrefix("M2   AX       -029.97003 ") && $0.hasSuffix(" 00:00:04;10") })
        #expect(lines.contains("* LOC: 00:01:01;02 RED Hit"))
    }

    @Test func edlRecordBaseFollowsSequenceTimecodeStart() {
        var tl = timeline([Track(kind: .video, clips: [clip(a, .video, src: 0, dur: 25, at: 0)])])
        tl.timecodeStart = Time(3600, 1)
        let out = EDLWriter.render(tl, media: [a]).text
        #expect(out.contains("00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00"))
    }

    @Test func edlSkipsWhatItCannotCarry() {
        var off = clip(a, .video, src: 0, dur: 25, at: 0)
        off.isEnabled = false
        let text = Clip(name: "Title", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 25),
                        start: fd * 25, generator: GeneratorRef(kind: GeneratorRef.text, payload: Data()))
        let upper = Track(kind: .video, clips: [clip(b, .video, src: 0, dur: 25, at: 0)])
        let out = EDLWriter.render(timeline([Track(kind: .video, clips: [off, text, clip(a, .video, src: 5, dur: 25, at: 50)]), upper]),
                                   media: [a, b])
        #expect(!out.text.contains("B & C"))
        #expect(out.warnings.count == 3)
        #expect(out.text.contains("001  AX       V     C"))
        #expect(!out.text.contains("002  AX       V"))
    }

    @Test func fcpxmlSpineGapConnectedSpeedTransitionAndMarker() {
        let link = UUID()
        let c1 = clip(a, .video, src: 50, dur: 50, at: 25, link: link)
        var c2 = clip(b, .video, src: 0, dur: 100, at: 100, speed: ClipSpeed(num: 2, den: 1))   // 2 s, 4 s of source
        c2.name = "Fast & Loud"
        var v1 = Track(kind: .video, clips: [c1, c2])
        v1.transitions = [Transition(kind: .crossDissolve, duration: fd * 10, alignment: .center, outgoing: c1.id, incoming: c2.id)]
        // c2 starts at 100 but c1 ends at 75: not adjacent, so no dissolve; the next case covers a real one.
        let over = clip(b, .video, src: 0, dur: 25, at: 50)
        let a1 = Track(kind: .audio, clips: [clip(a, .audio, src: 50, dur: 50, at: 25, link: link)])
        let a2 = Track(kind: .audio, clips: [clip(b, .audio, src: 0, dur: 25, at: 0)])
        var tl = timeline([v1, Track(kind: .video, clips: [over]), a1, a2])
        tl.markers = [Marker(time: fd * 25, name: "Beat", comment: "drum")]
        let out = FCPXMLWriter.render(tl, media: [a, b])
        let x = out.text
        #expect(x.contains("<fcpxml version=\"1.8\">"))
        #expect(x.contains("<format id=\"r1\" frameDuration=\"1/25s\" width=\"1920\" height=\"1080\"/>"))
        #expect(x.contains("src=\"file:///Volumes/Shoot/A001.mov\""))
        #expect(x.contains("src=\"file:///Volumes/Shoot/B%20&amp;%20C.mov\""))
        // Leading gap of one second, then the linked A/V pair as one asset clip.
        #expect(x.contains("<gap name=\"Gap\" offset=\"0s\" start=\"0s\" duration=\"1s\">"))
        #expect(x.contains("<asset-clip ref=\"r2\" offset=\"1s\" name=\"A001.mov\" start=\"2s\" duration=\"2s\""))
        #expect(x.contains("name=\"Fast &amp; Loud\""))
        #expect(x.contains("<timept time=\"0s\" value=\"0s\" interp=\"linear\"/>"))
        #expect(x.contains("<timept time=\"2s\" value=\"4s\" interp=\"linear\"/>"))
        // The V2 clip connects to the spine item under it with lane 1, offset in that item's own time.
        #expect(x.contains("lane=\"1\" offset=\"3s\""))
        // The audio-only clip on A2 sits on lane -2.
        #expect(x.contains("<audio ref=\"r3\" lane=\"-2\""))
        #expect(x.contains("<marker start=\"2s\" duration=\"1/25s\" value=\"Beat\" note=\"drum\"/>"))
        #expect(!x.contains("<transition"))
    }

    @Test func fcpxmlCrossDissolveBetweenAdjacentSpineClips() {
        let c1 = clip(a, .video, src: 0, dur: 50, at: 0), c2 = clip(a, .video, src: 100, dur: 50, at: 50)
        var v = Track(kind: .video, clips: [c1, c2])
        v.transitions = [Transition(kind: .crossDissolve, duration: fd * 10, alignment: .center, outgoing: c1.id, incoming: c2.id)]
        let x = FCPXMLWriter.render(timeline([v]), media: [a]).text
        #expect(x.contains("<transition name=\"Cross Dissolve\" offset=\"9/5s\" duration=\"2/5s\""))
        #expect(x.contains("tcFormat=\"NDF\""))
    }

    @Test func fcpxmlDropFrameTimecodeAndOffsets() {
        let ntsc = Time(1001, 30_000)
        var tl = timeline([Track(kind: .video, clips: [clip(a, .video, src: 0, dur: 30, at: 0, fd: ntsc)])], fd: ntsc)
        tl.timecodeStart = ntsc * 107_892
        let x = FCPXMLWriter.render(tl, media: [a]).text
        #expect(x.contains("tcFormat=\"DF\""))
        #expect(x.contains("frameDuration=\"1001/30000s\""))
        let start = FCPXMLWriter.timeString(tl.timecodeStart)
        #expect(x.contains("tcStart=\"\(start)\""))
        #expect(x.contains("offset=\"\(start)\""))
    }

    private func titleClip(_ text: String, at: Int64, dur: Int64) throws -> Clip {
        var style = CaptionPresetLibrary.builtIn.style(for: "title")
        style.size = 72; style.weight = .bold; style.alignment = .center
        style.color = RGBAColor(red: 1, green: 0.5, blue: 0)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "T", text: text, style: style), animations: nil)
        let id = UUID()
        return Clip(id: id, name: "Lower & Third", media: id, kind: .video, source: TimeRange(start: .zero, duration: fd * dur),
                    start: fd * at, generator: ref)
    }

    @Test func fcpxmlWritesTextClipsAsTitles() throws {
        let c1 = clip(a, .video, src: 0, dur: 50, at: 0)
        let spineTitle = try titleClip("Hello\nWorld <3", at: 50, dur: 25)
        let over = try titleClip("Over", at: 10, dur: 20)
        let tl = timeline([Track(kind: .video, clips: [c1, spineTitle]), Track(kind: .video, clips: [over])])
        let out = FCPXMLWriter.render(tl, media: [a])
        let x = out.text
        #expect(out.warnings.isEmpty)
        #expect(x.contains("<effect id=\"r3\" name=\"Basic Title\" uid=\".../Titles.localized/"))
        #expect(x.contains("<title ref=\"r3\" offset=\"2s\" name=\"Lower &amp; Third\" start=\"0s\" duration=\"1s\">"))
        #expect(x.contains("<title ref=\"r3\" lane=\"1\" offset=\"2/5s\" name=\"Lower &amp; Third\" start=\"0s\" duration=\"4/5s\">"))
        #expect(x.contains("<text-style ref=\"ts2\">Hello&#10;World &lt;3</text-style>"))
        #expect(x.contains("<text-style ref=\"ts1\">Over</text-style>"))
        #expect(x.contains("fontSize=\"72\""))
        #expect(x.contains("fontColor=\"1 0.5 0 1\""))
        #expect(x.contains("bold=\"1\""))
        #expect(x.contains("alignment=\"center\""))
        #expect(!x.contains("<gap"), "the title in the spine closes the sequence, no gap needed")
    }

    @Test func fcpxmlStillSkipsOtherGeneratorsAndWarns() {
        let solid = Clip(name: "Dip", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 25),
                         start: .zero, generator: GeneratorRef.solid(rgb: [0, 0, 0]))
        let out = FCPXMLWriter.render(timeline([Track(kind: .video, clips: [solid])]), media: [])
        #expect(out.warnings.contains { $0.contains("Generator") })
        #expect(!out.text.contains("<title"))
    }
}

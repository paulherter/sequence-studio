import Testing
import Foundation
import SSCore
import SSTranscribe
@testable import SSExport

@Suite struct SRTTests {
    @Test func timecodeFormatAndRounding() {
        #expect(SRTWriter.timecode(.zero) == "00:00:00,000")
        #expect(SRTWriter.timecode(Time(3_661_005, 1000)) == "01:01:01,005")
        // 1/3 s = 333.33 ms -> 333; 2/3 s = 666.67 -> 667
        #expect(SRTWriter.timecode(Time(1, 3)) == "00:00:00,333")
        #expect(SRTWriter.timecode(Time(2, 3)) == "00:00:00,667")
        // tie (0.5 ms) rounds up
        #expect(SRTWriter.timecode(Time(1, 2000)) == "00:00:00,001")
        // 29.97 fps: frame 30 = 30 * 1001/30000 = 1.001 s
        #expect(SRTWriter.timecode(Time(1001, 30000) * 30) == "00:00:01,001")
        // negative clamps to zero
        #expect(SRTWriter.timecode(Time(-5, 1)) == "00:00:00,000")
        // over 99 hours still well-formed
        #expect(SRTWriter.timecode(Time(360_000, 1)) == "100:00:00,000")
    }

    private func cue(_ lines: [String], _ s: Int64, _ e: Int64) -> SRTCue {
        SRTCue(lines: lines, range: TimeRange(start: Time(s, 1000), end: Time(e, 1000)))
    }

    @Test func rendersSequentialIndicesCRLFAndOwnLines() {
        let out = SRTWriter.render([cue(["Hello", "world"], 0, 1500), cue(["Bye"], 2000, 2500)], range: .entireSequence)
        #expect(out == "1\r\n00:00:00,000 --> 00:00:01,500\r\nHello\r\nworld\r\n\r\n2\r\n00:00:02,000 --> 00:00:02,500\r\nBye\r\n\r\n")
    }

    @Test func offsetsAndClipsToRange() {
        let r = TimeRange(start: Time(10, 1), end: Time(20, 1))
        let cues = [
            cue(["before"], 1000, 9000),          // out of range
            cue(["straddle in"], 9000, 11000),    // clipped to 10..11 -> 0..1
            cue(["inside"], 12000, 14000),
            cue(["touch end"], 20000, 21000),     // starts exactly at range end: out
            cue(["straddle out"], 19000, 25000),  // clipped to 19..20 -> 9..10
        ]
        let out = SRTWriter.render(cues, range: .inOut(r))
        #expect(out.contains("1\r\n00:00:00,000 --> 00:00:01,000\r\nstraddle in"))
        #expect(out.contains("2\r\n00:00:02,000 --> 00:00:04,000\r\ninside"))
        #expect(out.contains("3\r\n00:00:09,000 --> 00:00:10,000\r\nstraddle out"))
        #expect(!out.contains("before") && !out.contains("touch end"))
    }

    @Test func skipsEmptyCuesAndBlankLines() {
        let cues = [cue([], 0, 1000), cue(["  ", ""], 0, 1000), cue(["a", "", "b"], 1000, 2000),
                    cue(["zero length"], 3000, 3000),
                    // rounds to the same millisecond: dropped
                    SRTCue(lines: ["tiny"], range: TimeRange(start: Time(1, 3), end: Time(1, 3) + Time(1, 10_000)))]
        let out = SRTWriter.render(cues, range: .entireSequence)
        #expect(out == "1\r\n00:00:01,000 --> 00:00:02,000\r\na\r\nb\r\n\r\n")
    }

    @Test func emptyInputGivesEmptyString() {
        #expect(SRTWriter.render([], range: .entireSequence).isEmpty)
    }

    @Test func utf8RoundTrip() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.srt")
        try SRTWriter.write([cue(["Grüße — 日本語 🎬"], 0, 1000)], range: .entireSequence, to: url)
        let back = try String(contentsOf: url, encoding: .utf8)
        #expect(back.contains("Grüße — 日本語 🎬"))
    }

    @Test func cuesFromCaptions() {
        let words = [
            TranscriptWord(text: "Hello", range: TimeRange(start: Time(0, 1), end: Time(1, 2))),
            TranscriptWord(text: "there", range: TimeRange(start: Time(1, 2), end: Time(1, 1))),
        ]
        let caps = CaptionSegmenter.segment(Transcript(language: "en", words: words), preset: .standard)
        let cues = SRTWriter.cues(from: caps)
        #expect(cues.count == caps.count)
        #expect(cues.first?.lines == caps.first?.lines)
        #expect(cues.first?.range == caps.first?.range)
    }

    @Test func queueWritesSidecarNextToVideo() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = smallSettings(codec: .h264)
        s.captions = .sidecarSRT
        let q = ExportQueue()
        let id = await q.enqueue(ExportJob(name: "Clip", settings: s, outputDirectory: dir) {
            ExportSources(video: TestPatternSource(width: 64, height: 112, frameCount: 10, frameDuration: Time(1, 30)),
                          captions: [SRTCue(lines: ["Hi"], range: TimeRange(start: .zero, end: Time(1, 10)))])
        })
        await q.runAll()
        let st = try #require(await q.status(id))
        guard case .done(let url) = st.state else { Issue.record("not done: \(st.state)"); return }
        let srt = dir.appendingPathComponent("Clip.srt")
        #expect(st.sidecarURL == srt)
        #expect(url.deletingPathExtension().lastPathComponent == "Clip")
        #expect(try String(contentsOf: srt, encoding: .utf8).contains("00:00:00,000 --> 00:00:00,100\r\nHi"))
    }
}

@Suite struct BurnInWiringTests {
    private func timeline() throws -> Timeline {
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try t.replaceCaptions([
            CaptionItem(lines: ["Hello", "there"], range: TimeRange(start: Time(1, 1), end: Time(2, 1)), styleRef: "tiktok"),
            CaptionItem(lines: [" "], range: TimeRange(start: Time(3, 1), end: Time(4, 1))),      // blank: skipped
        ])
        return t
    }

    @Test func burnInOnlyWhenRequestedAndCaptionsExist() throws {
        var s = ExportSettings()
        #expect(ExportSourceBuilder.burnIn(for: try timeline(), settings: s) == nil)        // captions: none
        s.captions = .burnIn
        let b = try #require(ExportSourceBuilder.burnIn(for: try timeline(), settings: s))
        #expect(b.captions.count == 1 && b.captions[0].lines == ["Hello", "there"] && b.captions[0].styleRef == "tiktok")
        #expect(b.state(at: Time(3, 2)) != nil && b.state(at: Time(7, 2)) == nil)
        let empty = Timeline(name: "e", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        #expect(ExportSourceBuilder.burnIn(for: empty, settings: s) == nil)
    }

    @Test func hiddenCaptionTrackIsNotBurnedIn() throws {
        var t = try timeline()
        t.captionTracks[0].isVisible = false
        var s = ExportSettings(); s.captions = .burnIn
        #expect(ExportSourceBuilder.burnIn(for: t, settings: s) == nil)
    }
}

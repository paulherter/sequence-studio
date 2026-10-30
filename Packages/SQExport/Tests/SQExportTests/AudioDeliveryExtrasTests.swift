import Testing
import Foundation
import SQCore
@testable import SQExport

@Suite struct AudioDeliveryExtrasTests {
    @Test func namedTargets() {
        #expect(AudioDeliveryTarget.spotify.targetLUFS == -14)
        #expect(AudioDeliveryTarget.appleMusic.targetLUFS == -16)
        #expect(AudioDeliveryTarget.ebuR128.targetLUFS == -23)
        #expect(AudioDeliveryTarget.ebuR128.toleranceLU == 0.5)
        #expect(AudioDeliveryTarget.allCases.allSatisfy { $0.truePeakCeilingDB == -1 })
        #expect(AudioDeliveryTarget.matching(LoudnessNormalization(targetLUFS: -16, truePeakCeilingDB: -1)) == .appleMusic)
        #expect(AudioDeliveryTarget.matching(LoudnessNormalization(targetLUFS: -17, truePeakCeilingDB: -1)) == nil)
    }

    @Test func ebuToleranceIsTighter() {
        let a = AudioAnalysis(integratedLUFS: -22.2, truePeakDB: -3, clippedSamples: 0, gapCount: 0, longestGapSeconds: 0,
                              isDualMono: false, durationSeconds: 120)
        let t = AudioDeliveryTarget.ebuR128
        let loose = AudioPreflight.evaluate(a, target: t.normalization, normalizing: false)
        let tight = AudioPreflight.evaluate(a, target: t.normalization, normalizing: false, toleranceLU: t.toleranceLU)
        #expect(loose.first { $0.kind == .loudness }?.severity == .pass)
        #expect(tight.first { $0.kind == .loudness }?.severity == .fail)
    }

    @Test func loudnessRangeNeedsSixtySeconds() {
        #expect(!AudioDeliveryTarget.loudnessRangeAvailable(durationSeconds: 59.9))
        #expect(AudioDeliveryTarget.loudnessRangeAvailable(durationSeconds: 60))
    }

    @Test func webVTT() {
        func cue(_ l: [String], _ s: Int64, _ e: Int64) -> SRTCue { SRTCue(lines: l, range: TimeRange(start: Time(s, 1000), end: Time(e, 1000))) }
        let out = VTTWriter.render([cue(["B & <i>"], 3000, 4000), cue(["A"], 1000, 2500)], range: .entireSequence)
        #expect(out == "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nA\n\n00:00:03.000 --> 00:00:04.000\nB &amp; &lt;i>\n\n")
        let r = RangeSelection.inOut(TimeRange(start: Time(2, 1), end: Time(10, 1)))
        #expect(VTTWriter.render([cue(["A"], 1000, 1500)], range: r) == "WEBVTT\n\n")
    }

    @Test func captionModeSidecarExtension() {
        #expect(CaptionMode.sidecarVTT.sidecarExtension == "vtt")
        #expect(CaptionMode.sidecarSRT.sidecarExtension == "srt")
        #expect(CaptionMode.sidecarITT.sidecarExtension == "itt")
        #expect(CaptionMode.burnIn.sidecarExtension == nil)
    }

    @Test func youTubeChapters() {
        let ms = [Marker(time: Time(0, 1), name: "Start"), Marker(time: Time(75, 1), name: "Middle"),
                  Marker(time: Time(3725, 1), name: "End"), Marker(time: Time(80, 1), name: "")]
        let r = YouTubeChapters.make(from: ms)
        #expect(r.text == "0:00 Start\n1:15 Middle\n1:02:05 End")
        #expect(r.warnings.isEmpty)
        let r2 = YouTubeChapters.make(from: [Marker(time: Time(20, 1), name: "A"), Marker(time: Time(25, 1), name: "B")])
        #expect(r2.text.hasPrefix("0:00 Intro\n0:20 A"))
        #expect(r2.warnings.count >= 2)
    }

    @Test func stemsPerRole() {
        func track(_ role: AudioTag?, clip: Bool = true) -> Track {
            let c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, end: Time(1, 1)), start: .zero)
            var t = Track(kind: .audio, clips: clip ? [c] : [])
            t.audioRole = role
            return t
        }
        var tl = Timeline(name: "S", format: SequenceFormat(frameDuration: Time(1, 30)))
        tl.tracks = [track(.dialogue), track(.music), track(.music), track(nil), track(.sfx, clip: false)]
        let stems = StemPlan.stems(for: tl)
        #expect(stems.map(\.id) == ["dialogue", "music", "other", "me"])
        let music = stems[1].timeline.tracks
        #expect(music.map(\.isMuted) == [true, false, false, true, true])
        #expect(stems[3].timeline.tracks.map(\.isMuted) == [true, false, false, false, true])
        #expect(StemPlan.fileNames(base: "Show", stems: stems, ext: "wav").first == "Show_dialogue.wav")
        #expect(StemPlan.stems(for: Timeline(name: "E", format: SequenceFormat(frameDuration: Time(1, 30)))).isEmpty)
    }

    @Test func settingsAccept96kAndAAC() {
        var s = ExportSettings.socialDefault
        s.audio.sampleRate = 96_000
        #expect(s.validate().isEmpty)
        #expect(ExportWriter.audioOutputSettings(s.audio)[AVSampleRateKeyForTest] as? Int == 96_000)
    }
}

import AVFoundation
private let AVSampleRateKeyForTest = AVSampleRateKey

@Suite struct CaptionSidecarTests {
    @Test func writesEachFormat() throws {
        let cue = SRTCue(lines: ["Hi"], range: TimeRange(start: Time(1, 1), end: Time(2, 1)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (mode, marker) in [(CaptionMode.sidecarSRT, "-->"), (.sidecarVTT, "WEBVTT"), (.sidecarITT, "<tt ")] {
            let url = dir.appendingPathComponent("a.\(mode.sidecarExtension!)")
            try mode.writeSidecar([cue], range: .entireSequence, to: url)
            #expect(try String(contentsOf: url, encoding: .utf8).contains(marker))
        }
        let none = dir.appendingPathComponent("n.txt")
        try CaptionMode.burnIn.writeSidecar([cue], range: .entireSequence, to: none)
        #expect(!FileManager.default.fileExists(atPath: none.path))
    }
}

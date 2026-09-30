import Testing
import Foundation
import SSCore
@testable import SSTranscribe

/// Gated real-clip test: skipped (returns early) when the clip or the on-device model is missing.
/// Clip: SS_TRANSCRIBE_CLIP, else `<package>/TestMedia/de_speech_20s.m4a`, else the session scratchpad copy.
@Suite struct SpeechTranscriptionTests {
    static func clipURL() -> URL? {
        var candidates: [String] = []
        if let p = ProcessInfo.processInfo.environment["SS_TRANSCRIBE_CLIP"] { candidates.append(p) }
        candidates.append("/private/tmp/claude-501/-Users-paul-Documents-SequenceStudio/ceccc865-c2da-4882-afbc-8f13f0ff0a1f/scratchpad/de_speech_20s.m4a")
        let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(pkg.appendingPathComponent("TestMedia/de_speech_20s.m4a").path)
        return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test func cmTimeConversionIsRational() {
        let r = SpeechAnalyzerTranscriber.timeRange(.init(start: .init(value: 1, timescale: 3), duration: .init(value: 1, timescale: 6)))
        #expect(r?.start == Time(1, 3))
        #expect(r?.end == Time(1, 2))
    }

    @Test func transcribesGermanClip() async throws {
        guard let clip = Self.clipURL() else { print("SKIP: no test clip"); return }
        let locale = Locale(identifier: "de-DE")
        guard await SpeechAnalyzerTranscriber.isModelInstalled(for: locale) else { print("SKIP: de-DE model not installed"); return }
        let tr = try await SpeechAnalyzerTranscriber().transcribe(url: clip, locale: locale) { _ in }
        print("TRANSCRIBE: words=\(tr.words.count) first=\(tr.words.first.map { "\($0.text)@\($0.range.start.value)/\($0.range.start.timescale)" } ?? "-") last=\(tr.words.last.map { "\($0.text)@\($0.range.end.value)/\($0.range.end.timescale)" } ?? "-")")
        print("TRANSCRIBE text: \(tr.text)")
        #expect(tr.words.count > 10)
        #expect(tr.words.allSatisfy { !$0.range.start.isNegative })
        for (a, b) in zip(tr.words, tr.words.dropFirst()) { #expect(a.range.start <= b.range.start) }
        #expect(tr.words.last!.range.end <= Time(25, 1))
    }
}

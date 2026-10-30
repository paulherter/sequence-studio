import Testing
import Foundation
import SQCore
@testable import SQTranscribe

/// Gated real-clip test: skipped (returns early) when the clip or the on-device model is missing.
/// Clip: SQ_TRANSCRIBE_CLIP, else `<package>/TestMedia/de_speech_20s.m4a`, else the session scratchpad copy.
@Suite struct SpeechTranscriptionTests {
    static func clipURL() -> URL? {
        var candidates: [String] = []
        if let p = ProcessInfo.processInfo.environment["SQ_TRANSCRIBE_CLIP"] { candidates.append(p) }
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
        let confs = tr.words.compactMap(\.confidence)
        let unsure = tr.words.filter(\.isUnsure).count
        print("TRANSCRIBE confidence: reported=\(confs.count)/\(tr.words.count) min=\(confs.min() ?? -1) max=\(confs.max() ?? -1) unsure=\(unsure)")
        if let out = ProcessInfo.processInfo.environment["SQ_TRANSCRIBE_REPORT"] {   // test.sh drops passing logs
            let rows = tr.words.map { "\($0.text)\t\($0.confidence.map { String($0) } ?? "nil")" }.joined(separator: "\n")
            try? rows.write(toFile: out, atomically: true, encoding: .utf8)
        }
        if confs.isEmpty { print("TRANSCRIBE confidence: none reported by this engine/locale") }
        #expect(tr.words.allSatisfy { !$0.range.start.isNegative })
        for (a, b) in zip(tr.words, tr.words.dropFirst()) { #expect(a.range.start <= b.range.start) }
        #expect(tr.words.last!.range.end <= Time(25, 1))
    }
}

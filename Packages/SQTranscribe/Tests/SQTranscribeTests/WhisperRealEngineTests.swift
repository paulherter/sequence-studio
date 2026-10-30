import Foundation
import Testing
@testable import SQTranscribe

/// The real engine on the PC: whisper.dll (scripts/win-whisper-setup.sh) and the model download. Runs only with
/// `SQ_WHISPER_WAV` (a 16 kHz mono 16-bit WAV with English speech, e.g. whisper.cpp's jfk.wav); otherwise a no-op.
@Suite struct WhisperRealEngineTests {
    static func samples(wav url: URL) throws -> [Float] {
        let d = try Data(contentsOf: url)
        var at = 12                                  // RIFF header, then chunks
        while at + 8 <= d.count {
            let id = String(decoding: d[at..<at + 4], as: UTF8.self)
            let size = Int(d[at + 4]) | Int(d[at + 5]) << 8 | Int(d[at + 6]) << 16 | Int(d[at + 7]) << 24
            if id == "data" {
                let end = min(d.count, at + 8 + size)
                return stride(from: at + 8, to: end - 1, by: 2).map { Float(Int16(bitPattern: UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8)) / 32768 }
            }
            at += 8 + size + (size & 1)
        }
        return []
    }

    @Test func transcribesTheSampleWithWordTiming() async throws {
        guard let wav = ProcessInfo.processInfo.environment["SQ_WHISPER_WAV"] else { return }
        let samples = try Self.samples(wav: URL(fileURLWithPath: wav))
        #expect(samples.count > 16_000)
        let t = WhisperTranscriber(engine: WhisperRuntime(), audio: { _ in samples })
        let seen = Seen()
        try await t.prepare(locale: Locale(identifier: "en-US")) { seen.add($0) }
        #expect(t.store.isInstalled)
        let progress = Seen()
        let r = try await t.transcribe(url: URL(fileURLWithPath: wav), locale: Locale(identifier: "en-US")) { progress.add($0) }
        print("whisper real:", r.text)
        let text = r.text.lowercased()
        #expect(text.contains("country") && text.contains("ask"))
        #expect(r.words.count > 10)
        let seconds = Double(samples.count) / 16_000
        #expect(r.words.allSatisfy { Double($0.range.end.value) / Double($0.range.end.timescale) <= seconds + 1 })
        #expect(zip(r.words, r.words.dropFirst()).allSatisfy { $0.range.start <= $1.range.start })
        #expect(progress.values.last == 1)
    }
}

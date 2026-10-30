import AVFoundation
import Foundation
import Testing
@testable import SQTranscribe

private let webm = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/SequenceStudio/TestMedia/sample-vp9-vorbis-long.webm")

@Suite struct WebMAudioExtractionTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: webm.path)))
    func webmAudioBecomesAReadableTemporaryFile() async throws {
        let s = try await AudioExtraction.readableAudio(at: webm)
        defer { if s.isTemporary { try? FileManager.default.removeItem(at: s.url) } }
        #expect(s.isTemporary)
        let f = try AVAudioFile(forReading: s.url)
        #expect(f.length > 48_000)
        #expect(f.processingFormat.sampleRate == 48_000)
    }
}

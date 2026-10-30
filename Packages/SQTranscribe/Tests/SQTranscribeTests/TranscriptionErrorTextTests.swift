import Foundation
import Testing
@testable import SQTranscribe

@Suite struct TranscriptionErrorTextTests {
    @Test func everyCaseReadsAsASentenceNotAnEnumDump() {
        for e in [TranscriptionError.unavailable, .noAudio, .localeUnsupported("de-DE")] {
            let text = e.localizedDescription
            #expect(!text.contains("TranscriptionError"))
            #expect(text.hasSuffix("."))
        }
        #expect(TranscriptionError.unavailable.localizedDescription == "Transcription is not available on this system yet.")
    }
}

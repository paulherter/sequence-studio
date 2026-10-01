import Testing
import Foundation
import SQCore
@testable import SQTranscribe

@Suite struct TranscriptTests {
    @Test func textJoinsWordsWithSpaces() {
        let tr = transcript([w("Hallo,", 0, 500), w("Welt", 600, 900)])
        #expect(tr.text == "Hallo, Welt")
        #expect(transcript([]).text == "")
    }

    @Test func codableRoundTripKeepsRationalTime() throws {
        let word = TranscriptWord(text: "Test", range: TimeRange(start: Time(1, 3), end: Time(5, 6)), isEdited: true)
        let tr = Transcript(language: "de-DE", words: [word])
        let data = try JSONEncoder().encode(tr)
        let back = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(back == tr)
        #expect(back.words[0].range.start == Time(1, 3))
    }

    @Test func wordsAreNotEditedByDefaultAndHaveUniqueIDs() {
        let a = w("a", 0, 1), b = w("a", 0, 1)
        #expect(!a.isEdited)
        #expect(a.id != b.id)
    }
}

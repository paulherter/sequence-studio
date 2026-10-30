import Foundation
import SQCore

/// One recognized or edited word with its position on the source timeline (rational time).
public struct TranscriptWord: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var text: String
    public var range: TimeRange
    /// True once the text was changed by hand after recognition.
    public var isEdited: Bool
    /// The recognizer's own confidence, 0...1 (nil: the engine reported none, or the word was typed by hand).
    public var confidence: Float?

    public init(id: UUID = UUID(), text: String, range: TimeRange, isEdited: Bool = false, confidence: Float? = nil) {
        self.confidence = confidence
        self.id = id
        self.text = text
        self.range = range
        self.isEdited = isEdited
    }

    /// Same rule as the timeline word boxes (`CaptionWord.unsureBelow`); an edited word has no confidence.
    public var isUnsure: Bool { CaptionWord.isUnsure(confidence: confidence) }
}

public struct Transcript: Sendable, Hashable, Codable {
    /// BCP-47 identifier, e.g. "de-DE".
    public var language: String
    public var words: [TranscriptWord]

    public init(language: String, words: [TranscriptWord] = []) {
        self.language = language
        self.words = words
    }

    /// Words joined by single spaces.
    public var text: String { words.map(\.text).joined(separator: " ") }
}

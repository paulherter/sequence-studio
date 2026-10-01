import Foundation
import SQCore

/// One recognised or edited word with its position on the source timeline (rational time).
public struct TranscriptWord: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var text: String
    public var range: TimeRange
    /// True once the text was changed by hand after recognition.
    public var isEdited: Bool

    public init(id: UUID = UUID(), text: String, range: TimeRange, isEdited: Bool = false) {
        self.id = id
        self.text = text
        self.range = range
        self.isEdited = isEdited
    }
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

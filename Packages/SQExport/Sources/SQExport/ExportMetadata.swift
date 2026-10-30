#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation
import SQCore

/// Descriptive metadata written into the exported file: title, comment, creation date, and the chapter list.
public struct ExportMetadata: Sendable, Hashable, Codable {
    public var title: String
    public var comment: String
    public var creationDate: Date?
    /// Chapter list text (`M:SS Title` lines, see `YouTubeChapters`), appended to the comment.
    /// shortcut: chapters travel as text in the description field, not as a QuickTime chapter track; upgrade when a player needs the track.
    public var chapterText: String

    public init(title: String = "", comment: String = "", creationDate: Date? = nil, chapterText: String = "") {
        self.title = title; self.comment = comment; self.creationDate = creationDate; self.chapterText = chapterText
    }

    /// Title, comment and chapters from the sequence's named markers.
    public init(title: String, comment: String = "", creationDate: Date? = nil, markers: [Marker],
                rangeStart: Time = .zero, duration: Time? = nil) {
        self.init(title: title, comment: comment, creationDate: creationDate,
                  chapterText: markers.isEmpty ? "" : YouTubeChapters.make(from: markers, rangeStart: rangeStart, duration: duration).text)
    }

    public var isEmpty: Bool { title.isEmpty && comment.isEmpty && creationDate == nil && chapterText.isEmpty }

    /// Comment with the chapter list after it, blank line between.
    public var fullComment: String {
        [comment, chapterText].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    #if canImport(AVFoundation)
    /// (identifier, value) pairs in file order; `items` wraps them for the writer.
    var entries: [(AVMetadataIdentifier, String)] {
        var out: [(AVMetadataIdentifier, String)] = []
        if !title.isEmpty { out.append((.commonIdentifierTitle, title)) }
        if !fullComment.isEmpty { out.append((.commonIdentifierDescription, fullComment)) }
        if let d = creationDate { out.append((.commonIdentifierCreationDate, ISO8601DateFormatter().string(from: d))) }
        return out
    }

    public var items: [AVMetadataItem] {
        entries.map { id, value in
            let i = AVMutableMetadataItem()
            i.identifier = id
            i.value = value as NSString
            i.extendedLanguageTag = "und"
            return i
        }
    }
    #endif
}

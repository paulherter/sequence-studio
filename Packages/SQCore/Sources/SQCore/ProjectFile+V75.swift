import Foundation

// v75: recognizer confidence on caption words (`CaptionWord.confidence`). A v74 build does not know the key and drops it
// on save (the editor would lose the marks for unsure words); at v75 it refuses the file with
// `ProjectFileError.newerVersion` instead. Projects without a confidence keep the lowest version that holds their content.

extension Timeline {
    /// Some caption word in this sequence carries a confidence.
    public var containsWordConfidence: Bool {
        captionTracks.contains { $0.items.contains { $0.words.contains { $0.confidence != nil } } }
    }
}

extension Project {
    /// Some caption word carries a recognizer confidence: the file must be v75.
    public var containsV75Content: Bool { timelines.contains(where: \.containsWordConfidence) }
}

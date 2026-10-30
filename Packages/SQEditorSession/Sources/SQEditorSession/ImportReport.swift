import Foundation

/// What the last `importFiles` did, in one value: how many files landed and every file that did not (or landed
/// without sound), each with its plain-language detail. Shown by a notice or sheet; empty lists mean nothing to tell.
public struct ImportReport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let file: String
        /// Reason (failed), codec (unsupported, audioDropped) or the name of what it duplicates.
        public let detail: String
        public init(file: String, detail: String) { self.file = file; self.detail = detail }
    }

    public var imported = 0
    /// Same path as an item in the project.
    public var alreadyInProject: [String] = []
    /// Another path to a file that is already in the project or earlier in the same batch (link, hard link, spelling).
    public var duplicates: [String] = []
    public var failed: [Entry] = []
    public var unsupported: [Entry] = []
    /// Imported, but without sound (its audio codec cannot be decoded here).
    public var audioDropped: [Entry] = []
    public var canceled = false

    public init() {}

    /// Files that were not imported.
    public var skippedCount: Int { alreadyInProject.count + duplicates.count + failed.count + unsupported.count }
    public var isClean: Bool { skippedCount == 0 && audioDropped.isEmpty && !canceled }

    /// One status line: "Imported 12 files. 3 skipped: 1 already in the project, 2 could not be read."
    public var summary: String {
        let files = "\(imported) file\(imported == 1 ? "" : "s")"
        var parts: [String] = []
        if !alreadyInProject.isEmpty { parts.append("\(alreadyInProject.count) already in the project") }
        if !duplicates.isEmpty {
            parts.append("\(duplicates.count) \(duplicates.count == 1 ? "is" : "are") the same file as one already imported")
        }
        if !failed.isEmpty { parts.append("\(failed.count) could not be read") }
        if !unsupported.isEmpty {
            parts.append("\(unsupported.count) \(unsupported.count == 1 ? "uses" : "use") a codec this Mac cannot decode")
        }
        var line = imported == 0 && skippedCount > 0 ? "Nothing imported" : "Imported \(files)"
        if skippedCount > 0 {
            line += imported == 0 ? ": " : ". \(skippedCount) skipped: "
            line += parts.joined(separator: ", ")
        }
        line += "."
        if !audioDropped.isEmpty {
            line += " \(audioDropped.count) imported without sound (audio codec not supported)."
        }
        if canceled { line += " Import canceled." }
        return line
    }
}

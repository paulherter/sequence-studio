import Foundation
import SQUIKit

/// Cmd+V with files or an image on the system pasteboard (a Finder copy, a screenshot, an image copied in a browser).
/// Our own clip clipboard lives in the session, not on the pasteboard, so it keeps priority simply by being non-empty.
public enum PasteMedia {
    public enum Route: Sendable, Equatable {
        /// Existing behavior: the timeline's clip / effect paste (or nothing in the Project panel).
        case ownClipboard
        case importFiles
        case importImage
        case nothing
    }

    /// Pure routing. Media paste only applies with the Project panel or the timeline focused, and only when we hold
    /// no clip data of our own.
    public static func route(target: FocusedEditTarget, hasOwnClipData: Bool, hasFiles: Bool, hasImage: Bool) -> Route {
        guard target == .timeline || target == .project else { return .nothing }
        if hasOwnClipData { return .ownClipboard }
        if hasFiles { return .importFiles }
        if hasImage { return .importImage }
        return .nothing
    }

    public struct Content: Sendable, Equatable {
        public var fileURLs: [URL] = []
        public var imageData: Data?
        public var hasMedia: Bool { !fileURLs.isEmpty || imageData != nil }
        public init(fileURLs: [URL] = [], imageData: Data? = nil) { self.fileURLs = fileURLs; self.imageData = imageData }
    }

    /// `Pasted Image 2026-10-07 14.03.22.png` (numbered when that name is taken).
    public static func imageFileName(date: Date, existing: (String) -> Bool = { _ in false }) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Pasted Image " + f.string(from: date)
        var name = base + ".png", n = 2
        while existing(name) { name = "\(base) \(n).png"; n += 1 }
        return name
    }

    /// Writes PNG data into `folder` (created if needed) and returns the file.
    public static func writeImage(_ png: Data, into folder: URL, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = imageFileName(date: date) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let url = folder.appendingPathComponent(name)
        try png.write(to: url, options: .atomic)
        return url
    }
}

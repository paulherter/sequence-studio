import Foundation

/// Kind of a file shown in the library. Extension based (no UTType dependency).
public enum LibraryItemKind: String, Codable, Sendable, CaseIterable {
    case audio, video, image, overlay, lut, font, other

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "mxf", "webm", "mpg", "mpeg", "mts", "m2ts", "prores"]
    static let audioExtensions: Set<String> = ["wav", "mp3", "aif", "aiff", "aifc", "m4a", "aac", "flac", "caf", "ogg", "opus"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "exr", "dpx", "psd"]
    static let lutExtensions: Set<String> = ["cube", "3dl", "look", "mga", "m3d"]
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2"]

    /// Classify by extension. `hasAlpha` is a hint from a later probe: alpha video or image becomes `.overlay`.
    public static func classify(_ url: URL, hasAlpha: Bool = false) -> LibraryItemKind {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return hasAlpha ? .overlay : .video }
        if imageExtensions.contains(ext) { return hasAlpha ? .overlay : .image }
        if audioExtensions.contains(ext) { return .audio }
        if lutExtensions.contains(ext) { return .lut }
        if fontExtensions.contains(ext) { return .font }
        return .other
    }

    /// True for hidden and OS metadata files.
    public static func isIgnored(fileName: String) -> Bool {
        if fileName.hasPrefix(".") { return true }
        let lower = fileName.lowercased()
        return lower == "thumbs.db" || lower == "desktop.ini"
    }

    /// Kind, or nil when the file is hidden/system.
    public static func classifyIfVisible(_ url: URL, hasAlpha: Bool = false) -> LibraryItemKind? {
        isIgnored(fileName: url.lastPathComponent) ? nil : classify(url, hasAlpha: hasAlpha)
    }
}

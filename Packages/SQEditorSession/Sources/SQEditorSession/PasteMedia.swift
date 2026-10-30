import AppKit

/// The Mac pasteboard reader of `PasteMedia` (the routing and the file writer are portable, `PasteMediaRouting.swift`).
extension PasteMedia {
    /// Reads existing file URLs (preferred) or image data (PNG as is, TIFF converted to PNG) from a pasteboard.
    public static func read(from pb: NSPasteboard = .general) -> Content {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !files.isEmpty { return Content(fileURLs: files) }
        if let png = pb.data(forType: .png) { return Content(imageData: png) }
        if let tiff = pb.data(forType: .tiff), let png = pngData(fromImageData: tiff) { return Content(imageData: png) }
        return Content()
    }

    static func pngData(fromImageData data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }
}

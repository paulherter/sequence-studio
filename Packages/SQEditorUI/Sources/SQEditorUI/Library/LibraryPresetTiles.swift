import AppKit
import SQCore
import SQLibrary
import SQText

/// One cell of the Library's presets section (grid tile or list row): the flat row is what the list and the menus use.
enum LibraryPresetCell {
    case template(TextTemplateCatalog.Entry)
    case user(PresetItem)
}

/// Thumbnails of text templates and saved text presets. Every picture is drawn by the real text renderer
/// (`TextPresetPreview`) in the template's own style over a neutral well, so no two tiles look alike.
@MainActor
final class LibraryPresetThumbs {
    static let pixelWidth = 256, pixelHeight = 160
    private let stills = NSCache<NSString, NSImage>()

    private static let background: [UInt8] = {
        let c = Theme.Colors.tileBackground.usingColorSpace(.sRGB) ?? NSColor.darkGray
        let px = [c.redComponent, c.greenComponent, c.blueComponent].map { UInt8(max(0, min(255, ($0 * 255).rounded()))) } + [255]
        return (0..<pixelWidth * pixelHeight).flatMap { _ in px }
    }()

    private static func image(_ bytes: [UInt8]) -> CGImage? {
        let w = pixelWidth, h = pixelHeight
        guard bytes.count == w * h * 4, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func cached(_ key: String, make: () -> CGImage?) -> NSImage? {
        if let hit = stills.object(forKey: key as NSString) { return hit }
        guard let cg = make() else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        stills.setObject(image, forKey: key as NSString)
        return image
    }

    /// A text style at rest on the well (built-in text templates, saved text presets).
    func styleStill(key: String, style: TextStyle, text: String = TextPresetPreview.sampleText) -> NSImage? {
        cached(key) {
            Self.image(TextPresetPreview.still(style: style, text: text, background: Self.background,
                                               width: Self.pixelWidth, height: Self.pixelHeight))
        }
    }
}

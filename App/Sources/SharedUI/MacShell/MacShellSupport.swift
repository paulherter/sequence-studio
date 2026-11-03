import AppKit
import Metal
import SQCore
import SQUIKit

/// Small Mac-only helpers the shared UI needs (moved out of the AppKit EditorPanels / AppController).
enum MacShellSupport {
    /// A 320 px wide PNG of a rendered frame; nil when the frame cannot be read.
    @MainActor static func thumbnailPNG(_ texture: MTLTexture?) -> Data? {
        guard let texture, let snap = FrameExport.snapshot(of: texture), let full = FrameExport.cgImage(from: snap), full.width > 0 else { return nil }
        let w = min(320, full.width), h = max(1, full.height * w / full.width)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:])
    }

    static func bundledSupporters() -> [String] {
        guard let url = Bundle.main.url(forResource: SupportersList.fileName, withExtension: SupportersList.fileExtension),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return SupportersList.parse(text)
    }
}

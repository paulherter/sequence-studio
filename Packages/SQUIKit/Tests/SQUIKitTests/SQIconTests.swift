import AppKit
import Testing
@testable import SQUIKit

@Suite("SQIcon")
struct SQIconTests {
    @Test("every case loads shapes and renders a non-empty template image")
    func everyCaseRenders() throws {
        for icon in SQIcon.allCases {
            #expect(!SQIconCache.shared.parsed(icon).isEmpty, "no shapes for \(icon.rawValue)")
            let image = icon.image(size: 16)
            #expect(image.isTemplate)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
            NSGraphicsContext.restoreGraphicsState()
            var inked = false
            for y in 0..<32 { for x in 0..<32 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { inked = true } }
            #expect(inked, "\(icon.rawValue) drew nothing")
        }
    }

    @Test("images are cached per size and tinted copies are not templates")
    func cacheAndTint() {
        #expect(SQIcon.play.image(size: 14) === SQIcon.play.image(size: 14))
        #expect(SQIcon.play.image(size: 14) !== SQIcon.play.image(size: 12))
        #expect(!SQIcon.play.image(size: 14, color: .red).isTemplate)
    }

    @Test("arc path data produces a closed round shape")
    func arcs() {
        let path = CGMutablePath()
        SQIconPathData.append("M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Z", to: path)
        let box = path.boundingBox
        #expect(abs(box.width - 18) < 0.1 && abs(box.height - 18) < 0.1)
    }
}

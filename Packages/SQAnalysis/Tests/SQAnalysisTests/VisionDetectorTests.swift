import CoreGraphics
import Foundation
import Testing
@testable import SQAnalysis

extension VisionSuites {
@Suite struct VisionDetectorTests {
    /// Smoke test of the Vision wiring: a flat gray picture has no face or person, and every box is normalized.
    @Test func flatPictureHasNoPeople() throws {
        let ctx = try #require(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let boxes = try VisionSubjectDetector.detect(in: try #require(ctx.makeImage()))
        #expect(!boxes.contains { $0.kind == .face || $0.kind == .body })
        for b in boxes { #expect(b.rect.x >= -1e-6 && b.rect.y >= -1e-6 && b.rect.x + b.rect.width <= 1 + 1e-6) }
    }
}
}

import CoreGraphics
import CoreVideo
import Foundation
import SQCore
import Testing
@testable import SQAnalysis

extension VisionSuites {
@Suite struct PersonSegmenterTests {
    private func buffer(_ w: Int, _ h: Int, format: OSType, fill: (Int, Int, UnsafeMutableRawPointer) -> Void) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, w, h, format, nil, &pb) == kCVReturnSuccess)
        let b = try #require(pb)
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(b)), stride = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<h { for x in 0..<w { fill(x, y, base + y * stride) } }
        return b
    }

    @Test func eightBitMaskConvertsTopDown() throws {
        let b = try buffer(3, 2, format: kCVPixelFormatType_OneComponent8) { x, y, row in
            row.assumingMemoryBound(to: UInt8.self)[x] = y == 0 ? 255 : UInt8(x * 51)
        }
        let m = try #require(PersonSegmenter.matte(from: b))
        #expect(m.width == 3 && m.height == 2)
        #expect(m[0, 0] == 1 && m[2, 0] == 1)
        #expect(abs(m[1, 1] - 0.2) < 1e-6 && m[0, 1] == 0)
    }

    @Test func floatMaskIsClamped() throws {
        let b = try buffer(2, 1, format: kCVPixelFormatType_OneComponent32Float) { x, _, row in
            row.assumingMemoryBound(to: Float.self)[x] = x == 0 ? -0.5 : 1.5
        }
        let m = try #require(PersonSegmenter.matte(from: b))
        #expect(m.values == [0, 1])
    }

    @Test func halfMaskConverts() throws {
        let b = try buffer(3, 1, format: kCVPixelFormatType_OneComponent16Half) { x, _, row in
            row.assumingMemoryBound(to: Float16.self)[x] = [Float16(0.25), 2, -1][x]
        }
        #expect(try #require(PersonSegmenter.matte(from: b)).values == [0.25, 1, 0])
    }

    @Test func quarterTurnsMapToOrientations() {
        #expect(PersonSegmenter.orientation(quarterTurns: 0) == .up)
        #expect(PersonSegmenter.orientation(quarterTurns: 1) == .right)
        #expect(PersonSegmenter.orientation(quarterTurns: 2) == .down)
        #expect(PersonSegmenter.orientation(quarterTurns: 3) == .left)
        #expect(PersonSegmenter.orientation(quarterTurns: 5) == .right)
    }

    /// A landscape buffer stored sideways (portrait phone clip): the matte comes back upright, i.e. portrait.
    @Test func orientationGivesAnUprightMatte() throws {
        let frame = try buffer(160, 90, format: kCVPixelFormatType_32BGRA) { x, _, row in
            let p = row.assumingMemoryBound(to: UInt8.self) + x * 4
            p[0] = 128; p[1] = 128; p[2] = 128; p[3] = 255
        }
        let tracker = SubjectMatteTracker()
        let key = UUID()
        let up = try #require(try tracker.matte(for: frame, orientation: .up, key: key, frameIndex: 0, quality: .fast))
        #expect(up.width >= up.height)
        tracker.reset(key: key)
        let side = try #require(try tracker.matte(for: frame, orientation: .right, key: key, frameIndex: 0, quality: .fast))
        #expect(side.width < side.height, "\(side.width) x \(side.height)")
        // A paused redraw of the same frame comes from the cache.
        #expect(tracker.cached(key: key, frameIndex: 0) == side)
    }

    @Test func otherFormatsAreRefused() throws {
        let b = try buffer(2, 2, format: kCVPixelFormatType_32BGRA) { _, _, _ in }
        #expect(PersonSegmenter.matte(from: b) == nil)
    }

    /// Vision wiring: a flat gray picture has (almost) no person.
    @Test func flatPictureHasNoPerson() throws {
        let ctx = try #require(CGContext(data: nil, width: 128, height: 72, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 72))
        guard let m = try PersonSegmenter.matte(in: try #require(ctx.makeImage()), quality: .fast) else { return }
        #expect(m.width > 0 && m.height > 0)
        #expect(m.area / Double(m.width * m.height) < 0.1)
    }

    @Test func trackerSmoothsPerKey() {
        let tracker = SubjectMatteTracker()
        let a = UUID(), b = UUID()
        let full = SubjectMatte(width: 4, height: 4, values: .init(repeating: 1, count: 16))
        var half = full; for i in 0..<8 { half.values[i] = 0 }
        _ = tracker.smoothed(full, key: a, frameIndex: 0)
        // Clip b starts fresh: its first frame comes back unchanged.
        #expect(tracker.smoothed(half, key: b, frameIndex: 0) == half)
        // Next frame of a, same picture: blending with its own history keeps it; then a reset starts a over.
        #expect(tracker.smoothed(full, key: a, frameIndex: 1) == full)
        tracker.reset(key: a)
        #expect(tracker.smoothed(half, key: a, frameIndex: 2) == half)
    }
}
}

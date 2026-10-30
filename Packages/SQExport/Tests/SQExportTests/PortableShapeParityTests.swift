#if canImport(Metal)
import CoreVideo
import Foundation
import SQCore
import SQRender
import SQText
import Testing

/// Shape clips on the portable raster (Windows, `PortableShapeRenderer`) against the Mac `ShapeRenderer` (Core
/// Graphics): same picture size and covered box, nearly the same pixels for every kind, stroke, gradient and path.
@Suite struct PortableShapeParityTests {
    private let red = EffectColor(red: 1, green: 0, blue: 0)
    private let blue = EffectColor(red: 0, green: 0.2, blue: 1)
    private let white = EffectColor(red: 1, green: 1, blue: 1, alpha: 0.8)

    private func compare(_ st: ShapeStyle, meanBound: Float = 0.004, file: String = #fileID, line: Int = #line) throws {
        let mac = try #require(ShapeRenderer.picture(st))
        let pc = try #require(PortableShapeRenderer.render(st))
        let b = mac.buffer
        let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b)
        #expect(pc.picture.width == w && pc.picture.height == h)
        #expect(abs(pc.width - mac.width) < 1e-9 && abs(pc.height - mac.height) < 1e-9)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(b)!, rowBytes = CVPixelBufferGetBytesPerRow(b)
        var diff: Float = 0, macInk: Float = 0, pcInk: Float = 0
        for y in 0..<min(h, pc.picture.height) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<min(w, pc.picture.width) {
                for k in 0..<4 {
                    let a = Float(row[x * 4 + k]), p = pc.picture.pixels[(y * pc.picture.width + x) * 4 + k]
                    diff += abs(a - p)
                    if k == 3 { macInk += a; pcInk += p }
                }
            }
        }
        let mean = diff / Float(max(1, w * h * 4))
        #expect(mean < meanBound, "mean difference \(mean) (\(st.kind))")
        #expect(abs(pcInk - macInk) <= max(1, macInk * 0.01), "coverage \(pcInk) vs \(macInk) (\(st.kind))")
    }

    @Test func rectanglesWithStrokeAndCorners() throws {
        try compare(ShapeStyle(kind: .rectangle, width: 40, height: 20, fill: red, stroke: white, strokeWidth: 4))
        try compare(ShapeStyle(kind: .rectangle, width: 300, height: 120, cornerRadius: 24, fill: blue, stroke: white,
                               strokeWidth: 7))
    }

    @Test func ellipseArrowAndLine() throws {
        try compare(ShapeStyle(kind: .ellipse, width: 220, height: 140, fill: red, stroke: white, strokeWidth: 5))
        try compare(ShapeStyle(kind: .arrow, width: 260, height: 90, fill: blue, stroke: white, strokeWidth: 3))
        try compare(ShapeStyle(kind: .line, width: 300, height: 6, stroke: red, strokeWidth: 6))
    }

    @Test func gradientAtAnAngle() throws {
        try compare(ShapeStyle(kind: .rectangle, width: 200, height: 100, fill: red, gradientEnd: blue, gradientAngle: 35))
        try compare(ShapeStyle(kind: .ellipse, width: 160, height: 160, fill: red, gradientEnd: blue, gradientAngle: 90))
    }

    @Test func freeformPathsOpenAndClosed() throws {
        let pts = [Vec2(0, 0), Vec2(1, 0.3), Vec2(0.4, 1), Vec2(0.1, 0.6)]
        var closed = ShapeStyle(kind: .rectangle, width: 200, height: 150, fill: blue, stroke: white, strokeWidth: 6)
        closed.path = pts; closed.pathClosed = true
        try compare(closed)
        var open = ShapeStyle(kind: .rectangle, width: 200, height: 150, stroke: red, strokeWidth: 8)
        open.path = pts; open.pathClosed = false
        try compare(open)
    }

    @Test func nothingVisibleDrawsNothing() {
        #expect(PortableShapeRenderer.render(ShapeStyle(kind: .rectangle, width: 40, height: 20)) == nil)
        #expect(PortableShapeRenderer.render(ShapeStyle(kind: .rectangle, width: 0, height: 20, fill: red)) == nil)
    }
}
#endif

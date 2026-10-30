#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Perspective tilt (`ClipTransform.tiltX` / `tiltY`): the compositor places a layer's corners with the same
// `PerspectiveTilt` geometry the overlay and hit-test use, and maps the picture perspective-correctly.

private let (cw, ch) = (160, 120)   // canvas
private let (lw, lh) = (80, 48)     // layer

private func gradient() -> CVPixelBuffer {
    let attrs = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as [CFString: Any]
    var pb: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, lw, lh, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<lh {
        let row = (base + y * stride).assumingMemoryBound(to: Float16.self)
        for x in 0..<lw {
            // Red grows left to right, green top to bottom, opaque.
            let v = SIMD4<Float>((Float(x) + 0.5) / Float(lw), (Float(y) + 0.5) / Float(lh), 0, 1)
            for c in 0..<4 { row[x * 4 + c] = Float16(v[c]) }
        }
    }
    return b
}

private func render(_ transform: ClipTransform) throws -> [Float16]? {
    guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
    let comp = try Compositor(device: dev)
    let format = SequenceFormat(width: cw, height: ch, frameDuration: Time(1, 25))
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: cw, height: ch, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let layer = RenderLayer(content: .linearPremultiplied(gradient(), width: Double(lw), height: Double(lh)), transform: transform)
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: [.layer(layer)], format: format, into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    var out = [Float16](repeating: 0, count: cw * ch * 4)
    t.getBytes(&out, bytesPerRow: cw * 8, from: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0)
    return out
}

private func pixel(_ img: [Float16], _ x: Int, _ y: Int) -> SIMD4<Float> {
    let i = (y * cw + x) * 4
    return SIMD4(Float(img[i]), Float(img[i + 1]), Float(img[i + 2]), Float(img[i + 3]))
}

@Suite struct PerspectiveTiltRenderTests {
    /// Where the layer point `l` (layer px from its center) lands on the canvas, by the shared geometry.
    private func screen(_ l: Vec2, _ t: ClipTransform) -> Vec2 {
        let radius = PerspectiveTilt.layerRadius(size: Vec2(Double(lw), Double(lh)), anchor: t.anchor, scale: t.scale)
        let focal = PerspectiveTilt.focal(layerRadius: radius + 2, canvas: Vec2(Double(cw), Double(ch)))
        let p = PerspectiveTilt.project(l - t.anchor, tiltX: t.tiltX, tiltY: t.tiltY, focal: focal)
        return Vec2(Double(cw) / 2 + t.position.x + p.x, Double(ch) / 2 + t.position.y + p.y)
    }

    @Test func zeroTiltIsTheFlatPicture() throws {
        guard let flat = try render(ClipTransform(scale: Vec2(1.2, 1.2), rotation: 12)) else { return }
        let zero = try render(ClipTransform(scale: Vec2(1.2, 1.2), rotation: 12, tiltX: 0, tiltY: 0))
        #expect(zero == flat)
    }

    @Test func aTiltedLayerLandsWhereTheSharedGeometryPutsIt() throws {
        for (a, b) in [(0.0, 50.0), (35.0, 0.0), (-25.0, 40.0)] {
            let t = ClipTransform(position: Vec2(6, -4), rotation: 10, tiltX: a, tiltY: b)
            guard let img = try render(t) else { return }
            // Layer points through the whole picture: the pixel there carries the picture's own gradient.
            for fx in stride(from: -0.4, through: 0.4, by: 0.2) {
                for fy in stride(from: -0.4, through: 0.4, by: 0.2) {
                    let l = Vec2(fx * Double(lw), fy * Double(lh))
                    // Rotation about the anchor (the center) first, then the tilt: the same order the shader uses.
                    let r = 10.0 * .pi / 180
                    let rot = Vec2(l.x * cos(r) - l.y * sin(r), l.x * sin(r) + l.y * cos(r))
                    let radius = PerspectiveTilt.layerRadius(size: Vec2(Double(lw), Double(lh)), anchor: .zero, scale: Vec2(1, 1))
                    let focal = PerspectiveTilt.focal(layerRadius: radius + 2, canvas: Vec2(Double(cw), Double(ch)))
                    let q = PerspectiveTilt.project(rot, tiltX: a, tiltY: b, focal: focal)
                    let x = Int((Double(cw) / 2 + 6 + q.x).rounded(.down)), y = Int((Double(ch) / 2 - 4 + q.y).rounded(.down))
                    let px = pixel(img, x, y)
                    #expect(px.w > 0.9, "tilt (\(a), \(b)) point (\(fx), \(fy)) is covered")
                    // Perspective-correct mapping: the gradient at the pixel is the one of the layer point.
                    #expect(abs(Double(px.x) - (fx + 0.5)) < 0.06 && abs(Double(px.y) - (fy + 0.5)) < 0.08,
                            "tilt (\(a), \(b)) point (\(fx), \(fy)): got \(px.x), \(px.y)")
                }
            }
            // Far outside the projected quad nothing is drawn.
            #expect(pixel(img, 1, 1).x == 0 && pixel(img, cw - 2, ch - 2).x == 0)
            _ = screen(.zero, t)
        }
    }

    @Test func tiltedCoverageIsNarrowerThanFlat() throws {
        guard let flat = try render(ClipTransform()), let tilted = try render(ClipTransform(tiltY: 60)) else { return }
        func covered(_ img: [Float16]) -> Int { (0..<(cw * ch)).filter { Float(img[$0 * 4]) > 0.01 }.count }
        #expect(covered(tilted) < covered(flat))
        #expect(covered(tilted) > 0)
    }

    @Test func cameraDistanceFollowsThePaddedDrawSize() {
        var u = Compositor.Uniforms()
        u.canvas = SIMD2(1920, 1080); u.scale = SIMD2(1, 1); u.anchor = .zero
        u.size = SIMD2(1920, 1080)
        let plain = Compositor.tiltFocal(u)
        u.size = SIMD2(40_000, 22_000)   // a huge blur or shadow margin
        let padded = Compositor.tiltFocal(u)
        #expect(padded > plain)
        // Farthest corner of the padded picture stays in front of the camera at the largest tilt.
        let radius = hypot(20_000.0, 11_000.0)
        #expect(Double(padded) > radius)
        let w = PerspectiveTilt.depthDivisor(Vec2(20_000, 11_000), tiltX: 89, tiltY: 89, focal: Double(padded))
        #expect(w > 0)
    }
}
#endif

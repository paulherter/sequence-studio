import Foundation
import Testing
#if canImport(simd)
import simd
#endif
@testable import SQRender

/// C3: look thumbnails on a fixed procedural test picture, through the real (CPU reference) color pipeline.
@Suite struct LookThumbnailTests {
    static func identityLUT(_ n: Int = 17) -> CubeLUT {
        var t: [SIMD3<Float>] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            t.append(SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1))
        } } }
        return CubeLUT(kind: .lut3D, size: n, table: t)
    }

    @Test func testPictureHasSkyGreyRampSkinAndSixChips() {
        let w = LookThumbnail.width, h = LookThumbnail.height
        let px = LookThumbnail.testPicture(width: w, height: h)
        #expect(w == 256 && h == 144 && px.count == w * h)
        // Sky: blue dominant at the top, lighter towards the horizon.
        let top = px[2 * w + w / 2], horizon = px[Int(Float(h) * 0.4) * w + w / 2]
        #expect(top.z > top.x && top.z > top.y)
        #expect(horizon.sum() > top.sum())
        // Gray ramp: 11 neutral steps from black to white along the bottom row.
        let row = (h - 2) * w
        let steps = Set((0..<w).map { Int((px[row + $0].x * 10).rounded()) })
        #expect(steps == Set(0...10))
        #expect((0..<w).allSatisfy { abs(px[row + $0].x - px[row + $0].z) < 1e-6 })
        // Middle row: skin patch first, then six saturated chips.
        let mid = Int(Float(h) * 0.6) * w
        let cell = w / 7
        let skin = px[mid + cell / 2]
        #expect(skin.x > skin.y && skin.y > skin.z)
        for i in 1...6 {
            let c = px[mid + i * cell + cell / 2]
            #expect(c.max() - c.min() > 0.6, "chip \(i) \(c)")
        }
        // Deterministic.
        #expect(LookThumbnail.testPicture(width: w, height: h) == px)
    }

    @Test func identityLookReturnsThePictureWithinOneStep() {
        let w = 64, h = 36
        let plain = LookThumbnail.render(lut: nil, width: w, height: h)
        let looked = LookThumbnail.render(lut: Self.identityLUT(), width: w, height: h)
        #expect(plain.count == w * h * 4 && looked.count == plain.count)
        let worst = zip(plain, looked).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 1, "max difference \(worst)/255")
        // The plain render is the test picture itself.
        let pic = LookThumbnail.testPicture(width: w, height: h)
        #expect(plain[0] == LookThumbnail.byte(pic[0].x) && plain[(w * h - 1) * 4 + 2] == LookThumbnail.byte(pic[w * h - 1].z))
    }

    @Test func aLookChangesThePictureAndIntensityBlends() {
        // A look that swaps red and blue.
        let id = Self.identityLUT(9)
        let swapped = CubeLUT(kind: .lut3D, size: 9, table: id.table.map { SIMD3($0.z, $0.y, $0.x) })
        let w = 64, h = 36
        let plain = LookThumbnail.render(lut: nil, width: w, height: h)
        let full = LookThumbnail.render(lut: swapped, width: w, height: h)
        let none = LookThumbnail.render(lut: swapped, intensity: 0, width: w, height: h)
        let diff = zip(plain, full).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(diff > 100)
        #expect((zip(plain, none).map { abs(Int($0) - Int($1)) }.max() ?? 0) <= 1)
        // Sky pixel turns warm under the swap.
        let i = (2 * w + w / 2) * 4
        #expect(full[i] > full[i + 2])
    }
}

#if canImport(Metal)
import Foundation
import Metal
import simd
import Testing
import SQCore
@testable import SQRender

/// Every Color Range (HSL secondary) control, from the model value through `ColorPipeline.from(clipColor:)` (the path
/// preview and export share via `LayerColorResolver`) to the pixels, on the CPU reference and on the GPU. Each test
/// changes one parameter and checks which way the picture moves. A "probe" correction (saturation 0) makes membership
/// visible: a pixel inside the range loses its chroma, a pixel outside keeps it.
/// The range lives in the effect's grade data, so it is not keyframable (decision v48); the section switch is static too.
@Suite struct HSLSecondaryParameterTests {
    // Source-encoded Rec.709 pixels. Hue / saturation (HSV) / luma as the stage sees them: orange 24 deg, 0.625, 0.55.
    static let orange = SIMD3<Float>(0.8, 0.5, 0.3)
    static let yellowish = SIMD3<Float>(0.8, 0.7, 0.3)      // hue 48 deg
    static let pale = SIMD3<Float>(0.8, 0.7, 0.62)          // hue 27 deg, saturation 0.225, brighter than orange
    static let blue = SIMD3<Float>(0.2, 0.3, 0.8)
    static let grey = SIMD3<Float>(0.5, 0.5, 0.5)
    static let probes = [orange, yellowish, pale, blue, grey, orange, orange, orange]

    static func clip(_ edit: (inout HSLSecondary) -> Void, enabled: Bool = true) -> ClipColor {
        var r = HSLSecondary(); r.softness = 0
        edit(&r)
        var c = ClipColor.default
        c.effects[0].hslSecondary = r
        c.effects[0].setEnabled(.hslSecondary, enabled)
        return c
    }
    /// Probe correction: everything the range selects turns gray.
    static func probe(_ edit: (inout HSLSecondary) -> Void = { _ in }) -> ClipColor {
        clip { $0.saturation = 0; edit(&$0) }
    }

    static func pipeline(_ c: ClipColor) -> ColorPipeline {
        ColorPipeline.from(clipColor: c, mediaID: UUID(), mediaInfo: nil, lutProvider: nil)
    }

    /// CPU and GPU output for `probes`.
    static func render(_ c: ClipColor) throws -> (cpu: [SIMD3<Float>], gpu: [SIMD3<Float>]) {
        let p = pipeline(c)
        let cpu = probes.map { p.process($0) }
        guard let device = GPUTest.device else { return (cpu, cpu) }
        let queue = device.makeCommandQueue()!
        let gpu = try ColorPipelineGPUTests.shared(device)
        let w = probes.count
        let s = GPUTest.makeTexture(device, width: w, height: 1, format: .rgba32Float)
        let d = GPUTest.makeTexture(device, width: w, height: 1, format: .rgba32Float)
        GPUTest.upload(s, probes)
        var err: Error?
        _ = GPUTest.run(queue) { do { try gpu.encode(p, source: s, destination: d, commandBuffer: $0) } catch { err = error } }
        if let err { throw err }
        return (cpu, GPUTest.download(d))
    }

    static func chroma(_ v: SIMD3<Float>) -> Float { max(v.x, v.y, v.z) - min(v.x, v.y, v.z) }
    static func luma(_ v: SIMD3<Float>) -> Float { simd_dot(Gamut.rec709.lumaRow, v) }
    /// Hue in degrees.
    static func hue(_ v: SIMD3<Float>) -> Float {
        atan2f(sqrtf(3) * (v.y - v.z), 2 * v.x - v.y - v.z) * 180 / .pi
    }
    static func hueDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        var d = fabsf(hue(a) - hue(b)).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d
    }
    static let gray: Float = 0.01      // below this a pixel counts as desaturated by the probe

    static func expectSelected(_ c: ClipColor, _ i: Int, _ want: Bool, _ what: String) throws {
        let r = try render(c)
        #expect((chroma(r.cpu[i]) < gray) == want, "CPU: \(what)")
        #expect((chroma(r.gpu[i]) < gray) == want, "GPU: \(what)")
    }

    // MARK: Qualifier

    @Test func hueCenterMovesTheRange() throws {
        try Self.expectSelected(Self.probe(), 0, true, "default range takes orange")
        try Self.expectSelected(Self.probe { $0.hueCenter = 220 }, 0, false, "range moved to blue leaves orange")
        try Self.expectSelected(Self.probe { $0.hueCenter = 220 }, 3, true, "range moved to blue takes blue")
        try Self.expectSelected(Self.probe(), 3, false, "default range leaves blue")
    }

    @Test func hueWidthGrowsAndShrinksTheRange() throws {
        // yellowish is 23 degrees from the default center 25.
        try Self.expectSelected(Self.probe { $0.hueWidth = 20 }, 1, false, "narrow range leaves yellow")
        try Self.expectSelected(Self.probe { $0.hueWidth = 70 }, 1, true, "wide range takes yellow")
        try Self.expectSelected(Self.probe { $0.hueWidth = 360; $0.satMin = 0 }, 3, true, "360 degrees takes blue")
        // Grays carry no chroma for the probe to remove, so exposure shows membership.
        let hueRange = try Self.render(Self.clip { $0.exposure = 1 })
        let allHues = try Self.render(Self.clip { $0.exposure = 1; $0.hueWidth = 360; $0.satMin = 0 })
        for (name, h, a) in [("CPU", hueRange.cpu, allHues.cpu), ("GPU", hueRange.gpu, allHues.gpu)] {
            #expect(simd_distance(h[4], Self.pipeline(Self.clip { _ in }).process(Self.grey)) < 1e-4, "\(name): a hue range never takes grays")
            #expect(Self.luma(a[4]) > Self.luma(h[4]) * 1.1, "\(name): 360 degrees takes grays too")
        }
    }

    @Test func saturationRangeLimitsTheKey() throws {
        // orange saturation 0.625, pale 0.225.
        try Self.expectSelected(Self.probe(), 2, true, "default sat min 10 takes pale")
        try Self.expectSelected(Self.probe { $0.satMin = 40 }, 2, false, "raising sat min drops pale")
        try Self.expectSelected(Self.probe { $0.satMin = 40 }, 0, true, "...but keeps orange")
        try Self.expectSelected(Self.probe { $0.satMax = 40 }, 0, false, "lowering sat max drops orange")
        try Self.expectSelected(Self.probe { $0.satMax = 40 }, 2, true, "...but keeps pale")
    }

    @Test func lumaRangeLimitsTheKey() throws {
        // orange luma about 0.55, pale about 0.72 (tone signal).
        try Self.expectSelected(Self.probe { $0.lumMin = 64 }, 0, false, "raising luma min drops orange")
        try Self.expectSelected(Self.probe { $0.lumMin = 64 }, 2, true, "...but keeps the brighter pale")
        try Self.expectSelected(Self.probe { $0.lumMax = 64 }, 2, false, "lowering luma max drops pale")
        try Self.expectSelected(Self.probe { $0.lumMax = 64 }, 0, true, "...but keeps orange")
    }

    @Test func softnessFeathersTheEdge() throws {
        // yellowish is 23 degrees from the center, a 20-degree wide range ends at 10: outside, until the edge softens.
        let hard = try Self.render(Self.probe { $0.hueWidth = 20; $0.softness = 0 })
        let soft = try Self.render(Self.probe { $0.hueWidth = 20; $0.softness = 100 })
        for (name, h, s) in [("CPU", hard.cpu, soft.cpu), ("GPU", hard.gpu, soft.gpu)] {
            let plain = Self.chroma(Self.pipeline(Self.clip { _ in }).process(Self.yellowish))
            #expect(Self.chroma(h[1]) > plain * 0.95, "\(name): hard edge leaves yellow")
            #expect(Self.chroma(s[1]) < Self.chroma(h[1]) * 0.8, "\(name): soft edge takes part of yellow")
            #expect(Self.chroma(s[1]) > 0.0, "\(name): but not all of it")
            #expect(simd_distance(s[3], h[3]) < 1e-4, "\(name): far pixels stay out")
        }
    }

    @Test func invertCorrectsEverythingOutside() throws {
        try Self.expectSelected(Self.probe { $0.invert = true }, 0, false, "inverted range leaves orange")
        try Self.expectSelected(Self.probe { $0.invert = true }, 3, true, "inverted range takes blue")
    }

    // MARK: Correction inside the key

    @Test func hueShiftRotatesTheKeyedHue() throws {
        let base = try Self.render(Self.clip { _ in })
        let plus = try Self.render(Self.clip { $0.hueShift = 120 })
        let minus = try Self.render(Self.clip { $0.hueShift = -120 })
        for (name, b, p, m) in [("CPU", base.cpu, plus.cpu, minus.cpu), ("GPU", base.gpu, plus.gpu, minus.gpu)] {
            #expect(Self.hueDistance(p[0], b[0]) > 60, "\(name): +120 turns the orange")
            #expect(Self.hueDistance(m[0], b[0]) > 60, "\(name): -120 turns it the other way")
            #expect(Self.hueDistance(p[0], m[0]) > 60, "\(name): the two directions differ")
            #expect(simd_distance(p[3], b[3]) < 1e-4, "\(name): blue outside the key is untouched")
        }
    }

    @Test func saturationScalesChromaInsideTheKey() throws {
        let base = try Self.render(Self.clip { _ in })
        let more = try Self.render(Self.clip { $0.saturation = 180 })
        let less = try Self.render(Self.clip { $0.saturation = 40 })
        for (name, b, hi, lo) in [("CPU", base.cpu, more.cpu, less.cpu), ("GPU", base.gpu, more.gpu, less.gpu)] {
            #expect(Self.chroma(hi[0]) > Self.chroma(b[0]) * 1.2, "\(name): 180 raises chroma")
            #expect(Self.chroma(lo[0]) < Self.chroma(b[0]) * 0.8, "\(name): 40 lowers chroma")
            #expect(simd_distance(hi[3], b[3]) < 1e-4 && simd_distance(lo[3], b[3]) < 1e-4, "\(name): outside untouched")
        }
    }

    @Test func exposureBrightensAndDarkensTheKey() throws {
        let base = try Self.render(Self.clip { _ in })
        let up = try Self.render(Self.clip { $0.exposure = 1 })
        let down = try Self.render(Self.clip { $0.exposure = -1 })
        for (name, b, u, d) in [("CPU", base.cpu, up.cpu, down.cpu), ("GPU", base.gpu, up.gpu, down.gpu)] {
            #expect(Self.luma(u[0]) > Self.luma(b[0]) * 1.1, "\(name): +1 stop brightens")
            #expect(Self.luma(d[0]) < Self.luma(b[0]) * 0.9, "\(name): -1 stop darkens")
            #expect(simd_distance(u[3], b[3]) < 1e-4, "\(name): outside untouched")
        }
    }

    @Test func temperatureWarmsAndCoolsTheKey() throws {
        let base = try Self.render(Self.clip { _ in })
        let warm = try Self.render(Self.clip { $0.temperature = 60 })
        let cool = try Self.render(Self.clip { $0.temperature = -60 })
        for (name, b, w, c) in [("CPU", base.cpu, warm.cpu, cool.cpu), ("GPU", base.gpu, warm.gpu, cool.gpu)] {
            #expect(w[0].x / w[0].z > b[0].x / b[0].z, "\(name): + warms (red over blue)")
            #expect(c[0].x / c[0].z < b[0].x / b[0].z, "\(name): - cools")
            #expect(simd_distance(w[3], b[3]) < 1e-4, "\(name): outside untouched")
        }
    }

    @Test func tintMovesGreenMagentaInTheKey() throws {
        let base = try Self.render(Self.clip { _ in })
        let magenta = try Self.render(Self.clip { $0.tint = 60 })
        let green = try Self.render(Self.clip { $0.tint = -60 })
        for (name, b, m, g) in [("CPU", base.cpu, magenta.cpu, green.cpu), ("GPU", base.gpu, magenta.gpu, green.gpu)] {
            #expect(m[0].y / m[0].x < b[0].y / b[0].x, "\(name): + tint pulls green down")
            #expect(g[0].y / g[0].x > b[0].y / b[0].x, "\(name): - tint pushes green up")
            #expect(simd_distance(m[3], b[3]) < 1e-4, "\(name): outside untouched")
        }
    }

    // MARK: Switch, absence

    @Test func sectionSwitchAndMissingRangeLeaveThePictureAlone() throws {
        let off = try Self.render(Self.probe().switched(off: true))
        var none = Self.probe(); none.effects[0].hslSecondary = nil
        let plain = try Self.render(none)
        let on = try Self.render(Self.probe())
        #expect(off.cpu == plain.cpu && off.gpu == plain.gpu, "switch off = no range")
        #expect(Self.chroma(on.cpu[0]) < Self.gray && Self.chroma(plain.cpu[0]) > 0.05, "on takes orange, none does not")
    }

    @Test func qualifierAloneNeverChangesThePicture() throws {
        let plain = try Self.render(Self.clip { _ in })
        var none = ClipColor.default; none.effects[0].hslSecondary = nil
        let ref = try Self.render(none)
        #expect(plain.cpu == ref.cpu && plain.gpu == ref.gpu)
    }
}

private extension ClipColor {
    func switched(off: Bool) -> ClipColor { var c = self; c.effects[0].setEnabled(.hslSecondary, !off); return c }
}
#endif

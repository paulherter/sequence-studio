import Foundation
import Testing
import simd
import SSCore
@testable import SSRender

/// Constant 3D LUT: every input maps to `value` (makes "a LUT was applied" observable).
private func constantLUT(_ value: Float, title: String = "const") -> CubeLUT {
    CubeLUT(title: title, kind: .lut3D, size: 2, table: Array(repeating: SIMD3<Float>(repeating: value), count: 8))
}

final class StubProvider: LUTProvider, @unchecked Sendable {
    var table: [LUTRef: CubeLUT] = [:]
    func lut(for ref: LUTRef) -> CubeLUT? { table[ref] }
}

@Suite struct ClipColorPipelineTests {
    let media = UUID()
    var slog: MediaInfo { MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine, embeddedLUTName: "Look") }
    var slogNoLUT: MediaInfo { MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine) }
    func provider() -> StubProvider {
        let p = StubProvider(); p.table[.embedded(media)] = constantLUT(0.25, title: "embedded"); return p
    }

    @Test func sourceComesFromMediaOrOverride() {
        var c = ClipColor.default
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slogNoLUT, lutProvider: nil).source == .sLog3SGamut3Cine)
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: nil, lutProvider: nil).source == .rec709)
        c.source = .hlgBT2020
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slogNoLUT, lutProvider: nil).source == .hlgBT2020)
    }

    @Test func slog3ClipWithEmbeddedLUTOnAndOff() {
        let p = provider()
        var c = ClipColor.default
        let on = ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: p)
        #expect(on.conversionLUT?.title == "embedded")
        let px = SIMD3<Float>(0.4, 0.45, 0.5)
        let out = on.process(px)
        let expected = TransferFunctions.bt709InverseOETF(SIMD3<Float>(repeating: 0.25))
        #expect(simd_length(out - expected) < 1e-5)

        c.useEmbeddedLUT = false
        let off = ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: p)
        #expect(off.conversionLUT == nil)
        #expect(simd_length(off.process(px) - expected) > 1e-3)   // automatic conversion instead

        // Explicit "no LUT" and bypass behave like off; media without an embedded LUT too.
        c = .default; c.conversionLUT = nil
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: p).conversionLUT == nil)
        c = .default; c.bypassConversionLUT = true
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: p).conversionLUT == nil)
        #expect(ColorPipeline.from(clipColor: .default, mediaID: media, mediaInfo: slogNoLUT, lutProvider: p).conversionLUT == nil)
        // No provider: nothing to load.
        #expect(ColorPipeline.from(clipColor: .default, mediaID: media, mediaInfo: slog, lutProvider: nil).conversionLUT == nil)
    }

    @Test func embeddedLUTIsSkippedWhenSourceIsOverriddenAwayFromSLog3() {
        var c = ClipColor.default
        c.source = .rec709
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: provider()).conversionLUT == nil)
        // An explicit .embedded reference is honoured regardless.
        c.conversionLUT = .embedded(media)
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: provider()).conversionLUT != nil)
    }

    @Test func fileLUTsAndCreativeIntensity() {
        let p = StubProvider()
        p.table[.file("/c.cube")] = constantLUT(0.3, title: "conv")
        p.table[.file("/k.cube")] = constantLUT(0.9, title: "look")
        var c = ClipColor.default
        c.conversionLUT = .file("/c.cube")
        c.creativeLUT = .file("/k.cube")
        c.creativeIntensity = 0.5
        let pipe = ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: p)
        #expect(pipe.conversionLUT?.title == "conv" && pipe.creativeLUT?.title == "look")
        #expect(pipe.creativeIntensity == 0.5)
        let out = pipe.process([0.4, 0.4, 0.4])
        #expect(simd_length(out - TransferFunctions.bt709InverseOETF(SIMD3<Float>(repeating: 0.6))) < 1e-5)

        c.creativeIntensity = 7
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: p).creativeIntensity == 1)
        c.bypassCreativeLUT = true
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: p).creativeLUT == nil)
        // Missing file: no LUT, no crash.
        c.bypassCreativeLUT = false; c.creativeLUT = .file("/missing.cube")
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: p).creativeLUT == nil)
    }

    @Test func correctionRoundTripsIntoThePipeline() {
        var c = ClipColor.default
        c.correction.exposure = 1; c.correction.saturation = 80; c.correction.contrast = 25
        let pipe = ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: nil, lutProvider: nil)
        #expect(pipe.correction == c.correction)
        let direct = ColorPipeline(source: .rec709, correction: c.correction)
        let px = SIMD3<Float>(0.3, 0.5, 0.2)
        #expect(simd_length(pipe.process(px) - direct.process(px)) < 1e-7)

        c.bypassCorrection = true
        let bypassed = ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: nil, lutProvider: nil)
        #expect(bypassed.correction.isNeutral)
    }

    @Test func cachingProviderLoadsOncePerRefAndRetriesFailures() {
        final class Counter: @unchecked Sendable { var n = 0 }
        let count = Counter()
        let cube = Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8)
        let provider = CachingLUTProvider(file: { path in count.n += 1; return path == "/a.cube" ? cube : nil },
                                          embedded: { _ in nil })
        #expect(provider.lut(for: .file("/a.cube")) != nil)
        #expect(provider.lut(for: .file("/a.cube")) != nil)
        #expect(provider.lut(for: .file("/b.cube")) == nil)
        #expect(provider.lut(for: .file("/b.cube")) == nil)
        #expect(count.n == 3)   // a once, b twice: failures are not cached
        #expect(provider.lut(for: .automatic) == nil)
        provider.removeAll()
        _ = provider.lut(for: .file("/a.cube"))
        #expect(count.n == 4)
    }

    @Test func spaceMapping() {
        #expect(SourceColorSpace(.rec709) == .rec709)
        #expect(SourceColorSpace(.sLog3SGamut3Cine) == .sLog3SGamut3Cine)
        #expect(SourceColorSpace(.hlgBT2020) == .hlgBT2020)
    }
}

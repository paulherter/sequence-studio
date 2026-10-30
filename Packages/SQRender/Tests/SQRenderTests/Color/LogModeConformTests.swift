import Foundation
import Testing
#if canImport(simd)
import simd
#endif
import SQCore
@testable import SQRender

/// Per-clip log mode (camera LUT / built-in / off) and the HDR conform step.
@Suite struct LogModeConformTests {
    let media = UUID()
    var slog: MediaInfo { MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine, embeddedLUTName: "Look") }
    var hlg: MediaInfo { MediaInfo(duration: Time(1, 1), detectedColorSpace: .hlgBT2020) }
    func provider() -> StubProvider {
        let p = StubProvider()
        p.table[.embedded(media)] = CubeLUT(title: "e", kind: .lut3D, size: 2, table: Array(repeating: SIMD3<Float>(repeating: 0.25), count: 8))
        return p
    }

    @Test func builtInIgnoresTheCameraLUT() {
        var c = ClipColor.default
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: provider()).conversionLUT != nil)
        c.logMode = .builtIn
        let p = ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: provider())
        #expect(p.conversionLUT == nil && p.source == .sLog3SGamut3Cine)
    }

    @Test func offPassesLogThroughAsRec709() {
        var c = ClipColor.default
        c.logMode = .off
        let p = ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: provider())
        #expect(p.source == .rec709 && p.conversionLUT == nil && p.isIdentity)
    }

    @Test func offDoesNotTouchHDRSources() {
        var c = ClipColor.default
        c.logMode = .off
        #expect(ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: hlg, lutProvider: nil).source == .hlgBT2020)
    }

    @Test func conformOffSkipsTheToneMapOfHDRSourcesOnly() {
        var on = ClipColor.default
        let bright = SIMD3<Float>(0.9, 0.9, 0.9)   // HLG signal well above SDR white
        let mapped = ColorPipeline.from(clipColor: on, mediaID: media, mediaInfo: hlg, lutProvider: nil)
        on.hdrConform = false
        let raw = ColorPipeline.from(clipColor: on, mediaID: media, mediaInfo: hlg, lutProvider: nil)
        #expect(mapped.skipsToneMap == false && raw.skipsToneMap)
        #expect(raw.process(bright).x > mapped.process(bright).x)
        // Log sources keep their roll-off: the switch is for HLG / PQ.
        let log = ColorPipeline.from(clipColor: on, mediaID: media, mediaInfo: slog, lutProvider: nil)
        #expect(!log.skipsToneMap)
        on.hdrConform = true
        #expect(!ColorPipeline.from(clipColor: on, mediaID: media, mediaInfo: nil, lutProvider: nil).skipsToneMap)
    }

    @Test func hdrTargetKeepsTheHDRRangeOfHDRSourcesOnly() {
        let bright = SIMD3<Float>(0.9, 0.9, 0.9)
        for t in [TargetSpace.rec2020PQ, .rec2020HLG] {
            var c = ClipColor.default
            c.targetSpace = t
            let hdr = ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: hlg, lutProvider: nil)
            let sdr = ColorPipeline.from(clipColor: .default, mediaID: media, mediaInfo: hlg, lutProvider: nil)
            #expect(hdr.skipsToneMap && hdr.process(bright).x > sdr.process(bright).x)
            #expect(!ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: slog, lutProvider: nil).skipsToneMap)
        }
        var c = ClipColor.default
        c.targetSpace = .rec2020
        #expect(!ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: hlg, lutProvider: nil).skipsToneMap)
    }

    @Test func conformOffReachesTheGPUConversionSection() {
        var c = ClipColor.default
        c.hdrConform = false
        let off = ColorPipeline.from(clipColor: c, mediaID: media, mediaInfo: hlg, lutProvider: nil)
        let on = ColorPipeline.from(clipColor: .default, mediaID: media, mediaInfo: hlg, lutProvider: nil)
        #expect(ColorPipelineGPU.conversionToneMapFlag(off) < 0 && ColorPipelineGPU.conversionToneMapFlag(on) >= 0)
    }
}

@Suite struct HDRConformMathTests {
    let grey = SIMD3<Float>(repeating: 0.5)

    @Test func hlgToPQKeepsDisplayLight() {
        let hlg = TransferFunctions.hlgEncode(SIMD3(repeating: 1))        // reference white as HLG
        let pq = HDRConform.convert(hlg, .hlgToPQ)
        let light = TransferFunctions.pqDecode(pq)
        #expect(abs(light.x - 1) < 1e-3)
    }

    @Test func pqToHLGRoundTripsAndClipsAboveHLGPeak() {
        let pq = TransferFunctions.pqEncode(SIMD3(repeating: 2))
        let back = HDRConform.convert(HDRConform.convert(pq, .pqToHLG), .hlgToPQ)
        #expect(simd_length(back - pq) < 1e-3)
        let tooBright = TransferFunctions.pqEncode(SIMD3(repeating: 20))
        #expect(HDRConform.convert(tooBright, .pqToHLG).x <= 1.0001)
    }

    @Test func sdrToHLGPlacesWhiteByReference() {
        let white = SIMD3<Float>(repeating: 1)                           // SDR white, linear
        let at75 = HDRConform.convert(white, .sdrToHLG(.percent75))
        let at100 = HDRConform.convert(white, .sdrToHLG(.percent100))
        #expect(abs(at75.x - 0.75) < 5e-3)
        #expect(abs(at100.x - 1.0) < 5e-3)
    }

    @Test func sdrToPQPlacesWhiteAtThePeak() {
        let white = SIMD3<Float>(repeating: 1)
        let p = HDRConform.convert(white, .sdrToPQ(peakNits: 400))
        #expect(abs(TransferFunctions.pqDecode(p).x * TransferFunctions.pqReferenceWhite - 400) < 2)
        let d = HDRConform.convert(white, .sdrToPQ(peakNits: 0))   // clamped to a sane minimum
        #expect(d.x > 0)
    }

    @Test func hdrToSDRMatchesTheConversionToneMap() {
        let sig = TransferFunctions.hlgEncode(SIMD3(repeating: 2))
        let sdr = HDRConform.convert(sig, .hlgToSDR)                      // linear Rec.709 primaries, 0...1
        let expected = ToneMapping().apply(SIMD3(repeating: 2), peak: SourceColorSpace.hlgBT2020.toneMapPeak)
        #expect(simd_length(sdr - expected) < 1e-3)
    }

    @Test func kindForPairsOfTransfers() {
        #expect(HDRConform.kind(from: .hlgBT2020, to: .rec709) == .hlgToSDR)
        #expect(HDRConform.kind(from: .pqBT2020, to: .rec709) == .pqToSDR)
        #expect(HDRConform.kind(from: .rec709, to: .rec2020HLG) == .sdrToHLG(.percent75))
        #expect(HDRConform.kind(from: .rec709, to: .rec2020PQ) == .sdrToPQ(peakNits: 203))
        #expect(HDRConform.kind(from: .hlgBT2020, to: .rec2020PQ) == .hlgToPQ)
        #expect(HDRConform.kind(from: .pqBT2020, to: .rec2020HLG) == .pqToHLG)
        #expect(HDRConform.kind(from: .hlgBT2020, to: .rec2020HLG) == nil)
        #expect(HDRConform.kind(from: .rec709, to: .rec709) == nil)
        #expect(HDRConform.kind(from: .appleLog, to: .rec2020PQ) == nil)   // log goes through its own conversion
    }
}

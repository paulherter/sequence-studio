import Foundation
#if canImport(simd)
import simd
#endif
import Testing
import SQCore
@testable import SQRender

/// Zone Board and color-volume mask maths on the tone signal.
@Suite struct ZoneBoardStageTests {
    static func board(_ f: (inout ZoneBoard) -> Void) -> PreparedZoneBoard {
        var z = ZoneBoard(); f(&z)
        return PreparedZoneBoard(z, gamut: .rec709)
    }
    static let px: [SIMD3<Float>] = [[0.1, 0.1, 0.1], [0.5, 0.4, 0.3], [0.9, 0.8, 0.7], [0.2, 0.6, 0.3]]

    @Test func freshBoardDoesNothing() {
        let b = Self.board { _ in }
        for c in Self.px { #expect(simd_length(b.apply(c, pre: false) - c) < 1e-6) }
    }

    @Test func globalSaturationZeroMakesGray() {
        let b = Self.board { $0.global.saturation = 0 }
        let o = b.apply(SIMD3(0.8, 0.3, 0.2), pre: false)
        #expect(abs(o.x - o.y) < 1e-5 && abs(o.y - o.z) < 1e-5)
    }

    @Test func shadowsExposureMovesShadowsMoreThanHighlights() {
        let b = Self.board { $0.shadows.exposure = 1 }
        let dark = b.apply(SIMD3(repeating: 0.1), pre: false).x - 0.1
        let bright = b.apply(SIMD3(repeating: 0.95), pre: false).x - 0.95
        #expect(dark > 0.02 && abs(bright) < dark * 0.2)
    }

    @Test func highlightsPuckTintsBrightColorsOnly() {
        let b = Self.board { $0.highlights = ZoneSetting(puckX: 1, puckY: 0.5) }   // pushes toward red
        let bright = b.apply(SIMD3(repeating: 0.9), pre: false)
        let dark = b.apply(SIMD3(repeating: 0.05), pre: false)
        #expect(bright.x - bright.z > 0.05)
        #expect(abs(dark.x - dark.z) < 0.005)
    }

    @Test func volumeMaskIsAballAroundTheCenter() {
        var r = HSLSecondary()
        r.maskMode = .volume; r.hueCenter = 0; r.volumeSat = 80; r.volumeLum = 26; r.volumeRadius = 20; r.softness = 0
        let s = PreparedHSLSecondary(r, gamut: .rec709)
        #expect(s.mask(SIMD3(0.7, 0.14, 0.14)) > 0.99)           // red, sat 0.8, luma 0.26: the center
        #expect(s.mask(SIMD3(0.14, 0.14, 0.7)) == 0)             // blue: far away on the hue circle
        #expect(s.mask(SIMD3(0.5, 0.5, 0.5)) == 0)               // gray axis is 0.8 from the center
        r.invert = true
        #expect(PreparedHSLSecondary(r, gamut: .rec709).mask(SIMD3(0.14, 0.14, 0.7)) == 1)
    }

    @Test func volumeModeIgnoresTheRanges() {
        var a = HSLSecondary(); a.maskMode = .volume
        var b = a; b.hueWidth = 10; b.satMin = 50; b.lumMin = 40
        let c = SIMD3<Float>(0.6, 0.4, 0.3)
        #expect(PreparedHSLSecondary(a, gamut: .rec709).mask(c) == PreparedHSLSecondary(b, gamut: .rec709).mask(c))
    }

    @Test func clipChainEmitsTheBoardOnlyWhenEnabledAndNotNeutral() {
        var c = ClipColor.default
        var e = c.effects[0]
        e.zoneBoard = ZoneBoard()
        c.effects[0] = e
        func hasBoard(_ c: ClipColor) -> Bool {
            ColorPipeline.from(clipColor: c, mediaID: UUID(), mediaInfo: nil, lutProvider: nil).ops.contains {
                if case .zoneBoard = $0 { true } else { false } }
        }
        #expect(!hasBoard(c))
        e.zoneBoard?.global.saturation = 0.2
        c.effects[0] = e
        #expect(hasBoard(c))
        e.setEnabled(.zoneBoard, false)
        c.effects[0] = e
        #expect(!hasBoard(c))
    }
}

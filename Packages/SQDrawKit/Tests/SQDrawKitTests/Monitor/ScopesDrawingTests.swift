import Foundation
import Testing
import SQGPUKernels
@testable import SQDrawKit

@Suite("ScopesDrawing") struct ScopesDrawingTests {
    /// A flat mid-gray picture (every pixel R'G'B' 0.5) binned into a small layout.
    static func gray() -> ScopeCounts {
        var c = ScopeCounts(layout: ScopeLayout(waveformWidth: 64, waveformLevels: 64, vectorscopeSize: 64))
        for x in 0..<64 { ScopeBinning.add(SIMD3(0.5, 0.5, 0.5), luma: 0.5, x: x, width: 64, to: &c) }
        ScopeBinning.finish(&c)
        return c
    }
    static func green(_ img: RGBAImage, _ x: Int, _ y: Int) -> UInt8 { img.pixels[(y * img.width + x) * 4 + 1] }

    @Test func rgbaMatchesNV12ForGray() {
        // Mid gray: RGBA 128 and full-range NV12 luma 128 with neutral chroma land in the same bins.
        let rgba = ScopeBinning.compute(rgba: [UInt8](repeating: 128, count: 4 * 4 * 4), width: 4, height: 4, layout: ScopeLayout())
        let nv12 = ScopeBinning.compute(nv12: [UInt8](repeating: 128, count: 4 * 4 * 3 / 2), width: 4, height: 4, fullRange: true,
                                        layout: ScopeLayout())
        #expect(rgba.waveformLuma == nv12.waveformLuma)
        #expect(rgba.vectorscope == nv12.vectorscope)
        #expect(rgba.maxWaveformLuma == 4)
    }

    @Test func boxLayoutMatchesMacBoard() {
        let s = CGSize(width: 300, height: 170)
        #expect(ScopeBoxLayout.plot(.waveform, in: s) == CGRect(x: 26, y: 8, width: 268, height: 154))
        #expect(ScopeBoxLayout.plot(.histogram, in: s) == CGRect(x: 6, y: 6, width: 288, height: 148))
        let v = ScopeBoxLayout.plot(.vectorscope, in: s)
        #expect(abs(v.width - 170 * 0.92) < 0.001 && v.midX.rounded() == 150)
        let enough: CGFloat = 378
        #expect(ScopeBoxLayout.showsTwo(height: enough, popup: 22))
        #expect(!ScopeBoxLayout.showsTwo(height: 300, popup: 22))
    }

    @Test func waveformTraceSitsAtItsLevel() {
        let img = ScopeImage.render(.waveform, Self.gray(), width: 64, height: 64)
        // Level 0.5 of 64 levels is row 31 from the top (row 0 = 100 %); far rows stay background (12/255).
        #expect(Self.green(img, 32, 31) > 200)
        #expect(Self.green(img, 32, 5) == 12)
        #expect(Self.green(img, 32, 60) == 12)
    }

    @Test func vectorscopeGrayIsCenterDot() {
        let img = ScopeImage.render(.vectorscope, Self.gray(), width: 64, height: 64)
        #expect(Self.green(img, 32, 32) > 100)
        #expect(Self.green(img, 4, 4) == 12)
    }

    @Test func histogramFillsOnlyItsBin() {
        let img = ScopeImage.render(.histogram, Self.gray(), width: 256, height: 64)
        let bottom = 63
        // Bin 128 (value 0.5) is full height in all four rows: R+G+B+Y add up to near white at the bottom.
        #expect(Self.green(img, 128, bottom) > 200 && Self.green(img, 128, 1) > 200)
        #expect(Self.green(img, 20, bottom) == 12)
    }

    @Test func overlayDrawsEveryKind() {
        for k in ScopeKind.allCases {
            var c = Canvas(width: 300, height: 200, atlas: nil, scale: 1)
            ScopeOverlay.draw(&c, k, box: CGRect(x: 0, y: 0, width: 300, height: 200), theme: DrawTheme())
            #expect(!c.list.quads.isEmpty, "\(k)")
        }
    }
}

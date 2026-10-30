import AppKit
import Testing
@testable import SQEditorUI

@MainActor @Suite struct SplashTitleTests {
    @Test func linePitchEqualsDesignLineHeight() {
        #expect(SplashTitle.baseline(1) - SplashTitle.baseline(0) == 62)   // pip-startbild: font-size 62, line-height 1
        let h = StartupSplashWindow().titleLayers.map(\.frame)
        #expect(h.count == 2)
        #expect(abs((h[0].minY - h[1].minY) - 62) < 0.01)   // layers sit one pitch apart (y up)
    }

    @Test func eachLayerContainsItsFullLine() {
        let f = SplashTitle.font
        for i in 0..<2 {
            let fr = SplashTitle.frame(line: i, windowHeight: 500)
            let baselineY = 500 - SplashTitle.baseline(i)   // y-up
            #expect(fr.minY <= baselineY + f.descender)     // descender fits below the baseline
            #expect(fr.maxY >= baselineY + f.ascender)      // ascender fits above
            let needed = SplashTitle.attributed(SplashTitle.lines[i]).size()
            #expect(fr.width >= needed.width)
        }
    }

    @Test func titleEndsClearlyAboveVersion() {
        #expect(SplashTitle.versionTop - SplashTitle.inkBottom >= 8)
        // Even with a descender the block must not reach the version text.
        #expect(SplashTitle.versionTop - (SplashTitle.baseline(1) - SplashTitle.font.descender) >= 2)
    }
}

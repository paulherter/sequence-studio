import AppKit
import Testing
@testable import SSEditorUI

private func rgba(_ c: NSColor) -> [Int] {
    let s = c.usingColorSpace(.sRGB)!
    return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent].map { Int(($0 * 255).rounded()) }
}

@Suite struct ThemeTests {
    @Test func hexValues() {
        #expect(rgba(Theme.Colors.accent) == [0x0A, 0x84, 0xFF, 255])
        #expect(rgba(Theme.Colors.accentFill) == [0x0A, 0x6C, 0xF0, 255])
        #expect(rgba(Theme.Colors.clipVideo) == [0x3D, 0x67, 0xB8, 255])
        #expect(rgba(Theme.Colors.clipAudioWave) == [0x9F, 0xD9, 0x8A, 255])
        #expect(rgba(Theme.Colors.clipCaptionEdge) == [0x9C, 0x82, 0xE4, 255])
        #expect(rgba(Theme.Colors.viewer) == [0x0C, 0x0C, 0x0C, 255])
        #expect(rgba(Theme.Colors.curveY) == [0x64, 0xD2, 0xFF, 255])
    }

    @Test func alphaTokens() {
        #expect(rgba(Theme.Colors.label) == [255, 255, 255, 219])      // 86 %
        #expect(rgba(Theme.Colors.label3) == [255, 255, 255, 117])     // 46 %
        #expect(rgba(Theme.Colors.accentTint)[3] == 56)                // 22 %
        #expect(rgba(Theme.Colors.menu) == [0x22, 0x22, 0x22, 242])    // 95 %
        #expect(rgba(Theme.Colors.clipShade) == [0, 0, 0, 56])
    }

    @Test func scalesMatchDesign() {
        #expect(Theme.Spacing.scale == [2, 4, 8, 12, 16, 24])
        #expect(Theme.Spacing.iconToLabel == 6)
        #expect(Theme.Spacing.paneDivider == 1)
        #expect(Theme.Radius.scale == [3, 4, 5, 6, 8, 10, 12, 16])
        #expect(Theme.Radius.capsule(forHeight: 22) == 11)
    }

    @Test func metricsAndFonts() {
        #expect(Theme.Metrics.toolbar == 52 && Theme.Metrics.statusBar == 22 && Theme.Metrics.panelHeader == 30)
        #expect(Theme.Metrics.effectControlsRow == 24 && Theme.Metrics.listRow == 22)
        #expect(Theme.Metrics.controlHeight == 20 && Theme.Metrics.pushButton == 22)
        #expect(Theme.Metrics.trackV1 == 32 && Theme.Metrics.trackA1 == 26 && Theme.Metrics.trackOther == 20)
        #expect(Theme.Metrics.trackHeader == 124 && Theme.Metrics.toolColumn == 38)
        #expect(Theme.Fonts.mini.pointSize == 10 && Theme.Fonts.small.pointSize == 11)
        #expect(Theme.Fonts.body.pointSize == 13 && Theme.Fonts.timecode.pointSize == 18)
        #expect(Theme.Fonts.clip.pointSize == 9.5 && Theme.Fonts.meter.pointSize == 9)
    }
}

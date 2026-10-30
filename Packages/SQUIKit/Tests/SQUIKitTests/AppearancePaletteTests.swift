import XCTest
@testable import SQUIKit

final class AppearancePaletteTests: XCTestCase {
    func testContrastRatioMatchesWCAG() {
        XCTAssertEqual(PaletteColor(hex: 0xFFFFFF).contrast(with: PaletteColor(hex: 0x000000)), 21, accuracy: 0.01)
        XCTAssertEqual(PaletteColor(hex: 0x777777).contrast(with: PaletteColor(hex: 0xFFFFFF)), 4.48, accuracy: 0.01)
    }

    func testDarkDefaultKeepsTheAppValues() {
        let p = AppearancePalette.resolve(.standard)
        XCTAssertEqual(p.panel, PaletteColor(hex: 0x1E1E21))
        XCTAssertEqual(p.titlebar, PaletteColor(hex: 0x232326))
        XCTAssertEqual(p.content, PaletteColor(hex: 0x19191C))
        XCTAssertEqual(p.timeline, PaletteColor(hex: 0x151518))
        XCTAssertEqual(p.overlay, PaletteColor(hex: 0x2A2A2E))
        XCTAssertEqual(p.divider, PaletteColor(hex: 0x080809))
        XCTAssertEqual(p.label, PaletteColor(hex: 0xE6E6E8))
        XCTAssertEqual(p.label2, PaletteColor(hex: 0xB2B2B8))
        XCTAssertEqual(p.label3, PaletteColor(hex: 0x9C9CA2))
        XCTAssertEqual(p.accent, PaletteColor(hex: 0xA56BFF))
        XCTAssertEqual(p.accentFill, PaletteColor(hex: 0x7C3AED))
    }

    func testLightIsDerivedAndUsesTheFilledAccent() {
        let p = AppearancePalette.resolve(AppearanceSettings(mode: .light))
        XCTAssertEqual(p.panel, PaletteColor(hex: 0xFFFFFF))
        XCTAssertEqual(p.accent, PaletteColor(hex: 0x7A33E0))
        XCTAssertEqual(p.accentFill, PaletteColor(hex: 0x7C3AED))
        XCTAssertLessThan(p.label.luminance, 0.05)
        XCTAssertGreaterThanOrEqual(PaletteColor.white.contrast(with: p.accentFill), 4.5)
    }

    func testTextReachesFourPointFiveEverywhere() {
        for mode in AppearanceMode.allCases {
            for bg in AppearanceSettings.backgroundRange {
                for ct in stride(from: 0, through: 100, by: 5) {
                    let s = AppearanceSettings(mode: mode, background: bg, contrast: ct)
                    let p = AppearancePalette.resolve(s)
                    XCTAssertGreaterThanOrEqual(p.lowestTextContrast, 4.5, "\(s)")
                }
            }
        }
    }

    func testContrastSpreadsSurfacesFromTheCanvas() {
        let low = AppearancePalette.resolve(AppearanceSettings(contrast: 0))
        let high = AppearancePalette.resolve(AppearanceSettings(contrast: 100))
        XCTAssertLessThan(low.overlay.contrast(with: low.canvas), high.overlay.contrast(with: high.canvas))
        let darker = AppearancePalette.resolve(AppearanceSettings(background: -6))
        XCTAssertLessThan(darker.panel.luminance, AppearancePalette.resolve(.standard).panel.luminance)
    }

    func testSettingsClampAndPersist() {
        let s = AppearanceSettings(mode: .light, background: 40, contrast: -3)
        XCTAssertEqual(s.background, 6)
        XCTAssertEqual(s.contrast, 0)
        let d = UserDefaults(suiteName: "sq.appearance.test")!
        d.removePersistentDomain(forName: "sq.appearance.test")
        XCTAssertEqual(AppearanceSettings(defaults: d), .standard)
        s.save(to: d)
        XCTAssertEqual(d.string(forKey: "sq.appearance.mode"), "light")
        XCTAssertEqual(AppearanceSettings(defaults: d), s)
        d.removePersistentDomain(forName: "sq.appearance.test")
    }
}

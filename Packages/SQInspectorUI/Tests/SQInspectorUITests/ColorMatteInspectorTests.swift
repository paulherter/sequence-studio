import Foundation
import AppKit
import Testing
import SQCore
@testable import SQInspectorUI

@MainActor @Suite struct ColorMatteInspectorTests {
    @Test func sectionResolvesForAMatteAndLeads() {
        let matte = Clip(name: "m", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero,
                         generator: .solid(rgb: [1, 2, 3]))
        #expect(ClipSectionMode.resolve(matte) == .matte)
        #expect(ClipSectionMode.matte.title == "Color Matte" && ClipSectionMode.matte.leads)
    }

    @Test func rowShowsAndReportsTheColor() {
        let v = ColorMatteInspectorView()
        var got: [ColorMatteColor] = []
        v.onColorChange = { got.append($0) }
        v.show(ColorMatteColor(r: 255, g: 128, b: 0))
        #expect(got.isEmpty)
        #expect(ColorMatteInspectorView.hexString(ColorMatteColor(r: 255, g: 128, b: 0)) == "#FF8000")
        v.well.color = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        _ = v.well.sendAction(v.well.action, to: v.well.target)
        #expect(got == [ColorMatteColor(r: 0, g: 255, b: 0)])
    }
}

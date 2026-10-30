import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Color Range (HSL secondary) in the Color panel: editing creates the range, Reset Color Range removes it.
@MainActor @Suite struct ColorRangePanelTests {
    @Test func firstEditCreatesTheRangeWithSkinToneDefaults() {
        let m = ColorInspectorModel()
        var changes = 0
        m.onChange = { _ in changes += 1 }
        #expect(m.colorRange(1) == nil)
        #expect(m.rangeValue(1, .saturation) == 100 && m.rangeValue(1, .hueCenter) == 25, "defaults show before a range exists")
        m.setRange(1, .saturation, 60)
        var want = HSLSecondary(); want.saturation = 60
        #expect(m.colorRange(1) == want)
        #expect(changes == 1)
        m.setRange(1, .hueShift, 500)
        #expect(m.rangeValue(1, .hueShift) == 180, "values are clamped to the row range")
        m.setRangeInvert(1, true)
        #expect(m.colorRange(1)?.invert == true)
        m.resetRangeParameter(1, .saturation)
        #expect(m.rangeValue(1, .saturation) == 100)
    }

    @Test func resettingAValueWithoutARangeCreatesNothing() {
        let m = ColorInspectorModel()
        var changes = 0
        m.onChange = { _ in changes += 1 }
        m.resetRangeParameter(1, .saturation)
        #expect(m.colorRange(1) == nil, "a double-click on a default value must not create a range (or a v48 file)")
        #expect(changes == 0, "no undo step")
    }

    @Test func minAndMaxNeverCross() {
        let m = ColorInspectorModel()
        m.setRange(1, .satMax, 40)
        m.setRange(1, .satMin, 70)
        #expect(m.rangeValue(1, .satMin) == 70 && m.rangeValue(1, .satMax) == 70, "raising the minimum pushes the maximum")
        m.setRange(1, .lumMin, 50)
        m.setRange(1, .lumMax, 20)
        #expect(m.rangeValue(1, .lumMin) == 20 && m.rangeValue(1, .lumMax) == 20, "lowering the maximum pushes the minimum")
    }

    @Test func resetColorRangeIsEnabledOnlyWithARangeAndRemovesIt() {
        let m = ColorInspectorModel()
        func rangeEntry() -> Bool? { m.sectionResets(1).first { $0.kind == .hslSecondary }?.enabled }
        #expect(rangeEntry() == false)
        m.setRange(1, .exposure, 0.5)
        #expect(rangeEntry() == true)
        m.resetSection(1, .hslSecondary)
        #expect(m.colorRange(1) == nil && rangeEntry() == false)
        // The section toggle works like the others.
        m.setEnabled(1, .hslSecondary, false)
        #expect(!m.isEnabled(1, .hslSecondary))
    }

    static func sections(_ v: NSView) -> [ColorSectionView] {
        var out: [ColorSectionView] = []
        if let s = v as? ColorSectionView { out.append(s) }
        for sub in v.subviews { out += sections(sub) }
        return out
    }

    @Test func panelShowsTheRangeRowsAndEditsReachTheModel() throws {
        let m = ColorInspectorModel()
        let view = ColorInspectorView(model: m)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 900)
        view.refresh()
        m.setCollapsed(ColorPanelKey(1, .hslSecondary), false)
        view.refresh()
        let section = try #require(Self.sections(view).first { $0.effect == 1 && $0.kind == .hslSecondary })
        #expect(section.header.toggle.isEnabled)
        #expect(Set(section.groups.keys) == ["Range", "Correction"])
        #expect(section.rangeRows.count == ColorRangeParam.allCases.count)
        let sat = try #require(section.rangeRows[.saturation])
        sat.onBegin?(); sat.onSet?(50); sat.onEnd?()
        view.refresh()
        #expect(m.colorRange(1)?.saturation == 50 && sat.slider.value == 50)
        let invert = try #require(section.rangeInvert)
        invert.state = .on
        _ = invert.sendAction(invert.action, to: invert.target)
        #expect(m.colorRange(1)?.invert == true)
        m.resetSection(1, .hslSecondary)
        view.refresh()
        #expect(sat.slider.value == 100 && invert.state == .off)
    }

    /// Every row of the section writes its own field of the effect's range (and nothing else), and shows it again.
    @Test func everyRowWritesExactlyItsOwnField() throws {
        let m = ColorInspectorModel()
        let view = ColorInspectorView(model: m)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 900)
        view.refresh()
        m.setCollapsed(ColorPanelKey(1, .hslSecondary), false)
        view.refresh()
        let section = try #require(Self.sections(view).first { $0.effect == 1 && $0.kind == .hslSecondary })
        let pairs: [ColorRangeParam] = [.satMin, .satMax, .lumMin, .lumMax]
        for p in ColorRangeParam.allCases {
            let row = try #require(section.rangeRows[p])
            let before = m.colorRange(1) ?? HSLSecondary()
            let v = min(max(p.read(before) == p.neutral ? p.neutral + 7 : p.neutral, p.range.lowerBound), p.range.upperBound)
            row.onBegin?(); row.onSet?(v); row.onEnd?()
            view.refresh()
            let after = try #require(m.colorRange(1))
            #expect(p.read(after) == v, "\(p.title) reaches the model")
            #expect(row.slider.value == Double(v), "\(p.title) is shown again")
            for q in ColorRangeParam.allCases where q != p && !(pairs.contains(p) && pairs.contains(q)) {
                #expect(q.read(after) == q.read(before), "\(p.title) must not change \(q.title)")
            }
        }
    }
}

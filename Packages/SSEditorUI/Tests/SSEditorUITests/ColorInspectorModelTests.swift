import Foundation
import Testing
import SSCore
import SSRender
@testable import SSEditorUI

@MainActor @Suite struct ColorInspectorModelTests {
    func model() -> ColorInspectorModel {
        let m = ColorInspectorModel()
        m.recents = RecentLUTs(defaults: UserDefaults(suiteName: "ColorInspectorModelTests-\(UUID())")!)
        return m
    }
    var basicID: Int { 1 }
    var lutID: Int { 2 }

    @Test func defaultStackIsBasicCorrectionThenInputLUT() {
        let m = model()
        #expect(m.sections.map(\.kind) == [.basicCorrection, .inputLUT])
        #expect(m.lutChoice(lutID) == .automatic)
        #expect(m.color.isDefault)
        #expect(m.source == .rec709)
    }

    @Test func sliderSpecsFollowLumetri() {
        #expect(ColorParam.layout(for: .basicCorrection).flatMap(\.params).map(\.title) ==
                ["Temperature", "Tint", "Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks", "Saturation", "Vibrance"])
        #expect(ColorParam.saturation.neutral == 100 && ColorParam.saturation.range == 0...200)
        #expect(ColorParam.exposure.range == -5...5 && ColorParam.exposure.decimals == 2)
        #expect(ColorParam.vignetteMidpoint.neutral == 50 && ColorParam.vignetteFeather.neutral == 50)
        #expect(ColorParam.lookIntensity.neutral == 100)
        // Every slider reads and writes exactly its own block and round-trips its neutral.
        for p in ColorParam.allCases {
            let kind: ColorSectionKind = switch p {
            case .temperature, .tint, .exposure, .contrast, .highlights, .shadows, .whites, .blacks, .saturation, .vibrance: .basicCorrection
            case .lookIntensity, .fadedFilm, .creativeVibrance, .creativeSaturation, .tintBalance: .creative
            case .wheelsSaturation: .wheels
            case .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather: .vignette
            }
            var params = ColorSectionParams.defaults(for: kind)
            #expect(p.read(params) == p.neutral, "\(p) default is its neutral")
            #expect(p.write(p.range.upperBound, into: &params))
            #expect(p.read(params) == p.range.upperBound)
            var other = ColorSectionParams.defaults(for: .curves)
            #expect(!p.write(1, into: &other))
        }
    }

    @Test func setClampsAndTargetsTheSection() {
        let m = model()
        m.set(basicID, .temperature, 250)
        m.set(basicID, .exposure, -9)
        m.set(basicID, .saturation, 300)
        m.set(basicID, .contrast, 12.5)
        m.set(basicID, .whites, 40)
        #expect(m.value(basicID, .temperature) == 100)
        #expect(m.value(basicID, .exposure) == -5)
        #expect(m.value(basicID, .saturation) == 200)
        #expect(m.value(basicID, .contrast) == 12.5 && m.value(basicID, .whites) == 40)
        // Setting a slider on a block it does not belong to does nothing.
        m.set(lutID, .temperature, 10)
        #expect(m.color.sections[1].params == .inputLUT(.automatic))
    }

    @Test func changeCallbackFiresOncePerRealChange() {
        let m = model()
        var seen: [ClipColor] = []
        m.onChange = { seen.append($0) }
        m.set(basicID, .tint, 10)
        #expect(seen.count == 1)
        m.set(basicID, .tint, 10)
        #expect(seen.count == 1)
        guard case .basic(let b) = seen[0].sections[0].params else { Issue.record("basic"); return }
        #expect(b.tint == 10)
    }

    @Test func addRemoveReorderEnableAndReset() {
        let m = model()
        m.addSection(.curves); m.addSection(.vignette); m.addSection(.basicCorrection)
        #expect(m.sections.map(\.kind) == [.basicCorrection, .inputLUT, .curves, .vignette, .basicCorrection])
        let second = m.sections[4].id
        m.moveSection(second, to: 1)                 // a second correction before the LUT
        #expect(m.sections.map(\.kind) == [.basicCorrection, .basicCorrection, .inputLUT, .curves, .vignette])
        m.moveSection(second, by: 1)
        #expect(m.sections.map(\.kind) == [.basicCorrection, .inputLUT, .basicCorrection, .curves, .vignette])
        m.moveSection(m.sections[0].id, by: -1)      // already first: no-op
        #expect(m.sections[0].kind == .basicCorrection)
        m.set(second, .contrast, 30)
        m.setEnabled(second, false)
        #expect(!m.isEnabled(second))
        m.resetSection(second)
        #expect(m.value(second, .contrast) == 0 && !m.isEnabled(second), "reset keeps the enabled state")
        m.removeSection(second)
        #expect(m.sections.count == 4)
        let lut = m.sections.first { $0.kind == .inputLUT }!.id
        m.removeSection(lut)
        #expect(m.sections.contains { $0.kind == .inputLUT }, "the Input LUT cannot be removed")
        m.set(m.sections[0].id, .exposure, 2)
        m.setSourceOverride(.hlgBT2020)
        m.resetAll()
        #expect(m.sections.map(\.kind) == [.basicCorrection, .inputLUT] && m.color.source == .hlgBT2020)
        #expect(m.value(1, .exposure) == 0)
    }

    @Test func structuralEditsAreOneGestureEach() {
        let m = model()
        var began = 0, ended = 0
        m.onGestureBegan = { began += 1 }
        m.onGestureEnded = { ended += 1 }
        m.addSection(.wheels)
        m.resetSection(1)
        m.moveSection(2, by: 1)
        m.removeSection(3)
        #expect(began == 4 && ended == 4)
        began = 0; ended = 0
        m.gesture { m.set(1, .tint, 5); m.set(1, .tint, 6) }
        #expect(began == 1 && ended == 1)
        m.resetParameter(1, .tint)
        #expect(began == 2 && ended == 2 && m.value(1, .tint) == 0)
    }

    @Test func wheelsAndTintsStoreHueAmountAndLuma() {
        let m = model()
        m.addSection(.wheels); m.addSection(.creative)
        let w = m.sections[2].id, c = m.sections[3].id
        m.setWheel(w, .shadows, hue: 210, amount: 1.4)
        m.setWheelLuma(w, .shadows, -250)
        m.setWheelLuma(w, .midtones, 40)
        #expect(m.wheel(w, .shadows).value == WheelValue(hue: 210, amount: 1))
        #expect(m.wheel(w, .shadows).luma == -100 && m.wheel(w, .midtones).luma == 40)
        m.setWheel(c, .shadowTint, hue: 30, amount: 0.5)
        #expect(m.wheel(c, .shadowTint).value == WheelValue(hue: 30, amount: 0.5))
        m.setWheelLuma(c, .shadowTint, 50)   // tints have no luma
        #expect(m.wheel(c, .shadowTint).luma == 0)
        m.resetWheel(w, .shadows)
        #expect(m.wheel(w, .shadows).value.isNeutral && m.wheel(w, .shadows).luma == 0)
        #expect(m.wheel(w, .midtones).luma == 40, "other wheels untouched")
        #expect(ColorWheelSlot.highlights.hasLuma && !ColorWheelSlot.shadowTint.hasLuma)
    }

    @Test func curvesRoundTrip() {
        let m = model()
        m.addSection(.curves)
        let id = m.sections[2].id
        var c = m.curves(id)
        #expect(c.isNeutral)
        c.master = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        m.setCurves(id, c)
        #expect(m.curves(id).master.count == 3)
        m.setCurves(1, c)   // not a curves block: ignored
        #expect(m.color.sections[0].params == .basic(BasicCorrection()))
    }

    @Test func loadAndClipColorRoundTrip() {
        let m = model()
        var fired = 0
        m.onChange = { _ in fired += 1 }
        var c = ClipColor.default
        c.source = .sLog3SGamut3Cine
        c.sections[0].params = .basic({ var b = BasicCorrection(); b.exposure = 1; return b }())
        c.sections[1].enabled = false
        c.addSection(.vignette)
        m.load(c, mediaID: UUID(), info: MediaInfo(duration: Time(1, 1), detectedColorSpace: .hlgBT2020, embeddedLUTName: "Look"))
        #expect(fired == 0, "load never reports")
        #expect(m.clipColor() == c)
        #expect(m.detectedSource == .hlgBT2020 && m.embeddedLUTName == "Look")
        #expect(m.sourceOverride == .sLog3SGamut3Cine && m.source == .sLog3SGamut3Cine)
        m.setSourceOverride(nil)
        #expect(m.source == .hlgBT2020, "automatic follows the media")
        #expect(fired == 1)
    }

    @Test func collapsedStateIsUIOnlyAndPrunedOnLoad() {
        let m = model()
        m.addSection(.vignette)
        m.setCollapsed(3, true)
        #expect(m.isCollapsed(3))
        #expect(m.color.sections.count == 3, "collapsing does not edit the clip")
        m.load(.default, mediaID: nil, info: nil)
        #expect(!m.isCollapsed(3), "ids that no longer exist are forgotten")
    }

    @Test func lutChoicesMapToRefsAndRecentsArePersistedMostRecentFirst() {
        let m = model()
        let media = UUID()
        m.load(.default, mediaID: media, info: MediaInfo(duration: Time(1, 1), embeddedLUTName: "Look"))
        m.setLUT(lutID, .embedded(name: "x"))
        #expect(m.color.sections[1].params == .inputLUT(.embedded(media)))
        #expect(m.lutChoice(lutID) == .embedded(name: "Look"))
        m.setLUT(lutID, .file("/luts/a.cube"))
        m.setLUT(lutID, .file("/luts/b.cube"))
        m.setLUT(lutID, .file("/luts/a.cube"))
        #expect(m.recentLUTs == ["/luts/a.cube", "/luts/b.cube"])
        #expect(m.lutChoice(lutID)?.name == "a")
        m.setLUT(lutID, nil)
        #expect(m.color.sections[1].params == .inputLUT(nil) && m.lutChoice(lutID) == nil)
        m.setLUT(lutID, .automatic)
        #expect(m.color.sections[1].params == .inputLUT(.automatic))
        // Creative look.
        m.addSection(.creative)
        let cr = m.sections[2].id
        m.setLUT(cr, .file("/luts/look.cube"))
        #expect(m.lutChoice(cr) == .file("/luts/look.cube"))
        m.setLUT(cr, nil)
        #expect(m.lutChoice(cr) == nil)
        #expect(m.recents.paths.first == "/luts/look.cube")
    }

    @Test func recentLUTsKeepAtMostEightAndSurviveANewStore() {
        let suite = "RecentLUTsTests-\(UUID())"
        let store = RecentLUTs(defaults: UserDefaults(suiteName: suite)!)
        for i in 0..<12 { store.add("/l/\(i).cube") }
        #expect(store.paths.count == 8 && store.paths.first == "/l/11.cube")
        #expect(RecentLUTs(defaults: UserDefaults(suiteName: suite)!).paths == store.paths)
        store.clear()
        #expect(store.paths.isEmpty)
    }

    @Test func sectionDropSlotCountsBlocksAboveThePointer() {
        #expect(ColorSectionsStack.slot(midYs: [50, 150, 250], y: 10) == 0)
        #expect(ColorSectionsStack.slot(midYs: [50, 150, 250], y: 160) == 2)
        #expect(ColorSectionsStack.slot(midYs: [50, 150, 250], y: 999) == 3)
        #expect(ColorSectionsStack.slot(midYs: [], y: 5) == 0)
    }

    @Test func curveEditingKeepsOrderGapsAndEndPoints() {
        var p = RGBCurves.diagonal
        let added = CurveEditing.add(p, x: 0.5, y: 0.7)
        p = added.points
        #expect(added.index == 1 && p.count == 3)
        p = CurveEditing.move(p, index: 1, to: 2, 0.3)       // x clamps below the last point
        #expect(p[1].x <= 1 - CurveEditing.minGap && p[1].y == 0.3)
        p = CurveEditing.move(p, index: 0, to: 0.4, 0.2)     // end points only move vertically
        #expect(p[0].x == 0 && p[0].y == 0.2)
        #expect(CurveEditing.remove(p, index: 0) == p, "end points stay")
        #expect(CurveEditing.remove(p, index: 1).count == 2)
        #expect(CurveEditing.remove(RGBCurves.diagonal, index: 0).count == 2)
        let hit = CurveEditing.hit(p, x: 0, y: 100 * (1 - 0.2), size: CGSize(width: 100, height: 100))
        #expect(hit == 0)
        #expect(CurveEditing.hit(p, x: 50, y: 5, size: CGSize(width: 100, height: 100)) == nil)
    }
}

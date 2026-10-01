import AppKit
import Foundation
import Testing
import SSCore
import SSRender
@testable import SSEditorUI

@MainActor @Suite struct ColorInspectorModelTests {
    func model() -> ColorInspectorModel {
        let m = ColorInspectorModel()
        m.recents = RecentLUTs(defaults: UserDefaults(suiteName: "ColorInspectorModelTests-\(UUID())")!)
        m.recentLUTs = []
        return m
    }
    let e1 = 1

    @Test func defaultIsOneEffectWithAutomaticInputLUT() {
        let m = model()
        #expect(m.effects.count == 1)
        #expect(m.lutChoice(e1, .input) == .automatic)
        #expect(m.lutChoice(e1, .look) == nil)
        #expect(m.color.isDefault)
        #expect(m.source == .rec709)
    }

    @Test func sliderLayoutFollowsLumetri() {
        let basic = ColorParam.layout(for: .basicCorrection)
        #expect(basic.map { $0.group ?? "" } == ["Color", "Light"])
        #expect(basic[0].params.map(\.title) == ["Temperature", "Tint", "Saturation"])
        #expect(basic[1].params.map(\.title) == ["Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks"])
        let creative = ColorParam.layout(for: .creative)
        #expect(creative[0].group == "Adjustments")
        #expect(creative[0].params.map(\.title) == ["Faded Film", "Vibrance", "Saturation"])
        #expect(ColorParam.saturation.neutral == 100 && ColorParam.saturation.range == 0...200)
        #expect(ColorParam.exposure.range == -5...5 && ColorParam.exposure.decimals == 2)
        #expect(ColorParam.temperature.track == .temperature && ColorParam.tint.track == .tint && ColorParam.contrast.track == .plain)
        #expect(ColorParam.vignetteMidpoint.neutral == 50 && ColorParam.vignetteFeather.neutral == 50)
        #expect(ColorParam.lookIntensity.neutral == 100 && ColorParam.inputLUTIntensity.neutral == 100)
        // Every slider reads its neutral from a default effect, writes (clamped) into it and belongs to its section.
        for p in ColorParam.allCases {
            var e = ColorEffect(id: 1)
            #expect(p.read(e) == p.neutral, "\(p) default is its neutral")
            p.write(p.range.upperBound + 500, into: &e)
            #expect(p.read(e) == p.range.upperBound)
            p.write(p.range.lowerBound - 500, into: &e)
            #expect(p.read(e) == p.range.lowerBound)
        }
    }

    @Test func setClampsAndTargetsTheEffect() {
        let m = model()
        m.set(e1, .temperature, 250)
        m.set(e1, .exposure, -9)
        m.set(e1, .saturation, 300)
        m.set(e1, .contrast, 12.5)
        m.set(e1, .whites, 40)
        #expect(m.value(e1, .temperature) == 100)
        #expect(m.value(e1, .exposure) == -5)
        #expect(m.value(e1, .saturation) == 200)
        #expect(m.value(e1, .contrast) == 12.5 && m.value(e1, .whites) == 40)
        m.set(99, .tint, 5)   // unknown effect: ignored
        #expect(m.effects.count == 1 && m.value(99, .tint) == 0)
    }

    @Test func changeCallbackFiresOncePerRealChange() {
        let m = model()
        var seen: [ClipColor] = []
        m.onChange = { seen.append($0) }
        m.set(e1, .tint, 10)
        #expect(seen.count == 1)
        m.set(e1, .tint, 10)
        #expect(seen.count == 1)
        #expect(seen[0].effects[0].basic.tint == 10)
    }

    @Test func sectionTogglesResetsAndEffects() {
        let m = model()
        m.set(e1, .contrast, 30)
        m.set(e1, .fadedFilm, 20)
        m.setEnabled(e1, .basicCorrection, false)
        #expect(!m.isEnabled(e1, .basicCorrection) && m.isEnabled(e1, .creative))
        m.resetSection(e1, .basicCorrection)
        #expect(m.value(e1, .contrast) == 0 && !m.isEnabled(e1, .basicCorrection), "reset keeps the toggle")
        #expect(m.value(e1, .fadedFilm) == 20, "other sections are untouched")
        m.setEnabled(e1, .hslSecondary, false)
        #expect(m.isEnabled(e1, .hslSecondary), "the HSL placeholder cannot be toggled")
        m.addEffect()
        #expect(m.effects.map(\.id) == [1, 2])
        m.set(2, .vignetteAmount, -2)
        #expect(m.value(2, .vignetteAmount) == -2 && m.value(1, .vignetteAmount) == 0)
        m.removeEffect(2)
        #expect(m.effects.count == 1)
        m.removeEffect(1)
        #expect(m.effects.count == 1, "the last effect stays")
        m.set(e1, .exposure, 2)
        m.setSourceOverride(.hlgBT2020)
        m.resetAll()
        #expect(m.color.source == .hlgBT2020 && m.color.effects.count == 1 && m.value(e1, .exposure) == 0)
    }

    @Test func structuralEditsAreOneGestureEach() {
        let m = model()
        var began = 0, ended = 0
        m.onGestureBegan = { began += 1 }
        m.onGestureEnded = { ended += 1 }
        m.addEffect()
        m.resetSection(e1, .creative)
        m.setEnabled(e1, .wheels, false)
        m.removeEffect(2)
        #expect(began == 4 && ended == 4)
        began = 0; ended = 0
        m.gesture { m.set(e1, .tint, 5); m.set(e1, .tint, 6) }
        #expect(began == 1 && ended == 1)
        m.resetParameter(e1, .tint)
        #expect(began == 2 && ended == 2 && m.value(e1, .tint) == 0)
    }

    @Test func whiteBalanceIsOneGestureAndClamps() {
        let m = model()
        var began = 0, ended = 0
        m.onGestureBegan = { began += 1 }
        m.onGestureEnded = { ended += 1 }
        m.setWhiteBalance(e1, temperature: -35.5, tint: 140)
        #expect(m.value(e1, .temperature) == -35.5 && m.value(e1, .tint) == 100)
        #expect(began == 1 && ended == 1)
    }

    @Test func resetEffectKeepsTogglesAndOtherEffects() {
        let m = model()
        m.addEffect()
        m.set(e1, .contrast, 30); m.set(e1, .vignetteAmount, -2); m.set(2, .exposure, 1)
        m.setWheel(e1, .shadows, hue: 10, amount: 0.5)
        m.setEnabled(e1, .creative, false)
        var began = 0
        m.onGestureBegan = { began += 1 }
        m.resetEffect(e1)
        #expect(began == 1, "one undo step")
        #expect(m.value(e1, .contrast) == 0 && m.value(e1, .vignetteAmount) == 0 && m.wheel(e1, .shadows).value.isNeutral)
        #expect(!m.isEnabled(e1, .creative), "toggles stay")
        #expect(m.value(2, .exposure) == 1)
        #expect(m.lutChoice(e1, .input) == .automatic, "the first effect's Input LUT returns to automatic")
    }

    @Test func wheelsAndTintsStoreHueAmountAndLuma() {
        let m = model()
        m.setWheel(e1, .shadows, hue: 210, amount: 1.4)
        m.setWheelLuma(e1, .shadows, -250)
        m.setWheelLuma(e1, .midtones, 40)
        #expect(m.wheel(e1, .shadows).value == WheelValue(hue: 210, amount: 1))
        #expect(m.wheel(e1, .shadows).luma == -100 && m.wheel(e1, .midtones).luma == 40)
        m.setWheel(e1, .shadowTint, hue: 30, amount: 0.5)
        #expect(m.wheel(e1, .shadowTint).value == WheelValue(hue: 30, amount: 0.5))
        m.setWheelLuma(e1, .shadowTint, 50)   // tints have no luma
        #expect(m.wheel(e1, .shadowTint).luma == 0)
        m.resetWheel(e1, .shadows)
        #expect(m.wheel(e1, .shadows).value.isNeutral && m.wheel(e1, .shadows).luma == 0)
        #expect(m.wheel(e1, .midtones).luma == 40, "other wheels untouched")
        #expect(ColorWheelSlot.highlights.hasLuma && !ColorWheelSlot.shadowTint.hasLuma)
    }

    @Test func curvesRoundTrip() {
        let m = model()
        var c = m.curves(e1)
        #expect(c.isNeutral)
        c.master = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        m.setCurves(e1, c)
        #expect(m.curves(e1).master.count == 3)
        m.setCurves(42, c)   // unknown effect: ignored
        #expect(m.color.effects.count == 1)
    }

    @Test func loadAndClipColorRoundTrip() {
        let m = model()
        var fired = 0
        m.onChange = { _ in fired += 1 }
        var c = ClipColor.default
        c.source = .sLog3SGamut3Cine
        c.effects[0].basic.exposure = 1
        c.effects[0].setEnabled(.vignette, false)
        c.addEffect()
        m.load(c, mediaID: UUID(), info: MediaInfo(duration: Time(1, 1), detectedColorSpace: .hlgBT2020, embeddedLUTName: "Look"))
        #expect(fired == 0, "load never reports")
        #expect(m.clipColor() == c)
        #expect(m.detectedSource == .hlgBT2020 && m.embeddedLUTName == "Look")
        #expect(m.sourceOverride == .sLog3SGamut3Cine && m.source == .sLog3SGamut3Cine)
        m.setSourceOverride(nil)
        #expect(m.source == .hlgBT2020, "automatic follows the media")
        #expect(fired == 1)
    }

    @Test func collapsedStateIsUIOnlyDefaultsLikePremiereAndIsPruned() {
        let m = model()
        m.load(.default, mediaID: nil, info: nil)
        #expect(!m.isCollapsed(ColorPanelKey(1, .basicCorrection)) && !m.isCollapsed(ColorPanelKey(1, .creative)))
        #expect(m.isCollapsed(ColorPanelKey(1, .curves)) && m.isCollapsed(ColorPanelKey(1, .vignette)))
        let key = ColorPanelKey(1, .basicCorrection, group: "Light")
        m.setCollapsed(key, true)
        #expect(m.isCollapsed(key))
        #expect(m.color.isDefault, "collapsing does not edit the clip")
        m.setCollapsed(ColorPanelKey(1, .curves), false)
        m.load(.default, mediaID: nil, info: nil)
        #expect(!m.isCollapsed(ColorPanelKey(1, .curves)), "reloading the same effect keeps the user's choice")
        var two = ClipColor.default; two.addEffect()
        m.load(two, mediaID: nil, info: nil)
        #expect(m.isCollapsed(ColorPanelKey(2, .curves)) && !m.isCollapsed(ColorPanelKey(2, .basicCorrection)))
        m.load(.default, mediaID: nil, info: nil)
        #expect(!m.isCollapsed(ColorPanelKey(2, .curves)), "keys of effects that no longer exist are forgotten")
    }

    @Test func lutChoicesMapToRefsAndRecentsArePersistedMostRecentFirst() {
        let m = model()
        let media = UUID()
        m.load(.default, mediaID: media, info: MediaInfo(duration: Time(1, 1), embeddedLUTName: "Look"))
        m.setLUT(e1, .input, .embedded(name: "x"))
        #expect(m.color.effects[0].inputLUT == .embedded(media))
        #expect(m.lutChoice(e1, .input) == .embedded(name: "Look"))
        m.setLUT(e1, .input, .file("/luts/a.cube"))
        m.setLUT(e1, .input, .file("/luts/b.cube"))
        m.setLUT(e1, .input, .file("/luts/a.cube"))
        #expect(m.recentLUTs == ["/luts/a.cube", "/luts/b.cube"])
        #expect(m.lutChoice(e1, .input)?.name == "a")
        m.setLUT(e1, .input, nil)
        #expect(m.color.effects[0].inputLUT == nil && m.lutChoice(e1, .input) == nil)
        m.setLUT(e1, .input, .automatic)
        #expect(m.color.effects[0].inputLUT == .automatic)
        // Creative look.
        m.setLUT(e1, .look, .file("/luts/look.cube"))
        #expect(m.lutChoice(e1, .look) == .file("/luts/look.cube"))
        m.setLUT(e1, .look, nil)
        #expect(m.lutChoice(e1, .look) == nil)
        #expect(m.recents.paths.first == "/luts/look.cube")
    }

    @Test func lookArrowsCycleThroughNoneAndTheAvailableLooks() {
        let m = model()
        m.availableLUTs = [.file("/l/a.cube"), .file("/l/b.cube")]
        #expect(m.lookChoices.map(\.name) == ["a", "b"])
        var began = 0
        m.onGestureBegan = { began += 1 }
        m.cycleLook(e1, by: 1)
        #expect(m.lutChoice(e1, .look) == .file("/l/a.cube"))
        m.cycleLook(e1, by: 1)
        #expect(m.lutChoice(e1, .look)?.name == "b")
        m.cycleLook(e1, by: 1)
        #expect(m.lutChoice(e1, .look) == nil, "wraps to None")
        m.cycleLook(e1, by: -1)
        #expect(m.lutChoice(e1, .look)?.name == "b", "backwards wraps to the last look")
        #expect(began == 4, "one undo step per arrow click")
        // A look that is not in the list (chosen from a file) is still part of the cycle.
        m.setLUT(e1, .look, .file("/elsewhere/c.cube"))
        m.cycleLook(e1, by: 1)
        #expect(m.lutChoice(e1, .look) == nil)
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

    @Test func lookPreviewRendersTheLookIntoTheThumbnail() throws {
        let plain = ColorLookPreview.render(lut: nil, width: 20, height: 12)
        #expect(plain.size == NSSize(width: 20, height: 12))
        // A constant-red look turns every pixel red.
        let cube = "LUT_3D_SIZE 2\n1 0 0\n1 0 0\n1 0 0\n1 0 0\n1 0 0\n1 0 0\n1 0 0\n1 0 0\n"
        let lut = try CubeLUT.parse(cube)
        let img = ColorLookPreview.render(lut: lut, width: 20, height: 12)
        let tiff = try #require(img.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let px = try #require(rep.colorAt(x: 10, y: 3)?.usingColorSpace(.sRGB))
        #expect(px.redComponent > 0.9 && px.greenComponent < 0.25 && px.blueComponent < 0.25, "\(px)")
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

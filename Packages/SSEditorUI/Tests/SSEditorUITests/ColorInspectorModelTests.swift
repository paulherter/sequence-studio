import Foundation
import Testing
import SSCore
import SSRender
@testable import SSEditorUI

@MainActor @Suite struct ColorInspectorModelTests {
    @Test func sectionsInProcessingOrder() {
        #expect(ColorInspectorModel.Section.allCases == [.source, .correction, .conversionLUT, .creativeLUT])
        #expect(ColorInspectorModel.Parameter.allCases.map(\.title) ==
                ["Temperature", "Tint", "Exposure", "Contrast", "Highlights", "Shadows", "Saturation"])
    }

    @Test func startsNeutral() {
        let m = ColorInspectorModel()
        #expect(m.correction == .neutral)
        #expect(m.state.correction.isNeutral)
        #expect(m.state.conversionLUT == .automatic && m.state.creativeLUT == nil)
        #expect(m.state.source == .rec709)
    }

    @Test func setBuildsCorrectionAndClamps() {
        let m = ColorInspectorModel()
        m.set(.temperature, 250)
        m.set(.exposure, -9)
        m.set(.saturation, 300)
        m.set(.contrast, 12.5)
        #expect(m.correction.temperature == 100)
        #expect(m.correction.exposure == -4)
        #expect(m.correction.saturation == 200)
        #expect(m.correction.contrast == 12.5)
        #expect(m.value(.tint) == 0 && m.value(.saturation) == 200)
    }

    @Test func changeCallbackFires() {
        let m = ColorInspectorModel()
        var states: [ColorInspectorModel.State] = []
        m.onChange = { states.append($0) }
        m.set(.tint, 10)
        #expect(states.count == 1 && states[0].correction.tint == 10)
        m.set(.tint, 10)   // unchanged: no callback
        #expect(states.count == 1)
    }

    @Test func bypassNeutralisesOnlyThatSection() {
        let m = ColorInspectorModel()
        m.set(.exposure, 1)
        m.conversionLUT = .init(id: "a", name: "A")
        m.creativeLUT = .init(id: "b", name: "B")
        m.creativeIntensity = 0.5
        m.setBypassed(.correction, true)
        #expect(m.state.correction.isNeutral)
        #expect(m.correction.exposure == 1)            // values are kept
        #expect(m.state.conversionLUT?.id == "a")
        m.setBypassed(.creativeLUT, true)
        #expect(m.state.creativeLUT == nil && m.state.creativeIntensity == 0.5)
        m.setBypassed(.conversionLUT, true)
        #expect(m.state.conversionLUT == nil)
        m.setBypassed(.correction, false)
        #expect(m.state.correction.exposure == 1)
    }

    @Test func bypassFiresChangeOnce() {
        let m = ColorInspectorModel()
        var n = 0
        m.onChange = { _ in n += 1 }
        m.setBypassed(.correction, true)
        m.setBypassed(.correction, true)
        #expect(n == 1)
    }

    @Test func sourceCannotBeBypassed() {
        let m = ColorInspectorModel()
        m.setBypassed(.source, true)
        #expect(!m.isBypassed(.source))
    }

    @Test func resetSectionAndAll() {
        let m = ColorInspectorModel()
        m.source = .hlgBT2020
        m.set(.contrast, 40)
        m.conversionLUT = .init(id: "a", name: "A")
        m.creativeLUT = .init(id: "b", name: "B")
        m.creativeIntensity = 0.3
        m.setBypassed(.creativeLUT, true)
        m.reset(.correction)
        #expect(m.correction == .neutral && m.source == .hlgBT2020)
        m.reset(.creativeLUT)
        #expect(m.creativeLUT == nil && m.creativeIntensity == 1 && !m.isBypassed(.creativeLUT))
        m.set(.shadows, 5)
        m.resetAll()
        #expect(m.source == .rec709 && m.correction == .neutral && m.conversionLUT == .automatic)
    }

    @Test func gestureCallbacksWrapReset() {
        let m = ColorInspectorModel()
        m.set(.tint, 4)
        var log: [String] = []
        m.onGestureBegan = { log.append("begin") }
        m.onChange = { _ in log.append("change") }
        m.onGestureEnded = { log.append("end") }
        m.reset(.correction)
        #expect(log.first == "begin" && log.last == "end" && log.contains("change"))
        #expect(log.filter { $0 == "begin" }.count == 1)
    }

    @Test func resetParameter() {
        let m = ColorInspectorModel()
        m.set(.saturation, 50)
        m.resetParameter(.saturation)
        #expect(m.value(.saturation) == 100)
    }

    @Test func intensityClamped() {
        let m = ColorInspectorModel()
        m.creativeIntensity = 3
        #expect(m.creativeIntensity == 1)
        m.creativeIntensity = -1
        #expect(m.creativeIntensity == 0)
    }

    @Test func wheelsStoredAndReset() {
        let m = ColorInspectorModel()
        m.setWheel(.shadows, hue: 210, amount: 0.4)
        m.setWheelMaster(.shadows, 0.25)
        #expect(m.wheel(.shadows).hue == 210 && m.wheel(.shadows).master == 0.25)
        #expect(m.correction == .neutral)   // not part of ColorCorrection yet
        m.resetWheel(.shadows)
        #expect(m.wheel(.shadows) == .init())
    }

    @Test func sourceChangeFires() {
        let m = ColorInspectorModel()
        var last: ColorInspectorModel.State?
        m.onChange = { last = $0 }
        m.source = .sLog3SGamut3Cine
        #expect(last?.source == .sLog3SGamut3Cine)
    }

    @Test func loadAndClipColorRoundTrip() {
        let media = UUID()
        var c = ClipColor.default
        c.source = .hlgBT2020
        c.correction.exposure = 1.5
        c.conversionLUT = .file("/tmp/a.cube")
        c.creativeLUT = .file("/tmp/b.cube")
        c.creativeIntensity = 0.5
        c.bypassCreativeLUT = true
        c.useEmbeddedLUT = false
        let m = ColorInspectorModel()
        var fired = 0
        m.onChange = { _ in fired += 1 }
        m.load(c, mediaID: media, info: MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine, embeddedLUTName: "Look"))
        #expect(fired == 0)                                   // loading is silent
        #expect(m.clipColor() == c)
        #expect(m.detectedSource == .sLog3SGamut3Cine && m.embeddedLUTName == "Look")
        #expect(m.conversionLUT?.name == "a.cube" && m.isBypassed(.creativeLUT))
    }

    @Test func automaticSourceFollowsMediaAndOverrideIsExplicit() {
        let m = ColorInspectorModel()
        m.load(.default, mediaID: UUID(), info: MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine))
        #expect(m.source == .sLog3SGamut3Cine && m.clipColor().source == nil)
        m.setSourceOverride(.rec709)
        #expect(m.source == .rec709 && m.clipColor().source == .rec709)
        m.setSourceOverride(nil)
        #expect(m.clipColor().source == nil)
    }

    @Test func conversionChoicesMapToLUTRefs() {
        let media = UUID()
        let m = ColorInspectorModel()
        m.load(.default, mediaID: media, info: MediaInfo(duration: Time(1, 1), embeddedLUTName: "Look"))
        #expect(m.clipColor().conversionLUT == .automatic)
        m.conversionLUT = .embedded(name: "Look")
        #expect(m.clipColor().conversionLUT == .embedded(media))
        m.conversionLUT = nil
        #expect(m.clipColor().conversionLUT == nil)
        m.conversionLUT = .file("/x/y.cube")
        #expect(m.clipColor().conversionLUT == .file("/x/y.cube"))
    }
}

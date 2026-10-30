import Foundation
import Testing
import SQCore
import SQLibrary
import SQRender
@testable import SQEditorUI
@testable import SQInspectorUI

/// F1: after Reset on S-Log3 footage with its camera LUT the Source LUT popup, "Interpret As" and the render pipeline
/// describe the same state (Automatic LUT, S-Log3 source, the embedded LUT applied).
@MainActor @Suite struct ColorResetAgreementTests {
    private struct Provider: LUTProvider {
        let lut = CubeLUT(title: "cam", kind: .lut3D, size: 2, table: Array(repeating: SIMD3<Float>(repeating: 0.5), count: 8))
        func lut(for ref: LUTRef) -> CubeLUT? { if case .embedded = ref { lut } else { nil } }
    }

    private func model() -> ColorInspectorModel {
        let m = ColorInspectorModel()
        m.recents = RecentLUTs(defaults: UserDefaults(suiteName: "ColorResetAgreementTests-\(UUID())")!)
        return m
    }

    private func conversion(_ p: ColorPipeline) -> CubeLUT?? {
        for op in p.ops { if case .conversion(let l) = op { return .some(l) } }
        return nil
    }

    @Test func resetReturnsToAutomaticAndThePipelineAppliesTheEmbeddedLUT() {
        let media = UUID()
        let info = MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine, embeddedLUTName: "Embedded LUT")
        // Before: the user had picked the embedded LUT explicitly and bent a slider.
        var e = ColorEffect(id: 1, inputLUT: .embedded(media))
        e.basic.exposure = 1
        let m = model()
        m.load(ClipColor(source: nil, useEmbeddedLUT: true, effects: [e]), mediaID: media, info: info)
        #expect(m.lutChoice(1, .input) == .embedded(name: "Embedded LUT"))

        m.resetEffect(1)
        #expect(m.lutChoice(1, .input) == .automatic)                 // the popup's selected item
        #expect(m.source == SourceColorSpace(.sLog3SGamut3Cine))      // Interpret As: Automatic (S-Log3)
        #expect(m.sourceOverride == nil)

        let pipeline = ColorPipeline.from(clipColor: m.clipColor(), mediaID: media, mediaInfo: info, lutProvider: Provider())
        #expect(conversion(pipeline) != nil)
        if let c = conversion(pipeline) { #expect(c != nil, "Automatic on S-Log3 uses the embedded LUT") }
        #expect(!pipeline.ops.contains { if case .basic = $0 { true } else { false } }, "the slider is back at neutral")
    }

    @Test func resetKeepsAnExplicitInterpretAsAndAutomaticThenSkipsTheCameraLUT() {
        // Source reinterpreted as Rec.709: the Sony look LUT expects S-Log3, so Automatic correctly applies none.
        let media = UUID()
        let info = MediaInfo(duration: Time(1, 1), detectedColorSpace: .sLog3SGamut3Cine, embeddedLUTName: "Embedded LUT")
        let m = model()
        m.load(ClipColor(source: .rec709, useEmbeddedLUT: true, effects: [ColorEffect(id: 1, inputLUT: .embedded(media))]), mediaID: media, info: info)
        m.resetEffect(1)
        #expect(m.lutChoice(1, .input) == .automatic)
        #expect(m.source == SourceColorSpace(.rec709))
        let pipeline = ColorPipeline.from(clipColor: m.clipColor(), mediaID: media, mediaInfo: info, lutProvider: Provider())
        if let c = conversion(pipeline) { #expect(c == nil) } else { Issue.record("no conversion op") }
    }
}

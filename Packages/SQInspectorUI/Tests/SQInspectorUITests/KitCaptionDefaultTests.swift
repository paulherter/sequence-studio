import Foundation
import Testing
import SQCore
import SQText
import SQTranscribe
@testable import SQInspectorUI

private struct NoService: TranscriptionService {
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        Transcript(language: "de-DE", words: [])
    }
}

@MainActor @Suite struct KitCaptionDefaultTests {
    private func model() -> CaptionsPanelModel { CaptionsPanelModel(service: NoService(), debounce: .milliseconds(20)) }

    private func library() -> CaptionLookLibrary {
        CaptionLookLibrary(store: nil, defaults: UserDefaults(suiteName: "sq.test.kitdefault.\(UUID().uuidString)")!)
    }

    @Test func kitCaptionStyleBecomesTheDefaultPreset() {
        let m = model()
        let kit = StyleKit.starter
        #expect(kit.caption != nil)
        #expect(NamedLookPreset.install(into: m, library: library(), kit: kit))
        #expect(m.presets[m.selectedPresetIndex].name == NamedLookPreset.kitPresetName)
        let p = m.presets[m.selectedPresetIndex].preset
        #expect(p.styleRef == StyleKit.captionStyleRef && p.animationRef == StyleKit.captionAnimationRef)
    }

    @Test func noKitCaptionStyleLeavesThePresetsAlone() {
        let m = model()
        #expect(!NamedLookPreset.install(into: m, library: library(), kit: StyleKit()))
        #expect(!NamedLookPreset.install(into: m, library: library(), kit: nil))
        #expect(!m.presets.contains { $0.name == NamedLookPreset.kitPresetName })
        #expect(m.presets[m.selectedPresetIndex].name == "Standard")
    }

    @Test func aUserPickStaysSelected() {
        let m = model()
        m.selectedPresetIndex = 1                       // Short Video
        NamedLookPreset.install(into: m, library: library(), kit: .starter)
        #expect(m.presets[m.selectedPresetIndex].name == "Short Video")
    }
}

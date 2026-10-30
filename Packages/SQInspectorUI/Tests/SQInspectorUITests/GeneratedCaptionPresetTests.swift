import Testing
import SQCore
import SQText
import Foundation
import SQTranscribe
@testable import SQInspectorUI

private struct NoService: TranscriptionService {
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript { Transcript(language: "en-US") }
    func supportedLanguages() async -> [String] { [] }
}

@MainActor @Suite struct GeneratedCaptionPresetTests {
    @Test func presetsFollowTheFamily() throws {
        let lib = CaptionPresetLibrary.builtIn
        var seen = Set<TextPresetCategory>()
        for l in GeneratedCaptionLooks.all {
            let p = CaptionPreset.generated(for: l)
            #expect(p.styleRef == l.styleRef && p.animationRef == l.animationRef)
            #expect(lib.hasStyle(p.styleRef) && lib.hasAnimation(p.animationRef))
            let c = try #require(l.category)
            seen.insert(c)
            switch c {
            case .tiktok: #expect(p.maxWordsPerCaption == 1 && p.emphasis == .none)
            case .youtube: #expect(p.maxCharsPerLine == 32 && p.maxLines == 2)
            default: #expect(p.maxCharsPerLine == CaptionPreset.standard.maxCharsPerLine)
            }
        }
        #expect(seen == [.tiktok, .youtube, .professional])
    }

    @Test func addingKeepsTheSelectionAndIsIdempotent() {
        let m = CaptionsPanelModel(service: NoService())
        let before = m.presets.count
        m.selectedPresetIndex = 1
        GeneratedCaptionPresets.add(to: m)
        GeneratedCaptionPresets.add(to: m)
        #expect(m.presets.count == before + GeneratedCaptionPresets.named.count)
        #expect(m.selectedPresetIndex == 1 && m.presets[1].name == "Short Video")
        #expect(Set(m.presets.map(\.name)).count == m.presets.count)
    }
}

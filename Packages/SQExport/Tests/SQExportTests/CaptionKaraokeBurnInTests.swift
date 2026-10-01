import Foundation
import Testing
import SQCore
import SQText
import SQTranscribe
@testable import SQExport

@Suite struct CaptionKaraokeBurnInTests {
    func caption(karaoke: KaraokeStyle?) -> Caption {
        let words = [("so", 0, 3), ("this", 4, 8), ("works", 9, 14)].map {
            CaptionWord(text: $0.0, range: TimeRange(start: Time(Int64($0.1), 10), end: Time(Int64($0.2), 10)))
        }
        return Caption(lines: ["so this works"], range: TimeRange(start: .zero, end: Time(2, 1)),
                       styleRef: "tiktok", animationRef: "none", words: words, karaoke: karaoke)
    }

    @Test func theBurnInLightsTheSameWordAsTheMonitor() {
        let k = KaraokeStyle()
        let burn = CaptionBurnIn(captions: [caption(karaoke: k)], library: .builtIn)
        let item = CaptionItem(lines: ["so this works"], range: TimeRange(start: .zero, end: Time(2, 1)),
                               words: caption(karaoke: k).words)
        for tenths in stride(from: Int64(0), to: 20, by: 1) {
            let t = Time(tenths, 10)
            #expect(burn.state(at: t)?.highlight == CaptionKaraoke.highlight(for: item, style: k, at: t))
        }
        #expect(burn.state(at: Time(5, 10))?.highlight?.words == 1..<2)
    }

    @Test func withoutKaraokeNothingIsLit() {
        let burn = CaptionBurnIn(captions: [caption(karaoke: nil)], library: .builtIn)
        #expect(burn.state(at: Time(5, 10))?.highlight == nil)
    }

    @Test func theBuilderPassesTheTrackStyleAndWordTimings() throws {
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        let item = CaptionItem(lines: ["so this works"], range: TimeRange(start: .zero, end: Time(2, 1)),
                               styleRef: "tiktok", words: caption(karaoke: nil).words)
        let id = try tl.replaceCaptions([item])
        try tl.setCaptionKaraoke(KaraokeStyle(), track: id)
        var settings = ExportSettings.proRes422HQMaster
        settings.captions = .burnIn
        let burn = try #require(ExportSourceBuilder.burnIn(for: tl, settings: settings))
        #expect(burn.captions[0].karaoke == KaraokeStyle())
        #expect(burn.captions[0].words.count == 3)
        #expect(burn.state(at: Time(5, 10))?.highlight?.words == 1..<2)
    }
}

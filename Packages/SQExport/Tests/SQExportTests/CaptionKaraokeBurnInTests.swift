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

    /// After an out look the next caption's first frame is evaluated one frame into its in look; the lit word stays the
    /// one at the real time (the Program monitor plans the highlight with the unshifted time).
    @Test func theHandoverShiftDoesNotMoveTheLitWord() throws {
        func template(_ keys: [(time: Time, value: Double, shape: SegmentShape)]) -> KeyframeTemplate {
            KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: keys)], duration: Time(1, 5))
        }
        var out = template([(.zero, 1, .linear), (Time(1, 5), 0, .linear)]); out.anchor = .end
        let fadeIn = template([(.zero, 0, .linear), (Time(1, 5), 1, .linear)])
        var lib = CaptionPresetLibrary.builtIn
        lib = lib.adding(CaptionLook(style: lib.style(for: "tiktok"), animation: out), id: "k-out")
        lib = lib.adding(CaptionLook(style: lib.style(for: "tiktok"), animation: fadeIn), id: "k-in")
        let fd = Time(1, 30)
        let start = fd * 15
        // Word times are relative to the caption start.
        let mid = Time(1, 60)
        let words = [CaptionWord(text: "gamma", range: TimeRange(start: .zero, end: mid)),
                     CaptionWord(text: "delta", range: TimeRange(start: mid, end: fd * 12))]
        let k = KaraokeStyle()
        let a = Caption(lines: ["alpha"], range: TimeRange(start: fd * 3, end: start), styleRef: "tiktok",
                        animationRef: CaptionLook.animationID(for: "k-out"), words: [], karaoke: k)
        let b = Caption(lines: ["gamma delta"], range: TimeRange(start: start, end: fd * 27), styleRef: "tiktok",
                        animationRef: CaptionLook.animationID(for: "k-in"), words: words, karaoke: k)
        let burn = CaptionBurnIn(captions: [a, b], library: lib, frameDuration: fd)
        let item = CaptionItem(lines: b.lines, range: b.range, words: words)
        let cut = burn.states(at: start, canvasWidth: 540, canvasHeight: 960)
        #expect(cut.map(\.index) == [1])
        #expect(cut[0].opacity > 0)
        #expect(cut[0].highlight == CaptionKaraoke.highlight(for: item, style: k, at: start))
        #expect(cut[0].highlight != CaptionKaraoke.highlight(for: item, style: k, at: start + fd))
    }
}

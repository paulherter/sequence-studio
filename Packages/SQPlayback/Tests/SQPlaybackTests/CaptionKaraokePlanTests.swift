import Foundation
import Testing
import SQCore
import SQText
@testable import SQPlayback

@Suite struct CaptionKaraokePlanTests {
    let canvas = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))

    func item() -> CaptionItem {
        let words = [("so", 0, 3), ("this", 4, 8), ("works", 9, 14)].map {
            CaptionWord(text: $0.0, range: TimeRange(start: Time(Int64($0.1), 10), end: Time(Int64($0.2), 10)))
        }
        return CaptionItem(lines: ["so this works"], range: TimeRange(start: .zero, end: Time(2, 1)), styleRef: "tiktok", words: words)
    }

    /// The caption must be on screen on every frame, also on the frames where the lit word changes: the plain caption
    /// is the same raster for the whole caption, so it never has to be made again at a word change.
    @Test func thePlainCaptionIsTheSameRasterOnEveryFrame() throws {
        let it = item()
        var plain = Set<GeneratorRef>(), lit = Set<GeneratorRef>()
        let frames = 60
        for f in 0..<frames {
            let t = canvas.frameDuration * Int64(f)
            guard it.range.contains(t) else { continue }
            let p = try CaptionPreview.plan(for: it, karaoke: KaraokeStyle(), canvas: canvas, at: t)
            plain.insert(p.plain)
            if let l = p.lit { lit.insert(l) }
        }
        #expect(plain.count == 1)        // one raster for the whole caption
        #expect(lit.count == 3)          // one small lit layer per word
    }

    @Test func theNextWordIsPreparedBeforeItStarts() throws {
        let it = item()
        let k = KaraokeStyle()
        let at0 = try CaptionPreview.plan(for: it, karaoke: k, canvas: canvas, at: .zero)
        let at5 = try CaptionPreview.plan(for: it, karaoke: k, canvas: canvas, at: Time(5, 10))
        #expect(at0.next == at5.lit)     // what is "next" while word 0 is lit is what word 1 will need
        let last = try CaptionPreview.plan(for: it, karaoke: k, canvas: canvas, at: Time(10, 10))
        #expect(last.next == nil)
    }

    @Test func theCaptionStaysVisibleWhileTheLitLayerIsNotReady() throws {
        // The plain raster is cached by itself; a cold lit layer does not make the caption wait.
        let it = item()
        TextGenerator.clearCache()
        let p = try CaptionPreview.plan(for: it, karaoke: KaraokeStyle(), canvas: canvas, at: Time(5, 10))
        try TextGenerator.prewarm(ref: p.plain)
        #expect(TextGenerator.isCached(ref: p.plain))
        let lit = try #require(p.lit)
        #expect(!TextGenerator.isCached(ref: lit))                 // cold: skipped, the plain caption is still drawn
        try TextGenerator.prewarm(ref: lit)
        let later = try CaptionPreview.plan(for: it, karaoke: KaraokeStyle(), canvas: canvas, at: Time(10, 10))
        #expect(TextGenerator.isCached(ref: later.plain))          // a word change never un-caches the caption
    }

    @Test func withoutKaraokeThereIsOnlyThePlainCaption() throws {
        let p = try CaptionPreview.plan(for: item(), karaoke: nil, canvas: canvas, at: Time(5, 10))
        #expect(p.lit == nil && p.next == nil)
    }
}

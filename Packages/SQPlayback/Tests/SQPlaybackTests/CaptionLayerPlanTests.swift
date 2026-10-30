import Foundation
import Testing
import SQCore
import SQText
@testable import SQPlayback

/// `CaptionLayerPlan` (the Windows Program monitor's captions) asks for the layers the Mac render loop draws: the plain
/// caption and its lit word, at the caption's box position and clip time.
@Suite struct CaptionLayerPlanTests {
    let format = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))

    func item(start: Int64 = 0) -> CaptionItem {
        let words = [("so", 0, 3), ("this", 4, 8), ("works", 9, 14)].map {
            CaptionWord(text: $0.0, range: TimeRange(start: Time(Int64($0.1), 10), end: Time(Int64($0.2), 10)))   // caption-local
        }
        return CaptionItem(lines: ["so this works"], range: TimeRange(start: Time(start, 1), end: Time(start + 2, 1)),
                           styleRef: "tiktok", words: words)
    }

    func timeline(_ items: [CaptionItem], karaoke: KaraokeStyle?) -> Timeline {
        var tl = Timeline(name: "c", format: format)
        tl.captionTracks = [CaptionTrack(items: items, karaoke: karaoke)]
        return tl
    }

    @Test func plainAndLitWordAtTheCaptionsPlace() throws {
        let it = item(start: 1)
        let tl = timeline([it], karaoke: KaraokeStyle())
        let t = Time(3, 2)
        let layers = CaptionLayerPlan.layers(tl, slots: tl.captionSlots(at: t), at: t, library: .builtIn) { _ in nil }
        let plan = try CaptionPreview.plan(for: it, karaoke: KaraokeStyle(), canvas: format.layoutFormat, at: t)
        #expect(layers.map(\.ref) == [plan.plain, try #require(plan.lit)])
        let at = CaptionPreview.position(for: it, canvas: format.layoutFormat)
        #expect(layers.allSatisfy { $0.position == at && $0.localTime == Time(1, 2) && $0.opacity == 1 })
        #expect(layers.allSatisfy { $0.duration == it.range.duration })
    }

    @Test func nothingOutsideCaptionsAndNoLitLayerWithoutKaraoke() throws {
        let tl = timeline([item(start: 1)], karaoke: nil)
        #expect(CaptionLayerPlan.layers(tl, slots: tl.captionSlots(at: Time(5, 1)), at: Time(5, 1), library: .builtIn) { _ in nil }
            .isEmpty)
        let one = CaptionLayerPlan.layers(tl, slots: tl.captionSlots(at: Time(3, 2)), at: Time(3, 2), library: .builtIn) { _ in nil }
        #expect(one.count == 1)
    }
}

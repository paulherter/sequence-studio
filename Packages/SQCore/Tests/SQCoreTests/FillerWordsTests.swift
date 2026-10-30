import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func t(_ ms: Int64) -> Time { Time(ms, 1000) }
private func word(_ s: String, _ a: Int64, _ b: Int64) -> CaptionWord { CaptionWord(text: s, range: TimeRange(start: t(a), end: t(b))) }

@Suite struct FillerWordsTests {
    @Test func listsAreLanguageAware() {
        #expect(FillerWords.isFiller("um", language: "en-US"))
        #expect(!FillerWords.isFiller("um", language: "de-DE"))      // German "um" is a real word
        #expect(FillerWords.isFiller("ähm", language: "de-DE"))
        #expect(FillerWords.isFiller("Äh,", language: "de-AT"))
        #expect(FillerWords.isFiller("Uh...", language: "en"))
        #expect(!FillerWords.isFiller("umbrella", language: "en-GB"))
        #expect(!FillerWords.isFiller("hello", language: "en-US"))
        #expect(FillerWords.isFiller("uhm", language: "fr-FR"))      // the neutral sounds hold everywhere
        #expect(!FillerWords.isFiller("um", language: "fr-FR"))
        #expect(FillerWords.isFiller("euh", language: "fr-FR"))
    }

    @Test func cutsAreFrameAlignedSortedAndMerged() {
        let words = [word("so", 0, 300), word("um", 1_010, 1_390), word("uh", 1_400, 1_700), word("yes", 2_000, 2_300)]
        let cuts = FillerWords.cuts(words: words, language: "en-US", frameDuration: fd)
        #expect(cuts == [TimeRange(start: Time(30, 30), end: Time(51, 30))])    // um + uh touch after snapping and join
        let de = FillerWords.cuts(words: words, language: "de-DE", frameDuration: fd)
        #expect(de == [TimeRange(start: Time(42, 30), end: Time(51, 30))])      // "um" is no German filler
        #expect(FillerWords.count(words: words, language: "de-DE") == 1)
    }

    @Test func fillersShorterThanAFrameAreDropped() {
        #expect(FillerWords.cuts(words: [word("uh", 1_000, 1_010)], language: "en", frameDuration: fd).isEmpty)
    }

    @Test func scanUsesTimedCaptionsAndReportsTheRest() {
        let timed = CaptionItem(lines: ["so um yes"], range: TimeRange(start: .zero, duration: t(3_000)),
                                words: [word("so", 0, 300), word("um", 1_000, 1_400), word("yes", 2_000, 2_300)])
        let untimed = CaptionItem(lines: ["uh no"], range: TimeRange(start: t(4_000), duration: t(1_000)))
        var tl = Timeline(name: "T", frameDuration: fd)
        tl.captionTracks = [CaptionTrack(items: [timed, untimed])]
        let scan = FillerWords.scan(tl, language: "en-US")
        #expect(scan.count == 1 && scan.cuts.count == 1)
        #expect(scan.untimedCaptions == 1)                           // spread timings would be a guess: not cut
        #expect(scan.total == scan.cuts[0].duration)
    }

    @Test func hiddenTracksAreIgnored() {
        let item = CaptionItem(lines: ["um"], range: TimeRange(start: .zero, duration: t(1_000)), words: [word("um", 100, 600)])
        var tl = Timeline(name: "T", frameDuration: fd)
        tl.captionTracks = [CaptionTrack(isVisible: false, items: [item])]
        #expect(FillerWords.scan(tl, language: "en").cuts.isEmpty)
    }
}

import Foundation
import Testing
import SQCore
@testable import SQEditorUI

@Suite struct CaptionSearchTests {
    @Test func transcriptMatchesAreFoundInOrderAndIgnoreCaseByDefault() {
        let m = TranscriptSearch.matches(in: "The cat sat. the CAT ran.", find: "cat", caseSensitive: false)
        #expect(m == [NSRange(location: 4, length: 3), NSRange(location: 17, length: 3)])
        #expect(TranscriptSearch.matches(in: "The cat sat. the CAT ran.", find: "cat", caseSensitive: true).count == 1)
        #expect(TranscriptSearch.matches(in: "abc", find: "", caseSensitive: false).isEmpty)
    }

    @Test func nextAndPreviousWalkTheMatchesAndWrap() {
        let m = [NSRange(location: 4, length: 3), NSRange(location: 17, length: 3), NSRange(location: 30, length: 3)]
        #expect(TranscriptSearch.step(m, from: 0, forward: true) == 0)
        #expect(TranscriptSearch.step(m, from: 4, forward: true) == 1)       // on the first: move on
        #expect(TranscriptSearch.step(m, from: 30, forward: true) == 0)      // wraps
        #expect(TranscriptSearch.step(m, from: 17, forward: false) == 0)
        #expect(TranscriptSearch.step(m, from: 4, forward: false) == 2)      // wraps backwards
        #expect(TranscriptSearch.step([], from: 0, forward: true) == nil)
    }

    @Test func captionMatchesStepThroughTimeBothWays() throws {
        func item(_ text: String, _ a: Int64) -> CaptionItem {
            CaptionItem(lines: [text], range: TimeRange(start: Time(a, 1), end: Time(a + 1, 1)))
        }
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try t.replaceCaptions([item("hello", 0), item("the cat", 2), item("nothing", 4), item("a cat again", 6)])
        let ids = t.captionTracks[0].items.map(\.id)
        #expect(t.captionMatch(find: "cat", caseSensitive: false, from: .zero, forward: true) == ids[1])
        #expect(t.captionMatch(find: "cat", caseSensitive: false, from: Time(2, 1), forward: true) == ids[3])
        #expect(t.captionMatch(find: "cat", caseSensitive: false, from: Time(6, 1), forward: true) == ids[1])    // wraps
        #expect(t.captionMatch(find: "cat", caseSensitive: false, from: Time(6, 1), forward: false) == ids[1])
        #expect(t.captionMatch(find: "cat", caseSensitive: false, from: Time(2, 1), forward: false) == ids[3])   // wraps back
        #expect(t.captionMatch(find: "dog", caseSensitive: false, from: .zero, forward: true) == nil)
    }

    @Test func nextAndPreviousAreOrderedByTimeAcrossTracks() throws {
        func item(_ a: Int64) -> CaptionItem { CaptionItem(lines: ["cat"], range: TimeRange(start: Time(a, 1), end: Time(a + 1, 1))) }
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try t.replaceCaptions([item(5)])
        t.captionTracks.append(CaptionTrack(items: [item(1), item(8)]))
        func start(_ id: CaptionItem.ID?) -> Time? { t.captionTracks.flatMap(\.items).first { $0.id == id }?.range.start }
        #expect(start(t.captionMatch(find: "cat", caseSensitive: false, from: Time(1, 1), forward: true)) == Time(5, 1))
        #expect(start(t.captionMatch(find: "cat", caseSensitive: false, from: Time(8, 1), forward: false)) == Time(5, 1))
    }
}

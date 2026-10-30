import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func cap(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: s(a), end: s(b)), styleRef: "style", animationRef: "anim")
}
private func timeline(_ items: [CaptionItem]) throws -> (Timeline, CaptionTrack.ID) {
    var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
    let id = try t.replaceCaptions(items)
    return (t, id)
}

/// Premiere-like caption tracks: named "Captions N", one look per track, sparse per-caption overrides.
@Suite struct CaptionTrackLookTests {
    @Test func firstCaptionTrackIsNamedCaptions1AndAddedOnesCountUp() throws {
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try t.replaceCaptions([cap("a", 0, 2)])
        #expect(t.captionTracks.map(\.name) == ["Captions 1"])
        let second = t.addCaptionTrack()
        #expect(t.captionTracks.map(\.name) == ["Captions 1", "Captions 2"])
        #expect(t.captionTrack(second)?.items.isEmpty == true)
        t.captionTracks[0].name = "Captions 3"      // a taken name is skipped, never duplicated
        _ = t.addCaptionTrack()
        #expect(Set(t.captionTracks.map(\.name)).count == 3)
    }

    @Test func manualCaptionOnEmptySequenceCreatesTheTrack() throws {
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try t.addCaption(at: s(1), duration: s(2))
        #expect(t.captionTracks.map(\.name) == ["Captions 1"])
    }

    @Test func trackLookChangesAllButOverriddenCaptions() throws {
        var (t, id) = try timeline([cap("a", 0, 2), cap("b", 2, 4), cap("c", 4, 6)])
        let b = t.captionTracks[0].items[1].id
        try t.setCaptionItemStyle([b], styleRef: "own")
        try t.setCaptionStyle(styleRef: "new", animationRef: "newAnim", track: id)
        #expect(t.captionTracks[0].items.map(\.styleRef) == ["new", "own", "new"])
        #expect(t.captionTracks[0].items.map(\.animationRef) == ["newAnim", "anim", "newAnim"])
    }

    @Test func resetToTrackLookClearsStyleAnimationAndPosition() throws {
        var (t, id) = try timeline([cap("a", 0, 2), cap("b", 2, 4)])
        try t.setCaptionStyle(styleRef: "track", animationRef: "trackAnim", track: id)
        let b = t.captionTracks[0].items[1].id
        try t.setCaptionItemStyle([b], styleRef: "own")
        try t.setCaptionItemAnimation([b], animationRef: "ownAnim")
        try t.setCaptionItemPosition([b], position: CaptionPosition(vertical: .top))
        #expect(t.captionTracks[0].items[1].styleOverridden)
        try t.resetCaptionItemsToTrackLook([b])
        let item = t.captionTracks[0].items[1]
        #expect(!item.styleOverridden && item.position == nil)
        #expect(item.styleRef == "track" && item.animationRef == "trackAnim")
    }

    @Test func resetOnLockedTrackThrowsAndChangesNothing() throws {
        var (t, _) = try timeline([cap("a", 0, 2)])
        let a = t.captionTracks[0].items[0].id
        try t.setCaptionItemStyle([a], styleRef: "own")
        t.captionTracks[0].isLocked = true
        let before = t
        #expect(throws: EditError.self) { try t.resetCaptionItemsToTrackLook([a]) }
        #expect(t == before)
    }

    @Test func trackLookOfSecondTrackLeavesFirstAlone() throws {
        var (t, first) = try timeline([cap("a", 0, 2)])
        let second = t.addCaptionTrack()
        _ = try t.addCaption(at: s(3), duration: s(1), track: second)
        try t.setCaptionStyle(styleRef: "one", track: first)
        try t.setCaptionStyle(styleRef: "two", track: second)
        #expect(t.captionTrack(first)?.items.first?.styleRef == "one")
        #expect(t.captionTrack(second)?.items.first?.styleRef == "two")
        #expect(t.captionTrackID(containing: t.captionTrack(second)!.items[0].id) == second)
    }

    @Test func overriddenCountsOnlyDeviatingCaptions() throws {
        var (t, id) = try timeline([cap("a", 0, 2), cap("b", 2, 4)])
        #expect(t.captionTrack(id)?.overriddenCount == 0)
        try t.setCaptionItemPosition([t.captionTracks[0].items[0].id], position: CaptionPosition(vertical: .top))
        try t.setCaptionItemStyle([t.captionTracks[0].items[1].id], styleRef: "own")
        #expect(t.captionTrack(id)?.overriddenCount == 2)
    }
}

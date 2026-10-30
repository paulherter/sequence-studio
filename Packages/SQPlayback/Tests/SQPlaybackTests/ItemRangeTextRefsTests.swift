import Foundation
import Testing
import SQCore
@testable import SQPlayback

// Item lanes: the texts a timeline shows at one time leave out the items of a Graphic that are outside their range.

@Suite struct ItemRangeTextRefsTests {
    private func ref(_ n: UInt8) -> GeneratorRef { GeneratorRef(kind: GeneratorRef.text, payload: Data([n])) }
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    private func item(_ r: GeneratorRef, _ range: TimeRange?) -> GraphicsLayer {
        var l = GraphicsLayer.text(r)
        l.range = range
        return l
    }

    /// A 10 s Graphic at 2 s holding `items`.
    private func graphic(_ items: [GraphicsLayer]) -> Clip {
        var c = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: s(2),
                     generator: .graphicsClip)
        c.graphics = GraphicsDocument(layers: items)
        return c
    }

    private func timeline(_ clips: [Clip]) -> Timeline {
        Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: clips)])
    }

    @Test func anItemOutsideItsRangeAtTheTimeIsLeftOut() {
        let whole = ref(1), ranged = ref(2), empty = ref(3)
        // The ranged item shows over clip-local 4 s ..< 6 s: timeline 6 s ..< 8 s.
        let tl = timeline([graphic([item(whole, nil), item(ranged, TimeRange(start: s(4), end: s(6))),
                                    item(empty, TimeRange(start: s(3), end: s(3)))])])
        func refs(_ t: Time?) -> Set<GeneratorRef> { RenderLoop.textRefs(tl, sequences: [:], at: t) }
        #expect(refs(nil) == [whole, ranged])                    // no time: every item that can show
        #expect(refs(s(6) - Time(1, 30)) == [whole])             // the frame before the range
        #expect(refs(s(6)) == [whole, ranged])                   // its first frame
        #expect(refs(s(8) - Time(1, 30)) == [whole, ranged])     // its last frame
        #expect(refs(s(8)) == [whole])                           // the end is exclusive
        #expect(refs(s(1)) == [whole])                           // before the clip: a ranged item is not shown either
        #expect(refs(s(20)) == [whole])
    }

    @Test func aTextUsedByAShownItemElsewhereStays() {
        // One text in two Graphics: out of range in the first, in range in the second at 15 s.
        let shared = ref(7)
        var later = graphic([item(shared, TimeRange(start: s(1), end: s(5)))])
        later.start = s(13)
        let tl = timeline([graphic([item(shared, TimeRange(start: s(0), end: s(2)))]), later])
        #expect(RenderLoop.textRefs(tl, sequences: [:], at: s(15)) == [shared])
        #expect(RenderLoop.textRefs(tl, sequences: [:], at: s(12) + Time(1, 2)).isEmpty)
    }

    @Test func aNestedSequenceKeepsItsItems() {
        // A nested sequence runs on its own time: its ranged items are not judged by the outer time.
        let inner = timeline([graphic([item(ref(4), TimeRange(start: s(4), end: s(6)))])])
        let outer = timeline([])
        #expect(RenderLoop.textRefs(outer, sequences: [inner.id: inner], at: s(1)) == [ref(4)])
    }
}

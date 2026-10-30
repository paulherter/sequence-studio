import Foundation
import Testing
import SQCore
@testable import SQPlayback

@Suite struct TextStandInsTests {
    private func ref(_ n: UInt8) -> GeneratorRef { GeneratorRef(kind: GeneratorRef.text, payload: Data([n])) }

    @Test func uncachedEditKeepsShowingTheLastRaster() {
        let s = TextStandIns(), clip = UUID(), a = ref(1), b = ref(2)
        var cached: Set<GeneratorRef> = [a]
        #expect(s.resolve(clip: clip, ref: a, isCached: { cached.contains($0) }) == a)
        #expect(s.resolve(clip: clip, ref: b, isCached: { cached.contains($0) }) == a)   // b still rendering
        cached.insert(b)
        #expect(s.resolve(clip: clip, ref: b, isCached: { cached.contains($0) }) == b)
    }

    @Test func nothingBeforeTheFirstRasterAndNoEvictedStandIn() {
        let s = TextStandIns(), clip = UUID(), a = ref(1), b = ref(2)
        #expect(s.resolve(clip: clip, ref: a, isCached: { _ in false }) == nil)
        _ = s.resolve(clip: clip, ref: a, isCached: { $0 == a })
        #expect(s.resolve(clip: clip, ref: b, isCached: { _ in false }) == nil)           // a was evicted
        _ = s.resolve(clip: clip, ref: a, isCached: { $0 == a })
        s.prune(keeping: [])
        #expect(s.resolve(clip: clip, ref: b, isCached: { $0 == a }) == nil)
    }

    @Test func clipsSharingALayerIdKeepSeparateStandIns() {
        // Two graphics clips made from one template: the same text layer id, told apart by the graphics clip.
        let s = TextStandIns(), layer = UUID(), g1 = UUID(), g2 = UUID(), a = ref(1), b = ref(2)
        _ = s.resolve(clip: layer, group: g1, ref: a, isCached: { $0 == a })
        #expect(s.resolve(clip: layer, group: g2, ref: b, isCached: { $0 == a }) == nil)      // g2 never showed anything
        #expect(s.resolve(clip: layer, group: g1, ref: b, isCached: { $0 == a }) == a)
        s.prune(keeping: [g2])                                                                // g1 left the timeline
        #expect(s.resolve(clip: layer, group: g1, ref: b, isCached: { $0 == a }) == nil)
    }
}

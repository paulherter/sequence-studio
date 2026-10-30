import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct RenderCacheSubstitutionTests {
    let ctx = RenderCacheContext(rendererID: "r1", workingSpace: "rec709")
    private let blur = ClipEffect(kind: ClipEffect.gaussianBlurKind)

    private func clip(_ start: Int64, _ len: Int64, effects: [ClipEffect] = []) -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(len)), start: s(start), effects: effects)
    }

    @Test func cachedHeavySegmentBecomesOneLayerOthersStayLive() {
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip(0, 2, effects: [blur]), clip(2, 2)])])
        let segs = RenderCachePlan.segments(of: t, context: ctx)
        var idx = RenderCacheIndex()
        idx.record(key: segs[0].key, bytes: 1, duration: s(2), now: Date())
        idx.record(key: segs[1].key, bytes: 1, duration: s(2), now: Date())     // light segment: never substituted
        let shown = t.withRenderCache(segments: segs, index: idx)
        #expect(shown.renderCacheSpans.count == 1)
        let at = shown.videoLayers(at: Time(3, 2))
        #expect(at.count == 1 && at[0].media == RenderCacheMedia.id(forKey: segs[0].key) && at[0].sourceTime == Time(3, 2))
        #expect(shown.videoLayers(at: s(3)) == t.videoLayers(at: s(3)))
        #expect(t.videoLayers(at: Time(3, 2)).first?.media == t.tracks[0].clips[0].media)
    }

    @Test func spansAreNeverEncodedAndEditDropsTheSpan() throws {
        var t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip(0, 2, effects: [blur])])])
        let segs = RenderCachePlan.segments(of: t, context: ctx)
        var idx = RenderCacheIndex()
        idx.record(key: segs[0].key, bytes: 1, duration: s(2), now: Date())
        let shown = t.withRenderCache(segments: segs, index: idx)
        let data = try JSONEncoder().encode(shown)
        #expect(try JSONDecoder().decode(Timeline.self, from: data).renderCacheSpans.isEmpty)
        var edited = t.tracks[0].clips[0]
        edited.effects = [blur, blur]
        t.tracks[0] = Track(id: t.tracks[0].id, kind: .video, clips: [edited])
        #expect(t.withRenderCache(segments: RenderCachePlan.segments(of: t, context: ctx), index: idx).renderCacheSpans.isEmpty)
    }

    @Test func transitionNeighborChangesTheKey() {
        let a = clip(0, 3), b = clip(3, 3)
        let tr = Transition(kind: .crossDissolve, duration: Time(1, 1), outgoing: a.id, incoming: b.id)
        var t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [a, b], transitions: [tr])])
        let before = RenderCachePlan.segments(of: t, context: ctx)[0].key
        var b2 = b
        b2.media = UUID()
        t.tracks[0] = Track(id: t.tracks[0].id, kind: .video, clips: [a, b2], transitions: [tr])
        #expect(RenderCachePlan.segments(of: t, context: ctx)[0].key != before)
    }

    @Test func mediaIDFollowsTheKey() {
        #expect(RenderCacheMedia.id(forKey: "00112233445566778899aabbccddeeff").uuidString == "00112233-4455-6677-8899-AABBCCDDEEFF")
    }
}

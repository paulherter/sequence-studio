import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// 20 frames half a second apart; the matte vanishes from 4.0 to 5.5 s.
private let weakSamples: [MagicTrackHealth.Sample] = (0..<20).map {
    .init(pts: Double($0) * 0.5, area: (8...10).contains($0) ? 0 : 0.5)
}

@MainActor @Suite struct MagicTrackHealthCacheTests {
    private let fd = Time(1, 30)
    private func tracked() -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(seconds: 10)),
                     start: Time(seconds: 100), mediaDuration: Time(seconds: 10))
        var m = ClipMask.make(.rectangle, name: "Magic")
        m.source = .magic
        m.magic = MagicSelection(points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero)])
        c.masks = [m]
        return c
    }
    private func timeline(_ c: Clip) -> Timeline {
        var t = Track(kind: .video); try! t.overwrite(c)
        return Timeline(name: "T", frameDuration: fd, tracks: [t])
    }

    @Test func sequenceWithoutTrackedMaskSaysSo() {
        let cache = MagicTrackHealthCache(samples: { _ in [] })
        var c = tracked(); c.masks = []
        #expect(cache.nextWeakStart(after: .zero, in: timeline(c)) == .noTrackedMask)
        #expect(cache.nextWeakStart(after: .zero, in: nil) == .noTrackedMask)
    }

    @Test func firstAskIsPendingThenFindsTheWeakStretch() async throws {
        let cache = MagicTrackHealthCache(samples: { _ in weakSamples })
        let c = tracked(), tl = timeline(c)
        #expect(cache.nextWeakStart(after: .zero, in: tl) == .pending)
        for _ in 0..<200 where cache.isPending(c) { try await Task.sleep(for: .milliseconds(10)) }
        guard case .found(let t) = cache.nextWeakStart(after: .zero, in: tl) else { Issue.record("no stretch"); return }
        #expect(abs(Double(t.value) / Double(t.timescale) - 104) < 0.1)
        #expect(cache.nextWeakStart(after: Time(seconds: 105), in: tl) == .none)
    }

    @Test func forgetClearsAndNotifies() async throws {
        let cache = MagicTrackHealthCache(samples: { _ in weakSamples })
        var forgot = 0, changed = 0
        cache.onForget = { forgot += 1 }
        cache.onChange = { changed += 1 }
        let c = tracked()
        _ = cache.weakSpans(for: c)
        for _ in 0..<200 where cache.isPending(c) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cache.weakSpans(for: c) != nil)
        cache.forget()
        #expect(forgot == 1 && changed >= 2)
        #expect(cache.weakSpans(for: c) == nil)
    }

    @Test func messagesMatchTheMac() {
        #expect(MagicTrackHealthCache.message(for: .found(.zero)) == nil)
        #expect(MagicTrackHealthCache.message(for: .none) == "No weak tracking after the playhead.")
    }
}

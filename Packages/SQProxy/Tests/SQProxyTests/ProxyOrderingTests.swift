import Foundation
import Testing
import SQCore
@testable import SQProxy

@Suite struct ProxyOrderingTests {
    private func clip(_ media: UUID, at start: Int64) -> Clip {
        Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(start, 1))
    }

    @Test func firstUseIsTheEarliestClipStartAcrossTracks() {
        let a = UUID(), b = UUID()
        let t = Timeline(name: "T", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [
            Track(kind: .video, clips: [clip(a, at: 50), clip(b, at: 0)]),
            Track(kind: .video, clips: [clip(a, at: 20)]),
        ])
        let use = ProxyOrdering.firstUse(in: t)
        #expect(use[a] == Time(20, 1))
        #expect(use[b] == Time(0, 1))
        #expect(ProxyOrdering.firstUse(in: nil).isEmpty)
    }

    @Test func timelineMediaFirstThenBinOnlyInBinOrder() {
        let bin1 = UUID(), late = UUID(), early = UUID(), bin2 = UUID()
        let order = ProxyOrdering.sorted([bin1, late, early, bin2], firstUse: [late: Time(30, 1), early: Time(5, 1)])
        #expect(order == [early, late, bin1, bin2])
    }

    @Test func equalPositionKeepsBinOrder() {
        let a = UUID(), b = UUID()
        #expect(ProxyOrdering.sorted([a, b], firstUse: [a: .zero, b: .zero]) == [a, b])
    }
}

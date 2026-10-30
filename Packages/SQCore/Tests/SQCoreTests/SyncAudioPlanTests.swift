import Foundation
import Testing
@testable import SQCore

@Suite("SyncAudioPlan")
struct SyncAudioPlanTests {
    private func clip(_ name: String, kind: TrackKind, at frame: Int64, link: UUID? = nil) -> Clip {
        let fd = Time(1, 30)
        var c = Clip(name: name, media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: fd * 100), start: fd * frame, link: link)
        c.mediaDuration = fd * 100
        return c
    }

    @Test func earliestClipIsTheReferenceAndLinkedPartnersAreSkipped() throws {
        let link = UUID()
        let ref = clip("ref", kind: .audio, at: 0)
        let a = clip("a", kind: .audio, at: 300, link: link), v = clip("v", kind: .video, at: 300, link: link)
        let b = clip("b", kind: .audio, at: 700)
        var t1 = Track(kind: .audio), t2 = Track(kind: .audio), t3 = Track(kind: .video)
        try t1.overwrite(ref); try t1.overwrite(b); try t2.overwrite(a); try t3.overwrite(v)
        let t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t3, t1, t2])
        let plan = try #require(t.syncAudioPlan(selection: [ref.id, a.id, v.id, b.id]))
        #expect(plan.reference == ref.id)
        #expect(plan.targets == [a.id, b.id])
    }

    @Test func oneClipHasNoPlan() throws {
        let ref = clip("ref", kind: .audio, at: 0)
        var tr = Track(kind: .audio)
        try tr.overwrite(ref)
        let t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [tr])
        #expect(t.syncAudioPlan(selection: [ref.id]) == nil)
        #expect(t.syncAudioPlan(selection: []) == nil)
    }
}

import Foundation
import Testing
@testable import SQCore

@Suite struct SpokenSearchTests {
    private func project() -> (Project, MediaRef, MediaRef) {
        let a = MediaRef(name: "A001", path: "/x/a.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(60, 1))
        let b = MediaRef(name: "B002", path: "/x/b.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(60, 1))
        var p = Project(name: "P", media: [a, b])
        let ca = Clip(name: "a", media: a.id, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let cb = Clip(name: "b", media: b.id, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(10, 1))
        var tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [ca, cb])])
        let item = CaptionItem(lines: ["Das ist ein Café"], range: TimeRange(start: Time(12, 1), duration: Time(2, 1)))
        tl.captionTracks = [CaptionTrack(items: [item])]
        p.timelines = [tl]
        return (p, a, b)
    }

    @Test func findsMediaUnderMatchingCaption() {
        let (p, a, b) = project()
        #expect(p.mediaIDs(spoken: "cafe") == [b.id])
        #expect(p.mediaIDs(spoken: " ").isEmpty)
        #expect(p.mediaIDs(spoken: "nope").isEmpty)
        #expect(!p.mediaIDs(spoken: "cafe").contains(a.id))
    }

    @Test func smartBinMatchesSpokenOnlyWhenEnabled() {
        let (_, _, b) = project()
        var bin = SmartBin(name: "s", text: "cafe")
        #expect(!bin.matches(b, isUsed: true, isOffline: false, spoken: [b.id]))
        bin.searchesSpoken = true
        #expect(bin.matches(b, isUsed: true, isOffline: false, spoken: [b.id]))
        #expect(!bin.matches(b, isUsed: true, isOffline: false, spoken: []))
    }

    @Test func smartBinKeyRoundTrips() throws {
        let bin = SmartBin(name: "s", text: "x", searchesSpoken: true)
        let back = try JSONDecoder().decode(SmartBin.self, from: JSONEncoder().encode(bin))
        #expect(back.searchesSpoken == true)
    }
}

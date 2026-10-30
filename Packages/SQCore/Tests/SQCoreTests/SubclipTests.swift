import Foundation
import Testing
@testable import SQCore

// Make Subclip (v57): a range of a media item becomes its own Project item. It plays the same file; its In/Out start at
// the range (soft bounds, like Premiere with "Restrict trims" off) and its poster frame at the range start.

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func project() -> (Project, MediaRef.ID, Bin.ID) {
    var p = Project(name: "P")
    let m = MediaRef(name: "Interview.mov", path: "/v/Interview.mov", fingerprint: MediaFingerprint(size: 42), duration: s(60),
                     label: .iris)
    let other = MediaRef(name: "Other.mov", path: "/v/Other.mov", fingerprint: MediaFingerprint(size: 7), duration: s(10))
    p.add(m); p.add(other)
    let bin = p.newBin(name: "Footage")!
    _ = p.move([.media(m.id), .media(other.id)], to: bin)
    return (p, m.id, bin)
}

@Suite struct SubclipTests {
    @Test func makesAMediaItemOverTheRange() throws {
        var (p, m, bin) = project()
        let id = try p.makeSubclip(of: m, range: TimeRange(start: s(10), end: s(20)))
        let sub = try #require(p.media(id))
        let parent = try #require(p.media(m))
        #expect(sub.id != m)
        #expect(sub.path == parent.path && sub.fingerprint == parent.fingerprint && sub.duration == parent.duration)
        #expect(sub.label == parent.label)
        #expect(sub.subclip == Subclip(parent: m, range: TimeRange(start: s(10), end: s(20))))
        #expect(sub.name == "Interview.mov Subclip")
        #expect(sub.posterTime == s(10))
        #expect(p.sourceMarks[id] == SourceMarks(markIn: s(10), markOut: s(20)))
        // Filed right after its parent, in the parent's bin.
        let kids = try #require(p.rootBin.bin(bin)).children.map(\.ref)
        #expect(kids.firstIndex(of: .media(id)) == kids.firstIndex(of: .media(m)).map { $0 + 1 })
        // Comes after the parent in `media`, so a path lookup still finds the parent first.
        #expect(p.media.first { $0.path == parent.path }?.id == m)
    }

    @Test func namesCountUp() throws {
        var (p, m, _) = project()
        _ = try p.makeSubclip(of: m, range: TimeRange(start: s(1), end: s(2)))
        let second = try p.makeSubclip(of: m, range: TimeRange(start: s(3), end: s(4)))
        #expect(p.media(second)?.name == "Interview.mov Subclip 2")
        let named = try p.makeSubclip(of: m, range: TimeRange(start: s(3), end: s(4)), name: "Answer 1")
        #expect(p.media(named)?.name == "Answer 1")
    }

    @Test func subclipOfASubclipPointsAtTheFile() throws {
        var (p, m, _) = project()
        let a = try p.makeSubclip(of: m, range: TimeRange(start: s(10), end: s(30)))
        let b = try p.makeSubclip(of: a, range: TimeRange(start: s(12), end: s(15)))
        #expect(p.media(b)?.subclip?.parent == m)
        #expect(p.media(b)?.isSubclip == true)
        #expect(p.media(m)?.isSubclip == false)
    }

    @Test func rangeIsClampedToTheMedia() throws {
        var (p, m, _) = project()
        let id = try p.makeSubclip(of: m, range: TimeRange(start: s(-5), end: s(90)))
        #expect(p.media(id)?.subclip?.range == TimeRange(start: s(0), end: s(60)))
    }

    @Test func refusesUnknownMediaAndEmptyRanges() {
        var (p, m, _) = project()
        let before = p
        #expect(throws: EditError.clipNotFound) { try p.makeSubclip(of: UUID(), range: TimeRange(start: s(0), end: s(1))) }
        #expect(throws: EditError.emptyClip) { try p.makeSubclip(of: m, range: TimeRange(start: s(70), end: s(80))) }
        #expect(throws: EditError.emptyClip) { try p.makeSubclip(of: m, range: TimeRange(start: s(5), end: s(5))) }
        #expect(p == before)
    }

    @Test func subclipRoundTripsAndOldMediaDecodesWithout() throws {
        var (p, m, _) = project()
        let id = try p.makeSubclip(of: m, range: TimeRange(start: s(10), end: s(20)))
        let ref = try #require(p.media(id))
        let back = try JSONDecoder().decode(MediaRef.self, from: JSONEncoder().encode(ref))
        #expect(back == ref)
        let plain = try JSONEncoder().encode(try #require(p.media(m)))
        let obj = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(obj["subclip"] == nil)
    }
}

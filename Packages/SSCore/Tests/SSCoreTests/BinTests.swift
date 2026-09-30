import Foundation
import Testing
@testable import SSCore

@Suite struct BinTests {
    func ref(_ name: String) -> MediaRef {
        MediaRef(name: name, path: "/x/\(name)", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1))
    }

    func project() -> (Project, [MediaRef]) {
        let ms = ["b.mov", "a.mov", "c.mov"].map(ref)
        var p = Project(name: "P", timelines: [Timeline(name: "Seq", frameDuration: Time(1, 30), tracks: [])])
        ms.forEach { p.add($0) }
        return (p, ms)
    }

    @Test func newProjectFilesEverythingInRoot() {
        let (p, ms) = project()
        #expect(p.rootBin.children.count == 4)
        #expect(p.rootBin.mediaIDs == ms.map(\.id))
        #expect(p.rootBin.contains(.sequence(p.timelines[0].id)))
    }

    @Test func addMediaTwiceKeepsOneEntry() {
        var (p, ms) = project()
        p.add(ms[0])
        #expect(p.rootBin.allRefs.count == 4)
    }

    @Test func newBinAndRename() {
        var (p, _) = project()
        let b = p.newBin(name: "Day 1")!
        let inner = p.newBin(name: "Inner", in: b)!
        #expect(p.bin(inner)?.name == "Inner")
        #expect(p.rootBin.parent(of: .bin(inner)) == b)
        do { let r = p.renameBin(b, to: "Day 2"); #expect(r) }
        #expect(p.bin(b)?.name == "Day 2")
        do { let r = p.renameBin(b, to: "  "); #expect(!r) }
        do { let r = p.renameBin(UUID(), to: "x"); #expect(!r) }
        #expect(p.newBin(in: UUID()) == nil)
    }

    @Test func moveItemsBetweenBins() {
        var (p, ms) = project()
        let b = p.newBin()!
        do { let r = p.move([.media(ms[0].id), .media(ms[2].id)], to: b); #expect(r) }
        #expect(p.bin(b)?.mediaIDs == [ms[0].id, ms[2].id])
        #expect(p.rootBin.parent(of: .media(ms[0].id)) == b)
        #expect(p.rootBin.allRefs.count == 5)
        // reorder inside the destination, index counts after removal
        do { let r = p.move([.media(ms[2].id)], to: b, at: 0); #expect(r) }
        #expect(p.bin(b)?.mediaIDs == [ms[2].id, ms[0].id])
        // back to root
        do { let r = p.move([.media(ms[0].id)], to: p.rootBin.id, at: 0); #expect(r) }
        #expect(p.rootBin.children.first?.ref == .media(ms[0].id))
    }

    @Test func moveRefusesUnknownAndDoesNotPartiallyApply() {
        var (p, ms) = project()
        let b = p.newBin()!
        let before = p
        do { let r = p.move([.media(ms[0].id), .media(UUID())], to: b); #expect(!r) }
        do { let r = p.move([.media(ms[0].id)], to: UUID()); #expect(!r) }
        #expect(p == before)
    }

    @Test func moveCannotCreateCycles() {
        var (p, _) = project()
        let a = p.newBin(name: "A")!
        let b = p.newBin(name: "B", in: a)!
        let c = p.newBin(name: "C", in: b)!
        let before = p
        do { let r = p.move([.bin(a)], to: a); #expect(!r) }
        do { let r = p.move([.bin(a)], to: c); #expect(!r) }
        do { let r = p.move([.bin(b)], to: c); #expect(!r) }
        do { let r = p.move([.bin(p.rootBin.id)], to: a); #expect(!r) }
        #expect(p == before)
        do { let r = p.move([.bin(c)], to: a); #expect(r) }
        #expect(p.rootBin.parent(of: .bin(c)) == a)
    }

    @Test func deleteBinMovesChildrenToParentInPlace() {
        var (p, ms) = project()
        let a = p.newBin(name: "A")!
        let b = p.newBin(name: "B", in: a)!
        p.move([.media(ms[0].id)], to: a)
        p.move([.media(ms[1].id)], to: b)
        let i = p.rootBin.children.firstIndex { $0.ref == .bin(a) }!
        do { let r = p.deleteBin(a); #expect(r) }
        #expect(p.bin(a) == nil)
        #expect(p.rootBin.children[i].ref == .bin(b))
        #expect(p.rootBin.children[i + 1].ref == .media(ms[0].id))
        #expect(p.bin(b)?.mediaIDs == [ms[1].id])
        #expect(Set(p.rootBin.mediaIDs) == Set(ms.map(\.id)))
        do { let r = p.deleteBin(p.rootBin.id); #expect(!r) }
        do { let r = p.deleteBin(UUID()); #expect(!r) }
    }

    @Test func sortByNameIsStableAndReversible() {
        var (p, ms) = project()
        let bin = p.newBin(name: "x")!
        let dup1 = ref("a.mov"), dup2 = ref("a.mov")
        p.add(dup1); p.add(dup2)
        p.move([.media(dup2.id), .media(dup1.id), .media(ms[0].id)], to: bin)   // b, then the two "a.mov"
        p.sortBin(bin, by: .name)
        #expect(p.bin(bin)?.mediaIDs == [dup2.id, dup1.id, ms[0].id])    // equal names keep order
        p.sortBin(bin, by: .name, ascending: false)
        #expect(p.bin(bin)?.mediaIDs == [ms[0].id, dup2.id, dup1.id])
    }

    @Test func sortByKindPutsBinsFirstThenSequencesThenMedia() {
        var (p, ms) = project()
        let b = p.newBin(name: "Z")!
        p.sortBin(p.rootBin.id, by: .kind)
        let refs = p.rootBin.children.map(\.ref)
        #expect(refs.first == .bin(b))
        #expect(refs[1] == .sequence(p.timelines[0].id))
        #expect(refs.dropFirst(2) == [.media(ms[0].id), .media(ms[1].id), .media(ms[2].id)])
    }

    @Test func normalizeDropsStaleAndDuplicatesAndFilesOrphans() {
        var (p, ms) = project()
        p.rootBin.children.append(.media(UUID()))
        p.rootBin.children.append(.media(ms[0].id))
        p.rootBin.children.removeAll { $0.ref == .media(ms[2].id) }
        p.normalizeBins()
        #expect(p.rootBin.allRefs.count == 4)
        #expect(p.rootBin.children.last?.ref == .media(ms[2].id))
    }
}

@Suite struct SourceMarksTests {
    let m = UUID()

    @Test func setAndClear() {
        var p = Project(name: "P")
        p.setSourceIn(Time(2, 1), for: m)
        p.setSourceOut(Time(5, 1), for: m)
        #expect(p.sourceMarks(for: m).range == TimeRange(start: Time(2, 1), end: Time(5, 1)))
        p.clearSourceIn(for: m)
        #expect(p.sourceMarks(for: m) == SourceMarks(markIn: nil, markOut: Time(5, 1)))
        #expect(p.sourceMarks(for: m).range == nil)
        p.clearSourceOut(for: m)
        #expect(p.sourceMarks[m] == nil)
    }

    @Test func crossingMarksClearTheOtherSide() {
        var p = Project(name: "P")
        p.setSourceIn(Time(2, 1), for: m)
        p.setSourceOut(Time(5, 1), for: m)
        p.setSourceIn(Time(6, 1), for: m)
        #expect(p.sourceMarks(for: m) == SourceMarks(markIn: Time(6, 1), markOut: nil))
        p.setSourceOut(Time(3, 1), for: m)
        #expect(p.sourceMarks(for: m) == SourceMarks(markIn: nil, markOut: Time(3, 1)))
    }

    @Test func clearAll() {
        var p = Project(name: "P")
        p.setSourceIn(Time(1001, 30000), for: m)
        p.clearSourceMarks(for: m)
        #expect(p.sourceMarks.isEmpty)
    }
}

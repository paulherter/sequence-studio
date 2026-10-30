import Foundation
import Testing
@testable import SQCore

/// One file is one asset: a relink onto a path another item holds, and a linked original next to its imported copy,
/// fold into one item and the clips follow.
@Suite struct MergeMediaTests {
    private let fd = Time(1, 30)

    private func ref(_ path: String, size: Int64 = 100) -> MediaRef {
        MediaRef(name: URL(fileURLWithPath: path).lastPathComponent, path: path, fingerprint: MediaFingerprint(size: size))
    }

    private func clip(_ m: MediaRef) -> Clip {
        Clip(name: m.name, media: m.id, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
    }

    private func project(_ media: [MediaRef], clips: [Clip]) -> Project {
        Project(name: "t", media: media, timelines: [Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd),
                                                               tracks: [Track(kind: .video, clips: clips)])])
    }

    private func clipMedia(_ p: Project) -> [MediaRef.ID] { p.timelines.flatMap { $0.tracks.flatMap { $0.clips.map(\.media) } } }

    @Test func relinkOntoAHeldPathMergesAndClipsFollow() {
        let copy = ref("/P/Files/Imported/a.mov"), linked = ref("/Users/x/a.mov")
        var p = project([copy, linked], clips: [clip(copy), clip(linked)])
        p.relink([linked.id: copy.path])
        #expect(p.media.map(\.id) == [copy.id])
        #expect(clipMedia(p) == [copy.id, copy.id])
        #expect(p.rootBin.mediaIDs == [copy.id])
    }

    @Test func relinkToAFreePathKeepsIdentity() {
        let linked = ref("/Users/x/a.mov")
        var p = project([linked], clips: [clip(linked)])
        p.relink([linked.id: "/P/Files/Imported/a.mov"])
        #expect(p.media.map(\.id) == [linked.id] && p.media[0].path == "/P/Files/Imported/a.mov")
        #expect(clipMedia(p) == [linked.id])
    }

    @Test func twoRelinksToOnePathMakeOneItem() {
        let a = ref("/o1/a.mov"), b = ref("/o2/a.mov")
        var p = project([a, b], clips: [clip(a), clip(b)])
        p.relink([a.id: "/P/Imported/a.mov", b.id: "/P/Imported/a.mov"])
        #expect(p.media.count == 1)
        #expect(Set(clipMedia(p)) == [p.media[0].id])
    }

    @Test func mergeCarriesSourceMarksWhenKeeperHasNone() {
        let copy = ref("/P/Imported/a.mov"), linked = ref("/o/a.mov")
        var p = project([copy, linked], clips: [clip(linked)])
        p.sourceMarks[linked.id] = SourceMarks(markIn: Time(1, 1))
        p.relink([linked.id: copy.path])
        #expect(p.sourceMarks[copy.id] != nil && p.sourceMarks[linked.id] == nil)
    }

    @Test func repairFoldsLinkedOriginalIntoImportedCopy() {
        let copy = ref("/P/Files/Imported/a.mov"), linked = ref("/Users/x/a.mov"), other = ref("/Users/x/b.mov", size: 7)
        var p = project([linked, copy, other], clips: [clip(linked), clip(other)])
        let n = p.mergeLinkedOriginals(intoCopiesIn: "/P/Files/Imported/") { orig, imported in orig.id == linked.id && imported.id == copy.id }
        #expect(n == 1)
        #expect(Set(p.media.map(\.id)) == [copy.id, other.id])
        #expect(clipMedia(p) == [copy.id, other.id])
    }

    @Test func repairLeavesDifferentFilesAlone() {
        let copy = ref("/P/Files/Imported/a.mov"), linked = ref("/Users/x/a.mov")
        var p = project([linked, copy], clips: [clip(linked)])
        #expect(p.mergeLinkedOriginals(intoCopiesIn: "/P/Files/Imported/") { _, _ in false } == 0)
        #expect(p.media.count == 2)
    }

    @Test func subclipsSharingTheParentPathAreNotFolded() {
        let parent = ref("/o/a.mov")
        var sub = ref("/o/a.mov"); sub.subclip = Subclip(parent: parent.id, range: TimeRange(start: .zero, duration: Time(1, 1)))
        var p = project([parent, sub], clips: [clip(sub)])
        p.relink([parent.id: "/P/Imported/a.mov", sub.id: "/P/Imported/a.mov"])
        #expect(p.media.count == 2)
        #expect(clipMedia(p) == [sub.id])
    }

    @Test func mergeRepointsSubclipParentsAndCarriesMetadata() {
        let copy = ref("/P/Imported/a.mov"), linked = ref("/o/a.mov")
        var sub = ref("/o/a.mov"); sub.subclip = Subclip(parent: linked.id, range: TimeRange(start: .zero, duration: Time(1, 1)))
        var l = linked
        l.label = .rose; l.posterTime = Time(2, 1); l.sourceMarkers = [Marker(time: Time(1, 1), name: "m")]
        var p = project([copy, l, sub], clips: [clip(l)])
        p.relink([l.id: copy.path])
        #expect(p.media.count == 2)
        #expect(p.media.first { $0.id == sub.id }?.subclip?.parent == copy.id)
        let kept = p.media.first { $0.id == copy.id }
        #expect(kept?.label == .rose && kept?.posterTime == Time(2, 1) && kept?.sourceMarkers?.count == 1)
    }

    @Test func repairSkipsSubclips() {
        let copy = ref("/P/Files/Imported/a.mov")
        var sub = ref("/o/a.mov"); sub.subclip = Subclip(parent: UUID(), range: TimeRange(start: .zero, duration: Time(1, 1)))
        var p = project([sub, copy], clips: [clip(sub)])
        #expect(p.mergeLinkedOriginals(intoCopiesIn: "/P/Files/Imported/") { _, _ in true } == 0)
    }

    @Test func mergeRepointsEmbeddedLUTs() {
        let copy = ref("/P/Imported/a.mov"), linked = ref("/o/a.mov")
        var c = clip(copy)
        var fx = ClipEffect(kind: "color")
        fx.grade = ColorGradeData(inputLUT: .embedded(linked.id), look: .embedded(linked.id))
        var graph = ClipEffect(kind: "colorGraph")
        var g = ColorGraph()
        g.inputLUT = .embedded(linked.id)
        g.steps[0].lut = .embedded(linked.id)
        graph.colorGraph = g
        c.effects = [fx, graph]
        var p = project([copy, linked], clips: [c])
        p.relink([linked.id: copy.path])
        let e = p.timelines[0].tracks[0].clips[0].effects
        #expect(e[0].grade?.inputLUT == .embedded(copy.id) && e[0].grade?.look == .embedded(copy.id))
        #expect(e[1].colorGraph?.inputLUT == .embedded(copy.id) && e[1].colorGraph?.steps[0].lut == .embedded(copy.id))
    }
}

import Foundation
import Testing
import SQCore
@testable import SQEditorUI

private func ref(_ name: String, path: String? = nil, w: Int = 3840, dur: Time = Time(10, 1)) -> MediaRef {
    let v = VideoTrackInfo(width: w, height: 2160, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                           nominalFrameDuration: Time(1001, 30000), isVariableFrameRate: false)
    return MediaRef(name: name, path: path ?? "/nonexistent/\(name)", fingerprint: MediaFingerprint(size: 1),
                    duration: dur, info: MediaInfo(duration: dur, video: v))
}

@MainActor final class Recorder { var edits: [(Project, String)] = [] }

@MainActor private func makeModel(_ p: Project = Project(name: "P"),
                                  probe: @escaping ProjectPanelModel.Probe = { url in ref(url.lastPathComponent, path: url.path) })
    -> (ProjectPanelModel, Recorder) {
    let rec = Recorder()
    let m = ProjectPanelModel(project: p, probe: probe, onEdit: { rec.edits.append(($0, $1)) })
    return (m, rec)
}

@MainActor @Suite struct ProjectPanelModelTests {
    @Test func formatString() {
        #expect(ProjectPanelModel.formatString(ref("a")) == "3840×2160 29.97 H.264 4:2:2 10-bit")
        var r = ref("b"); r.info = nil
        #expect(ProjectPanelModel.formatString(r) == "")
    }

    @Test func durationTimecode() {
        #expect(ProjectPanelModel.durationString(ref("a", dur: Time(1001, 30000) * (30 * 3725))) == "01:02:05:00")
        // 301 frames at 29.97 -> 00:00:10:01 (rounded fps 30)
        let d = Time(1001, 30000) * 301
        #expect(ProjectPanelModel.durationString(ref("a", dur: d)) == "00:00:10:01")
    }

    @Test func importAddsToCurrentBinInOneUndoStep() async {
        let (m, rec) = makeModel()
        let bin = m.newBin()!
        rec.edits.removeAll()
        m.currentBin = bin
        await m.importFiles([URL(fileURLWithPath: "/x/a.mov"), URL(fileURLWithPath: "/x/b.mov")])
        #expect(rec.edits.count == 1)
        #expect(m.project.media.count == 2)
        #expect(m.project.bin(bin)!.mediaIDs.count == 2)
        #expect(m.project.rootBin.children.count == 1)
    }

    // Review finding 37: the same file dropped twice while the first probe still ran was added twice.
    @Test func overlappingImportsOfOneFileAddItOnce() async {
        let (m, _) = makeModel(probe: { url in
            try await Task.sleep(for: .milliseconds(60))
            return ref(url.lastPathComponent, path: url.path)
        })
        let url = URL(fileURLWithPath: "/x/a.mov")
        async let first: Void = m.importFiles([url])
        async let second: Void = m.importFiles([url])
        _ = await (first, second)
        #expect(m.project.media.count == 1)
    }

    @Test func importSkipsDuplicatesAndReportsFailures() async {
        struct Boom: Error {}
        let (m, rec) = makeModel(probe: { url in
            if url.lastPathComponent == "bad.txt" { throw Boom() }
            return ref(url.lastPathComponent, path: url.path)
        })
        await m.importFiles([URL(fileURLWithPath: "/x/a.mov")])
        await m.importFiles([URL(fileURLWithPath: "/x/a.mov"), URL(fileURLWithPath: "/x/bad.txt")])
        #expect(m.project.media.count == 1)
        #expect(m.importFailures == ["bad.txt"])
        #expect(rec.edits.count == 1)            // second call changed nothing
        #expect(m.pendingImports == 0)
    }

    @Test func binOperations() {
        let (m, rec) = makeModel()
        let a = m.newBin(name: "A")!
        let b = m.newBin(name: "B")!
        #expect(rec.edits.count == 2)
        #expect(m.rename(.bin(a), to: "Alpha"))
        #expect(!m.rename(.bin(a), to: "  "))
        #expect(m.project.bin(a)?.name == "Alpha")
        #expect(m.move([.bin(b)], to: a))
        #expect(!m.move([.bin(a)], to: b))        // cycle refused
        #expect(m.project.bin(a)?.children.count == 1)
        #expect(m.delete([.bin(a)]).changed)
        #expect(m.project.rootBin.children.map(\.ref) == [.bin(b)])
        #expect(!m.delete([.bin(m.project.rootBin.id)]).changed)
    }

    @Test func mediaDelete() {
        let r1 = ref("a"), r2 = ref("b")
        var p = Project(name: "P"); p.add(r1); p.add(r2)
        let (m, _) = makeModel(p)
        #expect(m.delete([.media(r1.id)]).changed)
        #expect(m.project.media.map(\.id) == [r2.id])
        #expect(m.project.rootBin.mediaIDs == [r2.id])
    }

    @Test func offlineFlagged() {
        let here = URL(fileURLWithPath: #filePath).path
        var p = Project(name: "P")
        let ok = MediaRef(name: "ok", path: here, fingerprint: MediaFingerprint(size: -1))   // size mismatch: changed, not offline
        let gone = ref("gone")
        p.add(ok); p.add(gone)
        let (m, _) = makeModel(p)
        m.refreshOffline()
        #expect(m.isOffline(gone.id))
        #expect(!m.isOffline(ok.id))
    }

    @Test func sortAndSearch() {
        var p = Project(name: "P")
        let b = ref("b.mov", w: 1920), a = ref("a.mov", w: 3840, dur: Time(20, 1)), c = ref("c.mov", w: 1280, dur: Time(5, 1))
        p.add(b); p.add(a); p.add(c)
        let (m, _) = makeModel(p)
        func names() -> [String] { m.children(of: m.project.rootBin).map { m.project.displayName(of: $0.ref) } }
        #expect(names() == ["b.mov", "a.mov", "c.mov"])
        m.setSort(.name, ascending: true);      #expect(names() == ["a.mov", "b.mov", "c.mov"])
        m.setSort(.duration, ascending: false); #expect(names() == ["a.mov", "b.mov", "c.mov"])
        m.setSort(.duration, ascending: true);  #expect(names() == ["c.mov", "b.mov", "a.mov"])
        m.setSort(nil, ascending: true);        #expect(names() == ["b.mov", "a.mov", "c.mov"])
        m.searchText = "A.M"
        #expect(names() == ["a.mov"])
        #expect(m.project.rootBin.children.count == 3)   // filter is display-only
    }

    @Test func searchKeepsBinsWithMatches() {
        var p = Project(name: "P"); let r = ref("needle.mov"); p.add(r); p.add(ref("hay.mov"))
        let bin = p.newBin(name: "Sub")!; _ = p.newBin(name: "Empty")!
        p.move([.media(r.id)], to: bin)
        let (m, _) = makeModel(p)
        m.searchText = "needle"
        #expect(m.children(of: m.project.rootBin).map(\.ref) == [.bin(bin)])
        #expect(m.children(of: m.project.bin(bin)!).count == 1)
    }

    @Test func pasteboardIDsRoundTrip() {
        let refs: [BinItemRef] = [.media(UUID()), .bin(UUID()), .sequence(UUID())]
        #expect(ProjectPanelModel.decodeItems(ProjectPanelModel.encodeItems(refs)) == refs)
        #expect(ProjectPanelModel.decodeItems("garbage") == [])
    }
}

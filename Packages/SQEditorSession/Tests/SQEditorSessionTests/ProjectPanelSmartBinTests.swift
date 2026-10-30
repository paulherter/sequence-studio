import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

@MainActor @Suite struct ProjectPanelSmartBinTests {
    private final class Edits { var list: [(Project, String)] = [] }

    private func media(_ name: String) -> MediaRef {
        MediaRef(name: name, path: "/nonexistent/\(name).mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1))
    }

    private func model() -> (ProjectPanelModel, Edits) {
        let a = media("Interview"), b = media("Broll")
        var p = Project(name: "P", media: [a, b])
        let clip = Clip(name: "c", media: a.id, kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        p.timelines = [Timeline(name: "S", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip])])]
        let rec = Edits()
        let m = ProjectPanelModel(project: p, probe: { _ in throw CancellationError() }, onEdit: { rec.list.append(($0, $1)) })
        return (m, rec)
    }

    @Test func smartBinListsMatchingMediaFlat() {
        let (m, rec) = model()
        let id = m.addSmartBin(SmartBin(name: "Unused", usage: .unused))!
        #expect(rec.list.last?.1 == "New Smart Folder")
        #expect(rec.list.last?.0.smartBinList.count == 1)
        #expect(m.smartBinMedia(id).count == 1)
        m.activeSmartBin = id
        let shown = m.children(of: m.project.rootBin)
        #expect(shown.count == 1)
        #expect(m.project.displayName(of: shown[0].ref) == "Broll")
        #expect(m.isFiltering)
    }

    @Test func currentFilterBecomesSmartBin() {
        let (m, _) = model()
        m.searchText = " roll "
        m.mediaFilter = .unused
        let sb = m.currentFilterAsSmartBin(name: "Spare")
        #expect(sb.text == "roll" && sb.usage == .unused)
        let id = m.addSmartBin(sb)!
        #expect(m.smartBinMedia(id).count == 1)
    }

    @Test func deleteIsOneEditAndClearsActive() {
        let (m, rec) = model()
        let id = m.addSmartBin(SmartBin(name: "All"))!
        m.activeSmartBin = id
        #expect(m.removeSmartBin(id))
        #expect(m.activeSmartBin == nil)
        #expect(rec.list.last?.1 == "Delete Smart Folder")
        #expect(m.project.smartBins == nil)
    }

    @Test func usedFractionFromSequences() {
        let (m, _) = model()
        #expect(m.usedFraction(of: m.project.media[0].id) == 0.5)
        #expect(m.usedFraction(of: m.project.media[1].id) == 0)
    }

    @Test func spokenSearchFindsMediaByCaptionText() {
        let (m0, _) = model()
        var p = m0.project
        let item = CaptionItem(lines: ["welcome back"], range: TimeRange(start: Time(1, 1), duration: Time(1, 1)))
        p.timelines[0].captionTracks = [CaptionTrack(items: [item])]
        let m = ProjectPanelModel(project: p, probe: { _ in throw CancellationError() }, onEdit: { _, _ in })
        m.searchText = "welcome"
        #expect(m.children(of: m.project.rootBin).isEmpty)
        m.searchSpoken = true
        let shown = m.children(of: m.project.rootBin)
        #expect(shown.count == 1)
        #expect(m.project.displayName(of: shown[0].ref) == "Interview")
        #expect(m.currentFilterAsSmartBin(name: "Said").searchesSpoken == true)
    }
}

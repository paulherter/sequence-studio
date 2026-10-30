import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct ProjectPanelGroupingTests {
    private func media(_ name: String, camera: String?) -> MediaRef {
        var info = MediaInfo(duration: Time(10, 1))
        info.cameraModel = camera
        return MediaRef(name: name, path: "/nonexistent/\(name).mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1), info: info)
    }

    private func model() -> ProjectPanelModel {
        let p = Project(name: "P", media: [media("a", camera: "FX3"), media("b", camera: "GoPro"), media("c", camera: "FX3")])
        return ProjectPanelModel(project: p, probe: { _ in throw CancellationError() }, onEdit: { _, _ in })
    }

    @Test func cameraGroupingListsHeadersAndMovesNothing() throws {
        let m = model()
        let before = m.project.rootBin
        m.grouping = .camera
        let root = m.children(of: m.project.rootBin)
        #expect(root.count == 2)
        let first = try #require(root.first)
        guard case .bin(let id) = first.ref else { Issue.record("no header"); return }
        #expect(m.isGroupHeader(id))
        #expect(m.displayName(of: first.ref) == "FX3")
        #expect(m.children(of: try #require(m.displayBin(id))).count == 2)
        #expect(m.project.rootBin == before)
        #expect(ProjectPanelModel.groupID(.camera, "fx3") == id)
    }

    @Test func tokensFilterFolderView() {
        let m = model()
        m.filterTokens = [MediaFilterToken(.camera, "gopro")]
        #expect(m.children(of: m.project.rootBin).count == 1)
        #expect(m.isFiltering)
    }
}

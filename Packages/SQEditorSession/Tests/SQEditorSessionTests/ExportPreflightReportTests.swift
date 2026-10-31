import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorSession

private struct NoFrames: FrameSource {
    let frameCount = 50
    let frameDuration = Time(1, 25)
    func frame(at index: Int) async throws -> ExportFrame { throw FrameSourceError.indexOutOfRange(index) }
}

/// The notes both hosts show before an export starts (moved out of the Mac `ExportCoordinator`).
@MainActor @Suite struct ExportPreflightReportTests {
    func model(for project: Project) -> ExportDialogModel {
        ExportDialogModel(sequences: ExportDialogModel.sequenceItems(for: EditorSession(project: project)), initialPreset: nil,
                                  freeSpace: { _ in nil }) { _, _ in ExportSources(video: NoFrames()) }
    }

    @Test func offlineMediaIsNamedWithTheMacTitle() async {
        let gone = MediaRef(name: "gone.mov", path: "/nonexistent/gone.mov", fingerprint: MediaFingerprint(size: 1))
        let clip = Clip(name: "c", media: gone.id, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let tl = Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [Track(kind: .video, clips: [clip])])
        var project = Project(name: "P", timelines: [tl])
        project.media = [gone]
        let r = await ExportPreflightReport.build(model: model(for: project), project: project,
                                                  directory: FileManager.default.temporaryDirectory)
        #expect(r.title == "Media is offline")
        #expect(r.lines.first?.contains("• gone.mov") == true)
    }

    @Test func untrackedMagicFramesComeFromTheHostCounter() async {
        let tl = Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [Track(kind: .video)])
        let project = Project(name: "P", timelines: [tl])
        let r = await ExportPreflightReport.build(model: model(for: project), project: project,
                                                  directory: FileManager.default.temporaryDirectory,
                                                  untrackedMagicFrames: { _, _ in 3 })
        #expect(r.title == "Magic mask not tracked")
        #expect(r.lines == ["Magic mask not tracked on 3 frames: those frames export without the mask. Select the clip, then Track Forward / Backward in its mask row."])
        let clean = await ExportPreflightReport.build(model: model(for: project), project: project,
                                                      directory: FileManager.default.temporaryDirectory)
        #expect(clean.isEmpty)
    }

    @Test func existingFilesQuestionNamesUpToThree() {
        #expect(ExportPreflightReport.existingFilesQuestion([]) == nil)
        let one = ExportPreflightReport.existingFilesQuestion([URL(fileURLWithPath: "/x/A.mp4")])
        #expect(one?.title == "“A.mp4” already exists in this folder")
        let five = (1...5).map { URL(fileURLWithPath: "/x/\($0).mp4") }
        #expect(ExportPreflightReport.existingFilesQuestion(five)?.title == "“1.mp4”, “2.mp4”, “3.mp4” and 2 more already exist in this folder")
    }
}

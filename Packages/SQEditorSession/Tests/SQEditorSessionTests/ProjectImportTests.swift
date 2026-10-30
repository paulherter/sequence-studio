import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct ProjectImportTests {
    private func package(named name: String, in dir: URL) throws -> URL {
        let m = MediaRef(name: "a", path: "/v/a.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1))
        let t = Timeline(name: "Cut", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        let url = dir.appendingPathComponent("\(name).sqproj")
        try ProjectFile.write(Project(name: name, media: [m], timelines: [t]), to: url)
        return url
    }

    private func model(_ edits: Recorder) -> ProjectPanelModel {
        var p = Project(name: "Current")
        p.add(MediaRef(name: "own", path: "/v/own.mov", fingerprint: MediaFingerprint(size: 1)))
        p.timelines = [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])]
        p.activeTimeline = p.timelines[0].id
        p.normalizeBins()
        return ProjectPanelModel(project: p, probe: { _ in throw CocoaError(.fileReadUnknown) }, onEdit: { edits.edits.append(($0, $1)) })
    }

    @Test func importsAPackageAsOneBinInOneUndoStep() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try package(named: "Other", in: dir)
        let rec = Recorder()
        let m = model(rec)
        let active = m.project.activeTimeline
        await m.importProjects([url])
        #expect(rec.edits.count == 1)
        #expect(m.projectImportError == nil)
        #expect(m.project.timelines.count == 2 && m.project.media.count == 2)
        #expect(m.project.activeTimeline == active)
        #expect(m.project.rootBin.children.contains { if case .bin(let b) = $0 { b.name == "Other" } else { false } })
        // undo = the snapshot before the edit is the caller's history; the recorded project is the merged one
        #expect(rec.edits[0].0 == m.project)
    }

    @Test func damagedPackageGivesAReadableErrorAndNoEdit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("Bad.sqproj")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        let rec = Recorder()
        let m = model(rec)
        await m.importProjects([bad])
        #expect(rec.edits.isEmpty)
        let e = try #require(m.projectImportError)
        #expect(!e.detail.contains("project.json") && !e.title.contains("project.json"))
        #expect(e.detail.contains("no project"))
    }

    @Test func goodAndBadTogetherStillImportsTheGoodOne() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try package(named: "Good", in: dir)
        let bad = dir.appendingPathComponent("Bad.sqproj")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        let rec = Recorder()
        let m = model(rec)
        await m.importProjects([bad, good])
        #expect(rec.edits.count == 1 && m.projectImportError != nil)
        #expect(m.importedProjectNames == ["Good"])
    }
}

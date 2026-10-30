import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
    return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
}

@MainActor @Suite struct ProjectNotesAndSalvageTests {
    @Test func notesAreOneUndoStepAndMarkTheProjectDirty() {
        let ses = makeSession()
        ses.setProjectNotes("Deliver Friday")
        #expect(ses.project.notes == "Deliver Friday")
        #expect(ses.isDirty)
        ses.setProjectNotes("Deliver Friday")        // same text: no second step
        #expect(ses.undo())
        #expect(ses.project.notes.isEmpty)
        #expect(!ses.undo())
        #expect(ses.redo())
        #expect(ses.project.notes == "Deliver Friday")
    }

    @Test func aDamagedFileOpensSalvagedUnsavedAndTheOriginalStaysUntouched() async throws {
        let m = UUID()
        func clip(_ n: String, _ s: Int64) -> Clip {
            Clip(name: n, media: m, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(s, 1))
        }
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip("A", 0), clip("B", 2)])])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-\(UUID().uuidString).sqproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectFile.write(Project(name: "P", timelines: [t]), to: dir)
        let file = dir.appendingPathComponent("project.json")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var proj = obj["project"] as! [String: Any]
        var tls = proj["timelines"] as! [[String: Any]]
        var trs = tls[0]["tracks"] as! [[String: Any]]
        var cl = trs[0]["clips"] as! [[String: Any]]
        cl[1]["kind"] = "hologram"
        trs[0]["clips"] = cl; tls[0]["tracks"] = trs; proj["timelines"] = tls; obj["project"] = proj
        let bytes = try JSONSerialization.data(withJSONObject: obj)
        try bytes.write(to: file)

        let ses = makeSession()
        let report = try await ses.open(url: dir)
        // The clip and the media item the fixture never listed (offline placeholder).
        #expect(report?.dropped.filter { $0.hasPrefix("Clip") }.count == 1)
        #expect(ses.project.timelines[0].tracks[0].clips.map(\.name) == ["A"])
        #expect(ses.fileURL == nil)
        #expect(ses.isDirty)
        await #expect(throws: (any Error).self) { try await ses.save() }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func aGoodFileOpensWithoutAReport() async throws {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-\(UUID().uuidString).sqproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectFile.write(Project(name: "P", timelines: [t]), to: dir)
        let ses = makeSession()
        let report = try await ses.open(url: dir)
        #expect(report == nil)
        #expect(ses.fileURL == dir)
        #expect(!ses.isDirty)
    }

    @Test func savingOverTheDamagedOriginalKeepsABackupFirst() async throws {
        let m = UUID()
        func clip(_ n: String, _ s: Int64) -> Clip {
            Clip(name: n, media: m, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(s, 1))
        }
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip("A", 0), clip("B", 2)])])
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("bak-\(UUID().uuidString)")
        let dir = parent.appendingPathComponent("P.sqproj")
        defer { try? FileManager.default.removeItem(at: parent) }
        try ProjectFile.write(Project(name: "P", timelines: [t]), to: dir)
        let file = dir.appendingPathComponent("project.json")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var proj = obj["project"] as! [String: Any]
        var tls = proj["timelines"] as! [[String: Any]]
        var trs = tls[0]["tracks"] as! [[String: Any]]
        var cl = trs[0]["clips"] as! [[String: Any]]
        cl[1]["kind"] = "hologram"
        trs[0]["clips"] = cl; tls[0]["tracks"] = trs; proj["timelines"] = tls; obj["project"] = proj
        let bytes = try JSONSerialization.data(withJSONObject: obj)
        try bytes.write(to: file)

        let ses = makeSession()
        try await ses.open(url: dir)
        try await ses.saveAs(to: dir)
        let bak = parent.appendingPathComponent("P.sqproj.damaged.bak")
        #expect(try Data(contentsOf: bak) == bytes)
        #expect(try Data(contentsOf: file) != bytes)
    }
}

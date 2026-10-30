import Foundation
import Testing
@testable import SQCore

// v83: `Project.notes`, written only when not empty. A v82 build would drop it on save; at v83 it refuses the file.
struct ProjectFileV83Tests {
    private func project() -> Project {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks())
        return Project(name: "P", timelines: [t])
    }
    private func json(_ d: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: d) as! [String: Any] }

    @Test func emptyNotesStoreNothingAndKeepTheLowerVersion() throws {
        var p = project()
        #expect(!p.containsV83Content)
        let before = try ProjectFile.encode(p)
        p.notes = "x"
        p.notes = ""
        #expect(try ProjectFile.encode(p) == before)
        #expect(!String(decoding: before, as: UTF8.self).contains("\"notes\""))
        #expect(ProjectFile.writtenVersion(for: p) < 83)
    }

    @Test func notesWriteV83AndRoundTrip() throws {
        var p = project()
        p.notes = "Client wants captions in yellow.\nDeliver Friday."
        #expect(ProjectFile.writtenVersion(for: p) == 83)
        let data = try ProjectFile.encode(p)
        #expect(try json(data)["formatVersion"] as? Int == 83)
        for migrations in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: migrations)
            #expect(back == p)
            #expect(back.notes == "Client wants captions in yellow.\nDeliver Friday.")
        }
    }

    @Test func aV82FileMigratesToV83WithEmptyNotes() throws {
        var obj = try json(try ProjectFile.encode(project()))
        obj["formatVersion"] = 82
        let old = try JSONSerialization.data(withJSONObject: obj)
        let p = try ProjectFile.decode(old, migrations: ProjectFile.migrations)
        #expect(p.notes.isEmpty)
        #expect(p.name == "P")
    }

    @Test func aV82BuildRefusesAV83File() throws {
        var obj = try json(try ProjectFile.encode(project()))
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: nil)
        }
    }

    @Test func aMalformedNotesValueOpensAsEmpty() throws {
        var obj = try json(try ProjectFile.encode(project()))
        var p = obj["project"] as! [String: Any]
        p["notes"] = 5
        obj["project"] = p
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: nil)
        #expect(back.notes.isEmpty)
    }
}

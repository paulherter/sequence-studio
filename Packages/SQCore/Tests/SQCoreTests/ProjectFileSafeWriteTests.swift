import Foundation
import Testing
@testable import SQCore

@Suite struct ProjectFileSafeWriteTests {
    let fm = FileManager.default

    func tempDir() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("sqsafe-\(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Writes a project file claiming an older format version.
    func writeOld(_ project: Project, version: Int, to pkg: URL) throws {
        try ProjectFile.write(project, to: pkg)
        let f = pkg.appendingPathComponent(ProjectFile.fileName)
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any])
        obj["formatVersion"] = version
        obj["appFormat"] = nil   // older builds did not write it
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: f)
    }

    func baks(_ dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".bak") }.sorted()
    }

    @Test func atomicWriteIsReadableAndLeavesNoTemp() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("P.sqproj")
        let p = Project(name: "P", timelines: [])
        try ProjectFile.write(p, to: pkg)
        try ProjectFile.write(p, to: pkg)
        #expect(try ProjectFile.read(from: pkg) == p)
        #expect(try fm.contentsOfDirectory(atPath: pkg.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test func interruptedWriteKeepsOldFile() throws {
        struct Boom: Error {}
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.json")
        try Data("old".utf8).write(to: file)
        #expect(throws: Boom.self) {
            try ProjectFile.atomicWrite(Data("new".utf8), to: file, fileManager: fm, beforeRename: { throw Boom() })
        }
        #expect(try Data(contentsOf: file) == Data("old".utf8))
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["f.json"])
    }

    @Test func firstMigratedSaveBacksUpOnce() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("P.sqproj")
        let p = Project(name: "P", timelines: [])
        try writeOld(p, version: 10, to: pkg)
        let oldBytes = try Data(contentsOf: pkg.appendingPathComponent(ProjectFile.fileName))
        try ProjectFile.write(p, to: pkg)
        #expect(baks(dir) == ["P.sqproj.v10.bak"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("P.sqproj.v10.bak")) == oldBytes)
        try ProjectFile.write(p, to: pkg)
        #expect(baks(dir) == ["P.sqproj.v10.bak"])
    }

    @Test func existingBackupIsNeverOverwrittenAndOnlyThreeKept() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("P.sqproj")
        let p = Project(name: "P", timelines: [])
        try Data("keep".utf8).write(to: dir.appendingPathComponent("P.sqproj.v10.bak"))
        try writeOld(p, version: 10, to: pkg)
        try ProjectFile.write(p, to: pkg)
        #expect(try Data(contentsOf: dir.appendingPathComponent("P.sqproj.v10.bak")) == Data("keep".utf8))
        for v in [11, 12, 13] {
            try writeOld(p, version: v, to: pkg)
            try ProjectFile.write(p, to: pkg)
        }
        #expect(baks(dir) == ["P.sqproj.v11.bak", "P.sqproj.v12.bak", "P.sqproj.v13.bak"])
    }

    @Test func ordinarySavesAndLowContentVersionMakeNoBackup() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("P.sqproj")
        var p = Project(name: "P", timelines: [])
        try ProjectFile.write(p, to: pkg)
        p.name = "Q"
        try ProjectFile.write(p, to: pkg)
        // A file this build wrote at a lower, content-gated version is not "older".
        let f = pkg.appendingPathComponent(ProjectFile.fileName)
        let header = try #require(ProjectFile.header(of: f))
        #expect(header.app == ProjectFile.currentVersion)
        #expect(baks(dir).isEmpty)
    }

    @Test func unknownAuthorFileFromAtLeastFloorIsNotBackedUp() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("P.sqproj")
        let p = Project(name: "P", timelines: [])
        try writeOld(p, version: ProjectFile.unknownAuthorFloor, to: pkg)
        try ProjectFile.write(p, to: pkg)
        #expect(baks(dir).isEmpty)
    }

    @Test func realOlderBackupSurvivesPruningBelowThree() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("P.sqproj")
        let p = Project(name: "P", timelines: [])
        try writeOld(p, version: 30, to: pkg)
        try ProjectFile.write(p, to: pkg)
        try ProjectFile.write(p, to: pkg)   // ordinary edit afterwards
        try writeOld(p, version: 11, to: pkg)
        try ProjectFile.write(p, to: pkg)
        #expect(baks(dir) == ["P.sqproj.v11.bak", "P.sqproj.v30.bak"])
    }

    @Test func olderAppFormatBacksUpOnce() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("P.sqproj")
        let p = Project(name: "P", timelines: [])
        try ProjectFile.write(p, to: pkg)
        let f = pkg.appendingPathComponent(ProjectFile.fileName)
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any])
        obj["appFormat"] = ProjectFile.currentVersion - 1
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: f)
        try ProjectFile.write(p, to: pkg)
        #expect(baks(dir).count == 1)
        try ProjectFile.write(p, to: pkg)
        #expect(baks(dir).count == 1)
    }

    @Test func nonFiniteDoublesStayWritable() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        var p = Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [Track(kind: .audio)])])
        p.timelines[0].tracks[0].pan = .nan
        p.timelines[0].tracks[0].height = .infinity
        try ProjectFile.write(p, to: dir)
        let back = try ProjectFile.read(from: dir)
        #expect(back.timelines[0].tracks[0].pan.isNaN)
        #expect(back.timelines[0].tracks[0].height == .infinity)
    }

    @Test func autosaveWithClockSetBackKeepsNewest() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        var p = Project(name: "P", timelines: [])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 {
            p.name = "v\(i)"
            try ProjectFile.autosave(p, in: dir, keep: 3, date: base.addingTimeInterval(Double(i)))
        }
        p.name = "back"
        let written = try ProjectFile.autosave(p, in: dir, keep: 3, date: base.addingTimeInterval(-3600))
        #expect(fm.fileExists(atPath: written.path))
        #expect(ProjectFile.autosaves(in: dir).count == 3)
        #expect(ProjectFile.latestAutosave(in: dir)?.name == "back")
    }

    @Test func saveOverNewerBuildFileKeepsBackup() throws {
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("P.sqproj")
        let p = Project(name: "P", timelines: [])
        try ProjectFile.write(p, to: pkg)
        let f = pkg.appendingPathComponent(ProjectFile.fileName)
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any])
        obj["appFormat"] = ProjectFile.currentVersion + 5
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: f)
        let newerBytes = try Data(contentsOf: f)
        try ProjectFile.write(p, to: pkg)
        let name = "P.sqproj.v\(ProjectFile.currentVersion + 5).bak"
        #expect(baks(dir) == [name])
        #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == newerBytes)
    }
}

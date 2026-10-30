import Foundation
import Testing
@testable import SQCore

@Suite struct ProjectExtensionTests {
    let fm = FileManager.default

    @Test func newAndLegacyExtensions() {
        #expect(ProjectFile.fileExtension == "sqproj")
        #expect(ProjectFile.legacyFileExtensions == ["ssproj"])
        #expect(ProjectFile.isProjectURL(URL(fileURLWithPath: "/x/A.sqproj")))
        #expect(ProjectFile.isProjectURL(URL(fileURLWithPath: "/x/A.ssproj")))
        #expect(ProjectFile.isProjectURL(URL(fileURLWithPath: "/x/A.SSPROJ")))
        #expect(!ProjectFile.isProjectURL(URL(fileURLWithPath: "/x/A.json")))
        #expect(ProjectFile.isLegacyURL(URL(fileURLWithPath: "/x/A.ssproj")))
        #expect(!ProjectFile.isLegacyURL(URL(fileURLWithPath: "/x/A.sqproj")))
    }

    @Test func convertedURLIsASiblingAndNeverOverwrites() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("sqext-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let old = dir.appendingPathComponent("Film.ssproj")
        #expect(ProjectFile.convertedURL(for: old).lastPathComponent == "Film.sqproj")
        #expect(ProjectFile.convertedURL(for: old).deletingLastPathComponent().path == dir.path)
        try fm.createDirectory(at: dir.appendingPathComponent("Film.sqproj"), withIntermediateDirectories: true)
        #expect(ProjectFile.convertedURL(for: old).lastPathComponent == "Film 2.sqproj")
    }

    @Test func legacyReadsStillWork() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("sqext-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Old.ssproj")
        let p = Project(name: "Old")
        try ProjectFile.write(p, to: url)
        #expect(try ProjectFile.read(from: url) == p)
    }

    @Test func autosaveVersionsListsLegacyPackages() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("sqext-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let store = AutosaveStore(base: base)
        let p = Project(name: "P")
        let v = try store.write(p, date: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(v.url.pathExtension == "sqproj")
        // A version written by an older build, one second later.
        let older = try store.write(p, date: Date(timeIntervalSince1970: 1_700_000_100))
        let legacy = older.url.deletingPathExtension().appendingPathExtension("ssproj")
        try fm.moveItem(at: older.url, to: legacy)
        let exts = store.versions(for: p.id).map { $0.url.pathExtension }
        #expect(Set(exts) == ["sqproj", "ssproj"])
    }
}

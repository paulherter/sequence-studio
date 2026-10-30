import Foundation
import Testing
@testable import SQCore

/// A project copied to another machine (the Mac project opened on Windows): media next to the project file is found again.
@Suite struct NearProjectRelinkTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-near-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func file(_ dir: URL, _ rel: String, size: Int) throws -> URL {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: url)
        return url
    }

    private func ref(_ path: String, size: Int64) -> MediaRef {
        MediaRef(name: MediaPathResolver.fileName(of: path), path: path, fingerprint: MediaFingerprint(size: size))
    }

    @Test func storedMacPathsResolveByTheirTrailingFoldersBelowTheProjectFolder() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let imported = try file(dir, "Files/Imported/C2171.MP4", size: 10)
        _ = try file(dir, "Media/C2171.MP4", size: 10)          // same name and size elsewhere: the trailing folders decide
        let media = try file(dir, "Media/C2174.MP4", size: 20)
        let a = ref("/Users/me/Documents/Projects/Client Film/Files/Imported/C2171.MP4", size: 10)
        let b = ref("/Users/me/Documents/Projects/Client/Media/C2174.MP4", size: 20)
        let plan = NearProjectRelink.plan(missing: [a, b], folder: dir)
        #expect(plan[a.id] == imported.standardizedFileURL.path)
        #expect(plan[b.id] == media.standardizedFileURL.path)
    }

    @Test func windowsStoredPathsAndNameSearchWithTheRecordedSize() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deep = try file(dir, "Shoot/Day 2/clip.mov", size: 30)
        _ = try file(dir, "Other/b.wav", size: 7)
        let a = ref(#"D:\Footage\Card 1\clip.mov"#, size: 30)       // no trailing folder matches: found by name and size
        let b = ref("/Volumes/SSD/b.wav", size: 8)                  // same name, other size: a different file
        let plan = NearProjectRelink.plan(missing: [a, b], folder: dir)
        #expect(plan[a.id] == deep.standardizedFileURL.path)
        #expect(plan[b.id] == nil)
    }

    @Test func trailingMatchPrefersTheLongestExistingSuffixAndChecksTheSize() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let long = try file(dir, "Proj/Files/x.mp4", size: 5)
        _ = try file(dir, "x.mp4", size: 5)
        #expect(NearProjectRelink.trailingMatch("/Users/a/Proj/Files/x.mp4", in: dir, size: 5) == long.standardizedFileURL.path)
        #expect(NearProjectRelink.trailingMatch("/Users/a/Proj/Files/x.mp4", in: dir, size: 6) == nil)
        #expect(NearProjectRelink.trailingMatch("/Users/a/Proj/Files/x.mp4", in: dir, size: 0) == long.standardizedFileURL.path)
    }

    @Test func nothingNearTheProjectGivesAnEmptyPlan() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(NearProjectRelink.plan(missing: [ref("/Users/a/gone.mov", size: 1)], folder: dir).isEmpty)
        #expect(NearProjectRelink.plan(missing: [], folder: dir).isEmpty)
    }
}

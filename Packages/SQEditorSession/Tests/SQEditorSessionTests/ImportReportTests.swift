import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

private func ref(_ name: String, path: String) -> MediaRef {
    MediaRef(name: name, path: path, fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
             info: MediaInfo(duration: Time(10, 1), video: nil))
}

@MainActor private func model(probe: @escaping ProjectPanelModel.Probe = { ref($0.lastPathComponent, path: $0.path) }) -> ProjectPanelModel {
    ProjectPanelModel(project: Project(name: "P"), probe: probe, onEdit: { _, _ in })
}

private func tempFolder() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sqreport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@MainActor @Suite struct ImportReportTests {
    @Test func cleanImportReportsCountOnly() async {
        let m = model()
        await m.importFiles([URL(fileURLWithPath: "/x/a.mov"), URL(fileURLWithPath: "/x/b.mov")])
        let r = m.lastImportReport
        #expect(r?.imported == 2)
        #expect(r?.isClean == true)
        #expect(r?.summary == "Imported 2 files.")
    }

    @Test func reportListsEverySkippedKindWithReasons() async {
        struct Boom: Error {}
        let m = model(probe: { url in
            switch url.lastPathComponent {
            case "broken.mov": throw Boom()
            case "hdr.mkv": throw MediaError.unsupportedCodec("av01")
            case "talk.webm": ImportNotes.noteAudioDropped(url, codec: "ac-3")
            default: break
            }
            return ref(url.lastPathComponent, path: url.path)
        })
        await m.importFiles([URL(fileURLWithPath: "/x/old.mov")])
        await m.importFiles(["old.mov", "broken.mov", "hdr.mkv", "talk.webm", "ok.mov"].map { URL(fileURLWithPath: "/x/\($0)") })
        let r = try! #require(m.lastImportReport)
        #expect(r.imported == 2)                                       // ok.mov and talk.webm
        #expect(r.alreadyInProject == ["old.mov"])
        #expect(r.failed.map(\.file) == ["broken.mov"])
        #expect(r.unsupported.map(\.file) == ["hdr.mkv"] && r.unsupported.map(\.detail) == ["av01"])
        #expect(r.audioDropped.map(\.file) == ["talk.webm"])
        #expect(r.skippedCount == 3)
        #expect(!r.isClean)
        #expect(r.summary.contains("Imported 2 files"))
        #expect(r.summary.contains("3 skipped"))
        #expect(r.summary.contains("1 already in the project"))
        #expect(r.summary.contains("1 could not be read"))
        #expect(r.summary.contains("1 uses a codec this Mac cannot decode"))
    }

    @Test func allSkippedStillProducesAReport() async {
        let m = model()
        await m.importFiles([URL(fileURLWithPath: "/x/a.mov")])
        await m.importFiles([URL(fileURLWithPath: "/x/a.mov")])
        let r = m.lastImportReport
        #expect(r?.imported == 0 && r?.alreadyInProject == ["a.mov"])
        #expect(r?.summary == "Nothing imported: 1 already in the project.")
    }

    @Test func sameFileUnderAnotherPathIsADuplicate() async throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov")
        try Data(repeating: 1, count: 64).write(to: a)
        let link = dir.appendingPathComponent("link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let hard = dir.appendingPathComponent("hard.mov")
        try FileManager.default.linkItem(at: a, to: hard)
        let other = dir.appendingPathComponent("other.mov")
        try Data(repeating: 1, count: 64).write(to: other)              // same bytes, different file: not a duplicate

        let m = model()
        await m.importFiles([a])
        await m.importFiles([link, hard, other])
        #expect(m.project.media.count == 2)
        let r = try #require(m.lastImportReport)
        #expect(Set(r.duplicates) == ["link.mov", "hard.mov"])
        #expect(r.imported == 1)
        #expect(r.summary.contains("2 are the same file as one already imported"))
    }

    @Test func duplicatesInsideOneBatchImportOnce() async throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.wav")
        try Data(repeating: 2, count: 64).write(to: a)
        let link = dir.appendingPathComponent("again.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let m = model()
        await m.importFiles([a, link])
        #expect(m.project.media.count == 1)
        #expect(m.lastImportReport?.duplicates == ["again.wav"])
    }

    @Test func missingFilesAreNeverDuplicates() async {
        let m = model()
        await m.importFiles([URL(fileURLWithPath: "/nowhere/a.mov"), URL(fileURLWithPath: "/nowhere2/b.mov")])
        #expect(m.lastImportReport?.duplicates.isEmpty == true)
        #expect(m.project.media.count == 2)
    }
}

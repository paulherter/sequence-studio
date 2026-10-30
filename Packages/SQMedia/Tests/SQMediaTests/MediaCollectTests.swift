import Foundation
import SQCore
import Testing
@testable import SQMedia

/// Collect Files into Project Folder: the copy loop both hosts (Mac and Windows) call.
@Suite struct MediaCollectTests {
    let fm = FileManager.default

    private func ref(_ url: URL) -> MediaRef {
        MediaRef(name: url.lastPathComponent, path: url.path, fingerprint: MediaFingerprint(size: 10))
    }

    @Test func collectCopiesOutsideMediaOnceAndLeavesTheOriginals() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sqcollect-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("A/clip.mov"), b = root.appendingPathComponent("B/clip.mov")
        let gone = root.appendingPathComponent("A/gone.mov")
        let folder = root.appendingPathComponent("Proj/Files/Imported")
        for u in [a, b] { try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data(repeating: 1, count: 300).write(to: a)
        try Data(repeating: 2, count: 300).write(to: b)
        // two refs share one source; the second clip.mov has other content and another name
        let media = [ref(a), ref(a), ref(b), ref(gone)]
        let out = MediaFileOps.collect(media: media, into: folder)
        #expect(out.failed.isEmpty)
        #expect(out.done.count == 3)                                   // the missing source is not planned
        let dests = Set(out.done.map(\.destination))
        #expect(dests.count == 2)                                      // the shared source shares one copy
        for d in dests { #expect(fm.fileExists(atPath: d)) }
        #expect(out.done[0].destination == out.done[1].destination)
        #expect(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path))
        // Collecting again finds nothing outside: media that point into the folder are skipped.
        var moved = media
        for item in out.done { if let i = moved.firstIndex(where: { $0.id == item.id }) { moved[i].path = item.destination } }
        #expect(MediaFileOps.collect(media: moved.filter { $0.path.hasPrefix(folder.path) }, into: folder).done.isEmpty)
    }

    @Test func aSourceThatCannotBeCopiedIsReportedByName() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sqcollect-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("Files")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // A directory is "there" for the plan but is no file to copy and verify.
        let dir = root.appendingPathComponent("Dir.mov")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = MediaFileOps.collect(media: [ref(dir)], into: folder)
        #expect(out.done.isEmpty && out.failed == ["Dir.mov"])
    }
}

import Foundation
import SQCore
import Testing
@testable import SQMedia

@Suite struct MediaFileOpsTests {
    let fm = FileManager.default

    func makeDirs() throws -> (src: URL, files: URL, root: URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("sqmfo-\(UUID().uuidString)")
        let src = root.appendingPathComponent("Desktop"), files = root.appendingPathComponent("Proj/Files")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        return (src, files, root)
    }

    func write(_ url: URL, _ bytes: Int, seed: UInt8 = 1) throws {
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }).write(to: url)
    }

    let removeHard: MediaFileOps.Remover = { try FileManager.default.removeItem(at: $0) }

    @Test func copyKeepsOriginalAndCreatesFolder() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let s = d.src.appendingPathComponent("shot.png"); try write(s, 5000)
        let r = try MediaFileOps.ingest(s, into: d.files, mode: .copy)
        #expect(fm.fileExists(atPath: s.path))
        #expect(r.url.path == d.files.appendingPathComponent("shot.png").path)
        #expect(try MediaFileOps.identical(s, r.url))
        #expect(!r.originalRemoved)
        #expect(try fm.contentsOfDirectory(atPath: d.files.path) == ["shot.png"])   // no temp leftovers
    }

    @Test func moveRemovesOriginalOnlyAfterVerifiedCopy() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let s = d.src.appendingPathComponent("shot.png"); try write(s, 5000)
        let r = try MediaFileOps.ingest(s, into: d.files, mode: .move, removeOriginal: removeHard)
        #expect(!fm.fileExists(atPath: s.path))
        #expect(fm.fileExists(atPath: r.url.path) && r.originalRemoved)
    }

    @Test func moveKeepsOriginalWhenRemovalFails() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let s = d.src.appendingPathComponent("a.mov"); try write(s, 100)
        struct Boom: Error {}
        let r = try MediaFileOps.ingest(s, into: d.files, mode: .move, removeOriginal: { _ in throw Boom() })
        #expect(fm.fileExists(atPath: s.path) && fm.fileExists(atPath: r.url.path) && !r.originalRemoved)
    }

    @Test func leaveAndInsideReturnSourceUntouched() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let s = d.src.appendingPathComponent("a.mov"); try write(s, 100)
        #expect(try MediaFileOps.ingest(s, into: d.files, mode: .leave).url == s)
        #expect(!fm.fileExists(atPath: d.files.path))
        try fm.createDirectory(at: d.files, withIntermediateDirectories: true)
        let inside = d.files.appendingPathComponent("b.mov"); try write(inside, 100)
        let r = try MediaFileOps.ingest(inside, into: d.files, mode: .move, removeOriginal: removeHard)
        #expect(r.url == inside && fm.fileExists(atPath: inside.path))
    }

    @Test func nameClashWithDifferentContentGetsNewName() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        try fm.createDirectory(at: d.files, withIntermediateDirectories: true)
        let existing = d.files.appendingPathComponent("a.mov"); try write(existing, 100, seed: 9)
        let s = d.src.appendingPathComponent("a.mov"); try write(s, 100, seed: 1)
        let r = try MediaFileOps.ingest(s, into: d.files, mode: .copy)
        #expect(r.url.lastPathComponent == "a 2.mov" && !r.reused)
        #expect(try MediaFileOps.identical(s, r.url))
        #expect(try MediaFileOps.identical(existing, existing) && (try Data(contentsOf: existing)).count == 100)
        #expect(try !MediaFileOps.identical(existing, s))   // existing untouched
    }

    @Test func identicalFileInFolderIsReused() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let s = d.src.appendingPathComponent("a.mov"); try write(s, 100)
        _ = try MediaFileOps.ingest(s, into: d.files, mode: .copy)
        let r = try MediaFileOps.ingest(s, into: d.files, mode: .copy)
        #expect(r.reused && r.url.lastPathComponent == "a.mov")
        #expect(try fm.contentsOfDirectory(atPath: d.files.path).count == 1)
    }

    @Test func missingSourceThrowsAndWritesNothing() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        #expect(throws: MediaFileOps.Failure.sourceMissing("x.mov")) {
            _ = try MediaFileOps.ingest(d.src.appendingPathComponent("x.mov"), into: d.files, mode: .move)
        }
    }

    @Test func largeFileSampledHashDetectsMiddleChange() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let a = d.src.appendingPathComponent("a.bin"), b = d.src.appendingPathComponent("b.bin")
        try write(a, 6 << 20)
        var data = try Data(contentsOf: a)
        #expect(try MediaFileOps.identical(a, a))
        data[data.count * 3 / 7 + 10] ^= 0xFF          // inside a sampled chunk
        try data.write(to: b)
        #expect(try !MediaFileOps.identical(a, b))
    }

    @Test func screenshotFromDesktopSurvivesDeletingTheOriginal() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let s = d.src.appendingPathComponent("Screenshot.png"); try write(s, 20_000)
        let fp = MediaFingerprint(size: 20_000)
        let r = try MediaFileOps.ingest(s, into: d.files, mode: .copy)
        try fm.removeItem(at: s)                        // user deletes the Desktop file
        let ref = MediaRef(name: "Screenshot.png", path: r.url.path, fingerprint: fp)
        #expect(ref.status() != .missing)
    }

    @Test func moveOfAFileAlreadyInFilesViaSymlinkNeverRemovesIt() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        try fm.createDirectory(at: d.files, withIntermediateDirectories: true)
        let real = d.files.appendingPathComponent("a.mov"); try write(real, 100)
        let alias = d.root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: d.files)
        let viaAlias = alias.appendingPathComponent("a.mov")
        let r = try MediaFileOps.ingest(viaAlias, into: d.files, mode: .move, removeOriginal: removeHard)
        #expect(fm.fileExists(atPath: real.path) && !r.originalRemoved && r.url == viaAlias)
        // A symlink elsewhere pointing into Files is the same.
        let link = d.src.appendingPathComponent("link.mov")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let r2 = try MediaFileOps.ingest(link, into: d.files, mode: .move, removeOriginal: removeHard)
        #expect(fm.fileExists(atPath: real.path) && !r2.originalRemoved)
    }

    @Test func symlinkSourceCopiesTheRealFile() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let real = d.src.appendingPathComponent("real.mov"); try write(real, 300)
        let link = d.src.appendingPathComponent("link.mov")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let r = try MediaFileOps.ingest(link, into: d.files, mode: .copy)
        let attrs = try fm.attributesOfItem(atPath: r.url.path)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular)
        #expect(try MediaFileOps.identical(real, r.url))
    }

    @Test func sameNamedFilesIngestedInParallelGetDistinctNames() async throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        var urls: [URL] = []
        for i in 0..<6 {
            let dir = d.src.appendingPathComponent("card\(i)"); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let u = dir.appendingPathComponent("C0001.MP4"); try write(u, 500, seed: UInt8(i + 1)); urls.append(u)
        }
        let files = d.files
        let results = try await withThrowingTaskGroup(of: URL.self) { g in
            for u in urls { g.addTask { try MediaFileOps.ingest(u, into: files, mode: .copy).url } }
            var out: [URL] = []; for try await r in g { out.append(r) }; return out
        }
        #expect(Set(results.map { $0.lastPathComponent.lowercased() }).count == 6)
        for u in urls { #expect(results.contains { (try? MediaFileOps.identical(u, $0)) == true }) }
    }

    @Test func sampledEqualButDifferentFileIsNeverReusedOrTrashed() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        try fm.createDirectory(at: d.files, withIntermediateDirectories: true)
        let s = d.src.appendingPathComponent("a.bin"); try write(s, 6 << 20)
        var data = try Data(contentsOf: s)
        data[1_500_000] ^= 0xFF                        // between the samples
        let existing = d.files.appendingPathComponent("a.bin"); try data.write(to: existing)
        #expect(try MediaFileOps.identical(s, existing))              // the sampled check is fooled
        let r = try MediaFileOps.ingest(s, into: d.files, mode: .move, removeOriginal: removeHard)
        #expect(!r.reused && r.url.lastPathComponent == "a 2.bin")
        #expect(try MediaFileOps.fullyIdentical(r.url, existing) == false)   // own copy, not the stand-in
        #expect(try Data(contentsOf: existing) == data)
    }

    @Test func existingUppercaseNumberedNameIsNotOverwritten() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        try fm.createDirectory(at: d.files, withIntermediateDirectories: true)
        let a = d.files.appendingPathComponent("Clip.MOV"), b = d.files.appendingPathComponent("Clip 2.MOV")
        try write(a, 50, seed: 3); try write(b, 50, seed: 4)
        let s = d.src.appendingPathComponent("Clip.MOV"); try write(s, 50, seed: 5)
        let r = try MediaFileOps.ingest(s, into: d.files, mode: .copy)
        #expect(r.url.lastPathComponent == "Clip 3.MOV")
        #expect(try !MediaFileOps.identical(b, s))
    }

    @Test func libraryItemsAreDeduplicatedByContentNotName() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let lib = d.root.appendingPathComponent("Proj/Files/Library")
        let a = d.src.appendingPathComponent("boom.wav"), copyOfA = d.src.appendingPathComponent("boom copy.wav")
        let other = d.src.appendingPathComponent("boom2.wav")
        try write(a, 3000, seed: 2); try write(copyOfA, 3000, seed: 2); try write(other, 3000, seed: 3)
        #expect(!fm.fileExists(atPath: lib.path))
        let first = try MediaFileOps.ingestLibraryItem(a, into: lib)
        #expect(first.url.lastPathComponent == "boom.wav" && !first.reused)
        let again = try MediaFileOps.ingestLibraryItem(copyOfA, into: lib)       // other name, same content
        #expect(again.reused && again.url == first.url)
        let different = try MediaFileOps.ingestLibraryItem(other, into: lib)
        #expect(!different.reused && different.url.lastPathComponent == "boom2.wav")
        #expect(try fm.contentsOfDirectory(atPath: lib.path).sorted() == ["boom.wav", "boom2.wav"])
        #expect(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: copyOfA.path))       // sources untouched
    }

    @Test func sameSizeButDifferentContentIsNotMerged() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let lib = d.root.appendingPathComponent("Proj/Files/Library")
        let a = d.src.appendingPathComponent("a.wav"), b = d.src.appendingPathComponent("b.wav")
        try write(a, 3 << 20, seed: 1)
        var data = try Data(contentsOf: a); data[1_500_000] ^= 0xFF; try data.write(to: b)    // between the samples
        _ = try MediaFileOps.ingestLibraryItem(a, into: lib)
        let r = try MediaFileOps.ingestLibraryItem(b, into: lib)
        #expect(!r.reused && r.url.lastPathComponent == "b.wav")
    }

    @Test func moveAfterCopyRemovesOriginalOnlyWhenVerified() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let s = d.src.appendingPathComponent("a.mov"); try write(s, 400)
        let copy = d.root.appendingPathComponent("copy.mov")
        try write(copy, 400, seed: 9)                                                  // same size, other content
        #expect(!MediaFileOps.removeOriginal(s, afterCopy: copy, remover: removeHard) && fm.fileExists(atPath: s.path))
        try fm.removeItem(at: copy); try fm.copyItem(at: s, to: copy)
        #expect(!MediaFileOps.removeOriginal(s, afterCopy: s, remover: removeHard) && fm.fileExists(atPath: s.path))   // same file
        #expect(MediaFileOps.removeOriginal(s, afterCopy: copy, remover: removeHard))
        #expect(!fm.fileExists(atPath: s.path) && fm.fileExists(atPath: copy.path))
        #expect(!MediaFileOps.removeOriginal(s, afterCopy: copy, remover: removeHard))   // already gone: nothing happens
    }

    @Test func aSymlinkMoveCopiesTheContentAndTrashesNothing() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let target = d.src.appendingPathComponent("real.mov"); try write(target, 400)
        let link = d.src.appendingPathComponent("link.mov")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(MediaFileOps.isLinkOrAlias(link) && !MediaFileOps.isLinkOrAlias(target))
        let r = try MediaFileOps.ingest(link, into: d.files, mode: .move, removeOriginal: removeHard)
        #expect(!r.originalRemoved && fm.fileExists(atPath: target.path) && fm.fileExists(atPath: r.url.path))
        let copy = d.root.appendingPathComponent("copy.mov"); try fm.copyItem(at: target, to: copy)
        #expect(!MediaFileOps.removeOriginal(link, afterCopy: copy, remover: removeHard) && fm.fileExists(atPath: target.path))
    }

    @Test func canceledBatchDeletesOnlyCopiesItCreated() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let a = d.src.appendingPathComponent("a.mov"), b = d.src.appendingPathComponent("b.mov")
        try write(a, 300); try write(b, 300, seed: 4)
        let ra = try MediaFileOps.ingest(a, into: d.files, mode: .copy)
        let rb = try MediaFileOps.ingest(b, into: d.files, mode: .copy)
        let again = try MediaFileOps.ingest(a, into: d.files, mode: .copy)       // reuses the identical file
        #expect(ra.created && rb.created && !again.created)
        MediaFileOps.discardUnlinked([rb, again])
        #expect(fm.fileExists(atPath: ra.url.path) && !fm.fileExists(atPath: rb.url.path))
        #expect(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path))
    }

    @Test func aStaleDiscardKeepsAFileAReDropReused() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let a = d.src.appendingPathComponent("a.mov"); try write(a, 300)
        let first = try MediaFileOps.ingest(a, into: d.files, mode: .copy)       // the canceled batch's copy
        let reDrop = try MediaFileOps.ingest(a, into: d.files, mode: .copy)      // after Revert: same file, reused
        #expect(first.created && reDrop.reused && reDrop.url == first.url)
        MediaFileOps.discardUnlinked([first])                                    // the stale delete lands late
        #expect(fm.fileExists(atPath: first.url.path))
        MediaFileOps.discardUnlinked([first])                                    // nothing reused it since: removed
        #expect(!fm.fileExists(atPath: first.url.path))
    }

    @Test func aCollectedLUTIsCopiedOnceByContentAndTheSourceStays() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let library = d.root.appendingPathComponent("Proj/Files/Library")
        let lut = d.src.appendingPathComponent("look.cube"); try write(lut, 200)
        let first = try MediaFileOps.collectLUT(lut, into: library)
        #expect(first.created && first.url.lastPathComponent == "look.cube")
        #expect(try MediaFileOps.fullyIdentical(lut, first.url))
        let twin = d.src.appendingPathComponent("twin.cube"); try fm.copyItem(at: lut, to: twin)
        #expect(try MediaFileOps.collectLUT(twin, into: library).url == first.url)          // same content: reused
        let other = d.src.appendingPathComponent("sub"); try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let clash = other.appendingPathComponent("look.cube"); try write(clash, 200, seed: 9)
        let second = try MediaFileOps.collectLUT(clash, into: library)                      // same name, other content
        #expect(second.created && second.url != first.url)
        #expect(try fm.contentsOfDirectory(atPath: library.path).count == 2)
        #expect(fm.fileExists(atPath: lut.path) && fm.fileExists(atPath: clash.path))
        #expect(throws: MediaFileOps.Failure.self) { try MediaFileOps.collectLUT(d.src.appendingPathComponent("none.cube"), into: library) }
    }

    @Test func aStoredLUTPathResolvesAbsoluteThenLibraryCopyAndRefusesEscapes() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let project = d.root.appendingPathComponent("Proj")
        let library = project.appendingPathComponent("Files/Library")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let lut = d.src.appendingPathComponent("look.cube"); try write(lut, 200)
        #expect(MediaManagement.resolveStoredPath(lut.path, projectFolder: project) == lut.path)    // old absolute paths work
        #expect(MediaManagement.resolveStoredPath(lut.path, projectFolder: nil) == lut.path)
        let gone = "/gone/dir/look.cube"
        #expect(MediaManagement.resolveStoredPath(gone, projectFolder: project) == gone)            // no copy: stays missing
        try write(library.appendingPathComponent("look.cube"), 200)
        #expect(MediaManagement.resolveStoredPath(gone, projectFolder: project) == library.appendingPathComponent("look.cube").path)
        let rel = MediaManagement.resolveStoredPath("Files/Library/look.cube", projectFolder: project)
        #expect(rel == project.standardizedFileURL.appendingPathComponent("Files/Library/look.cube").path)
        #expect(MediaManagement.resolveStoredPath("Files/../../Desktop/look.cube", projectFolder: project) == nil)
        #expect(MediaManagement.resolveStoredPath("../look.cube", projectFolder: project) == nil)
        #expect(MediaManagement.resolveStoredPath("Files/Library/look.cube", projectFolder: nil) == nil)
    }

    @Test func aCaseVariantRedropKeepsTheFileAStaleDiscardWouldDelete() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let upper = d.src.appendingPathComponent("IMG.MOV"); try write(upper, 300)
        let first = try MediaFileOps.ingest(upper, into: d.files, mode: .copy)                     // batch A creates IMG.MOV
        guard fm.fileExists(atPath: d.files.appendingPathComponent("img.mov").path) else { return }  // case-sensitive volume: n/a
        let lowerDir = d.root.appendingPathComponent("Other"); try fm.createDirectory(at: lowerDir, withIntermediateDirectories: true)
        let lower = lowerDir.appendingPathComponent("img.mov"); try write(lower, 300)             // identical, other spelling
        let again = try MediaFileOps.ingest(lower, into: d.files, mode: .copy)
        #expect(first.created && again.reused)
        MediaFileOps.discardUnlinked([first])                                                     // A's late discard
        #expect(fm.fileExists(atPath: first.url.path), "the re-drop's clips use this file")
        #expect(MediaFileOps.identityKey(first.url) == MediaFileOps.identityKey(d.files.appendingPathComponent("img.mov")))
        MediaFileOps.discardUnlinked([first])
        #expect(!fm.fileExists(atPath: first.url.path))
    }

    @Test func aLibraryFileACollectedLUTReusedSurvivesTheBatchDiscard() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let library = d.root.appendingPathComponent("Proj/Files/Library")
        let lut = d.src.appendingPathComponent("look.cube"); try write(lut, 200)
        let batch = try MediaFileOps.ingestLibraryItem(lut, into: library)           // a canceled batch's copy
        let twin = d.src.appendingPathComponent("twin.cube"); try fm.copyItem(at: lut, to: twin)
        #expect(try MediaFileOps.collectLUT(twin, into: library).url == batch.url)   // a grade now points at it
        MediaFileOps.discardUnlinked([batch])
        #expect(fm.fileExists(atPath: batch.url.path))
    }

    @Test func manyReusedMarksAreNotForgottenAtOnce() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let a = d.src.appendingPathComponent("a.mov"); try write(a, 300)
        let first = try MediaFileOps.ingest(a, into: d.files, mode: .copy)
        _ = try MediaFileOps.ingest(a, into: d.files, mode: .copy)                                 // marks `first`
        for i in 0..<40 {                                                                          // other files are reused too
            let f = d.src.appendingPathComponent("f\(i).mov"); try write(f, 50, seed: UInt8(i + 10))
            let r = try MediaFileOps.ingest(f, into: d.files, mode: .copy)
            _ = try MediaFileOps.ingest(f, into: d.files, mode: .copy)
            MediaFileOps.discardUnlinked([r])                                                      // resolved: mark dropped
            #expect(fm.fileExists(atPath: r.url.path))
        }
        MediaFileOps.discardUnlinked([first])
        #expect(fm.fileExists(atPath: first.url.path), "its mark is still there")
    }

    @Test func failedCopyLeavesTheOriginalAndNoFolderLitter() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let s = d.src.appendingPathComponent("gone.mov")
        #expect(throws: MediaFileOps.Failure.sourceMissing("gone.mov")) {
            _ = try MediaFileOps.ingestLibraryItem(s, into: d.files)
        }
        #expect(!fm.fileExists(atPath: d.files.path))
    }

    @Test func staleTemporariesOlderThanAnHourAreRemoved() throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        try fm.createDirectory(at: d.files, withIntermediateDirectories: true)
        let old = d.files.appendingPathComponent(".a.mov.sqpart-1"), fresh = d.files.appendingPathComponent(".b.mov.sqpart-2")
        let real = d.files.appendingPathComponent("c.mov")
        for u in [old, fresh, real] { try write(u, 10) }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: real.path)
        #expect(MediaFileOps.removeStaleTemporaries(in: d.files, olderThan: 3600) == 1)
        #expect(!fm.fileExists(atPath: old.path) && fm.fileExists(atPath: fresh.path) && fm.fileExists(atPath: real.path))
    }

    @Test func aCanceledCopyLeavesNoTemporary() async throws {
        let d = try makeDirs(); defer { try? fm.removeItem(at: d.root) }
        let s = d.src.appendingPathComponent("a.mov"); try write(s, 100)
        try fm.createDirectory(at: d.files, withIntermediateDirectories: true)
        let dest = d.files.appendingPathComponent("a.mov")
        let task = Task.detached { () -> Bool in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
            return (try? MediaFileOps.verifiedCopy(from: s, to: dest)) != nil
        }
        task.cancel()
        #expect(await task.value == false)
        #expect(try fm.contentsOfDirectory(atPath: d.files.path).isEmpty)
    }
}

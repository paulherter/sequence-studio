import Foundation
import Testing
@testable import SQCore

@Suite struct FileWalkTests {
    let fm = FileManager.default

    private func tree(_ dirs: [String], _ files: [String]) throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("sqwalk-\(UUID().uuidString)")
        for d in dirs { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        for f in files { try Data([1]).write(to: root.appendingPathComponent(f)) }
        return root
    }

    /// Windows bug this walk replaces: after one skipped folder the enumerator listed no file of any later folder.
    @Test func skippingOneFolderStillWalksItsSiblings() throws {
        let root = try tree(["A", "B.sqproj", "C"], ["A/a.mov", "B.sqproj/b.mov", "C/c.mov", "C/d.mov"])
        defer { try? fm.removeItem(at: root) }
        var files: [String] = []
        FileWalk.walk(root) { url, values, _ in
            if values?.isDirectory != true { files.append(url.lastPathComponent) }
            return url.pathExtension == "sqproj" ? .skip : .descend
        }
        #expect(files.sorted() == ["a.mov", "c.mov", "d.mov"])
    }

    @Test func dotFilesAreHiddenEverywhereAndLevelsCountFromOne() throws {
        let root = try tree(["X/Y", ".cache"], ["X/Y/z.mov", "X/.hidden.mov", ".cache/c.mov", "top.mov"])
        defer { try? fm.removeItem(at: root) }
        var seen: [String: Int] = [:]
        FileWalk.walk(root) { url, _, level in seen[url.lastPathComponent] = level; return .descend }
        #expect(seen == ["X": 1, "top.mov": 1, "Y": 2, "z.mov": 3])
    }

    @Test func stopEndsTheWholeWalk() throws {
        let root = try tree(["A", "B"], ["A/1.mov", "A/2.mov", "B/3.mov"])
        defer { try? fm.removeItem(at: root) }
        var files = 0
        let finished = FileWalk.walk(root) { _, values, _ in
            if values?.isDirectory == true { return .descend }
            files += 1
            return files == 2 ? .stop : .descend
        }
        #expect(!finished && files == 2)
    }

    /// Windows bug (Reconnect Media and the open relink crashed, 0xC000001D): `URL.resourceValues` trapped on a file of
    /// 2-4 GiB (the Oppo camera clips) and failed above 4 GiB.
    @Test func filesOfEverySizeGiveTheirSizeAndDate() throws {
        let root = try tree(["Imported"], ["Imported/small.wav"])
        defer { try? fm.removeItem(at: root) }
        let sizes: [String: Int] = ["C2171.MP4": 3_288_967_572, "C2170.MP4": 2_349_427_350, "long.mov": 6_500_000_000]
        for (name, size) in sizes {
            let url = root.appendingPathComponent("Imported/\(name)")
            fm.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(size))           // sparse where the file system allows it
            try h.close()
        }
        var seen: [String: Int] = [:]
        var dated = 0
        FileWalk.walk(root, keys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]) { url, values, _ in
            if values?.isRegularFile == true { seen[url.lastPathComponent] = values?.fileSize ?? -1 }
            if values?.contentModificationDate != nil { dated += 1 }
            return .descend
        }
        #expect(seen == sizes.merging(["small.wav": 1]) { a, _ in a })
        #expect(dated >= 4)
        #expect(FileWalk.Values.read(root.appendingPathComponent("Imported"))?.isDirectory == true)
        #expect(FileWalk.Values.read(root.appendingPathComponent("gone")) == nil)
    }

    @Test func absolutePathsOfThisSystem() {
        #expect(LocalPath.isAbsolute("/Volumes/SSD/a.mov"))
        #expect(!LocalPath.isAbsolute("Files/a.mov"))
        #expect(!LocalPath.isAbsolute(""))
        #if os(Windows)
        #expect(LocalPath.isAbsolute("C:/Users/p/a.mov") && LocalPath.isAbsolute("d:\\Footage\\a.mov"))
        #expect(LocalPath.isAbsolute("\\\\nas\\share\\a.mov"))
        #expect(!LocalPath.isAbsolute("C:a.mov"))
        #else
        #expect(!LocalPath.isAbsolute("C:/Users/p/a.mov") && !LocalPath.isAbsolute("D:\\Footage\\a.mov"))
        #endif
    }
}

import Foundation
import SQCore
import Testing
@testable import SQMedia

/// Windows bug: `URL.resourceValues` traps (0xC000001D) on a file of 2-4 GiB (the Oppo camera clips). The waveform
/// cache key and the file identity checks read such files through `FileWalk.Values` and must answer for them.
@Suite struct LargeFileValuesTests {
    let fm = FileManager.default

    /// A sparse file of `size` bytes (where the file system allows it) in a fresh folder.
    func bigFile(_ name: String, size: UInt64) throws -> (folder: URL, file: URL) {
        let folder = fm.temporaryDirectory.appendingPathComponent("sqbig-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: size)
        try h.close()
        return (folder, url)
    }

    @Test func waveformCacheKeysA3GiBClip() throws {
        let (folder, clip) = try bigFile("C2171.MP4", size: 3_288_967_572)
        defer { try? fm.removeItem(at: folder) }
        let cache = WaveformDiskCache(directory: folder.appendingPathComponent("cache"), limitBytes: 1 << 20)
        let key = cache.file(url: clip, baseBucketSize: 256)
        #expect(key != nil)
        #expect(key == cache.file(url: clip, baseBucketSize: 256))
        #expect(cache.file(url: folder.appendingPathComponent("gone.mp4"), baseBucketSize: 256) == nil)
    }

    @Test func fileIdentityOfA3GiBClip() throws {
        let (folder, clip) = try bigFile("C2170.MP4", size: 2_349_427_350)
        defer { try? fm.removeItem(at: folder) }
        let other = folder.appendingPathComponent("sub/../C2170.MP4")
        #expect(!MediaFileOps.isLinkOrAlias(clip))
        #expect(MediaFileOps.sameFile(clip, clip))
        #expect(MediaFileOps.fileIdentity(clip) != nil)
        #expect(MediaFileOps.identityKey(clip) == MediaFileOps.identityKey(URL(fileURLWithPath: other.standardizedFileURL.path)))
        #expect(MediaFileOps.fileIdentity(folder.appendingPathComponent("gone.mp4")) == nil)
    }
}

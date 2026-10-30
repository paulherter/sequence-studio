import Foundation
import SQCore
import Testing
@testable import SQLibrary

/// Windows bug: `URL.resourceValues` traps on a 2-4 GiB file; a card with camera clips that size must still scan.
@Suite struct CardLargeFileTests {
    @Test func scanListsA3GiBClipWithItsSize() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sqcardbig-\(UUID().uuidString)")
        let dcim = root.appendingPathComponent("DCIM/100OPPO")
        try fm.createDirectory(at: dcim, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let clip = dcim.appendingPathComponent("C2171.MP4")
        fm.createFile(atPath: clip.path, contents: nil)
        let h = try FileHandle(forWritingTo: clip)
        try h.truncate(atOffset: 3_288_967_572)          // sparse where the file system allows it
        try h.close()
        let found = CardScanner.scan(root)
        #expect(found.map(\.name) == ["C2171.MP4"])
        #expect(found.first?.size == 3_288_967_572)
        #expect(found.first.map { $0.modified > Date.distantPast } == true)
    }
}

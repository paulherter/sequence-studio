import Foundation
import Testing
@testable import SQCore

@Suite struct FileReplaceTests {
    @Test func replacesExistingAndMovesNew() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("final.bin"), a = dir.appendingPathComponent("a.part"), b = dir.appendingPathComponent("b.part")
        try Data("one".utf8).write(to: a)
        try FileReplace.replace(dest, withItemAt: a)
        #expect(try Data(contentsOf: dest) == Data("one".utf8))
        #expect(!FileManager.default.fileExists(atPath: a.path))
        try Data("two".utf8).write(to: b)
        try FileReplace.replace(dest, withItemAt: b)
        #expect(try Data(contentsOf: dest) == Data("two".utf8))
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }
}

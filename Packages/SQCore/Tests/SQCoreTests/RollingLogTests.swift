import Foundation
import Testing
@testable import SQCore

@Suite struct RollingLogTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("SQLogTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func writesLinesToCurrentFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RollingLog(directory: dir, maxBytesPerFile: 1000, fileCount: 3)
        log.write("first"); log.write("second"); log.flush()
        let text = try String(contentsOf: dir.appendingPathComponent("sq.log"), encoding: .utf8)
        #expect(text == "first\nsecond\n")
    }

    @Test func rotatesAndKeepsThreeFiles() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = RollingLog(directory: dir, maxBytesPerFile: 100, fileCount: 3)
        for i in 0..<40 { log.write(String(format: "line %03d xxxxxxxxxxxxxxxxxxxx", i)) }   // 30 bytes each
        log.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["sq.1.log", "sq.2.log", "sq.log"])
        for n in names {
            let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.size] as? Int ?? 0
            #expect(size <= 100)
        }
        // Newest line is in sq.log, older ones moved down; the oldest lines are gone.
        let cur = try String(contentsOf: dir.appendingPathComponent("sq.log"), encoding: .utf8)
        let old = try String(contentsOf: dir.appendingPathComponent("sq.2.log"), encoding: .utf8)
        #expect(cur.contains("line 039"))
        #expect(!old.contains("line 000"))
        #expect(old < cur)
    }

    @Test func resumesSizeFromExistingFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = RollingLog(directory: dir, maxBytesPerFile: 60, fileCount: 3)
        a.write(String(repeating: "a", count: 40)); a.flush()
        let b = RollingLog(directory: dir, maxBytesPerFile: 60, fileCount: 3)
        b.write(String(repeating: "b", count: 40)); b.flush()
        let rotated = try String(contentsOf: dir.appendingPathComponent("sq.1.log"), encoding: .utf8)
        #expect(rotated.hasPrefix("aaaa"))
    }
}

import Foundation
import Testing
@testable import SQPremiereImport

@Suite struct PRInflateTests {
    @Test func portableInflateMatchesInput() throws {
        #if canImport(Compression)
        var text = ""
        for i in 0..<5000 { text += "<Clip id=\"\(i % 97)\">Premiere \(i * 31 % 1013)</Clip>\n" }
        let raw = Data(text.utf8)
        let packed = try (raw as NSData).compressed(using: .zlib) as Data
        #expect(packed.count < raw.count / 2)
        #expect(try PRInflate.inflate([UInt8](packed), limit: raw.count) == raw)
        #expect(throws: PRImportError.corruptArchive) { try PRInflate.inflate([UInt8](packed), limit: 100) }
        #expect(throws: PRImportError.corruptArchive) { try PRInflate.inflate([UInt8](packed.prefix(40)), limit: raw.count) }
        #endif
    }
}

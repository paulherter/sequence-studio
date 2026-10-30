import Foundation
import Testing
@testable import SQMedia

@Test func ebmlLaceSizeRejectsCorruptValues() {
    // 1-byte vint bias is 63: raw 63 is delta 0, raw 70 is +7.
    #expect(WebMFile.Parser.laceSize(after: 100, raw: 70, length: 1) == 107)
    #expect(WebMFile.Parser.laceSize(after: 100, raw: 63, length: 1) == 100)
    #expect(WebMFile.Parser.laceSize(after: 10, raw: 0, length: 1) == nil)   // negative
    #expect(WebMFile.Parser.laceSize(after: 10, raw: .max, length: 1) == nil) // unknown size
    #expect(WebMFile.Parser.laceSize(after: Int.max, raw: UInt64(Int64.max), length: 8) == nil)  // overflow
    #expect(WebMFile.Parser.laceSize(after: 1, raw: 5, length: 9) == nil)
}

@Test func renderFormatsFormSequences() {
    let d = URL(fileURLWithPath: "/tmp/x")
    for ext in ["exr", "dpx", "tga"] {
        let urls = (1...3).map { d.appendingPathComponent("f_000\($0).\(ext)") }
        #expect(ImageSequence.groups(in: urls).count == 1)
        #expect(StillImage.extensions.contains(ext))
    }
}

@Test func mediaBookmarkForExistingFileAndMissingFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bm-\(UUID().uuidString).txt")
    try Data("x".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(MediaBookmark.make(for: url) != nil)
    #expect(MediaBookmark.make(for: url.appendingPathExtension("gone")) == nil)
}

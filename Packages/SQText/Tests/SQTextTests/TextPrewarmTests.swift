import Testing
import Foundation
import SQCore
@testable import SQText

@Suite(.serialized) struct TextPrewarmTests {
    @Test func prewarmFillsTheCache() throws {
        // Unique text and size: no other test can have cached it (and no cache clearing that could disturb them).
        let style = TextStyle(fontName: "Helvetica-Bold", size: 77, color: .white)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "Warm me \(UUID())", style: style), animations: nil)
        #expect(!TextGenerator.isCached(ref: ref))
        try TextGenerator.prewarm(ref: ref)
        #expect(TextGenerator.isCached(ref: ref))
        let bad = GeneratorRef(kind: "text", payload: Data("nope".utf8))
        #expect(throws: TextGeneratorError.self) { try TextGenerator.prewarm(ref: bad) }
    }
}

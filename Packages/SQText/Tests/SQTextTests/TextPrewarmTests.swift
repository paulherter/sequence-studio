#if canImport(CoreText)
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

    /// PLAYBACK-PERF "Text payload decode memo": every text layer was JSON-decoded twice per composited frame on the render
    /// thread. A decoded payload is kept; the result is the same value, errors are not kept (always rethrown).
    @Test func decodeIsMemoizedAndExact() throws {
        let fade = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 2), 1, .linear)])],
                                    duration: Time(1, 2))
        let set = AnimationSet(in: fade, out: nil)
        let template = TextTemplate(name: "t", text: "Decode me \(UUID())", style: TextStyle(fontName: "Helvetica", size: 50, color: .white))
        let ref = try TextGenerator.makeRef(template: template, animations: set)
        let before = TextGenerator.decodeMemoHits
        let a = try TextGenerator.decode(ref)
        let b = try TextGenerator.decode(ref)
        #expect(a.0 == template && a.1 == set)
        #expect(b.0 == a.0 && b.1 == a.1)
        #expect(TextGenerator.decodeMemoHits >= before + 1)
        // Same bytes, another version number: decoded on its own (version is part of the key and checked first).
        let future = GeneratorRef(kind: ref.kind, payload: ref.payload, payloadVersion: TextGenerator.payloadVersion + 1)
        #expect(throws: TextGeneratorError.self) { _ = try TextGenerator.decode(future) }
        let bad = GeneratorRef(kind: "text", payload: Data("nope \(UUID())".utf8))
        #expect(throws: TextGeneratorError.self) { _ = try TextGenerator.decode(bad) }
        #expect(throws: TextGeneratorError.self) { _ = try TextGenerator.decode(bad) }
    }
}
#endif

import Testing
import Foundation
import CoreVideo
import SQCore
@testable import SQText

@Suite struct TextGeneratorTests {
    let style = TextStyle(fontName: "Helvetica-Bold", size: 100, color: .white)
    var template: TextTemplate { TextTemplate(name: "t", text: "Hello", style: style) }
    let fadeIn = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity",
                                                          keys: [(.zero, 0, .linear), (Time(1, 2), 1, .linear)])],
                                  duration: Time(1, 2))
    let canvas = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))

    @Test func codecRoundTrip() throws {
        let set = AnimationSet(in: fadeIn, out: nil)
        let ref = try TextGenerator.makeRef(template: template, animations: set)
        #expect(ref.kind == GeneratorRef.text)
        #expect(ref.payloadVersion == TextGenerator.payloadVersion)
        let (t, a) = try TextGenerator.decode(ref)
        #expect(t == template)
        #expect(a == set)
        // Stable bytes.
        #expect(try TextGenerator.makeRef(template: template, animations: set).payload == ref.payload)
        let (_, none) = try TextGenerator.decode(try TextGenerator.makeRef(template: template, animations: nil))
        #expect(none == nil)
    }

    @Test func newerVersionAndWrongKindFail() throws {
        var ref = try TextGenerator.makeRef(template: template, animations: nil)
        ref.payloadVersion = TextGenerator.payloadVersion + 1
        #expect(throws: TextGeneratorError.unsupportedPayloadVersion(found: TextGenerator.payloadVersion + 1,
                                                                     supported: TextGenerator.payloadVersion)) {
            try TextGenerator.decode(ref)
        }
        let other = GeneratorRef(kind: "solid", payload: Data())
        #expect(throws: TextGeneratorError.wrongKind("solid")) { try TextGenerator.decode(other) }
        let bad = GeneratorRef(kind: "text", payload: Data("nope".utf8))
        #expect(throws: TextGeneratorError.self) { try TextGenerator.decode(bad) }
    }

    @Test func fadeInOpacity() throws {
        let ref = try TextGenerator.makeRef(template: template, animations: AnimationSet(in: fadeIn, out: nil))
        let dur = Time(4, 1)
        let f0 = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: dur, canvas: canvas, scale: 1))
        #expect(f0.opacity == 0)
        let mid = try #require(try TextGenerator.frame(ref: ref, localTime: Time(2, 1), clipDuration: dur, canvas: canvas, scale: 1))
        #expect(mid.opacity == 1 && mid.scale == 1 && mid.offsetX == 0 && mid.offsetY == 0)
    }

    @Test func cacheHitReturnsSameBuffer() throws {
        let ref = try TextGenerator.makeRef(template: template, animations: AnimationSet(in: fadeIn, out: nil))
        let a = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(4, 1), canvas: canvas, scale: 1))
        let b = try #require(try TextGenerator.frame(ref: ref, localTime: Time(1, 1), clipDuration: Time(4, 1), canvas: canvas, scale: 1))
        #expect(a.buffer === b.buffer)
        let c = try #require(try TextGenerator.frame(ref: ref, localTime: Time(1, 1), clipDuration: Time(4, 1), canvas: canvas, scale: 0.5))
        #expect(c.buffer !== a.buffer)
    }

    @Test func placementCentersBlockOnCanvas() throws {
        let ref = try TextGenerator.makeRef(template: template, animations: nil)
        let f = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(1, 1), canvas: canvas, scale: 1))
        let layout = TextLayout.layout(text: "Hello", style: style, maxWidth: nil)
        let b = layout.bounds
        #expect(abs((f.x + (b.x - layout.inkBounds.x) + b.width / 2) - 960) < 0.01)
        #expect(abs((f.y + (b.y - layout.inkBounds.y) + b.height / 2) - 540) < 0.01)
        #expect(abs(f.width - Double(CVPixelBufferGetWidth(f.buffer))) < 1)
    }

    @Test func emptyTextIsNil() throws {
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "e", text: "", style: style), animations: nil)
        #expect(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(1, 1), canvas: canvas, scale: 1) == nil)
    }
}

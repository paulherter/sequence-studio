import Foundation
import Testing
import SQCore
import SQText
@testable import SQPlayback

@Suite struct LookPreviewTests {
    private func ref(_ text: String, size: Double = 40) throws -> GeneratorRef {
        try TextGenerator.makeRef(template: TextTemplate(name: "t", text: text, style: TextStyle(fontName: "Menlo", size: size, color: .white)), animations: nil)
    }

    @Test func aTextPreviewSwapsOnlyTheRefOfItsContainer() throws {
        let state = LookPreviewState()
        let (from, to, other) = (try ref("A"), try ref("A", size: 90), try ref("B"))
        let clip = Clip.ID(), layer = UUID()
        #expect(state.text(from, container: clip, layer: layer) == from)
        #expect(state.set(.text(container: clip, layer: layer, from: from, to: to)))
        #expect(state.text(from, container: clip, layer: layer) == to)
        #expect(state.text(other, container: clip, layer: layer) == other)          // another text of the same container
        #expect(state.text(from, container: Clip.ID(), layer: layer) == from)       // the same ref in another clip
        #expect(!state.set(.text(container: clip, layer: layer, from: from, to: to)))   // unchanged: no redraw
        #expect(state.text(from, container: clip, layer: UUID()) == from)  // a second layer with the same ref
        #expect(state.set(nil))
        #expect(state.text(from, container: clip, layer: layer) == from)
    }

    @Test func aCaptionPreviewMapsEveryStyleAndIsDerivedOnce() throws {
        let state = LookPreviewState()
        let base = CaptionPresetLibrary.builtIn
        #expect(state.captionLibrary(over: base).styles == base.styles)
        let style = TextStyle(fontName: "Menlo", size: 99, color: .white)
        #expect(state.set(.captions(style: style, animation: nil, karaoke: nil)))
        let lib = state.captionLibrary(over: base)
        #expect(lib.styles.count == base.styles.count && lib.styles.values.allSatisfy { $0 == style })
        #expect(lib.animations == base.animations)                    // a Look without animation keeps the captions' own
        #expect(lib.style(for: "no-such-ref") == style)
        #expect(state.karaoke(nil) == nil)
        #expect(state.set(.captions(style: style, animation: nil, karaoke: KaraokeStyle())))
        #expect(state.karaoke(nil) == KaraokeStyle())
        #expect(state.set(nil))
        #expect(state.karaoke(nil) == nil)
        #expect(state.captionLibrary(over: base).styles == base.styles)
    }
}

import Foundation
import Testing
import SQCore
@testable import SQText

@Suite(.serialized) struct PaulsKitTests {
    @Test func roundTripsThroughSqstyle() throws {
        let kit = StyleKit.pauls
        #expect(try StyleKitFile.decode(StyleKitFile.encode(kit)) == kit)
    }

    @Test func carriesOnlyResearchedValues() {
        let kit = StyleKit.pauls
        #expect(kit.fonts[StyleKit.brandFontToken] == "Inter-Bold")        // E2 2.4: Inter Bold
        #expect(kit.colors[StyleKit.textColorToken] == .white)             // white captions
        #expect(kit.caption?.font == .token(StyleKit.brandFontToken))
        #expect(kit.caption?.usesPill == false)                            // soft shadow, no pill
        #expect(kit.caption?.size == nil)                                  // unknown: left unset
        #expect(kit.motion == nil)                                         // unknown: left unset
        #expect(kit.pill == nil)
        // Caption y 0.707 of the canvas height (C1 brand kit): middle plus 0.207 down.
        #expect(kit.captionPosition == CaptionPosition(vertical: .middle, offsetY: 0.707 - 0.5))
    }

    @Test func captionStyleResolvesToInterBoldWithShadow() {
        let lib = CaptionPresetLibrary.base.applying(.pauls)
        let s = lib.style(for: StyleKit.captionStyleRef)
        #expect(s.fontName == "Inter-Bold")
        #expect(s.color == .white)
        #expect(s.shadow != nil)
        #expect(s.background == nil)
        #expect(lib.animation(for: StyleKit.captionAnimationRef) == .captionPop)
    }

    @Test func importKeepsTheImportersBrand() {
        var mine = StyleKit(fonts: [StyleKit.brandFontToken: "Avenir-Black"])
        mine = mine.merging(.pauls).kit
        #expect(mine.fonts[StyleKit.brandFontToken] == "Avenir-Black")
        #expect(mine.caption != nil)
    }
}

#if canImport(CoreText)
import Testing
@testable import SQText

@Suite struct RasterizeHostileInputTests {
    @Test func nonFiniteOrHugeScaleNeverTraps() throws {
        let style = TextStyle()
        for scale in [Double.infinity, .nan, -.infinity] {
            #expect(try TextRenderer.render(text: "Aa", style: style, maxWidth: nil, scale: scale) == nil)
        }
        #expect(throws: TextRendererError.self) {
            _ = try TextRenderer.render(text: "Aa", style: style, maxWidth: nil, scale: 1e12)
        }
        #expect(try TextRenderer.render(text: "Aa", style: style, maxWidth: nil, scale: 1) != nil)
    }
}
#endif

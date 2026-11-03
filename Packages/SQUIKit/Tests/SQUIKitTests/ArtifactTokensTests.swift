import Testing
@testable import SQUIKit

@Suite struct ArtifactTokensTests {
    @Test func surfacesAndLinesMatchTheArtifact() {
        #expect(SQTokens.Hex.raisedDark == 0x2E2E31 && SQTokens.Hex.wellDark == 0x161618 && SQTokens.Hex.wellLight == 0xEAEAEC)
        #expect(SQTokens.Line.hair2Dark == 0.11 && SQTokens.Line.edgeDark == 0.14 && SQTokens.Line.currentDark == 0.08 && SQTokens.Line.hoverLight == 0.04)
    }
}

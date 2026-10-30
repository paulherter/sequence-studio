import Testing
@testable import SQInspectorUI

@Suite struct HueCurveExplanationTests {
    @Test func everyCurveExplainsItself() {
        for k in HueCurveKind.allCases {
            #expect(k.explanation.hasPrefix(k.title))
        }
    }
}

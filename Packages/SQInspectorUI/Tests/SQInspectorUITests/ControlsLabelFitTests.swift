import AppKit
import Testing
import SQCore
import SQUIKit
@testable import SQInspectorUI

/// Truncation guard: the label column of the Controls grid is wide enough for every property name of the Transform
/// stage ("Uniform Scale", "Shutter Angle") in the row font.
@MainActor
@Suite("Controls label column fit")
struct ControlsLabelFitTests {
    private func width(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: Theme.Typography.body]).width)
    }

    @Test func transformNamesFit() {
        let names = EffectTransformStage.transformSpec.params.map(\.title) + ["Uniform Scale", "Blend Mode"]
        for n in names {
            #expect(width(n) <= Theme.Inspector.nameWidth, "\(n) is \(width(n)) pt, column \(Theme.Inspector.nameWidth)")
        }
    }
}

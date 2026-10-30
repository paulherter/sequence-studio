import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

@MainActor @Suite struct ColorPrimaryWheelsTests {
    @Test func everyWheelRoundTripsPuckAndMaster() {
        for w in PrimaryWheel.allCases {
            let puck = ColorWheelMath.Value(hue: 70, amount: 0.4)
            let t = w.triple(puck: puck, master: 0.3)
            let back = w.puck(of: t)
            #expect(abs(back.hue - 70) < 0.5 && abs(back.amount - 0.4) < 0.02, "\(w.title) puck")
            #expect(abs(w.master(of: t) - 0.3) < 0.02, "\(w.title) master")
        }
    }

    @Test func neutralWheelsSitInTheCenter() {
        for w in PrimaryWheel.allCases {
            let t = w.triple(StepPrimaries())
            #expect(w.puck(of: t).amount < 1e-6 && abs(w.master(of: t)) < 1e-6)
        }
    }

    @Test func horizontalMasterSliderMapsEdgesAndCenter() {
        #expect(abs(ColorWheelMath.master(forX: 0, width: 100) + 1) < 1e-9)
        #expect(abs(ColorWheelMath.master(forX: 50, width: 100)) < 1e-9)
        #expect(abs(ColorWheelMath.x(forMaster: 1, width: 100) - 100) < 1e-9)
    }

    @Test func primaryRowsShowWholeNumbersWithNeutralFifty() {
        #expect(StepPrimaryRow.contrast.neutral == 50 && StepPrimaryRow.saturation.neutral == 50)
        #expect(StepPrimaryRow.pivot.range == 0...100)
        #expect(StepPrimaryRow.allCases.allSatisfy { $0.decimals == 0 })
    }

    @Test func settingAWheelWritesTheStepAndReadsBack() throws {
        let m = ColorInspectorModel()
        var graphs: [ColorGraph] = []
        m.onGraphChange = { graphs.append($0) }
        m.startEmptyGraph()
        let id = try #require(graphs.last?.steps.first?.id)
        m.setStepWheel(id, .gain, puck: .init(hue: 30, amount: 0.5), master: 0.2)
        let r = m.stepWheel(id, .gain)
        #expect(abs(r.puck.hue - 30) < 0.5 && abs(r.master - 0.2) < 0.02)
        #expect(m.stepWheel(id, .lift).puck.amount < 1e-6)
    }
}

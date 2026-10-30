import Testing
@testable import SQCore

@Suite struct StepStatusTests {
    @Test func singularAndPlural() {
        #expect(StepStatus.line("Trim", frames: -1) == "Trim: 1 frame earlier")
        #expect(StepStatus.line("Slip", frames: StepStatus.large) == "Slip: 10 frames later")
    }
}

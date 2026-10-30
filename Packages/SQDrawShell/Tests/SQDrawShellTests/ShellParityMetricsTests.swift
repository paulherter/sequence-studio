import Testing
@testable import SQDrawShell

@Suite struct ShellParityMetricsTests {
    /// Mac SQFormRow caption host: caption line plus a 10 pt gap before the next row (round 18 measurement).
    @Test func captionGapMatchesMac() {
        #expect(ShellForm.M.captionAfter == 10)
        #expect(ShellForm.M.captionLine == 14)
    }
}

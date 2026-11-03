import Testing
@testable import SQDrawShell

@Suite struct ShellParityMetricsTests {
    /// Settings heading (art.html): 18 above the line, 4 after it, no row gap before the first row of its group.
    @Test func captionGapMatchesMac() {
        #expect(ShellForm.M.captionAfter == 4)
        #expect(ShellForm.M.captionLine == 14)
    }
}

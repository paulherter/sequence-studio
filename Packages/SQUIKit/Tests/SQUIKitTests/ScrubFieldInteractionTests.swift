import AppKit
import Testing
@testable import SQUIKit

@MainActor @Suite struct ScrubFieldInteractionTests {
    private func field() -> ScrubField {
        let f = ScrubField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        f.range = 0...100; f.value = 40
        return f
    }

    // Design v11: every scrubbable value is accent, animated or not.
    @Test func valueColourIsAccent() {
        let f = field()
        #expect(f.valueColor == Theme.Colors.accent)
        f.isAnimated = true
        #expect(f.valueColor == Theme.Colors.accent)
    }

    // F8: reset
    @Test func resetUsesDefaultValueAsOneTriple() {
        let f = field(); f.defaultValue = 10
        var log: [String] = []
        f.onBegin = { log.append("begin") }
        f.onChange = { log.append("changed \($0)") }
        f.onEnd = { log.append("end \($0)") }
        f.resetToDefault()
        #expect(f.value == 10)
        #expect(log == ["begin", "changed 10.0", "end 10.0"])
        log = []
        f.resetToDefault()          // already default: no undo step
        #expect(log.isEmpty)
    }

    @Test func onResetWinsOverDefaultValue() {
        let f = field(); f.defaultValue = 10
        var called = 0
        f.onReset = { called += 1 }
        f.resetToDefault()
        #expect(called == 1 && f.value == 40)
    }

    @Test func resetWithoutDefaultDoesNothing() {
        let f = field()
        f.resetToDefault()
        #expect(f.value == 40)
    }

    // F10: arrow bursts
    @Test func arrowBurstIsOneTriple() {
        let f = field()
        var log: [String] = []
        f.onBegin = { log.append("begin") }
        f.onChange = { _ in log.append("changed") }
        f.onEnd = { _ in log.append("end") }
        f.stepForTesting(+1); f.stepForTesting(+1); f.stepForTesting(+1)
        #expect(f.value == 43)
        #expect(log == ["begin", "changed", "changed", "changed"])
        f.endStepBurst()
        #expect(log.last == "end" && log.filter { $0 == "end" }.count == 1)
        f.endStepBurst()            // idempotent
        #expect(log.filter { $0 == "end" }.count == 1)
    }

    @Test func stepBurstState() {
        var b = StepBurst()
        let first = b.step(), second = b.step()
        #expect(first && !second)       // the first press opens a burst, the next joins it
        let closed = b.end(), again = b.end()
        #expect(closed && !again)       // closing is reported once
        let reopened = b.step()
        #expect(reopened)
    }
}

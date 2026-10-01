import AppKit
import Testing
@testable import SQEditorUI

@MainActor @Suite struct ScrubFieldTests {
    @Test func displayAndFormatter() {
        let f = ScrubField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        f.unit = "%"; f.value = 42
        #expect(f.displayText == "42 %")
        f.valueFormatter = { "\($0)!" }
        #expect(f.displayText == "42.0!")
    }

    @Test func accessibilityStepIsOneTriple() {
        let f = ScrubField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        f.range = 0...10; f.value = 10
        var log: [String] = []
        f.onBegin = { log.append("begin") }
        f.onChange = { log.append("changed \($0)") }
        f.onEnd = { log.append("end \($0)") }
        _ = f.accessibilityPerformDecrement()
        #expect(log == ["begin", "changed 9.0", "end 9.0"])
        f.value = 10
        log = []
        _ = f.accessibilityPerformIncrement()   // clamped: no change, no undo step
        #expect(log.isEmpty)
    }
}

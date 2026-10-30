import Testing
@testable import SQEditorSession

@Suite struct ToolHoldTests {
    @Test func tapIsSticky() {
        var h = ToolHold()
        h.press(.char("c"), tool: .razor, previous: .selection, at: 0)
        #expect(h.release(.char("c"), at: 0.1) == nil)
    }

    @Test func holdRevertsToPreviousTool() {
        var h = ToolHold()
        h.press(.char("c"), tool: .razor, previous: .ripple, at: 0)
        #expect(h.release(.char("c"), at: 0.4) == .ripple)
        #expect(h.release(.char("c"), at: 0.5) == nil)   // only once
    }

    /// Focus lost while a tool key is held: the key-up never comes, so the hold ends as if it came now.
    @Test func releaseAllEndsALongHold() {
        var h = ToolHold()
        h.press(.char("c"), tool: .razor, previous: .ripple, at: 0)
        #expect(h.releaseAll(at: 0.4) == .ripple)
        #expect(h.release(.char("c"), at: 0.5) == nil)
    }

    @Test func releaseAllKeepsATappedTool() {
        var h = ToolHold()
        h.press(.char("c"), tool: .razor, previous: .ripple, at: 0)
        #expect(h.releaseAll(at: 0.1) == nil)
        var empty = ToolHold()
        #expect(empty.releaseAll(at: 1) == nil)
    }

    @Test func exactlyAtThresholdCountsAsHold() {
        var h = ToolHold()
        h.press(.char("y"), tool: .slip, previous: .selection, at: 1)
        #expect(h.release(.char("y"), at: 1 + ToolHold.threshold) == .selection)
    }

    @Test func samePreviousAndNewIsNoRevert() {
        var h = ToolHold()
        h.press(.char("c"), tool: .razor, previous: .razor, at: 0)
        #expect(h.release(.char("c"), at: 1) == nil)
    }

    @Test func otherKeyUpIgnored() {
        var h = ToolHold()
        h.press(.char("c"), tool: .razor, previous: .selection, at: 0)
        #expect(h.release(.char("x"), at: 1) == nil)
        #expect(h.release(.char("c"), at: 1) == .selection)
    }

    @Test func overlappingHoldKeepsOriginalPrevious() {
        var h = ToolHold()
        h.press(.char("c"), tool: .razor, previous: .selection, at: 0)
        h.press(.char("y"), tool: .slip, previous: .razor, at: 0.5)
        #expect(h.release(.char("c"), at: 0.6) == nil)          // c is no longer the active hold
        #expect(h.release(.char("y"), at: 1.0) == .selection)   // back to the tool from before the chain
    }

    @Test func autoRepeatDoesNotRestartTimer() {
        var h = ToolHold()
        h.press(.char("c"), tool: .razor, previous: .selection, at: 0)
        h.press(.char("c"), tool: .razor, previous: .razor, at: 0.3)   // repeat of the same key
        #expect(h.release(.char("c"), at: 0.4) == .selection)
    }

    @Test func clearForgetsHold() {
        var h = ToolHold()
        h.press(.char("c"), tool: .razor, previous: .selection, at: 0)
        h.clear()
        #expect(h.release(.char("c"), at: 1) == nil)
    }
}

import Testing
@testable import SQEditorSession

@Suite struct EffectiveTimelineToolTests {
    /// Tools that only act in the monitor behave as Selection inside the timeline.
    @Test func monitorToolsActAsSelection() {
        for t: TimelineTool in [.type, .mask] {
            #expect(t.effectiveTimelineTool == .selection)
        }
    }

    @Test func timelineToolsStayThemselves() {
        for t: TimelineTool in [.selection, .trackSelectForward, .rippleEdit, .rollEdit, .slip, .slide, .razor, .hand, .rateStretch, .zoom] {
            #expect(t.effectiveTimelineTool == t)
        }
    }

    @Test func toolStateKeepsTheActiveTool() {
        var s = ToolState()
        s.tool = .type
        #expect(s.timelineTool == .selection)
        #expect(s.tool == .type)
    }
}

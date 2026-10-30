import AppKit
import Testing
import SQUIKit
@testable import SQMonitorUI

/// Program monitor M5: Pip shows with no sequence and, for a fresh project, with a sequence that has nothing on it.
@MainActor @Suite struct ProgramEmptyPipTests {
    private func pips(in v: NSView) -> [SQMascotView] {
        (v as? SQMascotView).map { [$0] } ?? v.subviews.flatMap { pips(in: $0) }
    }

    private func shown(_ kind: ProgramEmptyKind) -> (ProgramEmptyView, NSWindow) {
        let v = ProgramEmptyView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = v
        v.apply(kind)
        v.layoutSubtreeIfNeeded()
        return (v, window)
    }

    @Test func modelPicksTheKind() {
        let m = MonitorPanelModel(frameDuration: .init(1, 30), mode: .program)
        #expect(m.programEmptyState == .none)
        m.timelineIsEmpty = true
        #expect(m.programEmptyState == .emptyTimeline)
        m.hasSequence = false
        #expect(m.programEmptyState == .noSequence)
    }

    @Test func noSequenceShowsPipAndButton() {
        let (v, w) = shown(.noSequence)
        _ = w
        #expect(!v.isHidden && !v.buttonIsHidden)
        let pip = pips(in: v).first
        #expect(pip?.place == .programEmpty)
        #expect(pip?.isShownWithSize == true)
    }

    @Test func emptyTimelineShowsPipWithoutButton() {
        let (v, w) = shown(.emptyTimeline)
        _ = w
        #expect(!v.isHidden && v.buttonIsHidden)
        #expect(pips(in: v).first?.isShownWithSize == true)
    }

    @Test func hiddenWhenTheTimelineHasContent() {
        let (v, w) = shown(.none)
        _ = w
        #expect(v.isHidden)
    }
}

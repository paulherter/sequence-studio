import Foundation
import SQCore
import Testing
@testable import SQDrawEditor
@testable import SQDrawKit

@Suite("EditorFooter") struct EditorFooterTests {
    func setup(inOut: TimeRange? = nil) -> (EditorScreen, EditorSnapshot) {
        var (t, _, _, _, _, _) = sampleTimeline()
        t.inOut = inOut
        let snap = EditorSnapshot(projectName: "Sample", timeline: t)
        var s = EditorScreen()
        s.layout(width: 1280, height: 800, snap)
        return (s, snap)
    }

    @Test func dragOnEmptyStripMarksANewRange() {
        var (s, snap) = setup()
        let m = s.footer.scrubMath(s.footerState(snap))
        let bar = s.scrubBar
        func x(_ sec: Int64) -> Float { bar.x + Float(m.x(for: Time(seconds: sec))) }
        _ = s.handle(.mouseDown(x: x(2), y: bar.midY, modifiers: []), snap)
        _ = s.handle(.mouseDragged(x: x(5), y: bar.midY), snap)
        // While dragging the footer shows the preview range.
        #expect(s.footerState(snap).markIn != nil && s.footerState(snap).markOut != nil)
        let out = s.handle(.mouseUp(x: x(5), y: bar.midY), snap)
        guard case .setInOut(let r, .newRange)? = out.first else { Issue.record("\(out)"); return }
        let fd = snap.frameDuration
        #expect(abs(r.start.frameIndex(frameDuration: fd) - 60) <= 2 && abs(r.end.frameIndex(frameDuration: fd) - 150) <= 2)
        #expect(s.footerState(snap).markIn == nil)   // preview dropped: the stored marks show again
    }

    @Test func clickOnStripScrubs() {
        var (s, snap) = setup()
        let bar = s.scrubBar
        let down = s.handle(.mouseDown(x: bar.midX, y: bar.midY, modifiers: []), snap)
        let up = s.handle(.mouseUp(x: bar.midX, y: bar.midY), snap)
        #expect((down + up).contains(.beginScrub) && (down + up).last == .endScrub)
    }

    @Test func storedMarksReachTheFooter() {
        let r = TimeRange(start: Time(seconds: 1), end: Time(seconds: 3))
        let (s, snap) = setup(inOut: r)
        let st = s.footerState(snap)
        #expect(st.markIn == r.start && st.markOut == r.end && st.inOutDurationText != nil)
    }
}

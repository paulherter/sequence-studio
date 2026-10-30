import AppKit
import Testing
import SQCore
@testable import SQMonitorUI

@MainActor
@Suite struct MonitorFooterWidthTests {
    private func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }

    @Test(arguments: [MonitorMode.source, .program], [380.0, 320.0])
    func footerFitsWithoutClipping(mode: MonitorMode, width: Double) throws {
        let m = MonitorPanelModel(frameDuration: Time(1, 30), mode: mode)
        m.duration = Time(3725, 1); m.currentTime = Time(3601, 1)
        let panel = MonitorPanelView(model: m)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 380))
        win.contentView = host
        host.addSubview(panel)
        panel.frame = host.bounds
        win.layoutIfNeeded(); panel.layoutSubtreeIfNeeded()
        let tc = try #require(allViews(panel).first { $0 is TimecodeField })
        let footer = try #require(tc.superview)
        // The scrub bar sits above the row in the same footer (v9 `.mtr`); the row is everything else.
        let kids = footer.subviews.filter { !($0 is MonitorScrubBar) }.sorted { $0.frame.minX < $1.frame.minX }
        #expect(tc.frame.width >= 92, "timecode clipped")
        // The field frame carries a 2 pt alignment inset into the next view; compare the buttons and the right group.
        let rest = Array(kids.dropFirst())
        for (a, b) in zip(rest, rest.dropFirst()) { #expect(a.frame.maxX <= b.frame.minX + 0.5, "overlap \(a.frame) \(b.frame)") }
        #expect(tc.frame.minX + 92 <= (rest.first?.frame.minX ?? 0) + 0.5)
        #expect(kids.last!.frame.maxX <= footer.bounds.maxX + 0.5)
    }
}

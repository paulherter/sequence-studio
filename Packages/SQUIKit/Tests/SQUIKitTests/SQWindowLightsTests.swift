import AppKit
import Testing
@testable import SQUIKit

@MainActor
@Suite struct SQWindowLightsTests {
    @Test func editorOriginsSitOnTheDesignDots() {
        let l = SQWindowLights.Layout.editor
        let o = SQWindowLights.origins(layout: l, buttonSize: CGSize(width: 14, height: 14))
        // v9 dots: 12 pt, 8 apart, 16 from the left -> centers 22, 42, 62; vertically centered in the 44 pt bar.
        #expect(o.map { $0.x + 7 } == [22, 42, 62])
        #expect(o.allSatisfy { $0.y + 7 == ShellMetrics.topBar / 2 })
    }

    @Test func containerIsPinnedToTheWindowTop() {
        let f = SQWindowLights.containerFrame(windowSize: CGSize(width: 1000, height: 700), barHeight: 44)
        #expect(f == CGRect(x: 0, y: 656, width: 1000, height: 44))
    }

    @Test func realButtonsArePlacedVisibleAndSurviveResize() throws {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        let layout = SQWindowLights.Layout.editor
        SQWindowLights.install(in: w, layout: layout)
        func check() throws {
            let close = try #require(w.standardWindowButton(.closeButton))
            let zoom = try #require(w.standardWindowButton(.zoomButton))
            #expect(close.frame.midX == 22 && zoom.frame.midX == 62)
            #expect(close.frame.midY == layout.barHeight / 2)
            #expect(close.alphaValue == 1 && !close.isHidden)
            let container = try #require(close.superview?.superview)
            #expect(container.frame.height == layout.barHeight)
            #expect(container.frame.maxY == w.frame.height)
        }
        try check()
        w.setContentSize(NSSize(width: 900, height: 500))
        SQWindowLights.reapply(in: w)
        try check()
    }
}

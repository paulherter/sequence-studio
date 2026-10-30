import AppKit
import Testing
@testable import SQMonitorUI

@MainActor @Suite struct ViewerViewTests {
    @Test func instantiateAndLayout() {
        let v = ViewerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        v.frameProvider = { _ in nil }
        v.zoom = .percent(100)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        v.layoutSubtreeIfNeeded()
        v.layout()
        #expect(v.zoom == .percent(100))
        if let ml = v.layer as? CAMetalLayer { #expect(ml.drawableSize.width >= 640) }
    }

    @Test func resizeKeepsAspectGravityAndNotifiesOwner() {
        let v = ViewerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        var resizes = 0
        v.onResize = { resizes += 1 }
        v.layout()
        #expect(v.metalLayer?.contentsGravity == .resizeAspect)
        let first = resizes
        #expect(first >= 1)
        v.layout()
        #expect(resizes == first)                     // same size: no redraw request
        v.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        v.layout()
        #expect(resizes == first + 1)
        if let ml = v.metalLayer {
            let scale = ml.contentsScale
            #expect(ml.drawableSize == CGSize(width: 200 * scale, height: 400 * scale))
        }
    }
}

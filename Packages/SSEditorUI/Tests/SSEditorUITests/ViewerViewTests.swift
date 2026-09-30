import AppKit
import Testing
@testable import SSEditorUI

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
}

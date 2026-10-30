import AppKit
import Testing
import SQRender
@testable import SQMonitorUI

/// Source and Program viewers are the same `ViewerView`: both layers must carry the one display color space, so a clip
/// looks identical in both monitors.
@MainActor @Suite struct ViewerColorPipelineTests {
    @Test func sourceAndProgramViewersShareTheDisplayColorSpace() throws {
        let source = ViewerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let program = ViewerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        source.layout(); program.layout()
        let a = try #require(source.metalLayer?.colorspace)
        let b = try #require(program.metalLayer?.colorspace)
        #expect(a == b)
        #expect(a == Presenter.displayColorSpace)
        #expect(source.metalLayer?.pixelFormat == program.metalLayer?.pixelFormat)
    }
}

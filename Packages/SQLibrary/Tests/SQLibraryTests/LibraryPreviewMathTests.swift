import Testing
@testable import SQLibrary

@Suite struct LibraryPreviewMathTests {
    @Test func skipClamps() {
        #expect(LibraryPreviewMath.skipTarget(position: 3, delta: -5, duration: 60) == 0)
        #expect(LibraryPreviewMath.skipTarget(position: 58, delta: 5, duration: 60) == 60)
        #expect(LibraryPreviewMath.skipTarget(position: 10, delta: 5, duration: 60) == 15)
        #expect(LibraryPreviewMath.skipTarget(position: 10, delta: 5, duration: 0) == 15)
        #expect(LibraryPreviewMath.skipTarget(position: .nan, delta: 5, duration: 60) == 0)
    }

    @Test func timeText() {
        #expect(LibraryPreviewMath.timeText(0) == "0:00")
        #expect(LibraryPreviewMath.timeText(65.9) == "1:05")
        #expect(LibraryPreviewMath.timeText(3725) == "1:02:05")
        #expect(LibraryPreviewMath.timeText(-3) == "0:00")
        #expect(LibraryPreviewMath.timeText(.infinity) == "0:00")
    }

    @Test func modes() {
        #expect(LibraryPreviewMath.mode(for: .audio) == .audio)
        #expect(LibraryPreviewMath.mode(for: .video) == .video)
        #expect(LibraryPreviewMath.mode(for: .image) == .image)
        #expect(LibraryPreviewMath.mode(for: .lut) == nil)
    }

    @Test func viewerHeightClamps() {
        #expect(LibraryPreviewMath.viewerHeight(stored: nil, fallback: 150, panelHeight: 800) == 150)
        #expect(LibraryPreviewMath.viewerHeight(stored: 10, fallback: 150, panelHeight: 800) == LibraryPreviewMath.minViewerHeight)
        #expect(LibraryPreviewMath.viewerHeight(stored: 9000, fallback: 150, panelHeight: 800) == LibraryPreviewMath.maxViewerHeight)
        #expect(LibraryPreviewMath.viewerHeight(stored: .nan, fallback: 150, panelHeight: 800) == 150)
        // a short panel keeps room for the list: never below the minimum, never more than panel minus the reserve
        #expect(LibraryPreviewMath.viewerHeight(stored: 300, fallback: 150, panelHeight: 400) == 400 - LibraryPreviewMath.listReserve - LibraryPreviewMath.chromeHeight)
        #expect(LibraryPreviewMath.viewerHeight(stored: 300, fallback: 150, panelHeight: 100) == LibraryPreviewMath.minViewerHeight)
        #expect(LibraryPreviewMath.viewerHeight(stored: 300, fallback: 150, panelHeight: 0) == 300)   // unknown panel size: no panel limit
    }

    @Test func dragResizeGrowsUpward() {
        #expect(LibraryPreviewMath.resizedHeight(start: 150, dragDeltaY: -40) == 190)   // pointer up (y falls in a flipped view) = taller
        #expect(LibraryPreviewMath.resizedHeight(start: 150, dragDeltaY: 40) == 110)
    }
}

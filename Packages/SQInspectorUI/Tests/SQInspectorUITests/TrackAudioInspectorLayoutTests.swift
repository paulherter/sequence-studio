import AppKit
import Testing
@testable import SQInspectorUI

/// All seven sliders of the track audio inspector share one left and one right edge at every width (the control column caps them).
@MainActor @Suite struct TrackAudioInspectorLayoutTests {
    func sliders(_ root: NSView) -> [NSView] {
        var out: [NSView] = []
        func walk(_ v: NSView) { if v is NumericSlider { out.append(v) }; v.subviews.forEach(walk) }
        walk(root)
        return out
    }

    @Test func slidersShareLeftAndRightEdges() {
        for w: CGFloat in [280, 420] {
            let v = TrackAudioInspectorView(model: TrackAudioInspectorModel())
            v.frame = NSRect(x: 0, y: 0, width: w, height: 400)
            v.layoutSubtreeIfNeeded()
            let frames = sliders(v).map { v.convert($0.bounds, from: $0) }
            #expect(frames.count == 7)
            let minX = frames.map(\.minX), maxX = frames.map(\.maxX)
            #expect(Set(minX).count == 1, "left edges at \(w): \(minX)")
            #expect(Set(maxX).count == 1, "right edges at \(w): \(maxX)")
            #expect(maxX.first == min(w - ControlsGrid.trailing, ControlsGrid.controlColumnMaxX), "right edges at \(w): \(maxX)")
        }
    }
}

import AppKit
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

private let fd = Time(1001, 30000)

/// Ruler click/scrub through the real responder chain (window -> ruler subview -> TimelineView), with headers present
/// and the timeline placed at an offset inside its window.
@MainActor
struct RulerClickTests {
    @MainActor private struct Rig {
        let window: NSWindow
        let view: TimelineView

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
            let clip = Clip(name: "c", media: UUID(), kind: .video,
                            source: TimeRange(start: .zero, duration: Time(414, 30)), start: .zero)
            let t = Timeline(name: "t", frameDuration: fd,
                             tracks: [Track(kind: .video, clips: [clip], name: "V1"), Track(kind: .audio, name: "A1")])
            view = TimelineView(timeline: t, frame: NSRect(x: 50, y: 30, width: 1000, height: 300))
            window.contentView?.addSubview(view)
            view.setZoom(pointsPerSecond: 34)
        }

        func click(atViewX x: CGFloat, y: CGFloat = 10, type: NSEvent.EventType = .leftMouseDown) {
            let e = NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
            // An unordered test window does not dispatch through `sendEvent`: hit-test like AppKit would, then let the
            // event travel the responder chain from the hit view (ruler subview -> TimelineView).
            let hit = window.contentView?.hitTest(e.locationInWindow)
            switch type {
            case .leftMouseDown: hit?.mouseDown(with: e)
            default: hit?.mouseUp(with: e)
            }
        }
    }

    @Test func clickAtTickXSeeksToTick() {
        let rig = Rig()
        var got: [Time] = []
        rig.view.onSeek = { got.append($0) }
        for scroll in [CGFloat(0), 120] {
            rig.view.scroll(toX: scroll)
            for seconds in [5, 6, 8] {
                let t = Time(Int64(seconds), 1).snapped(to: fd)
                let x = rig.view.geometry.x(for: t)
                guard x > TimelineGeometry.contentOriginX else { continue }
                rig.click(atViewX: x)
                rig.click(atViewX: x, type: .leftMouseUp)
                #expect(got.last == t, "scroll \(scroll), t=\(seconds)s")
            }
        }
        #expect(!got.isEmpty)
    }

    @Test func rulerClickIsNotOffsetByHeaderColumn() {
        let rig = Rig()
        var got: Time?
        rig.view.onSeek = { got = $0 }
        rig.click(atViewX: TimelineGeometry.contentOriginX + 34 * 5)       // 5 s at 34 pt/s, scroll 0
        #expect(got == Time(5, 1).snapped(to: fd))
    }

    @Test func geometryRoundTripsTickPositions() {
        var g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 34)
        let empty = Timeline(name: "", frameDuration: fd)
        for scroll in [CGFloat(0), 77.5, 400] {
            g.scrollX = scroll
            for frame in [0, 1, 150, 299, 1000] as [Int64] {
                let t = fd * frame
                #expect(g.time(atX: g.x(for: t)) == t)
                if g.x(for: t) >= TimelineGeometry.contentOriginX {
                    #expect(g.hitTest(CGPoint(x: g.x(for: t), y: 5), in: empty) == .ruler)
                }
            }
        }
    }
}

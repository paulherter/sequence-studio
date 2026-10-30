import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 30)

/// A press on a key-lane glyph (found by the host's hit tester) is reported and consumed; any other press ends the lane keys.
@MainActor
struct KeyLaneClickTests {
    private func press(_ view: TimelineView, _ window: NSWindow, at p: CGPoint) {
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(p, to: nil), modifierFlags: [],
                                   timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: 1)!
        view.mouseDown(with: e)
    }

    @Test func glyphPressReportsClipAndTimeThenOtherPressClears() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(20, 1)), start: .zero)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip], name: "V1")])
        let v = TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        window.contentView?.addSubview(v)
        v.setZoom(pointsPerSecond: 34)
        v.setSelection([clip.id])
        v.keyLaneSection = .opacity
        let saved = TimelineView.keyLaneHitTester
        defer { TimelineView.keyLaneHitTester = saved }
        TimelineView.keyLaneHitTester = { _, _, rect, p, _ in p.y > rect.midY ? Time(5, 1) : nil }
        var got: [(Clip.ID, Time, Bool)] = []
        v.onKeyLaneClick = { got.append(($0, $1, $2)) }
        let row = v.geometry.rows(for: v.timeline).first!
        press(v, window, at: CGPoint(x: v.geometry.x(for: Time(5, 1)), y: row.y + row.height - 4))
        #expect(got.count == 1)
        #expect(got.first?.0 == clip.id)
        #expect(got.first?.1 == Time(5, 1))
        #expect(v.keyLaneKeysActive)
        press(v, window, at: CGPoint(x: v.geometry.x(for: Time(5, 1)), y: row.y + 3))
        #expect(!v.keyLaneKeysActive)
        #expect(got.count == 1)
    }
}

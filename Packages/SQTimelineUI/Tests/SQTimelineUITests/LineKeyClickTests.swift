import AppKit
import Foundation
import SQCore
import SQEditorSession
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 30)

/// A press on a key of the opacity line reports it (so the session can select it and nudge it); any other press clears.
@MainActor
struct LineKeyClickTests {
    private func rig() -> (NSWindow, TimelineView, Clip) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(20, 1)), start: .zero)
        _ = clip.addOpacityKey(atLocal: Time(5, 1))
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip], name: "V1")])
        let view = TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        window.contentView?.addSubview(view)
        view.setZoom(pointsPerSecond: 34)
        return (window, view, clip)
    }

    private func press(_ view: TimelineView, _ window: NSWindow, at p: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(p, to: nil), modifierFlags: modifiers,
                                   timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: 1)!
        view.mouseDown(with: e)
    }

    @Test func clickOnKeyReportsItAndShiftExtends() {
        let (w, v, clip) = rig()
        let row = v.geometry.rows(for: v.timeline).first!
        let rect = CGRect(x: v.geometry.x(for: clip.timeline.start), y: row.y,
                          width: v.geometry.x(for: clip.timeline.end) - v.geometry.x(for: clip.timeline.start), height: row.height)
        let key = OpacityLine.keyPoints(clip: clip, clipRect: rect)[0]
        var got: [(LineKeyRef?, Bool)] = []
        v.onLineKeyClick = { got.append(($0, $1)) }
        press(v, w, at: key)
        #expect(got.count == 1)
        #expect(got.first?.0 == LineKeyRef(clip: clip.id, property: .opacity, key: clip.animation.opacity.track.keys[0].id))
        #expect(got.first?.1 == false)
        press(v, w, at: key, modifiers: .shift)
        #expect(got.last?.1 == true)
    }
}

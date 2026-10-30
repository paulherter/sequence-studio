import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 30)

/// Bug (feedback 2026-10-05): playing, then a short click back in the ruler (no drag) kept playback running; a drag stopped it.
/// The ruler is the playhead's handle: every press there is a scrub gesture that stops playback, with or without a drag.
/// Wired exactly like `EditorPanels` (timeline view -> session), driven through the real responder chain, with the stub
/// engine as an injected clock (`simulatePlayback`).
@MainActor
struct PlayheadTransportTests {
    @MainActor private final class Rig {
        let window: NSWindow
        let view: TimelineView
        let engine = StubProgramEngine()
        let session: EditorSession

        init(marker: Bool = false) {
            var t = Track(kind: .video)
            try! t.overwrite(Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero))
            var tl = Timeline(name: "Main", frameDuration: fd, tracks: [t])
            if marker { tl.markers = [Marker(time: Time(4, 1))] }
            session = EditorSession(project: Project(name: "P", timelines: [tl]), engine: engine)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
            view = TimelineView(timeline: tl, frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
            window.contentView?.addSubview(view)
            view.setZoom(pointsPerSecond: 60)
            view.onSeek = { [session] in session.seek(to: $0) }
            view.onScrubBegan = { [session] in session.beginScrub() }
            view.onScrub = { [session] in session.scrub(to: $0) }
            view.onScrubEnded = { [session] in session.endScrub() }
        }

        func x(_ t: Time) -> CGFloat { view.geometry.x(for: t) }

        func send(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 10) {
            let e = NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
            let hit = window.contentView?.hitTest(e.locationInWindow)
            switch type {
            case .leftMouseDown: hit?.mouseDown(with: e)
            case .leftMouseDragged: view.mouseDragged(with: e)
            default: view.mouseUp(with: e)
            }
        }

        func click(at t: Time) { send(.leftMouseDown, x: x(t)); send(.leftMouseUp, x: x(t)) }

        /// Engine clock runs on for `n` frames; the session must ignore it while paused.
        func tick(_ n: Int) { for _ in 0..<n { engine.simulatePlayback(advance: fd) } }

        var scrubBalance: Int {
            engine.calls.filter { $0 == .beginScrub }.count - engine.calls.filter { $0 == .endScrub }.count
        }

        func expectStopped(at t: Time, _ c: SourceLocation = #_sourceLocation) {
            #expect(!session.isPlaying, sourceLocation: c)
            #expect(engine.rate.isPaused, sourceLocation: c)
            tick(10)
            #expect(session.playhead == t, "playhead stays put after ticks", sourceLocation: c)
            #expect(scrubBalance == 0, "every scrub gesture ended", sourceLocation: c)
        }
    }

    @Test func rulerClickWithoutDragStopsPlayback() {
        let r = Rig()
        r.session.seek(to: Time(3, 1))
        r.session.playPause()
        r.tick(15)
        #expect(r.session.isPlaying)
        let back = r.session.playhead - fd * 4      // a few frames back, pure click (no mouseDragged at all)
        r.click(at: back)
        r.expectStopped(at: back)
    }

    @Test func pressInRulerStopsBeforeMouseUp() {
        let r = Rig()
        r.session.playPause()
        r.tick(30)
        r.send(.leftMouseDown, x: r.x(Time(2, 1)))
        #expect(!r.session.isPlaying)                // stopped on press, not on release
        r.tick(5)
        #expect(r.session.playhead == Time(2, 1))
        r.send(.leftMouseUp, x: r.x(Time(2, 1)))
        r.expectStopped(at: Time(2, 1))
    }

    @Test func rapidClickDragPlaySequencesAlwaysStop() {
        let r = Rig()
        for i in 0..<20 {
            r.session.playPause()
            r.tick(3 + i % 4)
            #expect(r.session.isPlaying)
            let t = Time(Int64(1 + i % 5), 1)
            switch i % 3 {
            case 0: r.click(at: t)                                                    // click
            case 1: r.send(.leftMouseDown, x: r.x(t) + 30)                           // drag back to t
                r.send(.leftMouseDragged, x: r.x(t) + 10); r.send(.leftMouseDragged, x: r.x(t))
                r.send(.leftMouseUp, x: r.x(t))
            default: r.send(.leftMouseDown, x: r.x(t)); r.send(.leftMouseUp, x: r.x(t) + 1)   // up without drag, jitter
            }
            r.expectStopped(at: t)
        }
    }

    @Test func clickOnMarkerFlagSeeksAndStops() {
        let r = Rig(marker: true)
        r.session.playPause()
        r.tick(10)
        r.click(at: Time(4, 1))
        r.expectStopped(at: Time(4, 1))
    }

    @Test func escapeDuringRulerScrubEndsTheScrub() {
        let r = Rig()
        r.session.playPause()
        r.send(.leftMouseDown, x: r.x(Time(2, 1)))
        r.send(.leftMouseDragged, x: r.x(Time(3, 1)))
        r.view.cancelGesture()                       // what Escape does mid-drag; the mouse-up is then swallowed
        #expect(r.scrubBalance == 0)
        r.session.playPause()
        #expect(r.session.isPlaying)
        r.click(at: Time(1, 1))
        r.expectStopped(at: Time(1, 1))
    }
}

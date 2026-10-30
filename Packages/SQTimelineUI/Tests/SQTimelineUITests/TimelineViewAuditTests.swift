import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 24)

/// Pre-release timeline audit (2026-10-07): view-level mouse paths, driven with real NSEvents.
@MainActor
struct TimelineViewAuditTests {
    @MainActor private struct Rig {
        let window: NSWindow
        let view: TimelineView
        let clip: Clip

        init(clip custom: Clip? = nil) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
            clip = custom ?? Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 2400), start: .zero)
            let t = Timeline(name: "t", frameDuration: fd,
                             tracks: [Track(kind: .video, clips: [clip], name: "V1"), Track(kind: .audio, name: "A1")])
            view = TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
            window.contentView?.addSubview(view)
            view.setZoom(pointsPerSecond: 48)
        }

        /// y in the middle of V1.
        var laneY: CGFloat { view.geometry.rows(for: view.timeline).first { $0.kind == .video }.map { $0.y + $0.height / 2 } ?? 60 }

        func send(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            let e = NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: flags,
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: clicks, pressure: 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: e)
            case .leftMouseDragged: view.mouseDragged(with: e)
            default: view.mouseUp(with: e)
            }
        }
    }

    /// The app sends Esc to "back to Selection tool" unless the timeline reports a drag: a zoom-tool marquee is one, so
    /// its Esc reaches the view and cancels it instead of switching the tool and zooming anyway on mouse up.
    @Test func zoomMarqueeCountsAsDrag() {
        let rig = Rig()
        rig.view.toolState.tool = .zoom
        let x = rig.view.geometry.x(for: fd * 24)
        rig.send(.leftMouseDown, x: x, y: rig.laneY)
        rig.send(.leftMouseDragged, x: x + 80, y: rig.laneY)
        #expect(rig.view.isDragging)
        #expect(rig.view.cancelsOnEscape)
        let before = rig.view.geometry.pointsPerSecond
        rig.view.cancelGesture()
        rig.send(.leftMouseUp, x: x + 80, y: rig.laneY)
        #expect(!rig.view.isDragging)
        #expect(rig.view.geometry.pointsPerSecond == before)
    }

    /// Two quick razor clicks on one clip are two cuts, not "open in Source" (Premiere: double-click only opens with the
    /// Selection tool).
    @Test func razorDoubleClickCutsInsteadOfOpening() {
        let rig = Rig()
        rig.view.toolState.tool = .razor
        rig.view.toolState.snapping = false
        var opened = 0, commits = 0
        rig.view.onOpenClipInSource = { _ in opened += 1 }
        rig.view.onCommit = { _ in commits += 1 }
        let x = rig.view.geometry.x(for: fd * 48)
        rig.send(.leftMouseDown, x: x, y: rig.laneY, clicks: 2)
        rig.send(.leftMouseUp, x: x, y: rig.laneY, clicks: 2)
        #expect(opened == 0)
        #expect(commits == 1)
    }

    @Test func zoomToolDoubleClickDoesNotOpenClip() {
        let rig = Rig()
        rig.view.toolState.tool = .zoom
        var opened = 0
        rig.view.onOpenClipInSource = { _ in opened += 1 }
        let x = rig.view.geometry.x(for: fd * 48)
        rig.send(.leftMouseDown, x: x, y: rig.laneY, clicks: 2)
        rig.send(.leftMouseUp, x: x, y: rig.laneY, clicks: 2)
        #expect(opened == 0)
    }

    @Test(arguments: [TimelineTool.selection, .hand, .slip, .trackSelectForward])
    func otherToolsDoubleClickStillOpens(tool: TimelineTool) {
        let rig = Rig()
        rig.view.toolState.tool = tool
        var opened = 0
        rig.view.onOpenClipInSource = { _ in opened += 1 }
        let x = rig.view.geometry.x(for: fd * 48)
        rig.send(.leftMouseDown, x: x, y: rig.laneY, clicks: 2)
        rig.send(.leftMouseUp, x: x, y: rig.laneY, clicks: 2)
        #expect(opened == 1)
    }

    /// A Graphic opens its layers (the Graphics panel), not its text on the monitor and not Source.
    @Test func graphicDoubleClickOpensItsLayers() {
        var g = Clip(name: "G", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 2400), start: .zero)
        g.generator = GeneratorRef.graphicsClip
        let rig = Rig(clip: g)
        var layers: [Clip.ID] = [], text = 0, source = 0
        rig.view.onOpenGraphicLayers = { layers.append($0) }
        rig.view.onEditTextClip = { _ in text += 1 }
        rig.view.onOpenClipInSource = { _ in source += 1 }
        let x = rig.view.geometry.x(for: fd * 48)
        rig.send(.leftMouseDown, x: x, y: rig.laneY, clicks: 2)
        rig.send(.leftMouseUp, x: x, y: rig.laneY, clicks: 2)
        #expect(layers == [g.id] && text == 0 && source == 0)
    }

    @Test func selectionDoubleClickStillOpens() {
        let rig = Rig()
        var opened = 0
        rig.view.onOpenClipInSource = { _ in opened += 1 }
        let x = rig.view.geometry.x(for: fd * 48)
        rig.send(.leftMouseDown, x: x, y: rig.laneY, clicks: 2)
        rig.send(.leftMouseUp, x: x, y: rig.laneY, clicks: 2)
        #expect(opened == 1)
    }

    /// A marker scrolled under the track headers is hidden there: a ruler press above the headers must not grab it.
    @Test func hiddenMarkerUnderHeadersIsNotGrabbed() {
        let rig = Rig()
        var t = rig.view.timeline
        _ = t.addMarker(at: fd * 24)
        rig.view.setTimeline(t)
        rig.view.scroll(toX: 48 + 40)        // the 1 s marker ends 40 pt left of the content origin
        let x = rig.view.geometry.x(for: fd * 24)
        guard x > TimelineGeometry.toolColumnWidth + 8, x < TimelineGeometry.contentOriginX - 8 else {
            Issue.record("marker x \(x) not under the headers"); return
        }
        var edited = 0, moved = 0
        rig.view.onEditMarker = { _ in edited += 1 }
        rig.view.onMarkerMoved = { _, _ in moved += 1 }
        rig.send(.leftMouseDown, x: x, y: 10, clicks: 2)
        rig.send(.leftMouseUp, x: x, y: 10, clicks: 2)
        #expect(edited == 0)
        #expect(rig.view.markerID(at: CGPoint(x: x, y: 10)) == nil)
        #expect(moved == 0)
    }

    /// A marker under the playhead: a press on the ruler far above the dot is not a marker hit (it scrubs), the dot itself is.
    @Test func markerNotHitAboveItsDot() {
        let rig = Rig()
        var t = rig.view.timeline
        let m = t.addMarker(at: fd * 24)
        rig.view.setTimeline(t)
        let x = rig.view.geometry.x(for: fd * 24)
        #expect(rig.view.markerID(at: CGPoint(x: x, y: 2)) == nil)
        #expect(rig.view.markerID(at: CGPoint(x: x, y: 6)) == nil)
        #expect(rig.view.markerID(at: CGPoint(x: x, y: TimelineGeometry.rulerHeight - 8)) == m)
        #expect(MarkerRange.grabBand(rulerHeight: 24).contains(17))
        #expect(!MarkerRange.grabBand(rulerHeight: 24).contains(5))
    }

    /// Two markers close together: the press picks the nearer one, so the later marker can still be grabbed.
    @Test func markerHitPicksNearest() {
        let rig = Rig()
        var t = rig.view.timeline
        let a = t.addMarker(at: fd * 24)
        let b = t.addMarker(at: fd * 25)          // 2 pt apart at 48 pt/s
        rig.view.setTimeline(t)
        let xb = rig.view.geometry.x(for: fd * 25)
        #expect(rig.view.markerID(at: CGPoint(x: xb + 1, y: 10)) == b)
        let xa = rig.view.geometry.x(for: fd * 24)
        #expect(rig.view.markerID(at: CGPoint(x: xa - 1, y: 10)) == a)
    }
}

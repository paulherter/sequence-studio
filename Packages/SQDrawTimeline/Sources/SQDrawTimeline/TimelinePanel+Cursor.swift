import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI

/// The Mac `TimelineView.resetCursorRects` and its drag-time `NSCursor.set` calls as one query: which pointer shape
/// shows at a point (tool cursors from `TimelineCursorMap`, transition edges, item lane trims, track resize edges), and
/// during a gesture the shape it began with. The panel puts it into `HostHover` for every mouse event it handles.
/// It also offers the track header buttons' tips (the Mac `TrackHeaderView.setTooltip` names).
extension TimelinePanel {
    /// The shape at host pixels `x, y`; nil outside the panel (the host's arrow).
    public func cursor(at x: Float, y: Float, modifiers: InputModifiers = []) -> DrawCursor? {
        if let g = gesture { return dragCursor(g) }
        guard frame.contains(x, y) else { return nil }
        return cursor(atPoint: point(x: x, y: y), modifiers: modifiers)
    }

    /// The shape at a panel point while no gesture runs (the Mac cursor rects, last added wins: row edges, item lanes,
    /// transitions, then the tool's regions).
    func cursor(atPoint p: CGPoint, modifiers mods: InputModifiers) -> DrawCursor? {
        if interaction.isIdle, TrackSizing.zone(at: p, rows: rows, viewWidth: size.width) != nil { return .resizeUpDown }
        let tool = toolState.timelineTool
        if tool == .selection, case .bar(_, _, let mode)? = itemLaneHit(at: p) {
            switch mode {
            case .head: return .trimIn
            case .tail: return .trimOut
            case .move: return nil
            }
        }
        let content = CGRect(x: TimelineGeometry.contentOriginX, y: TimelineGeometry.rulerHeight,
                             width: max(size.width - TimelineGeometry.contentOriginX, 0),
                             height: max(trackAreaHeight - TimelineGeometry.rulerHeight, 0))
        guard content.contains(p) else { return nil }
        if tool == .selection, let t = transitionCursor(at: p) { return t }
        let regions = TimelineCursorMap.regions(timeline: timeline, geometry: geometry, tool: tool, content: content,
                                                command: mods.contains(.command), option: mods.contains(.option))
        return regions.last { $0.rect.contains(p) }.map { Self.drawCursor($0.kind) }
    }

    /// Transition boxes: resize on the ends, a hand over the body; transition layers: resize on the ends and the cut.
    private func transitionCursor(at p: CGPoint) -> DrawCursor? {
        let fd = timeline.format.frameDuration
        for row in rows where p.y >= row.y && p.y < row.maxY {
            guard let track = timeline.track(row.track) else { continue }
            for r in track.resolvedTransitions(frameDuration: fd) {
                let box = TransitionLayout.rect(r, row: row, geometry: geometry)
                guard box.contains(p) else { continue }
                let e = TransitionLayout.edgeWidth(forWidth: box.width)
                return p.x < box.minX + e || p.x >= box.maxX - e ? .resizeLeftRight : .openHand
            }
        }
        return TransitionLayerLayout.hitTest(p, in: timeline, geometry: geometry) != nil ? .resizeLeftRight : nil
    }

    /// The shape a running gesture keeps (the Mac drags set theirs at the press and leave it until the release).
    func dragCursor(_ g: Gesture) -> DrawCursor? {
        switch g {
        case .resize: return .resizeUpDown
        case .keystone, .attach, .transitionLayer, .speed: return .resizeLeftRight
        case .transition: return pressCursor == .openHand ? .closedHand : .resizeLeftRight
        case .band: return .resizeUpDown
        case .patch(_, _, let dragging): return dragging ? .closedHand : nil
        case .clips:
            if interaction.moveHint?.contains("opy") == true { return .dragCopy }
            if toolState.timelineTool == .hand { return .closedHand }
            return pressCursor
        default: return pressCursor
        }
    }

    static func drawCursor(_ k: TimelineCursorKind) -> DrawCursor {
        switch k {
        case .trimIn: .trimIn
        case .trimOut: .trimOut
        case .rippleIn: .rippleIn
        case .rippleOut: .rippleOut
        case .rateIn: .rateIn
        case .rateOut: .rateOut
        case .roll: .roll
        case .slip: .slip
        case .slide: .slide
        case .razor: .razor
        case .hand: .openHand
        case .zoom: .zoomIn
        case .trackSelect: .trackSelect
        case .copy: .dragCopy
        }
    }

    /// After a mouse event: the shape into `HostHover` (inside the panel or while its gesture runs), and on a move the
    /// tip of the header button under the pointer.
    func publishHover(_ e: InputEvent) {
        let hover = HostHover.current
        switch e {
        case .mouseMoved(let x, let y):
            hover.request(cursor(at: x, y: y, modifiers: liveModifiers?() ?? []))
            if frame.contains(x, y) { hover.offerTip(tip(atPoint: point(x: x, y: y))) }
        case .mouseDown(let x, let y, _), .mouseDragged(let x, let y), .mouseUp(let x, let y):
            hover.request(cursor(at: x, y: y, modifiers: liveModifiers?() ?? []))
        case .keyDown, .scroll: break      // keys: `key(_:modifiers:)` publishes
        }
    }

    /// After a key: a tool key or a held modifier changes the shape under a resting pointer.
    func publishKeyHover() {
        guard let p = hoverPoint, gesture == nil else { return }
        HostHover.current.replace(cursor(atPoint: p, modifiers: liveModifiers?() ?? []))
    }

    /// The Mac `TrackHeaderView` button tips.
    func tip(atPoint p: CGPoint) -> String? {
        guard let (_, toggle) = headerHit(p) else { return nil }
        return switch toggle {
        case .target: "Target Track"
        case .visible: "Show or Hide Track"
        case .mute: "Mute Track"
        case .solo: "Solo Track"
        case .lock: "Lock Track"
        case .syncLock: "Sync Lock"
        }
    }
}

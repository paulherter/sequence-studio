import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI

/// G1 Keystones on the timeline, translated from TimelineView+Keystones: the drop ghost (where and how long a dragged
/// keystone lands on the clip under the pointer) and the bar of the keystone applied last, whose edges stretch it (keys
/// follow live, one undo step on release). The host drives the drop like the media drop: `keystoneHover` per pointer
/// move, `keystoneDrop` on release, `keystoneExit` when the drag leaves. The keystone travels as
/// `KeystoneDrag.string(for:)`, the Mac pasteboard payload.
extension TimelinePanel {
    // MARK: Drop

    /// The video clip under `p` and its row, when a keystone may land there.
    private func keystoneTarget(at p: CGPoint) -> (clip: Clip, row: TrackRow)? {
        guard let row = rows.first(where: { p.y >= $0.y && p.y < $0.maxY }), row.kind == .video,
              let track = timeline.track(row.track), !track.isLocked else { return nil }
        let t = geometry.unsnappedTime(atX: p.x)
        guard let c = track.clips.first(where: { $0.timeline.start <= t && t < $0.timeline.end }) else { return nil }
        return (c, row)
    }

    /// A keystone dragged over the panel at window pixels `x`, `y`: the ghost follows. True when it may land there.
    @discardableResult
    public mutating func keystoneHover(_ k: Keystone, x: Float, y: Float) -> Bool {
        let p = point(x: x, y: y)
        var ghost: KeystoneBar?
        if let t = keystoneTarget(at: p) {
            let local = geometry.unsnappedTime(atX: p.x) - t.clip.timeline.start
            ghost = KeystoneBar(clip: t.clip.id, span: k.placement(dropAt: local, clipDuration: t.clip.timeline.duration), name: k.name)
        }
        keystoneGhost = ghost
        return ghost != nil
    }

    /// The keystone drag left the panel or was canceled: the ghost goes.
    public mutating func keystoneExit() { keystoneGhost = nil }

    /// Released over the panel: the keystone lands where the ghost showed (the Mac `onDropKeystone`). Empty when there is
    /// no clip under the pointer.
    public mutating func keystoneDrop(_ k: Keystone, x: Float, y: Float) -> [TimelineAction] {
        keystoneHover(k, x: x, y: y)
        defer { keystoneGhost = nil }
        guard let g = keystoneGhost else { return [] }
        return [.dropKeystone(k, clip: g.clip, span: g.span)]
    }

    // MARK: The bar of the keystone applied last

    /// Shows the bar of a keystone that just landed (or was stretched) on `clip`, as it is now in the session; nil hides
    /// it. The bar hides by itself once its clip changes by anything but the bar (undo, another edit, deleted).
    public mutating func setKeystoneBar(_ bar: KeystoneBar?, clip: Clip?) {
        keystoneBar = bar
        keystoneBarClip = bar == nil ? nil : clip
    }

    /// `sync`: the bar goes when its clip is no longer what the bar left (the Mac `syncKeystoneBar`).
    mutating func syncKeystoneBar() {
        guard let bar = keystoneBar else { return }
        if timeline.tracks.lazy.flatMap(\.clips).first(where: { $0.id == bar.clip }) != keystoneBarClip {
            keystoneBar = nil
            keystoneBarClip = nil
        }
    }

    private func barRect(_ bar: KeystoneBar) -> (rect: CGRect, clip: Clip, track: Track.ID)? {
        for row in rows where row.kind == .video && row.height >= KeystoneBar.minimumRowHeight {
            if let c = timeline.track(row.track)?.clips.first(where: { $0.id == bar.clip }) {
                guard bar.span.end <= c.timeline.duration else { return nil }      // the clip was trimmed under it
                return (KeystoneBar.rect(span: bar.span, clipStart: c.timeline.start, row: row, geometry: geometry), c, row.track)
            }
        }
        return nil
    }

    /// A press on a bar edge with the Selection tool starts the stretch. True when it took the press.
    mutating func keystoneDown(_ p: CGPoint) -> Bool {
        guard toolState.timelineTool == .selection, let bar = keystoneBar, let r = barRect(bar),
              timeline.track(r.track)?.isLocked == false,
              let edge = KeystoneBar.edge(at: p, barRect: r.rect) else { return false }
        gesture = .keystone(KeystoneEdgeDrag(bar: bar, edge: edge, original: r.clip, current: bar.span))
        return true
    }

    /// The pointer is over a bar edge (the host shows the left-right resize cursor).
    public func keystoneEdgeHovered(at x: Float, y: Float) -> Bool {
        let p = point(x: x, y: y)
        guard toolState.timelineTool == .selection, let bar = keystoneBar, let r = barRect(bar) else { return false }
        return KeystoneBar.edge(at: p, barRect: r.rect) != nil
    }

    mutating func keystoneDragged(_ d0: KeystoneEdgeDrag, to p: CGPoint) {
        var d = d0
        let local = geometry.unsnappedTime(atX: p.x) - d.original.timeline.start
        let span = KeystoneBar.dragged(d.bar.span, edge: d.edge, toLocal: local.snapped(to: timeline.frameDuration),
                                       clipDuration: d.original.timeline.duration, minimum: timeline.frameDuration)
        guard span != d.current else { return }
        d.current = span
        gesture = .keystone(d)
        var c = d.original
        c.restretchKeystone(d.bar.span, to: span)
        var t = timeline
        if (try? t.replaceClip(c)) != nil { timeline = t }
        keystoneBar = KeystoneBar(clip: d.bar.clip, span: span, name: d.bar.name)
    }

    /// Release: the preview goes back to the committed timeline and the session commits the stretch (one undo step).
    mutating func keystoneUp(_ d: KeystoneEdgeDrag, at p: CGPoint) -> [TimelineAction] {
        keystoneDragged(d, to: p)
        guard case .keystone(let last) = gesture else { return [] }
        timeline = committed
        guard last.current != last.bar.span else { keystoneBar = last.bar; return [] }
        return [.restretchKeystone(clip: last.bar.clip, from: last.bar.span, to: last.current, name: last.bar.name)]
    }

    // MARK: Drawing

    func drawKeystoneOverlay(_ cv: inout Canvas, rows: [TrackRow]) {
        if let bar = keystoneBar, let r = barRect(bar) { drawKeystoneBar(&cv, r.rect, name: bar.name, ghost: false) }
        if let g = keystoneGhost,
           let row = rows.first(where: { r in timeline.track(r.track)?.clips.contains { $0.id == g.clip } ?? false }),
           let c = timeline.track(row.track)?.clips.first(where: { $0.id == g.clip }) {
            let x0 = geometry.x(for: c.timeline.start), x1 = geometry.x(for: c.timeline.end)
            cv.stroke(roundedRect: CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height - 1).insetBy(dx: 1, dy: 1), radius: 0,
                      width: 1, theme.accent)
            var r = KeystoneBar.rect(span: g.span, clipStart: c.timeline.start, row: row, geometry: geometry)
            if row.height < KeystoneBar.minimumRowHeight { r = CGRect(x: r.minX, y: row.y + 1, width: r.width, height: row.height - 3) }
            drawKeystoneBar(&cv, r, name: g.name, ghost: true)
        }
    }

    private func drawKeystoneBar(_ cv: inout Canvas, _ r: CGRect, name: String, ghost: Bool) {
        let radius = DrawTheme.Radius.small.cg
        cv.fill(roundedRect: r, radius: radius, skin.accentTint)
        cv.stroke(roundedRect: r, radius: radius, width: 1, theme.accent)
        if !ghost, r.width > 10 {
            for x in [r.minX + 2, r.maxX - 4] {                       // edge grips
                cv.fill(roundedRect: CGRect(x: x, y: r.minY + 2, width: 2, height: r.height - 4), radius: 1, theme.onClip)
            }
        }
        guard r.width > 30 else { return }
        cv.saveGState()
        cv.clip(to: CGRect(x: r.minX + 7, y: r.minY, width: r.width - 14, height: r.height))
        cv.draw(name, in: CGRect(x: r.minX + 7, y: r.minY, width: r.width - 14, height: r.height),
                fontSize: CGFloat(DrawTheme.TypeSize.caption), theme.onClip)
        cv.restoreGState()
    }
}

import Foundation
import SQCore

/// G11 Follow: the Graphics panel's Follow section and the overlay's view of pinned layers.
extension GraphicsEditor {
    /// The graphic as drawn at the playhead, Follow resolved (same call as evaluation): overlay boxes, handles and hit
    /// tests use it. The stored document when nothing follows.
    public var shownDocument: GraphicsDocument? {
        guard let doc = document else { return nil }
        return doc.resolvingFollow(atLocal: localTime, canvas: canvas, text: textMeasure)
    }

    /// The single selected layer where it is drawn (Follow resolved).
    public var shownSelectedLayer: GraphicsLayer? {
        guard let l = selectedLayer else { return nil }
        return l.follow == nil ? l : shownDocument?.layer(l.id)
    }

    /// The layers the monitor outlines at the playhead, where they are drawn: visible and inside their range (item
    /// lanes), the same gate as render and hit test.
    public var outlinedLayers: [GraphicsLayer] {
        let t = localTime
        return shownDocument?.layers.filter { $0.isVisible && $0.isShown(atLocal: t) } ?? []
    }

    /// The single selected layer when the monitor gives it handles and the move cursor: it is drawn at the playhead
    /// (inside its range). An item out of its range stays selected (lane, panel) but has nothing on the picture.
    public var handledLayer: GraphicsLayer? {
        guard let l = shownSelectedLayer, l.isShown(atLocal: localTime) else { return nil }
        return l
    }

    /// The single selected layer's Follow (nil = follows nothing).
    public var follow: GraphicsFollow? { selectedLayer?.follow }

    /// Layers the selected layer may follow (no cycle), front first.
    public var followCandidates: [GraphicsLayer] {
        guard let l = selectedLayer else { return [] }
        return document?.followCandidates(for: l.id) ?? []
    }

    /// Default edges and padding for a new Follow: every edge, 24 px (a box around a title).
    public static let defaultFollowPadding = 24.0

    /// Sets what the selected layer follows (nil = nothing). A new Follow takes every edge and the default padding; a change
    /// of target keeps the edges and padding. A target that would close a cycle is refused.
    public func setFollowTarget(_ target: GraphicsFollow.Target?) {
        guard let l = selectedLayer, !l.isLocked else { return }
        if case .layer(let id)? = target, !followCandidates.contains(where: { $0.id == id }) { return }
        let next: GraphicsFollow? = target.map { t in
            var f = l.follow ?? GraphicsFollow(target: t, padding: Self.defaultFollowPadding)
            f.target = t
            return f
        }
        guard next != l.follow else { return }
        edit(next == nil ? "Stop Following" : "Follow") { $0.update(l.id) { $0.follow = next } }
    }

    /// Switches one edge of the selected layer's Follow on or off.
    public func toggleFollowEdge(_ edge: GraphicsEdges) {
        guard let l = selectedLayer, !l.isLocked, var f = l.follow else { return }
        if f.edges.contains(edge) { f.edges.remove(edge) } else { f.edges.insert(edge) }
        edit("Follow Edges") { $0.update(l.id) { $0.follow = f } }
    }

    /// Padding of the selected layer's Follow (a drag is one undo step).
    public func setFollowPadding(_ v: Double) {
        guard let l = selectedLayer, !l.isLocked, var f = l.follow, f.padding != v || f.edgePadding != nil else { return }
        f.padding = v
        f.edgePadding = nil   // the one value sets every edge
        edit("Follow Padding", merge: "props:followPadding:\(l.id)") { $0.update(l.id) { $0.follow = f } }
    }

    /// One edge's padding of the selected layer's Follow (v85; a drag is one undo step). Four equal values collapse again.
    public func setFollowPadding(_ v: Double, for edge: GraphicsEdges) {
        guard let l = selectedLayer, !l.isLocked, var f = l.follow else { return }
        let before = f
        f.setPadding(v, for: edge)
        guard f != before else { return }
        edit("Follow Padding", merge: "props:followPadding:\(l.id)") { $0.update(l.id) { $0.follow = f } }
    }

    /// "Follows" popup title of a target.
    public func followTitle(_ t: GraphicsFollow.Target?) -> String {
        switch t {
        case nil: "None"
        case .frame?: "Frame"
        case .layer(let id)?: document?.layer(id)?.name ?? "None"
        }
    }
}

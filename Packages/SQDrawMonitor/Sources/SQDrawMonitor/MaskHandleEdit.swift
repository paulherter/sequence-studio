import Foundation
import SQCore

/// One pen-handle edit of a mask from the Program monitor overlay (frame fractions). Shared by the Mac
/// `TransformOverlayView` and the canvas `TransformOverlay`; the host applies it through Effect Controls
/// (`moveMaskTangent`, `moveMask`, `insertMaskVertex`, `placeMaskVertex`, `removeMaskVertex`, `toggleMaskVertexSmooth`).
public enum MaskHandleEdit: Sendable, Equatable {
    /// A Bezier handle of `vertex` dragged to `offset` from its vertex (`independent`: Option / Alt breaks the pair).
    case tangent(ClipMask.ID, vertex: Int, out: Bool, offset: Vec2, independent: Bool)
    /// The whole mask moved by `delta` since the drag began.
    case move(ClipMask.ID, delta: Vec2)
    /// A click on the outline: a vertex at `t` along `segment`, the curve kept.
    case insert(ClipMask.ID, segment: Int, t: Double)
    /// A press on the outline then a drag: the new vertex with its handle pulled out to `handle` (relative to the vertex).
    case pen(ClipMask.ID, segment: Int, t: Double, handle: Vec2, independent: Bool)
    /// Cmd / Ctrl-click on a vertex: removed.
    case remove(ClipMask.ID, vertex: Int)
    /// Option / Alt-click on a vertex: corner <-> smooth.
    case toggleSmooth(ClipMask.ID, vertex: Int)

    public var maskID: ClipMask.ID {
        switch self {
        case .tangent(let id, _, _, _, _), .move(let id, _), .insert(let id, _, _), .pen(let id, _, _, _, _),
             .remove(let id, _), .toggleSmooth(let id, _): id
        }
    }

    /// Edits the path shown at the playhead (adding or deleting a vertex changes every key, wherever the playhead is).
    public var editsAtPlayhead: Bool {
        switch self {
        case .insert, .remove: false
        default: true
        }
    }
}

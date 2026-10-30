#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Dragging a caption in the Program monitor: the caption's own position moves by the drag, and its text block snaps to
/// the canvas center lines and the action / title safe zones (offset space: sequence px from the canvas center, y down).
public enum CaptionDrag {
    /// - Parameters:
    ///   - start: the caption's effective position when the drag began (alignment is kept, only the offset moves).
    ///   - textRect: the drawn text block at `start`.
    ///   - delta: drag distance so far (sequence px).
    ///   - threshold: snap distance (sequence px); 0 turns snapping off (Option held).
    ///   - zone: platform UI zone in offset space; the box snaps softly to its edges, nothing is forced.
    public static func moved(start: CaptionPosition, textRect: CGRect, delta: Vec2, canvas: CGSize, threshold: Double, zone: CGRect? = nil)
        -> (position: CaptionPosition, guides: SnapGuides.Result) {
        var dx = delta.x, dy = delta.y
        var guides = SnapGuides.Result.none
        if threshold > 0 {
            let targets = SnapGuides.targets(canvas: canvas, others: [], safeAreas: SafeArea.allCases, zone: zone)
            let box = textRect.offsetBy(dx: delta.x, dy: delta.y)
            guides = SnapGuides.snap(box: box, targets: targets, threshold: threshold)
            dx += guides.dx; dy += guides.dy
        }
        let w = max(Double(canvas.width), 1), h = max(Double(canvas.height), 1)
        var p = start
        p = CaptionPosition(vertical: start.vertical, horizontal: start.horizontal,
                            offsetX: start.offsetX + dx / w, offsetY: start.offsetY + dy / h)
        return (p, guides)
    }
}

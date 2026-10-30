import Foundation
import SQCore
import SQDrawKit

/// The window of the selected Color Step on the Program monitor (the Mac `StepWindowOverlayView` on the draw list): its
/// outline, a center handle, edge handles that resize, a rotate handle and the body to move it. Maths in
/// `StepWindowEditGeometry`; the host writes each change into the Step (one drag = one undo step). A press that hits no
/// handle and not the body goes on to the monitor. Window points, like `MonitorPanel`.
@MainActor
public final class StepWindowOverlay {
    public enum Phase: Sendable { case began, changed, ended }

    public var geometry = StepWindowEditGeometry(layer: ZoomEditGeometry(layer: TransformOverlayGeometry(
        sequenceSize: CGSize(width: 1920, height: 1080), viewRect: .zero, mediaAspect: 16.0 / 9, transform: .identity)))
    public var stepWindow = StepWindow()
    /// The window changed (live): the host writes it into the Step.
    public var onChange: ((Phase, StepWindow) -> Void)?
    public var isDragging: Bool { drag != nil }

    private var drag: (hit: StepWindowEditGeometry.Hit, press: CGPoint, base: StepWindow)?

    public init() {}

    public func mouseDown(_ p: CGPoint) -> Bool {
        guard let hit = geometry.hitTest(p, stepWindow) else { return false }
        drag = (hit, p, stepWindow)
        onChange?(.began, stepWindow)
        return true
    }

    public func mouseDragged(_ p: CGPoint) {
        guard let d = drag else { return }
        stepWindow = geometry.dragged(d.hit, from: d.press, to: p, base: d.base)
        onChange?(.changed, stepWindow)
    }

    public func mouseUp(_ p: CGPoint) {
        guard drag != nil else { return }
        drag = nil
        onChange?(.ended, stepWindow)
    }

    /// Esc during a drag puts the window back where the press found it.
    public func cancelDrag() -> Bool {
        guard let d = drag else { return false }
        drag = nil
        stepWindow = d.base
        onChange?(.ended, stepWindow)
        return true
    }

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        let w = stepWindow
        let pts = geometry.outline(w)
        guard pts.count >= 2 else { return }
        if w.shape == .linear {
            c.strokePolyline(pts, width: 3, t.onPictureShadow)
            c.strokePolyline(pts, width: 1.5, t.accent)
        } else {
            c.stroke(polygon: pts, width: 3, t.onPictureShadow)
            c.stroke(polygon: pts, width: 1.5, t.accent)
        }
        func dot(_ p: CGPoint, filled: Bool) {
            let h = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            c.fill(ellipseIn: h, filled ? t.accent : t.onPictureStroke)
            c.stroke(ellipseIn: h, width: 1, t.onPictureShadow)
        }
        for e in StepWindowEditGeometry.Edge.allCases { if let p = geometry.edgePoint(e, w) { dot(p, filled: true) } }
        let center = geometry.centerPoint(w), r = geometry.rotatePoint(w)
        c.strokeLine(from: center, to: r, width: 1, t.guide)
        dot(r, filled: false)
        dot(center, filled: true)
    }
}

import Foundation
import SQCore
import SQDrawKit
import SQEditorSession

/// Dynamic Zoom editor on the Program monitor (the Mac `ZoomEditOverlayView` on the draw list): the Start and End windows
/// of the clip's picture with corner handles (a corner resizes, the body moves), the "End zoom" field and Done at the
/// bottom center. Geometry is `ZoomEditGeometry`; the host writes the windows into the clip (one undo step per drag).
/// Coordinates are window points, like the rest of `MonitorPanel`.
@MainActor
public final class ZoomEditOverlay {
    public enum Phase: Sendable { case began, changed, ended }

    public var geometry = ZoomEditGeometry(layer: TransformOverlayGeometry(
        sequenceSize: CGSize(width: 1920, height: 1080), viewRect: .zero, mediaAspect: 16.0 / 9, transform: .identity))
    public var start = ZoomRect.full
    public var end = ZoomRect.centred(zoom: 1.25) { didSet { syncField() } }
    /// A window changed (live): the host writes it into the clip's stage.
    public var onChange: ((Phase, ZoomRect, ZoomRect) -> Void)?
    public var onDone: (() -> Void)?

    public private(set) var field: ScrubFieldControl
    private var drag: (hit: ZoomEditGeometry.Hit, press: CGPoint, base: (start: ZoomRect, end: ZoomRect))?
    private var fieldPressed = false
    private var donePressed = false
    public private(set) var fieldRect: CGRect = .zero
    public private(set) var doneRect: CGRect = .zero

    public static let fieldWidth: CGFloat = 150, doneWidth: CGFloat = 60, controlHeight: CGFloat = 24

    public init() {
        var f = ScrubFieldControl(value: 125)
        f.unit = "%"
        f.range = 100...10_000
        f.step = 5
        f.defaultValue = EditorSession.dynamicZoomAmount * 100
        field = f
        syncField()
    }

    public var isDragging: Bool { drag != nil || fieldPressed || donePressed }
    public var isEditingField: Bool { field.isEditing }

    private func syncField() { if !field.isDragging && !field.isEditing { field.value = (end.zoom * 100).rounded() } }

    /// Lays the field and Done out at the bottom center of `slot` (window points).
    public func layout(slot: CGRect) {
        let h = Self.controlHeight, gap = CGFloat(DrawTheme.Spacing.sm)
        let x = (slot.midX - (Self.fieldWidth + Self.doneWidth + gap) / 2).rounded()
        let y = slot.maxY - h - CGFloat(DrawTheme.Spacing.md)
        fieldRect = CGRect(x: x, y: y, width: Self.fieldWidth, height: h)
        doneRect = CGRect(x: x + Self.fieldWidth + gap, y: y, width: Self.doneWidth, height: h)
    }

    // MARK: Events (window points; `scale` = pixels per point for the field)

    /// True when the press was the editor's (a window, a handle, the field or Done). A press elsewhere on the picture
    /// ends a typed field edit and goes on.
    public func mouseDown(_ p: CGPoint, clickCount: Int, scale: Float) -> Bool {
        if fieldRect.contains(p) {
            fieldPressed = true
            apply(field.mouseDown(x: Float(p.x) * scale, clickCount: clickCount))
            return true
        }
        if field.isEditing { apply(field.commitEditing()) }
        if doneRect.contains(p) { donePressed = true; return true }
        guard let hit = geometry.hitTest(p, start: start, end: end) else { return false }
        drag = (hit, p, (start, end))
        onChange?(.began, start, end)
        return true
    }

    public func mouseDragged(_ p: CGPoint, modifiers: InputModifiers, scale: Float) {
        if fieldPressed { apply(field.mouseDragged(x: Float(p.x) * scale, modifiers: modifiers, scale: scale)); return }
        guard let d = drag else { return }
        (start, end) = geometry.dragged(d.hit, from: d.press, to: p, base: d.base)
        onChange?(.changed, start, end)
    }

    public func mouseUp(_ p: CGPoint) {
        if fieldPressed { fieldPressed = false; apply(field.mouseUp()); return }
        if donePressed { donePressed = false; if doneRect.contains(p) { onDone?() }; return }
        guard drag != nil else { return }
        drag = nil
        onChange?(.ended, start, end)
    }

    /// Typing in the field (Enter commits, Esc cancels); Esc with nothing open closes the editor. False: not the editor's.
    public func key(_ k: InputKey, modifiers: InputModifiers, now: Double) -> Bool {
        if field.isEditing || field.isDragging { apply(field.key(k, modifiers: modifiers, now: now)); return true }
        if k == .escape {
            if let d = drag { drag = nil; (start, end) = d.base; onChange?(.ended, start, end); return true }
            onDone?()
            return true
        }
        return false
    }

    private func apply(_ events: [ScrubFieldControl.Event]) {
        for e in events {
            switch e {
            case .begin: onChange?(.began, start, end)
            case .live(let v), .change(let v): end = end.withZoom(v / 100); onChange?(.changed, start, end)
            case .end(let v), .cancel(let v): end = end.withZoom(v / 100); onChange?(.ended, start, end)
            }
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        for (which, r) in [(ZoomEditGeometry.Which.start, start), (.end, end)] {
            let q = geometry.quad(of: r)
            let color = which == .end ? t.accent : t.onPictureStroke
            c.stroke(polygon: q, width: 3, t.onPictureShadow)
            if which == .start { c.strokeDashed(q, closed: true, width: 1.5, on: 5, off: 4, color) }
            else { c.stroke(polygon: q, width: 1.5, color) }
            for p in q {
                let h = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                c.fill(ellipseIn: h, color)
                c.stroke(ellipseIn: h, width: 1, t.onPictureShadow)
            }
            let label = (which == .start ? "Start " : "End ") + "\(Int((r.zoom * 100).rounded())) %"
            c.draw(label, at: CGPoint(x: q[0].x + 6, y: q[0].y + 4), fontSize: CGFloat(DrawTheme.TypeSize.caption), color)
        }
        // The move from the Start window to the End window.
        c.strokeLine(from: geometry.centre(of: start), to: geometry.centre(of: end), width: 1, t.guide)
        c.fill(roundedRect: fieldRect.insetBy(dx: -2, dy: -2), radius: CGFloat(DrawTheme.Radius.control), t.viewerHUD)
        c.draw("End zoom", in: CGRect(x: fieldRect.minX, y: fieldRect.minY, width: 64, height: fieldRect.height),
               fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2, inset: 6)
        field.draw(&c, in: CGRect(x: fieldRect.minX + 64, y: fieldRect.minY, width: fieldRect.width - 64, height: fieldRect.height),
                   theme: t, focused: field.isEditing)
        InspectorDraw.button(&c, title: "Done", in: doneRect, hovering: false, pressed: donePressed, enabled: true, accent: true, t)
    }
}

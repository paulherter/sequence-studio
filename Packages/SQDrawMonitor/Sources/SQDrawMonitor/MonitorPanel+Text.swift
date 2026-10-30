import Foundation
import SQCore
import SQDrawKit

/// The Program monitor's Type tool and text double-click (the Mac ProgramSurfaceView `typeTool` press and
/// `mouseDown(clickCount: 2)`): a click places point text, a drag out of more than 4 pt draws an area text box, a
/// double-click on the picture asks the host to edit the text under it. The host owns the text model.
extension MonitorPanel {
    static let typeDragThreshold: CGFloat = 4
    static let doubleClickInterval: Double = 0.4

    /// A press on the picture: the Type tool takes it (Program only), else the second press of a double-click edits the
    /// text under the pointer. False lets the press go on to the transform box and the pick.
    func beginTextPress(at p: CGPoint) -> Bool {
        guard model.mode == .program else { return false }
        if typeToolOn(), onTypeClick != nil || onTypeBox != nil {
            lastPress = nil
            typePress = (p, p)
            return true
        }
        let now = clock()
        if let last = lastPress, now - last.time <= Self.doubleClickInterval,
           hypot(p.x - last.p.x, p.y - last.p.y) <= Self.typeDragThreshold,
           let hook = onTextDoubleClick, let pos = sequencePosition(p) {
            lastPress = nil
            hook(pos)
            return true
        }
        lastPress = (now, p)
        return false
    }

    /// The Type tool press ended: a drag drew a box (center and size in sequence px), a click places point text.
    func endTypePress(at p: CGPoint) {
        guard let press = typePress else { return }
        typePress = nil
        guard let a = sequencePosition(press.start) else { return }
        if hypot(p.x - press.start.x, p.y - press.start.y) > Self.typeDragThreshold, let b = sequencePosition(p) {
            let size = Vec2(abs(b.x - a.x), abs(b.y - a.y))
            if size.x >= 1, size.y >= 1, let box = onTypeBox {
                box(Vec2((a.x + b.x) / 2, (a.y + b.y) / 2), size)
                return
            }
        }
        onTypeClick?(a)
    }

    /// The box being dragged out, in view points (nil while no Type tool press is under way or it is still a click).
    var typeDragRect: CGRect? {
        guard let press = typePress,
              hypot(press.now.x - press.start.x, press.now.y - press.start.y) > Self.typeDragThreshold else { return nil }
        return CGRect(x: min(press.start.x, press.now.x), y: min(press.start.y, press.now.y),
                      width: abs(press.now.x - press.start.x), height: abs(press.now.y - press.start.y))
            .intersection(canvasRect)
    }

    func drawTextTools(_ c: inout Canvas) {
        if let r = typeDragRect, !r.isNull {
            c.strokeDashed(roundedRect: r, radius: 0, width: 1, on: 4, off: 3, theme.accent)
        }
        textField.draw(&c, canvasRect: canvasRect, theme: theme)
    }

    /// Sequence px from the canvas center for a view point (clamped onto the canvas, as the pick does).
    private func sequencePosition(_ p: CGPoint) -> Vec2? {
        mapping.clickPosition(CGPoint(x: p.x - slot.minX, y: p.y - slot.minY))
    }
}

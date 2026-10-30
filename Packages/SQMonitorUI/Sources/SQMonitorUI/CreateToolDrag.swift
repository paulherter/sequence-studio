import AppKit
import SQCore
import SQDrawMonitor

/// The shared drag (SQDrawMonitor `CreateToolDrag`) fed from AppKit events: Shift constrains, Option grows from the
/// press point.
extension CreateToolDrag {
    mutating func move(to p: CGPoint, flags: NSEvent.ModifierFlags) {
        move(to: p, constrain: flags.contains(.shift), fromCenter: flags.contains(.option))
    }
}

/// The outline of the item a Create tool drag is making, with its size beside it. Drawn only.
final class CreateToolPreviewView: NSView {
    var outline: CreateToolDrag.Outline? { didSet { needsDisplay = true } }
    var label: String? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func pt(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }

    override func draw(_ dirtyRect: NSRect) {
        guard let outline else { return }
        let path = NSBezierPath()
        var box: CGRect
        switch outline {
        case .box(let r, let ellipse):
            box = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
            if ellipse { path.appendOval(in: box) } else { path.appendRect(box) }
        case .line(let a, let b):
            path.move(to: pt(a)); path.line(to: pt(b))
            box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .stroke(let pts):
            guard let first = pts.first else { return }
            path.move(to: pt(first))
            for p in pts.dropFirst() { path.line(to: pt(p)) }
            box = path.bounds
        }
        path.lineJoinStyle = .round; path.lineCapStyle = .round
        path.lineWidth = 3
        Theme.OnPicture.shadow.setStroke(); path.stroke()
        path.lineWidth = 1.5
        Theme.OnPicture.stroke.setStroke(); path.stroke()
        guard let label, !label.isEmpty else { return }
        let text = NSAttributedString(string: label, attributes: [
            .font: Theme.Typography.ns(Theme.Typography.captionSize, .medium), .foregroundColor: Theme.OnPicture.stroke,
        ])
        let size = text.size()
        let pad = Theme.Spacing.xs
        var pill = CGRect(x: box.midX - size.width / 2 - pad, y: box.maxY + Theme.Spacing.sm,
                          width: size.width + 2 * pad, height: size.height + pad)
        pill.origin.x = min(max(pill.minX, 0), max(bounds.width - pill.width, 0))
        pill.origin.y = min(pill.minY, max(bounds.height - pill.height, 0))
        Theme.OnPicture.hudFill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        text.draw(at: CGPoint(x: pill.minX + pad, y: pill.minY + pad / 2))
    }
}

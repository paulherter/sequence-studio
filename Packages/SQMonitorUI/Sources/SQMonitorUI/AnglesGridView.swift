import AppKit
import SQUIKit

/// Source monitor viewer for an Angles clip: every angle's frame at the playhead side by side. A click on a tile gives
/// the piece under the playhead that angle (the same edit as the number key). The host sets `model.angleTiles`.
@MainActor
public final class AnglesGridView: NSView {
    private let model: MonitorPanelModel
    private var hover: Int?
    private var area: NSTrackingArea?
    var aspect: CGFloat = 16.0 / 9.0

    public init(model: MonitorPanelModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityLabel("Angles")
        setAccessibilityRole(.group)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cells: [CGRect] {
        AnglesGridLayout.cells(count: model.angleTiles?.count ?? 0, in: bounds.insetBy(dx: Theme.Spacing.sm, dy: Theme.Spacing.sm),
                               aspect: aspect, gap: Theme.Spacing.sm)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(a); area = a
    }

    public override func mouseMoved(with event: NSEvent) {
        let i = AnglesGridLayout.index(at: convert(event.locationInWindow, from: nil), cells: cells)
        if i != hover { hover = i; needsDisplay = true }
    }
    public override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    public override func mouseDown(with event: NSEvent) {
        guard let i = AnglesGridLayout.index(at: convert(event.locationInWindow, from: nil), cells: cells) else { return }
        model.onPickAngle?(i)
    }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.monitorBackdrop.setFill()
        bounds.fill()
        guard let tiles = model.angleTiles else { return }
        for (i, r) in cells.enumerated() where i < tiles.count {
            let t = tiles[i]
            Theme.Colors.lane.setFill()
            r.fill()
            if let image = t.image.map({ $0 as! CGImage }), let cg = NSGraphicsContext.current?.cgContext {
                cg.saveGState()
                cg.translateBy(x: r.minX, y: r.maxY)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
                cg.restoreGState()
            }
            let label = "\(i + 1)  \(t.name)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label]
            label.draw(at: NSPoint(x: r.minX + Theme.Spacing.sm, y: r.minY + Theme.Spacing.xs), withAttributes: attrs)
            if t.isActive || hover == i {
                (t.isActive ? Theme.Colors.accent : Theme.Colors.label3).setStroke()
                let border = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
                border.lineWidth = t.isActive ? 2 : 1
                border.stroke()
            }
        }
    }
}

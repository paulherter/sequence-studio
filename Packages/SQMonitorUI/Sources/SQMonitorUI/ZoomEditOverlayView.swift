import AppKit
import SQCore

/// Dynamic Zoom editor over the Program monitor: the Start and End windows of the clip's picture as two rectangles with
/// corner handles (drag a corner to resize, the body to move), like Premiere's motion handles, plus a Zoom field for the
/// End window and a Done button. Pure drawing and event routing; maths is in `ZoomEditGeometry`. One drag = one undo step.
@MainActor
public final class ZoomEditOverlayView: NSView {
    public enum Phase: Sendable { case began, changed, ended }

    public var layerGeometry = ZoomEditGeometry(layer: TransformOverlayGeometry(
        sequenceSize: CGSize(width: 1920, height: 1080), viewRect: .zero, mediaAspect: 16.0 / 9, transform: .identity)) {
        didSet { needsDisplay = true }
    }
    public var start = ZoomRect.full { didSet { syncField(); needsDisplay = true } }
    public var end = ZoomRect.centred(zoom: 1.25) { didSet { syncField(); needsDisplay = true } }
    /// A window changed (live): the host writes it into the clip's stage.
    public var onChange: ((Phase, ZoomRect, ZoomRect) -> Void)?
    public var onDone: (() -> Void)?

    private let zoomField = ScrubField()
    private let doneButton = SQButton(title: "Done", target: nil, action: nil, style: .accent)
    private var drag: (hit: ZoomEditGeometry.Hit, press: CGPoint, base: (start: ZoomRect, end: ZoomRect))?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override init(frame: NSRect) { super.init(frame: frame); setup() }
    public required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        clipsToBounds = true
        zoomField.prefix = "End zoom"
        zoomField.unit = "%"
        zoomField.range = 100...10_000
        zoomField.step = 5
        zoomField.defaultValue = EditorSession.dynamicZoomAmount * 100
        zoomField.sqToolTip = "Zoom of the End window; the corner handles set it by dragging."
        zoomField.onBegin = { [weak self] in self?.onChange?(.began, self?.start ?? .full, self?.end ?? .full) }
        zoomField.onChange = { [weak self] v in self?.applyZoom(v, .changed) }
        zoomField.onEnd = { [weak self] v in self?.applyZoom(v, .ended) }
        doneButton.target = self
        doneButton.action = #selector(done)
        addSubview(zoomField)
        addSubview(doneButton)
        syncField()
    }

    @objc private func done() { onDone?() }

    private func applyZoom(_ percent: Double, _ phase: Phase) {
        end = end.withZoom(percent / 100)
        onChange?(phase, start, end)
    }

    private func syncField() { if !zoomField.isDragging && !zoomField.isEditing { zoomField.value = (end.zoom * 100).rounded() } }

    public override func layout() {
        super.layout()
        let h = Theme.Row.controlLarge, zw: CGFloat = 150, bw: CGFloat = 60, gap = Theme.Spacing.sm
        let x = (bounds.width - zw - bw - gap) / 2, y = bounds.height - h - Theme.Spacing.md
        zoomField.frame = CGRect(x: x, y: y, width: zw, height: h)
        doneButton.frame = CGRect(x: x + zw + gap, y: y, width: bw, height: h)
    }

    // MARK: Events

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = layerGeometry.hitTest(p, start: start, end: end) else { return }
        drag = (hit, p, (start, end))
        onChange?(.began, start, end)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let d = drag else { return }
        let w = layerGeometry.dragged(d.hit, from: d.press, to: convert(event.locationInWindow, from: nil), base: d.base)
        (start, end) = w
        onChange?(.changed, w.start, w.end)
    }

    public override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        onChange?(.ended, start, end)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        for (which, r) in [(ZoomEditGeometry.Which.start, start), (.end, end)] {
            let q = layerGeometry.quad(of: r)
            let path = NSBezierPath()
            path.move(to: q[0]); q.dropFirst().forEach { path.line(to: $0) }; path.close()
            let colour = which == .end ? Theme.Colors.accent : Theme.OnPicture.stroke
            Theme.OnPicture.shadow.setStroke(); path.lineWidth = 3; path.stroke()
            colour.setStroke(); path.lineWidth = 1.5
            if which == .start { path.setLineDash([5, 4], count: 2, phase: 0) }
            path.stroke()
            for c in q {
                let h = NSBezierPath(ovalIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
                colour.setFill(); h.fill(); Theme.OnPicture.shadow.setStroke(); h.lineWidth = 1; h.stroke()
            }
            let label = (which == .start ? "Start " : "End ") + "\(Int((r.zoom * 100).rounded())) %"
            (label as NSString).draw(at: CGPoint(x: q[0].x + 6, y: q[0].y + 4), withAttributes: [
                .font: Theme.Typography.captionStrong, .foregroundColor: colour,
            ])
        }
        // The move from the Start window to the End window.
        let line = NSBezierPath()
        line.move(to: layerGeometry.centre(of: start)); line.line(to: layerGeometry.centre(of: end))
        Theme.OnPicture.guide.setStroke(); line.lineWidth = 1; line.stroke()
    }
}

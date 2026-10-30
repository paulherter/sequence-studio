import AppKit

extension ClipDrawing {
    /// Color page: a 2 pt yellow outline just inside the clip, for the clips the Color panel grades.
    @MainActor static func drawGradeOutline(rect: CGRect) {
        guard rect.width >= 4 else { return }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        path.lineWidth = 2
        Theme.Colors.yellow.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}

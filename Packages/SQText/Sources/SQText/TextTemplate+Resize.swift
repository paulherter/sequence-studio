import Foundation
import SQCore

public extension TextTemplate {
    /// Smallest and largest font size a handle drag may produce (sequence px).
    static let resizeSizeRange: ClosedRange<Double> = 1...2000

    /// This text with every size-bound value multiplied by `factor`: font size, second line size, tracking, line
    /// spacing and the area box. Dragging a text frame's handles resizes the font this way and leaves the clip's
    /// Scale alone. Sizes are sequence-frame px.
    func resized(by factor: Double) -> TextTemplate {
        guard factor.isFinite, factor > 0 else { return self }
        var t = self
        func clamp(_ v: Double) -> Double { min(max(v, Self.resizeSizeRange.lowerBound), Self.resizeSizeRange.upperBound) }
        t.style.size = clamp(style.size * factor)
        let applied = t.style.size / max(style.size, 1e-9)   // after clamping, the rest follows the size actually reached
        t.style.tracking = style.tracking * applied
        t.style.lineSpacing = style.lineSpacing * applied
        if var second = t.style.secondLine { second.size = clamp(second.size * applied); t.style.secondLine = second }
        if let own = t.style.lineStyles { t.style.lineStyles = own.map { var l = $0; l.size = clamp(l.size * applied); return l } }
        if let b = box { t.box = TextBox(width: b.width * applied, height: b.height * applied) }
        return t
    }

    /// Font size factor for a scale-handle drag from Scale `start` to `now`: the geometric mean of the two axis ratios
    /// (edge handles stretch one axis). 1 for a degenerate start.
    static func resizeFactor(from start: Vec2, to now: Vec2) -> Double {
        guard abs(start.x) > 1e-9, abs(start.y) > 1e-9 else { return 1 }
        let f = abs((now.x / start.x) * (now.y / start.y)).squareRoot()
        return f.isFinite && f > 0 ? f : 1
    }
}

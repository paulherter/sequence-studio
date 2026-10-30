import Foundation

/// `fit`: aspect-fitted. `percent(p)`: p/100 drawable px per texture px, centered. `view`: free zoom and pan,
/// `scale` = drawable px per texture px, `centerX/Y` = the texture offset (from its center) shown at the drawable center.
/// Portable so the Windows monitor places its picture with the same math as the Mac presenter.
public enum ViewerZoom: Sendable, Hashable {
    case fit, percent(Int), view(scale: Double, centerX: Double, centerY: Double)

    public var isFit: Bool { if case .fit = self { true } else { false } }

    /// Destination rectangle in drawable pixels (origin top-left). Fit scales to the drawable (up or down)
    /// preserving aspect; `.percent(p)` is p/100 drawable px per texture px. Centered, origin snapped to whole pixels.
    public func destinationRect(textureSize: CGSize, drawableSize: CGSize) -> CGRect {
        guard textureSize.width > 0, textureSize.height > 0, drawableSize.width > 0, drawableSize.height > 0 else { return .zero }
        let scale: CGFloat
        var cx: CGFloat = 0, cy: CGFloat = 0
        switch self {
        case .fit: scale = min(drawableSize.width / textureSize.width, drawableSize.height / textureSize.height)
        case .percent(let p): scale = CGFloat(max(p, 1)) / 100
        case .view(let s, let x, let y): scale = CGFloat(max(s, 0.001)); cx = CGFloat(x); cy = CGFloat(y)
        }
        let w = textureSize.width * scale, h = textureSize.height * scale
        let x = ((drawableSize.width - w) / 2 - cx * scale).rounded(), y = ((drawableSize.height - h) / 2 - cy * scale).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

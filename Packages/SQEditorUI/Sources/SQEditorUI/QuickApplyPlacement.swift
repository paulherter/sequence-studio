import Foundation

/// Where the palette sits: the user's dragged spot (top-left corner, screen coordinates) or the default spot, always clamped
/// so the whole card stays on a visible screen. Pure, so it is testable without a window.
public enum QuickApplyPlacement {
    public static let originKey = "sq.quickApply.origin"

    /// Reads the remembered top-left corner (nil when never moved).
    public static func load(_ defaults: UserDefaults = .standard) -> CGPoint? {
        guard let a = defaults.array(forKey: originKey) as? [Double], a.count == 2 else { return nil }
        return CGPoint(x: a[0], y: a[1])
    }

    public static func save(_ topLeft: CGPoint, _ defaults: UserDefaults = .standard) {
        defaults.set([Double(topLeft.x), Double(topLeft.y)], forKey: originKey)
    }

    public static func reset(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: originKey) }

    /// The default top-left: horizontally centered in `frame`, 28% below its top.
    public static func defaultTopLeft(in frame: CGRect, width: CGFloat) -> CGPoint {
        CGPoint(x: frame.midX - width / 2, y: frame.maxY - frame.height * 0.28)
    }

    /// Moves `topLeft` so a card of `size` lies inside the visible frame it overlaps most (the first one when none overlap).
    /// A card larger than the screen is pinned to its top-left corner.
    public static func clamp(topLeft: CGPoint, size: CGSize, screens: [CGRect]) -> CGPoint {
        guard !screens.isEmpty else { return topLeft }
        let card = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        var best = screens[0]
        var bestArea: CGFloat = -1
        for s in screens {
            let i = s.intersection(card)
            let area = i.isNull ? 0 : i.width * i.height
            if area > bestArea { best = s; bestArea = area }
        }
        let x = max(best.minX, min(topLeft.x, best.maxX - size.width))
        let y = min(best.maxY, max(topLeft.y, best.minY + size.height))
        return CGPoint(x: size.width > best.width ? best.minX : x, y: size.height > best.height ? best.maxY : y)
    }
}

import Foundation

/// One angle in the multi-angle view: its name, the frame it shows now (nil while loading) and whether it is the one that plays.
public struct AngleTile: @unchecked Sendable, Equatable {
    public static func == (a: AngleTile, b: AngleTile) -> Bool {
        a.name == b.name && a.isActive == b.isActive && a.image === b.image && a.picture == b.picture
    }

    /// The frame as a draw-list image (canvas monitor): image slot and its source rect (u0, v0, u1, v1) in that slot.
    public struct Picture: Sendable, Equatable {
        public var slot: Int
        public var u0: Float, v0: Float, u1: Float, v1: Float
        public init(slot: Int, u0: Float = 0, v0: Float = 0, u1: Float = 1, v1: Float = 1) {
            self.slot = slot; self.u0 = u0; self.v0 = v0; self.u1 = u1; self.v1 = v1
        }
    }

    public var name: String
    /// The frame (a `CGImage` on the Mac); nil while loading.
    public var image: AnyObject?
    /// The frame on the canvas monitor (Windows); nil while loading or on the Mac.
    public var picture: Picture?
    public var isActive: Bool

    public init(name: String, image: AnyObject? = nil, picture: Picture? = nil, isActive: Bool = false) {
        self.name = name; self.image = image; self.picture = picture; self.isActive = isActive
    }
}

/// Where the tiles of the multi-angle view lie: as many columns as give the largest pictures of `aspect` (width / height).
public enum AnglesGridLayout {
    public static func cells(count: Int, in bounds: CGRect, aspect: CGFloat, gap: CGFloat) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0, aspect > 0 else { return [] }
        var best: (columns: Int, width: CGFloat) = (1, 0)
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let w = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let h = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let fit = max(0, min(w, h * aspect))
            if fit > best.width { best = (columns, fit) }
        }
        let rows = (count + best.columns - 1) / best.columns
        let w = best.width, h = w / aspect
        let usedW = w * CGFloat(best.columns) + gap * CGFloat(best.columns - 1)
        let usedH = h * CGFloat(rows) + gap * CGFloat(rows - 1)
        let origin = CGPoint(x: bounds.minX + (bounds.width - usedW) / 2, y: bounds.minY + (bounds.height - usedH) / 2)
        return (0..<count).map { i in
            let r = i / best.columns, c = i % best.columns
            // The last row is centered when it is not full.
            let inRow = r == rows - 1 ? count - r * best.columns : best.columns
            let shift = CGFloat(best.columns - inRow) * (w + gap) / 2
            return CGRect(x: origin.x + shift + CGFloat(c) * (w + gap), y: origin.y + CGFloat(r) * (h + gap), width: w, height: h)
        }
    }

    /// The tile under `point`, if any.
    public static func index(at point: CGPoint, cells: [CGRect]) -> Int? { cells.firstIndex { $0.contains(point) } }
}

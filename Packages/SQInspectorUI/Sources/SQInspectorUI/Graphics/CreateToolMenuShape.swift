import SQCore

extension GraphicsEditor {
    /// The drag Sequence > New Shape stands for: a box one third of the picture height, centered; lines run
    /// horizontally. The menu item takes the Create tool's path, so it is only a command alias of it.
    public static func menuShapeDrag(_ kind: ShapeKind, canvas: Vec2) -> (from: Vec2, to: Vec2) {
        let half = canvas.y / 6
        if kind == .line || kind == .arrow { return (Vec2(-half, 0), Vec2(half, 0)) }
        return (Vec2(-half, -half), Vec2(half, half))
    }
}

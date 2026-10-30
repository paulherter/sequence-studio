import AppKit
import SQCore

/// What a Magic click on the Program monitor does: add the area under the pointer to the pick, or remove it. Chosen on the
/// monitor's Add | Remove switch; holding Option flips it for as long as it is held.
public enum MagicClickMode: Int, Sendable, Equatable {
    case add, remove

    /// The mode a click uses with Option held or not.
    public func effective(option: Bool) -> MagicClickMode { option ? (self == .add ? .remove : .add) : self }
    public var subtracts: Bool { self == .remove }
}

/// A click point of the active Magic mask on the shown frame (frame fraction), drawn as a small + / − dot.
public struct MagicMarker: Sendable, Equatable {
    public var position: Vec2
    public var subtract: Bool
    public init(position: Vec2, subtract: Bool) { self.position = position; self.subtract = subtract }

    /// The points of `selection` made on the frame at `sourceTime` (pick points on the pick's frame, corrections on
    /// theirs: a correction is stored at the decoded frame's time, at or up to one frame before the playhead's).
    public static func markers(_ selection: MagicSelection?, sourceTime: Time, frameDuration: Time) -> [MagicMarker] {
        guard let selection else { return [] }
        func sec(_ t: Time) -> Double { Double(t.value) / Double(max(t.timescale, 1)) }
        let frame = sec(frameDuration)
        return selection.points.filter { let d = sec(sourceTime) - sec($0.sourceTime); return d > -1e-4 && d < frame - 1e-4 }
            .map { MagicMarker(position: $0.position, subtract: $0.subtract) }
    }

    /// Dot radius (view points).
    static let radius: CGFloat = 5

    func draw(at c: CGPoint) {
        let r = Self.radius
        let dot = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        (subtract ? Theme.OnPicture.magicRemove : Theme.OnPicture.magicAdd).setFill(); dot.fill()
        Theme.OnPicture.shadow.setStroke(); dot.lineWidth = 1; dot.stroke()
        let sign = NSBezierPath()
        sign.move(to: CGPoint(x: c.x - 2.5, y: c.y)); sign.line(to: CGPoint(x: c.x + 2.5, y: c.y))
        if !subtract { sign.move(to: CGPoint(x: c.x, y: c.y - 2.5)); sign.line(to: CGPoint(x: c.x, y: c.y + 2.5)) }
        Theme.OnPicture.stroke.setStroke(); sign.lineWidth = 1.5; sign.stroke()
    }
}

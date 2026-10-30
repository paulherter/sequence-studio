import Foundation

/// Where project items dropped on the Program monitor go: the left half inserts at the playhead (later clips move
/// right), the right half overwrites. Pure so the split is testable; the panel shows the zone under the pointer.
public enum MonitorDropZone: Sendable, Equatable, CaseIterable {
    case insert, overwrite

    /// The zone at horizontal position `x` of a panel `width` wide.
    public static func zone(atX x: CGFloat, width: CGFloat) -> MonitorDropZone {
        guard width > 0 else { return .overwrite }
        return x < width / 2 ? .insert : .overwrite
    }

    public var title: String { self == .insert ? "Insert" : "Overwrite" }

    /// The half of a panel of `size` this zone covers (origin at the left).
    public func rect(in size: CGSize) -> CGRect {
        let half = size.width / 2
        return CGRect(x: self == .insert ? 0 : half, y: 0, width: half, height: size.height)
    }
}

import Foundation
/// Color page compare (Before | After | Split): the monitor shows the target clips without their grade, either whole
/// (`before`) or on the left half of the picture (`split`, graded on the right). A viewing aid only: never stored in
/// the project and never applied by the export.
public struct ColorBypass: Sendable, Hashable {
    public enum Mode: Sendable, Hashable { case before, split }

    /// Clips (or adjustment layers / the sequence grade layer) shown ungraded.
    public var clips: Set<Clip.ID>
    public var mode: Mode

    public init(clips: Set<Clip.ID>, mode: Mode) { self.clips = clips; self.mode = mode }

    public var isEmpty: Bool { clips.isEmpty }
    public var isSplit: Bool { mode == .split }
    public func bypasses(_ clip: Clip.ID) -> Bool { clips.contains(clip) }

    /// Width in pixels of the ungraded (left) part of a split picture `width` pixels wide.
    public static func splitWidth(_ width: Int) -> Int { max(width, 0) / 2 }

    /// Resolver slot of a clip's ungraded pipeline (distinct from the clip's own slot, so both stay cached side by side).
    /// The Mac RenderLoop and the Windows engine resolve the Before picture under it.
    public static func ungradedOwner(_ clip: UUID) -> UUID {
        var u = clip.uuid
        u.0 ^= 0x5A; u.15 ^= 0xA5
        return UUID(uuid: u)
    }

    /// The color a bypassed layer is drawn with and the resolver slot to resolve it under; nil when `request` keeps its grade.
    public func ungraded(_ request: LayerRequest) -> (color: ClipColor, owner: UUID)? {
        guard bypasses(request.clip) else { return nil }
        return (request.color.ungraded, Self.ungradedOwner(request.clip))
    }
}

extension ClipColor {
    /// The same footage without a grade: the source interpretation (color space override, embedded camera LUT switch)
    /// stays, so log footage is still converted to the display; every Color effect returns to the default one.
    public var ungraded: ClipColor { ClipColor(source: source, useEmbeddedLUT: useEmbeddedLUT) }
}

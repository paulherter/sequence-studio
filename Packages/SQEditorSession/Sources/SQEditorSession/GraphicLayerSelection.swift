import Foundation
import SQCore

/// The selected layers of one graphics clip, as the session sees them.
public struct GraphicLayerSelection: Equatable, Sendable {
    public var clip: Clip.ID
    public var layers: Set<UUID>

    public init(clip: Clip.ID, layers: Set<UUID>) { self.clip = clip; self.layers = layers }
}

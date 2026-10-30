import SQCore

public enum SpeedEditPhase: Sendable { case began, changed, ended }

/// One speed band edit for the host: the clip and its new speed track. `keepingKeys` comes from the track at mouse-down
/// (`SpeedBand.Gesture.keepsKeys`), so every change of one drag is decided the same way (see `Timeline.editSpeedKeys`).
public struct SpeedEdit: Sendable {
    public var clip: Clip.ID
    public var keys: SpeedKeys
    public var phase: SpeedEditPhase
    public var keepingKeys: Bool

    public init(clip: Clip.ID, keys: SpeedKeys, phase: SpeedEditPhase, keepingKeys: Bool = false) {
        self.clip = clip; self.keys = keys; self.phase = phase; self.keepingKeys = keepingKeys
    }
}

/// A key or a transition of a speed band (what the context menu and Delete act on).
public struct SpeedBandKeyHit: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case key(Int), ramp(Int) }
    public var hit: Kind
    public init(hit: Kind) { self.hit = hit }
    public var band: SpeedBand.Hit {
        switch hit {
        case .key(let b): return .key(b)
        case .ramp(let i): return .ramp(i)
        }
    }
    public var title: String {
        switch hit {
        case .key: return "Delete Speed Keyframe"
        case .ramp: return "Remove Speed Transition"
        }
    }
}

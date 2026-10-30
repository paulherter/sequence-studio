import Foundation
import SQCore

// MARK: - Sections

/// One section of Effect Controls. Lives here so the timeline key lane can name it without knowing Effect Controls; its
/// `properties` stay with Effect Controls (DECISIONS "SQEditorUI split").
public enum EffectSection: Hashable, Sendable {
    case motion, opacity, volume
    /// Clip speed (Speed, Reverse, Keep Pitch): the retime of the clip, edited through the session (not a stored animation).
    case speed
    /// One applied effect (an instance: a clip can have several of one kind).
    case effect(ClipEffect.ID, kind: String)
    /// W6.7: one path mask of the clip (Feather, Opacity, Expansion, Invert, Mode, Path stopwatch, delete).
    case mask(ClipMask.ID)
    /// A Custom Intro / Outro of a text clip: one keyframe row per `AnimationParam` (the keys live in the clip's
    /// `AnimationSet`, shown in clip time).
    case animation(AnimationSide)

    public static let builtIns: [EffectSection] = [.motion, .opacity, .volume, .speed]

    public var rawValue: String {
        switch self {
        case .motion: "motion"
        case .opacity: "opacity"
        case .volume: "volume"
        case .speed: "speed"
        case .effect(let id, let kind): "fx:\(id.uuidString):\(kind)"
        case .mask(let id): "mask:\(id.uuidString)"
        case .animation(let side): "anim:\(side.rawValue)"
        }
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix("mask:"), let id = UUID(uuidString: String(rawValue.dropFirst(5))) { self = .mask(id); return }
        if rawValue.hasPrefix("anim:"), let side = AnimationSide(rawValue: String(rawValue.dropFirst(5))) { self = .animation(side); return }
        switch rawValue {
        case "motion": self = .motion
        case "opacity": self = .opacity
        case "volume": self = .volume
        case "speed": self = .speed
        default:
            let parts = rawValue.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[0] == "fx", let id = UUID(uuidString: parts[1]) else { return nil }
            self = .effect(id, kind: parts[2])
        }
    }

    public var title: String {
        switch self {
        case .motion: "Transform"     // V1 Quiet display names; ids stay "motion" / "opacity"
        case .opacity: "Blend"
        case .volume: "Volume"
        case .speed: "Speed"
        case .effect(_, let kind): EffectCatalog.title(for: kind)
        case .mask: "Mask"
        case .animation(let side): "\(side.title) Animation"
        }
    }

    /// Kind of the applied effect behind this section; nil for the built-in clip properties (always present).
    public var effectKind: String? {
        if case .effect(_, let kind) = self { return kind }
        return nil
    }

    public var effectID: ClipEffect.ID? {
        if case .effect(let id, _) = self { return id }
        return nil
    }
}

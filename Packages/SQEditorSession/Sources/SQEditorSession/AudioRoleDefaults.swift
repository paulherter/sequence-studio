import Foundation
import SQCore

/// Per-role audio editing defaults (Settings Audio page): J / L cut offset, crossfade length and the crossfade kind.
/// A role is the clip's `AudioTag`; untagged clips use the dialogue values. Pure value, `load` / `save` use UserDefaults.
public struct AudioRoleDefaults: Sendable, Equatable {
    /// J / L offset in seconds per role.
    public var splitOffsetSeconds: [AudioTag: Double]
    /// Audio transition length in seconds per role.
    public var transitionSeconds: [AudioTag: Double]
    /// Kind a default audio transition gets (the crossfade curve; the fade-handle curve is `DefaultFadeCurve`).
    public var crossfadeKind: TransitionKind

    /// Dialogue and effects: 0.25 s lead (one beat of breath); music and voice-over beds lead longer, 0.5 s.
    /// Transition lengths: dialogue short (0.1 s), effects 0.25 s, music long (1 s).
    public static let standard = AudioRoleDefaults(
        splitOffsetSeconds: [.dialogue: 0.25, .music: 0.5, .sfx: 0.25],
        transitionSeconds: [.dialogue: 0.1, .music: 1, .sfx: 0.25],
        crossfadeKind: .constantPower)

    public init(splitOffsetSeconds: [AudioTag: Double], transitionSeconds: [AudioTag: Double], crossfadeKind: TransitionKind) {
        self.splitOffsetSeconds = splitOffsetSeconds; self.transitionSeconds = transitionSeconds; self.crossfadeKind = crossfadeKind
    }

    public enum Key {
        public static func splitOffset(_ r: AudioTag) -> String { "sq.audio.splitOffsetSeconds.\(r.rawValue)" }
        public static func transition(_ r: AudioTag) -> String { "sq.audio.transitionSeconds.\(r.rawValue)" }
        public static let crossfadeKind = "sq.audio.crossfadeKind"
    }

    public func splitOffset(for role: AudioTag?, frameDuration fd: Time) -> Time {
        Self.wholeFrames(splitOffsetSeconds[role ?? .dialogue] ?? 0.25, frameDuration: fd)
    }

    /// Audio transition length for a role; nil role = `fallback` seconds (the single Settings value).
    public func transitionDuration(for role: AudioTag?, fallbackSeconds: Double, frameDuration fd: Time) -> Time {
        Self.wholeFrames(role.flatMap { transitionSeconds[$0] } ?? fallbackSeconds, frameDuration: fd)
    }

    static func wholeFrames(_ seconds: Double, frameDuration fd: Time) -> Time {
        fd * max(1, Int64((seconds * Double(fd.timescale) / Double(fd.value)).rounded()))
    }

    public static func load(from d: UserDefaults = .standard) -> AudioRoleDefaults {
        var s = standard
        for r in AudioTag.allCases {
            if d.object(forKey: Key.splitOffset(r)) != nil {
                let v = d.double(forKey: Key.splitOffset(r)); if v.isFinite, v > 0, v <= 10 { s.splitOffsetSeconds[r] = v }
            }
            if d.object(forKey: Key.transition(r)) != nil {
                let v = d.double(forKey: Key.transition(r)); if v.isFinite, v > 0, v <= 600 { s.transitionSeconds[r] = v }
            }
        }
        if let raw = d.string(forKey: Key.crossfadeKind), let k = TransitionKind(rawValue: raw), k.trackKind == .audio { s.crossfadeKind = k }
        return s
    }

    public func save(to d: UserDefaults = .standard) {
        for r in AudioTag.allCases {
            if let v = splitOffsetSeconds[r] { d.set(v, forKey: Key.splitOffset(r)) }
            if let v = transitionSeconds[r] { d.set(v, forKey: Key.transition(r)) }
        }
        d.set(crossfadeKind.rawValue, forKey: Key.crossfadeKind)
    }
}

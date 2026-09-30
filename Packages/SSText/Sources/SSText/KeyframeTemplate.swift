import Foundation
import SSCore

/// Reduced rational in 0...1: a keyframe position normalized to the animation's duration.
public struct Fraction: Sendable, Hashable, Codable, Comparable {
    public let numerator: Int64
    public let denominator: Int64
    public init(_ n: Int64, _ d: Int64) {
        guard d > 0 else { self.numerator = 0; self.denominator = 1; return }
        if n <= 0 { self.numerator = 0; self.denominator = 1; return }
        if n >= d { self.numerator = 1; self.denominator = 1; return }
        var a = n, b = d
        while b != 0 { (a, b) = (b, a % b) }
        self.numerator = n / a; self.denominator = d / a
    }
    public static let zero = Fraction(0, 1)
    public static let one = Fraction(1, 1)
    public var doubleValue: Double { Double(numerator) / Double(denominator) }
    public static func < (a: Fraction, b: Fraction) -> Bool {
        a.numerator * b.denominator < b.numerator * a.denominator
    }
}

public enum Easing: String, Sendable, Hashable, Codable {
    case linear, easeIn, easeOut, easeInOut
    /// Ease-out with overshoot past the end value (back-out).
    case overshoot
    /// Keeps the start value until the next keyframe.
    case hold

    /// Maps linear progress 0...1 to eased progress (may exceed 1 for `overshoot`).
    public func apply(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        switch self {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: let u = 1 - t; return 1 - u * u * u
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .overshoot:
            let c1 = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case .hold: return t >= 1 ? 1 : 0
        }
    }
}

/// `easing` shapes the segment from this keyframe to the next.
public struct Keyframe: Sendable, Hashable, Codable {
    public var time: Fraction
    public var value: Double
    public var easing: Easing
    public init(time: Fraction, value: Double, easing: Easing = .linear) {
        self.time = time; self.value = value; self.easing = easing
    }
}

public struct KeyframeTrack: Sendable, Hashable, Codable {
    /// e.g. "scale", "opacity", "positionX", "positionY", "rotation".
    public var property: String
    public private(set) var keyframes: [Keyframe]
    public init(property: String, keyframes: [Keyframe]) {
        self.property = property
        self.keyframes = keyframes.enumerated().sorted {
            $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset
        }.map(\.element)
    }

    /// nil for an empty track; clamped to the first/last value outside the keyframe range.
    public func value(at t: Fraction) -> Double? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        if t <= first.time { return first.value }
        if t >= last.time { return last.value }
        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i], b = keyframes[i + 1]
            if t >= a.time && t <= b.time {
                let span = b.time.doubleValue - a.time.doubleValue
                let local = span > 0 ? (t.doubleValue - a.time.doubleValue) / span : 1
                return a.value + (b.value - a.value) * a.easing.apply(local)
            }
        }
        return last.value
    }
}

/// Placeholder until SSCore keyframes land: tracks over normalized time plus a default duration.
public struct KeyframeTemplate: Sendable, Hashable, Codable {
    public var tracks: [KeyframeTrack]
    /// Default playback length of the animation (rational timeline time).
    public var duration: Time
    public init(tracks: [KeyframeTrack], duration: Time) { self.tracks = tracks; self.duration = duration }
    public static let none = KeyframeTemplate(tracks: [], duration: .zero)
    public func track(for property: String) -> KeyframeTrack? { tracks.first { $0.property == property } }
}

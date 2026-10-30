import Foundation
import SQCore

/// Text for a clip's speed: "200%", "33.33%", "-100%" (reversed). Used for the badge on the timeline clip.
public enum SpeedLabel {
    /// At most two decimals, trailing zeros dropped; "-" in front when reversed.
    public static func text(speed: ClipSpeed, reversed: Bool) -> String {
        var s = String(format: "%.2f", speed.percent)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return (reversed ? "-" : "") + s + "%"
    }

    /// " [200%]" appended to the clip name; empty for a clip at 100 % that is not reversed.
    public static func nameSuffix(for clip: Clip) -> String {
        if clip.speedKeys != nil { return " [Speed Ramp]" }
        guard !clip.speed.isNormal || clip.reversed else { return "" }
        return " [" + text(speed: clip.speed, reversed: clip.reversed) + "]"
    }
}

/// Logic of the Speed/Duration dialog (Premiere's Clip > Speed/Duration, Cmd+R), without any view.
///
/// Speed and duration are two views of one number while `isLinked` is on: typing one recomputes the other (the clip's
/// source range stays, `Timeline.setSpeed`). With the link off, a typed speed keeps the clip's length and changes how
/// much media it shows (`SpeedChange.holdingDuration`). Typing a duration always changes the speed. A negative speed
/// means Reverse Speed. Several clips: the speed applies to each; the duration field is disabled.
public struct SpeedDialogModel: Equatable, Sendable {
    public let frameDuration: Time
    /// Source duration of the first clip: the duration at 100 % speed.
    public let sourceDuration: Time
    public let clipCount: Int
    public let hasAudio: Bool
    public private(set) var percent: Double
    public private(set) var duration: Time
    public var isLinked = true
    public var reversed: Bool
    public var keepsPitch: Bool
    /// Time Interpolation (video clips only; the picker is hidden for audio).
    public var timeInterpolation: TimeInterpolation
    public let hasVideo: Bool
    public var ripple = false
    private enum Edited { case none, speed, duration }
    private var edited = Edited.none
    private let originalSpeed: ClipSpeed
    private let originalDuration: Time
    private let originalReversed: Bool
    private let originalKeepsPitch: Bool
    private let originalInterpolation: TimeInterpolation

    /// `clips` = the selected retimable clips (at least one).
    public init(clips: [Clip], frameDuration: Time) {
        let first = clips[0]
        self.frameDuration = frameDuration
        sourceDuration = first.retimeSpan
        clipCount = clips.count
        hasAudio = clips.contains { $0.kind == .audio }
        hasVideo = clips.contains { $0.kind == .video }
        let avg = first.averageSpeed
        percent = avg.percent
        duration = first.duration
        reversed = first.reversed
        keepsPitch = first.keepsPitch
        timeInterpolation = first.timeInterpolation
        originalInterpolation = first.timeInterpolation
        originalDuration = first.duration
        originalSpeed = avg; originalReversed = first.reversed; originalKeepsPitch = first.keepsPitch
    }

    public var canEditDuration: Bool { clipCount == 1 }
    public static let percentRange: ClosedRange<Double> = 1...10_000

    public var speed: ClipSpeed { ClipSpeed(percent: percent) }

    /// Speed typed in the field (percent; negative = reverse).
    public mutating func setPercent(_ typed: Double) {
        guard typed.isFinite, typed != 0 else { return }
        if typed < 0 { reversed = true }
        percent = min(max(abs(typed), Self.percentRange.lowerBound), Self.percentRange.upperBound)
        edited = speed == originalSpeed ? .none : .speed       // typing the current value is no change
        if isLinked || !canEditDuration { duration = Self.frames(speed.unscale(sourceDuration), frameDuration) }
    }

    /// Duration typed in the field (any time; snapped to frames, at least one frame). The speed follows, clamped.
    public mutating func setDuration(_ typed: Time) {
        guard canEditDuration else { return }
        let d = max(typed.snapped(to: frameDuration), frameDuration)
        let s = ClipSpeed(num: sourceDuration.value * d.timescale, den: sourceDuration.timescale * d.value)
        percent = s.percent
        duration = Self.frames(s.unscale(sourceDuration), frameDuration)
        edited = duration == originalDuration ? .none : .duration
    }

    private static func frames(_ t: Time, _ fd: Time) -> Time { max(t.snapped(to: fd), fd) }

    /// True when OK would change something.
    public var hasChanges: Bool {
        edited != .none || reversed != originalReversed || keepsPitch != originalKeepsPitch || timeInterpolation != originalInterpolation
    }

    /// The edit to apply to every selected clip.
    public var change: SpeedChange {
        switch edited {
        case .duration:
            return SpeedChange(duration: duration, reversed: reversed, keepsPitch: keepsPitch, ripple: ripple, timeInterpolation: interpolationChange)
        case .speed:
            return SpeedChange(speed: speed, reversed: reversed, keepsPitch: keepsPitch, ripple: ripple,
                               holdingDuration: !isLinked && canEditDuration, timeInterpolation: interpolationChange)
        case .none:
            return SpeedChange(speed: originalSpeed, reversed: reversed, keepsPitch: keepsPitch, ripple: ripple,
                               timeInterpolation: interpolationChange)
        }
    }

    private var interpolationChange: TimeInterpolation? { timeInterpolation != originalInterpolation ? timeInterpolation : nil }
}

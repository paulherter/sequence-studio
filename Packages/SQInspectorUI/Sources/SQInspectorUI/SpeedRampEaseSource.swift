import Foundation
import SQCore

/// The curve popover's source for one speed transition of the Time Remapping band (W4.4): reads the ramp's Bezier curve
/// and writes it through the session (one undo step per handle drag, one per preset chip).
@MainActor
public final class SpeedRampEaseSource: EaseCurveSource {
    public let session: EditorSession
    public let clip: Clip.ID
    public let segment: Int
    private var inGesture = false
    private var emitted = false
    /// The transition this source was opened for, by where it sits (start and length in clip time): a key added or removed
    /// elsewhere shifts segment indices but not this ramp, so it is looked up again on every read and write. When an edit
    /// moved, resized or split it, nothing matches: the source then reads empty and writes nothing.
    private let identity: Identity?

    private struct Identity: Equatable {
        var start: Time, duration: Time
    }

    public init(session: EditorSession, clip: Clip.ID, segment: Int) {
        self.session = session; self.clip = clip; self.segment = segment
        identity = Self.keys(session: session, clip: clip).flatMap { k in
            k.segments.indices.contains(segment) && k.segments[segment].isRamp
                ? Identity(start: k.boundaries[segment], duration: k.segments[segment].duration) : nil
        }
    }

    private static func keys(session: EditorSession, clip: Clip.ID) -> SpeedKeys? {
        session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clip })?.speedKeys
    }

    /// The ramp's current segment index, nil once it is gone.
    public var currentSegment: Int? {
        guard let identity, let k = Self.keys(session: session, clip: clip) else { return nil }
        return k.segments.indices.first { k.segments[$0].isRamp && k.boundaries[$0] == identity.start
            && k.segments[$0].duration == identity.duration }
    }

    /// True while the ramp the popover was opened on still exists.
    public var isCurrent: Bool { currentSegment != nil }

    public var easeReading: EaseReading {
        guard let i = currentSegment else { return .empty }
        return session.speedRampEase(clip: clip, segment: i).map { .common($0) } ?? .empty
    }

    public func applyEaseShape(_ shape: EaseShape) {
        guard let i = currentSegment else { return }
        let changed = session.setSpeedRampEase(shape, clip: clip, segment: i, continuesGesture: inGesture && emitted)
        if inGesture && changed { emitted = true }
    }

    /// A speed transition stores no Hold (it would clear the curve) and no value outside 0...1 (`SpeedEase.normalized`).
    public var allowsHold: Bool { false }
    public var handleValueRange: ClosedRange<Double> { 0...1 }

    public func beginGesture() { inGesture = true; emitted = false }
    public func endGesture() { inGesture = false; emitted = false }

    public var sessionEasingCurves: [EasingCurve] { [] }
    public func observeEaseInputs() { _ = session.activeTimeline }
    public var emptyEaseHint: String { "Select a speed transition" }
}

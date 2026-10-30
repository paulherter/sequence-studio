import Foundation
import SQCore

/// The curve popover's source for the easing of one transition: a clip-edge transition or a transition layer. Reads the
/// stored curve and writes a hand-drawn one back through the session (one undo step per handle drag, one per preset chip).
/// Same editor and same stored `EasingCurve` as the Effect Controls graphs; render and export read it identically.
@MainActor
public final class TransitionEaseSource: EaseCurveSource {
    public enum Target: Sendable, Equatable {
        case edge(Transition.ID)
        case layer(Clip.ID)
    }

    public let session: EditorSession
    public let target: Target
    private var inGesture = false
    private var emitted = false

    public init(session: EditorSession, target: Target) { self.session = session; self.target = target }

    private var current: EasingCurve? {
        switch target {
        case .edge(let id): session.transitionInfo(id)?.transition.effectiveEasing
        case .layer(let id): session.transitionLayerInfo(id)?.transition.effectiveEasing
        }
    }

    public var easeReading: EaseReading { current.map { .common($0.shape) } ?? .empty }
    public var allowsHold: Bool { false }

    public func applyEaseShape(_ shape: EaseShape) {
        // Hold would turn the transition into a cut: ignored (and `allowsHold` keeps the chip out of the popover).
        guard let curve = EasingCurve.transitionCurve(for: shape), curve != current else { return }
        let continues = inGesture && emitted
        switch target {
        case .edge(let id): session.setTransitionStyle(id, easing: curve, continuesGesture: continues)
        case .layer(let id): _ = session.setTransitionLayerStyle(id, "Easing", continuesGesture: continues) { $0.easing = curve }
        }
        if inGesture { emitted = true }
    }

    public func beginGesture() { inGesture = true; emitted = false }
    public func endGesture() { inGesture = false; emitted = false }

    public var sessionEasingCurves: [EasingCurve] { [] }
    public func observeEaseInputs() { _ = session.activeTimeline }
    public var emptyEaseHint: String { "Select a transition" }
}

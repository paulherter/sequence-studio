import SQCore

// MARK: - What the popover edits

/// Something the curve popover can read and write: selected keyframe segments (Effect Controls) or a speed transition of the
/// Time Remapping band. `observeEaseInputs` reads every observable value the reading depends on (for observation tracking).
@MainActor
public protocol EaseCurveSource: AnyObject {
    var easeReading: EaseReading { get }
    func applyEaseShape(_ shape: EaseShape)
    func beginGesture()
    func endGesture()
    /// Curves saved this session that the chips offer too.
    var sessionEasingCurves: [EasingCurve] { get }
    func observeEaseInputs()
    /// Text when there is nothing to ease.
    var emptyEaseHint: String { get }
    /// Whether spring presets can be baked here (keyframe segments yes, speed transitions no).
    var canBakeSpring: Bool { get }
    func applySpring(_ spring: SpringEasing)
    /// Whether a Hold curve can be applied here (a transition refuses it: it would be a cut). Decides the Hold chip.
    var allowsHold: Bool { get }
    /// What the value part of a handle may be here (the editor's vertical drag stops there). Below 0 and above 1 the
    /// curve winds up or overshoots; a speed transition of the band stores 0...1 only.
    var handleValueRange: ClosedRange<Double> { get }
}

extension EaseCurveSource {
    public var canBakeSpring: Bool { false }
    public var allowsHold: Bool { true }
    public var handleValueRange: ClosedRange<Double> { -2...3 }
    public func applySpring(_ spring: SpringEasing) {}
}

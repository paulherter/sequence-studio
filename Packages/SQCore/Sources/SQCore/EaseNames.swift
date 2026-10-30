import Foundation

/// The one easing vocabulary of the app (docs/VOCABULARY.md, DECISIONS 2026-10-06): every menu, pop-up, chip and tooltip
/// that names a curve reads it here. Display only: stored names (`EasingCurve.name`, raw values) never change.
/// Title case, as every menu of the app. Order of any list: Steady, Smooth, Smooth In, Smooth Out, Hold, then extra presets, Custom last.
public enum EaseName {
    public static let steady = "Steady"
    public static let smooth = "Smooth"
    /// Slow arriving at the right key.
    public static let smoothIn = "Smooth In"
    /// Slow leaving the left key.
    public static let smoothOut = "Smooth Out"
    public static let hold = "Hold"
    /// The mirrored hold of a clip key (the next key's value from right after the key). Listed directly under Hold,
    /// only where a key can be one (clip keyframes; curves, transitions and Graphics keys only know Hold).
    public static let holdAhead = "Hold Ahead"
    public static let fastStart = "Fast Start"
    public static let fastEnd = "Fast End"
    public static let gentle = "Gentle"
    public static let smoothIn100 = "Smooth In 100%"
    public static let smoothOut100 = "Smooth Out 100%"
    public static let softLanding = "Soft Landing"
    public static let custom = "Custom"
    /// Menu item that opens the curve editor.
    public static let customMenu = "Custom\u{2026}"

    /// The keyframe right-click list: the reference order.
    public static let keyframeMenu = [steady, smooth, smoothIn, smoothOut, hold]
    /// The same list where a key can be a Hold Ahead (clip keys and item lanes in the Controls panel): Hold Ahead directly under Hold.
    public static let keyframeMenuWithHoldAhead = [steady, smooth, smoothIn, smoothOut, hold, holdAhead]
}

extension EasingCurve {
    /// The name shown for this curve: the own name of a built-in (by id, so curves stored under an older name read the
    /// same), else the name the user gave it.
    public var displayName: String {
        switch id {
        case EasingCurve.linear.id: EaseName.steady
        case EasingCurve.hold.id: EaseName.hold
        case EasingCurve.easeInOut.id: EaseName.smooth
        case EasingCurve.easeIn.id: EaseName.smoothIn
        case EasingCurve.easeOut.id: EaseName.smoothOut
        case EasingCurve.fastStart.id: EaseName.fastStart
        case EasingCurve.fastEnd.id: EaseName.fastEnd
        case EasingCurve.premiereDefault.id: EaseName.gentle
        case EasingCurve.easeOut100.id: EaseName.smoothIn100
        case EasingCurve.easeIn100.id: EaseName.smoothOut100
        case EasingCurve.softLanding.id: EaseName.softLanding
        default: name
        }
    }
}

import Foundation
import SQCore
import SQUIKit

/// The choices of the text animator rows (Animation section: In / Out by character, word or line) and the Look menu,
/// shared by the Mac `TextBlockView` and the portable `TextBlockDraw` so both list the same entries in the same order.
public enum TextAnimatorChoices {
    public static let effects: [(String, TextAnimatorEffect?)] = [
        ("None", nil), ("Fade", .fade), ("Pop", .pop), ("Slide", .slide), ("Typewriter", .typewriter), ("Blur", .blur),
        ("Wave (Loop)", .wave), ("Pulse (Loop)", .pulse),
    ]
    public static let units: [(String, TextAnimatorUnit)] = [("By Character", .character), ("By Word", .word), ("By Line", .line)]
    public static let directions: [(String, TextSlideDirection)] = [("Up", .up), ("Down", .down), ("Left", .left), ("Right", .right)]
    public static let easings: [(String, SegmentShape)] = [
        (EaseName.steady, .linear), (EaseName.smooth, .easeInOut), (EaseName.smoothIn, .easeIn), (EaseName.smoothOut, .easeOut),
        ("Overshoot", .overshoot),
    ]
    public static let orders: [(String, TextAnimatorOrder)] = [("Forward", .forward), ("Reverse", .reverse), ("From Center", .center)]
    /// A new animator's unit length (TextInspectorModel creates it with 0.3 s); the Length field's reset target.
    public static let defaultDurationMilliseconds = 300
    /// The Stagger field's reset when no animator is set (by word).
    public static let defaultStaggerMilliseconds = 80

    /// Which controls of an animator side take input: everything but the effect needs an animator; Length not for
    /// Typewriter (each unit appears at once), Direction and Distance for Slide and Wave, Loops for the loop effects,
    /// Blur for Blur (TextBlockView.refreshAnimator).
    public enum Control: Sendable, CaseIterable { case effect, unit, easing, direction, order, stagger, length, distance, blur, loops }
    public static func isEnabled(_ c: Control, _ a: TextAnimator?) -> Bool {
        switch c {
        case .effect: true
        case .unit, .easing, .order, .stagger: a != nil
        case .length: a != nil && a?.effect != .typewriter
        case .direction, .distance: a?.effect == .slide || a?.effect == .wave
        case .loops: a?.effect.isLoop == true
        case .blur: a?.effect == .blur
        }
    }

    /// Right-click on the Look popup: Update / Save as New / Rename / Delete for an editable Look (`name`), only Save
    /// as New for a built-in one or none.
    @MainActor public static func lookMenuItems(editable name: String?, update: @escaping @MainActor () -> Void = {},
                                                saveNew: @escaping @MainActor () -> Void,
                                                rename: @escaping @MainActor () -> Void = {},
                                                delete: @escaping @MainActor () -> Void = {}) -> [SQMenuItem] {
        let save = SQMenuItem(title: "Save as New Look\u{2026}", action: saveNew)
        guard let name else { return [save] }
        return [SQMenuItem(title: SQL10n.format("Update \u{201C}%@\u{201D}", name), action: update), save,
                SQMenuItem(title: "Rename\u{2026}", action: rename), SQMenuItem(title: "Delete", action: delete)]
    }

    /// Saved title templates join the Look popup under this id prefix and with " (Template)" after their name.
    public static let templateIDPrefix = "template:"
    public static func templateTitle(_ name: String) -> String { "\(name) (Template)" }
    public static func templateID(_ token: String) -> UUID? {
        guard token.hasPrefix(templateIDPrefix) else { return nil }
        return UUID(uuidString: String(token.dropFirst(templateIDPrefix.count)))
    }
}

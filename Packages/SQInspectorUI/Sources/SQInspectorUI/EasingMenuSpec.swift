import Foundation
import SQCore

/// Pure description of the easing menu (testable without AppKit).
public struct EasingMenuSpec: Sendable, Equatable {
    public enum Entry: Sendable, Equatable {
        case header(String)
        case side(EaseSide, title: String, checked: Bool)
        case curve(EasingCurve, enabled: Bool)
        case separator
        case saveCurve(enabled: Bool)
    }
    public var entries: [Entry]

    /// Board order of the built-in curves (menus.txt "Inline keyframe graph"): the 33 % curves are the Smooth family.
    public static let easeOrder: [EasingCurve] = [.linear, .easeInOut, .easeIn, .easeOut, .hold, .fastStart, .fastEnd,
                                                  .premiereDefault, .easeOut100, .easeIn100]
    /// Menu wording of a curve: the app's one easing vocabulary (`EaseName`).
    public static func title(of c: EasingCurve) -> String { c.displayName }

    public init(library: EasingLibrary, side: EaseSide, hasSelection: Bool) {
        var e: [Entry] = [.header("Apply to")]
        e.append(.side(.both, title: "Both sides", checked: side == .both))
        e.append(.side(.in, title: "Incoming only", checked: side == .in))
        e.append(.side(.out, title: "Outgoing only", checked: side == .out))
        e.append(.separator)
        e.append(.header("Ease"))
        for c in Self.easeOrder { e.append(.curve(c, enabled: hasSelection)) }
        if !library.userCurves.isEmpty {
            e.append(.separator)
            e.append(.header("Presets"))
            for c in library.userCurves { e.append(.curve(c, enabled: hasSelection)) }
        }
        e.append(.separator)
        e.append(.saveCurve(enabled: hasSelection))
        entries = e
    }

    public var curveNames: [String] { entries.compactMap { if case .curve(let c, _) = $0 { c.name } else { nil } } }
}

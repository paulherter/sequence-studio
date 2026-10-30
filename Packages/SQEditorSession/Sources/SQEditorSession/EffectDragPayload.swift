import SQCore

/// Pasteboard strings of the effects and transitions drags, below the panels so the timeline can read them
/// (`EffectsPanelView` and `EffectFolderOutline` forward here).
public enum EffectDragPayload {
    /// Pasteboard / row id of a transition: `transition.<TransitionKind raw value>`.
    public static let transitionPrefix = "transition."
    public static func transitionID(_ k: TransitionKind) -> String { transitionPrefix + k.rawValue }
    public static func transitionKind(forID id: String) -> TransitionKind? {
        id.hasPrefix(transitionPrefix) ? TransitionKind(rawValue: String(id.dropFirst(transitionPrefix.count))) : nil
    }

    /// Effect-id pasteboard string: one id, or several (a dragged folder) separated by newlines.
    public static func encodeDrag(_ ids: [String]) -> String { ids.joined(separator: "\n") }
    public static func decodeDrag(_ s: String) -> [String] { s.split(separator: "\n").map(String.init) }
}

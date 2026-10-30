import Foundation
import SQCore
import SQEditorSession

/// Other names an effect is searched by in the Effects panel (lowercase). The shown title stays the one name; these only widen
/// the search, so someone who types what the effect does ("steady", "shake") or the other spelling finds it.
public enum EffectSearchTerms {
    private static let byKind: [String: [String]] = [
        ClipEffect.stabilizeKind: ["stabilize", "stabilise", "stabilization", "stabiliser", "steady", "steadicam", "shake", "shaky",
                                   "gyroflow", "warp stabilizer"],
        // Film Dissolve (Premiere) and Cross Dissolve / Video style (Resolve) are this Dissolve: the compositor mixes in linear light.
        EffectDragPayload.transitionID(.crossDissolve): ["film dissolve", "cross dissolve", "non-additive dissolve"],
    ]
    public static func terms(forKind kind: String) -> [String] { byKind[kind] ?? [] }
}

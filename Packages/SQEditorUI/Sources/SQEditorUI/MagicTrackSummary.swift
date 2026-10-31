import SQCore
import SQUIKit

/// The status line a finished Magic track leaves (the end of `MacMagicMasks.runMagicTrack`): how many frames were
/// followed, on how many the object was lost, and for Face / Skin masks on how many the narrowing was unsure.
public enum MagicTrackSummary {
    /// `covers`: the mask keeps an enlarged estimate on frames without the subject (a Face / Skin or "must cover" mask).
    public static func message(frames: Int, lost: Int, unsure: Int, covers: Bool, part: AnonymizeTarget?) -> String {
        let check = unsure == 0 ? "" : " On \(unsure) of them the \(part == .skin ? "skin" : "face") was not found, so more is covered there: check them."
        if frames == 0 {
            return lost > 0 ? "The object was not found from this frame on: click it here to pick it up again."
                            : "Nothing to follow here: pick the object on this frame first."
        }
        if lost > 0 {
            return covers
                ? SQL10n.format("Tracked %@ frames; on %@ more the person was not found, so the cover there is an enlarged estimate: check them.", String(frames), String(lost)) + check
                : SQL10n.format("Tracked %@ frames; on %@ more the object was not found (marked on the strip): click it there to pick it up again.", String(frames), String(lost))
        }
        return SQL10n.format("Tracked the Magic mask over %@ frames.", String(frames)) + check
    }
}

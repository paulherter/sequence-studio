import Foundation
import SQCore

/// N8b: where the live duck is, drawn on each ducked Music track: a thin amber line that dips under speaking dialogue (the
/// same curve the mix applies, `LiveDucking.curve`). Read-only; to edit it, bake it into volume keys.
public struct DuckCurveSource {
    /// The setting in force (project or Preferences), read at draw time; nil = off.
    public var ducking: () -> LiveDucking?
    /// Pauses inside dialogue clips (the mix's own provider), so the curve is what is heard.
    public var silences: (any DialogueSilenceProvider)?

    public init(ducking: @escaping () -> LiveDucking?, silences: (any DialogueSilenceProvider)?) {
        self.ducking = ducking; self.silences = silences
    }
}

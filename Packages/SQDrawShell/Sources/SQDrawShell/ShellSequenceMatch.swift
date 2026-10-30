import Foundation
import SQCore
import SQEditorSession
import SQUIKit

/// "This clip does not match the sequence settings": asked when the first clip lands in an empty, never configured sequence
/// of another size or frame rate. Translated from the Mac `askChangeSequenceFormat`; the session asks it through
/// `askFormatChange` (`EditorSession.placeMediaAsking`). True = adopt the clip's format.
extension ShellHost {
    public func askChangeSequenceFormat(_ current: SequenceFormat, _ proposed: SequenceFormat) async -> Bool {
        let d = ShellDialog("This clip does not match the sequence settings.",
                            informative: SQL10n.format("Sequence: %@. Clip: %@. Change the sequence settings to match the clip?",
                                                       Self.formatText(current), Self.formatText(proposed)))
        d.addButton("Change Sequence Settings")
        d.addButton("Keep Existing Settings")
        return await ask(d) == .first
    }

    /// "1920×1080, 29.97 fps" (`%.5g`).
    static func formatText(_ f: SequenceFormat) -> String {
        let fps = Double(f.frameDuration.timescale) / Double(f.frameDuration.value)
        return "\(f.width)×\(f.height), \(String(format: "%.5g", fps)) fps"
    }
}

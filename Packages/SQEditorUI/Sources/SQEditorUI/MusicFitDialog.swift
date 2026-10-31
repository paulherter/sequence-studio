import AppKit
import SQAnalysis
import SQCore
import SQEditorSession
import SQUIKit

/// Clip > Beat Edits > Fit Music to Length…: one row (button) per proposed version, a click applies it.
@MainActor
public enum MusicFitDialog {
    /// "Version 1: 30.0 s, exact, cut 2 bars" for a row.
    public static func rowTitle(_ v: MusicFit.Version, index: Int) -> String { EditorSession.musicFitRowTitle(v, index: index) }

    private static func seconds(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

    public static func present(on window: NSWindow, clipName: String, target: Time, versions: [MusicFit.Version],
                               completion: @escaping @MainActor (MusicFit.Version?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Fit Music to Length"
        alert.informativeText = String(format: "%@ to %.1f s. Joins sit on bar lines with a short crossfade.", clipName, seconds(target))
        alert.width = SQModal.Size.s.width
        for (i, v) in versions.enumerated() { alert.addButton(rowTitle(v, index: i)) }
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                completion(versions.indices.contains(response.rawValue) ? versions[response.rawValue] : nil)
            }
        }
    }
}

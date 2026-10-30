import SQUIKit
import AppKit
import SQCore
import SQEditorSession

/// "Create Angles Clip" sheet (F7.16): name, how the angles are lined up, whose sound plays.
public enum AnglesDialog {
    /// How the angles are lined up in time (portable: `AngleSyncMode`, shared with the draw-list shell).
    public typealias Sync = AngleSyncMode

    public struct Result: Equatable, Sendable {
        public var name: String
        public var sync: Sync
        /// Index of the angle whose sound plays.
        public var audioAngle: Int
        public var audioFollowsVideo: Bool

        public init(name: String, sync: Sync, audioAngle: Int, audioFollowsVideo: Bool) {
            self.name = name; self.sync = sync; self.audioAngle = audioAngle; self.audioFollowsVideo = audioFollowsVideo
        }
    }

    /// First free "Angles NN" among `existing` names.
    public static func defaultName(existing: [String]) -> String { AngleSyncMode.defaultName(existing: existing) }

    /// The sync choices on offer (`AngleSyncMode.choices`).
    public static func syncChoices(angles: [AngleCandidate], fromTimeline: Bool) -> [Sync] {
        AngleSyncMode.choices(angles: angles, fromTimeline: fromTimeline)
    }

    /// The angle whose sound plays by default: the first with sound.
    public static func defaultAudioAngle(_ angles: [AngleCandidate]) -> Int { AngleSyncMode.defaultAudioAngle(angles) }

    /// The accessory view alone, so a test can render it.
    @MainActor
    public static func makeView(angles: [AngleCandidate], fromTimeline: Bool, name: String)
        -> (view: NSView, name: NSTextField, sync: SQPopup, sound: SQPopup, follows: SQCheckbox) {
        let field = SQDialog.makeField(width: 220)
        field.stringValue = name
        let choices = syncChoices(angles: angles, fromTimeline: fromTimeline)
        let sync = SQPopup(frame: .zero, pullsDown: false)
        sync.addItems(withTitles: choices.map(\.title))
        let sound = SQPopup(frame: .zero, pullsDown: false)
        sound.addItems(withTitles: angles.enumerated().map { "\($0.offset + 1)  \($0.element.name)" })
        sound.selectItem(at: defaultAudioAngle(angles))
        let follows = SQCheckbox(title: "Audio Follows Video", target: nil, action: nil)
        let form = SQDialogForm(rows: [
            SQDialog.formRow("Name", field),
            SQDialog.formRow("Sync by", sync),
            SQDialog.formRow("Sound from", sound),
            SQDialog.checkRow(follows),
        ])
        return (form, field, sync, sound, follows)
    }

    /// Presents the sheet on `window`; `completion` gets the choices on OK, nil on Cancel.
    @MainActor
    public static func present(on window: NSWindow, angles: [AngleCandidate], fromTimeline: Bool, existingNames: [String],
                               completion: @escaping @MainActor (Result?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Create Angles Clip"
        alert.informativeText = SQL10n.format("%@ angles become one clip. Cut it and choose an angle per piece with the keys 1 to 9.", String(angles.count))
        alert.width = SQModal.Size.s.width
        let fallback = defaultName(existing: existingNames)
        let choices = syncChoices(angles: angles, fromTimeline: fromTimeline)
        let ui = makeView(angles: angles, fromTimeline: fromTimeline, name: fallback)
        let field = ui.name, sync = ui.sync, sound = ui.sound, follows = ui.follows
        alert.accessoryView = ui.view
        alert.addButton("OK")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .first else { completion(nil); return }
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let i = min(max(sync.indexOfSelectedItem, 0), choices.count - 1)
                completion(Result(name: name.isEmpty ? fallback : name, sync: choices[i],
                                  audioAngle: max(sound.indexOfSelectedItem, 0), audioFollowsVideo: follows.state == .on))
            }
        }
    }
}

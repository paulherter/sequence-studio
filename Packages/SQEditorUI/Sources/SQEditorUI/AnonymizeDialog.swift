import AppKit
import SQCore
import SQEditorSession

/// The Anonymize sheet: what to cover (Face, Whole Person, Skin), with what (Mosaic, Blur) and which of the people found on
/// the current frame. The text never promises a result: detection is a guess and the user checks it.
@MainActor
public enum AnonymizeDialog {
    public static let hint = AnonymizeText.hint

    nonisolated public static func personLabel(_ index: Int, _ p: AnonymizePerson) -> String { AnonymizeText.personLabel(index, p) }

    public static func present(on window: NSWindow, clipName: String, people: [AnonymizePerson],
                               completion: @escaping @MainActor (AnonymizeChoice?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Anonymize"
        alert.informativeText = AnonymizeText.info(clipName: clipName)
        alert.width = SQModal.Size.s.width
        let ui = makeView(people: people)
        alert.accessoryView = ui.view
        alert.addButton("Anonymize")
        alert.addButton("Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                withExtendedLifetime(ui.controller) {}
                let c = ui.controller.choice
                guard response == .first, !c.people.isEmpty else { completion(nil); return }
                c.remember()
                completion(c)
            }
        }
    }

    /// The accessory view and its controller (a test renders the view).
    public static func makeView(people: [AnonymizePerson], defaults: UserDefaults = .standard) -> (view: NSView, controller: AnonymizeFieldsController) {
        let c = AnonymizeFieldsController(people: people, initial: AnonymizeChoice.remembered(defaults))
        return (c.view, c)
    }

    /// The list of frames to check by hand after a run. Ranges where the person may be outside the cover come first and
    /// are all listed; of the others at most `maxLines`. `go`: jump to the first one.
    public static func presentChecks(on window: NSWindow, lines: [AnonymizeCheckLine], go: @escaping @MainActor (Time) -> Void) {
        let list = AnonymizeCheckLine.shown(lines, limit: maxLines)
        guard let first = list.lines.first else { return }
        let alert = SQDialog()
        alert.messageText = "Anonymize: Check These Frames"
        alert.informativeText = checksText(lines)
        alert.width = SQModal.Size.sList.width
        let shown = list.lines.map { SQDialog.formText($0.text, note: false) }
        let more = list.more > 0 ? [SQDialog.formText(AnonymizeText.moreNote(list.more))] : []
        alert.accessoryView = SQDialogForm(rows: shown + more)
        alert.addButton("Go to First")
        alert.addButton("Close")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { if response == .first { go(first.time) } }
        }
    }

    nonisolated public static func checksText(_ lines: [AnonymizeCheckLine]) -> String { AnonymizeText.checksText(lines) }

    static let maxLines = AnonymizeText.maxLines
}

@MainActor
public final class AnonymizeFieldsController: NSObject {
    let target: SQSegmented
    let cover: SQSegmented
    let boxes: [SQCheckbox]
    public let view: NSView

    public var choice: AnonymizeChoice {
        AnonymizeChoice(target: AnonymizeTarget.allCases[min(max(target.selectedSegment, 0), AnonymizeTarget.allCases.count - 1)],
                        cover: AnonymizeCover.allCases[min(max(cover.selectedSegment, 0), AnonymizeCover.allCases.count - 1)],
                        people: boxes.indices.filter { boxes[$0].state == .on })
    }

    init(people: [AnonymizePerson], initial: (target: AnonymizeTarget, cover: AnonymizeCover)) {
        target = SQSegmented(labels: AnonymizeTarget.allCases.map(\.title), segmentWidth: 104)
        cover = SQSegmented(labels: AnonymizeCover.allCases.map(\.title), segmentWidth: 104)
        target.selectedSegment = AnonymizeTarget.allCases.firstIndex(of: initial.target) ?? 0
        cover.selectedSegment = AnonymizeCover.allCases.firstIndex(of: initial.cover) ?? 0
        boxes = people.enumerated().map { i, p in
            let b = SQCheckbox(title: AnonymizeDialog.personLabel(i, p), target: nil, action: nil)
            b.state = .on
            return b
        }
        var rows: [NSView] = [SQDialog.formRow("Cover", target), SQDialog.formRow("With", cover)]
        rows.append(SQDialog.formText(AnonymizeText.peopleNote(count: people.count), note: false, top: 6))
        rows += boxes.map { SQDialog.checkRow($0) }
        rows.append(SQDialog.formText(AnonymizeDialog.hint))
        view = SQDialogForm(rows: rows)
        super.init()
    }
}

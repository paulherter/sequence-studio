import AppKit
import SQCore
import SQEditorUI

/// Fit Clip chooser for a four-mark Source edit whose source and sequence ranges differ in length. Own SQ look
/// (SQModalSheet, SQRadioGroup); the last choice is preselected (`sq.fourPointFit`).
@MainActor
final class FourPointFitSheet: NSObject {
    /// The rows and the remembered choice are shared with Windows (SQDrawMonitor).
    typealias Choice = FourPointFitChoice

    static var saved: Choice { FourPointFitChoice.saved() }

    private var keepAlive: FourPointFitSheet?
    private var sheet: SQModalSheet?
    private let completion: (Choice?) -> Void
    private var group: SQRadioGroup?

    /// `choice` is nil when the sheet was canceled.
    static func present(over window: NSWindow, completion: @escaping (Choice?) -> Void) {
        let s = FourPointFitSheet(completion: completion)
        s.keepAlive = s
        s.show(over: window)
    }

    private init(completion: @escaping (Choice?) -> Void) { self.completion = completion }

    private func show(over window: NSWindow) {
        let width = SQModal.Size.m.width
        let title = SQDialogText(.title, "Fit Clip", width: width - 32)
        let note = SQDialogText(.note, "The Source and the sequence marks differ in length. Choose what decides the edit.",
                                width: width - 32)
        let all = Choice.allCases
        let made = SQRadioGroup.make(titles: all.map(\.title), selected: all.firstIndex(of: Self.saved))
        group = made.0
        let body = SQDialogForm(rows: made.1.map { SQDialog.formRow("", $0) })

        func button(_ title: String, _ action: Selector, _ style: SQButton.Style) -> SQButton {
            let b = SQButton(title: title, target: self, action: action, style: style)
            b.horizontalPadding = SQDialogMetrics.buttonPadding
            b.boxHeight = SQDialogMetrics.buttonHeight
            b.setContentHuggingPriority(.required, for: .horizontal)
            return b
        }
        let cancel = button("Cancel", #selector(cancel), .standard)
        cancel.keyEquivalent = "\u{1b}"
        let ok = button("Edit", #selector(accept), .accent)
        ok.keyEquivalent = "\r"
        let footer = SQDialog.footerRow(left: [], right: [cancel, ok])
        let card = SQDialog.cardContent(title: title, note: note, body: body, footer: footer, width: width)
        let w = SQModalSheet(card: card) { [weak self] in self?.cancel() }
        sheet = w
        w.present(over: window)
    }

    private func finish(_ choice: Choice?) {
        sheet?.dismiss(); sheet = nil
        keepAlive = nil
        completion(choice)
    }

    @objc private func cancel() { finish(nil) }

    @objc private func accept() {
        let all = Choice.allCases
        let c = all[max(0, min(group?.selectedIndex ?? 0, all.count - 1))]
        FourPointFitChoice.save(c)
        finish(c)
    }
}

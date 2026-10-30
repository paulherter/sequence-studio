import AppKit
import SQEditorUI
import SQExport

/// OpenTimelineIO export scope before the save panel: the open sequence or every sequence of the project.
/// Own SQ look (SQModalSheet, SQSegmented); remembered in `sq.export.otioScope`.
@MainActor
final class OTIOScopeSheet: NSObject {
    private var keepAlive: OTIOScopeSheet?
    private var sheet: SQModalSheet?
    private let completion: (OTIOWriter.Scope?) -> Void
    private let segmented = SQSegmented(labels: ["Open sequence", "All sequences"], segmentWidth: 124)

    static let scopeKey = "sq.export.otioScope"

    static var savedScope: OTIOWriter.Scope {
        UserDefaults.standard.string(forKey: scopeKey).flatMap(OTIOWriter.Scope.init(rawValue:)) ?? .activeSequence
    }

    /// `scope` is nil when the sheet was canceled.
    static func present(over window: NSWindow, completion: @escaping (OTIOWriter.Scope?) -> Void) {
        let s = OTIOScopeSheet(completion: completion)
        s.keepAlive = s
        s.show(over: window)
    }

    private init(completion: @escaping (OTIOWriter.Scope?) -> Void) { self.completion = completion }

    private func show(over window: NSWindow) {
        let width = SQModal.Size.m.width
        let title = SQDialogText(.title, "Export OpenTimelineIO", width: width - 32)
        let note = SQDialogText(.note, "All sequences are written to one file; importing it opens each of them as a sequence.",
                                width: width - 32)
        segmented.selectedSegment = OTIOWriter.Scope.allCases.firstIndex(of: Self.savedScope) ?? 0
        let body = SQDialogForm(rows: [SQDialog.formRow("Scope", [segmented, NSView()])])

        func button(_ title: String, _ action: Selector, _ style: SQButton.Style) -> SQButton {
            let b = SQButton(title: title, target: self, action: action, style: style)
            b.horizontalPadding = SQDialogMetrics.buttonPadding
            b.boxHeight = SQDialogMetrics.buttonHeight
            b.setContentHuggingPriority(.required, for: .horizontal)
            return b
        }
        let cancel = button("Cancel", #selector(cancel), .standard)
        cancel.keyEquivalent = "\u{1b}"
        let ok = button("Export…", #selector(accept), .accent)
        ok.keyEquivalent = "\r"
        let footer = SQDialog.footerRow(left: [], right: [cancel, ok])
        let card = SQDialog.cardContent(title: title, note: note, body: body, footer: footer, width: width)
        let w = SQModalSheet(card: card) { [weak self] in self?.cancel() }
        sheet = w
        w.present(over: window)
    }

    private func finish(_ scope: OTIOWriter.Scope?) {
        sheet?.dismiss(); sheet = nil
        keepAlive = nil
        completion(scope)
    }

    @objc private func cancel() { finish(nil) }

    @objc private func accept() {
        let all = OTIOWriter.Scope.allCases
        let scope = all[max(0, min(segmented.selectedSegment, all.count - 1))]
        UserDefaults.standard.set(scope.rawValue, forKey: Self.scopeKey)
        finish(scope)
    }
}

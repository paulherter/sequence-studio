import AppKit
import SQEditorUI
import SQExport

/// FCPXML export options before the save panel: DTD version and target app. Own SQ look (SQModalSheet, SQSegmented);
/// the choice is remembered in `sq.export.fcpxmlVersion` / `sq.export.fcpxmlTarget`.
@MainActor
final class InterchangeExportSheet: NSObject {
    private var keepAlive: InterchangeExportSheet?
    private var sheet: SQModalSheet?
    private let completion: (FCPXMLWriter.Version, FCPXMLWriter.Target?) -> Void
    private let versionSegmented = SQSegmented(labels: FCPXMLWriter.Version.allCases.map(\.rawValue), segmentWidth: 64)
    private let targetSegmented = SQSegmented(labels: ["DaVinci Resolve", "Final Cut Pro"], segmentWidth: 116)

    static let versionKey = "sq.export.fcpxmlVersion", targetKey = "sq.export.fcpxmlTarget"

    static var savedVersion: FCPXMLWriter.Version {
        UserDefaults.standard.string(forKey: versionKey).flatMap(FCPXMLWriter.Version.init(rawValue:)) ?? .v1_8
    }
    static var savedTarget: FCPXMLWriter.Target {
        UserDefaults.standard.string(forKey: targetKey).flatMap(FCPXMLWriter.Target.init(rawValue:)) ?? .resolve
    }

    /// `target` is nil when the sheet was canceled.
    static func present(over window: NSWindow, completion: @escaping (FCPXMLWriter.Version, FCPXMLWriter.Target?) -> Void) {
        let s = InterchangeExportSheet(completion: completion)
        s.keepAlive = s
        s.show(over: window)
    }

    private init(completion: @escaping (FCPXMLWriter.Version, FCPXMLWriter.Target?) -> Void) { self.completion = completion }

    private var selectedVersion: FCPXMLWriter.Version {
        let all = FCPXMLWriter.Version.allCases
        return all[max(0, min(versionSegmented.selectedSegment, all.count - 1))]
    }

    private func show(over window: NSWindow) {
        let width = SQModal.Size.m.width
        let title = SQDialogText(.title, "Export FCPXML", width: width - 32)
        let note = SQDialogText(.note, "Final Cut Pro 10.4 reads 1.8, 10.6 reads 1.10, 11 reads 1.13. DaVinci Resolve reads all three.",
                                width: width - 32)
        versionSegmented.selectedSegment = FCPXMLWriter.Version.allCases.firstIndex(of: Self.savedVersion) ?? 0
        targetSegmented.selectedSegment = FCPXMLWriter.Target.allCases.firstIndex(of: Self.savedTarget) ?? 0
        let body = SQDialogForm(rows: [SQDialog.formRow("Version", [versionSegmented, NSView()]),
                                       SQDialog.formRow("Target", [targetSegmented, NSView()])])

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

    private func finish(_ target: FCPXMLWriter.Target?) {
        sheet?.dismiss(); sheet = nil
        keepAlive = nil
        completion(selectedVersion, target)
    }

    @objc private func cancel() { finish(nil) }

    @objc private func accept() {
        let targets = FCPXMLWriter.Target.allCases
        let target = targets[max(0, min(targetSegmented.selectedSegment, targets.count - 1))]
        UserDefaults.standard.set(selectedVersion.rawValue, forKey: Self.versionKey)
        UserDefaults.standard.set(target.rawValue, forKey: Self.targetKey)
        finish(target)
    }
}

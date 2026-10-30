import AppKit
import SQEditorUI
import SQPremiereImport

/// Shown after a Premiere import (IMP-17): what was mapped, approximated and dropped, worst first.
/// Own SQ look (dark panel, SQButton); no NSAlert. "Save Report…" writes the same text the log gets.
@MainActor
final class ImportReportSheet: NSObject {
    private var keepAlive: ImportReportSheet?
    private var sheet: SQModalSheet?
    private let report: PRImportReport
    private let fileName: String
    private let completion: () -> Void
    /// Checklist mode (project imports): rows come from the checklist, with Show / Reconnect on the rows that can act.
    private let checklist: PRImportChecklist?
    private let onShow: ((PRImportChecklist.Item) -> Void)?
    private let onReconnect: (() -> Void)?

    /// Worst first: dropped, approximated, mapped.
    static func rows(_ report: PRImportReport) -> [PRImportReport.Entry] {
        report.entries.sorted { ($0.status, $1.count, $0.feature) > ($1.status, $0.count, $1.feature) }
    }

    static func present(_ report: PRImportReport, fileName: String, over window: NSWindow,
                        checklist: PRImportChecklist? = nil, onShow: ((PRImportChecklist.Item) -> Void)? = nil,
                        onReconnect: (() -> Void)? = nil, completion: @escaping () -> Void) {
        let s = ImportReportSheet(report: report, fileName: fileName, checklist: checklist, onShow: onShow, onReconnect: onReconnect, completion: completion)
        s.keepAlive = s
        s.show(over: window)
    }

    private init(report: PRImportReport, fileName: String, checklist: PRImportChecklist?, onShow: ((PRImportChecklist.Item) -> Void)?,
                 onReconnect: (() -> Void)?, completion: @escaping () -> Void) {
        self.report = report; self.fileName = fileName; self.completion = completion
        self.checklist = checklist; self.onShow = onShow; self.onReconnect = onReconnect
    }

    /// One row of the list: dot color, headline, detail line and (checklist mode) the checklist item behind it.
    private struct Row { var color: NSColor; var head: String; var detail: String; var item: PRImportChecklist.Item? }

    private var listRows: [Row] {
        if let checklist {
            return checklist.items.map { i in
                let color: NSColor = switch i.kind {
                case .cameOver: Theme.Colors.green
                case .approximated: Theme.Palette.marker(.yellow)
                case .leftOut: Theme.Palette.marker(.orange)
                case .missingFiles: Theme.Colors.red
                }
                let head = i.kind == .approximated || i.kind == .leftOut ? "\(i.count)x  \(i.title)" : i.title
                return Row(color: color, head: head, detail: i.detail, item: i)
            }
        }
        return Self.rows(report).map { e in
            let color = e.status == .dropped ? Theme.Colors.red : e.status == .approximated ? Theme.Palette.marker(.orange) : Theme.Colors.green
            let status = e.status.label.prefix(1).uppercased() + e.status.label.dropFirst()
            return Row(color: color, head: "\(e.count)x  \(e.feature)", detail: e.note.isEmpty ? status : "\(status): \(e.note)", item: nil)
        }
    }

    private func show(over window: NSWindow) {
        func total(_ s: PRImportReport.Status) -> Int { report.entries.filter { $0.status == s }.reduce(0) { $0 + $1.count } }
        let width = SQModal.Size.m.width
        let title = SQDialogText(.title, "Imported \(fileName)", width: width - 32)
        let noteText = checklist != nil
            ? (checklist!.needsAttention ? "Show jumps to the affected clips. This list stays under File > Import Checklist."
                                         : "Everything came over as is.")
            : "\(total(.mapped)) mapped, \(total(.approximated)) approximated, \(total(.dropped)) dropped. Fix the last two by hand."
        let note = SQDialogText(.note, noteText, width: width - 32)

        // Board `.well`: inset 16, radius 6, 4 above and below; rows 38 high, dot column 18, name over status (label3).
        let list = NSStackView()
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let rows = listRows
        for r in rows {
            let color = r.color
            let dotSize: CGFloat = 8
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = dotSize / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            let head = NSTextField(labelWithString: r.head)
            head.font = Theme.Typography.bodyStrong; head.textColor = Theme.Colors.label
            let detail = NSTextField(labelWithString: r.detail)
            detail.lineBreakMode = .byTruncatingTail
            detail.font = Theme.Typography.body; detail.textColor = Theme.Colors.label3
            let text = NSStackView(views: [head, detail]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 0
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(dot); row.addSubview(text)
            var trailing = row.trailingAnchor
            if let item = r.item, let action = rowAction(for: item) {
                let b = SQButton(title: action.title, target: self, action: action.selector, style: .standard)
                b.identifier = NSUserInterfaceItemIdentifier(item.id)
                b.horizontalPadding = 10
                b.boxHeight = 24
                b.setContentHuggingPriority(.required, for: .horizontal)
                b.setContentCompressionResistancePriority(.required, for: .horizontal)
                b.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(b)
                NSLayoutConstraint.activate([b.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                                             b.centerYAnchor.constraint(equalTo: row.centerYAnchor)])
                trailing = b.leadingAnchor
            }
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 38),
                dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: dotSize), dot.heightAnchor.constraint(equalToConstant: dotSize),
                text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 30),
                text.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -12),
                text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let flipped = FlippedView(); flipped.addSubview(list)
        let scroll = NSScrollView()
        scroll.documentView = flipped
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.setAccessibilityLabel("Import report")
        flipped.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let listHeight = CGFloat(rows.count) * 38 + 8
        let well = NSView()
        well.wantsLayer = true
        well.layer?.backgroundColor = Theme.Colors.content.cgColor
        well.layer?.cornerRadius = Theme.Dialog.reportWellRadius
        well.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(scroll)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 4), list.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: flipped.trailingAnchor), list.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -4),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: well.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: well.topAnchor), scroll.bottomAnchor.constraint(equalTo: well.bottomAnchor),
            well.heightAnchor.constraint(equalToConstant: min(max(listHeight, 46), 300)),
        ])
        let body = SQDialog.pad(well, SQDialogMetrics.insets(0, 0))

        func button(_ title: String, _ action: Selector, _ style: SQButton.Style) -> SQButton {
            let b = SQButton(title: title, target: self, action: action, style: style)
            b.horizontalPadding = SQDialogMetrics.buttonPadding
            b.boxHeight = SQDialogMetrics.buttonHeight
            b.setContentHuggingPriority(.required, for: .horizontal)
            return b
        }
        let done = button("Done", #selector(close), .accent)
        done.keyEquivalent = "\r"
        let footer = SQDialog.footerRow(left: [], right: [button("Save Report…", #selector(saveReport), .standard), done])
        let card = SQDialog.cardContent(title: title, note: note, body: body, footer: footer, width: width)
        let w = SQModalSheet(card: card) { [weak self] in self?.close() }
        sheet = w
        w.present(over: window)
    }

    private func rowAction(for item: PRImportChecklist.Item) -> (title: String, selector: Selector)? {
        switch item.kind {
        case .cameOver: return nil
        case .missingFiles: return onReconnect.map { _ in ("Reconnect…", #selector(reconnectTapped)) }
        case .approximated, .leftOut: return item.locations.isEmpty || onShow == nil ? nil : ("Show", #selector(showTapped(_:)))
        }
    }

    @objc private func showTapped(_ sender: NSView) {
        guard let item = checklist?.items.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        close()
        onShow?(item)
    }

    @objc private func reconnectTapped() {
        close()
        onReconnect?()
    }

    @objc private func close() {
        sheet?.dismiss(); sheet = nil
        let done = completion
        keepAlive = nil
        done()
    }

    @objc private func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(fileName) import report.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.summary.write(to: url, atomically: true, encoding: .utf8)
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

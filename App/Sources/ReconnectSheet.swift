import AppKit
import SQCore
import SQEditorUI
import SQUIKit

/// Reconnect Media checklist (own SQ look): one row per proposed match with the found file and the signals that agree.
/// Strong matches start ticked, weak ones (renamed copy, other size, several equal files) start unticked; nothing is
/// applied until "Reconnect N". Missing items without a match are listed in the note.
@MainActor
final class ReconnectSheet: NSObject {
    private var keepAlive: ReconnectSheet?
    private var sheet: SQModalSheet?
    private let result: RelinkScorer.Result
    private let total: Int
    private let names: [MediaRef.ID: String]
    private let onApply: ([RelinkProposal]) -> Void
    private var boxes: [SQCheckbox] = []
    private var apply: SQButton!
    private var cancel: SQButton!

    static func present(result: RelinkScorer.Result, total: Int, names: [MediaRef.ID: String], over window: NSWindow,
                        onApply: @escaping ([RelinkProposal]) -> Void) {
        let s = ReconnectSheet(result: result, total: total, names: names, onApply: onApply)
        s.keepAlive = s
        s.show(over: window)
    }

    private init(result: RelinkScorer.Result, total: Int, names: [MediaRef.ID: String], onApply: @escaping ([RelinkProposal]) -> Void) {
        self.result = result; self.total = total; self.names = names; self.onApply = onApply
    }

    private func show(over window: NSWindow) {
        let width = SQModal.Size.m.width
        let title = SQDialogText(.title, result.foundText(total: total), width: width - SQDialogMetrics.sidePad * 2)
        let unmatched = result.unmatched.count
        let note = SQDialogText(.note, unmatched == 0 ? "Untick any match you do not trust. Weak matches start unticked."
                                : "\(unmatched) still missing after this. Untick any match you do not trust; weak matches start unticked.",
                                width: width - SQDialogMetrics.sidePad * 2)
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = Theme.Spacing.sm
        list.translatesAutoresizingMaskIntoConstraints = false
        for p in result.proposals {
            let box = SQCheckbox(title: names[p.mediaID] ?? MediaPathResolver.fileName(of: p.path), target: self, action: #selector(toggled))
            box.state = p.isChecked ? .on : .off
            boxes.append(box)
            let detail = NSTextField(labelWithString: "\(p.tier == .strong ? "Strong" : "Weak") · \(SQL10n.string(p.signalText)) · \(p.path)")
            detail.font = Theme.Typography.caption
            detail.textColor = p.tier == .strong ? Theme.Colors.label2 : Theme.Colors.warning
            detail.lineBreakMode = .byTruncatingMiddle
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [box, detail])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2
            list.addArrangedSubview(row)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let inner = width - SQDialogMetrics.sidePad * 2
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: inner),
            scroll.heightAnchor.constraint(equalToConstant: min(260, CGFloat(max(1, result.proposals.count)) * 40)),
            list.widthAnchor.constraint(equalToConstant: inner - 12),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        cancel = SQButton(title: "Cancel", target: self, action: #selector(close), style: .standard)
        apply = SQButton(title: "Reconnect", target: self, action: #selector(confirm), style: .accent)
        for b in [cancel!, apply!] {
            b.horizontalPadding = SQDialogMetrics.buttonPadding; b.boxHeight = SQDialogMetrics.buttonHeight
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        apply.keyEquivalent = "\r"
        updateButton()
        let footer = SQDialog.footerRow(left: [], right: [cancel, apply])
        let content = SQDialog.cardContent(title: title, note: note, body: scroll, footer: footer, width: width)
        let w = SQModalSheet(card: content) { [weak self] in self?.close() }
        sheet = w
        w.present(over: window)
    }

    private var ticked: [RelinkProposal] { zip(result.proposals, boxes).filter { $1.state == .on }.map(\.0) }

    private func updateButton() {
        let n = ticked.count
        apply.title = n == 0 ? "Reconnect" : "Reconnect \(n)"
        apply.isEnabled = n > 0
    }

    @objc private func toggled() { updateButton() }

    @objc private func confirm() {
        let picked = ticked
        finish()
        onApply(picked)
    }

    @objc private func close() { finish() }

    private func finish() {
        guard keepAlive != nil else { return }
        sheet?.dismiss(); sheet = nil
        keepAlive = nil
    }
}

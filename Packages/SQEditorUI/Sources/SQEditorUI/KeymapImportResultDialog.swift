import AppKit
import SQUIKit

/// Body of the Keyboard Shortcuts import result sheet (ladder step `sList`, 480): the lists of commands without an
/// equivalent, changed keys and skipped keys in a scrolling block of fixed height under the summary.
@MainActor
public enum KeymapImportResultDialog {
    public static let listHeight: CGFloat = 220

    public static func title(_ r: KeymapImport) -> String { r.summary }
    public static func note(name: String) -> String {
        "“\(name)” is saved as one of your own sets. Commands it does not mention keep their Sequence Studio keys."
    }

    /// The form under the summary; no rows when there is nothing to list.
    public static func makeAccessory(_ r: KeymapImport) -> NSView {
        let list = NSMutableAttributedString()
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            list.append(NSAttributedString(string: title + "\n", attributes: [.font: Theme.Typography.bodyStrong, .foregroundColor: Theme.Colors.label]))
            list.append(NSAttributedString(string: lines.joined(separator: "\n") + "\n\n", attributes: [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label2]))
        }
        section("No equivalent in Sequence Studio (\(r.unmapped.count))", r.unmapped.map { KeymapImport.title(of: $0) })
        section("Changed keys", r.conflicts.map(\.message))
        section("Not imported", r.skippedKeys.map(\.message))

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textStorage?.setAttributedString(list)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        SQScrollView.apply(to: scroll)
        scroll.hasHorizontalScroller = false

        var rows: [NSView] = []
        if !list.string.isEmpty { rows.append(SQDialog.pad(scroll, SQDialogMetrics.insets(0, 0), height: listHeight)) }
        return SQDialogForm(rows: rows)
    }
}

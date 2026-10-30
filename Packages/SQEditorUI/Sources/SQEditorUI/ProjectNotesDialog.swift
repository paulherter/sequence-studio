import AppKit
import SQCore
import SQUIKit

/// Body of the Project Notes dialog: one multi-line text field in the SQ field look (fill, edge, accent ring while typing).
/// The text is the project's free-text notes (`Project.notes`); the caller applies it as one undo step on OK.
@MainActor
public enum ProjectNotesDialog {
    public static let boxHeight: CGFloat = 180
    public static let hint = "Notes stay with the project file: who it is for, deadlines, delivery specs, to-dos."

    /// The form and its text view; `text` is the current notes.
    public static func makeView(text: String) -> (view: NSView, textView: NSTextView) {
        let box = NotesBox(text: text)
        return (SQDialogForm(rows: [SQDialog.pad(box, SQDialogMetrics.insets(0, 0), height: boxHeight)]), box.textView)
    }

    /// The accessory text view the dialog reads back, as stored text.
    public static func notes(from textView: NSTextView) -> String { textView.string }

    @MainActor
    private final class NotesBox: NSView, NSTextViewDelegate {
        let textView = NSTextView()
        private let scroll = NSScrollView()

        init(text: String) {
            super.init(frame: .zero)
            textView.delegate = self
            textView.string = text
            textView.drawsBackground = false
            textView.font = Theme.Typography.body
            textView.textColor = Theme.Colors.label
            textView.insertionPointColor = Theme.Colors.accent
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.allowsUndo = true            // typing inside the dialog; the project's undo gets one step on OK
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            scroll.documentView = textView
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.translatesAutoresizingMaskIntoConstraints = false
            addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            ])
            setAccessibilityLabel("Project notes")
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.overlay, yRadius: Theme.Radius.overlay)
            Theme.Colors.field.setFill(); p.fill()
            (textView.window?.firstResponder === textView ? Theme.Colors.accentRing : Theme.Colors.fieldEdge).setStroke()
            p.lineWidth = 1; p.stroke()
        }

        func textDidBeginEditing(_ notification: Notification) { needsDisplay = true }
        func textDidEndEditing(_ notification: Notification) { needsDisplay = true }
    }
}

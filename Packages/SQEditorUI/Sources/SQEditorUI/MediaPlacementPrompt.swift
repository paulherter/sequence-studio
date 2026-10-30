import AppKit
import SQCore

/// The small prompt shown at a drop of media from outside the project folder: the clip has already landed, this decides
/// what happens to the file. Copy (V), Move (X), Leave (L); Return repeats the last choice, Esc leaves.
@MainActor
public final class MediaPlacementPrompt {
    public enum Choice: String, Sendable { case copy, move, leave }

    private static let lastChoiceKey = "sq.mediaPlacement.lastChoice"

    /// The choice Return takes: the last one used, Copy at first.
    public static var lastChoice: Choice {
        get { UserDefaults.standard.string(forKey: lastChoiceKey).flatMap(Choice.init(rawValue:)) ?? .copy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lastChoiceKey) }
    }

    private var popover: SQPopover?

    public init() {}

    public var isShown: Bool { popover?.isShown == true }

    /// Shows the prompt at `screenPoint` (AppKit screen coordinates) below `window`. `onChoice(choice, always)` runs once;
    /// closing the prompt any other way counts as Leave.
    public func show(fileCount: Int, at screenPoint: CGPoint, in window: NSWindow, alwaysTitle: String,
                     onChoice: @escaping @MainActor (Choice, Bool) -> Void) {
        guard let view = window.contentView else { return }
        let content = PromptView(fileCount: fileCount, alwaysTitle: alwaysTitle)
        var done = false
        let finish: @MainActor (Choice, Bool) -> Void = { [weak self] choice, always in
            guard !done else { return }
            done = true
            if choice != .leave || always { Self.lastChoice = choice }
            self?.popover?.close()
            onChoice(choice, always)
        }
        content.onChoice = finish
        let p = SQPopover(contentView: content)
        p.mode = .transient
        p.onClose = { [weak self] in
            self?.popover = nil
            finish(.leave, false)
        }
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        let anchor = view.convert(inWindow, from: nil)
        popover = p
        p.show(relativeTo: CGRect(x: anchor.x - 1, y: anchor.y - 1, width: 2, height: 2), of: view, preferredEdge: .maxY)
    }

    public func close() { popover?.close() }
}

@MainActor
private final class PromptView: NSView {
    var onChoice: (@MainActor (MediaPlacementPrompt.Choice, Bool) -> Void)?
    private let always: SQCheckbox
    private let title: NSTextField

    init(fileCount: Int, alwaysTitle: String) {
        always = SQCheckbox(title: alwaysTitle, target: nil, action: nil)
        title = NSTextField(labelWithString: fileCount == 1 ? "This file is outside the project folder"
                                                           : "These \(fileCount) files are outside the project folder")
        super.init(frame: .zero)
        title.font = Theme.Typography.bodyStrong
        title.textColor = Theme.Colors.label

        let defaultChoice = MediaPlacementPrompt.lastChoice
        func button(_ text: String, _ choice: MediaPlacementPrompt.Choice, _ tip: String) -> SQButton {
            let b = SQButton(title: text, target: self, action: #selector(pressed(_:)))
            b.style = choice == defaultChoice ? .accent : .standard
            b.identifier = NSUserInterfaceItemIdentifier(choice.rawValue)
            b.toolTip = tip
            return b
        }
        let row = NSStackView(views: [
            button("Copy into project (V)", .copy, "Copy into Files/Imported and use the copy"),
            button("Move into project (X)", .move, "Copy into Files/Imported, use the copy, then move the original to the Trash"),
            button("Leave where it is (L)", .leave, "Keep using the file at its place"),
        ])
        row.orientation = .horizontal
        row.spacing = Theme.Spacing.sm
        let column = NSStackView(views: [title, row, always])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Theme.Spacing.sm
        column.edgeInsets = NSEdgeInsets(top: Theme.Spacing.md, left: Theme.Spacing.md, bottom: Theme.Spacing.md, right: Theme.Spacing.md)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
        ])
        frame.size = column.fittingSize
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { nil }

    @objc private func pressed(_ sender: SQButton) {
        guard let id = sender.identifier?.rawValue, let c = MediaPlacementPrompt.Choice(rawValue: id) else { return }
        onChoice?(c, always.state == .on)
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        return handle(event)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let choice: MediaPlacementPrompt.Choice
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": choice = .copy
        case "x": choice = .move
        case "l": choice = .leave
        case "\r", "\u{3}": choice = MediaPlacementPrompt.lastChoice
        default: return false
        }
        onChoice?(choice, always.state == .on)
        return true
    }
}

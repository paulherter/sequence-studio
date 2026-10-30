import AppKit
import SQCore

/// Find and replace on the caption track: find field with match count and previous / next, replace field with
/// Replace and Replace All, Match Case. Stays open while the timeline is used (close: Esc or the close button), so
/// matches can be walked and fixed one after the other. All logic is `CaptionSearchModel`.
@MainActor
final class CaptionSearchPopup: NSObject, NSSearchFieldDelegate, NSTextFieldDelegate {
    private(set) var model: CaptionSearchModel
    /// The timeline to search and the playhead (the first match shown is the one at or after it).
    var timeline: () -> Timeline = { Timeline(name: "", frameDuration: Time(1, 30), tracks: []) }
    var playhead: () -> Time = { .zero }
    /// Return, Next, Previous or Replace went to this match: select it, move the playhead to it, bring it on screen.
    var onShowMatch: ((CaptionTextMatch) -> Void)?
    /// Typing found this match: mark it only. The playhead and the scroll position stay while the user types.
    var onHighlightMatch: ((CaptionTextMatch) -> Void)?
    /// False until the current match was gone to: the first Return or Next goes to it, later ones step on.
    private var visited = false
    /// "N replaced", shown in place of the match count until the next action in the popup.
    private var notice: String?
    /// A replace produced this timeline (one undo step with this name).
    var onReplace: ((Timeline, String) -> Void)?
    var onClose: (() -> Void)?

    static let width: CGFloat = 356
    private let content = NSView()
    private let findField = SQSearchField()
    private let replaceField = SQTextField(string: "")
    private let countLabel = NSTextField(labelWithString: "")
    private lazy var previousButton = SQButton(symbol: .chevronUp, label: "Previous Match", target: self, action: #selector(previous))
    private lazy var nextButton = SQButton(symbol: .chevronDown, label: "Next Match", target: self, action: #selector(next))
    private lazy var closeButton = SQButton(symbol: .close, label: "Close", target: self, action: #selector(closePopup))
    private lazy var replaceButton = SQButton(title: "Replace", target: self, action: #selector(replaceOne), style: .standard)
    private lazy var replaceAllButton = SQButton(title: "Replace All", target: self, action: #selector(replaceAll), style: .standard)
    private lazy var caseBox = SQCheckbox(title: "Match Case", target: self, action: #selector(caseChanged))
    private var popover: SQPopover?

    init(model: CaptionSearchModel = CaptionSearchModel()) {
        self.model = model
        super.init()
        build()
    }

    var isShown: Bool { popover?.isShown ?? false }

    func show(relativeTo rect: CGRect, of view: NSView) {
        if isShown { focusFind(); return }
        let p = SQPopover(contentView: content)
        p.mode = .applicationDefined
        p.onClose = { [weak self] in self?.popover = nil; self?.onClose?() }
        popover = p
        p.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        refresh(highlight: false)
        focusFind()
    }

    func close() { popover?.close() }

    private func focusFind() {
        findField.window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    /// The timeline changed under the popup (an edit, undo): search again, keep the place.
    func timelineChanged() {
        guard isShown else { return }
        resync()
    }

    /// Searches the timeline again. A "N replaced" notice stays: this runs inside the replace that set it.
    func resync() {
        model.refresh(in: timeline(), from: playhead())
        syncControls()
    }

    private func build() {
        let pad = Theme.Spacing.md, gap = Theme.Spacing.sm, h = Theme.Metrics.quietField, icon: CGFloat = 22
        let w = Self.width
        let height = pad + h + gap + h + gap + h + pad
        content.frame = CGRect(x: 0, y: 0, width: w, height: height)
        // Unflipped content: row 1 on top.
        let y1 = height - pad - h, y2 = y1 - gap - h, y3 = y2 - gap - h
        var right = w - pad
        for b in [closeButton, nextButton, previousButton] {
            b.frame = CGRect(x: right - icon, y: y1, width: icon, height: h)
            right -= icon + Theme.Spacing.xs
            content.addSubview(b)
        }
        right -= gap - Theme.Spacing.xs
        let countWidth: CGFloat = 64
        countLabel.font = Theme.Typography.tabularBody
        countLabel.textColor = Theme.Colors.label3
        countLabel.alignment = .right
        countLabel.frame = CGRect(x: right - countWidth, y: y1 + 3, width: countWidth, height: h - 6)
        content.addSubview(countLabel)
        findField.frame = CGRect(x: pad, y: y1, width: right - countWidth - gap - pad, height: h)
        findField.setQuietPlaceholder("Find in captions")
        findField.delegate = self
        findField.sendsSearchStringImmediately = true
        findField.setAccessibilityLabel("Find in captions")
        content.addSubview(findField)

        let allWidth = max(replaceAllButton.intrinsicContentSize.width, 84), oneWidth = max(replaceButton.intrinsicContentSize.width, 68)
        replaceAllButton.frame = CGRect(x: w - pad - allWidth, y: y2, width: allWidth, height: h)
        replaceButton.frame = CGRect(x: replaceAllButton.frame.minX - gap - oneWidth, y: y2, width: oneWidth, height: h)
        replaceField.frame = CGRect(x: pad, y: y2, width: replaceButton.frame.minX - gap - pad, height: h)
        replaceField.placeholderAttributedString = NSAttributedString(string: "Replace with", attributes: [
            .font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3])
        replaceField.delegate = self
        replaceField.setAccessibilityLabel("Replace with")
        for v in [replaceField, replaceButton, replaceAllButton] as [NSView] { content.addSubview(v) }

        caseBox.frame = CGRect(x: pad, y: y3, width: 160, height: h)
        content.addSubview(caseBox)
        findField.nextKeyView = replaceField
        replaceField.nextKeyView = findField
        syncControls()
    }

    private func syncControls() {
        countLabel.stringValue = notice ?? model.countLabel
        let has = !model.matches.isEmpty
        previousButton.isEnabled = has
        nextButton.isEnabled = has
        replaceButton.isEnabled = model.canReplace
        replaceAllButton.isEnabled = has && model.find != model.replacement
        caseBox.state = model.caseSensitive ? .on : .off
    }

    /// Takes the fields into the model and searches. `highlight`: the search text changed, so the match to go to is
    /// marked (count and highlight only; nothing seeks or scrolls while typing).
    private func refresh(highlight: Bool) {
        model.find = findField.stringValue
        model.replacement = replaceField.stringValue
        model.refresh(in: timeline(), from: playhead())
        if highlight {
            notice = nil
            visited = false
        }
        syncControls()
        if highlight, let m = model.currentMatch { onHighlightMatch?(m) }
    }

    // MARK: Actions

    @objc private func next() { step(forward: true) }
    @objc private func previous() { step(forward: false) }
    private func step(forward: Bool) {
        notice = nil
        // The match found while typing is only marked: the first Return or Next goes to it.
        if visited || !forward { model.step(forward: forward) }
        visited = true
        syncControls()
        if let m = model.currentMatch { onShowMatch?(m) }
    }

    @objc private func caseChanged() {
        model.caseSensitive = caseBox.state == .on
        refresh(highlight: true)
    }

    @objc private func replaceOne() {
        notice = nil
        model.replacement = replaceField.stringValue
        guard let out = model.replacingCurrent(in: timeline()) else { syncControls(); return }
        onReplace?(out, "Replace in Caption")
        visited = true
        syncControls()
        if let m = model.currentMatch { onShowMatch?(m) }
    }

    @objc private func replaceAll() {
        model.replacement = replaceField.stringValue
        guard let r = model.replacingAll(in: timeline()) else { notice = nil; syncControls(); return }
        // Set before the commit: the commit comes back through `timelineChanged`, which must not wipe it.
        notice = r.count == 1 ? "1 replaced" : "\(r.count) replaced"
        onReplace?(r.timeline, "Replace All in Captions")
        syncControls()
    }

    @objc private func closePopup() { close() }

    // MARK: Field delegate

    func controlTextDidChange(_ note: Notification) {
        refresh(highlight: (note.object as AnyObject?) === findField)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === findField { step(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)) }
            else { replaceOne() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default: return false
        }
    }

    // MARK: Tests

    func setFind(_ s: String) { findField.stringValue = s; refresh(highlight: true) }
    func setReplacement(_ s: String) { replaceField.stringValue = s; refresh(highlight: false) }
    func setCaseSensitive(_ on: Bool) { caseBox.state = on ? .on : .off; caseChanged() }
    func performNext() { next() }
    func performReplace() { replaceOne() }
    func performReplaceAll() { replaceAll() }
    var countText: String { countLabel.stringValue }
}

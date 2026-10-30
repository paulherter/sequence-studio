import AppKit
import Observation
import SQCore
import SQTranscribe

/// Transcribe tab of the Captions panel: Transcribe (whole sequence), language, transcript editor. Captions are created in the Captions tab.
/// Editing like Premiere: hovering marks the word, a click seeks to it, a double-click edits it, Return ends editing.
/// (Transcript editor with toolbar (DESIGN.md 3a/3b).) Real AppKit controls; state comes from `CaptionsPanelModel`.
@MainActor
public final class CaptionsPanelView: NSView, NSTextViewDelegate, NSSearchFieldDelegate {
    public let model: CaptionsPanelModel

    // Search in the transcript (the instances are marked; Return / Shift+Return move between them).
    private let searchField = SQSearchField()
    private let matchCount = NSTextField(labelWithString: "")
    private let prevHit = SQButton(symbol: .chevronUp, label: "Previous match (Shift+Return)", target: nil, action: nil, size: 10)
    private let nextHit = SQButton(symbol: .chevronDown, label: "Next match (Return)", target: nil, action: nil, size: 10)
    private let markAllButton = SQButton(title: "Mark All", target: nil, action: nil)
    /// Sets a sequence marker at every hit (the host adds them as one undo step): hit times, search text.
    public var onMarkHits: (([Time], String) -> Void)?
    private var searchTerm = ""
    private var currentMatch: NSRange?

    private let transcribeButton = SQButton(title: "Transcribe Sequence", target: nil, action: nil)
    private let languagePopUp = SQPopup(frame: .zero, pullsDown: false)
    private let progress = TranscribeProgressBar()
    private static let barRadius: CGFloat = Theme.Radius.small   // clamps to half the 2 pt bar
    private let createButton = SQButton(title: "Create Captions\u{2026}", target: nil, action: nil)
    /// Opens the Create Captions form (set by the Captions panel, which owns the look library and the session).
    public var onCreateCaptions: (() -> Void)?
    private let cancelButton = SQButton(title: "Cancel", target: nil, action: nil)
    private var progressRow = NSStackView()
    private var searchRowView = NSStackView()
    private let doneBar = NSView()
    private var languageRow = NSStackView()
    private var footerRow = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// Before the first transcript (v9 `cap-before`): what is missing, centered in the panel, instead of the status line.
    let emptyState = EmptyStateView(title: "Not transcribed yet.", hint: "The words of the sequence appear here.")
    private let scroll = NSScrollView()
    private let textView = TranscriptTextView()
    private var isApplyingModelText = false
    /// A word is being edited (double-click): the text view is editable until Return, Escape or focus loss.
    private var isEditingWord = false
    private var hoveredWord: Int?
    private var tracking = true

    public init(model: CaptionsPanelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        build()
        refresh()
        observe()
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    isolated deinit { tracking = false }

    /// The transcript editor (tests).
    var transcriptTextView: NSTextView { textView }
    var transcriptScroll: NSScrollView { scroll }
    /// A word is being typed (the field shows it: accent frame, lighter page, hint in the status line).
    var isInEditMode: Bool { isEditingWord }

    // MARK: Layout

    private func build() {
        for b in [transcribeButton] {
            b.target = self
        }
        transcribeButton.action = #selector(transcribeClicked)
        for p in [languagePopUp] {
            p.target = self
        }
        languagePopUp.action = #selector(languageChanged)
        statusLabel.font = Theme.Typography.body
        statusLabel.textColor = Theme.Colors.label3
        statusLabel.lineBreakMode = .byTruncatingTail

        let top = NSStackView(views: [transcribeButton, languagePopUp])
        top.spacing = Theme.Spacing.sm
        languageRow = top
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        doneBar.wantsLayer = true
        doneBar.layer?.backgroundColor = Theme.Colors.accentFill.cgColor
        doneBar.layer?.cornerRadius = Self.barRadius

        searchField.placeholderString = "Find in transcript"
        searchField.delegate = self
        // The action fires on Return only: Return = next match, Shift+Return = previous.
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.target = self; searchField.action = #selector(searchReturn)
        searchField.setAccessibilityLabel("Find in transcript")
        matchCount.font = Theme.Typography.body; matchCount.textColor = Theme.Colors.label3
        prevHit.target = self; prevHit.action = #selector(prevHitClicked)
        nextHit.target = self; nextHit.action = #selector(nextHitClicked)
        markAllButton.target = self; markAllButton.action = #selector(markAllClicked)
        markAllButton.sqToolTip = "Set a marker at every match, named after the search text"
        let searchRow = NSStackView(views: [searchField, matchCount, prevHit, nextHit, markAllButton])
        searchRow.spacing = Theme.Spacing.xs
        searchRowView = searchRow
        var progressParts: [NSView] = [progress, cancelButton]
        if let pip = SQMascotPlace.captionsRunning.makeView() { progressParts.insert(pip, at: 0) }   // M10
        progressRow = NSStackView(views: progressParts)
        progressRow.spacing = 10
        progressRow.alignment = .centerY

        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.Colors.panel
        textView.insertionPointColor = Theme.Colors.accent
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = Self.baseAttributes
        textView.isEditable = false
        textView.onClick = { [weak self] offset in self?.model.seek(toCharacter: offset) }
        textView.onDoubleClick = { [weak self] offset in self?.beginEditingWord(atCharacter: offset) }
        textView.onHover = { [weak self] offset in self?.hover(atCharacter: offset) }
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Theme.Radius.control

        createButton.style = .accent
        createButton.target = self
        createButton.action = #selector(createClicked)
        let footer = NSStackView(views: [NSView(), createButton])
        footer.orientation = .horizontal
        footerRow = footer
        let stack = NSStackView(views: [top, progressRow, statusLabel, searchRow, doneBar, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.sm
        // Search strip = panel header height, field centered in it.
        stack.edgeInsets = NSEdgeInsets(top: .zero, left: Theme.Spacing.sm, bottom: Theme.Spacing.sm, right: Theme.Spacing.sm)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: top.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            progressRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            doneBar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            doneBar.heightAnchor.constraint(equalToConstant: 2),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            languagePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    // MARK: Observation

    private func observe() {
        guard tracking else { return }
        withObservationTracking {
            _ = model.state; _ = model.statusNote; _ = model.transcript; _ = model.currentWordID; _ = model.language
            _ = model.languages; _ = model.presets; _ = model.selectedPresetIndex
            _ = model.needsOverwriteConfirmation; _ = model.sourceURL; _ = model.sequenceSource != nil; _ = model.isOutdated
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    /// Board: 12 px text on 22 px lines.
    static let baseAttributes: [NSAttributedString.Key: Any] = {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = 22; para.maximumLineHeight = 22
        return [.font: Theme.Typography.title, .foregroundColor: Theme.Colors.label, .paragraphStyle: para]
    }()

    @objc private func createClicked() { onCreateCaptions?() }

    private func refresh() {
        languagePopUp.removeAllItems()
        for id in model.languages {
            languagePopUp.addItem(withTitle: Locale.current.localizedString(forIdentifier: id) ?? id)
            languagePopUp.lastItem?.representedObject = id
        }
        if let i = model.languages.firstIndex(of: model.language) { languagePopUp.selectItem(at: i) }

        transcribeButton.isEnabled = model.canTranscribe && !{ if case .transcribing = model.state { return true }; return false }()
        // Like Premiere: the whole sequence (every audible clip), not a selected clip.
        // One primary button per state (board): Transcribe, (disabled) Transcribing…, Try Again, or the quiet Transcribe Again.
        var failed = false, running = false, ready = false
        switch model.state { case .failed: failed = true; case .transcribing: running = true; case .ready: ready = model.transcript != nil; default: break }
        transcribeButton.title = running ? "Transcribing…" : failed ? "Try Again" : model.transcript == nil ? "Transcribe" : "Transcribe Again"
        transcribeButton.style = (model.transcript == nil || failed) && !running ? .accent : .standard
        progressRow.isHidden = !running
        searchRowView.isHidden = !ready
        doneBar.isHidden = !ready
        footerRow.isHidden = !ready
        createButton.isEnabled = model.canCreateCaptions
        createButton.sqToolTip = model.canCreateCaptions ? nil : "The timeline changed since this transcript. Transcribe again."
        scroll.isHidden = !ready
        statusLabel.textColor = failed ? Theme.Colors.red : Theme.Colors.label3
        transcribeButton.sqToolTip = "Transcribes the speech of the whole sequence"
        languagePopUp.isEnabled = model.canTranscribe && !running
        switch model.state {
        case .idle:
            progress.isHidden = true
            statusLabel.stringValue = SQL10n.string(model.canTranscribe ? "Not transcribed yet." : "Nothing audible in this sequence.")
        case .transcribing(let p):
            progress.isHidden = false; progress.doubleValue = p
            statusLabel.stringValue = model.statusNote.map { SQL10n.string($0) + "..." } ?? SQL10n.format("Transcribing %@ %%", String(Int((p * 100).rounded())))
        case .ready:
            progress.isHidden = true
            let n = model.editedWordIDs.count
            statusLabel.stringValue = model.isOutdated
                ? SQL10n.string("The timeline changed since this transcript. Transcribe again.")
                : SQL10n.format(n > 0 ? "%@ words, %@ edited" : "%@ words", String(model.transcript?.words.count ?? 0), String(n))
        case .failed(let msg):
            progress.isHidden = true
            statusLabel.stringValue = msg.hasPrefix("Transcription failed") ? SQL10n.string(msg) : SQL10n.string("Transcription failed.") + " " + SQL10n.string(msg)
        }
        let idle = model.state == .idle
        emptyState.isHidden = !idle
        statusLabel.isHidden = idle
        if idle { emptyState.title = statusLabel.stringValue; emptyState.hint = model.canTranscribe ? "The words of the sequence appear here." : nil }
        textView.isEditable = isEditingWord && model.state == .ready
        if isEditingWord { statusLabel.stringValue = SQL10n.string(Self.editHint) }
        renderText()
        if model.needsOverwriteConfirmation { confirmOverwrite() }
    }

    private func renderText() {
        // A word is being typed: the model text is rewritten by the debounced edit, not by the view refresh.
        guard !isEditingWord else { return }
        guard let storage = textView.textStorage else { return }
        let words = model.transcript?.words ?? []
        let text = model.transcript?.text ?? ""
        isApplyingModelText = true
        defer { isApplyingModelText = false }
        let editing = window?.firstResponder === textView
        let normalisedView = textView.string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !(editing && normalisedView == text) && textView.string != text {
            let sel = textView.selectedRange()
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.baseAttributes))
            textView.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
        }
        // Word attributes only apply when the view text is the model text (not mid-edit).
        guard textView.string == text else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes, range: full)
        Self.applyWordMarks(to: storage, words: words, ranges: model.wordRanges)
        for (w, r) in zip(words, model.wordRanges) where NSMaxRange(r) <= storage.length {
            if let h = hoveredWord, !isEditingWord, h < words.count, words[h].id == w.id {
                storage.addAttributes([.backgroundColor: Theme.State.selected], range: r)
            }
            if w.id == model.currentWordID {
                storage.addAttributes([.backgroundColor: Theme.Colors.accentTint,
                                       .foregroundColor: Theme.Colors.onClip], range: r)
            }
        }
        for r in TranscriptSearch.matches(in: text, find: searchTerm, caseSensitive: false) where NSMaxRange(r) <= storage.length {
            storage.addAttribute(.backgroundColor, value: Theme.Colors.yellow.withAlphaComponent(0.35), range: r)
        }
        if let cur = currentMatch, NSMaxRange(cur) <= storage.length {
            storage.addAttributes([.backgroundColor: Theme.Colors.yellow, .foregroundColor: Theme.black(1)], range: cur)
        }
        storage.endEditing()
        updateSearchControls(text)
    }

    /// Underline marks of one word: hand-edited words yellow, unsure words (`TranscriptWord.isUnsure`) warning; unsure wins.
    static func wordMarks(for w: TranscriptWord) -> [NSAttributedString.Key: Any] {
        guard w.isEdited || w.isUnsure else { return [:] }
        return [.underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: w.isUnsure ? Theme.Colors.warning : Theme.Colors.yellow]
    }

    static func applyWordMarks(to s: NSMutableAttributedString, words: [TranscriptWord], ranges: [NSRange]) {
        for (w, r) in zip(words, ranges) where NSMaxRange(r) <= s.length {
            let m = wordMarks(for: w)
            if !m.isEmpty { s.addAttributes(m, range: r) }
        }
    }

    // MARK: Word editing (hover, double-click, Return)

    /// Index of the word whose text contains `offset` (a separator belongs to no word).
    private func wordIndex(strictlyAt offset: Int?) -> Int? {
        guard let offset else { return nil }
        return model.wordRanges.firstIndex { NSLocationInRange(offset, $0) }
    }

    private func hover(atCharacter offset: Int?) {
        guard !isEditingWord else { return }
        let i = wordIndex(strictlyAt: offset)
        guard i != hoveredWord else { return }
        hoveredWord = i
        let words = model.transcript?.words ?? []
        let unsure = i.map { $0 < words.count && words[$0].isUnsure } ?? false
        textView.sqToolTip = unsure ? Self.unsureHint : nil
        textView.setAccessibilityHelp(unsure ? Self.unsureHint : nil)
        renderText()
    }

    static let unsureHint = "Unsure word"

    static let editHint = "Editing text. Return or Esc keeps it; Cmd+Z undoes the edit."

    /// FB-Y: edit mode is visible like Premiere's text field: the whole transcript gets an accent frame and a lighter page.
    private func showEditMode(_ on: Bool) {
        scroll.layer?.borderWidth = on ? 2 : 0
        scroll.layer?.borderColor = on ? Theme.Colors.accent.cgColor : nil
        textView.backgroundColor = on ? Self.editingBackground : Theme.Colors.content
        statusLabel.textColor = on ? Theme.Colors.accent : Theme.Colors.label3
        if on { statusLabel.stringValue = SQL10n.string(Self.editHint) }
    }

    static var editingBackground: NSColor { Theme.Colors.content.blended(withFraction: 0.06, of: .white) ?? Theme.Colors.content }

    /// Double-click: the word becomes editable and selected; typing replaces it.
    func beginEditingWord(atCharacter offset: Int) {
        guard model.state == .ready, let i = wordIndex(strictlyAt: offset) ?? model.wordIndex(atCharacter: offset) else { return }
        let r = model.wordRanges[i]
        hoveredWord = nil
        renderText()                       // clears the hover mark before editing starts
        isEditingWord = true
        textView.isEditable = true
        showEditMode(true)
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(r)
    }

    private func endEditingWord() {
        guard isEditingWord else { return }
        model.flushEdits()
        isEditingWord = false
        textView.isEditable = false
        showEditMode(false)
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
        window?.makeFirstResponder(nil)
        refresh()          // status line back to the word count
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard isEditingWord else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            endEditingWord()
            return true
        }
        return false
    }

    public func textDidEndEditing(_ notification: Notification) { endEditingWord() }

    // MARK: Search

    private func updateSearchControls(_ text: String) {
        let n = TranscriptSearch.matches(in: text, find: searchTerm, caseSensitive: false).count
        matchCount.stringValue = searchTerm.isEmpty ? "" : (n == 0 ? SQL10n.string("No match") : "\(n)")
        prevHit.isEnabled = n > 0; nextHit.isEnabled = n > 0; markAllButton.isEnabled = n > 0 && !model.isOutdated
    }

    /// Moves to the next or previous match, selects it, scrolls it into view and puts the playhead on that word.
    private func stepSearch(forward: Bool) {
        let text = model.transcript?.text ?? ""
        let matches = TranscriptSearch.matches(in: text, find: searchTerm, caseSensitive: false)
        let here = currentMatch?.location ?? (forward ? textView.selectedRange().location - 1 : textView.selectedRange().location)
        guard let i = TranscriptSearch.step(matches, from: here, forward: forward) else { return }
        currentMatch = matches[i]
        matchCount.stringValue = SQL10n.format("%@ of %@", String(i + 1), String(matches.count))
        textView.scrollRangeToVisible(matches[i])
        model.seek(toCharacter: matches[i].location)
        renderText()
        matchCount.stringValue = SQL10n.format("%@ of %@", String(i + 1), String(matches.count))
    }

    @objc private func prevHitClicked() { stepSearch(forward: false) }
    @objc private func nextHitClicked() { stepSearch(forward: true) }

    /// Mark All: a marker at the start of the word each match begins in.
    @objc private func markAllClicked() {
        model.flushEdits()
        let text = model.transcript?.text ?? ""
        let times = TranscriptSearch.matches(in: text, find: searchTerm, caseSensitive: false).compactMap { r in
            model.wordIndex(atCharacter: r.location).flatMap { model.transcript?.words[$0].range.start }
        }
        guard !times.isEmpty else { return }
        onMarkHits?(times, searchTerm)
    }

    /// Return in the field: next; Shift+Return: previous.
    @objc private func searchReturn() {
        stepSearch(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        searchTerm = searchField.stringValue
        currentMatch = nil
        renderText()
    }

    // MARK: Actions

    @objc private func transcribeClicked() { model.transcribe() }
    @objc private func cancelClicked() { model.cancelTranscription() }
    @objc private func languageChanged() {
        if let id = languagePopUp.selectedItem?.representedObject as? String { model.language = id }
    }

    /// The overwrite question is open: refreshes while it is showing must not queue more sheets.
    private var overwriteSheetOpen = false

    /// The overwrite question (also used by the render harness).
    public static func makeOverwriteDialog() -> SQDialog {
        let alert = SQDialog()
        alert.messageText = "Replace the transcript?"
        alert.informativeText = "Transcribing again replaces the current transcript, including your edits. Media is not changed."
        alert.addButton("Transcribe Again")
        alert.addButton("Cancel")
        return alert
    }

    private func confirmOverwrite() {
        guard !overwriteSheetOpen else { return }
        let alert = Self.makeOverwriteDialog()
        guard let window else { model.cancelOverwrite(); return }
        overwriteSheetOpen = true
        alert.beginSheetModal(for: window) { [model, weak self] response in
            MainActor.assumeIsolated {
                self?.overwriteSheetOpen = false
                if response == .first { model.confirmOverwrite() } else { model.cancelOverwrite() }
            }
        }
    }

    // MARK: NSTextViewDelegate

    public func textDidChange(_ notification: Notification) {
        guard !isApplyingModelText else { return }
        model.textChanged(textView.string)
    }
}

/// Reports the character offset of a plain click (no drag selection) for click-to-seek.
final class TranscriptTextView: NSTextView {
    var onClick: ((Int) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    /// Character offset under the mouse; nil when it leaves the view.
    var onHover: ((Int?) -> Void)?
    private var area: NSTrackingArea?

    /// A full text stack (storage, layout manager, container). FB-M bug: replacing the container of a view made without
    /// one left it with no layout manager and no text storage, so the transcript never showed.
    private let storage = NSTextStorage()

    init() {
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 100), textContainer: container)
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let offset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if !isEditable {
            // Read-only transcript: a click seeks, a double-click starts editing that word (no native drag selection).
            if event.clickCount >= 2 { onDoubleClick?(offset) } else { onClick?(offset) }
            return
        }
        super.mouseDown(with: event)
    }
}

/// Flat determinate progress bar: `field` track, `accent` fill, radius `small`, 4 pt high (board).
@MainActor
final class TranscribeProgressBar: NSView {
    private static let radius: CGFloat = Theme.Radius.small   // clamps to half the 4 pt bar (2 px ends)
    var doubleValue: Double = 0 { didSet { if oldValue != doubleValue { needsDisplay = true } } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }
    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        Theme.Colors.fill.setFill()
        NSBezierPath(roundedRect: track, xRadius: Self.radius, yRadius: Self.radius).fill()
        var f = track; f.size.width = track.width * CGFloat(min(max(doubleValue, 0), 1))
        Theme.Colors.accentFill.setFill()
        NSBezierPath(roundedRect: f, xRadius: Self.radius, yRadius: Self.radius).fill()
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func accessibilityValue() -> Any? { doubleValue }
}

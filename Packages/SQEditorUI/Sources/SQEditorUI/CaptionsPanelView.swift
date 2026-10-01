import AppKit
import Observation
import SQCore

/// Transcript tab of the Text panel: Transcribe, language, editable transcript. Captions are created in the Captions tab.
/// (Transcript editor with toolbar (DESIGN.md 3a/3b).) Real AppKit controls; state comes from `CaptionsPanelModel`.
@MainActor
public final class CaptionsPanelView: NSView, NSTextViewDelegate, NSSearchFieldDelegate {
    public let model: CaptionsPanelModel

    // Search in the transcript (Premiere: the instances are marked, the arrows move between them).
    private let searchField = NSSearchField()
    private let matchCount = NSTextField(labelWithString: "")
    private let previousMatch = NSButton(title: "", target: nil, action: nil)
    private let nextMatch = NSButton(title: "", target: nil, action: nil)
    private var searchTerm = ""
    private var currentMatch: NSRange?

    private let transcribeButton = NSButton(title: "Transcribe", target: nil, action: nil)
    private let languagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let textView = TranscriptTextView()
    private var isApplyingModelText = false
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

    // MARK: Layout

    private func build() {
        for b in [transcribeButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = Theme.Fonts.small
            b.target = self
        }
        transcribeButton.action = #selector(transcribeClicked)
        for p in [languagePopUp] {
            p.controlSize = .small
            p.font = Theme.Fonts.small
            p.target = self
        }
        languagePopUp.action = #selector(languageChanged)
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        statusLabel.font = Theme.Fonts.small
        statusLabel.textColor = Theme.Colors.label2
        statusLabel.lineBreakMode = .byTruncatingTail

        let top = NSStackView(views: [transcribeButton, languagePopUp])
        top.spacing = Theme.Spacing.sm

        searchField.placeholderString = "Find in transcript"
        searchField.controlSize = .small; searchField.font = Theme.Fonts.small
        searchField.delegate = self
        searchField.target = self; searchField.action = #selector(searchReturn)
        searchField.setAccessibilityLabel("Find in transcript")
        matchCount.font = Theme.Fonts.small; matchCount.textColor = Theme.Colors.label3
        for (b, symbol, tip, sel) in [(previousMatch, "chevron.up", "Previous match (Shift+Return)", #selector(searchPrevious)),
                                      (nextMatch, "chevron.down", "Next match (Return)", #selector(searchNext))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.bezelStyle = .rounded; b.controlSize = .small; b.toolTip = tip
            b.target = self; b.action = sel
            b.isEnabled = false
        }
        let searchRow = NSStackView(views: [searchField, matchCount, previousMatch, nextMatch])
        searchRow.spacing = Theme.Spacing.xs
        let status = NSStackView(views: [progress, statusLabel])
        status.spacing = Theme.Spacing.sm

        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.Colors.content
        textView.insertionPointColor = Theme.Colors.accent
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = Self.baseAttributes
        textView.onClick = { [weak self] offset in self?.model.seek(toCharacter: offset) }
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let stack = NSStackView(views: [top, searchRow, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.sm
        stack.edgeInsets = NSEdgeInsets(top: Theme.Spacing.sm, left: Theme.Spacing.sm, bottom: Theme.Spacing.sm, right: Theme.Spacing.sm)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            progress.widthAnchor.constraint(equalToConstant: 120),
        ])
    }

    // MARK: Observation

    private func observe() {
        guard tracking else { return }
        withObservationTracking {
            _ = model.state; _ = model.statusNote; _ = model.transcript; _ = model.currentWordID; _ = model.language
            _ = model.languages; _ = model.presets; _ = model.selectedPresetIndex
            _ = model.needsOverwriteConfirmation; _ = model.sourceURL
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.Colors.label,
    ]

    private func refresh() {
        languagePopUp.removeAllItems()
        for id in model.languages {
            languagePopUp.addItem(withTitle: Locale.current.localizedString(forIdentifier: id) ?? id)
            languagePopUp.lastItem?.representedObject = id
        }
        if let i = model.languages.firstIndex(of: model.language) { languagePopUp.selectItem(at: i) }

        transcribeButton.isEnabled = model.canTranscribe
        transcribeButton.title = model.transcript == nil ? "Transcribe" : "Re-transcribe"
        languagePopUp.isEnabled = model.canTranscribe
        switch model.state {
        case .idle:
            progress.isHidden = true
            statusLabel.stringValue = model.sourceURL == nil ? "Select a clip to transcribe." : "Not transcribed yet."
        case .transcribing(let p):
            progress.isHidden = false; progress.doubleValue = p
            statusLabel.stringValue = model.statusNote.map { $0 + "..." } ?? "Transcribing \(Int((p * 100).rounded())) %"
        case .ready:
            progress.isHidden = true
            let n = model.editedWordIDs.count
            statusLabel.stringValue = "\(model.transcript?.words.count ?? 0) words" + (n > 0 ? ", \(n) edited" : "")
        case .failed(let msg):
            progress.isHidden = true
            statusLabel.stringValue = msg
        }
        textView.isEditable = model.state == .ready
        renderText()
        if model.needsOverwriteConfirmation { confirmOverwrite() }
    }

    private func renderText() {
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
        for (w, r) in zip(words, model.wordRanges) where NSMaxRange(r) <= storage.length {
            if w.isEdited {
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .underlineColor: Theme.Colors.yellow], range: r)
            }
            if w.id == model.currentWordID {
                storage.addAttributes([.backgroundColor: Theme.Colors.accentTint,
                                       .foregroundColor: NSColor.white], range: r)
            }
        }
        for r in TranscriptSearch.matches(in: text, find: searchTerm, caseSensitive: false) where NSMaxRange(r) <= storage.length {
            storage.addAttribute(.backgroundColor, value: Theme.Colors.yellow.withAlphaComponent(0.35), range: r)
        }
        if let cur = currentMatch, NSMaxRange(cur) <= storage.length {
            storage.addAttributes([.backgroundColor: Theme.Colors.yellow, .foregroundColor: NSColor.black], range: cur)
        }
        storage.endEditing()
        updateSearchControls(text)
    }

    // MARK: Search

    private func updateSearchControls(_ text: String) {
        let n = TranscriptSearch.matches(in: text, find: searchTerm, caseSensitive: false).count
        previousMatch.isEnabled = n > 0; nextMatch.isEnabled = n > 0
        matchCount.stringValue = searchTerm.isEmpty ? "" : (n == 0 ? "No match" : "\(n)")
    }

    /// Moves to the next or previous match, selects it, scrolls it into view and puts the playhead on that word.
    private func stepSearch(forward: Bool) {
        let text = model.transcript?.text ?? ""
        let matches = TranscriptSearch.matches(in: text, find: searchTerm, caseSensitive: false)
        let here = currentMatch?.location ?? (forward ? textView.selectedRange().location - 1 : textView.selectedRange().location)
        guard let i = TranscriptSearch.step(matches, from: here, forward: forward) else { return }
        currentMatch = matches[i]
        matchCount.stringValue = "\(i + 1) of \(matches.count)"
        textView.scrollRangeToVisible(matches[i])
        model.seek(toCharacter: matches[i].location)
        renderText()
        matchCount.stringValue = "\(i + 1) of \(matches.count)"
    }

    @objc private func searchNext() { stepSearch(forward: true) }
    @objc private func searchPrevious() { stepSearch(forward: false) }
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
    @objc private func languageChanged() {
        if let id = languagePopUp.selectedItem?.representedObject as? String { model.language = id }
    }

    private func confirmOverwrite() {
        let alert = NSAlert()
        alert.messageText = "Replace the transcript?"
        alert.informativeText = "Transcribing again replaces the current transcript, including your edits. Media is not changed."
        alert.addButton(withTitle: "Transcribe Again")
        alert.addButton(withTitle: "Cancel")
        guard let window else { model.cancelOverwrite(); return }
        alert.beginSheetModal(for: window) { [model] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { model.confirmOverwrite() } else { model.cancelOverwrite() }
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

    init() {
        super.init(frame: .zero, textContainer: nil)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        replaceTextContainer(container)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if selectedRange().length == 0, event.clickCount == 1 {
            onClick?(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
        }
    }
}

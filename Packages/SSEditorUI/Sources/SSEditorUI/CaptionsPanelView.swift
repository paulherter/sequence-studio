import AppKit
import Observation
import SSCore

/// Transcript editor with toolbar (DESIGN.md 3a/3b). Real AppKit controls; state comes from `CaptionsPanelModel`.
@MainActor
public final class CaptionsPanelView: NSView, NSTextViewDelegate {
    public let model: CaptionsPanelModel

    private let transcribeButton = NSButton(title: "Transcribe", target: nil, action: nil)
    private let languagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let presetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let createButton = NSButton(title: "Create Captions", target: nil, action: nil)
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
        for b in [transcribeButton, createButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = Theme.Fonts.small
            b.target = self
        }
        transcribeButton.action = #selector(transcribeClicked)
        createButton.action = #selector(createClicked)
        createButton.keyEquivalent = "\r"
        for p in [languagePopUp, presetPopUp] {
            p.controlSize = .small
            p.font = Theme.Fonts.small
            p.target = self
        }
        languagePopUp.action = #selector(languageChanged)
        presetPopUp.action = #selector(presetChanged)
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        statusLabel.font = Theme.Fonts.small
        statusLabel.textColor = Theme.Colors.label2
        statusLabel.lineBreakMode = .byTruncatingTail

        let top = NSStackView(views: [transcribeButton, languagePopUp])
        top.spacing = Theme.Spacing.sm
        let bottom = NSStackView(views: [presetPopUp, NSView(), createButton])
        bottom.spacing = Theme.Spacing.sm
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

        let stack = NSStackView(views: [top, scroll, status, bottom])
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
            status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Theme.Spacing.sm),
            progress.widthAnchor.constraint(equalToConstant: 120),
        ])
    }

    // MARK: Observation

    private func observe() {
        guard tracking else { return }
        withObservationTracking {
            _ = model.state; _ = model.transcript; _ = model.currentWordID; _ = model.language
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
        presetPopUp.removeAllItems()
        presetPopUp.addItems(withTitles: model.presets.map(\.name))
        if model.presets.indices.contains(model.selectedPresetIndex) { presetPopUp.selectItem(at: model.selectedPresetIndex) }

        transcribeButton.isEnabled = model.canTranscribe
        transcribeButton.title = model.transcript == nil ? "Transcribe" : "Re-transcribe"
        languagePopUp.isEnabled = model.canTranscribe
        createButton.isEnabled = model.canCreateCaptions
        switch model.state {
        case .idle:
            progress.isHidden = true
            statusLabel.stringValue = model.sourceURL == nil ? "Select a clip to transcribe." : "Not transcribed yet."
        case .transcribing(let p):
            progress.isHidden = false; progress.doubleValue = p
            statusLabel.stringValue = "Transcribing \(Int((p * 100).rounded())) %"
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
        storage.endEditing()
    }

    // MARK: Actions

    @objc private func transcribeClicked() { model.transcribe() }
    @objc private func createClicked() { model.createCaptions() }
    @objc private func languageChanged() {
        if let id = languagePopUp.selectedItem?.representedObject as? String { model.language = id }
    }
    @objc private func presetChanged() { model.selectedPresetIndex = presetPopUp.indexOfSelectedItem }

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

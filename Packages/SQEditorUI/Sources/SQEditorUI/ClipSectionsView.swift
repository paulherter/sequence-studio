import AppKit
import SQAudioFX
import SQCore
import SQText

/// Scrolls a self-sizing inspector (a view whose content is one top-pinned NSStackView) vertically.
@MainActor
final class InspectorScroll: NSScrollView {
    private final class Flipped: NSView { override var isFlipped: Bool { true } }

    init(content: NSView) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        let doc = Flipped()
        doc.translatesAutoresizingMaskIntoConstraints = false
        documentView = doc
        content.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: doc.topAnchor),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        if let stack = content.subviews.compactMap({ $0 as? NSStackView }).first {
            content.bottomAnchor.constraint(equalTo: stack.bottomAnchor).isActive = true
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Places a self-sizing inspector at a given width and reports the height it needs.
@MainActor
private final class FitHost: NSView {
    let content: NSView
    private let width: NSLayoutConstraint

    override var isFlipped: Bool { true }

    init(content: NSView) {
        self.content = content
        width = content.widthAnchor.constraint(equalToConstant: 280)
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            width,
        ])
        if let stack = content.subviews.compactMap({ $0 as? NSStackView }).first {
            content.bottomAnchor.constraint(equalTo: stack.bottomAnchor).isActive = true
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func height(forWidth w: CGFloat) -> CGFloat {
        width.constant = max(w, 1)
        content.layoutSubtreeIfNeeded()
        return ceil(content.fittingSize.height)
    }
}

/// The Text or Audio section of Effect Controls (Premiere): for a text clip the text field and style controls, for an
/// audio clip the track preset, noise reduction and compressor. Shown above Motion / Volume. Every edit goes through
/// `EditorSession` (one undo step per gesture).
///
/// Not undoable and not persisted yet: the track audio preset (`audioPresets`, the engine has no FX hook).
@MainActor
public final class ClipSectionsView: NSView, NSTextViewDelegate {
    public let session: EditorSession
    /// Track audio preset chosen here, by track. Forwarded to the audio engine via `onAudioPresetChange`.
    public private(set) var audioPresets: [Track.ID: TrackAudioPreset] = [:]
    public var onAudioPresetChange: ((Track.ID, TrackAudioPreset) -> Void)?
    /// One of the six align buttons of the Text section: the host moves the selected text clip against the frame.
    public var onAlignToFrame: ((FrameAlignment) -> Void)?
    /// The height this view wants changed (another section or another track); the host re-lays out.
    public var onHeightChange: (() -> Void)?
    public private(set) var mode: ClipSectionMode = .none

    static let headerHeight: CGFloat = 24
    private static let editorHeight: CGFloat = 64

    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "")

    // Text
    private let textModel = TextInspectorModel()
    private lazy var textHost = FitHost(content: TextInspectorView(model: textModel))
    private let textEditor = NSTextView()
    private let textEditorScroll = NSScrollView()
    private var textClipID: Clip.ID?
    private var textTemplate: TextTemplate?
    private var textGestureOpen = false

    // Audio
    private var audioModels: [Track.ID: TrackAudioInspectorModel] = [:]
    private var audioHosts: [Track.ID: FitHost] = [:]
    private var audioTrackID: Track.ID?

    public override var isFlipped: Bool { true }

    public init(session: EditorSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 0))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.Colors.titlebar.cgColor
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = Theme.Colors.label
        header.addSubview(titleLabel)
        addSubview(header)
        buildTextEditor()
        wireText()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Clip section")
        sync([.project, .selection])
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    // MARK: Session to UI

    public func sync(_ change: EditorSession.Change) {
        guard change.contains(.project) || change.contains(.selection) else { return }
        let clip = session.singleSelectedClip
        pruneAudio()
        let new = ClipSectionMode.resolve(clip)
        var changed = new != mode
        switch new {
        case .text: if let clip { loadText(clip) }
        case .audio:
            if let clip {
                let before = audioTrackID
                loadAudio(clip)
                changed = changed || before != audioTrackID
            }
        case .none: break
        }
        mode = new
        titleLabel.stringValue = new.title
        isHidden = new == .none
        textEditorScroll.isHidden = new != .text
        textHost.isHidden = new != .text
        for (id, h) in audioHosts { h.isHidden = !(new == .audio && id == audioTrackID) }
        needsLayout = true
        if changed { onHeightChange?() }
    }

    /// Height for `width`; 0 when no section applies.
    public func preferredHeight(for width: CGFloat) -> CGFloat {
        let pad = Theme.Spacing.md
        switch mode {
        case .none: return 0
        case .text: return Self.headerHeight + Self.editorHeight + 2 * pad + textHost.height(forWidth: width)
        case .audio:
            guard let id = audioTrackID, let h = audioHosts[id] else { return Self.headerHeight }
            return Self.headerHeight + h.height(forWidth: width)
        }
    }

    public override func layout() {
        super.layout()
        let pad = Theme.Spacing.md
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        titleLabel.frame = CGRect(x: 10, y: (Self.headerHeight - 14) / 2, width: max(bounds.width - 20, 0), height: 14)
        var y = Self.headerHeight
        switch mode {
        case .none: break
        case .text:
            textEditorScroll.frame = CGRect(x: pad, y: y + pad, width: max(bounds.width - 2 * pad, 0), height: Self.editorHeight)
            y += Self.editorHeight + 2 * pad
            textHost.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(bounds.height - y, 0))
        case .audio:
            if let id = audioTrackID, let h = audioHosts[id] {
                h.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(bounds.height - y, 0))
            }
        }
    }

    // MARK: Text

    private func buildTextEditor() {
        textEditor.font = Theme.Fonts.small
        textEditor.textColor = Theme.Colors.label
        textEditor.drawsBackground = true
        textEditor.backgroundColor = Theme.Colors.field
        textEditor.insertionPointColor = Theme.Colors.label
        textEditor.isRichText = false
        textEditor.allowsUndo = false           // undo belongs to the project history
        textEditor.isAutomaticQuoteSubstitutionEnabled = false
        textEditor.isVerticallyResizable = true
        textEditor.autoresizingMask = [.width]
        textEditor.textContainerInset = NSSize(width: 4, height: 4)
        textEditor.delegate = self
        textEditorScroll.documentView = textEditor
        textEditorScroll.hasVerticalScroller = true
        textEditorScroll.borderType = .lineBorder
        textEditor.setAccessibilityLabel("Text")
        addSubview(textEditorScroll)
        addSubview(textHost)
        textEditorScroll.isHidden = true
        textHost.isHidden = true
    }

    private func wireText() {
        textModel.onBeginEditing = { [weak self] in self?.textGestureOpen = false }
        textModel.onChange = { [weak self] style, anims in
            guard let self, let id = textClipID, var t = textTemplate else { return }
            t.style = style
            textTemplate = t
            session.updateTextClip(id, template: t, animations: anims, continuesGesture: textGestureOpen)
            textGestureOpen = true
        }
        textModel.onEndEditing = { [weak self] in self?.textGestureOpen = false }
        textModel.onAlignToFrame = { [weak self] a in self?.onAlignToFrame?(a) }
    }

    /// Drops the audio inspectors of tracks that no longer exist (their ids could come back with other settings).
    private func pruneAudio() {
        let live = Set(session.activeTimeline?.tracks.map(\.id) ?? [])
        for id in Array(audioHosts.keys) where !live.contains(id) {
            audioHosts[id]?.removeFromSuperview()
            audioHosts[id] = nil; audioModels[id] = nil; audioPresets[id] = nil
        }
        if let id = audioTrackID, !live.contains(id) { audioTrackID = nil }
    }

    private func loadText(_ clip: Clip) {
        guard let ref = clip.generator, let (t, anims) = try? TextGenerator.decode(ref) else {
            textClipID = nil; textTemplate = nil; textEditor.string = ""      // undecodable: never edit the previous clip
            return
        }
        let changedClip = textClipID != clip.id
        textClipID = clip.id
        if t != textTemplate || changedClip {
            textTemplate = t
            textModel.load(style: t.style, animations: anims ?? AnimationSet(in: nil, out: nil))
        }
        if textEditor.string != t.text, changedClip || window?.firstResponder !== textEditor {
            textEditor.string = t.text
        }
    }

    public func textDidBeginEditing(_ notification: Notification) { textGestureOpen = false }
    public func textDidEndEditing(_ notification: Notification) { textGestureOpen = false }

    public func textDidChange(_ notification: Notification) {
        guard let id = textClipID, var t = textTemplate, t.text != textEditor.string else { return }
        t.text = textEditor.string
        textTemplate = t
        session.updateTextClip(id, template: t, animations: textModel.animations, continuesGesture: textGestureOpen)
        textGestureOpen = true
    }

    // MARK: Audio

    private func loadAudio(_ clip: Clip) {
        guard let track = session.activeTimeline?.tracks.first(where: { $0.clips.contains { $0.id == clip.id } }) else {
            audioTrackID = nil
            return
        }
        audioTrackID = track.id
        if audioHosts[track.id] == nil {
            let model = TrackAudioInspectorModel(preset: audioPresets[track.id] ?? .off)
            model.onChange = { [weak self] preset in
                self?.audioPresets[track.id] = preset
                self?.onAudioPresetChange?(track.id, preset)
            }
            let view = TrackAudioInspectorView(model: model)
            view.note = "Applied to the track during playback. Not saved with the project yet."
            audioModels[track.id] = model
            let host = FitHost(content: view)
            audioHosts[track.id] = host
            addSubview(host)
        }
    }
}

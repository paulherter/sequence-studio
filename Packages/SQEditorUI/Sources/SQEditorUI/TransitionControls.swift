import AppKit
import SQCore

/// Effect Controls content while a transition is selected: its name, Duration (timecode) and Alignment.
@MainActor
public final class TransitionControlsView: NSView {
    public var onDuration: ((Time) -> Void)?
    public var onAlignment: ((TransitionAlignment) -> Void)?

    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let durationField = NSTextField(string: "")
    private let alignmentPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var frameDuration = Time(1, 30)
    private var shownDuration = Time.zero

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        title.font = Theme.Fonts.bodyTitle; title.textColor = Theme.Colors.label
        subtitle.font = Theme.Fonts.small; subtitle.textColor = Theme.Colors.label3
        note.font = Theme.Fonts.small; note.textColor = Theme.Colors.label3
        note.isHidden = true
        durationField.font = Theme.Fonts.body
        durationField.alignment = .right
        durationField.target = self; durationField.action = #selector(durationEdited)
        durationField.setAccessibilityLabel("Transition duration")
        alignmentPopUp.target = self; alignmentPopUp.action = #selector(alignmentPicked)
        alignmentPopUp.setAccessibilityLabel("Transition alignment")
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = Theme.Fonts.small; l.textColor = Theme.Colors.label2
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return l
        }
        let dRow = NSStackView(views: [label("Duration"), durationField]); dRow.spacing = Theme.Spacing.sm
        let aRow = NSStackView(views: [label("Alignment"), alignmentPopUp]); aRow.spacing = Theme.Spacing.sm
        durationField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let stack = NSStackView(views: [title, subtitle, dRow, aRow, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = Theme.Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.lg),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.lg),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Spacing.lg),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Transition controls")
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    private var timecode: Timecode { Timecode(frameDuration: frameDuration, dropFrame: false) }

    /// Shows a transition (nil = nothing). `resolved` nil means its cut is gone.
    public func update(transition: Transition?, resolved: ResolvedTransition?, frameDuration fd: Time) {
        guard let tr = transition else { return }
        frameDuration = fd
        title.stringValue = tr.kind.name
        subtitle.stringValue = tr.kind.trackKind == .video ? "Video Transition" : "Audio Transition"
        shownDuration = resolved?.duration ?? tr.duration
        durationField.stringValue = timecode.format(shownDuration)
        alignmentPopUp.removeAllItems()
        var options: [TransitionAlignment] = tr.isSingleSided ? [] : [.center, .startAtCut, .endAtCut]
        if tr.alignment == .custom { options.append(.custom) }
        for o in options { alignmentPopUp.addItem(withTitle: o.name); alignmentPopUp.lastItem?.representedObject = o.rawValue }
        if let i = options.firstIndex(of: tr.alignment) { alignmentPopUp.selectItem(at: i) }
        alignmentPopUp.isEnabled = !tr.isSingleSided
        if let r = resolved, r.isClamped {
            note.stringValue = "Shortened: the clips do not have enough media beyond the cut for the full length."
            note.isHidden = false
        } else {
            note.isHidden = true
        }
    }

    @objc private func durationEdited() {
        guard let t = timecode.parse(durationField.stringValue), t > .zero else {
            durationField.stringValue = timecode.format(shownDuration)
            return
        }
        onDuration?(t)
    }

    @objc private func alignmentPicked() {
        guard let raw = alignmentPopUp.selectedItem?.representedObject as? String, let a = TransitionAlignment(rawValue: raw) else { return }
        onAlignment?(a)
    }
}

/// Effect Controls with the transition view laid over it while a transition is selected.
@MainActor
public final class EffectControlsContainerView: NSView {
    public let effects: EffectControlsView
    public let transition: TransitionControlsView

    public init(effects: EffectControlsView, transition: TransitionControlsView) {
        self.effects = effects; self.transition = transition
        super.init(frame: effects.frame)
        for v in [effects, transition] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
                                         v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor)])
        }
        transition.isHidden = true
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    public var showsTransition: Bool {
        get { !transition.isHidden }
        set { transition.isHidden = !newValue; effects.isHidden = newValue }
    }
}

/// "Set Transition Duration" (double-click on a transition): a small sheet with the duration as timecode.
@MainActor
public enum TransitionDurationSheet {
    public static func present(on window: NSWindow?, name: String, duration: Time, frameDuration fd: Time,
                               completion: @escaping (Time) -> Void) {
        let tc = Timecode(frameDuration: fd, dropFrame: false)
        let alert = NSAlert()
        alert.messageText = "Set Transition Duration"
        alert.informativeText = name + ". Type a timecode, or digits for frames and seconds (101 is 1 second, 1 frame)."
        let field = NSTextField(string: tc.format(duration))
        field.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        field.alignment = .right
        field.setAccessibilityLabel("Duration")
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn, let t = tc.parse(field.stringValue), t > .zero else { return }
            completion(t)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}

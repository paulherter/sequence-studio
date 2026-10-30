import AppKit

/// The one modal shell (windows proposal section 1, `Theme.Modal`): a card centered over the whole main window, which is
/// dimmed by a 35 % black scrim that swallows every click. `SQDialog` (alerts, name prompts, tool forms) and every later
/// window (About, Settings, Sequence Settings, Export...) present through it. The shell is a borderless child window of the main
/// window whose frame equals the window frame: the window stays blocked and `attachedSheet` keeps working, but nothing
/// slides in from the top and the card sits in the middle.
///
/// This file holds the pure parts (sizes, placement, key routing) and the scrim view; `SQDialogWindow` is the window.
public enum SQModal {
    /// Card sizes: XS 360 (one or two fields), S 440 (alerts, prompts, forms), S with a list 480, M 600, L 860 x 640.
    /// Every dialog takes its width from here (`alert.width = SQModal.Size.s.width`); `scripts/lint-ui.sh` rejects a raw number.
    public enum Size: Sendable, Equatable {
        case xs, s, sList, m, l

        public var width: CGFloat {
            switch self {
            case .xs: Theme.Modal.widthXS
            case .s: Theme.Modal.widthS
            case .sList: Theme.Modal.widthSList
            case .m: Theme.Modal.widthM
            case .l: Theme.Modal.widthL
            }
        }
        /// Fixed height; nil: the card is as high as its content.
        public var height: CGFloat? { self == .l ? Theme.Modal.heightL : nil }
        /// Form label column of this size.
        public var labelColumn: CGFloat { self == .l ? Theme.Modal.labelColumnL : Theme.Modal.labelColumn }
    }

    /// Frame of a card of `size` centered in `bounds`; a card larger than the window keeps `edgeMargin` free on each side.
    public static func cardFrame(size: NSSize, in bounds: NSRect) -> NSRect {
        let m = Theme.Modal.edgeMargin
        let w = min(size.width, max(bounds.width - m * 2, 0))
        let h = min(size.height, max(bounds.height - m * 2, 0))
        return NSRect(x: bounds.minX + ((bounds.width - w) / 2).rounded(), y: bounds.minY + ((bounds.height - h) / 2).rounded(),
                      width: w, height: h)
    }

    /// True while a text field (its field editor) has the keyboard.
    public static func isEditingText(_ responder: NSResponder?) -> Bool { responder is NSTextView }

    /// Text and number inputs under `view`. A dialog with a single input is a prompt (Return confirms it at once);
    /// with several inputs it is a form (Return commits the field being edited first).
    @MainActor public static func inputCount(in view: NSView?) -> Int {
        guard let view else { return 0 }
        if view is ScrubField { return 1 }
        if let f = view as? NSTextField { return f.isEditable ? 1 : 0 }
        return view.subviews.reduce(0) { $0 + inputCount(in: $1) }
    }

    /// Return in an editing field of a form: the field takes the key (commits), then gives up the keyboard so the
    /// next Return confirms the dialog.
    @MainActor public static func endEditingAfterCommit(in window: NSWindow) {
        if isEditingText(window.firstResponder) { window.makeFirstResponder(nil) }
    }

    /// Escape in an editing field: drop the edit, keep the dialog. Returns true when it handled the key.
    @MainActor public static func abortEditing(in window: NSWindow) -> Bool {
        guard isEditingText(window.firstResponder) else { return false }
        if let t = window.firstResponder as? NSTextView, let f = t.delegate as? NSTextField { f.abortEditing() }
        window.makeFirstResponder(nil)
        return true
    }

    /// The response a key press triggers, nil when the key is not a dialog key. One place for every modal:
    /// Return = the focused button, else the main action (never a destructive one: see `SQDialogModel.returnIndex`),
    /// Escape and Cmd-. = Cancel, Cmd-D = Don't Save, Cmd-S = Save.
    public static func response(for model: SQDialogModel, keyCode: UInt16, command: Bool, otherModifiers: Bool,
                                character: String?, focusedIndex: Int? = nil, editingText: Bool = false) -> SQDialogModel.Response? {
        if otherModifiers { return nil }
        // A text field being edited owns Return (commits the field) and Escape (cancels the edit); the dialog stays open.
        if editingText, !command, keyCode == 53 || keyCode == 36 || keyCode == 76 { return nil }
        if command {
            switch character?.lowercased() {
            case ".": return model.response(forReturn: false)
            case "d": return model.dontSaveIndex.map { .init($0) }
            case "s": return model.saveIndex.map { .init($0) }
            default: return nil
            }
        }
        switch keyCode {
        case 53: return model.response(forReturn: false)
        case 36, 76: return focusedIndex.map { .init($0) } ?? model.response(forReturn: true)
        default: return nil
        }
    }
}

/// The scrim: fills the main window, dims it and swallows clicks; the card sits in the middle.
@MainActor
public final class SQModalScrimView: NSView {
    public let card: NSView
    public init(card: NSView) {
        self.card = card
        self.cardSize = card.frame.size
        super.init(frame: NSRect(origin: .zero, size: card.frame.size))
        wantsLayer = true
        layer?.backgroundColor = Theme.Modal.scrimColor.cgColor
        cardShadow.wantsLayer = true
        if let l = cardShadow.layer {
            l.backgroundColor = Theme.Colors.panel.cgColor
            l.cornerRadius = Theme.Modal.radius
            l.cornerCurve = .continuous
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = Float(Theme.Modal.shadowAlpha)
            l.shadowRadius = Theme.Modal.shadowRadius
            l.shadowOffset = CGSize(width: 0, height: -Theme.Modal.shadowOffsetY)      // layer space is y up
        }
        addSubview(cardShadow)
        addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = true
    }
    public required init?(coder: NSCoder) { fatalError() }

    /// False when a `SQModalBackdropView` on the host window dims it instead (the sheet then slides in with the card
    /// only, and the dim fades on its own).
    public var dimsItself = true {
        didSet { layer?.backgroundColor = dimsItself ? Theme.Modal.scrimColor.cgColor : NSColor.clear.cgColor }
    }
    public override var isOpaque: Bool { false }
    public override func layout() {
        super.layout()
        card.frame = SQModal.cardFrame(size: cardSize, in: bounds)
        cardShadow.frame = card.frame
        cardShadow.layer?.shadowPath = CGPath(roundedRect: cardShadow.bounds, cornerWidth: Theme.Modal.radius, cornerHeight: Theme.Modal.radius, transform: nil)
    }
    /// Natural size of the card (its fitting size when it was built); `setCardSize` follows content that grows.
    public private(set) var cardSize: NSSize
    public func setCardSize(_ size: NSSize) { cardSize = size; needsLayout = true }
    /// The card's drop shadow (`Theme.Modal.shadow*`): a panel-colored plate of the card's frame behind it, so the card
    /// itself can clip its content to the rounded corners.
    private let cardShadow = NSView()
    public override func mouseDown(with event: NSEvent) {}
    public override func rightMouseDown(with event: NSEvent) {}
    public override func otherMouseDown(with event: NSEvent) {}
    public override func scrollWheel(with event: NSEvent) {}
    public override var acceptsFirstResponder: Bool { false }
}

/// The dim behind a sheet: a translucent black layer on the host window's content that only fades (opacity). The sheet
/// window carries just the card, so the system slide moves the card alone. The host window clips it to its rounded corners.
@MainActor
public final class SQModalBackdropView: NSView {
    public override var isOpaque: Bool { false }
    public override func mouseDown(with event: NSEvent) {}
    public override func rightMouseDown(with event: NSEvent) {}
    public override func otherMouseDown(with event: NSEvent) {}
    public override func scrollWheel(with event: NSEvent) {}
    public override var acceptsFirstResponder: Bool { false }

    /// Fades a backdrop in over `host`'s content; nil when the host has no content view.
    public static func show(over host: NSWindow, fadeNow: Bool = true) -> SQModalBackdropView? {
        guard let content = host.contentView else { return nil }
        let v = SQModalBackdropView(frame: content.bounds)
        v.autoresizingMask = [.width, .height]
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.Modal.scrimColor.cgColor
        v.alphaValue = 0
        content.addSubview(v, positioned: .above, relativeTo: nil)
        if fadeNow { fade(v, to: 1) {} }
        return v
    }

    /// Starts the fade-in of a backdrop made with `fadeNow: false`.
    public func fadeIn() { Self.fade(self, to: 1) {} }

    /// Fades out (instantly under Reduce Motion), then removes the view.
    public func hide() {
        Self.fade(self, to: 0) { [weak self] in self?.removeFromSuperview() }
    }

    func fade(to alpha: CGFloat, duration d: Double, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = d
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = alpha
        }, completionHandler: { MainActor.assumeIsolated { completion() } })
    }

    private static func fade(_ v: NSView, to alpha: CGFloat, completion: @escaping @MainActor () -> Void) {
        let d = Theme.Motion.duration(Theme.Modal.dimFade)
        guard d > 0 else { v.alphaValue = alpha; completion(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = d
            ctx.timingFunction = Theme.Motion.Curve.easeOut.timingFunction
            v.animator().alphaValue = alpha
        }, completionHandler: { MainActor.assumeIsolated { completion() } })
    }
}

import AppKit

/// Own modal dialog (no system alert chrome, no system sheet material): title, message, optional accessory view and a row
/// of `SQButton`s on an opaque overlay card (radius 14, .5 px edge), presented through the shared modal shell (`SQModal`):
/// the card is centered over the dimmed main window. Same call shape as the system alert it replaces:
///
///     let d = SQDialog(); d.messageText = "…"; d.addButton("OK"); d.addButton("Cancel")
///     d.beginSheetModal(for: window) { response in if response == .first { … } }
///
/// plus the common patterns as one-liners: `confirm`, `warn`, `info`, `choice` (async) and `runConfirm`/`runChoice`
/// (blocking). Return presses the main button (never a destructive one), Esc / Cmd-. the cancel button, Cmd-D "Don't Save",
/// Cmd-S "Save" (roles: see `SQDialogModel`, keys: `SQModal.response`). The shell is a borderless sheet of the parent window
/// (the window is blocked while it shows); without a parent the front window of the app is used, and only without any
/// window the shell covers the screen.
@MainActor
public final class SQDialog: NSObject {
    public typealias Role = SQDialogModel.Role
    public typealias Response = SQDialogModel.Response

    public enum Style: Sendable { case plain, warning, critical }

    public var messageText = ""
    public var informativeText = ""
    public var accessoryView: NSView?
    /// Kept for source compatibility; the board draws every dialog the same (no color bar on warnings).
    public var style: Style = .plain
    /// Card width; nil: 332, or wider when a legacy accessory needs it. Board widths: 332 / 360 / 380 / 392 / 440 / 452.
    public var width: CGFloat?
    /// View that takes the keyboard first (a text field in the accessory); nil: Return acts on the default button.
    public var initialFirstResponder: NSView?
    /// Fixed card height (the L modal is 640 high): the accessory is stretched to fill what the header and footer leave.
    /// nil: the card is as high as its content.
    public var cardHeight: CGFloat?
    /// Asked before a button closes the dialog; false keeps it open (a field with invalid text shows its error state and the
    /// OK button does nothing). Must answer true for Cancel and `.dismissed`, or the dialog cannot be left.
    public var canClose: (@MainActor (Response) -> Bool)?
    public private(set) var model = SQDialogModel()
    /// Window after layout; exposed for tests.
    public private(set) var window: SQDialogWindow?

    var completion: (@MainActor (Response) -> Void)?
    private var parent: NSWindow?
    private var finished = false
    private var keepAlive: SQDialog?
    private var resizeToken: NSObjectProtocol?
    private var buttonViews: [Int: SQButton] = [:]

    public override init() { super.init() }

    @discardableResult
    public func addButton(_ title: String, role: Role = .normal, leading: Bool = false) -> SQDialogModel.Button {
        let b = SQDialogModel.Button(title: title, role: role, leading: leading)
        model.buttons.append(b)
        return b
    }

    // MARK: Presenting

    /// Shows the dialog as a sheet of `window` and calls `completion` with the pressed button.
    public func beginSheetModal(for window: NSWindow, completion: (@MainActor (Response) -> Void)? = nil) {
        self.completion = completion
        parent = window
        keepAlive = self
        let w = layout()
        w.present(over: window, path: "SQDialog.sheet")      // the scrim covers the whole window, the card sits in its middle
        track(window, w)
        focusInitial(w)
    }

    /// Shows the dialog modal and returns the pressed button. Over the front window of the app (blocking it like a
    /// sheet), or over the screen when the app has no window.
    @discardableResult
    public func runModal() -> Response {
        keepAlive = self
        let w = layout()
        var result = Response.dismissed
        completion = { result = $0 }
        if let host = Self.frontHost() {
            parent = host
            w.present(over: host, path: "SQDialog.runModal")
            track(host, w)
        } else {
            w.setFrame(NSScreen.main?.frame ?? NSRect(origin: .zero, size: NSSize(width: 1440, height: 900)), display: true)
        }
        focusInitial(w)
        NSApp.runModal(for: w)
        return result
    }

    /// The window a sheet-less dialog covers: key or main window, else any visible document window; the innermost sheet.
    private static func frontHost() -> NSWindow? {
        var w = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
        if w is SQDialogWindow, let p = w?.parent { w = p }
        while let s = w?.sqAttachedSheet { w = s }
        return w
    }

    /// Keeps the shell on the window when that is resized.
    private func track(_ host: NSWindow, _ shell: SQDialogWindow) {
        resizeToken = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: .main) { [weak host, weak shell] _ in
            MainActor.assumeIsolated { if let host, let shell { shell.setFrame(host.frame, display: true) } }
        }
    }

    private func focusInitial(_ w: SQDialogWindow) {
        if let f = initialFirstResponder { w.makeFirstResponder(f) } else if let i = model.initialFocusIndex, let b = buttonViews[i] { w.makeFirstResponder(b) }
    }

    /// Press a button as if clicked (key handling, tests).
    func press(_ response: Response) {
        guard !finished, let w = window else { return }
        if let canClose, !canClose(response) { return }
        finished = true
        let c = completion
        if let resizeToken { NotificationCenter.default.removeObserver(resizeToken) }
        resizeToken = nil
        w.closeFaded(from: parent)
        parent?.makeKey()
        if NSApplication.shared.modalWindow === w { NSApplication.shared.stopModal() }
        window = nil
        parent = nil
        completion = nil
        keepAlive = nil
        c?(response)
    }

    // MARK: Layout

    @discardableResult
    func layout() -> SQDialogWindow {
        if let window { return window }
        // A dialog without buttons can never be closed (it blocks the window or app): always offer OK.
        if model.buttons.isEmpty { addButton("OK", role: .default) }
        var accessoryWidth: CGFloat = 0
        if let a = accessoryView {
            if a.translatesAutoresizingMaskIntoConstraints, a.frame.width > 0, a.frame.height > 0 {
                a.translatesAutoresizingMaskIntoConstraints = false
                a.widthAnchor.constraint(equalToConstant: a.frame.width).isActive = true
                a.heightAnchor.constraint(equalToConstant: a.frame.height).isActive = true
                accessoryWidth = a.frame.width
            } else {
                a.translatesAutoresizingMaskIntoConstraints = false
                accessoryWidth = a.fittingSize.width
            }
        }
        let m = SQDialogMetrics.self
        let isForm = accessoryView is SQDialogForm
        // An alert (no accessory) is always the S modal; a dialog with content takes its requested width.
        let cardWidth = accessoryView == nil ? Theme.Modal.widthS
            : min(max(width ?? max(m.defaultWidth, isForm ? 0 : accessoryWidth + m.sidePad * 2), 300), 860)
        let contentWidth = cardWidth - m.sidePad * 2

        let title = messageText.isEmpty ? nil : SQDialogText(.title, messageText, width: contentWidth)
        let note = informativeText.isEmpty ? nil : SQDialogText(.note, informativeText, width: contentWidth)
        let body = accessoryView.map { wrapAccessory($0, isForm: isForm, width: cardWidth) }
        if let cardHeight, let body {
            // Header and footer keep their height; the body takes the rest (measured from a throw-away card with an empty body: header, the gap and the footer).
            let probe = Self.cardContent(title: title, note: note, body: nil, footer: buttonRow(), width: cardWidth)
            body.heightAnchor.constraint(equalToConstant: max(cardHeight - probe.fittingSize.height, 120)).isActive = true
        }
        let card = Self.cardContent(title: title, note: note, body: body, footer: buttonRow(), width: cardWidth)
        let w = SQDialogWindow(card: card)
        w.model = model
        w.onResponse = { [weak self] r in self?.press(r) }
        window = w
        return w
    }

    /// Footer (board `.df`): buttons 26 high capsules (padding 16); a button added with `leading: true` sits alone at the left edge.
    private func buttonRow() -> NSView {
        let m = SQDialogMetrics.self
        var left: [NSView] = []
        var right: [NSView] = []
        for i in model.displayOrder {
            let b = model.buttons[i]
            let isMain = i == model.primaryIndex && b.role != .destructive
            let button = SQButton(title: SQL10n.string(b.title), target: self, action: #selector(buttonClicked(_:)), style: isMain ? .accent : .standard)
            if b.role == .destructive { button.contentTintColor = Theme.Colors.red }
            buttonViews[i] = button
            button.tag = i
            button.horizontalPadding = m.buttonPadding
            button.boxHeight = m.buttonHeight
            button.cornerRadius = Theme.Sheet.buttonRadius
            button.quietFont = Theme.Sheet.buttonFont
            button.setContentHuggingPriority(.required, for: .horizontal)
            if b.isLeading && i != model.primaryIndex { left.append(button) } else { right.append(button) }
        }
        return Self.footerRow(left: left, right: right, band: accessoryView != nil)
    }

    /// Board layout: a form spans the card; a plain text field gets the naming row (16 inset, 4 below); any other legacy
    /// accessory keeps its size, inset 16.
    private func wrapAccessory(_ a: NSView, isForm: Bool, width: CGFloat) -> NSView {
        if isForm { return a }
        let m = SQDialogMetrics.self
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        a.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(a)
        if a is NSTextField {
            NSLayoutConstraint.activate([
                a.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: m.sidePad),
                a.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -m.sidePad),
                a.topAnchor.constraint(equalTo: holder.topAnchor),
                a.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: 0),
            ])
        } else {
            NSLayoutConstraint.activate([
                a.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: m.sidePad),
                a.topAnchor.constraint(equalTo: holder.topAnchor),
                a.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                a.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -m.sidePad),
            ])
        }
        return holder
    }

    @objc private func buttonClicked(_ sender: NSControl) { press(Response(sender.tag)) }

    // MARK: Accessory helpers

    /// Text field in the dialog look (board `.fld`): an `SQTextField` capsule, 22 high. In an accessory it stretches to the card
    /// (naming row); `width` only sets the frame when the field is used outside a dialog (`nil` leaves sizing to the caller).
    public static func makeField(_ text: String = "", placeholder: String? = nil, width: CGFloat? = 260) -> NSTextField {
        let f = SQTextField(frame: NSRect(x: 0, y: 0, width: width ?? 100, height: Theme.Sheet.controlHeight))
        f.isEditable = true
        f.isSelectable = true
        f.usesSingleLineMode = true
        f.stringValue = text
        f.placeholderString = placeholder
        f.translatesAutoresizingMaskIntoConstraints = false
        f.heightAnchor.constraint(equalToConstant: Theme.Sheet.controlHeight).isActive = true
        if width != nil { f.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        return f
    }

    /// Numeric input for dialogs: a `ScrubField` (drag, Shift x10, Option x0.1, double-click resets to `defaultValue`,
    /// type, arrows, Option+wheel), 24 high and `width` wide. Use this instead of `makeField` for any number.
    public static func makeNumberField(value: Double = 0, range: ClosedRange<Double>, step: Double = 1, decimals: Int = 0,
                                       unit: String = "", defaultValue: Double? = nil, width: CGFloat? = 70) -> ScrubField {
        let f = ScrubField()
        f.range = range
        f.step = step
        f.decimals = decimals
        f.unit = unit
        f.unitOutside = !unit.isEmpty
        f.defaultValue = defaultValue
        f.value = ScrubMath.clamp(value, to: range)
        f.translatesAutoresizingMaskIntoConstraints = false
        if let width { f.widthAnchor.constraint(equalToConstant: width).isActive = true } else { f.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        f.heightAnchor.constraint(equalToConstant: Theme.Sheet.controlHeight).isActive = true
        return f
    }

    /// Small secondary text for accessory views.
    public static func caption(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.Typography.body
        l.textColor = Theme.Colors.label2
        return l
    }

    // MARK: One-liners

    /// OK / Cancel style question. `completion(true)` when confirmed. Without a window it runs app-modal.
    public static func confirm(_ title: String, message: String = "", confirm: String = "OK", cancel: String = "Cancel",
                               destructive: Bool = false, in window: NSWindow?,
                               completion: @escaping @MainActor (Bool) -> Void) {
        let d = confirmDialog(title, message, confirm, cancel, destructive)
        if let window {
            d.beginSheetModal(for: window) { completion($0 == .first) }
        } else {
            completion(d.runModal() == .first)
        }
    }

    /// Blocking `confirm`.
    public static func runConfirm(_ title: String, message: String = "", confirm: String = "OK", cancel: String = "Cancel",
                                  destructive: Bool = false) -> Bool {
        confirmDialog(title, message, confirm, cancel, destructive).runModal() == .first
    }

    /// Warning with one OK button.
    public static func warn(_ title: String, message: String = "", in window: NSWindow?) { notice(title, message, .warning, window) }
    /// Information with one OK button.
    public static func info(_ title: String, message: String = "", in window: NSWindow?) { notice(title, message, .plain, window) }

    /// Several options plus optional cancel. `completion(index)` is the index into `options`, nil when canceled.
    public static func choice(_ title: String, message: String = "", options: [String], cancel: String? = "Cancel",
                              in window: NSWindow?, completion: @escaping @MainActor (Int?) -> Void) {
        let d = choiceDialog(title, message, options, cancel)
        let finish: @MainActor (Response) -> Void = { r in completion(Self.optionIndex(r, count: options.count)) }
        if let window { d.beginSheetModal(for: window, completion: finish) } else { finish(d.runModal()) }
    }

    /// Blocking `choice`.
    public static func runChoice(_ title: String, message: String = "", options: [String], cancel: String? = "Cancel") -> Int? {
        optionIndex(choiceDialog(title, message, options, cancel).runModal(), count: options.count)
    }

    /// The option index of a response, nil for the cancel button or a dismissed dialog.
    nonisolated static func optionIndex(_ r: Response, count: Int) -> Int? { r.rawValue >= 0 && r.rawValue < count ? r.rawValue : nil }

    private static func confirmDialog(_ title: String, _ message: String, _ confirm: String, _ cancel: String, _ destructive: Bool) -> SQDialog {
        let d = SQDialog()
        d.messageText = title
        d.informativeText = message
        d.addButton(confirm, role: destructive ? .destructive : .default)
        d.addButton(cancel, role: .cancel)
        return d
    }

    private static func choiceDialog(_ title: String, _ message: String, _ options: [String], _ cancel: String?) -> SQDialog {
        let d = SQDialog()
        d.messageText = title
        d.informativeText = message
        for (i, o) in options.enumerated() { d.addButton(o, role: i == 0 ? .default : .normal) }
        if let cancel { d.addButton(cancel, role: .cancel) }
        return d
    }

    private static func notice(_ title: String, _ message: String, _ style: Style, _ window: NSWindow?) {
        let d = SQDialog()
        d.messageText = title
        d.informativeText = message
        d.style = style
        d.addButton("OK", role: .default)
        if let window { d.beginSheetModal(for: window) } else { d.runModal() }
    }
}

/// The shell window of a dialog: borderless, transparent, as large as the window it covers. Its content view is the scrim
/// with the card in the middle. Keys go through `SQModal.response` (Return, Esc, Cmd-., Cmd-D, Cmd-S).
@MainActor
public final class SQDialogWindow: NSPanel {
    var model = SQDialogModel()
    var onResponse: (@MainActor (SQDialogModel.Response) -> Void)?
    public let scrim: SQModalScrimView

    /// Custom-card mode (no dialog model): Esc and Cmd-. call `onCancel`, every other key goes to the card.
    public var onCancel: (@MainActor () -> Void)?

    public init(card: NSView, size explicit: NSSize? = nil) {
        let size = explicit ?? card.fittingSize
        card.frame = NSRect(origin: .zero, size: size)
        scrim = SQModalScrimView(card: card)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        appearance = Theme.windowAppearance
        animationBehavior = .none
        contentView = scrim
        setContentSize(size)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    private var backdrop: SQModalBackdropView?
    private var settleTimer: Timer?
    /// Dims `host` with a fading backdrop; this window then holds the card only (clear scrim).
    func attachBackdrop(to host: NSWindow, fadeNow: Bool = true) {
        removeBackdrop()
        backdrop = SQModalBackdropView.show(over: host, fadeNow: fadeNow)
        scrim.dimsItself = backdrop == nil
    }

    /// The one way every dialog and card sheet goes up over `host`. The system sheet slide moves this host-sized window
    /// down from above; it is kept invisible (alpha 0) until the slide has settled, then the card and the dim fade in
    /// together at the final frame, so nothing sweeps across the editor. Logs `[Modal] path=... slidingFrame=... dimFrame=...`.
    func present(over host: NSWindow, path: String) {
        alphaValue = 0
        setContentSize(host.frame.size)
        attachBackdrop(to: host, fadeNow: false)
        host.addChildWindow(self, ordered: .above)
        makeKey()
        setFrame(host.frame, display: true)
        NSLog("[Modal] path=%@ slidingFrame=%@ dimFrame=%@ windowClear=%d", path, NSStringFromRect(frame),
              backdrop.map { NSStringFromRect($0.frame) } ?? "none", backgroundColor == .clear ? 1 : 0)
        revealFaded()
    }

    private func revealFaded() {
        backdrop?.fadeIn()
        let d = Theme.Motion.duration(Theme.Modal.dimFade)
        guard d > 0 else { alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = d
            ctx.timingFunction = Theme.Motion.Curve.easeOut.timingFunction
            animator().alphaValue = 1
        }
    }
    /// Closes together: card and dim fade out at the same time (shorter than the fade in), then the window goes.
    func closeFaded(from host: NSWindow?) {
        settleTimer?.invalidate(); settleTimer = nil
        let d = Theme.Motion.duration(Theme.Modal.dimFadeOut)
        let bd = backdrop; backdrop = nil
        let finish: @MainActor () -> Void = { [weak self] in
            bd?.removeFromSuperview()
            guard let self else { return }
            if let host, self.parent === host { host.removeChildWindow(self) }
            self.orderOut(nil)
        }
        guard d > 0 else { finish(); return }
        bd?.fade(to: 0, duration: d) {}
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = d
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { finish() } })
    }
    func removeBackdrop() {
        settleTimer?.invalidate(); settleTimer = nil
        backdrop?.hide(); backdrop = nil
    }

    /// Index of the button that has the keyboard focus (after Tab), nil when focus is elsewhere.
    var focusedButtonIndex: Int? {
        guard let b = firstResponder as? SQButton, b.window === self, model.buttons.indices.contains(b.tag) else { return nil }
        return b.tag
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, model.buttons.isEmpty {
            super.sendEvent(event)
            return
        }
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let command = flags.contains(.command)
            let other = !flags.subtracting([.command, .numericPad, .function, .capsLock]).isEmpty
            let editing = SQModal.isEditingText(firstResponder) && SQModal.inputCount(in: contentView) > 1
            if editing, !command, event.keyCode == 36 || event.keyCode == 76 {
                super.sendEvent(event)
                SQModal.endEditingAfterCommit(in: self)
                return
            }
            if editing, event.keyCode == 53 || (command && event.charactersIgnoringModifiers == "."), SQModal.abortEditing(in: self) { return }
            if let r = SQModal.response(for: model, keyCode: event.keyCode, command: command, otherModifiers: other,
                                        character: event.charactersIgnoringModifiers, focusedIndex: focusedButtonIndex, editingText: editing) {
                onResponse?(r)
                return
            }
            // Escape on a choice dialog that cannot be canceled, or Cmd-. there: swallowed, not beeped to the editor.
            if event.keyCode == 53 { return }
        }
        super.sendEvent(event)
    }

    public override func cancelOperation(_ sender: Any?) {
        if model.buttons.isEmpty { onCancel?(); return }
        if let r = model.response(forReturn: false) { onResponse?(r) }
    }
}

final class SQDialogCardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        SQDialogStyle.styleCard(layer)
    }
    required init?(coder: NSCoder) { fatalError() }
}

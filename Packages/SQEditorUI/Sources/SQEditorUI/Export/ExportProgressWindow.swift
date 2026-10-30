import AppKit
import SQCore
import SQExport

/// The quiet "Enjoying Sequence Studio? Support it" line of the export-done notice. The app decides (`SupportReminder`).
public struct SupportPrompt {
    public var shouldShow: () -> Bool
    public var didShow: () -> Void
    public var open: () -> Void
    public var turnOff: () -> Void
    public init(shouldShow: @escaping () -> Bool, didShow: @escaping () -> Void, open: @escaping () -> Void,
                turnOff: @escaping () -> Void) {
        self.shouldShow = shouldShow; self.didShow = didShow; self.open = open; self.turnOff = turnOff
    }
}

/// Content of the export progress window: progress bar with percent, phase, elapsed / remaining, output path and the
/// button row (Cancel with inline confirmation; Reveal / Open when done; Close on failure). Own SQ design, Theme tokens only.
@MainActor
public final class ExportProgressView: NSView {
    public static let size = Theme.Modal.exportProgressWindowSize

    public private(set) var model: ExportProgressModel
    public var onCancelConfirmed: (() -> Void)?
    public var onReveal: ((URL) -> Void)?
    public var onOpen: ((URL) -> Void)?
    public var onClose: (() -> Void)?
    /// Set by the owner; consulted once when the export finishes successfully.
    public var supportPrompt: SupportPrompt?
    private var supportButton: SQButton?
    private var supportOffButton: SQButton?

    private let bar = ExportProgressBar()
    private let percent = makeLabel("0%", font: Theme.Typography.bodyStrong, color: Theme.Colors.label)
    private let phase = makeLabel("", font: Theme.Typography.body, color: Theme.Colors.label)
    private let times = makeLabel("", font: Theme.Typography.body, color: Theme.Colors.label2)
    private let path = makeLabel("", font: Theme.Typography.caption, color: Theme.Colors.label3)
    private let message = makeLabel("", font: Theme.Typography.body, color: Theme.Colors.label2)
    private var buttons: [SQButton] = []
    private var pip: SQMascotView?
    private var pipPlace: SQMascotPlace?
    /// Content height: the done card grows so Pip's cheer (84 pt) fits at full size; the others keep the 148 pt window.
    public private(set) var preferredHeight = ExportProgressView.size.height
    /// Called when `preferredHeight` changes while shown (the owner resizes the window, top edge fixed).
    public var onPreferredHeightChange: ((CGFloat) -> Void)?

    private func updatePip() {
        let place: SQMascotPlace?
        switch model.stage {
        case .running, .confirmingCancel, .stopping: place = .exportRunning   // M7
        case .done: place = .exportDone                                       // M8
        case .failed: place = .exportFailed                                   // M9
        default: place = nil
        }
        guard place != pipPlace else { return }
        pipPlace = place
        pip?.removeFromSuperview()
        pip = place?.makeView()
        if let pip { addSubview(pip) }
        let h = Self.size.height + max(0, (pip?.intrinsicContentSize.height ?? 0) - 40)
        if h != preferredHeight { preferredHeight = h; onPreferredHeightChange?(h) }
        needsLayout = true
    }

    public override var isFlipped: Bool { true }

    public init(model: ExportProgressModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        times.alignment = .right
        percent.alignment = .right
        path.lineBreakMode = .byTruncatingMiddle
        message.lineBreakMode = .byTruncatingTail
        for v in [bar, percent, phase, times, path, message] as [NSView] { addSubview(v) }
        refresh()
    }
    public required init?(coder: NSCoder) { fatalError() }

    /// Replaces the model and redraws; only touches views whose text changed.
    public func apply(_ m: ExportProgressModel) {
        let stageChanged = m.stage != model.stage
        model = m
        refresh(rebuildButtons: stageChanged)
    }

    private func refresh(rebuildButtons: Bool = true) {
        bar.fraction = model.fraction
        bar.tone = model.errorText != nil ? .failed : .normal
        setText(percent, model.percentText)
        setText(phase, model.phaseText)
        setText(times, [model.elapsedText, model.remainingText].filter { !$0.isEmpty }.joined(separator: "  ·  "))
        setText(path, model.outputURL.path)
        switch model.stage {
        case .confirmingCancel: setText(message, model.cancelPrompt)
        case .failed(let m): setText(message, m)
        default: setText(message, "")
        }
        message.textColor = model.errorText != nil ? Theme.Colors.red : Theme.Colors.label2
        if rebuildButtons || buttons.isEmpty { rebuildButtonRow() }
        updatePip()
        needsLayout = true
    }

    private func setText(_ l: NSTextField, _ s: String) { if l.stringValue != s { l.stringValue = s } }

    private func rebuildButtonRow() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        supportButton?.removeFromSuperview(); supportButton = nil
        supportOffButton?.removeFromSuperview(); supportOffButton = nil
        reminderPending = false
        switch model.stage {
        case .running:
            buttons = [button("Cancel", .standard, #selector(cancelTapped))]
        case .confirmingCancel:
            buttons = [button("Keep Exporting", .standard, #selector(keepTapped)), button("Stop Export", .accent, #selector(confirmTapped))]
        case .stopping:
            buttons = []
        case .done:
            buttons = [button("Reveal in Finder", .standard, #selector(revealTapped)), button("Open", .accent, #selector(openTapped))]
            if let prompt = supportPrompt, prompt.shouldShow() {
                reminderPending = true
                let b = button("Enjoying Sequence Studio? Support it", .icon, #selector(supportTapped))
                b.image = Theme.symbol(.heart, size: 10, label: SQL10n.string("Support"))
                b.imagePosition = .imageLeading
                b.contentTintColor = Theme.Colors.support
                b.setAccessibilityLabel(SQL10n.string("Support Sequence Studio"))
                b.sizeToFit()
                supportButton = b
                addSubview(b)
                let off = button("Don’t show again", .icon, #selector(supportOffTapped))
                off.contentTintColor = Theme.Colors.label3
                off.sizeToFit()
                supportOffButton = off
                addSubview(off)
            }
        case .failed, .cancelled:
            buttons = [button("Close", .accent, #selector(closeTapped))]
        }
        buttons.forEach(addSubview)
        recordReminderIfOnScreen()
    }

    /// The 7-day slot is spent only when the line is really on screen: built, and its window visible and not minimized.
    private var reminderPending = false
    private var windowObservers: [NSObjectProtocol] = []
    private func recordReminderIfOnScreen() {
        guard reminderPending, supportButton != nil else { return }
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        guard SupportReminder.shouldRecord(lineShown: true, windowVisible: visible) else { return }
        reminderPending = false
        supportPrompt?.didShow()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { windowObservers.forEach { NotificationCenter.default.removeObserver($0) }; windowObservers = [] }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        guard let w = window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordReminderIfOnScreen() }
            })
        }
        recordReminderIfOnScreen()
    }

    private func button(_ title: String, _ style: SQButton.Style, _ action: Selector) -> SQButton {
        let b = SQButton(title: title, target: self, action: action, style: style)
        b.sizeToFit()
        return b
    }

    public override func layout() {
        super.layout()
        let m = Theme.Spacing.lg, w = bounds.width - 2 * m
        let pw: CGFloat = 40
        var y = Theme.Spacing.md + Theme.Spacing.xs
        bar.frame = NSRect(x: m, y: y + 4, width: w - pw - Theme.Spacing.sm, height: 6)
        percent.frame = NSRect(x: bounds.width - m - pw, y: y, width: pw, height: 14)
        y += 24
        let half = (w - Theme.Spacing.sm) / 2
        phase.frame = NSRect(x: m - 2, y: y, width: half, height: 14)   // text fields carry 2 pt inner padding
        times.frame = NSRect(x: m + half + Theme.Spacing.sm, y: y, width: half, height: 14)
        y += 20
        path.frame = NSRect(x: m - 2, y: y, width: w, height: 14)
        y += 18
        message.frame = NSRect(x: m - 2, y: y, width: w, height: 14)
        if let b = supportButton {
            let bw = ceil(b.intrinsicContentSize.width)
            b.frame = NSRect(x: m - 6, y: y - 4, width: bw, height: Theme.Metrics.pushButton)
            if let off = supportOffButton {
                let ow = ceil(off.intrinsicContentSize.width)
                off.frame = NSRect(x: bounds.width - m + 6 - ow, y: y - 4, width: ow, height: Theme.Metrics.pushButton)
            }
        }
        if let pip {
            let ps = pip.intrinsicContentSize
            // Small Pip centers on the button row; the big cheer sits on the card's bottom margin.
            let y = ps.height <= 40 ? bounds.height - Theme.Spacing.md - Theme.Metrics.pushButton / 2 - ps.height / 2
                                    : bounds.height - Theme.Spacing.md - ps.height
            pip.frame = NSRect(x: m, y: y, width: ps.width, height: ps.height)
        }
        // Button row: right aligned, 22 high, centered in the bottom band.
        let h = Theme.Metrics.pushButton
        var x = bounds.width - m
        let by = bounds.height - Theme.Spacing.md - h
        for b in buttons.reversed() {
            let bw = max(b.frame.width, ceil(b.intrinsicContentSize.width))
            x -= bw
            b.frame = NSRect(x: x, y: by, width: bw, height: h)
            x -= Theme.Spacing.sm
        }
    }

    @objc private func cancelTapped() { var m = model; m.requestCancel(); apply(m) }
    @objc private func keepTapped() { var m = model; m.keepExporting(); apply(m) }
    @objc private func confirmTapped() {
        guard model.stage == .confirmingCancel else { return }
        var m = model; m.confirmCancel(); apply(m)
        onCancelConfirmed?()
    }
    @objc private func revealTapped() { onReveal?(model.outputURL) }
    @objc private func openTapped() { onOpen?(model.outputURL) }
    @objc private func closeTapped() { onClose?() }
    @objc private func supportOffTapped() {
        supportPrompt?.turnOff()
        supportButton?.removeFromSuperview(); supportButton = nil
        supportOffButton?.removeFromSuperview(); supportOffButton = nil
    }
    @objc private func supportTapped() { supportPrompt?.open() }
}

/// 6 pt capsule bar: `fill` track, accent progress (red on failure).
final class ExportProgressBar: NSView {
    enum Tone { case normal, failed }
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    var tone: Tone = .normal { didSet { if tone != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        Theme.Colors.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let w = max(bounds.width * CGFloat(min(max(fraction, 0), 1)), fraction > 0 ? bounds.height : 0)
        guard w > 0 else { return }
        (tone == .failed ? Theme.Colors.red : Theme.Colors.accent).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: r, yRadius: r).fill()
    }
}

/// One export's progress window: an `SQFloatingPanel` (editor stays usable) fed from the queue rows at <= 10 Hz.
@MainActor
public final class ExportProgressWindow {
    public let view: ExportProgressView
    public let panel: SQFloatingPanel
    public var onFinished: ((ExportProgressModel) -> Void)?
    private var notifiedFinish = false
    private let clock: () -> Double
    private var timer: Timer?
    private let cancel: (UUID) -> Void
    private let source: () -> ExportQueueModel.Row?
    private let closeHandler: (() -> Void)?

    public static let updateInterval = 0.1   // 10 Hz

    public init(row: ExportQueueModel.Row,
                source: @escaping () -> ExportQueueModel.Row?,
                cancel: @escaping (UUID) -> Void,
                reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                supportPrompt: SupportPrompt? = nil,
                onClose: (() -> Void)? = nil) {
        self.clock = clock; self.cancel = cancel; self.source = source; self.closeHandler = onClose
        var m = ExportProgressModel(jobID: row.id, name: row.name, outputURL: row.outputURL)
        m.update(state: row.state, progress: row.progress, outputURL: row.outputURL, now: clock())
        view = ExportProgressView(model: m)
        view.supportPrompt = supportPrompt
        panel = SQFloatingPanel(key: "export-progress", title: m.title, subtitle: row.outputURL.lastPathComponent, content: view)
        view.onCancelConfirmed = { [weak self] in
            guard let self else { return }
            self.cancel(self.view.model.jobID)
        }
        view.onReveal = { [weak self] u in reveal(u); self?.panel.close() }
        view.onOpen = { [weak self] u in open(u); self?.panel.close() }
        view.onClose = { [weak self] in self?.panel.close() }
        panel.onClose = { [weak self] in self?.stopTimer(); self?.closeHandler?() }
        let p = panel
        view.onPreferredHeightChange = { [weak p] h in p?.setContentHeight(h) }
        panel.setContentHeight(view.preferredHeight)
    }

    public func show(near anchor: NSRect? = nil) {
        panel.show(near: anchor)
        timer = Timer.scheduledTimer(withTimeInterval: Self.updateInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func tick() {
        var m = view.model
        let now = clock()
        if let row = source() { m.update(state: row.state, progress: row.progress, outputURL: row.outputURL, now: now) } else { m.tick(now: now) }
        view.apply(m)
        if m.isFinished, !notifiedFinish { notifiedFinish = true; onFinished?(m) }
        if m.shouldAutoClose(now: now) { panel.close() }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
    public func close() { panel.close() }

    /// Offscreen card for `scripts/render-panels.sh`: running at 42 % (or the confirm / done / failed variants).
    public static func renderedWindow(stage: String = "running") -> NSView {
        let url = URL(fileURLWithPath: "/Users/you/Movies/My Video.mp4")
        var m = ExportProgressModel(jobID: UUID(), name: "My Video", outputURL: url)
        for s in 0...42 { m.update(state: .running, progress: Double(s) / 100, outputURL: url, now: Double(s) * 1.5) }
        switch stage {
        case "confirm": m.requestCancel()
        case "done": m.update(state: .done(url), progress: 1, outputURL: url, now: 70)
        case "failed": m.update(state: .failed("The disk is full."), progress: 0.42, outputURL: url, now: 70)
        default: break
        }
        let view = ExportProgressView(model: m)
        let panel = SQFloatingPanel(key: "render-export-progress", title: m.title, subtitle: url.lastPathComponent, content: view)
        panel.setContentHeight(view.preferredHeight)
        return panel.renderedView
    }
}

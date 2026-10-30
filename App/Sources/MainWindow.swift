import AppKit
import SQEditorUI

/// Window content: the 44 pt top bar (under the hidden title bar), the workspace host, a 28 pt status bar.
@MainActor
final class ShellContentView: NSView {
    let host = WorkspaceHostView()
    let statusBar = StatusBarView()
    /// Set by the controller once the toolbar exists.
    var topBar: TopBarView? {
        didSet { oldValue?.removeFromSuperview(); if let topBar { addSubview(topBar) }; needsLayout = true }
    }

    /// The project chooser (scrim + card) while it is up; covers the whole content.
    var overlay: NSView? {
        didSet { oldValue?.removeFromSuperview(); if let overlay { addSubview(overlay) }; needsLayout = true }
    }

    nonisolated override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.titlebar.cgColor
        addSubview(host)
        addSubview(statusBar)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let bar = ShellMetrics.statusBar
        let top = topBar == nil ? 0 : TopBarView.height
        topBar?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top)
        host.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - bar - top, 0))
        statusBar.frame = CGRect(x: 0, y: max(bounds.height - bar, 0), width: bounds.width, height: bar)
        overlay?.frame = bounds
    }
}

/// Status bar (v9 `.status`, 28 pt). Left: sequence format, save state, then messages (refused edit, autosave failure,
/// running job). Right: playback quality and the app version; warning chips and the export ring join them when shown.
@MainActor
final class StatusBarView: NSView {
    private let message = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// Save state with a dot, after the sequence format at the left (v9 `.status .ok`): "Saved" (green), "Edited" /
    /// "Edited · Backup 14:32" (warning). Never claims more than is on disk, see `SaveStatus`.
    private let saved = NSTextField(labelWithString: "Saved")
    var saveStateText: String { saved.stringValue }
    private let savedDot = NSView()
    /// Right end (board): "Playback: Full · GPU" and "Sequence Studio 0.1 Alpha".
    private let playback = NSTextField(labelWithString: "Playback: Full · GPU")
    private let version = NSTextField(labelWithString: "Sequence Studio " + StatusBarView.versionLabel)
    /// Color page (v9 `#cpStatus`): the shown grade of the picked clip, "No Pro grade", "Simple grade active", ...
    private let grade = NSTextField(labelWithString: "")
    var gradeText: String { grade.isHidden ? "" : grade.stringValue }
    static var versionLabel: String { AppVersion.display }
    /// Persistent chip while Linked Selection is off (the state is otherwise invisible and easy to forget).
    private let linkChip = NSTextField(labelWithString: "Linked Selection off")
    private var clearWork: DispatchWorkItem?
    /// "3 files outside the project folder · Collect": click collects them (nothing when all media is inside).
    private let outsideChip = StatusChipView()
    var onOutsideClicked: (() -> Void)? { didSet { outsideChip.onClick = onOutsideClicked } }
    /// "Found 4 offline files · Reconnect": the background relink offer; click applies it.
    private let relinkChip = StatusChipView()
    var onRelinkOfferClicked: (() -> Void)? { didSet { relinkChip.onClick = onRelinkOfferClicked } }
    /// `text` nil hides the chip.
    func setRelinkOffer(_ text: String?) {
        let hide = text == nil
        if let text, relinkChip.text != text { relinkChip.text = text; needsLayout = true }
        guard relinkChip.isHidden != hide else { return }
        relinkChip.isHidden = hide
        needsLayout = true
    }
    /// Background tasks (export queue): a small ring at the right end, visible while jobs exist; click opens the queue.
    private let ring = ProgressRingView()
    var onTasksClicked: ((NSView) -> Void)?

    nonisolated override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.titlebar.cgColor
        grade.textColor = Theme.Colors.label3
        grade.isHidden = true
        for l in [message, detail, saved, playback, version, grade] {
            l.font = Theme.Typography.body
            l.lineBreakMode = .byTruncatingTail
            addSubview(l)
        }
        savedDot.wantsLayer = true
        savedDot.layer?.backgroundColor = Theme.Colors.green.cgColor
        savedDot.layer?.cornerRadius = ShellMetrics.statusDot / 2
        addSubview(savedDot)
        linkChip.font = Theme.Typography.body
        linkChip.textColor = Theme.Colors.warning
        linkChip.alignment = .right
        linkChip.isHidden = true
        linkChip.setAccessibilityLabel("Linked Selection is off")
        addSubview(linkChip)
        outsideChip.isHidden = true
        outsideChip.sqToolTip = "Copy the media that sits outside the project folder into Files/Imported"
        addSubview(outsideChip)
        relinkChip.isHidden = true
        relinkChip.sqToolTip = "Files for offline media were found nearby: click to reconnect them (one undo step)"
        addSubview(relinkChip)
        message.textColor = Theme.Colors.label2
        detail.textColor = Theme.Colors.label3
        saved.textColor = Theme.Colors.label3
        playback.textColor = Theme.Colors.label3
        version.textColor = Theme.Colors.label3
        ring.sqToolTip = "Export queue"
        ring.setAccessibilityLabel("Export queue")
        ring.onClick = { [weak self] in
            guard let self else { return }
            self.onTasksClicked?(self.ring)
        }
        ring.isHidden = true
        addSubview(ring)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// "Playback: Full · GPU": the monitor's playback quality (the render path is always the GPU).
    func setPlaybackQuality(_ title: String) {
        playback.stringValue = "Playback: \(title) · GPU"
        needsLayout = true
    }

    func setDetail(_ s: String) { detail.stringValue = s; needsLayout = true }

    /// The Color page's grade text at the right, before the playback quality; "" (Edit page, no clip) hides it.
    func setGrade(_ s: String) {
        guard grade.stringValue != s else { return }
        grade.stringValue = s
        needsLayout = true
    }

    func setSaveStatus(_ status: SaveStatus) {
        let green = status.kind == .saved || status.kind == .empty
        savedDot.layer?.backgroundColor = (green ? Theme.Colors.green : Theme.Colors.warning).cgColor
        guard saved.stringValue != status.text else { return }
        saved.stringValue = status.text
        needsLayout = true
    }

    /// Board text: "1080 × 1920 · 30 fps"; the save state is `setSaveStatus`. `edited` stays in the signature for the host's call.
    func setSequence(width: Int, height: Int, fps: Double, variableFrameRate: Bool, edited: Bool) {
        let rate = fps.rounded() == fps ? String(Int(fps)) : String(format: "%.2f", fps)
        detail.stringValue = "\(width) × \(height) · \(rate) fps" + (variableFrameRate ? " VFR" : "")
        needsLayout = true
    }

    /// `text` nil hides the chip.
    func setOutsideHint(_ text: String?) {
        let hide = text == nil
        if let text, outsideChip.text != text { outsideChip.text = text; needsLayout = true }
        guard outsideChip.isHidden != hide else { return }
        outsideChip.isHidden = hide
        needsLayout = true
    }

    func setLinkedSelectionOff(_ off: Bool) {
        guard linkChip.isHidden == off else { return }
        linkChip.isHidden = !off
        needsLayout = true
    }

    /// `progress` nil hides the ring (no active jobs); 0...1 shows it.
    func setTasks(progress: Double?) {
        let visible = progress != nil
        if let progress { ring.progress = progress }
        if ring.isHidden == visible { ring.isHidden = !visible; needsLayout = true }
    }

    /// The job ring, made visible and laid out (animation target); nil when it has no window yet.
    func revealedRing() -> NSView? {
        guard window != nil else { return nil }
        if ring.isHidden { ring.isHidden = false; needsLayout = true }
        layoutSubtreeIfNeeded()
        return ring
    }

    /// A running background job's line ("Stabilize: analyzing … 42 %"): stays until it is set to nil, never times out.
    /// A flash shows over it and the job line comes back when the flash ends.
    private var job: String?

    func setJob(_ text: String?) {
        job = text
        if clearWork == nil { message.stringValue = text ?? "" }
    }

    /// Shows `text` for a few seconds (then the running job's line, if any).
    func flash(_ text: String, seconds: TimeInterval = 5) {
        message.stringValue = SQL10n.localized(text)     // engine and session texts are English keys (or filled-in patterns)
        clearWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clearWork = nil
                self.message.stringValue = self.job ?? ""
            }
        }
        clearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    override func layout() {
        super.layout()
        let h = Theme.Metrics.statusLine
        let y = ((bounds.height - h) / 2).rounded()
        let pad = ShellMetrics.statusPad, gap = ShellMetrics.statusPad
        let inset: CGFloat = 2          // a label draws its text 2 pt inside its frame
        // Measured from the text (a truncating label's intrinsic width came out short: "Autosav…").
        func textWidth(_ l: NSTextField) -> CGFloat {
            ceil((l.stringValue as NSString).size(withAttributes: [.font: l.font ?? Theme.Typography.body]).width) + 2 * inset
        }
        // v9 `.status`, left: "1080 × 1920 · 30 fps", dot + save state; then messages and jobs.
        var left = pad
        if !detail.stringValue.isEmpty {
            let w = textWidth(detail)
            detail.frame = CGRect(x: left - inset, y: y, width: w, height: h)
            left += w - 2 * inset + gap
        } else {
            detail.frame = .zero
        }
        let dot = ShellMetrics.statusDot
        savedDot.frame = CGRect(x: left, y: ((bounds.height - dot) / 2).rounded(), width: dot, height: dot)
        let savedW = textWidth(saved)
        saved.frame = CGRect(x: savedDot.frame.maxX + Theme.Spacing.iconToLabel - inset, y: y, width: savedW, height: h)
        left = saved.frame.maxX - inset + gap
        // Right: "Playback: Full · GPU", "Sequence Studio 0.1 Alpha", then the export ring. Chips sit left of them.
        var right = bounds.width - pad
        if !ring.isHidden {
            let side = Theme.Metrics.statusLine + 6
            ring.frame = CGRect(x: right - side + 3, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
            right = ring.frame.minX - gap + 3
        }
        // A narrow window drops the version first, then the playback text.
        for (label, least) in [(version, left + 320), (playback, left + 160)] {
            let w = textWidth(label)
            label.isHidden = right - w < least
            guard !label.isHidden else { continue }
            label.frame = CGRect(x: right - w + inset, y: y, width: w, height: h)
            right = label.frame.minX + inset - gap
        }
        // Color page: the grade text, dropped with the playback text in a narrow window.
        let gradeW = textWidth(grade)
        grade.isHidden = grade.stringValue.isEmpty || right - gradeW < left + 160
        if !grade.isHidden {
            grade.frame = CGRect(x: right - gradeW + inset, y: y, width: gradeW, height: h)
            right = grade.frame.minX + inset - gap
        }
        if !linkChip.isHidden {
            let w = textWidth(linkChip)
            linkChip.frame = CGRect(x: right - w + inset, y: y, width: w, height: h)
            right = linkChip.frame.minX + inset - gap
        }
        if !relinkChip.isHidden {
            let w = ceil(relinkChip.intrinsicContentSize.width)
            relinkChip.frame = CGRect(x: right - w, y: y, width: w, height: h)
            right = relinkChip.frame.minX - gap
        }
        if !outsideChip.isHidden {
            let w = ceil(outsideChip.intrinsicContentSize.width)
            outsideChip.frame = CGRect(x: right - w, y: y, width: w, height: h)
            right = outsideChip.frame.minX - gap
        }
        message.frame = CGRect(x: left - inset, y: y, width: max(right - left, 0), height: h)
    }

}

/// A clickable one-line status text in the caption style (the outside-media hint).
@MainActor
final class StatusChipView: NSView {
    var onClick: (() -> Void)?
    var text = "" { didSet { label.stringValue = text; invalidateIntrinsicContentSize() } }
    private let label = NSTextField(labelWithString: "")
    nonisolated override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Theme.Typography.caption
        label.textColor = Theme.Colors.warning
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityRole(.button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { label.intrinsicContentSize }
    override func layout() { super.layout(); label.frame = bounds }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Export-queue progress ring in Theme colors (track `fillHover`, arc `accent`); a click opens the queue.
@MainActor
final class ProgressRingView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    nonisolated override var isFlipped: Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3).insetBy(dx: 1, dy: 1)
        let track = NSBezierPath(ovalIn: r)
        track.lineWidth = 2
        Theme.State.controlHover.setStroke()
        track.stroke()
        let p = min(max(progress, 0), 1)
        guard p > 0 else { return }
        let c = NSPoint(x: r.midX, y: r.midY)
        let arc = NSBezierPath()
        // Flipped view: clockwise on screen is increasing angle with clockwise == false.
        arc.appendArc(withCenter: c, radius: r.width / 2, startAngle: -90, endAngle: -90 + 360 * CGFloat(p), clockwise: false)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        Theme.State.primary.setStroke()
        arc.stroke()
    }
}

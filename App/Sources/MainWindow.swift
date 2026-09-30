import AppKit
import SSEditorUI

/// Window content: the workspace host fills the window, a 22 pt status bar sits below it.
@MainActor
final class ShellContentView: NSView {
    let host = WorkspaceHostView()
    let statusBar = StatusBarView()

    override var isFlipped: Bool { true }

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
        let bar = Theme.Metrics.statusBar
        host.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - bar, 0))
        statusBar.frame = CGRect(x: 0, y: max(bounds.height - bar, 0), width: bounds.width, height: bar)
    }
}

/// Left: message (refused edit, autosave failure), right: sequence and project state.
@MainActor
final class StatusBarView: NSView {
    private let message = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var clearWork: DispatchWorkItem?
    /// Background tasks (export queue): a small ring at the right end, visible while jobs exist; click opens the queue.
    private let ring = NSProgressIndicator()
    private let ringButton = NSButton(title: "", target: nil, action: nil)
    var onTasksClicked: ((NSView) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.titlebar.cgColor
        for l in [message, detail] {
            l.font = Theme.Fonts.mini
            l.lineBreakMode = .byTruncatingTail
            addSubview(l)
        }
        message.textColor = Theme.Colors.label2
        detail.textColor = Theme.Colors.label3
        detail.alignment = .right
        ring.style = .spinning
        ring.controlSize = .small
        ring.isIndeterminate = false
        ring.minValue = 0; ring.maxValue = 1
        ringButton.isBordered = false
        ringButton.title = ""
        ringButton.toolTip = "Export queue"
        ringButton.target = self
        ringButton.action = #selector(tasksClicked)
        ringButton.setAccessibilityLabel("Export queue")
        ringButton.isHidden = true
        ring.isHidden = true
        addSubview(ring)
        addSubview(ringButton)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setDetail(_ s: String) { detail.stringValue = s }

    /// `progress` nil hides the ring (no active jobs); 0...1 shows it.
    func setTasks(progress: Double?) {
        let visible = progress != nil
        if let progress { ring.doubleValue = progress }
        if ring.isHidden == visible { ring.isHidden = !visible; ringButton.isHidden = !visible; needsLayout = true }
    }

    @objc private func tasksClicked() { onTasksClicked?(ringButton) }

    /// Shows `text` for a few seconds.
    func flash(_ text: String, seconds: TimeInterval = 5) {
        message.stringValue = text
        clearWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.message.stringValue = "" } }
        clearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 14
        let y = (bounds.height - h) / 2
        message.frame = CGRect(x: Theme.Spacing.md, y: y, width: bounds.width * 0.5, height: h)
        let ringW: CGFloat = ring.isHidden ? 0 : 20
        detail.frame = CGRect(x: bounds.width * 0.5, y: y, width: bounds.width * 0.5 - Theme.Spacing.md - ringW, height: h)
        ring.frame = CGRect(x: bounds.width - Theme.Spacing.md - 14, y: (bounds.height - 14) / 2, width: 14, height: 14)
        ringButton.frame = ring.frame.insetBy(dx: -3, dy: -3)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.separator.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

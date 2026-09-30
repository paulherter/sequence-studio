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
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setDetail(_ s: String) { detail.stringValue = s }

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
        detail.frame = CGRect(x: bounds.width * 0.5, y: y, width: bounds.width * 0.5 - Theme.Spacing.md, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.separator.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

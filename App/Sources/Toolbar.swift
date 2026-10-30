import AppKit
import SQEditorUI

/// Top bar (design v9 `.top`): our own 44 pt view instead of an NSToolbar, so no Liquid Glass and nothing that changes
/// with macOS updates. From the left: window buttons (gray, colored under the pointer), project name and "Edited 2 min
/// ago", the Edit | Color page switch; at the right the workspace popup and Export. Support lives in the Help menu.
/// Panels are shown and hidden from the Window menu; export progress is the ring in the status bar. State is pushed in
/// by `sync(store:)`.
@MainActor
final class EditorToolbar: NSObject {
    unowned let controller: AppController
    let bar = TopBarView()

    init(controller: AppController) {
        self.controller = controller
        super.init()
        bar.pageSwitch.target = controller
        bar.pageSwitch.action = #selector(AppController.toolbarPage(_:))
        bar.exportButton.target = controller
        bar.exportButton.action = #selector(AppController.toolbarExport(_:))
        bar.exportButton.sqToolTip = KeyboardListing.tip("Export…", .export)
    }

    /// Pushes the current page into the Edit | Color switch.
    func sync(store: WorkspaceStore) {
        bar.pageSwitch.selectedSegment = store.page == .color ? 1 : 0
        bar.needsLayout = true
        bar.workspacePopup.needsDisplay = true
    }
}

/// The 44 pt bar at the top of the window content (the window uses `fullSizeContentView`, title hidden). Fill `titlebar`.
/// The system close / minimize / zoom buttons stay (behavior, menus and accessibility are theirs) but show only while the
/// pointer is over them; at rest the bar draws three gray dots in their place. Dragging empty bar space moves the window,
/// a double-click zooms or minimizes it (system setting).
@MainActor
final class TopBarView: NSView {
    let pageSwitch = SQSegmented(labels: ["Edit", "Color"], segmentWidth: 0)
    /// Project name (the window title), 13 semibold.
    let titleLabel = NSTextField(labelWithString: "")
    /// "Edited 2 min ago" right of the name (empty until the project was saved or edited).
    let subtitleLabel = NSTextField(labelWithString: "")
    private(set) var subtitleText = ""
    private var titleObservation: NSKeyValueObservation?
    private var editedDate: Date?
    private var subtitleTimer: Timer?
    let workspacePopup = SQPopup(frame: .zero, pullsDown: true)
    let exportButton = SQButton(title: "Export", target: nil, action: nil, style: .accent)
    /// Total height: the bar (no divider line; the 2 pt gap above the panel cards separates it).
    static let height = ShellMetrics.topBar
    nonisolated override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        pageSwitch.isPageSwitch = true
        pageSwitch.images = [SQIcon.pageEdit.image(size: ShellMetrics.pageIcon), SQIcon.pageColor.image(size: ShellMetrics.pageIcon)]
        pageSwitch.setAccessibilityLabel("Workspace page")
        pageSwitch.setAccessibilityName("Edit page", forSegment: 0)
        pageSwitch.setAccessibilityName("Color page", forSegment: 1)
        pageSwitch.setToolTip("Edit Page", forSegment: 0)
        pageSwitch.setToolTip(Tooltip.text("Color Page", command: .focusPanel(.colorInspector)), forSegment: 1)
        workspacePopup.setTooltip("Workspace", command: .resetLayout)
        workspacePopup.setAccessibilityLabel("Workspace")
        workspacePopup.isFlat = true
        workspacePopup.sizesToTitle = true
        workspacePopup.font = Theme.Typography.shell
        let control = ShellMetrics.topControl
        pageSwitch.boxHeight = control
        workspacePopup.boxHeight = control
        titleLabel.font = Theme.Typography.windowTitle
        titleLabel.textColor = Theme.Colors.label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityLabel("Project name")
        subtitleLabel.font = Theme.Typography.body
        subtitleLabel.textColor = Theme.Colors.label3
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setAccessibilityLabel("Last edit")
        exportButton.quietFont = Theme.Typography.shell
        exportButton.horizontalPadding = Theme.Spacing.md
        exportButton.cornerRadius = Theme.Radius.control
        exportButton.boxHeight = control
        exportButton.setAccessibilityLabel("Export")
        for v in [titleLabel, subtitleLabel, pageSwitch, workspacePopup, exportButton] as [NSView] { addSubview(v) }
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Toolbar")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Left edge of the name: padding, three window buttons, one gap (v9: 16 + 3 × 12 + 2 × 8 + 12 = 80).
    static var titleX: CGFloat {
        ShellMetrics.topLeading + 3 * ShellMetrics.windowLight + 2 * ShellMetrics.windowLightGap + ShellMetrics.topGap
    }
    /// v9 `.top .seg{margin-left:16px}` on top of the bar's gap.
    static let pageSwitchLead: CGFloat = 16
    /// A label draws its text 2 pt inside its frame.
    private static let labelInset: CGFloat = 2

    private func textWidth(_ l: NSTextField) -> CGFloat {
        ceil((l.stringValue as NSString).size(withAttributes: [.font: l.font ?? Theme.Typography.body]).width) + 2 * Self.labelInset
    }

    /// Width of the widest "Edited …" text ("Edited 59 min ago" and its siblings).
    static func subtitleSlotWidth(_ font: NSFont) -> CGFloat {
        ["Edited just now", "Edited 59 min ago", "Edited 23 h ago", "Edited 99 d ago"]
            .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
    }

    override func layout() {
        super.layout()
        let ch = ShellMetrics.topControl, y = ((ShellMetrics.topBar - ch) / 2).rounded()
        let gap = ShellMetrics.topGap
        let exportW = exportButton.intrinsicContentSize.width
        exportButton.frame = NSRect(x: bounds.width - ShellMetrics.topTrailing - exportW, y: y, width: exportW, height: ch)
        let popW = workspacePopup.intrinsicContentSize.width
        workspacePopup.frame = NSRect(x: exportButton.frame.minX - Theme.Spacing.sm - popW, y: y, width: popW, height: ch)
        // Name, "Edited …" and the page switch from the left; when the bar gets narrow the edit time goes first, then
        // the name shortens. The page switch never shrinks.
        let seg = pageSwitch.intrinsicContentSize
        let segLead = gap + Self.pageSwitchLead
        let left = Self.titleX - Self.labelInset
        let room = max(workspacePopup.frame.minX - gap - seg.width - segLead - left, 0)
        // The edit time has a reserved slot (its widest text), so the page switch stays put while it appears,
        // disappears or changes.
        let subGap = Theme.Spacing.sm - 2 * Self.labelInset
        let subSlot = Self.subtitleSlotWidth(subtitleLabel.font ?? Theme.Typography.body) + 2 * Self.labelInset
        let nameW = min(textWidth(titleLabel), 360, max(room - subGap - subSlot, 0))
        let th = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(x: left, y: ((ShellMetrics.topBar - th) / 2).rounded(), width: nameW, height: th)
        var x = titleLabel.frame.maxX
        let subW = textWidth(subtitleLabel)
        let showsSub = !subtitleText.isEmpty && subW <= subSlot
        subtitleLabel.isHidden = !showsSub
        if showsSub {
            let sh = subtitleLabel.intrinsicContentSize.height
            // Same baseline as the name.
            let base = titleLabel.frame.minY + titleLabel.firstBaselineOffsetFromTop
            subtitleLabel.frame = NSRect(x: x + subGap, y: (base - subtitleLabel.firstBaselineOffsetFromTop).rounded(), width: subW, height: sh)
        }
        x += subGap + subSlot
        pageSwitch.frame = NSRect(x: x - Self.labelInset + segLead, y: y, width: seg.width, height: ch)
        if let window { SQWindowLights.reapply(in: window) }   // a page or tab switch lays the title bar out again
    }

    /// Time of the last edit, shown as "Edited 2 min ago" after the name; nil (nothing saved or edited yet) clears it.
    func setEdited(_ date: Date?) {
        editedDate = date
        refreshSubtitle()
    }

    private func refreshSubtitle() {
        let text = editedDate.map { "Edited " + Self.relative(from: $0, to: Date()) } ?? ""
        guard subtitleText != text else { return }
        subtitleText = text
        subtitleLabel.stringValue = text
        needsLayout = true
    }

    /// "just now", "2 min ago", "3 h ago", "4 d ago".
    static func relative(from date: Date, to now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86_400)) d ago"
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        subtitleTimer?.invalidate()
        guard let window else { subtitleTimer = nil; return }
        subtitleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSubtitle() }
        }
        titleLabel.stringValue = window.title
        titleObservation = window.observe(\.title, options: [.new]) { [weak self] _, change in
            let t = change.newValue ?? ""
            MainActor.assumeIsolated { self?.titleLabel.stringValue = t; self?.needsLayout = true }
        }
        SQWindowLights.install(in: window, layout: .editor)   // the real buttons, where the v9 dots are
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
            return
        }
        window.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.titlebar.setFill()
        bounds.fill()
    }
}

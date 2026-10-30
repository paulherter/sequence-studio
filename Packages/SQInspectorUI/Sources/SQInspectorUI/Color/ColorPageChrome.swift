import AppKit
import SQCore

/// Shared metrics of the Color page's panel headers (design source `.ph`): inset 6 left, 8 right, controls 4 apart.
enum ColorHeaderMetrics {
    static let height = Theme.Row.panelHeader
    static let left: CGFloat = 6
    static let right = Theme.Spacing.sm
    static let gap = Theme.Spacing.xs
    /// Plain text in a header sits 6 px inside a tab pill's place.
    static let textInset: CGFloat = 6

    static func label(_ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = font
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    @MainActor static func drawBottomRule(in bounds: NSRect) {
        Theme.Separator.hairline.setFill()
        NSRect(x: 0, y: bounds.height - Theme.Separator.width, width: bounds.width, height: Theme.Separator.width).fill()
    }
}

/// Viewer header of the Color page (design board "Color"): clip name, "n of m", then Before | After | Split and the
/// more-actions button at the right.
@MainActor
public final class ColorViewerHeaderView: NSView {
    /// Before / After / Split was picked.
    public var onCompareChange: ((ColorCompareMode) -> Void)?
    /// The more-actions button was pressed; the point is its lower left corner on screen.
    public var onMore: ((NSPoint) -> Void)?

    public private(set) var content = ColorViewerHeaderContent(name: "")
    public private(set) var compare = ColorCompareMode.after
    private let name = ColorHeaderMetrics.label(Theme.Typography.bodyStrong, Theme.Colors.label)
    private let position = ColorHeaderMetrics.label(Theme.Typography.body, Theme.Colors.label3)
    private let segment = SQSegmented(labels: ColorCompareMode.allCases.map(\.title), segmentWidth: 0)
    private lazy var more = SQButton(symbol: .ellipsis, label: "More viewer actions", target: self, action: #selector(morePressed), size: 12)

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: ColorHeaderMetrics.height) }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: ColorHeaderMetrics.height))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        segment.selectedSegment = compare.rawValue
        segment.target = self
        segment.action = #selector(compareChanged)
        segment.setAccessibilityLabel("Compare")
        more.contentTintColor = Theme.Colors.label2     // board `.btn.ic`: t2
        for v in [name, position, segment, more] as [NSView] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Viewer")
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public func show(_ c: ColorViewerHeaderContent) {
        guard c != content else { return }
        content = c
        name.stringValue = c.name
        name.sqToolTip = c.name
        position.stringValue = c.position ?? ""
        needsLayout = true
    }

    /// Shows `mode` without calling `onCompareChange`.
    public func setCompare(_ mode: ColorCompareMode) {
        compare = mode
        segment.selectedSegment = mode.rawValue
    }

    @objc private func compareChanged() {
        guard let m = ColorCompareMode(rawValue: segment.selectedSegment), m != compare else { return }
        compare = m
        onCompareChange?(m)
    }

    @objc private func morePressed() {
        guard let window else { return }
        onMore?(window.convertPoint(toScreen: more.convert(NSPoint(x: more.bounds.minX, y: more.bounds.maxY), to: nil)))
    }

    public override func draw(_ dirtyRect: NSRect) { ColorHeaderMetrics.drawBottomRule(in: bounds) }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// The string's own width (a label's intrinsic width follows its current frame and truncates early).
    private static func textWidth(_ l: NSTextField) -> CGFloat {
        ceil((l.stringValue as NSString).size(withAttributes: [.font: l.font ?? Theme.Typography.body]).width) + 4
    }

    public override func layout() {
        super.layout()
        let h = bounds.height
        var right = bounds.width - ColorHeaderMetrics.right
        for c in [more, segment] as [NSView] {
            var s = c.intrinsicContentSize
            if c === more { s.width = Theme.Metrics.barIconWidth }   // board `.btn.ic`: 24 wide
            right -= s.width
            c.frame = NSRect(x: right, y: ((h - s.height) / 2).rounded(), width: s.width, height: s.height)
            right -= Theme.Spacing.iconToLabel      // board: 2 px flex gap + 4 px margin
        }
        var x = ColorHeaderMetrics.left + ColorHeaderMetrics.textInset
        let room = max(right - Theme.Spacing.sm - x, 0)
        let pw = position.stringValue.isEmpty ? 0 : Self.textWidth(position)
        let nw = min(Self.textWidth(name), max(room - pw - (pw > 0 ? 2 * ColorHeaderMetrics.textInset : 0), 0))
        let nh = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: x, y: ((h - nh) / 2).rounded(), width: nw, height: nh)
        x += nw + 2 * ColorHeaderMetrics.textInset
        position.frame = NSRect(x: x, y: ((h - nh) / 2).rounded(), width: min(pw, max(right - x, 0)), height: nh)
    }
}

/// Panel header of the Color page (version 9 `.ph` with `.tab`): text tabs, the selected one in `label` over a 2 pt
/// line at the header's lower edge, a quiet meta text and icon buttons at the right. The meta follows the first tab
/// while that one shows (version 9: "Scopes Rec. 709", "Steps Color Graph"), the last tab otherwise.
@MainActor
public final class ColorTabHeaderView: NSView {
    public var tabs: [String] = [] { didSet { if tabs != oldValue { needsDisplay = true; needsLayout = true } } }
    public private(set) var selected = 0
    /// The quiet text ("Rec. 709", "Color Graph").
    public var meta = "" { didSet { if meta != oldValue { needsDisplay = true } } }
    private var metaText: NSAttributedString {
        NSAttributedString(string: meta, attributes: [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3])
    }
    /// The meta sits between the first tab and the second.
    private var metaLeads: Bool { selected == 0 && !meta.isEmpty && tabs.count > 1 }
    /// Controls at the right end, left to right.
    public var tools: [NSView] = [] {
        didSet {
            for v in oldValue where !tools.contains(where: { $0 === v }) { v.removeFromSuperview() }
            for v in tools where v.superview !== self { addSubview(v) }
            needsLayout = true
        }
    }
    /// A tab was clicked (not called by `select`).
    public var onSelect: ((Int) -> Void)?

    /// Header inset to the first tab's box, and the tab's own side padding (version 9: text starts 20 pt in).
    static let inset = Theme.Spacing.md
    static let tabPad = Theme.Spacing.sm
    static let toolGap = Theme.Spacing.xxs

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: ColorHeaderMetrics.height) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public init(tabs: [String] = []) {
        self.tabs = tabs
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: ColorHeaderMetrics.height))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        setAccessibilityRole(.tabGroup)
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    /// Shows tab `i` without calling `onSelect`.
    public func select(_ i: Int) {
        guard i != selected, tabs.indices.contains(i) else { return }
        selected = i
        needsDisplay = true
    }

    private func attrs(_ on: Bool) -> [NSAttributedString.Key: Any] {
        [.font: on ? Theme.Typography.bodyStrong : Theme.Typography.body, .foregroundColor: on ? Theme.Colors.label : Theme.Colors.label3]
    }

    /// The tab boxes (text plus padding), left to right.
    public var tabFrames: [NSRect] {
        var x = Self.inset - Self.tabPad
        let lead = metaLeads ? ceil(metaText.size().width) + Theme.Spacing.iconToLabel : 0
        return tabs.enumerated().map { i, t in
            let w = ceil((t as NSString).size(withAttributes: attrs(i == selected)).width) + 2 * Self.tabPad
            defer { x += w + (i == 0 ? lead : 0) }
            return NSRect(x: x, y: 0, width: w, height: bounds.height)
        }
    }

    /// The hairline at the header's lower edge; the Pro page's tab row has none.
    public var showsBottomRule = true { didSet { if showsBottomRule != oldValue { needsDisplay = true } } }

    public override func draw(_ dirtyRect: NSRect) {
        if showsBottomRule { ColorHeaderMetrics.drawBottomRule(in: bounds) }
        var end = Self.inset
        let frames = tabFrames
        for (i, r) in frames.enumerated() {
            let s = NSAttributedString(string: tabs[i], attributes: attrs(i == selected))
            let size = s.size()
            s.draw(at: NSPoint(x: r.minX + Self.tabPad, y: ((bounds.height - size.height) / 2).rounded()))
            if i == selected, tabs.count > 1 {
                Theme.Colors.label3.setFill()
                let line = NSRect(x: r.minX + Self.tabPad, y: bounds.height - Theme.Metrics.tabUnderline, width: r.width - 2 * Self.tabPad,
                                  height: Theme.Metrics.tabUnderline)
                NSBezierPath(roundedRect: line, xRadius: Theme.Metrics.tabUnderline / 2, yRadius: Theme.Metrics.tabUnderline / 2).fill()
            }
            end = r.maxX
        }
        guard !meta.isEmpty else { return }
        if metaLeads, let first = frames.first { end = first.maxX }
        let right = (tools.first(where: { !$0.isHidden })?.frame.minX ?? bounds.width) - Theme.Spacing.sm
        let m = metaText
        let h = ceil(m.size().height)
        let x = end - Self.tabPad + Theme.Spacing.iconToLabel
        guard right > x else { return }
        m.draw(with: NSRect(x: x, y: ((bounds.height - h) / 2).rounded() + 1, width: right - x, height: h),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = tabFrames.firstIndex(where: { $0.contains(p) }), i != selected else { return }
        select(i)
        onSelect?(i)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        var right = bounds.width - Theme.Spacing.sm
        for c in tools.reversed() where !c.isHidden {
            var s = c.intrinsicContentSize
            if let b = c as? SQButton, b.title.isEmpty { s.width = Theme.Metrics.barIconWidth }
            right -= s.width
            c.frame = NSRect(x: right, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            right -= Self.toolGap
        }
        needsDisplay = true
    }
}

/// The header tools of a Color page panel (Steps, Sources, Timeline): Copy grade and Paste grade, plus Add step on the
/// Steps panel. Each panel's tab strip owns its own buttons (a view has one superview), so every panel gets one instance.
@MainActor
public final class ColorGradeTools {
    public var onCopy: (() -> Void)?
    public var onPaste: (() -> Void)?
    /// The "+" button: gets the screen point under the button to open the Add Step menu there.
    public var onAddStep: ((NSPoint) -> Void)?
    public private(set) var add: IconButton?
    public let copy: IconButton
    public let paste: IconButton

    /// The buttons for the tab strip, left to right.
    public var views: [NSView] { (add.map { [$0] } ?? []) + [copy, paste] }

    public init(addsStep: Bool) {
        let relay = ToolRelay()
        copy = IconButton(symbol: .copy, label: "Copy Grade", size: 12) { relay.copy?() }
        paste = IconButton(symbol: .paste, label: "Paste grade", size: 12) { relay.paste?() }
        copy.sqToolTip = "Copy the grade of what is being graded"
        paste.sqToolTip = "Paste the copied grade onto the selected clips"
        if addsStep {
            let button = IconButton(symbol: .plus, label: "Add step", size: 12) { relay.add?() }
            button.sqToolTip = "Add a Step after the selected one"
            add = button
            relay.add = { [weak self, weak button] in
                guard let self, let button else { return }
                guard let w = button.window else { self.onAddStep?(.zero); return }
                self.onAddStep?(w.convertPoint(toScreen: button.convert(NSPoint(x: 0, y: button.bounds.maxY), to: nil)))
            }
        }
        relay.copy = { [weak self] in self?.onCopy?() }
        relay.paste = { [weak self] in self?.onPaste?() }
    }

    public func setActions(canCopy: Bool, canPaste: Bool, canAdd: Bool = true) {
        if copy.isEnabled != canCopy { copy.isEnabled = canCopy }
        if paste.isEnabled != canPaste { paste.isEnabled = canPaste }
        if let add, add.isEnabled != canAdd { add.isEnabled = canAdd }
    }
}

/// Late-bound button actions (the buttons are created before `self` is complete).
@MainActor
private final class ToolRelay {
    var copy: (() -> Void)?
    var paste: (() -> Void)?
    var add: (() -> Void)?
}

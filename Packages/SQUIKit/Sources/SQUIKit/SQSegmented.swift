import AppKit

/// Segmented switch (design artifact v11, sq.css `.seg`), used only where a rounded selection carries meaning (Edit|Color,
/// mode switches): track 22 high with 6 px corners, `fill2`, no frame, 1 px padding; selected segment is an inner
/// 4 px-corner shape `fillPressed` + white text, unselected text `label`, 11 pt. Segment width fixed (`segmentWidth`, default 60) or fitted to the label when 0.
/// `isPageSwitch` gives the v9 top-bar look (`.seg`: `field` track, 2 px padding and gap, icon + 12 pt label, the selected
/// segment raised). A click anywhere in a segment's column selects it; every segment is a pressable radio button for
/// assistive tech.
/// The API mirrors the parts of NSSegmentedControl the app uses (`selectedSegment`, `segmentCount`, target/action),
/// so call sites only change the type.
open class SQSegmented: NSControl {
    public private(set) var labels: [String]
    public var images: [NSImage?] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var segmentWidth: CGFloat { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var boxHeight: CGFloat = Theme.Metrics.capsule { didSet { invalidateIntrinsicContentSize() } }
    /// v9 `.seg` of the top bar: icon and label side by side, `field` track, raised selected segment.
    public var isPageSwitch = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Icon left of the label in every segment (the Simple | Pro switch): 6 px gap, centered as one group. Always on in `isPageSwitch`.
    public var showsIconBesideLabel = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Opt-in keyboard access: the switch takes focus (Tab) and Left / Right (or Up / Down) select the neighbor segment.
    public var acceptsKeyboard = false
    private var iconBesideLabel: Bool { isPageSwitch || showsIconBesideLabel }
    public var selectedSegment: Int = 0 {
        didSet { if oldValue != selectedSegment { needsDisplay = true; updateAccessibility() } }
    }
    public var segmentCount: Int { labels.count }
    /// Toggle mode (like NSSegmentedControl `.selectAny`): every click flips that segment; `selectedSegment` is unused.
    public var allowsMultipleSelection = false
    public private(set) var selectedSet: Set<Int> = []
    private var disabledSegments: Set<Int> = []
    public func setEnabled(_ on: Bool, forSegment i: Int) {
        if on { disabledSegments.remove(i) } else { disabledSegments.insert(i) }
        needsDisplay = true
    }
    public func isEnabled(forSegment i: Int) -> Bool { !disabledSegments.contains(i) }
    public func isSelected(forSegment i: Int) -> Bool { allowsMultipleSelection ? selectedSet.contains(i) : i == selectedSegment }
    public func setSelected(_ on: Bool, forSegment i: Int) {
        if on { selectedSet.insert(i) } else { selectedSet.remove(i) }
        needsDisplay = true
    }
    var hovered: Int? { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?
    private var toolTips: [Int: String] = [:]
    private var segmentNames: [Int: String] = [:]
    private var elements: [SQSegmentElement] = []

    public init(labels: [String], segmentWidth: CGFloat = 60, target: AnyObject? = nil, action: Selector? = nil) {
        self.labels = labels
        self.segmentWidth = segmentWidth
        super.init(frame: .zero)
        self.target = target
        self.action = action
        focusRingType = .none
        setAccessibilityRole(.radioGroup)
        elements = labels.indices.map { SQSegmentElement(owner: self, index: $0) }
        setAccessibilityChildren(elements)
        updateAccessibility()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public static let font = Theme.Typography.body
    var labelFont: NSFont { isPageSwitch ? Theme.Typography.shell : Self.font }

    public func setLabel(_ label: String, forSegment i: Int) {
        guard labels.indices.contains(i) else { return }
        labels[i] = label
        invalidateIntrinsicContentSize(); needsDisplay = true
    }
    public func label(forSegment i: Int) -> String? { labels.indices.contains(i) ? labels[i] : nil }
    public func setToolTip(_ tip: String?, forSegment i: Int) { toolTips[i] = tip }
    /// The name assistive tech reads for segment `i` (default: its label, else its tooltip).
    public func setAccessibilityName(_ name: String?, forSegment i: Int) { segmentNames[i] = name }
    public func accessibilityName(forSegment i: Int) -> String? {
        if let n = segmentNames[i] { return n }
        if let l = label(forSegment: i), !l.isEmpty { return l }
        return toolTips[i]
    }

    private func image(_ i: Int) -> NSImage? { images.indices.contains(i) ? images[i] : nil }

    func width(of i: Int) -> CGFloat {
        if segmentWidth > 0 { return segmentWidth }
        let text = ceil((labels[i] as NSString).size(withAttributes: [.font: labelFont]).width)
        if iconBesideLabel {
            return Self.pagePadding * 2 + text + (image(i).map { $0.size.width + Self.pageIconGap } ?? 0)
        }
        if let img = image(i), labels[i].isEmpty { return img.size.width + 16 }
        return text + 20
    }

    private var contentWidth: CGFloat {
        (0..<labels.count).reduce(0) { $0 + width(of: $1) } + CGFloat(max(labels.count - 1, 0)) * gap + 2 * pad
    }

    open override var intrinsicContentSize: NSSize { NSSize(width: contentWidth, height: boxHeight) }

    /// Fits the custom-drawn box (the cell's own size would be the system control's).
    open override func sizeToFit() { setFrameSize(intrinsicContentSize) }

    /// 1 px between the track edge and the segments (sq.css `.seg{padding:1px}`).
    static let trackPadding: CGFloat = 1
    /// v9 `.seg`: 2 px padding and 2 px between segments, segment padding 0 10, icon to label 6.
    static let pageTrackPadding: CGFloat = 2
    static let pagePadding: CGFloat = 10
    static let pageIconGap: CGFloat = 6
    var pad: CGFloat { isPageSwitch ? Self.pageTrackPadding : Self.trackPadding }
    var gap: CGFloat { isPageSwitch ? Self.pageTrackPadding : 0 }

    /// The capsule track.
    var trackRect: NSRect {
        let h = min(boxHeight, bounds.height)
        return NSRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: contentWidth, height: h)
    }

    func segmentRect(_ i: Int) -> NSRect {
        let t = trackRect
        var x = t.minX + pad
        for j in 0..<i { x += width(of: j) + gap }
        return NSRect(x: x, y: t.minY + pad, width: width(of: i), height: t.height - 2 * pad)
    }

    /// The whole column of segment `i`: its drawn shape plus the track padding and half the gap, at the full view height.
    /// A click anywhere in it counts (the drawn shape alone left dead pixels at the track edge).
    func columnRect(_ i: Int) -> NSRect {
        let r = segmentRect(i), t = trackRect
        let lo = i == 0 ? t.minX : r.minX - gap / 2
        let hi = i == labels.count - 1 ? t.maxX : r.maxX + gap / 2
        return NSRect(x: lo, y: bounds.minY, width: hi - lo, height: bounds.height)
    }

    public func segment(at p: NSPoint) -> Int? {
        (0..<labels.count).first { columnRect($0).contains(p) }
    }

    // The switch sits in the window's title bar area: a click must select, never start a window drag, and the first
    // click on an inactive window counts.
    open override var mouseDownCanMoveWindow: Bool { false }
    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }
    open override func mouseMoved(with event: NSEvent) {
        hovered = segment(at: convert(event.locationInWindow, from: nil))
        sqToolTip = hovered.flatMap { toolTips[$0] }
    }
    open override func mouseExited(with event: NSEvent) { hovered = nil }

    open override var acceptsFirstResponder: Bool { acceptsKeyboard && isEnabled }
    open override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    open override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    open override func keyDown(with event: NSEvent) {
        guard acceptsKeyboard, !allowsMultipleSelection else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123, 126: step(-1)   // left, up
        case 124, 125: step(1)    // right, down
        default: super.keyDown(with: event)
        }
    }
    /// Selects the nearest enabled segment in `direction` (no wrap) and sends the action.
    func step(_ direction: Int) {
        var j = selectedSegment + direction
        while labels.indices.contains(j) {
            if press(j) { return }
            j += direction
        }
    }

    open override func mouseDown(with event: NSEvent) {
        guard let i = segment(at: convert(event.locationInWindow, from: nil)) else { return }
        press(i)
    }

    /// Selects (or, in toggle mode, flips) segment `i` and sends the action: a click or an accessibility press.
    @discardableResult
    public func press(_ i: Int) -> Bool {
        guard isEnabled, labels.indices.contains(i), !disabledSegments.contains(i) else { return false }
        if allowsMultipleSelection {
            setSelected(!selectedSet.contains(i), forSegment: i)
            sendAction(action, to: target)
            return true
        }
        guard i != selectedSegment else { return true }
        selectedSegment = i
        sendAction(action, to: target)
        return true
    }

    open override func draw(_ dirtyRect: NSRect) {
        guard !labels.isEmpty else { return }
        let track = trackRect
        let dim = isEnabled ? 1 : Theme.State.disabledAlpha
        let trackColor = isPageSwitch ? Theme.Colors.field : Theme.Colors.fill2
        trackColor.withAlphaComponent(trackColor.alphaComponent * dim).setFill()
        ControlShape.capsule(track).fill()   // design v7 `.seg`: 6 px track, no frame
        for i in 0..<labels.count {
            let r = segmentRect(i)
            let selected = isSelected(forSegment: i)
            if selected {
                let c = isPageSwitch ? Theme.Colors.overlay : Theme.State.selectedSegment
                c.withAlphaComponent(c.alphaComponent * dim).setFill()
                if isPageSwitch {   // v9 `.seg [aria-selected=true]`: raised, shadow 0 1 2 black 25 %
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = Theme.black(0.25)
                    shadow.shadowOffset = NSSize(width: 0, height: -1)
                    shadow.shadowBlurRadius = 2
                    shadow.set()
                    ControlShape.inner(r).fill()
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    ControlShape.inner(r).fill()
                }
            } else if hovered == i, isEnabled {
                Theme.State.controlHover.setFill()
                ControlShape.inner(r).fill()
            }
            let base: NSColor = isPageSwitch ? (selected ? Theme.Colors.label : Theme.Colors.label2)
                                             : (selected ? NSColor.white : Theme.Colors.label)
            let fg = base.withAlphaComponent(base.alphaComponent * (disabledSegments.contains(i) ? Theme.State.disabledAlpha : dim))
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: fg]
            let ts = (labels[i] as NSString).size(withAttributes: attrs)
            func drawImage(_ img: NSImage, x: CGFloat) {
                let s = img.size
                SQButton.tinted(img, fg).draw(in: NSRect(x: x.rounded(), y: (r.midY - s.height / 2).rounded(), width: s.width, height: s.height),
                                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            if let img = image(i), labels[i].isEmpty {
                drawImage(img, x: r.midX - img.size.width / 2)
                continue
            }
            var x = r.midX - ts.width / 2
            if iconBesideLabel, let img = image(i) {
                x = r.midX - (img.size.width + Self.pageIconGap + ts.width) / 2
                drawImage(img, x: x)
                x += img.size.width + Self.pageIconGap
            }
            (labels[i] as NSString).draw(at: NSPoint(x: x.rounded(), y: (r.midY - ts.height / 2).rounded()), withAttributes: attrs)
        }
        if ControlShape.isFocused(self) { ControlShape.drawFocusLine(in: track, radius: ControlShape.radius(track)) }
    }

    private func updateAccessibility() {
        setAccessibilityValue(label(forSegment: selectedSegment))
    }
}

/// One segment for assistive tech and UI scripting: a radio button with a name, a frame and a press action.
final class SQSegmentElement: NSAccessibilityElement {
    private weak var owner: SQSegmented?
    private let index: Int

    init(owner: SQSegmented, index: Int) {
        self.owner = owner
        self.index = index
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { owner?.accessibilityName(forSegment: index) }
    override func accessibilityValue() -> Any? { NSNumber(value: owner?.isSelected(forSegment: index) ?? false) }
    override func accessibilityParent() -> Any? { owner }
    override func isAccessibilityEnabled() -> Bool { owner.map { $0.isEnabled && $0.isEnabled(forSegment: index) } ?? false }
    override func accessibilityFrame() -> NSRect {
        guard let owner else { return .zero }
        return NSAccessibility.screenRect(fromView: owner, rect: owner.columnRect(index))
    }
    override func accessibilityPerformPress() -> Bool { owner?.press(index) ?? false }
}

import AppKit
import SQCore

/// One track's header (design v9 `.th`): target chip (V1 / A1, accent-filled while targeted), name, then lock + eye (video)
/// or M + S (audio). A locked audio track and a switched-off sync lock show one more button left of them, so the state is
/// never hidden; both commands are in the header's right-click menu. Clicks are reported through `onToggle`.
@MainActor
public final class TrackHeaderView: NSView {
    public private(set) var trackID: Track.ID
    public var onToggle: ((Track.ID, TrackToggle) -> Void)?
    /// Source patch chip (MON-30): a click toggles the connection of that stream.
    public var onPatchClick: ((TrackKind) -> Void)?
    /// Double-click on an empty header area; the flag is Shift (every track of the kind).
    public var onDoubleClick: ((_ wholeKind: Bool) -> Void)?
    /// Source patch chip dragged: the pointer in window coordinates; `ended` on mouse-up.
    /// Modifier keys of the chip gesture that is just ending (read inside `onPatchClick` / the ended `onPatchDrag`).
    public private(set) var patchGestureFlags: NSEvent.ModifierFlags = []
    public var onPatchDrag: ((TrackKind, NSPoint, _ ended: Bool) -> Void)?

    private var track: Track
    private var label: String
    private let eyeButton = TrackHeaderView.makeButton()
    private let muteButton = TrackHeaderView.makeButton()
    private let soloButton = TrackHeaderView.makeButton()
    private let lockButton = TrackHeaderView.makeButton()
    private let syncButton = TrackHeaderView.makeButton()
    private let chipButton = TrackHeaderView.makeButton()
    /// The row above the video / audio split (V1): a 2 pt strong line below it (v9 `.th.vsplit`).
    public var isSplitRow = false { didSet { if isSplitRow != oldValue { needsDisplay = true } } }

    /// v9 `.th .tgt`: at least 32 wide, 20 high, radius 4.
    static let chipWidth: CGFloat = 32
    static let chipHeight: CGFloat = 20
    /// v9 `.th .ibtn.sm` / `.ms`: 24 x 24. Rows under 30 pt get smaller buttons (the design drops them; here nothing disappears).
    static let buttonSize: CGFloat = 24
    static let buttonGap: CGFloat = 4
    static let leftPadding: CGFloat = 6
    static let rightPadding: CGFloat = 4
    static func buttonSize(rowHeight: CGFloat) -> CGFloat { rowHeight >= 30 ? buttonSize : max(14, min(buttonSize, rowHeight - 4)) }
    /// Source patch chip: 16 x 14, in a column left of the badge that exists while a source is loaded.
    static let patchWidth: CGFloat = 16
    static let patchGap: CGFloat = 4

    /// What the patch column shows on this row.
    public struct PatchState: Equatable, Sendable {
        /// The column is there (a source is loaded); off: the badge sits at the left edge as before.
        public var column: Bool
        /// The source stream patched to this track and whether it is connected; nil: an empty cell.
        public var chip: (kind: TrackKind, connected: Bool)?
        /// A patch chip is being dragged over this row.
        public var dropHighlight: Bool
        public init(column: Bool = false, chip: (kind: TrackKind, connected: Bool)? = nil, dropHighlight: Bool = false) {
            self.column = column; self.chip = chip; self.dropHighlight = dropHighlight
        }
        public static func == (l: PatchState, r: PatchState) -> Bool {
            l.column == r.column && l.dropHighlight == r.dropHighlight
                && l.chip?.kind == r.chip?.kind && l.chip?.connected == r.chip?.connected
        }
    }
    public private(set) var patch = PatchState()

    /// C6: a selected clip uses this track as a Picture mask (marker at the right edge of the badge row).
    public var isMatteSource = false {
        didSet {
            guard oldValue != isMatteSource else { return }
            sqToolTip = isMatteSource ? "A selected clip uses this track's picture as a mask" : nil
            needsDisplay = true
        }
    }

    public func apply(patch p: PatchState) {
        guard p != patch else { return }
        let reflow = p.column != patch.column
        patch = p
        if reflow { needsLayout = true }
        needsDisplay = true
    }
    private var patchTooltipArea: NSView.ToolTipTag?

    public nonisolated override var isFlipped: Bool { true }

    public init(track: Track, label: String) {
        self.track = track; self.trackID = track.id; self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        // macOS 14+: views do not clip by default, so an opaque `dirtyRect.fill()` would paint over its siblings.
        clipsToBounds = true
        for (button, toggle) in [(eyeButton, TrackToggle.visible), (muteButton, .mute), (soloButton, .solo),
                                 (lockButton, .lock), (syncButton, .syncLock), (chipButton, .target)] {
            button.target = self
            button.action = #selector(clicked(_:))
            button.tag = Self.tag(toggle)
            addSubview(button)
        }
        chipButton.drawsNothing = true
        muteButton.letter = "M"; muteButton.filled = true
        soloButton.letter = "S"; soloButton.filled = true
        chipButton.setTooltip("Target Track")
        eyeButton.setTooltip("Show or Hide Track")
        muteButton.setTooltip("Mute Track")
        soloButton.setTooltip("Solo Track")
        lockButton.setTooltip("Lock Track")
        syncButton.setTooltip("Sync Lock")
        apply(track: track, label: label)
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    private static func makeButton() -> TrackHeaderButton {
        let b = TrackHeaderButton(frame: .zero)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.setButtonType(.momentaryChange)
        b.focusRingType = .none
        return b
    }

    private static func tag(_ t: TrackToggle) -> Int {
        switch t { case .target: 0; case .visible: 1; case .mute: 2; case .solo: 3; case .lock: 4; case .syncLock: 5 }
    }

    @objc private func clicked(_ sender: NSButton) {
        let all: [TrackToggle] = [.target, .visible, .mute, .solo, .lock, .syncLock]
        onToggle?(trackID, all[sender.tag])
    }

    /// What the header shows of a track; `apply` rebuilds buttons and redraws only when this or the label changes.
    private struct Shown: Equatable {
        var id: Track.ID, kind: TrackKind, name: String
        var visible, muted, solo, locked, syncLock, targeted: Bool
        init(_ t: Track) {
            id = t.id; kind = t.kind; name = t.name
            visible = t.isVisible; muted = t.isMuted; solo = t.isSolo; locked = t.isLocked; syncLock = t.syncLock; targeted = t.isTargeted
        }
    }
    private var shown: (state: Shown, label: String)?
    /// Times `apply` actually changed the header (tests: scrolling must not rebuild headers).
    private(set) var contentApplyCount = 0

    public func apply(track: Track, label: String) {
        let state = Shown(track)
        if let s = shown, s.state == state, s.label == label { self.track = track; return }
        shown = (state, label)
        contentApplyCount += 1
        self.track = track; self.label = label; trackID = track.id
        let isVideo = track.kind == .video
        eyeButton.isHidden = !isVideo
        muteButton.isHidden = isVideo
        soloButton.isHidden = isVideo
        eyeButton.glyph = Self.symbolImage(track.isVisible ? .eye : .eyeOff, description: "Visibility")
        eyeButton.tint = track.isVisible ? Theme.Colors.label2 : Theme.Colors.warning
        eyeButton.setAccessibilityLabel(track.isVisible ? "Hide track" : "Show track")
        muteButton.isOn = track.isMuted; muteButton.tint = track.isMuted ? Theme.Colors.accent : Theme.Colors.label2
        muteButton.setAccessibilityLabel("Mute")
        soloButton.isOn = track.isSolo; soloButton.tint = track.isSolo ? Theme.Colors.yellow : Theme.Colors.label2
        soloButton.setAccessibilityLabel("Solo")
        lockButton.glyph = Self.symbolImage(.trackLock, description: "Lock")
        lockButton.tint = track.isLocked ? Theme.Colors.accent : Theme.Colors.label2
        lockButton.setAccessibilityLabel("Lock")
        syncButton.glyph = Self.symbolImage(.trackSyncLock, description: "Sync lock")
        syncButton.tint = track.syncLock ? Theme.Colors.label3 : Theme.Colors.warning
        syncButton.setAccessibilityLabel(track.syncLock ? "Sync lock, on" : "Sync lock, off")
        lockButton.isHidden = !showsLock
        syncButton.isHidden = !showsSync
        needsLayout = true
        needsDisplay = true
    }

    /// Sync lock is on by default: its button stays while it is off (warning tint) and shows dim while the pointer is
    /// over the row, so both ways are one click (the right-click menu has them too).
    private var showsSync: Bool { !track.syncLock || rowHovered }
    /// Video rows always carry the lock (v9); audio rows show it while locked, while the pointer is over the row and while the
    /// sync lock button is shown (its slot is left of the lock slot, so a hidden lock would leave a hole next to M).
    private var showsLock: Bool { track.kind == .video || track.isLocked || rowHovered || showsSync }

    /// Pointer over the row: reveals Lock and Sync Lock in their fixed slots. No button moves; the name gets shorter.
    var rowHovered = false {
        didSet {
            guard rowHovered != oldValue else { return }
            lockButton.isHidden = !showsLock
            syncButton.isHidden = !showsSync
            needsLayout = true
            needsDisplay = true
        }
    }
    private var rowHoverArea: NSTrackingArea?
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let rowHoverArea { removeTrackingArea(rowHoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        rowHoverArea = a
    }
    public override func mouseEntered(with event: NSEvent) { rowHovered = true }
    public override func mouseExited(with event: NSEvent) { rowHovered = false }

    private struct SymbolKey: Hashable { var symbol: SQIcon, description: String }
    private static var symbolCache: [SymbolKey: NSImage] = [:]

    /// An icon at the header's size, made once per (icon, description) and shared by all headers.
    static func symbolImage(_ symbol: SQIcon, description: String) -> NSImage? {
        let key = SymbolKey(symbol: symbol, description: description)
        if let hit = symbolCache[key] { return hit }
        let image = Theme.symbol(symbol, size: Theme.Typography.symbolInline, label: description)
        symbolCache[key] = image
        return image
    }

    /// Button positions of a header: they depend on the track's state only, never on hover (no reflow under the pointer).
    struct Slots: Equatable {
        /// `.zero` while not shown.
        var lock: CGRect, sync: CGRect
        var eye: CGRect?, mute: CGRect?, solo: CGRect?
        var nameRight: CGFloat
    }

    /// v9 `.th`: buttons 4 pt apart, 4 pt from the right edge, the name ends 4 pt before the first one.
    /// Right to left: eye, lock (video) or S, M (audio), then the lock of a locked audio track, then a switched-off sync lock.
    static func slots(width: CGFloat, height: CGFloat, kind: TrackKind, showsSync: Bool = false, showsLock: Bool? = nil) -> Slots {
        let s = buttonSize(rowHeight: height), y = ((height - s) / 2).rounded()
        var right = width - rightPadding
        func take() -> CGRect { defer { right -= s + buttonGap }; return CGRect(x: right - s, y: y, width: s, height: s) }
        var eye: CGRect?, mute: CGRect?, solo: CGRect?
        if kind == .video { eye = take() } else { solo = take(); mute = take() }
        let lock = (showsLock ?? (kind == .video)) ? take() : .zero
        let sync = showsSync ? take() : .zero
        return Slots(lock: lock, sync: sync, eye: eye, mute: mute, solo: solo, nameRight: right)
    }

    public override func layout() {
        super.layout()
        // Lock and Sync Lock keep one fixed slot each (shown or not), so a reveal on hover moves nothing.
        var sl = Self.slots(width: bounds.width, height: bounds.height, kind: track.kind, showsSync: true, showsLock: true)
        let first = [showsSync ? sl.sync : nil, showsLock ? sl.lock : nil, sl.mute, sl.eye].compactMap { $0 }.map(\.minX).min()
        sl.nameRight = (first ?? bounds.width) - Self.buttonGap
        lockButton.frame = sl.lock
        syncButton.frame = sl.sync
        if let r = sl.eye { eyeButton.frame = r }
        if let r = sl.mute { muteButton.frame = r }
        if let r = sl.solo { soloButton.frame = r }
        chipButton.frame = chipRect
        nameRight = sl.nameRight
        if let tag = patchTooltipArea { removeToolTip(tag) }
        patchTooltipArea = patch.column ? addToolTip(patchRect, owner: self, userData: nil) : nil
    }

    private var nameRight: CGFloat = 0
    private var chipRect: CGRect {
        let x = patch.column ? patchRect.maxX + Self.patchGap : Self.leftPadding
        let h = min(Self.chipHeight, max(bounds.height - 4, 12))
        return CGRect(x: x, y: ((bounds.height - h) / 2).rounded(), width: Self.chipWidth, height: h)
    }

    var patchRect: CGRect {
        let h = min(Self.chipHeight, max(bounds.height - 4, 12))
        return CGRect(x: Self.leftPadding, y: ((bounds.height - h) / 2).rounded(), width: Self.patchWidth, height: h)
    }

    private static let chipAttributes: [NSAttributedString.Key: Any] = [.font: Theme.Typography.ns(10, .semibold)]     // v9 .tgt: 600 10
    private static let nameAttributes: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label2, .paragraphStyle: p]
    }()

    public override func draw(_ dirtyRect: NSRect) {
        // v9 `.th`: panel color, 1 pt track line below (2 pt strong under V1), right-hand separator.
        Theme.Colors.panel.setFill()
        bounds.fill()
        if isSplitRow {
            Theme.Colors.trackHeaderLine.setFill()
            CGRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
        } else {
            Theme.Colors.trackRowLine.setFill()
            CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
        Theme.Colors.separator.setFill()
        CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        // Target chip (v9 `.tgt`): quiet fill with t2 text; targeted = accent fill with white text.
        let chip = chipRect
        (track.isTargeted ? Theme.Colors.accentFill : Theme.Colors.fill).setFill()
        NSBezierPath(roundedRect: chip, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        var attrs = Self.chipAttributes
        attrs[.foregroundColor] = track.isTargeted ? Theme.Colors.onClip : Theme.Colors.label2
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: CGPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2), withAttributes: attrs)

        drawPatch()
        if isMatteSource { drawMatteMarker() }

        // Name: what the user typed, else "Video 1" / "Audio 1"; it truncates with an ellipsis (v9 `.nm`).
        let shownName = Self.displayName(name: track.name, label: label, kind: track.kind)
        guard !shownName.isEmpty else { return }
        let nameX = chip.maxX + Self.buttonGap
        let w = nameRight - nameX
        if w > 12 {
            let h: CGFloat = 14
            (shownName as NSString).draw(in: CGRect(x: nameX, y: ((bounds.height - h) / 2).rounded(), width: w, height: h),
                                         withAttributes: Self.nameAttributes)
        }
    }

    /// The typed name, or "Video N" / "Audio N" taken from the chip ("V2" -> "Video 2"). A stored name that only repeats
    /// the chip ("V6" on track V6, as imported projects have it) counts as no name: the id never shows twice.
    static func displayName(name: String, label: String, kind: TrackKind) -> String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard typed.isEmpty || typed.caseInsensitiveCompare(label) == .orderedSame else { return typed }
        let number = label.drop { !$0.isNumber }
        guard !number.isEmpty else { return "" }
        return "\(kind == .video ? "Video" : "Audio") \(number)"
    }

    /// A small accent bar on the left edge of the header, 3 x 12 pt, centered vertically.
    private func drawMatteMarker() {
        let r = CGRect(x: 0, y: ((bounds.height - 12) / 2).rounded(), width: 3, height: 12)
        Theme.Colors.accent.setFill()
        NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
    }

    // MARK: Source patch chip

    /// Connected: accent fill, "V" / "A" in white. Disconnected: hairline outline, gray letter. Drop target: accent ring.
    private func drawPatch() {
        guard patch.column else { return }
        let r = patchRect
        let radius = Theme.Radius.small + 1
        if patch.dropHighlight {
            Theme.Colors.accent.setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            ring.lineWidth = 1
            ring.stroke()
        }
        guard let chip = patch.chip else { return }
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if chip.connected {
            Theme.Colors.accent.setFill(); path.fill()
        } else {
            Theme.Colors.label3.setStroke(); path.lineWidth = 1; path.stroke()
        }
        var attrs = Self.chipAttributes
        attrs[.foregroundColor] = chip.connected ? Theme.Colors.onClip : Theme.Colors.label3
        let text = (chip.kind == .video ? "V" : "A") as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let chip = patch.chip else { return "" }
        let what = chip.kind == .video ? "Source video" : "Source audio"
        return chip.connected ? "\(what) goes here. Click to turn off, Option+click for this stream only, drag to another track (Shift: both)."
                              : "\(what) is off. Click to turn on, drag to another track."
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let chip = patch.chip, patchRect.insetBy(dx: -2, dy: -3).contains(p), let window else {
            if event.clickCount == 2, let onDoubleClick { onDoubleClick(event.modifierFlags.contains(.shift)); return }
            super.mouseDown(with: event); return
        }
        var dragging = false
        patchGestureFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let q = convert(e.locationInWindow, from: nil)
            patchGestureFlags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.type == .leftMouseDragged {
                if !dragging, hypot(q.x - p.x, q.y - p.y) >= 3 { dragging = true; NSCursor.closedHand.push() }
                if dragging { onPatchDrag?(chip.kind, e.locationInWindow, false) }
            } else {
                if dragging { NSCursor.pop(); onPatchDrag?(chip.kind, e.locationInWindow, true) } else { onPatchClick?(chip.kind) }
                break
            }
        }
    }

}

extension TrackHeaderView: NSViewToolTipOwner {}

/// A header button (v9 `.th .ibtn.sm` / `.ms`): radius 4, a tinted line icon or a letter; M and S sit on a quiet fill.
final class TrackHeaderButton: NSButton {
    var glyph: NSImage? { didSet { needsDisplay = true } }
    var letter: String? { didSet { needsDisplay = true } }
    var filled = false
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var tint: NSColor = Theme.Colors.label2 { didSet { needsDisplay = true } }
    /// The target chip: the header draws it, this is only its click area.
    var drawsNothing = false
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard !drawsNothing else { return }
        let box = NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        if filled {
            (isOn ? Theme.Colors.fillPressed : (hovering ? Theme.Colors.fillHover : Theme.Colors.fill)).setFill()
            box.fill()
        } else if hovering {
            Theme.Colors.fillHover.setFill()
            box.fill()
        }
        let color = hovering && !isOn && tint == Theme.Colors.label2 ? Theme.Colors.label : tint
        if let letter {
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.ns(10, .semibold), .foregroundColor: color]
            let sz = (letter as NSString).size(withAttributes: attrs)
            (letter as NSString).draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
        } else if let glyph {
            let size = glyph.size
            let r = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            NSImage(size: size, flipped: false) { rect in
                glyph.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }.draw(in: r)
        }
    }
}

import AppKit
import SSCore

public enum TrackToggle: Sendable, Hashable { case target, visible, mute, solo, lock, syncLock }

/// One track's header: target chip, name, eye (video) or mute + solo (audio), lock on hover (always shown while locked).
/// Real `NSButton`s with SF Symbols; this slice only reports clicks through `onToggle` (T-04/T-05 act on them).
@MainActor
public final class TrackHeaderView: NSView {
    public private(set) var trackID: Track.ID
    public var onToggle: ((Track.ID, TrackToggle) -> Void)?

    private var track: Track
    private var label: String
    private var isHovering = false { didSet { updateLockVisibility(); needsLayout = true; needsDisplay = true } }
    private let eyeButton = TrackHeaderView.makeButton()
    private let muteButton = TrackHeaderView.makeButton()
    private let soloButton = TrackHeaderView.makeButton()
    private let lockButton = TrackHeaderView.makeButton()
    private let syncButton = TrackHeaderView.makeButton()
    private let chipButton = TrackHeaderView.makeButton()

    static let chipWidth: CGFloat = 24
    static let buttonSize: CGFloat = 16

    public override var isFlipped: Bool { true }

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
        chipButton.image = nil
        chipButton.toolTip = "Target track"
        eyeButton.toolTip = "Show or hide track"
        muteButton.toolTip = "Mute"
        soloButton.toolTip = "Solo"
        lockButton.toolTip = "Lock track"
        syncButton.toolTip = "Sync lock: follow ripple edits on other tracks"
        apply(track: track, label: label)
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    private static func makeButton() -> NSButton {
        let b = NSButton(frame: .zero)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
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

    public func apply(track: Track, label: String) {
        self.track = track; self.label = label; trackID = track.id
        let isVideo = track.kind == .video
        eyeButton.isHidden = !isVideo
        muteButton.isHidden = isVideo
        soloButton.isHidden = isVideo
        configure(eyeButton, symbol: track.isVisible ? "eye" : "eye.slash", on: !track.isVisible, tint: Theme.Colors.label2,
                  description: "Visibility")
        configure(muteButton, symbol: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2", on: track.isMuted,
                  tint: Theme.Colors.accent, description: "Mute")
        configure(soloButton, symbol: "headphones", on: track.isSolo, tint: Theme.Colors.yellow, description: "Solo")
        configure(lockButton, symbol: track.isLocked ? "lock.fill" : "lock.open", on: track.isLocked,
                  tint: Theme.Colors.label2, description: "Lock")
        configure(syncButton, symbol: "lock.rotation", on: track.syncLock, tint: Theme.Colors.accent, description: "Sync lock")
        updateLockVisibility()
        needsLayout = true
        needsDisplay = true
    }

    /// Sync lock shows while hovering, and always when it is off (the non-default state).
    private var showsSync: Bool { isHovering || !track.syncLock }

    private func configure(_ b: NSButton, symbol: String, on: Bool, tint: NSColor, description: String) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?.withSymbolConfiguration(cfg)
        b.contentTintColor = on ? tint : Theme.Colors.label3
    }

    private func updateLockVisibility() { lockButton.alphaValue = (isHovering || track.isLocked) ? 1 : 0 }

    public override func layout() {
        super.layout()
        let s = Self.buttonSize, y = ((bounds.height - s) / 2).rounded()
        var right = bounds.width - Theme.Spacing.xs
        lockButton.frame = CGRect(x: right - s, y: y, width: s, height: s); right -= s
        syncButton.isHidden = !showsSync
        if showsSync { syncButton.frame = CGRect(x: right - s, y: y, width: s, height: s); right -= s }
        if track.kind == .video {
            eyeButton.frame = CGRect(x: right - s, y: y, width: s, height: s); right -= s
        } else {
            soloButton.frame = CGRect(x: right - s, y: y, width: s, height: s); right -= s
            muteButton.frame = CGRect(x: right - s, y: y, width: s, height: s); right -= s
        }
        chipButton.frame = chipRect
        nameRight = right - Theme.Spacing.xs
    }

    private var nameRight: CGFloat = 0
    private var chipRect: CGRect {
        let h = min(bounds.height - 4, 16)
        return CGRect(x: Theme.Spacing.xs, y: ((bounds.height - h) / 2).rounded(), width: Self.chipWidth, height: h)
    }

    private static let chipAttributes: [NSAttributedString.Key: Any] = [.font: Theme.Fonts.mini]
    private static let nameAttributes: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return [.font: Theme.Fonts.small, .foregroundColor: Theme.Colors.label, .paragraphStyle: p]
    }()

    public override func draw(_ dirtyRect: NSRect) {
        (track.isTargeted ? Theme.Colors.accentTint : Theme.Colors.panel).setFill()
        bounds.fill()
        Theme.Colors.separator.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        // Target chip: accent tint when targeted, quiet fill otherwise.
        let chip = chipRect
        let chipPath = NSBezierPath(roundedRect: chip, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        (track.isTargeted ? Theme.Colors.accentFill : Theme.Colors.fill).setFill()
        chipPath.fill()
        var attrs = Self.chipAttributes
        attrs[.foregroundColor] = track.isTargeted ? Theme.Colors.onClip : Theme.Colors.label2
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: CGPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2), withAttributes: attrs)

        let nameX = chip.maxX + Theme.Spacing.sm - 2
        let name = track.name.isEmpty ? (track.kind == .video ? "Video" : "Audio") : track.name
        let w = nameRight - nameX
        if w > 12 {
            let h: CGFloat = 13
            (name as NSString).draw(in: CGRect(x: nameX, y: ((bounds.height - h) / 2).rounded(), width: w, height: h),
                                   withAttributes: Self.nameAttributes)
        }
    }

    // MARK: Hover (lock button)

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    public override func mouseEntered(with event: NSEvent) { isHovering = true }
    public override func mouseExited(with event: NSEvent) { isHovering = false }
}

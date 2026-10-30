import AppKit
import SQCore
import SQLibrary
import SQText

/// What the hover card shows for one preset or template row: a text sample in the template's own look (when it has one)
/// above the info lines (`PresetHoverInfo`).
struct PresetHoverContent {
    var title: String
    var lines: [String]
    var sample: TextStyle?
    var sampleText: String
}

/// Small own-design card next to the pointer after the pointer rests on a row; hides on exit, click, key or scroll.
/// Like `SQTooltip` (own panel, no native tooltip), but with a sample line and several text lines.
@MainActor
final class PresetHoverCard {
    static let shared = PresetHoverCard()
    static let delay: TimeInterval = 0.5
    static let width: CGFloat = 220
    private static let sampleHeight: CGFloat = 54
    private static let pad: CGFloat = 10

    private var panel: NSPanel?
    private var timer: Timer?
    private var monitor: Any?
    private(set) var shownKey: String?

    func schedule(key: String, anchor: NSView, content: @escaping @MainActor () -> PresetHoverContent?) {
        hide()
        shownKey = key
        timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self, weak anchor] _ in
            MainActor.assumeIsolated {
                guard let self, let anchor, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor, let c = content() else { self?.hide(); return }
                self.show(c)
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] e in
            MainActor.assumeIsolated { self?.hide() }
            return e
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
        shownKey = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func show(_ c: PresetHoverContent) {
        let view = PresetHoverCardView(content: c)
        let size = view.fittingSize(width: Self.width)
        let pointer = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = SQTooltipLayout.frame(size: size, pointer: pointer, screen: screen)
        view.frame = NSRect(origin: .zero, size: size)
        let p = panel ?? makePanel()
        panel = p
        p.contentView = view
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.transient, .ignoresCycle]
        return p
    }

    /// Sample height for a card with `lineCount` info lines (pure, tested).
    static func height(lineCount: Int, hasSample: Bool) -> CGFloat {
        pad * 2 + 16 + CGFloat(lineCount) * 14 + (hasSample ? sampleHeight + 6 : 0)
    }
}

/// Draws the card: overlay fill, 0.5 edge (same as the tooltip), title, optional sample on a dark well, info lines.
@MainActor
private final class PresetHoverCardView: NSView {
    let content: PresetHoverContent
    override var isFlipped: Bool { true }

    init(content: PresetHoverContent) {
        self.content = content
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func fittingSize(width: CGFloat) -> NSSize {
        NSSize(width: width, height: PresetHoverCard.height(lineCount: content.lines.count, hasSample: content.sample != nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: Theme.Radius.overlay, yRadius: Theme.Radius.overlay)
        Theme.Colors.overlay.setFill(); r.fill()
        Theme.Colors.tooltipEdge.setStroke(); r.lineWidth = 0.5; r.stroke()
        let pad: CGFloat = 10
        var y = pad
        (content.title as NSString).draw(in: NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 16),
                                         withAttributes: [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label,
                                                          .paragraphStyle: Self.truncating])
        y += 16
        if let style = content.sample {
            let well = NSRect(x: pad, y: y + 4, width: bounds.width - pad * 2, height: 54)
            Theme.Colors.thumbWell.setFill()
            NSBezierPath(roundedRect: well, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).fill()
            let font = NSFont(name: style.fontName, size: 20) ?? NSFont.systemFont(ofSize: 20, weight: .bold)
            let color = NSColor(srgbRed: style.color.red, green: style.color.green, blue: style.color.blue, alpha: style.color.alpha)
            let text = (style.allCaps ? content.sampleText.uppercased() : content.sampleText) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: Self.centered]
            let h = text.size(withAttributes: attrs).height
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: well, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).addClip()
            text.draw(in: NSRect(x: well.minX + 6, y: well.midY - h / 2, width: well.width - 12, height: h), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            y += 54 + 6
        }
        for line in content.lines {
            (line as NSString).draw(in: NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 14),
                                    withAttributes: [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3,
                                                     .paragraphStyle: Self.truncating])
            y += 14
        }
    }

    private static let truncating: NSParagraphStyle = { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p }()
    private static let centered: NSParagraphStyle = {
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingTail; return p
    }()
}

/// Watches the pointer over a table and asks for the card of the row under it.
@MainActor
final class PresetHoverTracker: NSResponder {
    private weak var table: NSTableView?
    /// Content for a row, or nil (no card): rows that are not presets or templates, headers.
    var content: ((Int) -> (key: String, content: PresetHoverContent)?)?
    private var area: NSTrackingArea?

    init(table: NSTableView) {
        self.table = table
        super.init()
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        table.addTrackingArea(a)
        area = a
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseMoved(with event: NSEvent) {
        guard let table else { return }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard row >= 0, let hit = content?(row) else { PresetHoverCard.shared.hide(); return }
        if PresetHoverCard.shared.shownKey == hit.key { return }       // same row: the card stays
        let r = row
        PresetHoverCard.shared.schedule(key: hit.key, anchor: table) { [weak self] in self?.content?(r)?.content }
    }

    override func mouseExited(with event: NSEvent) { PresetHoverCard.shared.hide() }
}

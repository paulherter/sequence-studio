import AppKit
import SQCore
import SQEditorSession
import SQLibrary
import SQMonitorUI
import SQText
import SQTimelineUI
import SQUIKit

/// A tile of the Templates tab: the template on a neutral well. A click places it at the playhead, a drag drops it on the
/// timeline (same pasteboard types as the Library, so the timeline's drop code is shared).
@MainActor
final class TextTemplateTileView: NSView, NSDraggingSource {
    static let size = CGSize(width: 140, height: 104)
    static let pixelWidth = 256, pixelHeight = 160

    let tile: TextTemplateTile
    var onPick: ((TextTemplateTile) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private let picture: NSImage?
    private var downAt: CGPoint?

    override var isFlipped: Bool { true }

    init(tile: TextTemplateTile) {
        self.tile = tile
        self.picture = Self.picture(for: tile)
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        setAccessibilityRole(.button)
        setAccessibilityLabel(tile.name)
        sqToolTip = tile.name
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static let background: [UInt8] = {
        let c = Theme.Colors.tileBackground.usingColorSpace(.sRGB) ?? NSColor.darkGray
        let px = [c.redComponent, c.greenComponent, c.blueComponent].map { UInt8(max(0, min(255, ($0 * 255).rounded()))) } + [255]
        return (0..<pixelWidth * pixelHeight).flatMap { _ in px }
    }()

    private static func picture(for tile: TextTemplateTile) -> NSImage? {
        if let data = tile.thumbnail, let img = NSImage(data: data) { return img }
        guard let style = tile.style else { return nil }
        let w = pixelWidth, h = pixelHeight
        let bytes = TextPresetPreview.still(style: style, text: tile.sampleText, background: background, width: w, height: h)
        guard bytes.count == w * h * 4, let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { downAt = convert(event.locationInWindow, from: nil) }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        if downAt != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?(tile) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4, let item = Self.pasteboardItem(for: tile) else { return }
        downAt = nil
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(NSRect(origin: .zero, size: Self.size), contents: picture ?? NSImage(size: Self.size))
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    /// Same payloads as the Library: a built-in is its catalog id, a saved title is its preset id.
    static func pasteboardItem(for tile: TextTemplateTile) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        switch tile.source {
        case .builtIn(let id): item.setString(id, forType: .sequenceTextTemplate)
        case .user(let id, let kind) where kind == .titleBlock || kind == .titleTemplate:
            item.setString(id.uuidString, forType: .sequenceTitleBlock)
        case .user: return nil      // a plain saved text style is placed by click
        }
        return item
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    override func accessibilityPerformPress() -> Bool { onPick?(tile); return true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let well = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 18).insetBy(dx: 1, dy: 1)
        let path = CGPath(roundedRect: well, cornerWidth: Theme.Radius.control, cornerHeight: Theme.Radius.control, transform: nil)
        ctx.setFillColor((hovering ? Theme.Colors.viewer : Theme.Colors.content).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        if let picture {
            picture.draw(in: well, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let text = NSAttributedString(string: tile.sampleText, attributes: [.font: Theme.Typography.bodyStrong, .foregroundColor: Theme.Colors.label2])
            let sz = text.size()
            text.draw(at: CGPoint(x: well.midX - min(sz.width, well.width - 8) / 2, y: well.midY - sz.height / 2))
        }
        ctx.restoreGState()
        ctx.setStrokeColor((hovering ? Theme.Colors.accent : Theme.Colors.separator).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path); ctx.strokePath()
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail; para.alignment = .center
        NSAttributedString(string: tile.name, attributes: [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label2,
                                                           .paragraphStyle: para])
            .draw(in: CGRect(x: 0, y: bounds.height - 15, width: bounds.width, height: 14))
    }
}

/// The Templates tab of the Text panel: every text and graphic template (the user's saved ones first, then the built-in
/// set) as tiles. One click places a template at the playhead, dragging drops it on a track.
@MainActor
public final class TextTemplatesTabView: NSView {
    /// Called with the picked tile; the host places it (it knows the session and the Library).
    public var onPick: ((TextTemplateTile) -> Void)?
    /// All tiles before the search filter.
    public var allTiles: [TextTemplateTile] = [] { didSet { if oldValue != allTiles { rebuild() } } }
    /// The tiles shown now (after the search).
    public private(set) var shownTiles: [TextTemplateTile] = []

    private let search = SQSearchField()
    private let scroll = NSScrollView()
    private let content = FlippedContentView()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var views: [TextTemplateTileView] = []

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        search.placeholderString = "Search templates"
        search.target = self
        search.action = #selector(searchChanged)
        hint.font = Theme.Typography.body
        hint.textColor = Theme.Colors.label3
        hint.stringValue = "Click a template to place it at the playhead, or drag it onto a track. Save your own from the timeline menu: Save as Template or Save to Library."
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = content
        addSubview(search)
        addSubview(scroll)
        content.addSubview(hint)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Templates")
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    @objc private func searchChanged() { rebuild() }

    private func rebuild() {
        views.forEach { $0.removeFromSuperview() }
        shownTiles = TextTemplateTile.filter(allTiles, query: search.stringValue)
        views = shownTiles.map { t in
            let v = TextTemplateTileView(tile: t)
            v.onPick = { [weak self] t in self?.onPick?(t) }
            content.addSubview(v)
            return v
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let pad = Theme.Spacing.sm
        search.frame = CGRect(x: pad, y: pad, width: max(bounds.width - 2 * pad, 0), height: 24)
        let top = search.frame.maxY + pad
        scroll.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top, 0))
        let width = scroll.contentSize.width
        let tw = TextTemplateTileView.size.width, th = TextTemplateTileView.size.height
        let cols = max(1, Int((width - pad) / (tw + pad)))
        let gap = cols > 1 ? max(pad, (width - 2 * pad - CGFloat(cols) * tw) / CGFloat(cols - 1)) : pad
        hint.frame = CGRect(x: pad, y: pad, width: max(width - 2 * pad, 0), height: 0)
        hint.frame.size.height = hint.sizeThatFits(NSSize(width: hint.frame.width, height: .greatestFiniteMagnitude)).height
        let y = hint.frame.maxY + pad
        for (i, v) in views.enumerated() {
            v.frame = CGRect(x: pad + CGFloat(i % cols) * (tw + gap), y: y + CGFloat(i / cols) * (th + pad), width: tw, height: th)
        }
        let rows = (views.count + cols - 1) / cols
        content.frame = CGRect(x: 0, y: 0, width: width, height: y + CGFloat(rows) * (th + pad))
    }
}

private final class FlippedContentView: NSView { override var isFlipped: Bool { true } }

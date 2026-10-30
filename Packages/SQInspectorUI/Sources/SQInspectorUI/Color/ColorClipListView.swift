import AppKit
import SQCore

/// The Clips strip of the Color page (design board "ColorClips"): every source file of the active sequence once, as a
/// tile in one row (thumbnail in the shape of the sequence, file name, uses and "graded"). Clicking a tile grades every
/// use of that source (its uses share one grade through the grade links, see `ColorSourceListItem.clipToGrade`); the
/// tile of the source being graded carries the yellow ring. Right-click offers copy/paste of the grade. Adjustment
/// layers and the sequence-wide grade are picked in the timeline, not here.
@MainActor
public final class ColorClipsPanelView: NSView {
    let session: EditorSession
    var onPickSource: ((ColorSourceListItem) -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onLinkAll: ((ColorSourceListItem) -> Void)?
    var canPaste: () -> Bool = { false }

    private(set) var items: [ColorSourceListItem] = []
    /// The tile of the source being graded; nil = none.
    private(set) var highlighted: Int?
    private(set) var format: ColorPageFormat = .landscape
    private let thumbnails = ProjectThumbnails()
    /// Media time of each tile's frame and the pixel height it is made at.
    private var frameTimes: [UUID: Time] = [:]
    private var frameHeight = 208
    private let scroll = NSScrollView()
    private let content = StripContent()
    /// "No sequence open" or "No video clips" instead of the tiles.
    let emptyState = EmptyStateView(title: "")
    /// The tile under the pointer (nil = none).
    private(set) var hovered: Int? { didSet { if hovered != oldValue { content.needsDisplay = true } } }

    // The pure layout is shared with the Windows strip (`ColorSourcesLayout`).
    static let pad = ColorSourcesLayout.pad
    static let lineGap = ColorSourcesLayout.lineGap
    static let ring = ColorSourcesLayout.ring
    static func tiles(_ timeline: Timeline?, project: Project) -> [ColorSourceListItem] { ColorSourcesLayout.tiles(timeline, project: project) }
    static func thumbSize(_ f: ColorPageFormat) -> NSSize { ColorSourcesLayout.thumbSize(f) }

    public override var isFlipped: Bool { true }

    init(session: EditorSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.content.cgColor
        appearance = NSAppearance(named: .darkAqua)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content
        content.strip = self
        addSubview(scroll)
        addSubview(emptyState)
        updateEmptyState(hasSequence: session.activeTimeline != nil)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Clips")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Reloads the tiles from the active sequence; the tile of `picked`'s source gets the ring (none while the whole
    /// sequence is graded).
    func reload(wholeSequence: Bool, picked: Clip.ID?, format: ColorPageFormat) {
        let t = session.activeTimeline
        let newItems = Self.tiles(t, project: session.project)
        let relayout = newItems.count != items.count || format != self.format
        items = newItems
        self.format = format
        highlighted = ColorSourcesLayout.highlighted(items, wholeSequence: wholeSequence, picked: picked)
        let size = Self.thumbSize(format)
        let h = Int(max(size.height, size.width) * 2)
        for item in items {
            guard let ref = session.project.media.first(where: { $0.id == item.media }) else { continue }
            let ft = Self.frameTime(of: item, in: t)
            if let ft { frameTimes[item.media] = ft }
            thumbnails.requestPosterAndFrame(ref, frameAt: ft, height: h) { [weak self] in self?.content.needsDisplay = true }
        }
        frameHeight = h
        frameTimes = frameTimes.filter { k, _ in items.contains { $0.media == k } }
        updateEmptyState(hasSequence: t != nil)
        if relayout { needsLayout = true }
        content.needsDisplay = true
    }

    static func emptyState(hasSequence: Bool, itemCount: Int) -> (title: String, hint: String)? {
        ColorSourcesLayout.emptyState(hasSequence: hasSequence, itemCount: itemCount)
    }

    private func updateEmptyState(hasSequence: Bool) {
        let e = Self.emptyState(hasSequence: hasSequence, itemCount: items.count)
        emptyState.isHidden = e == nil
        scroll.isHidden = e != nil
        if let e, emptyState.title != e.title { emptyState.title = e.title; emptyState.hint = e.hint }
        needsLayout = true
    }

    private var lineHeight: CGFloat { ceil(Theme.Typography.body.ascender - Theme.Typography.body.descender) + 1 }

    /// One tile: thumbnail, name line, uses line.
    var tileSize: NSSize {
        let t = Self.thumbSize(format)
        return NSSize(width: t.width, height: t.height + 2 * (Self.lineGap + lineHeight))
    }

    public override func layout() {
        super.layout()
        scroll.frame = bounds
        let n = CGFloat(items.count)
        let w = 2 * Self.pad + n * tileSize.width + max(n - 1, 0) * Self.pad
        content.frame = NSRect(x: 0, y: 0, width: max(w, bounds.width), height: max(tileSize.height + 2 * Self.pad, bounds.height))
        emptyState.frame = bounds
    }

    func tileRect(_ i: Int) -> NSRect {
        NSRect(x: Self.pad + CGFloat(i) * (tileSize.width + Self.pad), y: Self.pad, width: tileSize.width, height: tileSize.height)
    }

    static func steppedIndex(from: Int?, count: Int, forward: Bool) -> Int? {
        ColorSourcesLayout.steppedIndex(from: from, count: count, forward: forward)
    }

    public override var acceptsFirstResponder: Bool { true }

    /// Arrow keys (any direction) step through the sources and grade the one reached.
    public override func keyDown(with event: NSEvent) {
        let forward: Bool
        switch event.keyCode {
        case 124, 125: forward = true      // right, down
        case 123, 126: forward = false     // left, up
        default: super.keyDown(with: event); return
        }
        guard let i = Self.steppedIndex(from: highlighted, count: items.count, forward: forward) else { return }
        clickTile(i)
        scroll.contentView.scrollToVisible(tileRect(i).insetBy(dx: -Self.pad, dy: 0))
    }

    func tileIndex(at p: NSPoint) -> Int? { items.indices.first { tileRect($0).contains(p) } }

    /// A click on tile `i`: grades every use of its source.
    func clickTile(_ i: Int) {
        if items.indices.contains(i) { onPickSource?(items[i]) }
    }

    func menu(for i: Int, at screen: NSPoint) {
        clickTile(i)
        var entries: [SQMenuItem] = [
            SQMenuItem(title: "Copy Grade", shortcut: "\u{2318}C") { [weak self] in self?.onCopy?() },
            SQMenuItem(title: "Paste Grade", shortcut: "\u{2318}V", isEnabled: canPaste()) { [weak self] in self?.onPaste?() },
        ]
        if items.indices.contains(i), items[i].clips.count > 1 {
            let item = items[i]
            entries.append(.separator)
            entries.append(SQMenuItem(title: "Link All Cuts") { [weak self] in self?.onLinkAll?(item) })
        }
        SQMenuController.shared.present(items: entries, at: screen)
    }

    func poster(_ media: UUID) -> NSImage? { thumbnails.cachedPoster(media) }

    /// The media time a tile shows: the middle of the source range its first cut uses (the frame the cut is about,
    /// not the media's poster). nil when the tile has no cut.
    static func frameTime(of item: ColorSourceListItem, in timeline: Timeline?) -> Time? {
        ColorSourcesLayout.frameTime(of: item, in: timeline)
    }

    /// The picture of tile `i`: the frame of its first cut when loaded, else the media poster.
    func picture(_ i: Int) -> NSImage? {
        let item = items[i]
        if let t = frameTimes[item.media], let img = thumbnails.cachedFrame(item.media, at: t, height: frameHeight) { return img }
        return poster(item.media)
    }

    /// The tiles, drawn in one pass.
    final class StripContent: NSView {
        weak var strip: ColorClipsPanelView?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private var hoverArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(a)
            hoverArea = a
        }

        override func mouseMoved(with e: NSEvent) { strip?.hovered = strip?.tileIndex(at: convert(e.locationInWindow, from: nil)) }
        override func mouseExited(with e: NSEvent) { strip?.hovered = nil }

        /// Scrolling under a resting pointer sends no mouse event: re-read the pointer on every scroll step.
        private lazy var hoverSync = ScrollHoverSync(view: self) { [weak self] p in
            guard let self else { return }
            self.strip?.hovered = p.flatMap { self.strip?.tileIndex(at: $0) }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverSync.attach(); hoverSync.refresh() }

        override func mouseDown(with e: NSEvent) {
            guard let strip, let i = strip.tileIndex(at: convert(e.locationInWindow, from: nil)) else { return }
            strip.window?.makeFirstResponder(strip)
            if e.modifierFlags.contains(.control) { strip.menu(for: i, at: NSEvent.mouseLocation); return }
            strip.clickTile(i)
        }

        override func rightMouseDown(with e: NSEvent) {
            guard let strip, let i = strip.tileIndex(at: convert(e.locationInWindow, from: nil)) else { return }
            strip.menu(for: i, at: NSEvent.mouseLocation)
        }

        override func draw(_ dirty: NSRect) {
            guard let strip else { return }
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label]
            let usesAttrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3]
            let ts = ColorClipsPanelView.thumbSize(strip.format)
            let lh = strip.lineHeight, gap = ColorClipsPanelView.lineGap
            for (i, item) in strip.items.enumerated() {
                let r = strip.tileRect(i)
                guard r.insetBy(dx: -4, dy: -4).intersects(dirty) else { continue }
                let thumb = NSRect(x: r.minX, y: r.minY, width: ts.width, height: ts.height)
                let box = NSBezierPath(roundedRect: thumb, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
                NSGraphicsContext.saveGraphicsState()
                box.addClip()
                (i == strip.hovered ? Theme.Colors.fill : Theme.Colors.fill2).setFill()
                thumb.fill()
                if let img = strip.picture(i) {
                    let s = max(thumb.width / max(img.size.width, 1), thumb.height / max(img.size.height, 1))
                    let w = img.size.width * s, h = img.size.height * s
                    img.draw(in: NSRect(x: thumb.midX - w / 2, y: thumb.midY - h / 2, width: w, height: h), from: .zero,
                             operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                NSGraphicsContext.restoreGraphicsState()
                if i == strip.highlighted {
                    let w = ColorClipsPanelView.ring
                    let ring = NSBezierPath(roundedRect: thumb.insetBy(dx: -w / 2, dy: -w / 2),
                                            xRadius: Theme.Radius.control + w / 2, yRadius: Theme.Radius.control + w / 2)
                    ring.lineWidth = w
                    Theme.Colors.yellow.setStroke()
                    ring.stroke()
                }
                let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                NSAttributedString(string: item.name, attributes: nameAttrs)
                    .draw(with: NSRect(x: r.minX, y: thumb.maxY + gap, width: r.width, height: lh), options: opts)
                NSAttributedString(string: ColorUses.tileLine(uses: item.clips.count, grade: item.gradeText), attributes: usesAttrs)
                    .draw(with: NSRect(x: r.minX, y: thumb.maxY + 2 * gap + lh, width: r.width, height: lh), options: opts)
            }
        }
    }
}

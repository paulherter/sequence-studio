import AppKit
import SQCore
import SQText

/// One tile of the look gallery: the sample words in the look's style, still at rest, and moving (entrance, loop,
/// exit, lit words) while the pointer is over it. The motion is `CaptionStyleLooks.pose` / `litWord`, the maths playback
/// uses, so the tile shows what the look does. No timer runs while nothing is hovered.
@MainActor
final class LookSwatchView: NSView {
    static let size = CGSize(width: 92, height: 74)
    static let words = ["Say", "it", "loud"]

    let look: CaptionStyleLook
    private let library: CaptionPresetLibrary
    var onPick: ((CaptionStyleLook) -> Void)?
    var isCurrent = false { didSet { if oldValue != isCurrent { needsDisplay = true } } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var timer: Timer?
    private var started = Date()
    private var time: Time

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(look: CaptionStyleLook, library: CaptionPresetLibrary) {
        self.look = look; self.library = library
        self.time = Self.restTime(for: look.group)
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(look.title), \(look.group.title) look")
        sqToolTip = look.title
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { timer?.invalidate() }

    /// The still frame: settled after an entrance, mid-cycle in a loop, before an exit, one word lit.
    static func restTime(for group: LookGroup) -> Time {
        switch group {
        case .wordLight: Time(1, 1)
        case .entrance, .collection: Time(3, 2)
        case .motion: Time(1, 4)
        case .exit: .zero
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        started = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        timer?.invalidate(); timer = nil
        time = Self.restTime(for: look.group)
        needsDisplay = true
    }

    private func tick() {
        let ms = Int64(Date().timeIntervalSince(started) * 1000)
        let window = CaptionStyleLooks.previewDuration
        time = Time(ms % (window.value * 1000 / window.timescale), 1000)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?(look) }
    }

    override func accessibilityPerformPress() -> Bool { onPick?(look); return true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let tile = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 16).insetBy(dx: 1, dy: 1)
        let path = CGPath(roundedRect: tile, cornerWidth: Theme.Radius.control, cornerHeight: Theme.Radius.control, transform: nil)
        ctx.setFillColor((hovering ? Theme.Colors.viewer : Theme.Colors.content).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor((isCurrent ? Theme.Colors.accent : Theme.Colors.separator).cgColor)
        ctx.setLineWidth(isCurrent ? 2 : 1)
        ctx.addPath(path); ctx.strokePath()

        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        drawSample(in: tile, ctx: ctx)
        ctx.restoreGState()

        let label = NSAttributedString(string: look.title, attributes: [
            .font: Theme.Typography.caption, .foregroundColor: isCurrent ? Theme.Colors.label : Theme.Colors.label2,
        ])
        let sz = label.size()
        label.draw(at: CGPoint(x: (bounds.width - sz.width) / 2, y: bounds.height - 14))
    }

    private func drawSample(in tile: CGRect, ctx: CGContext) {
        let style = library.style(for: look.styleRef)
        let k = 17.0 / style.size                                  // sequence pixels -> tile points
        var scaled = style; scaled.size = 17
        let font = FontResolver.font(for: scaled) as NSFont
        let pose = CaptionStyleLooks.pose(of: look, library: library, at: time)
        let lit = look.karaoke.flatMap { _ in CaptionStyleLooks.litWord(count: Self.words.count, at: time) }

        let base = Self.color(style.color)
        let string = NSMutableAttributedString()
        for (i, w) in Self.words.enumerated() {
            var color = base
            if let ks = look.karaoke, let lit, ks.keepSpoken ? i <= lit : i == lit { color = Self.color(CaptionKaraoke.color(ks)) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let s = style.stroke, s.width > 0 {
                attrs[.strokeColor] = Self.color(s.color)
                attrs[.strokeWidth] = -min(25, s.width * k / 17 * 100)
            }
            string.append(NSAttributedString(string: w + (i < Self.words.count - 1 ? " " : ""), attributes: attrs))
        }
        let size = string.size()
        let pad = style.background.map { CGSize(width: $0.padding.horizontal * k, height: $0.padding.vertical * k) } ?? .zero
        ctx.saveGState()
        ctx.translateBy(x: tile.midX + pose.offsetX * k, y: tile.midY + pose.offsetY * k)
        ctx.scaleBy(x: pose.scale, y: pose.scale)
        ctx.setAlpha(pose.opacity)
        let box = CGRect(x: -size.width / 2 - pad.width, y: -size.height / 2 - pad.height,
                         width: size.width + 2 * pad.width, height: size.height + 2 * pad.height)
        if let bg = style.background {
            ctx.setFillColor(Self.color(bg.color).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: bg.cornerRadius * k, cornerHeight: bg.cornerRadius * k, transform: nil))
            ctx.fillPath()
        }
        if let sh = style.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = Self.color(sh.color)
            shadow.shadowOffset = NSSize(width: sh.offsetX * k, height: -sh.offsetY * k)
            shadow.shadowBlurRadius = sh.blur * k
            shadow.set()
        }
        string.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
        ctx.restoreGState()
    }

    static func color(_ c: RGBAColor) -> NSColor {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return NSColor(cgColor: CGColor(colorSpace: space, components: [c.red, c.green, c.blue, c.alpha].map { CGFloat($0) })!) ?? .white
    }
}

/// The look gallery of the Text panel: a grid of ready looks (word light, entrance, loop, exit). One click applies a
/// look through `onPick`; the host decides whether it lands on the caption track or on a title, and everything stays
/// editable afterwards in the Captions tab and the text properties.
@MainActor
public final class CaptionStyleLookGalleryView: NSView {
    public var onPick: ((CaptionStyleLook) -> Void)?
    /// The look that matches what is applied now (highlighted); nil when nothing matches.
    public var currentID: String? { didSet { for s in swatches { s.isCurrent = s.look.id == currentID } } }
    public let groups: [LookGroup]

    private let library: CaptionPresetLibrary
    private var swatches: [LookSwatchView] = []
    private var headings: [(LookGroup, NSTextField)] = []
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    public override var isFlipped: Bool { true }

    public init(library: CaptionPresetLibrary = .builtIn, groups: [LookGroup] = LookGroup.allCases, hint text: String = "") {
        self.library = library; self.groups = groups
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        hintLabel.stringValue = text
        hintLabel.font = Theme.Typography.body; hintLabel.textColor = Theme.Colors.label3
        hintLabel.isHidden = text.isEmpty
        addSubview(hintLabel)
        for g in groups {
            let h = NSTextField(labelWithString: g.title)
            h.font = Theme.Typography.bodyStrong; h.textColor = Theme.Colors.label2
            addSubview(h); headings.append((g, h))
            for look in CaptionStyleLooks.looks(in: g) {
                let s = LookSwatchView(look: look, library: library)
                s.onPick = { [weak self] l in self?.onPick?(l) }
                addSubview(s); swatches.append(s)
            }
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Looks")
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public var hint: String {
        get { hintLabel.stringValue }
        set { hintLabel.stringValue = newValue; hintLabel.isHidden = newValue.isEmpty; needsLayout = true }
    }

    /// Height the grid needs at `width`.
    public func contentHeight(forWidth width: CGFloat) -> CGFloat { place(width: width, apply: false) }

    public override func layout() {
        super.layout()
        _ = place(width: bounds.width, apply: true)
        if abs(contentHeight(forWidth: bounds.width) - lastHeight) > 0.5 { invalidateIntrinsicContentSize() }
    }

    private var lastHeight: CGFloat = 0

    /// The height the grid needs at its current width (auto layout hosts it in a section row).
    public override var intrinsicContentSize: NSSize {
        let h = contentHeight(forWidth: bounds.width > 0 ? bounds.width : 300)
        lastHeight = h
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
    }

    @discardableResult
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        let pad = Theme.Spacing.sm
        let gap: CGFloat = 6
        let sw = LookSwatchView.size
        let cols = max(1, Int((width - 2 * pad + gap) / (sw.width + gap)))
        var y = pad
        if !hintLabel.isHidden {
            let h = hintLabel.sizeThatFits(NSSize(width: max(width - 2 * pad, 20), height: 200)).height
            if apply { hintLabel.frame = CGRect(x: pad, y: y, width: max(width - 2 * pad, 20), height: h) }
            y += h + pad
        }
        for (g, heading) in headings {
            if apply { heading.sizeToFit(); heading.frame.origin = CGPoint(x: pad, y: y) }
            y += 18
            let mine = swatches.filter { $0.look.group == g }
            for (i, s) in mine.enumerated() {
                if apply { s.frame = CGRect(x: pad + CGFloat(i % cols) * (sw.width + gap), y: y + CGFloat(i / cols) * (sw.height + gap),
                                            width: sw.width, height: sw.height) }
            }
            y += CGFloat((mine.count + cols - 1) / cols) * (sw.height + gap) + 4
        }
        return y + pad
    }
}

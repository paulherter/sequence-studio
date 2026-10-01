import AppKit
import CoreGraphics

/// Pure geometry of the 4-band strip: log frequency axis 20 Hz...20 kHz across `width`.
public struct CompressorBandsGeometry: Sendable, Equatable {
    public var width: CGFloat
    public var handleHitRadius: CGFloat = 6
    /// Gain reduction that fills a bar completely.
    public static let fullScaleGainReductionDB: Double = 24

    public init(width: CGFloat) { self.width = width }

    private static var logMin: Double { log(CrossoverRules.minHz) }
    private static var logSpan: Double { log(CrossoverRules.maxHz) - log(CrossoverRules.minHz) }

    public func x(forHz hz: Double) -> CGFloat {
        let h = min(max(hz, CrossoverRules.minHz), CrossoverRules.maxHz)
        return CGFloat((log(h) - Self.logMin) / Self.logSpan) * width
    }

    public func hz(forX x: CGFloat) -> Double {
        guard width > 0 else { return CrossoverRules.minHz }
        let f = min(max(Double(x / width), 0), 1)
        return exp(Self.logMin + f * Self.logSpan)
    }

    /// x ranges of the 4 bands, low to high, tiling 0...width.
    public func bandRanges(crossoversHz: [Double]) -> [ClosedRange<CGFloat>] {
        let edges = [0] + crossoversHz.map { x(forHz: $0) } + [width]
        return (0..<(edges.count - 1)).map { edges[$0]...edges[$0 + 1] }
    }

    /// Index of the crossover handle within `handleHitRadius` of `x`, nearest first.
    public func handleIndex(at x: CGFloat, crossoversHz: [Double]) -> Int? {
        let hits = crossoversHz.enumerated()
            .map { ($0.offset, abs(self.x(forHz: $0.element) - x)) }
            .filter { $0.1 <= handleHitRadius }
        return hits.min { $0.1 < $1.1 }?.0
    }

    /// Frequency for dragging crossover `index` to `x`, clamped so the order is kept.
    public func draggedHz(index: Int, toX x: CGFloat, crossoversHz: [Double]) -> Double {
        CrossoverRules.clamp(hz(forX: x), index: index, in: crossoversHz)
    }

    /// 0...1 bar fill for a gain reduction in dB (positive = reduction).
    public static func barFraction(gainReductionDB: Double) -> Double {
        min(max(gainReductionDB / fullScaleGainReductionDB, 0), 1)
    }
}

/// 4-band strip: band columns with gain-reduction bars growing from the top, draggable crossovers.
public final class CompressorBandsView: NSView {
    public var crossoversHz: [Double] = [120, 900, 4500] { didSet { needsDisplay = true } }
    /// Current gain reduction per band in dB (positive), from the engine meter.
    public var gainReductionDB: [Double] = [0, 0, 0, 0] { didSet { needsDisplay = true } }
    public var isBypassed = false { didSet { needsDisplay = true } }
    public var beginDrag: (() -> Void)?
    public var crossoverChanged: ((Int, Double) -> Void)?
    public var endDrag: (() -> Void)?

    private var dragIndex: Int?
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }

    private static let labelHeight: CGFloat = 14
    private var geometry: CompressorBandsGeometry { CompressorBandsGeometry(width: bounds.width) }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 84) }
    public override var acceptsFirstResponder: Bool { false }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func draw(_ dirtyRect: NSRect) {
        let g = geometry
        let plot = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.labelHeight)
        let path = NSBezierPath(roundedRect: plot, xRadius: Theme.Radius.field, yRadius: Theme.Radius.field)
        Theme.Colors.field.setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let ranges = g.bandRanges(crossoversHz: crossoversHz)
        for (i, r) in ranges.enumerated() {
            let alpha: CGFloat = isBypassed ? 0.3 : 1
            if i % 2 == 1 { Theme.Colors.rowAlt.setFill(); NSRect(x: r.lowerBound, y: 0, width: r.upperBound - r.lowerBound, height: plot.height).fill() }
            let fraction = CGFloat(CompressorBandsGeometry.barFraction(gainReductionDB: i < gainReductionDB.count ? gainReductionDB[i] : 0))
            let barH = plot.height * fraction
            Theme.Colors.accent.withAlphaComponent(0.55 * alpha).setFill()
            NSRect(x: r.lowerBound + 1, y: 0, width: max(0, r.upperBound - r.lowerBound - 2), height: barH).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        Theme.Colors.fieldEdge.setStroke(); path.lineWidth = 1; path.stroke()

        for (i, hz) in crossoversHz.enumerated() {
            let x = g.x(forHz: hz).rounded() + 0.5
            let active = dragIndex == i || hoverIndex == i
            (active ? Theme.Colors.accent : Theme.Colors.label2).setFill()
            NSRect(x: x - 0.5, y: 0, width: active ? 2 : 1, height: plot.height).fill()
            let text = Self.hzText(hz) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Fonts.meter, .foregroundColor: active ? Theme.Colors.label : Theme.Colors.label3]
            let size = text.size(withAttributes: attrs)
            let tx = min(max(x - size.width / 2, 0), bounds.width - size.width)
            text.draw(at: NSPoint(x: tx, y: plot.height + 2), withAttributes: attrs)
        }
    }

    static func hzText(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1fk", hz / 1000) : String(format: "%.0f", hz)
    }

    // MARK: Mouse

    public override func resetCursorRects() {
        for hz in crossoversHz {
            let x = geometry.x(forHz: hz)
            addCursorRect(NSRect(x: x - 4, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        hoverIndex = geometry.handleIndex(at: convert(event.locationInWindow, from: nil).x, crossoversHz: crossoversHz)
    }
    public override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    public override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let i = geometry.handleIndex(at: x, crossoversHz: crossoversHz) else { return }
        dragIndex = i
        beginDrag?()
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let i = dragIndex else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let hz = geometry.draggedHz(index: i, toX: x, crossoversHz: crossoversHz)
        crossoversHz[i] = hz
        crossoverChanged?(i, hz)
    }

    public override func mouseUp(with event: NSEvent) {
        guard dragIndex != nil else { return }
        dragIndex = nil
        endDrag?()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}

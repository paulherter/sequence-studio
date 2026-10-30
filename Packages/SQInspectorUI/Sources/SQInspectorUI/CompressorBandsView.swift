import AppKit
import CoreGraphics
import SQAudioFX

/// 4-band strip: band columns with gain-reduction bars growing from the top, draggable crossovers.
public final class CompressorBandsView: NSView {
    public var crossoversHz: [Double] = [120, 900, 4500] { didSet { needsDisplay = true } }
    /// Current gain reduction per band in dB (positive), from the engine meter.
    public var gainReductionDB: [Double] = [0, 0, 0, 0] { didSet { needsDisplay = true } }
    public var isBypassed = false { didSet { needsDisplay = true } }
    /// Band input level per band as a 0...1 meter position (`MeterBallistics.position`), drawn from the bottom. Empty = none.
    public var inputLevel: [Double] = [] { didSet { if inputLevel != oldValue { needsDisplay = true } } }
    /// Per band: drawn dimmed (bypassed, or silent because another band is soloed).
    public var bandDimmed: [Bool] = [false, false, false, false] { didSet { if bandDimmed != oldValue { needsDisplay = true } } }
    /// Live spectrum (`SpectrumDisplay.levelsDB`, log-spaced 20 Hz...20 kHz across the width), drawn behind the bars.
    /// Empty = none.
    public var spectrumDB: [Float] = [] { didSet { if spectrumDB != oldValue { needsDisplay = true } } }
    /// Input bar color per band (defaults to the accent).
    public var bandColors: [NSColor] = [] { didSet { needsDisplay = true } }
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
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func draw(_ dirtyRect: NSRect) {
        let g = geometry
        let plot = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.labelHeight)
        let path = NSBezierPath(roundedRect: plot, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
        Theme.Colors.field.setFill(); path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let ranges = g.bandRanges(crossoversHz: crossoversHz)
        for (i, r) in ranges.enumerated() where i % 2 == 1 {
            Theme.Colors.rowAlt.setFill(); NSRect(x: r.lowerBound, y: 0, width: r.upperBound - r.lowerBound, height: plot.height).fill()
        }
        drawSpectrum(in: plot)
        for (i, r) in ranges.enumerated() {
            let dimmed = isBypassed || (i < bandDimmed.count && bandDimmed[i])
            let alpha: CGFloat = dimmed ? 0.3 : 1
            if i < inputLevel.count {
                // Band input level: a centered column from the bottom in the band color.
                let color = i < bandColors.count ? bandColors[i] : Theme.Colors.accent
                let h = plot.height * CGFloat(min(max(inputLevel[i], 0), 1))
                let bw = min(max((r.upperBound - r.lowerBound) * 0.3, 4), 14)
                color.withAlphaComponent(0.55 * alpha).setFill()
                NSRect(x: (r.lowerBound + r.upperBound) / 2 - bw / 2, y: plot.height - h, width: bw, height: h).fill()
            }
            let fraction = CGFloat(CompressorBandsGeometry.barFraction(gainReductionDB: i < gainReductionDB.count ? gainReductionDB[i] : 0))
            let barH = plot.height * fraction
            Theme.Colors.accentTint.withAlphaComponent(Theme.Colors.accentTint.alphaComponent * alpha).setFill()
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
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: active ? Theme.Colors.label : Theme.Colors.label3]
            let size = text.size(withAttributes: attrs)
            let tx = min(max(x - size.width / 2, 0), bounds.width - size.width)
            text.draw(at: NSPoint(x: tx, y: plot.height + 2), withAttributes: attrs)
        }
    }

    /// The spectrum as a filled curve from the bottom (neutral, so the band colors stay readable on top).
    private func drawSpectrum(in plot: NSRect) {
        let n = spectrumDB.count
        guard n > 1, plot.width > 0 else { return }
        let curve = NSBezierPath()
        curve.move(to: NSPoint(x: 0, y: plot.height))
        for (i, db) in spectrumDB.enumerated() {
            let x = plot.width * CGFloat(i) / CGFloat(n - 1)
            curve.line(to: NSPoint(x: x, y: plot.height * (1 - CGFloat(SpectrumDisplay.fraction(dB: db)))))
        }
        curve.line(to: NSPoint(x: plot.width, y: plot.height))
        curve.close()
        Theme.Colors.label3.withAlphaComponent(0.16).setFill(); curve.fill()
        let line = NSBezierPath()
        for (i, db) in spectrumDB.enumerated() {
            let p = NSPoint(x: plot.width * CGFloat(i) / CGFloat(n - 1), y: plot.height * (1 - CGFloat(SpectrumDisplay.fraction(dB: db))))
            if i == 0 { line.move(to: p) } else { line.line(to: p) }
        }
        line.lineWidth = 1
        Theme.Colors.label3.withAlphaComponent(0.5).setStroke(); line.stroke()
    }

    static func hzText(_ hz: Double) -> String { CompressorBandsGeometry.hzText(hz) }

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

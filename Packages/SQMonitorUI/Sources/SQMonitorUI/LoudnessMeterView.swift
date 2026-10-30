import AppKit
import SQCore
import SQPlayback

/// Momentary / short-term / integrated bars with numbers, true-peak with hold, target line and label at the sequence's
/// delivery target (`target`, -14 LUFS / -1 dBTP by default). True peak turns red above the target's ceiling.
public final class LoudnessMeterView: NSView {
    public var reading = LoudnessReading.silent { didSet { updatePeak(changed: reading != oldValue); needsDisplay = true } }
    /// Loudness range over what was measured so far; greyed out and "--" under 60 s (Tech 3342).
    public private(set) var range = LoudnessRangeTracker()
    public var target = LoudnessTarget.default { didSet { if target != oldValue { sqToolTip = target.label; needsDisplay = true } } }
    public private(set) var peakHold = PeakHold()
    private var lastPeakUpdate: CFTimeInterval?

    public override var isFlipped: Bool { true }
    /// `.rows`: horizontal M / S / I / TP bars with numbers (wide panels). `.columns`: four thin vertical bars on the
    /// LUFS scale with the target line across M / S / I and the integrated value on top (the narrow Audio Meters strip).
    public enum Style: Sendable { case rows, columns }
    public var style = Style.rows { didSet { if style != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    public static let columnsWidth: CGFloat = 40
    public override var intrinsicContentSize: NSSize {
        style == .rows ? NSSize(width: NSView.noIntrinsicMetric, height: 112) : NSSize(width: Self.columnsWidth, height: NSView.noIntrinsicMetric)
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }
    public override func accessibilityLabel() -> String? { "Loudness meter" }
    public override func accessibilityValue() -> Any? {
        reading.spokenText + ", " + (range.value.map { String(format: "loudness range %.1f LU", $0) } ?? "loudness range needs 60 seconds of signal")
    }
    public override func accessibilityHelp() -> String? { "Click to reset the integrated loudness and the true peak hold. " + target.label }

    /// Click: restart integrated and true-peak hold.
    public var onReset: (() -> Void)?
    public override func mouseDown(with event: NSEvent) { resetPeak(); onReset?() }

    public func resetPeak() { peakHold.reset(); range.reset(); lastPeakUpdate = nil; needsDisplay = true }

    private func updatePeak(changed: Bool = true) {
        let now = CACurrentMediaTime()
        let dt = lastPeakUpdate.map { now - $0 } ?? 0
        lastPeakUpdate = now
        // Only a moving signal advances the range clock (a paused meter repeats the same reading).
        if changed { range.add(shortTermLUFS: reading.shortTermLUFS, dt: min(dt, 1)) }
        peakHold.update(reading.truePeakDB, dt: dt)
    }

    public override func draw(_ dirtyRect: NSRect) {
        if style == .columns { drawColumns(); return }
        let rows: [(String, Double?)] = [("M", reading.momentaryLUFS), ("S", reading.shortTermLUFS), ("I", reading.integratedLUFS)]
        let labelW: CGFloat = 14, numW: CGFloat = 40, gap = Theme.Spacing.sm
        let barX = labelW + gap, barW = max(0, bounds.width - barX - numW - gap)
        let rowH: CGFloat = 14, rowGap = Theme.Spacing.iconToLabel
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label2]
        let numAttrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label]

        func bar(_ y: CGFloat, fill: Double, color: NSColor) {
            let track = NSRect(x: barX, y: y, width: barW, height: rowH)
            Theme.Colors.field.setFill()
            NSBezierPath(roundedRect: track, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
            var f = track; f.size.width = track.width * CGFloat(fill)
            color.setFill()
            NSBezierPath(roundedRect: f, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        }

        var y: CGFloat = 0
        for (name, value) in rows {
            (name as NSString).draw(at: NSPoint(x: 0, y: y + 1), withAttributes: attrs)
            let over = target.isOverTarget(value)
            bar(y, fill: LoudnessScale.fraction(lufs: value), color: over ? Theme.Colors.yellow : Theme.Colors.accent)
            (LoudnessScale.text(lufs: value) as NSString).draw(at: NSPoint(x: barX + barW + gap, y: y + 1), withAttributes: numAttrs)
            y += rowH + rowGap
        }
        // True peak: bar over -60...0 dBTP mapped like a short scale, with hold tick.
        ("TP" as NSString).draw(at: NSPoint(x: 0, y: y + 1), withAttributes: attrs)
        let tpFraction = { (db: Double) -> Double in db.isFinite ? min(max((db + 60) / 60, 0), 1) : 0 }
        bar(y, fill: tpFraction(reading.truePeakDB), color: target.isOverCeiling(reading.truePeakDB) ? Theme.Colors.red : Theme.Colors.green)
        let hold = peakHold.valueDB
        if hold.isFinite {
            let hx = barX + barW * CGFloat(tpFraction(hold))
            Theme.Colors.label.setFill()
            NSRect(x: min(hx, barX + barW - 1.5), y: y, width: 1.5, height: rowH).fill()
        }
        let tpText = reading.truePeakDB.isFinite && reading.truePeakDB > -100 ? String(format: "%.1f", reading.truePeakDB) : "-inf"
        (tpText as NSString).draw(at: NSPoint(x: barX + barW + gap, y: y + 1), withAttributes: numAttrs)

        // Target line across the three LUFS rows.
        let tx = (barX + barW * CGFloat(LoudnessScale.fraction(lufs: target.lufs))).rounded() + 0.5
        Theme.Colors.yellow.setFill()
        NSRect(x: tx - 0.5, y: -2, width: 1, height: 3 * (rowH + rowGap) - rowGap + 4).fill()
        // Target label under the true-peak row.
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3]
        (target.label as NSString).draw(at: NSPoint(x: barX, y: y + rowH + rowGap), withAttributes: labelAttrs)
        // Loudness range: dim until a minute of signal was measured.
        let lraAttrs: [NSAttributedString.Key: Any] = [
            .font: Theme.Typography.body,
            .foregroundColor: range.isReliable ? Theme.Colors.label2 : Theme.Colors.label3.withAlphaComponent(0.5),
        ]
        let lra = range.text as NSString
        let lw = lra.size(withAttributes: lraAttrs).width
        lra.draw(at: NSPoint(x: bounds.width - lw, y: y + rowH + rowGap), withAttributes: lraAttrs)
    }

    /// Narrow layout: integrated LUFS on top, then M S I TP columns (bottom = -40 LUFS / -60 dBTP), a target line across
    /// M S I, and the column letters at the bottom.
    private func drawColumns() {
        let small: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label2]
        let numAttrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label]
        let textH: CGFloat = 14, colW: CGFloat = 6, gap: CGFloat = 3
        let total = 4 * colW + 3 * gap
        let x0 = ((bounds.width - total) / 2).rounded()
        let top = textH + 2, bottom = bounds.height - textH - 2
        let h = max(bottom - top, 0)
        let integ = LoudnessScale.text(lufs: reading.integratedLUFS) as NSString
        let iw = integ.size(withAttributes: numAttrs).width
        integ.draw(at: NSPoint(x: ((bounds.width - iw) / 2).rounded(), y: 0), withAttributes: numAttrs)
        let tpFraction = { (db: Double) -> Double in db.isFinite ? min(max((db + 60) / 60, 0), 1) : 0 }
        let cols: [(String, Double, NSColor)] = [
            ("M", LoudnessScale.fraction(lufs: reading.momentaryLUFS), target.isOverTarget(reading.momentaryLUFS) ? Theme.Colors.yellow : Theme.Colors.accent),
            ("S", LoudnessScale.fraction(lufs: reading.shortTermLUFS), target.isOverTarget(reading.shortTermLUFS) ? Theme.Colors.yellow : Theme.Colors.accent),
            ("I", LoudnessScale.fraction(lufs: reading.integratedLUFS), target.isOverTarget(reading.integratedLUFS) ? Theme.Colors.yellow : Theme.Colors.accent),
            ("T", tpFraction(reading.truePeakDB), target.isOverCeiling(reading.truePeakDB) ? Theme.Colors.red : Theme.Colors.green),
        ]
        for (i, (name, fill, color)) in cols.enumerated() {
            let x = x0 + CGFloat(i) * (colW + gap)
            Theme.Colors.field.setFill()
            NSRect(x: x, y: top, width: colW, height: h).fill()
            let fh = h * CGFloat(fill)
            color.setFill()
            NSRect(x: x, y: top + h - fh, width: colW, height: fh).fill()
            let nw = (name as NSString).size(withAttributes: small).width
            (name as NSString).draw(at: NSPoint(x: x + (colW - nw) / 2, y: bottom + 2), withAttributes: small)
        }
        let hold = peakHold.valueDB
        if hold.isFinite {
            Theme.Colors.label.setFill()
            NSRect(x: x0 + 3 * (colW + gap), y: top + h - h * CGFloat(tpFraction(hold)), width: colW, height: 1.5).fill()
        }
        // Target line across M S I.
        let ty = (top + h - h * CGFloat(LoudnessScale.fraction(lufs: target.lufs))).rounded() + 0.5
        Theme.Colors.yellow.setFill()
        NSRect(x: x0 - 2, y: ty - 0.5, width: 3 * colW + 2 * gap + 4, height: 1).fill()
    }
}

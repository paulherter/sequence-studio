import AppKit

/// One snapshot of the R128 meter (values from the engine; nil LUFS = not enough signal yet).
public struct LoudnessReading: Sendable, Equatable {
    public var momentaryLUFS: Double?
    public var shortTermLUFS: Double?
    public var integratedLUFS: Double?
    public var truePeakDB: Double

    public init(momentaryLUFS: Double? = nil, shortTermLUFS: Double? = nil,
                integratedLUFS: Double? = nil, truePeakDB: Double = -.infinity) {
        self.momentaryLUFS = momentaryLUFS; self.shortTermLUFS = shortTermLUFS
        self.integratedLUFS = integratedLUFS; self.truePeakDB = truePeakDB
    }

    public var truePeakOver: Bool { truePeakDB > 0 } // above 0 dBTP
    public static let silent = LoudnessReading()
}

public enum LoudnessScale {
    public static let minLUFS: Double = -40
    public static let maxLUFS: Double = 0
    public static let targetLUFS: Double = -14

    /// 0...1 position on the -40...0 LUFS scale.
    public static func fraction(lufs: Double?) -> Double {
        guard let l = lufs, l.isFinite else { return 0 }
        return min(max((l - minLUFS) / (maxLUFS - minLUFS), 0), 1)
    }

    public static func text(lufs: Double?) -> String {
        guard let l = lufs, l.isFinite, l > -100 else { return "-inf" }
        return String(format: "%.1f", l)
    }
}

/// Peak indicator that holds the maximum for `holdSeconds`, then falls at `fallDBPerSecond`.
public struct PeakHold: Sendable, Equatable {
    public var holdSeconds: Double
    public var fallDBPerSecond: Double
    public private(set) var valueDB: Double = -.infinity
    private var heldFor: Double = 0

    public init(holdSeconds: Double = 2, fallDBPerSecond: Double = 20) {
        self.holdSeconds = holdSeconds; self.fallDBPerSecond = fallDBPerSecond
    }

    public mutating func update(_ peakDB: Double, dt: Double) {
        if peakDB >= valueDB { valueDB = peakDB; heldFor = 0; return }
        heldFor += dt
        let fallTime = min(dt, max(0, heldFor - holdSeconds))
        valueDB = max(peakDB, valueDB - fallTime * fallDBPerSecond)
    }

    public mutating func reset() { valueDB = -.infinity; heldFor = 0 }
}

/// Momentary / short-term / integrated bars with numbers, true-peak with hold, target line at -14 LUFS.
public final class LoudnessMeterView: NSView {
    public var reading = LoudnessReading.silent { didSet { updatePeak(); needsDisplay = true } }
    public private(set) var peakHold = PeakHold()
    private var lastPeakUpdate: CFTimeInterval?

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 96) }

    public func resetPeak() { peakHold.reset(); lastPeakUpdate = nil; needsDisplay = true }

    private func updatePeak() {
        let now = CACurrentMediaTime()
        let dt = lastPeakUpdate.map { now - $0 } ?? 0
        lastPeakUpdate = now
        peakHold.update(reading.truePeakDB, dt: dt)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let rows: [(String, Double?)] = [("M", reading.momentaryLUFS), ("S", reading.shortTermLUFS), ("I", reading.integratedLUFS)]
        let labelW: CGFloat = 14, numW: CGFloat = 40, gap = Theme.Spacing.sm
        let barX = labelW + gap, barW = max(0, bounds.width - barX - numW - gap)
        let rowH: CGFloat = 14, rowGap: CGFloat = 6
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Fonts.small, .foregroundColor: Theme.Colors.label2]
        let numAttrs: [NSAttributedString.Key: Any] = [.font: Theme.Fonts.small, .foregroundColor: Theme.Colors.label]

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
            let over = (value ?? -100) > LoudnessScale.targetLUFS + 1
            bar(y, fill: LoudnessScale.fraction(lufs: value), color: over ? Theme.Colors.yellow : Theme.Colors.accent)
            (LoudnessScale.text(lufs: value) as NSString).draw(at: NSPoint(x: barX + barW + gap, y: y + 1), withAttributes: numAttrs)
            y += rowH + rowGap
        }
        // True peak: bar over -60...0 dBTP mapped like a short scale, with hold tick.
        ("TP" as NSString).draw(at: NSPoint(x: 0, y: y + 1), withAttributes: attrs)
        let tpFraction = { (db: Double) -> Double in db.isFinite ? min(max((db + 60) / 60, 0), 1) : 0 }
        bar(y, fill: tpFraction(reading.truePeakDB), color: reading.truePeakOver ? Theme.Colors.red : Theme.Colors.green)
        let hold = peakHold.valueDB
        if hold.isFinite {
            let hx = barX + barW * CGFloat(tpFraction(hold))
            Theme.Colors.label.setFill()
            NSRect(x: min(hx, barX + barW - 1.5), y: y, width: 1.5, height: rowH).fill()
        }
        let tpText = reading.truePeakDB.isFinite && reading.truePeakDB > -100 ? String(format: "%.1f", reading.truePeakDB) : "-inf"
        (tpText as NSString).draw(at: NSPoint(x: barX + barW + gap, y: y + 1), withAttributes: numAttrs)

        // Target line across the three LUFS rows.
        let tx = (barX + barW * CGFloat(LoudnessScale.fraction(lufs: LoudnessScale.targetLUFS))).rounded() + 0.5
        Theme.Colors.yellow.withAlphaComponent(0.8).setFill()
        NSRect(x: tx - 0.5, y: -2, width: 1, height: 3 * (rowH + rowGap) - rowGap + 4).fill()
    }
}

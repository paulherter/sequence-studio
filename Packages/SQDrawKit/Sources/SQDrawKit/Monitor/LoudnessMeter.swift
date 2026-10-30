import Foundation
import SQCore

// The loudness meter (Mac SQMonitorUI `LoudnessMeterView`) on the portable canvas: reading, scale, target and peak hold
// moved here as they were; the meter state and its rows / columns drawing translated line by line.

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

    /// The reading as a sentence for VoiceOver.
    public var spokenText: String {
        func lufs(_ v: Double?) -> String { v.map { _ in LoudnessScale.text(lufs: v) + " LUFS" } ?? "no signal" }
        let peak = truePeakDB.isFinite && truePeakDB > -100 ? String(format: "%.1f dBTP", truePeakDB) : "no signal"
        return "Momentary \(lufs(momentaryLUFS)), short-term \(lufs(shortTermLUFS)), integrated \(lufs(integratedLUFS)), true peak \(peak)"
    }
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

/// What the meter measures against: the sequence's delivery target (LUFS integrated, dBTP ceiling), -14 / -1 without one.
public struct LoudnessTarget: Sendable, Equatable {
    public var lufs: Double
    public var truePeakDB: Double

    public init(lufs: Double, truePeakDB: Double) { self.lufs = lufs; self.truePeakDB = truePeakDB }
    public init(delivery: DeliveryTarget?) {
        self = delivery.map { LoudnessTarget(lufs: $0.targetLUFS, truePeakDB: $0.truePeakDB) } ?? .default
    }

    public static let `default` = LoudnessTarget(lufs: LoudnessScale.targetLUFS, truePeakDB: -1)

    public var label: String { "Target \(Self.number(lufs)) LUFS / \(Self.number(truePeakDB)) dBTP" }

    /// More than 1 LU above the target (the bar turns yellow).
    public func isOverTarget(_ value: Double?) -> Bool { (value ?? -100) > lufs + 1 }
    /// True peak above the ceiling (the bar turns red).
    public func isOverCeiling(_ truePeakDB: Double) -> Bool { truePeakDB.isFinite && truePeakDB > self.truePeakDB }

    private static func number(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
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

/// Momentary / short-term / integrated bars with numbers, true-peak with hold, target line and label at the sequence's
/// delivery target (`target`, -14 LUFS / -1 dBTP by default). True peak turns red above the target's ceiling.
public struct LoudnessMeter: Sendable, Equatable {
    public private(set) var reading = LoudnessReading.silent
    /// Loudness range over what was measured so far; grayed out and "--" under 60 s (Tech 3342).
    public private(set) var range = LoudnessRangeTracker()
    public var target = LoudnessTarget.default
    public private(set) var peakHold = PeakHold()
    private var lastPeakUpdate: Double?

    /// `.rows`: horizontal M / S / I / TP bars with numbers (wide panels). `.columns`: four thin vertical bars on the
    /// LUFS scale with the target line across M / S / I and the integrated value on top (the narrow Audio Meters strip).
    public enum Style: Sendable { case rows, columns }
    public var style = Style.rows
    public static let columnsWidth: CGFloat = 40
    public static let rowsHeight: CGFloat = 112
    static let fontSize: CGFloat = 11          // Theme.Typography.body

    public init(style: Style = .rows) { self.style = style }

    /// A new reading at `time` (seconds, monotonic): advances the range clock (only when the reading moved) and the hold.
    public mutating func update(_ r: LoudnessReading, at time: Double) {
        let changed = r != reading
        reading = r
        let dt = lastPeakUpdate.map { time - $0 } ?? 0
        lastPeakUpdate = time
        // Only a moving signal advances the range clock (a paused meter repeats the same reading).
        if changed { range.add(shortTermLUFS: reading.shortTermLUFS, dt: min(dt, 1)) }
        peakHold.update(reading.truePeakDB, dt: dt)
    }

    /// Drops momentary and short-term (playback stopped) without touching the hold.
    public mutating func clearLive() {
        reading.momentaryLUFS = nil; reading.shortTermLUFS = nil
    }

    /// Click: restart integrated and true-peak hold.
    public mutating func resetPeak() { peakHold.reset(); range.reset(); lastPeakUpdate = nil }

    static func field(_ t: DrawTheme) -> DrawColor { DrawColor(0, 0, 0, t.palette.isDark ? 0.28 : 0.05) }   // Theme.Colors.field
    static let green = DrawColor(hex: 0x30D158)                                                              // Theme.Colors.green
    static func tpFraction(_ db: Double) -> Double { db.isFinite ? min(max((db + 60) / 60, 0), 1) : 0 }

    public func draw(_ c: inout Canvas, in b: CGRect, theme t: DrawTheme) {
        if style == .columns { drawColumns(&c, in: b, theme: t); return }
        let red = DrawTheme.color(t.palette.red)
        let rows: [(String, Double?)] = [("M", reading.momentaryLUFS), ("S", reading.shortTermLUFS), ("I", reading.integratedLUFS)]
        let labelW: CGFloat = 14, numW: CGFloat = 40, gap: CGFloat = 8        // Theme.Spacing.sm
        let barX = b.minX + labelW + gap, barW = max(0, b.width - labelW - gap - numW - gap)
        let rowH: CGFloat = 14, rowGap: CGFloat = 6                            // Theme.Spacing.iconToLabel
        let font = Self.fontSize

        func bar(_ y: CGFloat, fill: Double, color: DrawColor) {
            let track = CGRect(x: barX, y: y, width: barW, height: rowH)
            c.fill(roundedRect: track, radius: 4, Self.field(t))                // Theme.Radius.small
            var f = track; f.size.width = track.width * CGFloat(fill)
            c.fill(roundedRect: f, radius: min(4, f.width / 2), color)
        }

        var y = b.minY
        for (name, value) in rows {
            _ = c.draw(name, at: CGPoint(x: b.minX, y: y + 1), fontSize: font, t.label2)
            bar(y, fill: LoudnessScale.fraction(lufs: value), color: target.isOverTarget(value) ? t.yellow : t.accent)
            _ = c.draw(LoudnessScale.text(lufs: value), at: CGPoint(x: barX + barW + gap, y: y + 1), fontSize: font, t.label)
            y += rowH + rowGap
        }
        // True peak: bar over -60...0 dBTP mapped like a short scale, with hold tick.
        _ = c.draw("TP", at: CGPoint(x: b.minX, y: y + 1), fontSize: font, t.label2)
        bar(y, fill: Self.tpFraction(reading.truePeakDB), color: target.isOverCeiling(reading.truePeakDB) ? red : Self.green)
        let hold = peakHold.valueDB
        if hold.isFinite {
            let hx = barX + barW * CGFloat(Self.tpFraction(hold))
            c.fill(CGRect(x: min(hx, barX + barW - 1.5), y: y, width: 1.5, height: rowH), t.label)
        }
        let tpText = reading.truePeakDB.isFinite && reading.truePeakDB > -100 ? String(format: "%.1f", reading.truePeakDB) : "-inf"
        _ = c.draw(tpText, at: CGPoint(x: barX + barW + gap, y: y + 1), fontSize: font, t.label)

        // Target line across the three LUFS rows.
        let tx = (barX + barW * CGFloat(LoudnessScale.fraction(lufs: target.lufs))).rounded() + 0.5
        c.fill(CGRect(x: tx - 0.5, y: b.minY - 2, width: 1, height: 3 * (rowH + rowGap) - rowGap + 4), t.yellow)
        // Target label under the true-peak row.
        _ = c.draw(target.label, at: CGPoint(x: barX, y: y + rowH + rowGap), fontSize: font, t.label3)
        // Loudness range: dim until a minute of signal was measured.
        let lra = range.text
        let lw = c.size(of: lra, fontSize: font).width
        _ = c.draw(lra, at: CGPoint(x: b.maxX - lw, y: y + rowH + rowGap), fontSize: font,
                   range.isReliable ? t.label2 : t.label3.alpha(t.label3.a * 0.5))
    }

    /// Narrow layout: integrated LUFS on top, then M S I TP columns (bottom = -40 LUFS / -60 dBTP), a target line across
    /// M S I, and the column letters at the bottom.
    func drawColumns(_ c: inout Canvas, in b: CGRect, theme t: DrawTheme) {
        let font = Self.fontSize
        let textH: CGFloat = 14, colW: CGFloat = 6, gap: CGFloat = 3
        let total = 4 * colW + 3 * gap
        let x0 = b.minX + ((b.width - total) / 2).rounded()
        let top = b.minY + textH + 2, bottom = b.maxY - textH - 2
        let h = max(bottom - top, 0)
        let integ = LoudnessScale.text(lufs: reading.integratedLUFS)
        let iw = c.size(of: integ, fontSize: font).width
        _ = c.draw(integ, at: CGPoint(x: b.minX + ((b.width - iw) / 2).rounded(), y: b.minY), fontSize: font, t.label)
        let red = DrawTheme.color(t.palette.red)
        let cols: [(String, Double, DrawColor)] = [
            ("M", LoudnessScale.fraction(lufs: reading.momentaryLUFS), target.isOverTarget(reading.momentaryLUFS) ? t.yellow : t.accent),
            ("S", LoudnessScale.fraction(lufs: reading.shortTermLUFS), target.isOverTarget(reading.shortTermLUFS) ? t.yellow : t.accent),
            ("I", LoudnessScale.fraction(lufs: reading.integratedLUFS), target.isOverTarget(reading.integratedLUFS) ? t.yellow : t.accent),
            ("T", Self.tpFraction(reading.truePeakDB), target.isOverCeiling(reading.truePeakDB) ? red : Self.green),
        ]
        for (i, (name, fill, color)) in cols.enumerated() {
            let x = x0 + CGFloat(i) * (colW + gap)
            c.fill(CGRect(x: x, y: top, width: colW, height: h), Self.field(t))
            let fh = h * CGFloat(fill)
            c.fill(CGRect(x: x, y: top + h - fh, width: colW, height: fh), color)
            let nw = c.size(of: name, fontSize: font).width
            _ = c.draw(name, at: CGPoint(x: x + (colW - nw) / 2, y: bottom + 2), fontSize: font, t.label2)
        }
        let hold = peakHold.valueDB
        if hold.isFinite {
            c.fill(CGRect(x: x0 + 3 * (colW + gap), y: top + h - h * CGFloat(Self.tpFraction(hold)), width: colW, height: 1.5), t.label)
        }
        // Target line across M S I.
        let ty = (top + h - h * CGFloat(LoudnessScale.fraction(lufs: target.lufs))).rounded() + 0.5
        c.fill(CGRect(x: x0 - 2, y: ty - 0.5, width: 3 * colW + 2 * gap + 4, height: 1), t.yellow)
    }
}

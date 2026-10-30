import Foundation

// The audio meter (Mac SQMonitorUI `AudioMeterView`) on the portable canvas: the pure meter math moved here as it was,
// the view state (channels, Mono, readout, clicks) and the drawing translated line by line.

/// Pure meter math: dBFS mapping, color zones and ballistics (peak hold, fall, latched clip). No AppKit state.
public enum MeterZone: Sendable, Equatable { case green, yellow, red }

/// Meter response preset (Settings > Audio, `sq.audio.meterBallistics`): how fast the bar falls and how long the peak holds.
public enum MeterStyle: String, Sendable, CaseIterable, Equatable {
    case smooth, standard, fast

    public static let defaultsKey = "sq.audio.meterBallistics"
    public static func current(_ defaults: UserDefaults = .standard) -> MeterStyle {
        defaults.string(forKey: defaultsKey).flatMap(MeterStyle.init(rawValue:)) ?? .standard
    }

    public var title: String {
        switch self { case .smooth: "Smooth"; case .standard: "Standard"; case .fast: "Fast" }
    }
    /// Seconds the peak marker stays before it falls.
    public var holdSeconds: Double {
        switch self { case .smooth: 3; case .standard: MeterBallistics.holdSeconds; case .fast: 0.5 }
    }
    /// dB per second the bar falls (the hold marker falls at the same rate once released).
    public var fallDBPerSecond: Float {
        switch self { case .smooth: 12; case .standard: MeterBallistics.barFallDBPerSecond; case .fast: 60 }
    }
}

public struct MeterBallistics: Sendable, Equatable {
    public static let floorDB: Float = -60
    public static let ceilingDB: Float = 0
    /// Board `.meter .bar i`: green up to 78 % of the bar, yellow to 92 %, red above. On the board scale that is -8 and -3 dBFS.
    public static let yellowStartDB: Float = -8
    public static let redStartDB: Float = -3
    public static let holdSeconds: Double = 1.5
    /// Fall rate of the bar and of the hold marker after the hold expired, in dB per second.
    public static let barFallDBPerSecond: Float = 24
    public static let holdFallDBPerSecond: Float = 24

    /// Current bar level in dBFS (rises instantly, falls at `barFallDBPerSecond`).
    public private(set) var levelDB: Float = floorDB
    /// Peak-hold marker in dBFS.
    public private(set) var holdDB: Float = floorDB
    /// Latched until `resetClip()`.
    public private(set) var clipped = false
    private var holdSetAt: Double = 0
    private var lastTime: Double?

    public var style: MeterStyle = .standard

    public init(style: MeterStyle = .standard) { self.style = style }

    public static func dB(fromLinear v: Float) -> Float {
        guard v > 0, v.isFinite else { return v.isNaN ? floorDB : (v > 0 ? ceilingDB : floorDB) }
        return max(floorDB, 20 * log10f(v))
    }

    /// Board scale (labels 0, -6, -12, -20, -30 sit at 1.0, .848, .661, .436, .211 of the bar): piecewise linear taper.
    private static let scaleKnots: [(dB: Float, pos: Float)] = [(-60, 0), (-40, 0.09), (-30, 0.211), (-20, 0.436),
                                                                (-12, 0.661), (-6, 0.848), (0, 1)]

    /// 0...1 position along the scale (floor to 0 dBFS), clamped.
    public static func position(dB: Float) -> Float {
        guard dB > floorDB else { return 0 }
        guard dB < ceilingDB else { return 1 }
        for i in 1..<scaleKnots.count where dB <= scaleKnots[i].dB {
            let a = scaleKnots[i - 1], b = scaleKnots[i]
            return a.pos + (b.pos - a.pos) * (dB - a.dB) / (b.dB - a.dB)
        }
        return 1
    }

    public static func zone(dB: Float) -> MeterZone {
        dB > redStartDB ? .red : (dB >= yellowStartDB ? .yellow : .green)
    }

    /// Feeds a new linear peak (0...1+, 1.0 = 0 dBFS) at `time` (seconds, monotonic). Pass 0 to only advance time.
    public mutating func update(peak: Float, at time: Double, isSignal: Bool = false) {
        if isSignal, peak < Self.silenceLinear { silence(); lastTime = time; return }
        let dt = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
        let db = Self.dB(fromLinear: peak)
        // Bar: instant attack, linear-in-dB release.
        levelDB = max(db, levelDB - style.fallDBPerSecond * Float(dt))
        levelDB = max(Self.floorDB, levelDB)
        // Hold: new maximum restarts the 1.5 s hold, then falls.
        if db >= holdDB {
            holdDB = db; holdSetAt = time
        } else if time - holdSetAt > style.holdSeconds {
            let fallen = min(dt, time - holdSetAt - style.holdSeconds)
            holdDB = max(levelDB, holdDB - style.fallDBPerSecond * Float(fallen))
        }
        if peak >= 1 { clipped = true }
    }

    /// Digital silence (below the floor) counts as "no sound": the bar drops at once, no slow fall.
    public static let silenceLinear: Float = 0.001

    /// Level and hold to the floor at once (playback stopped or silent). The clip latch stays.
    public mutating func silence() { levelDB = Self.floorDB; holdDB = Self.floorDB }

    public mutating func resetClip() { clipped = false }

    /// True when nothing is moving any more (timer can stop).
    public var isSettled: Bool { levelDB <= Self.floorDB && holdDB <= Self.floorDB }
}

/// Decides which engine meter readings reach the bars: a reading is fed once (by its buffer counter), so a stopped
/// engine lets the bars fall instead of holding the last peak.
public struct MeterFeed: Sendable {
    private var last: (source: ObjectIdentifier, sequence: Int)?
    public init() {}

    /// `source` identifies the engine the reading came from: a new engine restarts its buffer counter, so the same
    /// sequence number from another source is a new buffer.
    public mutating func peaks(for reading: (source: ObjectIdentifier, sequence: Int, peaks: [Float])?) -> [Float]? {
        guard let reading else { return nil }
        if let last, last.source == reading.source, last.sequence == reading.sequence { return nil }
        last = (reading.source, reading.sequence)
        return reading.peaks
    }
}

/// What the label under a bar shows (the Mac view's `labelColor(bar:)`): accent = soloed, red = muted, dim red =
/// silenced by another channel's solo.
public enum MeterChannelLabel: Sendable, Equatable { case normal, soloed, muted, silenced }

/// Where a click on the meter lands (the Mac view's `mouseDown`).
public enum AudioMeterHit: Sendable, Equatable {
    /// The readout on top: clears the clip latch.
    case resetClip
    /// A channel label: Solo (Option / Alt: Mute) that bar.
    case channel(Int)
    /// The bars: swallowed (inside the Source waveform a click on the bars must not scrub).
    case none
}

/// Stereo (or n-channel) peak meter state: feed it `update(peaks:at:)` from the engine tap (linear peaks per channel),
/// advance it with `tick(at:)` while not settled, draw it with `draw(_:in:theme:labels:)`.
public struct AudioMeter: Sendable, Equatable {
    public private(set) var channels: [MeterBallistics] = [MeterBallistics(), MeterBallistics()]
    public var style: MeterStyle = .standard {
        didSet { for i in channels.indices { channels[i].style = style } }
    }

    /// Design v9 `.tlmeter`: 48 wide; the peak readout on top, two 5 pt bars 3 pt apart, the scale right of them, "L R" below.
    public static let width: CGFloat = 48
    static let barWidth: CGFloat = 5
    static let gap: CGFloat = 3
    static let barsX: CGFloat = 8
    static let scaleRight: CGFloat = 39
    static let topInset: CGFloat = 22
    static let bottomInset: CGFloat = 22
    static let edgeInset: CGFloat = 8
    static let scaleTicks: [Float] = [0, -6, -12, -20, -30]
    /// Theme.Typography 9.5 regular.
    static let fontSize: CGFloat = 9.5

    public init(style: MeterStyle = .standard) {
        self.style = style
        channels = [MeterBallistics(style: style), MeterBallistics(style: style)]
    }

    /// Mono sequence (Sequence Settings > Channels): one bar, labeled "M", for the single folded channel.
    public var isMono = false {
        didSet {
            guard isMono != oldValue else { return }
            channels = Array(repeating: MeterBallistics(style: style), count: isMono ? 1 : 2)
        }
    }

    /// Bar labels under the bars.
    public var channelNames: [String] { isMono ? ["M"] : ["L", "R"] }

    /// Output channels a bar stands for (of `channelCount`): the Mono bar is both.
    public func channels(forBar i: Int, channelCount: Int = 2) -> [Int] { isMono ? [0, 1] : [min(max(i, 0), channelCount - 1)] }

    /// One bar (Mono) sits where the pair's middle is.
    func barX(_ i: Int) -> CGFloat { Self.barsX + CGFloat(i) * (Self.barWidth + Self.gap) + (isMono ? (Self.barWidth + Self.gap) / 2 : 0) }

    /// Bar index whose label column is at `x`, nil between the columns.
    public func bar(atX x: CGFloat) -> Int? {
        for i in 0..<(isMono ? 1 : 2) {
            let bx = barX(i)
            if x >= bx - Self.gap && x <= bx + Self.barWidth + Self.gap { return i }
        }
        return nil
    }

    /// A click at `p` in a meter `height` high.
    public func hit(_ p: CGPoint, height: CGFloat) -> AudioMeterHit {
        if p.y <= Self.topInset { return .resetClip }
        if p.y >= height - Self.bottomInset, let bar = bar(atX: p.x) { return .channel(bar) }
        return .none
    }

    /// Linear peaks per channel for the last audio block (1.0 = 0 dBFS) at `time`. A Mono sequence shows one bar: the
    /// loudest side.
    public mutating func update(peaks input: [Float], at time: Double) {
        let peaks = isMono ? [input.max() ?? 0] : input
        if peaks.count != channels.count { channels = Array(repeating: MeterBallistics(style: style), count: max(1, peaks.count)) }
        for (i, p) in peaks.enumerated() { channels[i].update(peak: p, at: time, isSignal: true) }
    }

    /// The 30 Hz tick between buffers: the bars fall. Returns whether the meter settled (the timer can stop).
    @discardableResult public mutating func tick(at time: Double) -> Bool {
        for i in channels.indices { channels[i].update(peak: 0, at: time) }
        return isSettled
    }
    public var isSettled: Bool { channels.allSatisfy(\.isSettled) }

    public mutating func resetClip() { for i in channels.indices { channels[i].resetClip() } }
    /// Level and hold to zero at once (no new audio arrives: stopped or paused). Clip latch stays.
    public mutating func silence() { for i in channels.indices { channels[i].silence() } }
    /// Clears level and hold (e.g. on stop). Clip latch stays until clicked.
    public mutating func reset() {
        let clip = channels.map(\.clipped)
        channels = clip.map { c in var b = MeterBallistics(style: style); if c { b.update(peak: 1, at: 0); b.update(peak: 0, at: 100) }; return b }
    }

    /// The readout on top: the highest held peak in dB ("-12.3"), a dash while silent.
    public var readout: String {
        let peak = channels.map(\.holdDB).max() ?? MeterBallistics.floorDB
        guard peak > MeterBallistics.floorDB else { return "\u{2013}" }
        let v = (Double(peak) * 10).rounded() / 10
        return v < 0 ? "\u{2212}" + String(format: "%.1f", -v) : String(format: "%.1f", v)
    }

    static func color(_ zone: MeterZone, _ t: DrawTheme) -> DrawColor {
        switch zone {
        case .green: DrawColor(hex: 0x30D158)      // Theme.Colors.green
        case .yellow: t.yellow
        case .red: DrawTheme.color(t.palette.red)
        }
    }

    static func labelColor(_ l: MeterChannelLabel, _ t: DrawTheme) -> DrawColor {
        switch l {
        case .normal: t.label3
        case .soloed: t.accent
        case .muted: DrawTheme.color(t.palette.red)
        case .silenced: DrawTheme.color(t.palette.red).alpha(0.6)
        }
    }

    /// Draws the meter into `r` (48 wide by design). `labels` per bar (Solo / Mute state), `.normal` when absent.
    public func draw(_ c: inout Canvas, in r: CGRect, theme t: DrawTheme, labels: [MeterChannelLabel] = []) {
        let meterTop = r.minY + Self.topInset
        let h = r.height - Self.topInset - Self.bottomInset
        guard h > 0 else { return }
        func y(_ dB: Float) -> CGFloat { meterTop + h * (1 - CGFloat(MeterBallistics.position(dB: dB))) }
        let font = Self.fontSize
        // Peak readout; red once a channel clipped (click it to clear).
        let clipped = channels.contains(where: \.clipped)
        let topSize = c.size(of: readout, fontSize: font)
        _ = c.draw(readout, at: CGPoint(x: r.minX + ((r.width - topSize.width) / 2).rounded(), y: r.minY + Self.edgeInset - 1),
                   fontSize: font, clipped ? DrawTheme.color(t.palette.red) : t.label3)
        // Scale labels (dB, no unit), right-aligned beside the bars.
        for tick in Self.scaleTicks {
            let s = tick == 0 ? "0" : "\u{2212}\(Int(-tick))"
            let size = c.size(of: s, fontSize: font)
            _ = c.draw(s, at: CGPoint(x: r.minX + Self.scaleRight - size.width,
                                      y: min(max(y(tick) - size.height / 2, meterTop - 1), meterTop + h - size.height + 1)),
                       fontSize: font, t.label3)
        }
        // "L R" under the bars.
        for (i, name) in channelNames.enumerated() {
            let size = c.size(of: name, fontSize: font)
            _ = c.draw(name, at: CGPoint(x: r.minX + barX(i) + (Self.barWidth - size.width) / 2, y: meterTop + h + 4), fontSize: font,
                       Self.labelColor(i < labels.count ? labels[i] : .normal, t))
        }
        // Bars.
        let segments: [(Float, Float, MeterZone)] = [(MeterBallistics.floorDB, MeterBallistics.yellowStartDB, .green),
                                                     (MeterBallistics.yellowStartDB, MeterBallistics.redStartDB, .yellow),
                                                     (MeterBallistics.redStartDB, MeterBallistics.ceilingDB, .red)]
        for (i, ch) in channels.enumerated() {
            let x = r.minX + barX(i)
            let track = CGRect(x: x, y: meterTop, width: Self.barWidth, height: h)
            c.saveGState()
            // shortcut: rectangle clip, so the level's ends are square where the Mac clips to the 2 pt rounded track;
            // upgrade when Canvas gets a rounded clip.
            c.clip(to: track)
            c.fill(roundedRect: track, radius: 2, t.timeline)        // Theme.Radius.small / 2
            let levelTop = y(ch.levelDB)
            for (lo, hi, zone) in segments {
                let top = max(y(hi), levelTop), bottom = y(lo)
                if bottom > top { c.fill(CGRect(x: x, y: top, width: Self.barWidth, height: bottom - top), Self.color(zone, t)) }
            }
            c.restoreGState()
            if ch.holdDB > MeterBallistics.floorDB {
                c.fill(CGRect(x: x, y: min(max(y(ch.holdDB), meterTop), meterTop + h - 1), width: Self.barWidth, height: 1.5),
                       Self.color(MeterBallistics.zone(dB: ch.holdDB), t))
            }
        }
    }
}

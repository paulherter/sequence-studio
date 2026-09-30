import AppKit

/// Pure meter math: dBFS mapping, color zones and ballistics (peak hold, fall, latched clip). No AppKit state.
public enum MeterZone: Sendable, Equatable { case green, yellow, red }

public struct MeterBallistics: Sendable, Equatable {
    public static let floorDB: Float = -60
    public static let ceilingDB: Float = 0
    /// Green below -12 dBFS, yellow -12...-3, red above -3 (DESIGN.md only names the colors; thresholds per task).
    public static let yellowStartDB: Float = -12
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

    public init() {}

    public static func dB(fromLinear v: Float) -> Float {
        guard v > 0, v.isFinite else { return v.isNaN ? floorDB : (v > 0 ? ceilingDB : floorDB) }
        return max(floorDB, 20 * log10f(v))
    }

    /// 0...1 position along the scale (floor to 0 dBFS), clamped.
    public static func position(dB: Float) -> Float {
        min(1, max(0, (dB - floorDB) / (ceilingDB - floorDB)))
    }

    public static func zone(dB: Float) -> MeterZone {
        dB > redStartDB ? .red : (dB >= yellowStartDB ? .yellow : .green)
    }

    /// Feeds a new linear peak (0...1+, 1.0 = 0 dBFS) at `time` (seconds, monotonic). Pass 0 to only advance time.
    public mutating func update(peak: Float, at time: Double) {
        let dt = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
        let db = Self.dB(fromLinear: peak)
        // Bar: instant attack, linear-in-dB release.
        levelDB = max(db, levelDB - Self.barFallDBPerSecond * Float(dt))
        levelDB = max(Self.floorDB, levelDB)
        // Hold: new maximum restarts the 1.5 s hold, then falls.
        if db >= holdDB {
            holdDB = db; holdSetAt = time
        } else if time - holdSetAt > Self.holdSeconds {
            let fallen = min(dt, time - holdSetAt - Self.holdSeconds)
            holdDB = max(levelDB, holdDB - Self.holdFallDBPerSecond * Float(fallen))
        }
        if peak >= 1 { clipped = true }
    }

    public mutating func resetClip() { clipped = false }

    /// True when nothing is moving any more (timer can stop).
    public var isSettled: Bool { levelDB <= Self.floorDB && holdDB <= Self.floorDB }
}

/// Stereo (or n-channel) peak meter. Feed it with `update(peaks:)` from the engine tap (linear peaks per channel,
/// on the main actor). Clip indicator stays lit until clicked.
@MainActor
public final class AudioMeterView: NSView {
    public private(set) var channels: [MeterBallistics] = [MeterBallistics(), MeterBallistics()]
    private var timer: Timer?
    private var lastPeakTime: Double = 0
    /// Injectable clock for deterministic tests.
    var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }

    private static let clipLED: CGFloat = 6
    private static let barWidth: CGFloat = 8
    private static let gap: CGFloat = 2
    private static let scaleWidth: CGFloat = 22
    private static let scaleTicks: [Float] = [0, -3, -6, -12, -24, -48]

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.scaleWidth + 2 * Self.barWidth + Self.gap + 4, height: NSView.noIntrinsicMetric)
    }

    /// Linear peaks per channel for the last audio block (1.0 = 0 dBFS).
    public func update(peaks: [Float]) {
        if peaks.count != channels.count { channels = Array(repeating: MeterBallistics(), count: max(1, peaks.count)) }
        let now = clock()
        for (i, p) in peaks.enumerated() { channels[i].update(peak: p, at: now) }
        lastPeakTime = now
        startTimerIfNeeded()
        needsDisplay = true
    }

    public func resetClip() {
        for i in channels.indices { channels[i].resetClip() }
        needsDisplay = true
    }

    /// Clears level and hold (e.g. on stop). Clip latch stays until clicked.
    public func reset() {
        let clip = channels.map(\.clipped)
        channels = clip.map { c in var b = MeterBallistics(); if c { b.update(peak: 1, at: 0); b.update(peak: 0, at: 100) }; return b }
        needsDisplay = true
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = clock()
        for i in channels.indices { channels[i].update(peak: 0, at: now) }
        needsDisplay = true
        if channels.allSatisfy(\.isSettled) { timer?.invalidate(); timer = nil }
    }

    isolated deinit { timer?.invalidate() }

    // MARK: drawing

    private var barsOrigin: CGFloat { Self.scaleWidth }
    private var meterTop: CGFloat { Self.clipLED + 4 }

    public override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height - meterTop
        guard h > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Clip LEDs.
        for (i, ch) in channels.enumerated() {
            let x = barsOrigin + CGFloat(i) * (Self.barWidth + Self.gap)
            (ch.clipped ? Theme.Colors.red : Theme.Colors.fill).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: Self.barWidth, height: Self.clipLED), xRadius: 2, yRadius: 2).fill()
        }
        // Scale ticks and labels.
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Fonts.meter, .foregroundColor: Theme.Colors.label3]
        for t in Self.scaleTicks {
            let y = meterTop + h * (1 - CGFloat(MeterBallistics.position(dB: t)))
            let s = NSAttributedString(string: t == 0 ? "0" : String(Int(t)), attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: Self.scaleWidth - 4 - size.width, y: min(max(y - size.height / 2, meterTop - 2), bounds.height - size.height)))
        }
        // Bars.
        for (i, ch) in channels.enumerated() {
            let x = barsOrigin + CGFloat(i) * (Self.barWidth + Self.gap)
            let track = NSRect(x: x, y: meterTop, width: Self.barWidth, height: h)
            Theme.Colors.field.setFill()
            track.fill()
            ctx.saveGState()
            ctx.clip(to: track)
            let levelTop = meterTop + h * (1 - CGFloat(MeterBallistics.position(dB: ch.levelDB)))
            for (lo, hi, color) in Self.segments {
                let yTop = meterTop + h * (1 - CGFloat(MeterBallistics.position(dB: hi)))
                let yBottom = meterTop + h * (1 - CGFloat(MeterBallistics.position(dB: lo)))
                let top = max(yTop, levelTop)
                if yBottom > top { color.setFill(); NSRect(x: x, y: top, width: Self.barWidth, height: yBottom - top).fill() }
            }
            ctx.restoreGState()
            if ch.holdDB > MeterBallistics.floorDB {
                let y = meterTop + h * (1 - CGFloat(MeterBallistics.position(dB: ch.holdDB)))
                color(for: ch.holdDB).setFill()
                NSRect(x: x, y: min(max(y, meterTop), meterTop + h - 1), width: Self.barWidth, height: 1.5).fill()
            }
        }
    }

    private static var segments: [(Float, Float, NSColor)] {
        [(MeterBallistics.floorDB, MeterBallistics.yellowStartDB, Theme.Colors.green),
         (MeterBallistics.yellowStartDB, MeterBallistics.redStartDB, Theme.Colors.yellow),
         (MeterBallistics.redStartDB, MeterBallistics.ceilingDB, Theme.Colors.red)]
    }

    private func color(for dB: Float) -> NSColor {
        switch MeterBallistics.zone(dB: dB) {
        case .green: Theme.Colors.green
        case .yellow: Theme.Colors.yellow
        case .red: Theme.Colors.red
        }
    }

    // MARK: clicks

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y <= Self.clipLED + 4, p.x >= barsOrigin { resetClip() } else { super.mouseDown(with: event) }
    }
}


/// Decides which engine meter readings reach the bars: a reading is fed once (by its buffer counter), so a stopped
/// engine lets the bars fall instead of holding the last peak.
public struct MeterFeed: Sendable, Equatable {
    private var last: Int?
    public init() {}

    public mutating func peaks(for reading: (sequence: Int, peaks: [Float])?) -> [Float]? {
        guard let reading, reading.sequence != last else { return nil }
        last = reading.sequence
        return reading.peaks
    }
}

/// Panel content for the audio meter: the meter bars centred on the panel background, polled from the engine's
/// meter tap (`ProgramEngine.meterReading`) at 30 Hz while the panel is in a window.
@MainActor
public final class AudioMeterPanelView: NSView {
    public let meter = AudioMeterView(frame: .zero)
    public var reading: (() -> (sequence: Int, peaks: [Float])?)?
    private var feed = MeterFeed()
    private var timer: Timer?

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(meter)
        setAccessibilityLabel("Audio meter")
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func layout() {
        super.layout()
        let w = meter.intrinsicContentSize.width
        meter.frame = CGRect(x: ((bounds.width - w) / 2).rounded(), y: Theme.Spacing.md, width: w,
                             height: max(bounds.height - 2 * Theme.Spacing.md, 0))
    }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.panel.setFill()
        dirtyRect.fill()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// One poll (the timer calls this; tests too).
    func poll() {
        if let peaks = feed.peaks(for: reading?()) { meter.update(peaks: peaks) }
    }

    isolated deinit { timer?.invalidate() }
}

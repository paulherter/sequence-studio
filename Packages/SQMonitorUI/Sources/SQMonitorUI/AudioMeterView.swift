import AppKit
import SQAudioFX

/// Stereo (or n-channel) peak meter. Feed it with `update(peaks:)` from the engine tap (linear peaks per channel,
/// on the main actor). Clip indicator stays lit until clicked.
@MainActor
public final class AudioMeterView: NSView {
    public private(set) var channels: [MeterBallistics] = [MeterBallistics(), MeterBallistics()]
    /// Fall speed and hold time. Starts from the user setting; the host may set it when the setting changes.
    public var style: MeterStyle = MeterStyle.current() {
        didSet { for i in channels.indices { channels[i].style = style } }
    }
    private var timer: Timer?
    private var lastPeakTime: Double = 0
    /// Injectable clock for deterministic tests.
    var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }

    /// Design v9 `.tlmeter`: 48 wide; the peak readout on top, two 5 pt bars 3 pt apart, the scale right of them, "L R" below.
    public static let width: CGFloat = 48
    private static let barWidth: CGFloat = 5
    private static let gap: CGFloat = 3
    private static let barsX: CGFloat = 8
    private static let scaleRight: CGFloat = 39
    private static let topInset: CGFloat = 22
    private static let bottomInset: CGFloat = 22
    private static let edgeInset: CGFloat = 8
    private static let scaleTicks: [Float] = [0, -6, -12, -20, -30]

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: NSView.noIntrinsicMetric)
    }

    /// Mono sequence (Sequence Settings > Channels): one bar, labeled "M", for the single folded channel.
    public var isMono = false {
        didSet {
            guard isMono != oldValue else { return }
            channels = Array(repeating: MeterBallistics(style: style), count: isMono ? 1 : 2)
            needsDisplay = true
        }
    }
    /// Monitoring-only Solo/Mute of the output channels (speakers; this meter keeps showing every channel).
    public var channelMonitor = ChannelMonitor() {
        didSet { if channelMonitor != oldValue { needsDisplay = true } }
    }
    /// The user changed Solo/Mute (click under a bar: Solo; Option-click: Mute). The host applies it to the engine.
    public var onChannelMonitorChange: ((ChannelMonitor) -> Void)?

    /// Output channels a bar stands for: the Mono bar is both.
    func channels(forBar i: Int) -> [Int] { isMono ? [0, 1] : [min(max(i, 0), ChannelMonitor.channelCount - 1)] }

    /// Bar index whose label column is at `x`, nil between the columns.
    func bar(atX x: CGFloat) -> Int? {
        let count = isMono ? 1 : 2
        for i in 0..<count {
            let bx = Self.barsX + CGFloat(i) * (Self.barWidth + Self.gap) + (isMono ? (Self.barWidth + Self.gap) / 2 : 0)
            if x >= bx - Self.gap && x <= bx + Self.barWidth + Self.gap { return i }
        }
        return nil
    }

    public func toggleSolo(bar: Int) {
        var m = channelMonitor
        m.toggleSolo(channels(forBar: bar))
        channelMonitor = m
        onChannelMonitorChange?(m)
    }

    public func toggleMute(bar: Int) {
        var m = channelMonitor
        m.toggleMute(channels(forBar: bar))
        channelMonitor = m
        onChannelMonitorChange?(m)
    }

    public func clearChannelMonitor() {
        guard !channelMonitor.isNeutral else { return }
        channelMonitor.clear()
        onChannelMonitorChange?(channelMonitor)
    }

    /// Label colour under a bar: accent = soloed, red = muted (dim red = silenced by another channel's solo).
    private func labelColor(bar i: Int) -> NSColor {
        let chs = channels(forBar: i)
        if chs.allSatisfy(channelMonitor.isMuted) { return Theme.Colors.red }
        if chs.allSatisfy(channelMonitor.isSoloed) { return Theme.Colors.accent }
        if !chs.contains(where: channelMonitor.isAudible) { return Theme.Colors.red.withAlphaComponent(0.6) }
        return Theme.Colors.label3
    }

    /// Bar labels under the bars.
    var channelNames: [String] { isMono ? ["M"] : ["L", "R"] }

    /// Linear peaks per channel for the last audio block (1.0 = 0 dBFS). A Mono sequence shows one bar: the loudest side.
    public func update(peaks input: [Float]) {
        let peaks = isMono ? [input.max() ?? 0] : input
        if peaks.count != channels.count { channels = Array(repeating: MeterBallistics(style: style), count: max(1, peaks.count)) }
        let now = clock()
        let wanted = MeterStyle.current()
        if wanted != style { style = wanted }   // the Settings page changed it
        for (i, p) in peaks.enumerated() { channels[i].update(peak: p, at: now, isSignal: true) }
        lastPeakTime = now
        startTimerIfNeeded()
        needsDisplay = true
    }

    public func resetClip() {
        for i in channels.indices { channels[i].resetClip() }
        needsDisplay = true
    }

    /// Level and hold to zero at once (no new audio arrives: stopped or paused). Clip latch stays.
    public func silence() {
        for i in channels.indices { channels[i].silence() }
        needsDisplay = true
    }

    /// Clears level and hold (e.g. on stop). Clip latch stays until clicked.
    public func reset() {
        let clip = channels.map(\.clipped)
        channels = clip.map { c in var b = MeterBallistics(style: style); if c { b.update(peak: 1, at: 0); b.update(peak: 0, at: 100) }; return b }
        needsDisplay = true
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // keeps running while the user scrubs or drags
        timer = t
    }

    private func tick() {
        let now = clock()
        for i in channels.indices { channels[i].update(peak: 0, at: now) }
        needsDisplay = true
        if channels.allSatisfy(\.isSettled) { timer?.invalidate(); timer = nil }
    }

    isolated deinit { timer?.invalidate() }

    // MARK: drawing

    private var meterTop: CGFloat { Self.topInset }

    /// The readout on top: the highest held peak in dB ("-12.3"), a dash while silent.
    var readout: String {
        let peak = channels.map(\.holdDB).max() ?? MeterBallistics.floorDB
        guard peak > MeterBallistics.floorDB else { return "\u{2013}" }
        let v = (Double(peak) * 10).rounded() / 10
        return v < 0 ? "\u{2212}" + String(format: "%.1f", -v) : String(format: "%.1f", v)
    }

    // MARK: accessibility

    /// "Left, minus 12.3 dB. Right, silent": the held peak per channel, the clip latch winning.
    var accessibilityLevels: String {
        let names = channelNames
        return SQAccessibilityText.meterValue(channels.enumerated().map { i, c in
            SQAccessibilityText.meterChannel(name: SQAccessibilityText.channelName(i < names.count ? names[i] : "\(i + 1)"),
                                             dB: c.holdDB > MeterBallistics.floorDB ? c.holdDB : nil, clipped: c.clipped)
        })
    }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }
    public override func accessibilityLabel() -> String? { SQAccessibilityText.meterLabel }
    public override func accessibilityValue() -> Any? { accessibilityLevels }
    public override func accessibilityHelp() -> String? {
        "Click to reset the clip indicator. Click a channel label to solo it, Option-click to mute it"
    }

    public override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height - meterTop - Self.bottomInset
        guard h > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // One bar (Mono) sits where the pair's middle is.
        func barX(_ i: Int) -> CGFloat { Self.barsX + CGFloat(i) * (Self.barWidth + Self.gap) + (isMono ? (Self.barWidth + Self.gap) / 2 : 0) }
        let font = Theme.Typography.ns(9.5, .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.Colors.label3]
        // Peak readout; red once a channel clipped (click it to clear).
        let clipped = channels.contains(where: \.clipped)
        let top = NSAttributedString(string: readout, attributes: [.font: font, .foregroundColor: clipped ? Theme.Colors.red : Theme.Colors.label3])
        let topSize = top.size()
        top.draw(at: NSPoint(x: ((bounds.width - topSize.width) / 2).rounded(), y: Self.edgeInset - 1))
        // Scale labels (dB, no unit), right-aligned beside the bars.
        for t in Self.scaleTicks {
            let y = meterTop + h * (1 - CGFloat(MeterBallistics.position(dB: t)))
            let s = NSAttributedString(string: t == 0 ? "0" : "\u{2212}\(Int(-t))", attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: Self.scaleRight - size.width, y: min(max(y - size.height / 2, meterTop - 1), meterTop + h - size.height + 1)))
        }
        // "L R" under the bars.
        for (i, name) in channelNames.enumerated() {
            var labelAttrs = attrs
            labelAttrs[.foregroundColor] = labelColor(bar: i)
            let s = NSAttributedString(string: name, attributes: labelAttrs)
            let size = s.size()
            s.draw(at: NSPoint(x: barX(i) + (Self.barWidth - size.width) / 2, y: meterTop + h + 4))
        }
        // Bars.
        for (i, ch) in channels.enumerated() {
            let x = barX(i)
            let track = NSRect(x: x, y: meterTop, width: Self.barWidth, height: h)
            ctx.saveGState()
            NSBezierPath(roundedRect: track, xRadius: Theme.Radius.small / 2, yRadius: Theme.Radius.small / 2).addClip()
            Theme.Colors.timeline.setFill()
            track.fill()
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
        if p.y <= Self.topInset { resetClip(); return }
        if p.y >= bounds.height - Self.bottomInset, let bar = bar(atX: p.x) {
            if event.modifierFlags.contains(.option) { toggleMute(bar: bar) } else { toggleSolo(bar: bar) }
            return
        }
        // Swallowed: the meter sits inside the Source waveform view, where a click on the bars must not scrub.
    }
    public override func mouseDragged(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {}
}


/// Panel content for the audio meter: the slim L/R peak bars centered on the panel background, polled from the engine's
/// meter tap (`ProgramEngine.meterReading`) at 30 Hz while the panel is in a window.
@MainActor
public final class AudioMeterPanelView: NSView {
    public let meter = AudioMeterView(frame: .zero)
    /// M / S / I / TP columns next to the peak bars (R128 numbers, same meter the export normalizer uses).
    public let loudness: LoudnessMeterView = { let v = LoudnessMeterView(frame: .zero); v.style = .columns; return v }()
    /// Delivery target of the sequence the loudness bars measure against.
    public var loudnessTarget: LoudnessTarget { get { loudness.target } set { loudness.target = newValue } }
    public var loudnessReading: (() -> LoudnessReading?)?
    public var loudnessTargetProvider: (() -> LoudnessTarget)?
    /// Click on the loudness bars restarts integrated and true-peak hold.
    public var onResetLoudness: (() -> Void)?
    public var reading: (() -> (source: ObjectIdentifier, sequence: Int, peaks: [Float])?)?
    /// Asked at every poll: whether the active sequence is Mono (Sequence Settings > Channels).
    public var monoProvider: (() -> Bool)?
    /// Solo/Mute changed on the meter (monitoring only): the host hands it to the audio engine
    /// (`AudioPlaying.setChannelMonitor`).
    public var onChannelMonitorChange: ((ChannelMonitor) -> Void)?
    /// Mono sequence: the meter shows one bar.
    public var isMono: Bool { get { meter.isMono } set { meter.isMono = newValue } }
    /// F7.5 listening level (speakers only; meters, export and project are untouched). Stored in `sq.monitor.*`.
    public let monitorSlider = SQSlider(value: 0, minValue: MonitorGain.minDB, maxValue: MonitorGain.maxDB)
    public let dimButton = IconButton(symbol: .volumeLow, label: "Dim Monitor", handler: {})
    private let monitorDefaults: UserDefaults
    public static let monitorStripHeight: CGFloat = Theme.Metrics.monitorStrip
    /// The slider and Dim strip shows from this panel width on. The slim meter (design v9, 48 pt) has no strip: the same
    /// two controls are in its right-click menu (`monitorItems`).
    public static let monitorStripMinWidth: CGFloat = 72
    private var feed = MeterFeed()
    private var timer: Timer?
    private var lastBufferTime: Double = 0
    /// Injectable clock for deterministic tests.
    var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// No new audio buffer for this long means playback stopped: the bars go to zero at once.
    static let staleSeconds: Double = 0.15

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }

    public convenience override init(frame: NSRect) { self.init(frame: frame, monitorDefaults: .standard) }

    public init(frame: NSRect, monitorDefaults: UserDefaults) {
        self.monitorDefaults = monitorDefaults
        super.init(frame: frame)
        addSubview(meter)
        addSubview(loudness)
        addSubview(monitorSlider)
        addSubview(dimButton)
        MonitorGain.applyLaunchRulesOnce(defaults: monitorDefaults)   // before the strip reads its state
        let current = MonitorGain.Setting.current(defaults: monitorDefaults)
        monitorSlider.defaultValue = MonitorGain.maxDB
        monitorSlider.doubleValue = current.levelDB
        monitorSlider.sqToolTip = "Listening Volume"
        dimButton.isSelected = current.dim
        monitorSlider.onChange = { [weak self] v in self?.setMonitor(levelDB: v) }
        dimButton.handler = { [weak self] in
            guard let self else { return }
            self.setMonitor(dim: !self.dimButton.isSelected)
        }
        loudness.onReset = { [weak self] in self?.onResetLoudness?() }
        meter.onChannelMonitorChange = { [weak self] m in self?.onChannelMonitorChange?(m) }
        setAccessibilityLabel(SQAccessibilityText.meterLabel)
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Writes the listening level; the audio engine follows the defaults live.
    func setMonitor(levelDB: Double? = nil, dim: Bool? = nil) {
        var s = MonitorGain.Setting.current(defaults: monitorDefaults)
        if let levelDB { s.levelDB = levelDB }
        if let dim { s.dim = dim; dimButton.isSelected = dim }
        MonitorGain.store(s, defaults: monitorDefaults)
    }

    /// Right-click on the meter: listening volume steps, Dim and the peak reset as SQ rows.
    func monitorItems() -> [SQMenuItem] {
        let s = MonitorGain.Setting.current(defaults: monitorDefaults)
        var rows: [SQMenuItem] = [.header("Listening Volume")]
        for db in [0.0, -6, -12, -18, -24, -36] {
            rows.append(SQMenuItem(title: db == 0 ? "Full (0 dB)" : "\u{2212}\(Int(-db)) dB", isChecked: s.levelDB == db) { [weak self] in
                self?.setMonitor(levelDB: db)
                self?.monitorSlider.doubleValue = db
            })
        }
        rows.append(.separator)
        rows.append(.header("Channels"))
        let cm = meter.channelMonitor
        for (i, name) in meter.channelNames.enumerated() {
            let chs = meter.channels(forBar: i)
            rows.append(SQMenuItem(title: "Solo \(name)", isChecked: chs.allSatisfy(cm.isSoloed)) { [weak self] in self?.meter.toggleSolo(bar: i) })
            rows.append(SQMenuItem(title: "Mute \(name)", isChecked: chs.allSatisfy(cm.isMuted)) { [weak self] in self?.meter.toggleMute(bar: i) })
        }
        rows.append(SQMenuItem(title: "Clear Solo and Mute") { [weak self] in self?.meter.clearChannelMonitor() })
        rows.append(.separator)
        rows.append(SQMenuItem(title: "Dim Monitor", isChecked: s.dim) { [weak self] in self?.setMonitor(dim: !s.dim) })
        rows.append(SQMenuItem(title: "Reset Peak and Loudness") { [weak self] in
            self?.meter.resetClip()
            self?.onResetLoudness?()
        })
        return rows
    }

    public override func rightMouseDown(with event: NSEvent) {
        SQContextMenu.popUp(items: monitorItems(), at: convert(event.locationInWindow, from: nil), in: self)
    }

    /// The slim meter (design v9, 48 wide) centered in the panel, the full panel height.
    public override func layout() {
        super.layout()
        let gap = Theme.Spacing.sm
        let showLoudness = bounds.width >= AudioMeterView.width + gap + LoudnessMeterView.columnsWidth
        let lw = showLoudness ? LoudnessMeterView.columnsWidth : 0
        let w = min(AudioMeterView.width, bounds.width)
        let total = w + (showLoudness ? gap + lw : 0)
        let x = ((bounds.width - total) / 2).rounded()
        let fits = bounds.height >= 100 && bounds.width >= Self.monitorStripMinWidth
        let strip = fits ? Self.monitorStripHeight : 0
        let meterH = bounds.height - strip
        meter.frame = CGRect(x: x, y: 0, width: w, height: meterH)
        loudness.isHidden = !showLoudness
        loudness.frame = CGRect(x: x + w + gap, y: 0, width: lw, height: meterH)
        monitorSlider.isHidden = strip == 0
        dimButton.isHidden = strip == 0
        let sw = max(0, min(bounds.width - 2 * gap, Theme.Metrics.monitorSliderMaxWidth))
        let sx = ((bounds.width - sw) / 2).rounded()
        monitorSlider.frame = CGRect(x: sx, y: meterH + gap, width: sw, height: Theme.Metrics.monitorSliderHeight)
        dimButton.frame = CGRect(x: ((bounds.width - Theme.Metrics.monitorDimWidth) / 2).rounded(), y: meterH + gap + Theme.Metrics.monitorSliderHeight + gap / 2,
                               width: Theme.Metrics.monitorDimWidth, height: Theme.Metrics.monitorDimHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.panel.setFill()
        dirtyRect.fill()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One poll (the timer calls this; tests too).
    func poll() {
        let now = clock()
        if let mono = monoProvider?(), mono != isMono { isMono = mono }
        if let peaks = feed.peaks(for: reading?()) {
            lastBufferTime = now
            meter.update(peaks: peaks)
            if let l = loudnessReading?() { loudness.reading = l }
            if let t = loudnessTargetProvider?() { loudness.target = t }
        } else if now - lastBufferTime > Self.staleSeconds, meter.channels.contains(where: { !$0.isSettled }) {
            meter.silence()
            if loudness.reading.momentaryLUFS != nil || loudness.reading.shortTermLUFS != nil {
                var l = loudness.reading; l.momentaryLUFS = nil; l.shortTermLUFS = nil; loudness.reading = l
            }
        }
    }

    isolated deinit { timer?.invalidate() }
}

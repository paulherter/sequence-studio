import Foundation
import SQAudioFX
import SQCore
import SQDrawKit
import SQPlayback
import SQUIKit

extension LoudnessReading {
    /// The engine's meter snapshot as a reading (same BS.1770 numbers the export normalizer measures).
    public init(_ l: LoudnessLevels) {
        self.init(momentaryLUFS: l.momentary, shortTermLUFS: l.shortTerm, integratedLUFS: l.integrated, truePeakDB: l.truePeakDB)
    }
}

/// The audio meter panel on the canvas (the Mac `AudioMeterPanelView` translated): the slim L/R peak bars and the
/// M / S / I / TP loudness columns beside them, polled from the engine's meter feed, a click on the loudness columns
/// restarts integrated and true-peak hold, a click on a channel label solos it (Alt: mutes it), the listening volume
/// strip (slider and Dim) under the meter when the card is tall and wide enough, a right click opens the meter menu
/// (listening steps, channel Solo / Mute, Dim, reset). Listening level and Dim are the `sq.monitor.*` preference
/// (`MonitorGain`); the host applies them and Solo / Mute to the audio output (speakers only, never the meter).
@MainActor
public final class MeterPanel {
    public var meter = AudioMeter()
    public var loudness = LoudnessMeter(style: .columns)
    public var theme = DrawTheme()
    /// The card in points.
    public private(set) var frame: CGRect = .zero
    public private(set) var meterRect: CGRect = .zero
    public private(set) var loudnessRect: CGRect = .zero
    /// The listening strip (zero when the card is too small, as on the Mac) and its two controls.
    public private(set) var stripRect: CGRect = .zero
    public private(set) var sliderRect: CGRect = .zero
    public private(set) var dimRect: CGRect = .zero
    /// Monitoring-only Solo / Mute of the output channels (the meter keeps showing every channel).
    public private(set) var channelMonitor = ChannelMonitor()
    private var draggingSlider = false
    private var hoverDim = false
    private let monitorDefaults: UserDefaults
    private var scale: Float = 1
    private var feed = MeterFeed()
    private var lastBufferTime: Double = 0
    /// No new audio buffer for this long means playback stopped: the bars go to zero at once.
    static let staleSeconds: Double = 0.15

    public var reading: (() -> (source: ObjectIdentifier, sequence: Int, peaks: [Float])?)?
    public var loudnessReading: (() -> LoudnessReading?)?
    public var loudnessTargetProvider: (() -> LoudnessTarget)?
    public var monoProvider: (() -> Bool)?
    public var onResetLoudness: (() -> Void)?
    public var onMenu: ((_ items: [SQMenuItem], _ at: CGPoint) -> Void)?
    /// Solo / Mute changed: the host hands it to the audio output (`AudioPlaying.setChannelMonitor`).
    public var onChannelMonitorChange: ((ChannelMonitor) -> Void)?
    /// The listening level or Dim changed (already stored in the defaults): the host applies it to the output.
    public var onMonitorGainChange: ((MonitorGain.Setting) -> Void)?

    /// The strip shows from this card width on (AudioMeterPanelView.monitorStripMinWidth) and 100 pt of height.
    public static let monitorStripMinWidth: CGFloat = 72

    public init(monitorDefaults: UserDefaults = .standard) {
        self.monitorDefaults = monitorDefaults
        MonitorGain.applyLaunchRulesOnce(defaults: monitorDefaults)   // before the strip reads its state
    }

    /// The listening level and Dim now (the preference).
    public var monitorSetting: MonitorGain.Setting { MonitorGain.Setting.current(defaults: monitorDefaults) }

    /// Writes the listening level and / or Dim and reports it (AudioMeterPanelView.setMonitor).
    public func setMonitor(levelDB: Double? = nil, dim: Bool? = nil) {
        var s = monitorSetting
        if let levelDB { s.levelDB = min(max(levelDB, MonitorGain.minDB), MonitorGain.maxDB) }
        if let dim { s.dim = dim }
        MonitorGain.store(s, defaults: monitorDefaults)
        onMonitorGainChange?(s)
    }

    // MARK: Solo / Mute (AudioMeterView.toggleSolo / toggleMute)

    public func toggleSolo(bar: Int) {
        channelMonitor.toggleSolo(meter.channels(forBar: bar, channelCount: ChannelMonitor.channelCount))
        onChannelMonitorChange?(channelMonitor)
    }
    public func toggleMute(bar: Int) {
        channelMonitor.toggleMute(meter.channels(forBar: bar, channelCount: ChannelMonitor.channelCount))
        onChannelMonitorChange?(channelMonitor)
    }
    public func clearChannelMonitor() {
        guard !channelMonitor.isNeutral else { return }
        channelMonitor.clear()
        onChannelMonitorChange?(channelMonitor)
    }

    /// What each bar's label shows: soloed (accent), muted (red), silenced by another channel's solo (dim red).
    public var channelLabels: [MeterChannelLabel] {
        meter.channelNames.indices.map { i in
            let chs = meter.channels(forBar: i, channelCount: ChannelMonitor.channelCount)
            if chs.allSatisfy(channelMonitor.isMuted) { return .muted }
            if chs.allSatisfy(channelMonitor.isSoloed) { return .soloed }
            if !chs.contains(where: channelMonitor.isAudible) { return .silenced }
            return .normal
        }
    }

    /// AudioMeterPanelView.layout: the meter (48 pt) and, when it fits, the loudness columns, centered.
    public func layout(_ r: DrawRect, scale: Float) {
        self.scale = max(scale, 0.01)
        let k = CGFloat(self.scale)
        frame = CGRect(x: CGFloat(r.x) / k, y: CGFloat(r.y) / k, width: CGFloat(r.w) / k, height: CGFloat(r.h) / k)
        let gap = CGFloat(DrawTheme.Spacing.sm)
        let showLoudness = frame.width >= AudioMeter.width + gap + LoudnessMeter.columnsWidth
        let lw = showLoudness ? LoudnessMeter.columnsWidth : 0
        let w = min(AudioMeter.width, frame.width)
        let total = w + (showLoudness ? gap + lw : 0)
        let x = frame.minX + ((frame.width - total) / 2).rounded()
        let fits = frame.height >= 100 && frame.width >= Self.monitorStripMinWidth
        let strip = fits ? CGFloat(DrawTheme.Metrics.monitorStrip) : 0
        let meterH = frame.height - strip
        meterRect = CGRect(x: x, y: frame.minY, width: w, height: meterH)
        loudnessRect = showLoudness ? CGRect(x: x + w + gap, y: frame.minY, width: lw, height: meterH) : .zero
        guard fits else { stripRect = .zero; sliderRect = .zero; dimRect = .zero; return }
        stripRect = CGRect(x: frame.minX, y: frame.minY + meterH, width: frame.width, height: strip)
        let sw = max(0, min(frame.width - 2 * gap, CGFloat(DrawTheme.Metrics.monitorSliderMaxWidth)))
        let sh = CGFloat(DrawTheme.Metrics.monitorSliderHeight)
        sliderRect = CGRect(x: frame.minX + ((frame.width - sw) / 2).rounded(), y: stripRect.minY + gap, width: sw, height: sh)
        let dw = CGFloat(DrawTheme.Metrics.monitorDimWidth), dh = CGFloat(DrawTheme.Metrics.monitorDimHeight)
        dimRect = CGRect(x: frame.minX + ((frame.width - dw) / 2).rounded(), y: sliderRect.maxY + gap / 2, width: dw, height: dh)
    }

    /// Slider position of a level: linear in dB between the floor (mute) and 0 dB, as the Mac SQSlider.
    static func sliderFraction(levelDB: Double) -> Double {
        (min(max(levelDB, MonitorGain.minDB), MonitorGain.maxDB) - MonitorGain.minDB) / (MonitorGain.maxDB - MonitorGain.minDB)
    }
    static func levelDB(sliderFraction f: Double) -> Double {
        MonitorGain.minDB + max(0, min(1, f)) * (MonitorGain.maxDB - MonitorGain.minDB)
    }

    /// One poll (AudioMeterPanelView.poll; the host calls it every frame).
    public func poll(now: Double) {
        if let mono = monoProvider?(), mono != meter.isMono { meter.isMono = mono }
        if let t = loudnessTargetProvider?() { loudness.target = t }
        if let peaks = feed.peaks(for: reading?()) {
            lastBufferTime = now
            let wanted = MeterStyle.current(monitorDefaults)   // the Settings page changed it (AudioMeterView.update)
            if wanted != meter.style { meter.style = wanted }
            meter.update(peaks: peaks, at: now)
            if let l = loudnessReading?() { loudness.update(l, at: now) }
        } else if now - lastBufferTime > Self.staleSeconds {
            if !meter.isSettled { meter.silence() }
            loudness.clearLive()
        }
        meter.tick(at: now)
    }

    public func draw(_ c: inout Canvas) {
        guard frame.width > 0, frame.height > 0 else { return }
        c.fill(roundedRect: frame, radius: CGFloat(DrawTheme.Radius.panel), theme.panel)
        meter.draw(&c, in: meterRect, theme: theme, labels: channelLabels)
        if loudnessRect.width > 0 { loudness.draw(&c, in: loudnessRect, theme: theme) }
        guard stripRect.height > 0 else { return }
        let s = monitorSetting
        InspectorDraw.slider(&c, fraction: Self.sliderFraction(levelDB: s.levelDB), in: sliderRect, enabled: true, theme)
        let r = CGFloat(DrawTheme.Radius.small)
        if s.dim { c.fill(roundedRect: dimRect, radius: r, theme.accentFill) }
        else if hoverDim { c.fill(roundedRect: dimRect, radius: r, theme.fillHover) }
        let icon: CGFloat = 12
        c.draw(icon: .volumeLow, at: CGPoint(x: dimRect.midX - icon / 2, y: dimRect.midY - icon / 2), size: icon,
               s.dim ? theme.accent : theme.label2)
    }

    /// The meter menu (AudioMeterPanelView.monitorItems): listening volume steps, channel Solo / Mute, Dim and the reset.
    public func menuItems() -> [SQMenuItem] {
        let s = monitorSetting
        var rows: [SQMenuItem] = [.header("Listening Volume")]
        for db in [0.0, -6, -12, -18, -24, -36] {
            rows.append(SQMenuItem(title: db == 0 ? "Full (0 dB)" : "\u{2212}\(Int(-db)) dB", isChecked: s.levelDB == db) { [weak self] in
                self?.setMonitor(levelDB: db)
            })
        }
        rows.append(.separator)
        rows.append(.header("Channels"))
        let cm = channelMonitor
        for (i, name) in meter.channelNames.enumerated() {
            let chs = meter.channels(forBar: i, channelCount: ChannelMonitor.channelCount)
            rows.append(SQMenuItem(title: "Solo \(name)", isChecked: chs.allSatisfy(cm.isSoloed)) { [weak self] in self?.toggleSolo(bar: i) })
            rows.append(SQMenuItem(title: "Mute \(name)", isChecked: chs.allSatisfy(cm.isMuted)) { [weak self] in self?.toggleMute(bar: i) })
        }
        rows.append(SQMenuItem(title: "Clear Solo and Mute") { [weak self] in self?.clearChannelMonitor() })
        rows.append(.separator)
        rows.append(SQMenuItem(title: "Dim Monitor", isChecked: s.dim) { [weak self] in self?.setMonitor(dim: !s.dim) })
        rows.append(SQMenuItem(title: "Reset Peak and Loudness") { [weak self] in
            self?.meter.resetClip(); self?.loudness.resetPeak(); self?.onResetLoudness?()
        })
        return rows
    }

    /// An event in pixels; true when the panel took it (a press on the card, the slider drag that followed it).
    public func handle(_ e: InputEvent) -> Bool {
        let k = CGFloat(scale)
        switch e {
        case .mouseDown(let x, let y, let mods):
            let p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
            guard frame.contains(p) else { return false }
            if mods.contains(.secondary) { onMenu?(menuItems(), p); return true }
            if loudnessRect.contains(p) { loudness.resetPeak(); onResetLoudness?(); return true }
            if dimRect.contains(p) { setMonitor(dim: !monitorSetting.dim); return true }
            if sliderRect.insetBy(dx: 0, dy: -4).contains(p) {
                draggingSlider = true
                setMonitor(levelDB: Self.levelDB(sliderFraction: InspectorDraw.sliderFraction(x: p.x, in: sliderRect)))
                return true
            }
            if meterRect.contains(p) {
                switch meter.hit(CGPoint(x: p.x - meterRect.minX, y: p.y - meterRect.minY), height: meterRect.height) {
                case .resetClip: meter.resetClip()
                case .channel(let bar): if mods.contains(.option) { toggleMute(bar: bar) } else { toggleSolo(bar: bar) }
                case .none: break
                }
            }
            return true
        case .mouseDragged(let x, _):
            guard draggingSlider else { return false }
            setMonitor(levelDB: Self.levelDB(sliderFraction: InspectorDraw.sliderFraction(x: CGFloat(x) / k, in: sliderRect)))
            return true
        case .mouseUp:
            guard draggingSlider else { return false }
            draggingSlider = false
            return true
        case .mouseMoved(let x, let y):
            hoverDim = dimRect.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k))
            return false
        default:
            return false
        }
    }
}

import AppKit
import SQCore
import SQMedia

/// Source monitor viewer for audio-only media (MON-36): the whole file's waveform with the In-Out range and the playhead.
/// Click or drag scrubs, like the strip below. State comes from `MonitorPanelModel`; the host feeds `sourceWaveform`.
@MainActor
public final class SourceWaveformView: NSView {
    private let model: MonitorPanelModel
    private var scrubbing = false
    private static let inset: CGFloat = 8
    private static let verticalInset: CGFloat = 24

    /// Level meter of the source player's own output for audio-only media. The host sets `meterReading` (the Source
    /// engine's `meterReading` with its identity); without it no meter shows and the waveform spans the full width.
    public let meter = AudioMeterView(frame: .zero)
    public var meterReading: (() -> (source: ObjectIdentifier, sequence: Int, peaks: [Float])?)? {
        didSet { meter.isHidden = meterReading == nil; needsLayout = true; needsDisplay = true; restartTimer() }
    }
    private var feed = MeterFeed()
    private var meterTimer: Timer?
    private var lastBufferTime: Double = 0
    var clock: @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Same rule as the Program meter: no new buffer for this long = stopped, bars fall to zero at once.
    static let staleSeconds: Double = 0.15

    public init(model: MonitorPanelModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityLabel("Audio waveform")
        setAccessibilityRole(.slider)
        meter.isHidden = true
        addSubview(meter)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    private var meterShown: Bool { meterReading != nil }
    /// Width the waveform and the scrub map use: the meter column is not part of it.
    private var contentWidth: CGFloat {
        meterShown ? max(1, bounds.width - AudioMeterView.width - Self.inset) : bounds.width
    }

    public override func layout() {
        super.layout()
        meter.frame = NSRect(x: bounds.width - AudioMeterView.width - Self.inset / 2, y: 0, width: AudioMeterView.width, height: bounds.height)
    }

    private var math: MonitorScrubMath {
        MonitorScrubMath(duration: model.duration, frameDuration: model.frameDuration, width: contentWidth, inset: Self.inset)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartTimer()
    }

    private func restartTimer() {
        meterTimer?.invalidate(); meterTimer = nil
        guard window != nil, meterShown else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollMeter() }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    /// One meter poll (the timer calls this; tests too).
    func pollMeter() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        let now = clock()
        if let peaks = feed.peaks(for: meterReading?()) {
            lastBufferTime = now
            meter.update(peaks: peaks)
        } else if now - lastBufferTime > Self.staleSeconds, meter.channels.contains(where: { !$0.isSettled }) {
            meter.silence()
        }
    }

    isolated deinit { meterTimer?.invalidate() }

    /// Scrub gesture step at view x; the first call of a gesture reports `onScrubBegan`.
    func scrub(began: Bool, x: CGFloat) {
        guard model.duration > .zero else { return }
        if began { scrubbing = true; model.onScrubBegan?() }
        guard scrubbing else { return }
        let t = math.time(atX: x)
        if let s = model.onScrub { s(t) } else { model.onSeek?(t) }
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        model.onScrubEnded?()
    }

    public override func mouseDown(with event: NSEvent) { scrub(began: true, x: convert(event.locationInWindow, from: nil).x) }
    public override func mouseDragged(with event: NSEvent) { scrub(began: false, x: convert(event.locationInWindow, from: nil).x) }
    public override func mouseUp(with event: NSEvent) { endScrub() }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.monitorBackdrop.setFill()
        bounds.fill()
        let wave = NSRect(x: Self.inset, y: Self.verticalInset, width: max(contentWidth - 2 * Self.inset, 1),
                          height: max(bounds.height - 2 * Self.verticalInset, 1))
        let m = math
        let total = model.duration
        // In-Out range behind the peaks (Out is stored one frame past the last frame).
        if model.markIn != nil || model.markOut != nil, total > .zero {
            let a = m.x(for: model.markIn ?? .zero), b = m.x(for: model.markOut ?? total)
            if b > a {
                Theme.Colors.accentTint.setFill()
                NSRect(x: a, y: wave.minY - 8, width: b - a, height: wave.height + 16).fill()
            }
        }
        guard let data = model.sourceWaveform, total > .zero, let cg = NSGraphicsContext.current?.cgContext else {
            let text = model.duration > .zero ? "Building waveform\u{2026}" : ""
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
            drawPlayhead(m)
            return
        }
        var style = WaveformStyle()
        style.shape = .bipolar
        let width = Int(wave.width.rounded())
        let input = WaveformPath.Input(data: data, source: TimeRange(start: .zero, end: total), clipWidth: wave.width,
                                       visibleColumns: 0..<width, style: style)
        WaveformPath.draw(in: cg, input: input, rect: wave, color: Theme.white(0.62).cgColor, clipColor: Theme.Colors.red.cgColor)
        drawPlayhead(m)
    }

    private func drawPlayhead(_ m: MonitorScrubMath) {
        guard model.duration > .zero else { return }
        Theme.Colors.playhead.setFill()
        Theme.PlayheadSkin.lineFrame(centerX: m.x(for: model.currentTime), height: bounds.height).fill()
    }
}

/// The quiet dot in the monitor's corner: dim at rest, amber while frames were dropped; next to it the count of the last
/// play run, and "Realtime not achieved" once the run dropped too many (persists until the next run).
@MainActor
final class DropDotView: NSView {
    var amber = false { didSet { if amber != oldValue { needsDisplay = true } } }
    var warn = false { didSet { if warn != oldValue { needsDisplay = true } } }
    var text: String? { didSet { if text != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var tip = "" { didSet { if tip != oldValue { setTooltip(tip); setAccessibilityLabel(tip) } } }
    static let size: CGFloat = 14

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Theme.Typography.caption, .foregroundColor: warn ? Theme.Colors.warning : Theme.Colors.label2]
    }
    private var textWidth: CGFloat { text.map { ceil(($0 as NSString).size(withAttributes: attributes).width) } ?? 0 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.size + (text == nil ? 0 : textWidth + Theme.Spacing.sm), height: Self.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        (amber || warn ? Theme.Colors.warning : Theme.Colors.label3.withAlphaComponent(0.5)).setFill()
        let d: CGFloat = 6
        NSBezierPath(ovalIn: NSRect(x: (Self.size - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)).fill()
        guard let text else { return }
        let h = ("Ag" as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(at: NSPoint(x: Self.size, y: (bounds.height - h) / 2), withAttributes: attributes)
    }
}

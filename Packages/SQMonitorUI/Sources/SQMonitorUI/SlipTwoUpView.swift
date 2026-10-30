import AppKit
import SQCore

// `SlipTwoUpLayout` (pane frames, readout) lives in SQDrawMonitor: the canvas monitor on Windows draws the same two-up.

/// The Slip two-up viewer: first and last frame of the clip being slipped, side by side, live during the drag
/// (the host feeds it `TimelineInteraction.slipTwoUp` and `preview`). Each picture has its own parked engine, the Program
/// engine is untouched, same as `TrimMonitorView`. The host overlays it on the Program viewer while a Slip drag runs.
@MainActor
public final class SlipTwoUpView: NSView {
    private let engines: (head: any ProgramEngine, tail: any ProgramEngine)
    private let headPane = Pane(title: "First frame")
    private let tailPane = Pane(title: "Last frame")
    private let readout = NSTextField(labelWithString: "")
    private var shown: (timeline: Timeline, sequences: [Timeline.ID: Timeline])?
    /// Both engines let go of the sequence (drag ended): the host frees their frame cache.
    public var onRelease: (() -> Void)?

    public init(headEngine: any ProgramEngine, tailEngine: any ProgramEngine) {
        engines = (headEngine, tailEngine)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.monitorBackdrop.cgColor
        setAccessibilityLabel("Slip viewer")
        addSubview(headPane); addSubview(tailPane)
        readout.font = Theme.Typography.body
        readout.textColor = Theme.Colors.label2
        readout.alignment = .center
        addSubview(readout)
        for p in [headPane, tailPane] { p.viewer.drivesLayer = false }
        engines.head.attach(headPane.viewer.metalLayer)
        engines.tail.attach(tailPane.viewer.metalLayer)
        headPane.viewer.onResize = { [weak self] in self?.engines.head.redraw() }
        tailPane.viewer.onResize = { [weak self] in self?.engines.tail.redraw() }
        isHidden = true
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// Shows the slipped clip: `timeline` is the drag preview, `headTime` / `tailTime` the clip's first and last frame.
    /// Cheap to call on every drag step: a timeline that did not change is not pushed again, only the seeks run.
    public func show(timeline: Timeline, sequences: [Timeline.ID: Timeline], headTime: Time, tailTime: Time,
                     offsetFrames: Int, settingsFrom program: (any ProgramEngine)? = nil) {
        isHidden = false
        if shown == nil, let program {            // decode like the Program monitor: proxy use, caption kit, quality
            for e in [engines.head, engines.tail] {
                e.proxyUse = program.proxyUse
                e.captionStyleKit = program.captionStyleKit
                e.captionLegacyFont = program.captionLegacyFont
                e.showsCaptions = program.showsCaptions
                e.quality = program.quality
            }
        }
        var changed = false
        if shown == nil || shown!.timeline != timeline || shown!.sequences != sequences {
            shown = (timeline, sequences); changed = true
            engines.head.setTimeline(timeline, sequences: sequences)
            engines.tail.setTimeline(timeline, sequences: sequences)
        }
        let tc = Timecode(frameDuration: timeline.frameDuration, dropFrame: false)
        headPane.set(time: headTime, timecode: tc.format(headTime), engine: engines.head, force: changed)
        tailPane.set(time: tailTime, timecode: tc.format(tailTime), engine: engines.tail, force: changed)
        readout.stringValue = SlipTwoUpLayout.readout(offsetFrames: offsetFrames)
        needsLayout = true
    }

    /// Hides the view and stops both engines from holding the sequence (drag ended or canceled).
    public func hide() {
        isHidden = true
        guard shown != nil else { return }
        shown = nil
        let empty = Timeline(name: "", frameDuration: Time(1, 30))
        engines.head.setTimeline(empty, sequences: [:])
        engines.tail.setTimeline(empty, sequences: [:])
        onRelease?()
    }

    public override func layout() {
        super.layout()
        let f = SlipTwoUpLayout.paneFrames(in: bounds)
        headPane.frame = f.head
        tailPane.frame = f.tail
        let gap = Theme.Spacing.sm
        readout.frame = CGRect(x: gap, y: bounds.height - SlipTwoUpLayout.readoutHeight, width: max(0, bounds.width - gap * 2),
                               height: 18)
    }

    private final class Pane: NSView {
        let viewer = ViewerView(frame: .zero)
        private let title: NSTextField
        private let code = NSTextField(labelWithString: "")
        private var lastTime: Time?

        init(title: String) {
            self.title = NSTextField(labelWithString: title)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.borderWidth = 1
            layer?.cornerRadius = Theme.Radius.overlay
            layer?.borderColor = Theme.Colors.separator.cgColor
            layer?.masksToBounds = true
            viewer.translatesAutoresizingMaskIntoConstraints = true
            addSubview(viewer)
            for l in [self.title, code] {
                l.font = Theme.Typography.body; l.textColor = Theme.Colors.label2
                l.backgroundColor = Theme.Colors.viewerHUD; l.drawsBackground = true
                addSubview(l)
            }
            setAccessibilityLabel(title)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }

        func set(time: Time, timecode: String, engine: any ProgramEngine, force: Bool) {
            code.stringValue = timecode
            if force || time != lastTime { engine.seek(to: time) } else { engine.redraw() }
            lastTime = time
        }

        override func layout() {
            super.layout()
            viewer.frame = bounds
            title.sizeToFit(); code.sizeToFit()
            title.setFrameOrigin(CGPoint(x: Theme.Spacing.inset, y: Theme.Spacing.inset))
            code.setFrameOrigin(CGPoint(x: Theme.Spacing.inset, y: bounds.height - code.frame.height - Theme.Spacing.inset))
        }
    }
}

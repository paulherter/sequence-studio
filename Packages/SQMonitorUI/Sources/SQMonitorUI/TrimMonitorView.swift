import AppKit
import SQCore

/// The two-up Trim monitor (TL-08 / TL-09): last frame before the edit on the left, first frame after it on the right, the
/// -5 -1 +1 +5 buttons and the side switch underneath. Each picture is drawn by its own parked engine; the Program engine
/// is not touched. The host places the view over the Program viewer while `TrimModeModel.isActive`.
@MainActor
public final class TrimMonitorView: NSView {
    private let model: TrimModeModel
    private let session: EditorSession
    private let engines: (before: any ProgramEngine, after: any ProgramEngine)
    private let beforePane = Pane(title: "Before the edit")
    private let afterPane = Pane(title: "After the edit")
    private let stepButtons: [SQButton]
    private let sideSwitch = SQSegmented(labels: ["Before", "After", "Both"], segmentWidth: 58)
    private let noteLabel = NSTextField(labelWithString: "")
    private let doneButton: SQButton
    private let controlsHeight: CGFloat = 52
    private var shown: (timeline: Timeline, sequences: [Timeline.ID: Timeline])?

    /// The user closed the view (Done button).
    public var onDone: (() -> Void)?
    /// Both engines let go of the sequence (mode closed): the host frees their frame cache.
    public var onRelease: (() -> Void)?

    public init(model: TrimModeModel, session: EditorSession,
                beforeEngine: any ProgramEngine, afterEngine: any ProgramEngine) {
        self.model = model
        self.session = session
        engines = (beforeEngine, afterEngine)
        stepButtons = TrimModeModel.steps.map { n in
            SQButton(title: n > 0 ? "+\(n)" : "\(n)", target: nil, action: nil)
        }
        doneButton = SQButton(title: "Done", target: nil, action: nil, style: .standard)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.monitorBackdrop.cgColor
        setAccessibilityLabel("Trim monitor")
        for pane in [beforePane, afterPane] { addSubview(pane) }
        for (b, n) in zip(stepButtons, TrimModeModel.steps) {
            b.tag = n
            b.target = self; b.action = #selector(stepPressed(_:))
            b.setAccessibilityLabel(n < 0 ? "Trim \(-n) frame\(n == -1 ? "" : "s") earlier" : "Trim \(n) frame\(n == 1 ? "" : "s") later")
            addSubview(b)
        }
        sideSwitch.target = self; sideSwitch.action = #selector(sideChanged)
        sideSwitch.setAccessibilityLabel("Trim side")
        addSubview(sideSwitch)
        noteLabel.font = Theme.Typography.body
        noteLabel.textColor = Theme.Colors.label2
        noteLabel.lineBreakMode = .byTruncatingTail
        addSubview(noteLabel)
        doneButton.target = self; doneButton.action = #selector(donePressed)
        addSubview(doneButton)
        for p in [beforePane, afterPane] { p.viewer.drivesLayer = false }
        engines.before.attach(beforePane.viewer.metalLayer)
        engines.after.attach(afterPane.viewer.metalLayer)
        beforePane.viewer.onResize = { [weak self] in self?.engines.before.redraw() }
        afterPane.viewer.onResize = { [weak self] in self?.engines.after.redraw() }
        isHidden = true
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// Re-reads the model: pushes the current sequence to both engines, parks them on the two frames, updates the controls.
    public func refresh() {
        isHidden = !model.isActive
        if !model.isActive { release(); return }
        guard let snap = session.pushedSnapshot, let tl = session.activeTimeline else { return }
        var changed = false
        if shown == nil || shown!.timeline != snap.timeline || shown!.sequences != snap.sequences {
            if shown == nil { syncSettings() }
            shown = snap; changed = true
            engines.before.setTimeline(snap.timeline, sequences: snap.sequences)
            engines.after.setTimeline(snap.timeline, sequences: snap.sequences)
        }
        let fr = model.frames
        let tc = Timecode(frameDuration: tl.frameDuration, dropFrame: false)
        beforePane.set(time: fr.outgoing, timecode: fr.outgoing.map(tc.format), engine: engines.before, force: changed)
        afterPane.set(time: fr.incoming, timecode: fr.incoming.map(tc.format), engine: engines.after, force: changed)
        beforePane.active = model.side == .outgoing || model.side == .roll
        afterPane.active = model.side == .incoming || model.side == .roll
        if let p = model.point {
            for (i, s) in [TrimSide.outgoing, .incoming, .roll].enumerated() { sideSwitch.setEnabled(p.supports(s), forSegment: i) }
        }
        sideSwitch.selectedSegment = [TrimSide.outgoing, .incoming, .roll].firstIndex(of: model.side) ?? 2
        noteLabel.stringValue = model.note
        needsLayout = true
    }

    /// Stops both engines from holding the sequence (Trim mode closed).
    public func release() {
        guard shown != nil else { return }
        shown = nil
        let empty = Timeline(name: "", frameDuration: session.activeTimeline?.frameDuration ?? Time(1, 30))
        engines.before.setTimeline(empty, sequences: [:])
        engines.after.setTimeline(empty, sequences: [:])
        onRelease?()
    }

    /// The monitors decode like the Program monitor: same proxy use, caption style kit and quality.
    private func syncSettings() {
        let src = session.engine
        for e in [engines.before, engines.after] {
            e.proxyUse = src.proxyUse
            e.captionStyleKit = src.captionStyleKit
            e.captionLegacyFont = src.captionLegacyFont
            e.showsCaptions = src.showsCaptions
            e.quality = src.quality
        }
    }

    @objc private func stepPressed(_ sender: SQButton) { model.step(frames: sender.tag) }
    @objc private func sideChanged() {
        model.select([TrimSide.outgoing, .incoming, .roll][max(0, min(2, sideSwitch.selectedSegment))])
    }
    @objc private func donePressed() { model.exit(); onDone?() }

    public override func layout() {
        super.layout()
        let gap = Theme.Spacing.sm
        let h = max(0, bounds.height - controlsHeight)
        let w = (bounds.width - gap * 3) / 2
        beforePane.frame = CGRect(x: gap, y: gap, width: max(0, w), height: max(0, h - gap))
        afterPane.frame = CGRect(x: gap * 2 + w, y: gap, width: max(0, w), height: max(0, h - gap))
        // Controls: -5 -1 +1 +5 centered, side switch left, note and Done right.
        let bw: CGFloat = 40, bh = Theme.Metrics.quietButton
        let y = h + (controlsHeight - bh) / 2
        let rowW = CGFloat(stepButtons.count) * bw + CGFloat(stepButtons.count - 1) * Theme.Spacing.xs
        var x = (bounds.width - rowW) / 2
        for b in stepButtons { b.frame = CGRect(x: x, y: y, width: bw, height: bh); x += bw + Theme.Spacing.xs }
        let sw = sideSwitch.intrinsicContentSize
        sideSwitch.frame = CGRect(x: gap, y: h + (controlsHeight - sw.height) / 2, width: sw.width, height: sw.height)
        let dw = doneButton.intrinsicContentSize.width
        doneButton.frame = CGRect(x: bounds.width - gap - dw, y: y, width: dw, height: bh)
        let nx = (bounds.width + rowW) / 2 + gap
        noteLabel.frame = CGRect(x: nx, y: y + 2, width: max(0, doneButton.frame.minX - nx - gap), height: 16)
    }

    /// One picture with its caption and timecode; the side being trimmed gets an accent frame.
    private final class Pane: NSView {
        let viewer = ViewerView(frame: .zero)
        private let title: NSTextField
        private let code = NSTextField(labelWithString: "")
        private var lastTime: Time?
        var active = false { didSet { layer?.borderColor = (active ? Theme.Colors.accent : Theme.Colors.separator).cgColor } }

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

        func set(time: Time?, timecode: String?, engine: any ProgramEngine, force: Bool) {
            code.stringValue = timecode ?? "No clip"
            viewer.isHidden = time == nil
            if let time, force || time != lastTime { engine.seek(to: time) } else if time != nil { engine.redraw() }
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

import AppKit
import Observation
import SSCore

/// Program/Source monitor panel: viewer slot on #0C0C0C, timecode row, Fit + quality popups, transport.
/// Callbacks only (see `MonitorPanelModel`); the host inserts its viewer into `viewerSlot`.
@MainActor
public final class MonitorPanelView: NSView, NSTextFieldDelegate, NSMenuDelegate {
    public let model: MonitorPanelModel
    /// Host inserts the viewer (Metal) view here; it should fill the slot.
    public let viewerSlot = NSView()

    private let timecodeField = TimecodeField(string: "")
    private let optionsPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    /// Safe-margin guides over the picture; `rectProvider` returns the picture's rect in the viewer slot.
    public let safeMarginsView = SafeMarginsView()
    private let durationLabel = NSTextField(labelWithString: "")
    private let inOutLabel = NSTextField(labelWithString: "")
    private let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let transport = NSStackView()
    private var buttons: [MonitorAction: NSButton] = [:]
    private let header = NSStackView()
    private let footer = NSView()
    private lazy var scrubBar = MonitorScrubBar(model: model)

    public init(model: MonitorPanelModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        build()
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static let symbols: [MonitorAction: (String, String)] = [
        .markIn: ("arrow.down.to.line.compact", "Mark In"),
        .markOut: ("arrow.up.to.line.compact", "Mark Out"),
        .goToIn: ("chevron.left.to.line", "Go to In"),
        .goToOut: ("chevron.right.to.line", "Go to Out"),
        .stepBack: ("backward.frame.fill", "Step Back"),
        .stepForward: ("forward.frame.fill", "Step Forward"),
        .playPause: ("play.fill", "Play"),
        .addMarker: ("mappin", "Add Marker"),
        .insert: ("arrow.down.right.square", "Insert"),
        .overwrite: ("square.and.arrow.down.on.square", "Overwrite"),
        .lift: ("arrow.up.to.line", "Lift"),
        .extract: ("arrow.up.to.line.compact", "Extract"),
        .exportFrame: ("camera", "Export Frame"),
    ]
    private static let tips: [MonitorAction: String] = [
        .markIn: "Mark In (I)", .markOut: "Mark Out (O)", .goToIn: "Go to In (Shift+I)", .goToOut: "Go to Out (Shift+O)",
        .stepBack: "Step Back (Left)", .stepForward: "Step Forward (Right)", .playPause: "Play/Stop (Space)",
        .addMarker: "Add Marker (M)", .insert: "Insert (,)", .overwrite: "Overwrite (.)",
        .lift: "Lift (;)", .extract: "Extract (')", .exportFrame: "Export Frame (Cmd+Shift+E)",
    ]

    private func build() {
        viewerSlot.wantsLayer = true
        viewerSlot.layer?.backgroundColor = Theme.Colors.viewer.cgColor
        viewerSlot.translatesAutoresizingMaskIntoConstraints = false
        let ctx = NSMenu(); ctx.delegate = self; viewerSlot.menu = ctx
        safeMarginsView.frame = viewerSlot.bounds
        safeMarginsView.autoresizingMask = [.width, .height]
        safeMarginsView.isHidden = true
        viewerSlot.addSubview(safeMarginsView)
        if model.mode == .source {
            let drag = StreamDragView(streams: .both)
            drag.model = model
            drag.frame = viewerSlot.bounds
            drag.autoresizingMask = [.width, .height]
            viewerSlot.addSubview(drag, positioned: .below, relativeTo: safeMarginsView)
        }

        // Timecode: 18 light, click to type.
        timecodeField.font = Theme.Fonts.timecode
        timecodeField.textColor = Theme.Colors.label
        timecodeField.isBordered = false
        timecodeField.drawsBackground = false
        timecodeField.focusRingType = .none
        timecodeField.isEditable = true
        timecodeField.isSelectable = true
        timecodeField.delegate = self
        timecodeField.target = self
        timecodeField.action = #selector(commitTimecode)
        timecodeField.setAccessibilityLabel("Timecode")
        timecodeField.setContentHuggingPriority(.required, for: .horizontal)

        for l in [durationLabel, inOutLabel] {
            l.font = Theme.Fonts.small
            l.textColor = Theme.Colors.label2
        }
        durationLabel.setAccessibilityLabel("Duration")
        inOutLabel.setAccessibilityLabel("In to Out duration")

        zoomPopup.addItems(withTitles: MonitorZoom.presets.map(\.title))
        zoomPopup.target = self; zoomPopup.action = #selector(zoomChanged)
        zoomPopup.controlSize = .small
        zoomPopup.font = Theme.Fonts.small
        zoomPopup.setAccessibilityLabel("Zoom")
        qualityPopup.addItems(withTitles: MonitorQuality.allCases.map(\.title))
        qualityPopup.target = self; qualityPopup.action = #selector(qualityChanged)
        qualityPopup.controlSize = .small
        qualityPopup.font = Theme.Fonts.small
        qualityPopup.setAccessibilityLabel("Playback quality")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.orientation = .horizontal
        header.spacing = Theme.Spacing.sm
        header.edgeInsets = NSEdgeInsets(top: 0, left: Theme.Spacing.md, bottom: 0, right: Theme.Spacing.md)
        optionsPopup.controlSize = .small
        optionsPopup.isBordered = false
        optionsPopup.addItem(withTitle: "")
        optionsPopup.item(at: 0)?.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Settings")
        optionsPopup.setAccessibilityLabel("Monitor settings")
        optionsPopup.toolTip = "Monitor settings"
        optionsPopup.menu?.delegate = self
        timecodeField.onDrag = { [weak self] phase, frames in self?.timecodeDrag(phase, frames) }
        timecodeField.toolTip = "Click to type a timecode, drag to scrub"
        for v in [timecodeField, durationLabel, spacer, optionsPopup, zoomPopup, qualityPopup] { header.addArrangedSubview(v) }
        header.translatesAutoresizingMaskIntoConstraints = false

        transport.orientation = .horizontal
        transport.spacing = Theme.Spacing.xs
        transport.translatesAutoresizingMaskIntoConstraints = false
        for a in MonitorAction.buttonBar(for: model.mode) {
            let (symbol, title) = Self.symbols[a]!
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
                             target: self, action: #selector(transportPressed(_:)))
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.contentTintColor = Theme.Colors.label
            b.toolTip = Self.tips[a] ?? title
            b.setAccessibilityLabel(title)
            b.tag = MonitorAction.allCases.firstIndex(of: a)!
            buttons[a] = b
            transport.addArrangedSubview(b)
        }
        inOutLabel.translatesAutoresizingMaskIntoConstraints = false

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(transport)
        if model.mode == .source {
            let video = StreamDragView(streams: .videoOnly), audio = StreamDragView(streams: .audioOnly)
            for (v, symbol, tip) in [(video, "film", "Drag Video Only"), (audio, "waveform", "Drag Audio Only")] {
                v.model = model
                v.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
                v.toolTip = tip
                v.setAccessibilityLabel(tip)
            }
            let box = NSStackView(views: [video, audio])
            box.spacing = Theme.Spacing.xs
            box.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(box)
            NSLayoutConstraint.activate([
                box.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Theme.Spacing.md),
                box.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            ])
        }
        footer.addSubview(inOutLabel)

        scrubBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header); addSubview(viewerSlot); addSubview(scrubBar); addSubview(footer)
        let bar = Theme.Metrics.panelHeader
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: bar + 6),
            viewerSlot.topAnchor.constraint(equalTo: header.bottomAnchor),
            viewerSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewerSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewerSlot.bottomAnchor.constraint(equalTo: scrubBar.topAnchor),
            scrubBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrubBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrubBar.bottomAnchor.constraint(equalTo: footer.topAnchor),
            scrubBar.heightAnchor.constraint(equalToConstant: 14),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: bar + 4),
            transport.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            transport.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            inOutLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Theme.Spacing.md),
            inOutLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    /// Re-reads the model and re-arms observation. Call once; it keeps itself updated.
    private func refresh() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func apply() {
        if timecodeField.currentEditor() == nil { timecodeField.stringValue = model.timecodeText }
        durationLabel.stringValue = "/ " + model.durationText
        inOutLabel.stringValue = model.inOutDurationText.map { "In/Out  " + $0 } ?? ""
        if let i = MonitorZoom.presets.firstIndex(of: model.zoom) {
            while zoomPopup.numberOfItems > MonitorZoom.presets.count { zoomPopup.removeItem(at: zoomPopup.numberOfItems - 1) }
            zoomPopup.selectItem(at: i)
        } else {   // a gesture zoom: one extra item shows the current percentage
            while zoomPopup.numberOfItems > MonitorZoom.presets.count { zoomPopup.removeItem(at: zoomPopup.numberOfItems - 1) }
            zoomPopup.addItem(withTitle: model.zoom.title)
            zoomPopup.selectItem(at: zoomPopup.numberOfItems - 1)
        }
        qualityPopup.selectItem(at: MonitorQuality.allCases.firstIndex(of: model.quality) ?? 0)
        scrubBar.needsDisplay = true
        safeMarginsView.isHidden = !model.safeMargins
        safeMarginsView.needsDisplay = true
        let available = Set(model.availableActions)
        for (a, b) in buttons {
            b.isHidden = !available.contains(a)
            b.isEnabled = true
        }
        if let play = buttons[.playPause] {
            let name = model.isPlaying ? "pause.fill" : "play.fill"
            let title = model.isPlaying ? "Pause" : "Play"
            play.image = NSImage(systemSymbolName: name, accessibilityDescription: title)
            play.toolTip = title
            play.setAccessibilityLabel(title)
        }
    }

    @objc private func transportPressed(_ sender: NSButton) {
        model.perform(MonitorAction.allCases[sender.tag])
    }

    @objc private func zoomChanged() {
        guard MonitorZoom.presets.indices.contains(zoomPopup.indexOfSelectedItem) else { return }
        model.setZoom(MonitorZoom.presets[zoomPopup.indexOfSelectedItem])
    }
    @objc private func qualityChanged() { model.setQuality(MonitorQuality.allCases[qualityPopup.indexOfSelectedItem]) }

    private var dragStartTime = Time.zero
    private func timecodeDrag(_ phase: TimecodeField.Phase, _ frames: Int) {
        switch phase {
        case .began:
            dragStartTime = model.currentTime
            model.onScrubBegan?()
        case .changed:
            let t = model.time(offsetFrom: dragStartTime, frames: frames)
            if let s = model.onScrub { s(t) } else { model.onSeek?(t) }
        case .ended: model.onScrubEnded?()
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === optionsPopup.menu {
            menu.removeAllItems()
            let head = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
            head.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Settings")
            addToggle(menu, "Loop Playback", .loop, on: model.isLooping)
            if model.mode == .program { addToggle(menu, "Play In to Out", .playInToOut, on: nil) }
            if model.mode == .program { addToggle(menu, "Safe Margins", .toggleSafeMargins, on: model.safeMargins) }
        } else if menu === viewerSlot.menu {
            menu.removeAllItems()
            model.contextMenuBuilder?(menu)
        }
    }

    private func addToggle(_ menu: NSMenu, _ title: String, _ a: MonitorAction, on: Bool?) {
        let it = menu.addItem(withTitle: title, action: #selector(optionPicked(_:)), keyEquivalent: "")
        it.target = self
        it.tag = MonitorAction.allCases.firstIndex(of: a)!
        if let on { it.state = on ? .on : .off }
    }

    @objc private func optionPicked(_ sender: NSMenuItem) { model.perform(MonitorAction.allCases[sender.tag]) }

    @objc private func commitTimecode() {
        if !model.commitTimecodeText(timecodeField.stringValue) { NSSound.beep() }
        timecodeField.stringValue = model.timecodeText
        window?.makeFirstResponder(nil)
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        timecodeField.stringValue = model.timecodeText
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            timecodeField.stringValue = model.timecodeText
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

/// Timecode readout: click to type, drag sideways to scrub (2 pt per frame).
@MainActor
final class TimecodeField: NSTextField {
    enum Phase { case began, changed, ended }
    var onDrag: ((Phase, Int) -> Void)?

    override func resetCursorRects() {
        if currentEditor() == nil { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    override func mouseDown(with event: NSEvent) {
        guard currentEditor() == nil, let window else { super.mouseDown(with: event); return }
        let startX = event.locationInWindow.x
        var dragging = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let dx = e.locationInWindow.x - startX
            if e.type == .leftMouseUp {
                if dragging { onDrag?(.ended, 0) } else { selectText(nil) }
                return
            }
            if !dragging, abs(dx) > 3 { dragging = true; onDrag?(.began, 0) }
            if dragging { onDrag?(.changed, Int((dx / 2).rounded())) }
        }
    }
}

/// Action-safe (90 %) and title-safe (80 %) guides and the centre cross over the picture.
@MainActor
public final class SafeMarginsView: NSView {
    /// Rect of the picture in this view's coordinates.
    public var rectProvider: (() -> CGRect)?
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        guard let r = rectProvider?(), r.width > 4 else { return }
        NSColor.white.withAlphaComponent(0.55).setStroke()
        for k in [0.9, 0.8] {
            let w = r.width * k, h = r.height * k
            let p = NSBezierPath(rect: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
            p.lineWidth = 1
            p.stroke()
        }
        let c = NSBezierPath()
        c.move(to: CGPoint(x: r.midX - 8, y: r.midY)); c.line(to: CGPoint(x: r.midX + 8, y: r.midY))
        c.move(to: CGPoint(x: r.midX, y: r.midY - 8)); c.line(to: CGPoint(x: r.midX, y: r.midY + 8))
        c.lineWidth = 1
        c.stroke()
    }
}

/// Source Monitor drag source: the picture itself (both streams) or the film / waveform icon (one stream).
@MainActor
final class StreamDragView: NSView, NSDraggingSource {
    let streams: SourceStreams
    weak var model: MonitorPanelModel?
    var image: NSImage? { didSet { needsDisplay = true } }
    private var downPoint: CGPoint?

    init(streams: SourceStreams) {
        self.streams = streams
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 18))
        setContentHuggingPriority(.required, for: .horizontal)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { image == nil ? super.intrinsicContentSize : NSSize(width: 22, height: 18) }
    override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) ?? superview?.menu }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let cfg = image.withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? image
        let s = cfg.size
        let r = NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        let tinted = NSImage(size: cfg.size)
        tinted.lockFocus()
        cfg.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        Theme.Colors.label2.set()
        NSRect(origin: .zero, size: cfg.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: r)
    }

    override func mouseDown(with event: NSEvent) { downPoint = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downPoint, let item = model?.dragItem?(streams) else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - down.x, p.y - down.y) > 4 else { return }
        downPoint = nil
        let symbol = streams == .audioOnly ? "waveform" : streams == .videoOnly ? "film" : "film.stack"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular)) ?? NSImage()
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(NSRect(x: p.x - img.size.width / 2, y: p.y - img.size.height / 2, width: img.size.width, height: img.size.height),
                              contents: img)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { model?.onDragEnded?() }
    }
}

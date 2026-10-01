import AppKit
import Observation
import SSCore

/// Program/Source monitor panel: viewer slot on #0C0C0C, timecode row, Fit + quality popups, transport.
/// Callbacks only (see `MonitorPanelModel`); the host inserts its viewer into `viewerSlot`.
@MainActor
public final class MonitorPanelView: NSView, NSTextFieldDelegate {
    public let model: MonitorPanelModel
    /// Host inserts the viewer (Metal) view here; it should fill the slot.
    public let viewerSlot = NSView()

    private let timecodeField = NSTextField(string: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let inOutLabel = NSTextField(labelWithString: "")
    private let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let transport = NSStackView()
    private var buttons: [MonitorAction: NSButton] = [:]
    private let header = NSStackView()
    private let footer = NSView()

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
    ]

    private func build() {
        viewerSlot.wantsLayer = true
        viewerSlot.layer?.backgroundColor = Theme.Colors.viewer.cgColor
        viewerSlot.translatesAutoresizingMaskIntoConstraints = false

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
        for v in [timecodeField, durationLabel, spacer, zoomPopup, qualityPopup] { header.addArrangedSubview(v) }
        header.translatesAutoresizingMaskIntoConstraints = false

        transport.orientation = .horizontal
        transport.spacing = Theme.Spacing.xs
        transport.translatesAutoresizingMaskIntoConstraints = false
        let order: [MonitorAction] = [.markIn, .markOut, .goToIn, .stepBack, .playPause, .stepForward, .goToOut,
                                      .addMarker, .insert, .overwrite]
        for a in order {
            let (symbol, title) = Self.symbols[a]!
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
                             target: self, action: #selector(transportPressed(_:)))
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.contentTintColor = Theme.Colors.label
            b.toolTip = title
            b.setAccessibilityLabel(title)
            b.tag = MonitorAction.allCases.firstIndex(of: a)!
            buttons[a] = b
            transport.addArrangedSubview(b)
        }
        inOutLabel.translatesAutoresizingMaskIntoConstraints = false

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(transport)
        footer.addSubview(inOutLabel)

        addSubview(header); addSubview(viewerSlot); addSubview(footer)
        let bar = Theme.Metrics.panelHeader
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: bar + 6),
            viewerSlot.topAnchor.constraint(equalTo: header.bottomAnchor),
            viewerSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewerSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewerSlot.bottomAnchor.constraint(equalTo: footer.topAnchor),
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

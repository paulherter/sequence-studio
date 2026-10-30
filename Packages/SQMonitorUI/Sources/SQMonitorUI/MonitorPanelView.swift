import AppKit
import Observation
import SQCore
import SQPlayback
import SQUIKit

/// Program/Source monitor panel (v9 `.monitor`): header tools at the right (content popup, "Fit", "Full", then the host's "⋯"),
/// picture with 12 pt padding and the size badge top left, then the 66 pt footer: scrub bar and one row (timecode, transport,
/// duration). Zoom and quality are two flat popups (and in the ⋯ menu).
/// Callbacks only (see `MonitorPanelModel`); the host inserts its viewer into `viewerSlot`.
@MainActor
public final class MonitorPanelView: NSView, NSTextFieldDelegate {
    public let model: MonitorPanelModel
    /// Host inserts the viewer (Metal) view here; it should fill the slot.
    public let viewerSlot = MonitorViewerSlot()

    private let hudLabel = NSTextField(labelWithString: "")
    private let sourcePopup = SQMenuPopup()
    /// Program monitor: format variant switcher (W5.1).
    private let formatPopup = SQMenuPopup()
    /// What the popups were last built from: `apply()` runs on every playhead tick, the menus are rebuilt only on change.
    private var builtSource: (items: [MonitorPanelModel.SourceItem], current: UUID?)?
    private var builtSequences: (name: String, items: [MonitorPanelModel.SequenceItem], current: UUID?)?
    private let timecodeField = TimecodeField(string: "")
    /// The one wrench menu: playback options plus the rest of the transport actions (markers, go to In/Out, edit, export frame).
    private let optionsPopup = SQMenuPopup()
    /// Safe-margin guides over the picture; `rectProvider` returns the picture's rect in the viewer slot.
    public let safeMarginsView = SafeMarginsView()
    private let durationLabel = NSTextField(labelWithString: "")
    private let inOutIcon = NSImageView()
    /// The picture area (surface #0c0c0c): the viewer slot sits in it with 10 pt above and below; badge, HUD and dots on top.
    private let pic = PictureAreaView()
    private let footerRight = NSStackView()
    /// Program monitor with no sequence open (Overlays board).
    private let programEmpty = ProgramEmptyView()
    /// Zoom popup and, right of it, its own Playback quality popup (changed often, so not inside the zoom menu).
    private let badge = NSStackView()
    /// Header popups, same capsule as the content popup (design B `.pop` in `.ph`: 22 high, fill, chevron): "Fit", "Full", and
    /// (Program) the platform safe zone.
    private let zoomBadge = SQMenuPopup()
    private let qualityBadge = SQMenuPopup()
    private let zoneBadge = SQMenuPopup()
    private let transport = NSStackView()
    private var buttons: [MonitorAction: SQButton] = [:]
    /// Source footer: Insert and Overwrite at the right of the row (the first things the narrow footer drops).
    private var editButtons: [SQButton] = []
    private let header = NSStackView()
    private var headerHeight: NSLayoutConstraint!
    /// Nothing sits after the tabs any more (v9): the content popup is the first of the header tools (`headerBadge`).
    public var headerAccessory: NSView? { nil }
    /// The header tools (content popup, safe zone while one is on, "Fit", "Full"), for a host that shows them in the tab
    /// strip at the right, next to "...".
    public var headerBadge: NSView { badge }
    private var contentPopup: SQMenuPopup { model.mode == .source ? sourcePopup : formatPopup }
    /// False where the host already shows a "..." for this monitor (Color page viewer header): the row's own one hides.
    public var showsOptionsButton = true { didSet { optionsPopup.isHidden = !showsOptionsButton } }
    /// True while the host shows the popup in its tab strip: the panel's own 30 pt header row collapses.
    public var hostsHeaderInStrip = false {
        didSet {
            guard oldValue != hostsHeaderInStrip else { return }
            updateHeaderRow()
            if !hostsHeaderInStrip, !badgeOnPicture, badge.superview !== header {      // back from a strip: into the row, after the spacer
                badge.removeFromSuperview()
                badge.translatesAutoresizingMaskIntoConstraints = false
                header.insertArrangedSubview(badge, at: min(1, header.arrangedSubviews.count))
            }
        }
    }
    /// Color page (board `.vbadge`): the monitor has no header row; the Fit and quality popups sit on the picture, top right,
    /// and the sequence format label and the format popup are not shown.
    public var badgeOnPicture = false {
        didSet {
            guard oldValue != badgeOnPicture else { return }
            updateHeaderRow()
            formatPopup.isHidden = badgeOnPicture
            // On the picture the zoom and quality popups merge into one pill ("Fit · 1/2", board `.vbadge`): one menu with
            // both choices, 20 pt high, caption font.
            qualityBadge.isHidden = badgeOnPicture
            zoomBadge.boxHeight = badgeOnPicture ? Self.pictureBadgeHeight : Theme.Row.controlLarge
            zoomBadge.font = badgeOnPicture ? Theme.Typography.caption : Theme.Typography.body
            zoomBadge.isFlat = !badgeOnPicture
            zoomBadge.itemsProvider = { [weak self] in
                guard let self else { return [] }
                return self.badgeOnPicture ? self.model.zoomMenu() + [.separator] + self.model.qualityMenu() : self.model.zoomMenu()
            }
            if badgeOnPicture {
                badge.removeFromSuperview()
                // The tab strip hosted it with autoresizing on; on the picture it is placed by constraints.
                badge.translatesAutoresizingMaskIntoConstraints = false
                pic.addSubview(badge)
                NSLayoutConstraint.activate([
                    badge.topAnchor.constraint(equalTo: pic.topAnchor, constant: Theme.Spacing.sm),
                    badge.trailingAnchor.constraint(equalTo: pic.trailingAnchor, constant: -Theme.Spacing.sm),
                ])
            } else {
                badge.removeFromSuperview()
                header.insertArrangedSubview(badge, at: min(1, header.arrangedSubviews.count))
            }
            apply()
        }
    }
    static let pictureBadgeHeight: CGFloat = 20
    /// Titles of the zoom popup's menu (tests).
    var headerBadgeItemsForTesting: [String] { (zoomBadge.itemsProvider?() ?? []).map(\.title) }
    /// The merged pill on the picture: "Fit · ½" (board `.vbadge`), fractions as one glyph.
    static func pictureBadgeTitle(zoom: String, quality: String) -> String {
        let q = ["1/2": "½", "1/4": "¼", "1/8": "⅛"][quality] ?? quality
        return "\(zoom) · \(q)"
    }
    /// The 30 pt header row shows only when neither a tab strip nor the picture hosts its popups.
    private func updateHeaderRow() {
        let hidden = hostsHeaderInStrip || badgeOnPicture
        header.isHidden = hidden
        headerHeight.constant = hidden ? 0 : Theme.Metrics.panelHeader
    }
    private let footer = NSView()
    private lazy var scrubBar = MonitorScrubBar(model: model)
    /// Source monitor: the viewer of audio-only media (shown instead of the picture).
    public lazy var waveformView = SourceWaveformView(model: model)
    /// Source monitor: all angles side by side (`model.angleTiles`), over the viewer.
    public lazy var anglesGrid = AnglesGridView(model: model)
    public var isShowingWaveform: Bool { model.mode == .source && model.viewerMode == .waveform && !waveformView.isHidden }
    /// Program monitor: the dropped-frame dot.
    private let dropDot = DropDotView()
    /// "Media offline" card over the picture and the resolution badge at its bottom-right corner.
    private let offlineCard = NSView()
    private let offlineTitle = NSTextField(labelWithString: "")
    private let offlineDetail = NSTextField(labelWithString: "")
    private let resolutionLabel = NSTextField(labelWithString: "")
    /// Program loudness readout (bottom left of the picture); the host sets the providers on the Program monitor only.
    private let loudnessLabel = NSTextField(labelWithString: "")
    public var loudnessProvider: (() -> LoudnessReading?)? { didSet { updateLoudnessReadout() } }
    public var loudnessTargetProvider: (() -> LoudnessTarget)?
    private var loudnessTimer: Timer?

    public init(model: MonitorPanelModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        build()
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Footer (v9 `.mtr`): 8 padding, 16 scrub bar, 6 gap, 28 row, 8 padding.
    private static let footerHeight: CGFloat = Theme.Metrics.monitorFooter
    /// v9 `.mtrow .tcd` / `.dur`: 92 wide.
    private static let timecodeWidth: CGFloat = 92
    /// Space around the picture (v9 `.view` padding 12).
    private static let pictureMargin: CGFloat = Theme.Spacing.md
    /// Transport row: 28 high (the Play button), small buttons 24 with a 12 pt glyph, Play with a 16 pt glyph.
    private static let rowHeight: CGFloat = 28
    private static let smallGlyph: CGFloat = 12
    private static let playGlyph: CGFloat = 16
    private static let symbols: [MonitorAction: (SQIcon, String)] = [
        .markIn: (.markIn, "Mark In"),
        .markOut: (.markOut, "Mark Out"),
        .goToIn: (.goToStart, "Go to In"),
        .goToOut: (.goToEnd, "Go to Out"),
        .stepBack: (.stepBack, "Step Back"),
        .stepForward: (.stepForward, "Step Forward"),
        .playPause: (.play, "Play"),
        .addMarker: (.marker, "Add Marker"),
        .insert: (.insertEdit, "Insert"),
        .overwrite: (.overwriteEdit, "Overwrite"),
        .lift: (.arrowUpFromLine, "Clear Range"),
        .extract: (.arrowUpToLine, "Delete Range"),
        .exportFrame: (.camera, "Export Frame"),
    ]
    /// Source monitor with no clip: says how to load one (INTERACTION-AUDIT section 10).
    private let sourceEmpty = EmptyStateView(title: "No clip in Source", hint: "Double-click a clip in the Project panel, or drag it here")

    /// The viewer slot's four edge constraints; their constant is `pictureMargin` at Fit and 0 once the picture is zoomed.
    private var slotEdges: [NSLayoutConstraint] = []

    /// Space between the pic area and the viewer: 12 pt at Fit (v9 `.view` padding), none when zoomed, so the picture runs
    /// out to the edge of the area and is not cut 12 pt inside it (the cut left four bands around the picture).
    static func viewerMargin(for zoom: MonitorZoom) -> CGFloat {
        if case .fit = zoom { return pictureMargin }
        return 0
    }

    private func applyViewerMargin() {
        let m = Self.viewerMargin(for: model.zoom)
        guard slotEdges.count == 4, pic.viewerMargin != m else { return }
        pic.viewerMargin = m
        slotEdges[0].constant = m; slotEdges[2].constant = m; slotEdges[3].constant = -m
        pic.viewerBottom?.constant = -m
        pic.needsLayout = true
    }

    private func build() {
        viewerSlot.wantsLayer = true
        viewerSlot.layer?.backgroundColor = Theme.Colors.monitorBackdrop.cgColor
        viewerSlot.translatesAutoresizingMaskIntoConstraints = false
        viewerSlot.itemsProvider = { [weak self] in self?.model.contextMenuBuilder?() ?? [] }
        safeMarginsView.frame = viewerSlot.bounds
        safeMarginsView.autoresizingMask = [.width, .height]
        safeMarginsView.isHidden = true
        safeMarginsView.onGuidesChange = { [weak self] g in self?.model.guides = g }
        viewerSlot.addSubview(safeMarginsView)
        if model.mode == .source {
            sourceEmpty.frame = viewerSlot.bounds
            sourceEmpty.autoresizingMask = [.width, .height]
            viewerSlot.addSubview(sourceEmpty, positioned: .below, relativeTo: safeMarginsView)
        }
        hudLabel.font = Theme.Typography.caption
        hudLabel.textColor = Theme.Colors.label2
        hudLabel.backgroundColor = Theme.Colors.viewerHUD
        hudLabel.drawsBackground = true
        hudLabel.isHidden = true
        hudLabel.setAccessibilityLabel("Scrub latency")
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        pic.wantsLayer = true
        pic.layer?.backgroundColor = Theme.Colors.monitorBackdrop.cgColor
        pic.translatesAutoresizingMaskIntoConstraints = false
        pic.addSubview(viewerSlot)
        let viewerBottom = viewerSlot.bottomAnchor.constraint(equalTo: pic.bottomAnchor, constant: -Self.pictureMargin)
        pic.viewerBottom = viewerBottom
        pic.viewerMargin = Self.pictureMargin
        slotEdges = [viewerSlot.topAnchor.constraint(equalTo: pic.topAnchor, constant: Self.pictureMargin),
                     viewerBottom,
                     viewerSlot.leadingAnchor.constraint(equalTo: pic.leadingAnchor, constant: Self.pictureMargin),
                     viewerSlot.trailingAnchor.constraint(equalTo: pic.trailingAnchor, constant: -Self.pictureMargin)]
        NSLayoutConstraint.activate(slotEdges)
        pic.addSubview(hudLabel)
        NSLayoutConstraint.activate([
            hudLabel.leadingAnchor.constraint(equalTo: pic.leadingAnchor, constant: Theme.Spacing.inset),
            hudLabel.topAnchor.constraint(equalTo: pic.topAnchor, constant: Theme.Spacing.inset),
        ])
        if model.mode == .program {
            programEmpty.onNew = { [weak self] in self?.model.onNewSequence?() }
            programEmpty.translatesAutoresizingMaskIntoConstraints = false
            pic.addSubview(programEmpty)
            NSLayoutConstraint.activate([
                programEmpty.topAnchor.constraint(equalTo: pic.topAnchor),
                programEmpty.bottomAnchor.constraint(equalTo: pic.bottomAnchor),
                programEmpty.leadingAnchor.constraint(equalTo: pic.leadingAnchor),
                programEmpty.trailingAnchor.constraint(equalTo: pic.trailingAnchor),
            ])
        }
        if model.mode == .source {
            let drag = StreamDragView(streams: .both)
            drag.model = model
            drag.frame = viewerSlot.bounds
            drag.autoresizingMask = [.width, .height]
            viewerSlot.addSubview(drag, positioned: .below, relativeTo: safeMarginsView)
            waveformView.frame = viewerSlot.bounds
            waveformView.autoresizingMask = [.width, .height]
            waveformView.isHidden = true
            viewerSlot.addSubview(waveformView, positioned: .below, relativeTo: safeMarginsView)
            anglesGrid.frame = viewerSlot.bounds
            anglesGrid.autoresizingMask = [.width, .height]
            anglesGrid.isHidden = true
            viewerSlot.addSubview(anglesGrid, positioned: .below, relativeTo: safeMarginsView)
        }
        dropDot.translatesAutoresizingMaskIntoConstraints = false
        dropDot.isHidden = true
        pic.addSubview(dropDot)
        NSLayoutConstraint.activate([
            dropDot.leadingAnchor.constraint(equalTo: pic.leadingAnchor, constant: Theme.Spacing.sm),
            dropDot.bottomAnchor.constraint(equalTo: pic.bottomAnchor, constant: -Theme.Spacing.sm),
            dropDot.heightAnchor.constraint(equalToConstant: DropDotView.size),
        ])

        resolutionLabel.font = Theme.Typography.caption
        resolutionLabel.textColor = Theme.Colors.label2
        resolutionLabel.backgroundColor = Theme.Colors.viewerHUD
        resolutionLabel.drawsBackground = true
        resolutionLabel.isHidden = true
        resolutionLabel.setAccessibilityLabel("Picture resolution")
        resolutionLabel.translatesAutoresizingMaskIntoConstraints = false
        pic.addSubview(resolutionLabel)
        NSLayoutConstraint.activate([
            resolutionLabel.trailingAnchor.constraint(equalTo: pic.trailingAnchor, constant: -Theme.Spacing.sm),
            resolutionLabel.bottomAnchor.constraint(equalTo: pic.bottomAnchor, constant: -Theme.Spacing.sm),
        ])

        loudnessLabel.font = Theme.Typography.caption
        loudnessLabel.textColor = Theme.Colors.label2
        loudnessLabel.backgroundColor = Theme.Colors.viewerHUD
        loudnessLabel.drawsBackground = true
        loudnessLabel.isHidden = true
        loudnessLabel.setAccessibilityLabel("Program loudness")
        loudnessLabel.translatesAutoresizingMaskIntoConstraints = false
        pic.addSubview(loudnessLabel)
        NSLayoutConstraint.activate([
            loudnessLabel.leadingAnchor.constraint(equalTo: pic.leadingAnchor, constant: Theme.Spacing.sm),
            loudnessLabel.bottomAnchor.constraint(equalTo: pic.bottomAnchor, constant: -Theme.Spacing.sm),
        ])

        offlineTitle.font = Theme.Typography.shellStrong
        offlineTitle.textColor = Theme.Colors.label
        offlineTitle.alignment = .center
        offlineDetail.font = Theme.Typography.caption
        offlineDetail.textColor = Theme.Colors.label2
        offlineDetail.alignment = .center
        offlineDetail.lineBreakMode = .byTruncatingMiddle
        let offlineStack = NSStackView(views: [offlineTitle, offlineDetail])
        offlineStack.orientation = .vertical
        offlineStack.spacing = Theme.Spacing.xs
        offlineStack.edgeInsets = NSEdgeInsets(top: Theme.Spacing.inset, left: Theme.Spacing.lg, bottom: Theme.Spacing.inset, right: Theme.Spacing.lg)
        offlineStack.translatesAutoresizingMaskIntoConstraints = false
        offlineCard.wantsLayer = true
        offlineCard.layer?.backgroundColor = Theme.Colors.viewerHUD.cgColor
        offlineCard.layer?.cornerRadius = Theme.Radius.control
        offlineCard.isHidden = true
        offlineCard.translatesAutoresizingMaskIntoConstraints = false
        offlineCard.addSubview(offlineStack)
        pic.addSubview(offlineCard)
        NSLayoutConstraint.activate([
            offlineStack.topAnchor.constraint(equalTo: offlineCard.topAnchor),
            offlineStack.bottomAnchor.constraint(equalTo: offlineCard.bottomAnchor),
            offlineStack.leadingAnchor.constraint(equalTo: offlineCard.leadingAnchor),
            offlineStack.trailingAnchor.constraint(equalTo: offlineCard.trailingAnchor),
            offlineCard.centerXAnchor.constraint(equalTo: pic.centerXAnchor),
            offlineCard.centerYAnchor.constraint(equalTo: pic.centerYAnchor),
            offlineCard.widthAnchor.constraint(lessThanOrEqualTo: pic.widthAnchor, constant: -Theme.Spacing.lg * 2),
        ])

        // Timecode: 12 semibold in the accent color (v9 `.tcd`), click to type, drag to scrub.
        timecodeField.font = Theme.Typography.shellStrong
        timecodeField.textColor = Theme.Colors.accentText
        timecodeField.isBordered = false
        timecodeField.drawsBackground = false
        timecodeField.focusRingType = .none
        timecodeField.isEditable = true
        timecodeField.isSelectable = true
        timecodeField.delegate = self
        timecodeField.target = self
        timecodeField.action = #selector(commitTimecode)
        timecodeField.setAccessibilityLabel(SQAccessibilityText.timecodeLabel)
        timecodeField.setContentHuggingPriority(.required, for: .horizontal)
        timecodeField.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The field has no intrinsic width: without a floor a tight header collapses it to nothing.
        timecodeField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.timecodeWidth).isActive = true

        durationLabel.font = Theme.Typography.shell
        durationLabel.textColor = Theme.Colors.label3
        durationLabel.alignment = .right
        durationLabel.setAccessibilityLabel("Duration")
        inOutIcon.image = SQIcon.markInOut.image(size: 14)
        inOutIcon.contentTintColor = Theme.Colors.label3
        inOutIcon.setAccessibilityElement(false)

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.orientation = .horizontal
        badge.spacing = Theme.Spacing.xs
        // v9 header tools, right of the tabs: content popup ("Main" / the clip), safe zone while one is on, "Fit", "Full";
        // the host's "..." follows. All flat (`pop sm flat`): text and chevron, fill only on hover.
        badge.addArrangedSubview(contentPopup)
        if model.mode == .program { badge.addArrangedSubview(zoneBadge) }
        badge.addArrangedSubview(zoomBadge)
        badge.addArrangedSubview(qualityBadge)
        for (popup, label, tip) in [(zoneBadge, "Safe zone", "Platform Safe Zone"), (zoomBadge, "Zoom", "Zoom: Fit, or 10 to 800 %"),
                                    (qualityBadge, "Playback quality", "Playback Quality")] {
            popup.font = Theme.Typography.body
            popup.setAccessibilityLabel(label)
            popup.setTooltip(tip)
        }
        for popup in [contentPopup, zoneBadge, zoomBadge, qualityBadge] {
            popup.boxHeight = Theme.Row.controlLarge
            popup.isFlat = true
            popup.translatesAutoresizingMaskIntoConstraints = false
        }
        zoneBadge.itemsProvider = { [weak self] in self?.model.safeZoneMenu() ?? [] }
        zoomBadge.itemsProvider = { [weak self] in self?.model.zoomMenu() ?? [] }
        qualityBadge.itemsProvider = { [weak self] in self?.model.qualityMenu() ?? [] }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.orientation = .horizontal
        header.spacing = Theme.Spacing.sm
        header.edgeInsets = NSEdgeInsets(top: 0, left: Theme.Spacing.md, bottom: 0, right: Theme.Spacing.md)
        optionsPopup.image = Theme.symbol(.ellipsis, label: "More")
        optionsPopup.itemsProvider = { [weak self] in self?.optionItems() ?? [] }
        optionsPopup.setAccessibilityLabel("Monitor menu")
        optionsPopup.setTooltip("More")
        timecodeField.onDrag = { [weak self] phase, frames in self?.timecodeDrag(phase, frames) }
        timecodeField.setTooltip("Timecode")
        if model.mode == .source {
            sourcePopup.sizesToTitle = true
            sourcePopup.font = Theme.Typography.body
            sourcePopup.setAccessibilityLabel("Source clip")
            sourcePopup.setTooltip("Source Clips")
            sourcePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            sourcePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
            sourcePopup.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
            registerForDraggedTypes([.sequenceMediaIDs, .fileURL])   // MON-33: Finder files too
        }
        if model.mode == .program {
            registerForDraggedTypes([.sequenceMediaIDs])      // SH-54: drop media = overwrite at the playhead
            formatPopup.sizesToTitle = true
            formatPopup.font = Theme.Typography.body
            formatPopup.setAccessibilityLabel("Sequence")
            formatPopup.setTooltip("Open Sequences")
            formatPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            formatPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
            formatPopup.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        }
        // The panel's own header row (only where no tab strip hosts the tools): the tools at the right, then the monitor menu.
        let headerViews: [NSView] = [spacer, badge, optionsPopup]
        for v in headerViews { header.addArrangedSubview(v) }
        header.translatesAutoresizingMaskIntoConstraints = false
        headerHeight = header.heightAnchor.constraint(equalToConstant: Theme.Metrics.panelHeader)

        transport.orientation = .horizontal
        transport.spacing = Theme.Spacing.xxs
        transport.translatesAutoresizingMaskIntoConstraints = false
        for a in MonitorAction.buttonBar(for: model.mode) {
            let (symbol, title) = Self.symbols[a]!
            // v9 `.ibtn.sm`: 24 x 24, radius 4, 12 pt glyph; Play is an `.ibtn`: 28 x 28, radius 6, 16 pt filled glyph.
            let b = SQButton(symbol: symbol, label: title, target: self, action: #selector(transportPressed(_:)))
            let isPlay = a == .playPause
            let glyph = isPlay ? Self.playGlyph : Self.smallGlyph
            b.boxHeight = isPlay ? Self.rowHeight : Theme.Row.controlLarge
            b.horizontalPadding = (b.boxHeight - glyph) / 2
            b.cornerRadius = isPlay ? Theme.Radius.control : Theme.Radius.small
            b.image = Theme.symbol(symbol, size: glyph, label: title)
            b.contentTintColor = isPlay ? Theme.Colors.label : Theme.Colors.label2
            b.sqToolTip = a.tip(title)
            b.setAccessibilityLabel(title)
            b.tag = MonitorAction.allCases.firstIndex(of: a)!
            buttons[a] = b
            transport.addArrangedSubview(b)
        }

        // Right of the footer: In/Out icon, the ONE duration, and (Source) the video-only / audio-only drag handles.
        footerRight.orientation = .horizontal
        footerRight.spacing = Theme.Spacing.iconToLabel
        footerRight.translatesAutoresizingMaskIntoConstraints = false
        footerRight.addArrangedSubview(inOutIcon)
        footerRight.addArrangedSubview(durationLabel)
        if model.mode == .source {
            for a in [MonitorAction.insert, .overwrite] {
                let (symbol, title) = Self.symbols[a]!
                let b = SQButton(symbol: symbol, label: title, target: self, action: #selector(transportPressed(_:)))
                b.boxHeight = Theme.Row.controlLarge
                b.horizontalPadding = (b.boxHeight - Self.smallGlyph) / 2
                b.cornerRadius = Theme.Radius.small
                b.image = Theme.symbol(symbol, size: Self.smallGlyph, label: title)
                b.contentTintColor = Theme.Colors.label2
                b.sqToolTip = a.tip(title)
                b.setAccessibilityLabel(title)
                b.tag = MonitorAction.allCases.firstIndex(of: a)!
                editButtons.append(b)
                footerRight.addArrangedSubview(b)
            }
            let video = StreamDragView(streams: .videoOnly), audio = StreamDragView(streams: .audioOnly)
            for (v, glyph, tip) in [(video, SQIcon.film, "Drag Video Only"), (audio, .waveform, "Drag Audio Only")] {
                v.model = model
                v.image = glyph.image(size: 14)
                v.sqToolTip = tip
                v.setAccessibilityLabel(tip)
                footerRight.addArrangedSubview(v)
            }
            footerRight.setCustomSpacing(2, after: video)
        }

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(transport)
        footer.addSubview(timecodeField)
        footer.addSubview(footerRight)
        timecodeField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header); addSubview(pic); addSubview(footer)
        // v9 `.mtr`: scrub bar on top, then the row: timecode left | five buttons centered | In/Out icon + duration (+ handles) right.
        let rowCenter = -(Theme.Spacing.sm + Self.rowHeight / 2)
        scrubBar.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(scrubBar)
        NSLayoutConstraint.activate([
            pic.bottomAnchor.constraint(equalTo: footer.topAnchor),
            scrubBar.topAnchor.constraint(equalTo: footer.topAnchor, constant: Theme.Spacing.sm),
            scrubBar.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            scrubBar.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            scrubBar.heightAnchor.constraint(equalToConstant: MonitorScrubBar.height),
        ])
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerHeight,
            pic.topAnchor.constraint(equalTo: header.bottomAnchor),
            pic.leadingAnchor.constraint(equalTo: leadingAnchor),
            pic.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            transport.leadingAnchor.constraint(greaterThanOrEqualTo: timecodeField.trailingAnchor),
            transport.centerYAnchor.constraint(equalTo: footer.bottomAnchor, constant: rowCenter),
            footerRight.leadingAnchor.constraint(greaterThanOrEqualTo: transport.trailingAnchor, constant: Theme.Spacing.xs),
            timecodeField.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Theme.Spacing.md - 2),
            timecodeField.centerYAnchor.constraint(equalTo: footer.bottomAnchor, constant: rowCenter),
            footerRight.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Theme.Spacing.md),
            footerRight.centerYAnchor.constraint(equalTo: footer.bottomAnchor, constant: rowCenter),
        ])
        // v9 `.mtrow`: the buttons sit in the middle of the row, not after the timecode.
        let centred = transport.centerXAnchor.constraint(equalTo: footer.centerXAnchor)
        centred.priority = NSLayoutConstraint.Priority(750)
        centred.isActive = true
    }


    /// Re-reads the model and re-arms observation. Call once; it keeps itself updated.
    private func refresh() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Narrow panels (min 320): the footer drops what it cannot fit instead of clipping the timecode or overlapping the transport.
    /// Order of loss: the video-only / audio-only handles first, then the duration, then Insert / Overwrite. Timecode and the five buttons always stay.
    public override func layout() {
        let rightViews = footerRight.arrangedSubviews
        let handles = rightViews.filter { $0 is StreamDragView }
        let edits = rightViews.filter { v in editButtons.contains { $0 === v } }
        let fixed = Theme.Spacing.md + Self.timecodeWidth + transport.fittingSize.width + Theme.Spacing.xs + Theme.Spacing.md
        func width(_ views: [NSView]) -> CGFloat {
            views.reduce(0) { $0 + max($1.fittingSize.width, $1.intrinsicContentSize.width) } + footerRight.spacing * CGFloat(max(views.count - 1, 0))
        }
        let all = rightViews.map { $0 }
        let noHandles = all.filter { !($0 is StreamDragView) }
        let core = noHandles.filter { $0 !== durationLabel }
        let avail = bounds.width
        let hideHandles = avail < fixed + width(all)
        let hideDuration = avail < fixed + width(noHandles)
        let hideEdits = avail < fixed + width(core)
        for h in handles where h.isHidden != hideHandles { h.isHidden = hideHandles }
        if durationLabel.isHidden != hideDuration { durationLabel.isHidden = hideDuration }
        for e in edits where e.isHidden != hideEdits { e.isHidden = hideEdits }
        super.layout()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        loudnessTimer?.invalidate()
        loudnessTimer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLoudnessReadout() }
        }
        RunLoop.main.add(t, forMode: .common)
        loudnessTimer = t
    }

    /// Short-term and integrated loudness over the picture while the engine measures (playing); gone when there is no signal.
    private func updateLoudnessReadout() {
        guard let reading = loudnessProvider?(), let text = LoudnessReadout.text(reading) else {
            if !loudnessLabel.isHidden { loudnessLabel.isHidden = true }
            return
        }
        let over = LoudnessReadout.isOver(reading, target: loudnessTargetProvider?() ?? .default)
        let shown = " \(text) "
        if loudnessLabel.stringValue != shown { loudnessLabel.stringValue = shown }
        loudnessLabel.textColor = over ? Theme.Colors.yellow : Theme.Colors.label2
        loudnessLabel.isHidden = false
    }

    /// VoiceOver: the panel is one group whose value says play state and playhead timecode.
    private func updateAccessibility() {
        let value = SQAccessibilityText.monitorValue(isPlaying: model.isPlaying, timecode: model.timecodeText)
        if accessibilityValueText != value { accessibilityValueText = value; NSAccessibility.post(element: self, notification: .valueChanged) }
    }
    private var accessibilityValueText = ""
    public override func isAccessibilityElement() -> Bool { false }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { SQAccessibilityText.monitorLabel }
    public override func accessibilityValue() -> Any? { accessibilityValueText.isEmpty ? nil : accessibilityValueText }

    private func apply() {
        if timecodeField.currentEditor() == nil { timecodeField.stringValue = model.timecodeText }
        // Exactly two time values in the footer: the playhead and ONE duration (In to Out when a range is set, else the length).
        durationLabel.stringValue = model.footerDurationText
        zoomBadge.title = badgeOnPicture ? Self.pictureBadgeTitle(zoom: model.badgeText, quality: model.qualityBadgeText) : model.badgeText
        qualityBadge.title = model.qualityBadgeText
        zoneBadge.title = model.safeZone.badgeTitle
        zoneBadge.isHidden = model.safeZone == .off     // design B header is [content][Fit][Full][...]; a zone adds its popup
        scrubBar.needsDisplay = true
        applyViewerMargin()
        if model.mode == .program {
            programEmpty.apply(model.programEmptyState)
            badge.isHidden = !model.hasSequence
            // Edit page: "Fit" and "Full" are two header popups; on the Color page they merge into one pill on the picture.
            qualityBadge.isHidden = badgeOnPicture
            formatPopup.isHidden = !model.hasSequence || badgeOnPicture
        }
        hudLabel.stringValue = model.latencyText ?? ""
        hudLabel.isHidden = model.latencyText == nil
        if model.mode == .source {
            applySourcePopup()
            let wave = model.viewerMode == .waveform
            waveformView.isHidden = !wave
            zoomBadge.isHidden = wave           // no zoom or quality for a waveform; the clip popup stays
            qualityBadge.isHidden = wave
            if wave { _ = (model.sourceWaveform, model.markIn, model.markOut, model.currentTime); waveformView.needsDisplay = true }
            anglesGrid.isHidden = model.angleTiles == nil
            if model.angleTiles != nil { anglesGrid.needsDisplay = true }
        }
        dropDot.isHidden = !model.dropIndicatorEnabled
        dropDot.amber = model.dropAmber
        dropDot.warn = model.dropRealtimeNotAchieved
        dropDot.text = model.dropBadgeText
        dropDot.tip = model.dropTooltip
        let hasPicture = model.mode == .program ? model.hasSequence : model.viewerMode == .picture
        let offline = hasPicture ? model.offlineFileName != nil : false
        offlineCard.isHidden = !offline
        if offline {
            offlineTitle.stringValue = model.offlineCardTitle
            offlineDetail.stringValue = model.offlineCardDetail ?? ""
        }
        resolutionLabel.stringValue = model.resolutionBadgeText.map { " \($0) " } ?? ""
        resolutionLabel.isHidden = model.resolutionBadgeText == nil || !hasPicture
        if model.mode == .program { applySequencePopup() }
        safeMarginsView.showsGuides = model.safeMargins
        safeMarginsView.guides = model.guides
        safeMarginsView.showsRulers = model.showsRulers
        safeMarginsView.aspectFrame = model.aspectFrame
        safeMarginsView.marginSizes = model.safeMarginSizes
        safeMarginsView.isHidden = model.overlaysHidden || (!model.safeMargins && model.safeZone == .off && !model.showsRulers
            && model.guides.isEmpty && model.aspectFrame == .off)
        safeMarginsView.needsDisplay = true
        let available = Set(model.availableActions)
        for (a, b) in buttons {
            b.isHidden = !available.contains(a)
            b.isEnabled = true
        }
        if let play = buttons[.playPause] {
            let glyph: SQIcon = model.isPlaying ? .pause : .play
            let title = model.isPlaying ? "Pause" : "Play"
            if play.sqToolTip != MonitorAction.playPause.tip(title) { play.image = Theme.symbol(glyph, size: Self.playGlyph, label: title) }
            play.sqToolTip = MonitorAction.playPause.tip(title)
            play.setAccessibilityLabel(title)
        }
        updateAccessibility()
    }

    // MARK: Source clip popup and drops

    /// Title popup: the clips opened before (most recent first), then Close / Close All.
    private func applySourcePopup() {
        let items = model.sourceItems, current = model.sourceCurrent
        if let b = builtSource, b.items == items, b.current == current { return }
        builtSource = (items, current)
        sourcePopup.isEnabled = !items.isEmpty
        sourceEmpty.isHidden = !items.isEmpty
        sourcePopup.title = MonitorMenus.sourceTitle(items, current: current)
        sourcePopup.itemsProvider = { [weak self] in
            guard let self else { return [] }
            return MonitorMenus.sourceItems(self.model.sourceItems, current: self.model.sourceCurrent,
                                            pick: { [weak self] id in self?.model.onPickSource?(id) },
                                            close: { [weak self] in self?.model.onCloseSource?() },
                                            closeAll: { [weak self] in self?.model.onCloseAllSources?() })
        }
    }

    // MARK: Sequence popup (Program)

    /// Title popup: the open sequences, the shown one checked. The frame format is not here (it is in the "..." menu).
    private func applySequencePopup() {
        let items = model.sequenceItems, current = model.sequenceCurrent, name = model.sequenceName
        if let b = builtSequences, b.name == name, b.items == items, b.current == current { return }
        builtSequences = (name, items, current)
        formatPopup.title = MonitorMenus.sequenceTitle(items, current: current, fallback: name)
        formatPopup.itemsProvider = { [weak self] in
            guard let self else { return [] }
            return MonitorMenus.sequenceItems(self.model.sequenceItems, current: self.model.sequenceCurrent,
                                              pick: { [weak self] id in self?.model.onPickSequence?(id) })
        }
    }

    private func droppedMedia(_ info: NSDraggingInfo) -> [UUID] {
        let raw = info.draggingPasteboard.string(forType: .sequenceMediaIDs) ?? ""
        return ProjectPanelModel.decodeItems(raw).compactMap { if case .media(let id) = $0 { id } else { nil } }
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        guard model.mode == .source, model.onDropFiles != nil else { return [] }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { !$0.hasDirectoryPath }
    }

    private let dropZoneLayer = CALayer()
    private let dropZoneText = CATextLayer()

    /// Program drops: the half under the pointer shows its action (Insert left, Overwrite right).
    private func showDropZone(_ sender: NSDraggingInfo?) {
        guard model.mode == .program, model.onDropMediaZone != nil, let sender, !droppedMedia(sender).isEmpty else {
            dropZoneLayer.removeFromSuperlayer()
            return
        }
        let x = convert(sender.draggingLocation, from: nil).x
        let zone = MonitorDropZone.zone(atX: x, width: bounds.width)
        let r = zone.rect(in: bounds.size)
        if dropZoneLayer.superlayer == nil {
            dropZoneLayer.backgroundColor = Theme.State.dropTargetFill.cgColor
            dropZoneText.font = Theme.Typography.body
            dropZoneText.fontSize = Theme.Typography.body.pointSize
            dropZoneText.foregroundColor = Theme.Colors.label.cgColor
            dropZoneText.alignmentMode = .center
            dropZoneLayer.addSublayer(dropZoneText)
            layer?.addSublayer(dropZoneLayer)
        }
        dropZoneLayer.frame = r
        dropZoneText.string = zone.title
        dropZoneText.contentsScale = window?.backingScaleFactor ?? 2
        dropZoneText.frame = CGRect(x: 0, y: r.height / 2 - 10, width: r.width, height: 20)
    }

    private func setDropHighlight(_ on: Bool) {
        if !on { dropZoneLayer.removeFromSuperlayer() }
        wantsLayer = true
        layer?.borderWidth = on ? Theme.State.focusRingWidth : 0
        layer?.borderColor = on ? Theme.State.focusRing.cgColor : nil
        layer?.backgroundColor = (on ? Theme.State.dropTargetFill : Theme.Colors.panel).cgColor
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppedMedia(sender).isEmpty || !droppedFiles(sender).isEmpty else { return [] }
        setDropHighlight(true)
        showDropZone(sender)
        return .copy
    }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        showDropZone(sender)
        return droppedMedia(sender).isEmpty && droppedFiles(sender).isEmpty ? [] : .copy
    }
    public override func draggingExited(_ sender: NSDraggingInfo?) { setDropHighlight(false) }
    public override func draggingEnded(_ sender: NSDraggingInfo) { setDropHighlight(false) }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        let ids = droppedMedia(sender)
        if !ids.isEmpty {
            if model.mode == .program, let onZone = model.onDropMediaZone {
                onZone(ids, MonitorDropZone.zone(atX: convert(sender.draggingLocation, from: nil).x, width: bounds.width))
            } else {
                model.onDropMedia?(ids)
            }
            return true
        }
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return false }
        model.onDropFiles?(files)
        return true
    }

    @objc private func transportPressed(_ sender: SQButton) {
        model.perform(MonitorAction.allCases[sender.tag])
    }

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

    /// The monitor menu ("..." of the tab strip and of the header): the shared rows (SQDrawMonitor) plus View Gamma and
    /// Display View, which need the Mac renderer.
    func optionItems() -> [SQMenuItem] {
        model.optionItems(viewItems: [
            SQMenuItem(title: "View Gamma", submenu: MonitorMenus.viewGammaItems(
                current: model.viewGamma, set: { [weak self] in self?.model.setViewGamma($0) })),
            SQMenuItem(title: "Display View", submenu: MonitorMenus.displayViewItems(
                current: model.displayView, set: { [weak self] in self?.model.setDisplayView($0) })),
        ])
    }

    public func showOptions(from sender: NSView) {
        SQContextMenu.popUp(items: optionItems(), at: NSPoint(x: sender.bounds.minX, y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY), in: sender)
    }

    /// Go to Timecode: puts the cursor in the timecode field with its text selected; Return commits (`commitTimecodeText`).
    public func focusTimecodeField() {
        window?.makeFirstResponder(timecodeField)
        timecodeField.selectText(nil)
    }

    @objc private func commitTimecode() {
        let typed = timecodeField.stringValue
        let ok = model.commitTimecodeText(typed)
        timecodeField.stringValue = model.timecodeText
        if !ok {
            let hint = MonitorPanelModel.timecodeHint(for: typed)
            if hint.isEmpty { NSSound.beep() } else { _ = SQToast.show(hint, in: self) }
        }
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

/// Program monitor with no sequence open (Overlays board): one line of text and the large "New Sequence..." button, centered.
/// Only the button takes clicks; drops fall through to the panel (drop media = new sequence is the host's call).
@MainActor
final class ProgramEmptyView: NSView {
    var onNew: (() -> Void)?
    static func text(_ k: ProgramEmptyKind) -> String { k.hint }
    private let label = NSTextField(wrappingLabelWithString: ProgramEmptyView.text(.noSequence))
    private(set) var kind: ProgramEmptyKind = .none
    var buttonIsHidden: Bool { button.isHidden }

    /// Hidden for `.none`; `.emptyTimeline` keeps Pip and the hint but has no New Sequence button (one exists).
    func apply(_ k: ProgramEmptyKind) {
        kind = k
        isHidden = k == .none
        label.stringValue = Self.text(k)
        button.isHidden = k != .noSequence
    }
    private lazy var button = SQButton(title: "New Sequence…", target: self, action: #selector(newPressed))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.monitorBackdrop.cgColor
        label.font = Theme.Typography.body
        label.textColor = Theme.Colors.label3
        label.alignment = .center
        button.boxHeight = Theme.Row.controlLarge
        button.horizontalPadding = Theme.Spacing.lg
        button.setAccessibilityLabel("New Sequence")
        var parts: [NSView] = [label, button]
        if let pip = SQMascotPlace.programEmpty.makeView() {   // M5
            parts.insert(pip, at: 0)
            pip.reactToHover(in: self)                         // R2
        }
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Theme.Spacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Spacing.xl),
        ])
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func newPressed() { onNew?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === button || v?.isDescendant(of: button) == true ? v : nil
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

/// Action-safe (90 %) and title-safe (80 %) guides and the center cross over the picture.
@MainActor
public final class SafeMarginsView: NSView {
    /// Rect of the picture in this view's coordinates.
    public var rectProvider: (() -> CGRect)?
    /// Platform UI zone (frame fractions, origin top-left) of the zone popup; nil = none.
    public var platformZoneProvider: (() -> NormRect?)?
    /// Elements of the platform UI mock (zone popup "Show platform UI"); empty = none.
    public var platformMockProvider: (() -> [PlatformUIMock.Element])?
    /// The 90 % / 80 % guides and the center cross (the Safe Margins toggle); the platform zone draws on its own.
    public var showsGuides = true
    /// User guides and rulers (percent of the picture); `onGuidesChange` reports a drag so the model keeps them.
    public var guides = MonitorGuides() { didSet { if guides != oldValue { needsDisplay = true } } }
    public var showsRulers = false { didSet { if showsRulers != oldValue { needsDisplay = true } } }
    public var onGuidesChange: ((MonitorGuides) -> Void)?
    /// Aspect frame (dims what lies outside it) and the sizes of the safe-margin rectangles.
    public var aspectFrame = AspectFrame.off { didSet { if aspectFrame != oldValue { needsDisplay = true } } }
    public var marginSizes = SafeMarginSizes.default { didSet { if marginSizes != oldValue { needsDisplay = true } } }
    var activeGuide: (axis: MonitorGuides.Axis, index: Int)?
    static let rulerThickness: CGFloat = 14, guideGrab: CGFloat = 4
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return guideTarget(at: p) == nil ? nil : self
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let r = rectProvider?(), r.width > 4 else { return }
        defer { drawGuides(in: r) }
        if let f = aspectFrame.rect(in: r) {
            // Dim the picture outside the frame so the crop reads at a glance; the frame edge is a thin guide line.
            Theme.Colors.guide.withAlphaComponent(0.18).setFill()
            let band = NSBezierPath(rect: r)
            band.append(NSBezierPath(rect: f))
            band.windingRule = .evenOdd
            band.fill()
            Theme.Colors.guide.setStroke()
            let edge = NSBezierPath(rect: f)
            edge.lineWidth = 1
            edge.stroke()
        }
        if let z = platformZoneProvider?() {
            // Dim what the platform's own buttons, name and caption cover; the clear rectangle is where content stays visible.
            let safe = CGRect(x: r.minX + z.x * r.width, y: r.minY + z.y * r.height, width: z.width * r.width, height: z.height * r.height)
            Theme.Colors.guide.withAlphaComponent(0.18).setFill()
            let band = NSBezierPath(rect: r)
            band.append(NSBezierPath(rect: safe))
            band.windingRule = .evenOdd
            band.fill()
            Theme.Colors.guide.setStroke()
            let edge = NSBezierPath(rect: safe)
            edge.lineWidth = 1
            edge.setLineDash([4, 3], count: 2, phase: 0)
            edge.stroke()
            drawMock(in: r)
        }
        guard showsGuides else { return }
        Theme.Colors.guide.setStroke()
        for k in marginSizes.fractions {
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

extension SafeMarginsView {
    /// What a press at `p` grabs: an existing guide (move it) or a ruler strip (pull a new guide out).
    enum GuideTarget: Equatable { case guide(MonitorGuides.Axis, Int), newVertical, newHorizontal }

    func guideTarget(at p: CGPoint) -> GuideTarget? {
        guard let r = rectProvider?(), r.width > 4 else { return nil }
        guard showsRulers || !guides.isEmpty else { return nil }
        if r.insetBy(dx: -Self.guideGrab, dy: -Self.guideGrab).contains(p) {
            for (i, f) in guides.vertical.enumerated() where abs(p.x - (r.minX + f * r.width)) <= Self.guideGrab { return .guide(.vertical, i) }
            for (i, f) in guides.horizontal.enumerated() where abs(p.y - (r.minY + f * r.height)) <= Self.guideGrab { return .guide(.horizontal, i) }
        }
        guard showsRulers else { return nil }
        let t = Self.rulerThickness
        if CGRect(x: r.minX, y: r.minY, width: r.width, height: t).contains(p) { return .newHorizontal }
        if CGRect(x: r.minX, y: r.minY, width: t, height: r.height).contains(p) { return .newVertical }
        return nil
    }

    private func fraction(_ axis: MonitorGuides.Axis, at p: CGPoint, in r: CGRect) -> Double {
        axis == .vertical ? Double((p.x - r.minX) / max(r.width, 1)) : Double((p.y - r.minY) / max(r.height, 1))
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let r = rectProvider?(), let target = guideTarget(at: p) else { return }
        switch target {
        case .guide(let a, let i): activeGuide = (a, i)
        case .newVertical:
            activeGuide = (.vertical, guides.add(.vertical, at: fraction(.vertical, at: p, in: r)))
        case .newHorizontal:
            activeGuide = (.horizontal, guides.add(.horizontal, at: fraction(.horizontal, at: p, in: r)))
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let g = activeGuide, let r = rectProvider?() else { return }
        let p = convert(event.locationInWindow, from: nil)
        guides.move(g.axis, index: g.index, to: fraction(g.axis, at: p, in: r))
        onGuidesChange?(guides)
    }

    public override func mouseUp(with event: NSEvent) {
        guard let g = activeGuide, let r = rectProvider?() else { return }
        activeGuide = nil
        let p = convert(event.locationInWindow, from: nil)
        let f = fraction(g.axis, at: p, in: r)
        // Dropped back into the ruler or outside the picture: the guide is gone.
        let t = Double(Self.rulerThickness / max(g.axis == .vertical ? r.width : r.height, 1))
        if f < t * 0.5 || f > 1.02 || !r.insetBy(dx: -40, dy: -40).contains(p) { guides.remove(g.axis, index: g.index) }
        onGuidesChange?(guides)
    }

    func drawGuides(in r: CGRect) {
        if showsRulers {
            let t = Self.rulerThickness
            Theme.Colors.field.withAlphaComponent(0.85).setFill()
            CGRect(x: r.minX, y: r.minY, width: r.width, height: t).fill()
            CGRect(x: r.minX, y: r.minY + t, width: t, height: r.height - t).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label3]
            Theme.Colors.label3.setFill()
            let steps = Int((1 / MonitorGuides.minorStep).rounded())
            for i in 0...steps {
                let f = Double(i) * MonitorGuides.minorStep
                let major = i % 2 == 0
                let len: CGFloat = major ? t * 0.6 : t * 0.3
                let x = (r.minX + CGFloat(f) * r.width).rounded(), y = (r.minY + CGFloat(f) * r.height).rounded()
                CGRect(x: x, y: r.minY + t - len, width: 1, height: len).fill()
                if i > 0 { CGRect(x: r.minX + t - len, y: y, width: len, height: 1).fill() }
                if major, i > 0, i < steps {
                    ("\(Int((f * 100).rounded()))" as NSString).draw(at: NSPoint(x: x + 2, y: r.minY), withAttributes: attrs)
                }
            }
        }
        Theme.Colors.accent.setFill()
        for v in guides.vertical { CGRect(x: (r.minX + CGFloat(v) * r.width).rounded(), y: r.minY, width: 1, height: r.height).fill() }
        for h in guides.horizontal { CGRect(x: r.minX, y: (r.minY + CGFloat(h) * r.height).rounded(), width: r.width, height: 1).fill() }
    }

    private static func glyph(_ kind: PlatformUIMock.Kind) -> SQIcon? {
        switch kind {
        case .avatar: .user
        case .like: .heart
        case .comment: .discord
        case .share: .share
        case .save: .bookmarkFilled
        default: nil
        }
    }

    /// Light placeholder shapes of the platform's own UI; geometry from SQCore (`PlatformUIMock`), color from one Theme token.
    fileprivate func drawMock(in r: CGRect) {
        guard let elements = platformMockProvider?(), !elements.isEmpty else { return }
        let ink = Theme.Colors.platformMock
        for e in elements {
            let box = CGRect(x: r.minX + e.rect.x * r.width, y: r.minY + e.rect.y * r.height,
                             width: e.rect.width * r.width, height: e.rect.height * r.height)
            if e.isRoundButton {
                ink.withAlphaComponent(0.22).setFill()
                NSBezierPath(ovalIn: box).fill()
                if let name = Self.glyph(e.kind) {
                    let img = name.image(size: box.width * 0.42, color: ink)
                    let size = img.size
                    img.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
                }
            } else if e.kind == .progressBar {
                ink.withAlphaComponent(0.5).setFill()
                box.fill()
            } else {
                ink.withAlphaComponent(e.kind == .accountName ? 0.55 : 0.32).setFill()
                NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            }
        }
    }
}

/// The viewer's host view: right-click and ctrl-click show the SQ rows the app builds (`contextMenuBuilder`), no NSMenu.
@MainActor
public final class MonitorViewerSlot: NSView {
    var itemsProvider: (() -> [SQMenuItem])?
    private func show(for event: NSEvent) {
        if let items = itemsProvider?(), !items.isEmpty { SQContextMenu.show(items: items, for: event, in: self) }
    }
    public override func rightMouseDown(with event: NSEvent) { show(for: event) }
    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { show(for: event) } else { super.mouseDown(with: event) }
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
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: Theme.Row.control))
        setContentHuggingPriority(.required, for: .horizontal)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Board `.hdl`: 26 x 22 capsule, fill2 with a hairline edge, icon in label2.
    override var intrinsicContentSize: NSSize { image == nil ? super.intrinsicContentSize : NSSize(width: 26, height: 22) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let box = bounds.insetBy(dx: 0.25, dy: 0.25)
        let cap = NSBezierPath(roundedRect: box, xRadius: Theme.Radius.capsule(forHeight: box.height), yRadius: Theme.Radius.capsule(forHeight: box.height))
        Theme.Colors.fill2.setFill()
        cap.fill()
        Theme.Colors.separator.setStroke()
        cap.lineWidth = 0.5
        cap.stroke()
        let cfg = image
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
        guard let down = downPoint, let item = model?.dragItem?(streams) as? NSPasteboardItem else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - down.x, p.y - down.y) > 4 else { return }
        downPoint = nil
        let img = Self.ghostImage(streams)
        let drag = NSDraggingItem(pasteboardWriter: item)
        // The ghost tile follows the pointer, the tip hangs under it (Panels board "Source").
        drag.setDraggingFrame(NSRect(x: p.x - Self.ghostTile.width / 2, y: p.y - img.size.height + Self.ghostTile.height / 2,
                                     width: img.size.width, height: img.size.height), contents: img)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    /// Board ghost: 60 x 106 tile (radius 6, 1.5 pt yellow edge, 92 % opacity) with the tip pill under it.
    static let ghostTile = CGSize(width: 60, height: 106)

    static func tipText(_ streams: SourceStreams) -> String {
        switch streams { case .both: "Video and audio"; case .videoOnly: "Video only"; case .audioOnly: "Audio only" }
    }

    static func ghostImage(_ streams: SourceStreams) -> NSImage {
        let tip = tipText(streams)
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.caption, .foregroundColor: Theme.Colors.label]
        let tipSize = (tip as NSString).size(withAttributes: attrs)
        let tipBox = CGSize(width: ceil(tipSize.width) + 12, height: 20)
        let gap: CGFloat = 6, pad: CGFloat = 4
        let size = CGSize(width: max(ghostTile.width, tipBox.width) + 2 * pad, height: ghostTile.height + gap + tipBox.height + 2 * pad)
        let symbol: SQIcon = streams == .audioOnly ? .waveform : streams == .videoOnly ? .film : .sequence
        return NSImage(size: size, flipped: true) { _ in
            let tile = NSRect(x: (size.width - ghostTile.width) / 2, y: pad, width: ghostTile.width, height: ghostTile.height)
            let tilePath = NSBezierPath(roundedRect: tile, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
            Theme.Colors.fill.setFill()
            tilePath.fill()
            Theme.Colors.yellow.setStroke()
            tilePath.lineWidth = 1.5
            tilePath.stroke()
            if let glyph = Theme.symbol(symbol, size: 22) {
                let tinted = NSImage(size: glyph.size, flipped: false) { rect in
                    glyph.draw(in: rect)
                    Theme.Colors.label2.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(at: NSPoint(x: tile.midX - glyph.size.width / 2, y: tile.midY - glyph.size.height / 2),
                            from: .zero, operation: .sourceOver, fraction: 1)
            }
            let box = NSRect(x: (size.width - tipBox.width) / 2, y: tile.maxY + gap, width: tipBox.width, height: tipBox.height)
            let boxPath = NSBezierPath(roundedRect: box, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
            Theme.Colors.overlay.setFill()
            boxPath.fill()
            (tip as NSString).draw(at: NSPoint(x: box.minX + 6, y: box.midY - tipSize.height / 2), withAttributes: attrs)
            return true
        }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { model?.onDragEnded?() }
    }
}

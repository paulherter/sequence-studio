import AppKit
import SQCore

/// The header bar above the timeline (design v9 `.ph` of the Timeline panel): sequence tabs (left, flexible), then the
/// Normal | Fast Cut switch, the playhead timecode, Snapping, Linked selection, Add marker and the "Fit" popup (zoom and
/// track height commands). The tools live in `ToolStripView`.
/// `bind(to:)` mirrors the timeline's `toolState` into the toggles and routes clicks back.
@MainActor
public final class TimelineHeaderBar: NSView {
    // MARK: Layout metrics (pure, tested)

    /// v9 `.ph`: 30 high, 4 pt padding left and right, 4 pt between the controls.
    public static let height: CGFloat = Theme.Row.timelineHeader
    /// v9 `.ibtn.sm`: 24 x 24, radius 4.
    public static let buttonWidth: CGFloat = 24
    public static let toggleHeight: CGFloat = 24
    public static let spacing: CGFloat = Theme.Spacing.xs
    public static let leftPadding: CGFloat = Theme.Spacing.xs
    public static let rightPadding: CGFloat = Theme.Spacing.xs
    public static let separatorHeight: CGFloat = Theme.Spacing.lg
    /// v9 timecode: 8 pt before the first button.
    public static let groupGap: CGFloat = Theme.Spacing.xs * 2
    /// v9 flat popup "Fit": 10 pt, label, 8 pt, 12 pt chevron, 8 pt.
    public static let fitWidth: CGFloat = 56
    /// Edit mode capsule (icon + label, 22 high): fits the longer label so the bar never shifts.
    public static var modeWidth: CGFloat { TimelineModeChip.width }

    /// Playhead timecode ("00:00:15:12", 11 pt) left of the buttons.
    public static let timecodeWidth: CGFloat = 72
    static let minTabsWidth: CGFloat = 140

    public struct Frames: Equatable {
        public var tabs: CGRect
        public var timecode: CGRect = .zero
        public var snap: CGRect, link: CGRect
        public var marker: CGRect = .zero
        /// Normal | Fast Cut switch (`SQSegmented`), left of the timecode.
        public var editMode: CGRect = .zero
        /// Place Sequences as Clips: in the Fit popup, no button.
        public var placeClips: CGRect = .zero
        /// Zoom out / in: in the Fit popup, no buttons.
        public var zoomOut: CGRect, zoomIn: CGRect, fit: CGRect
        /// Track height commands: in the Fit popup, no buttons.
        public var heightShorter: CGRect, heightTaller: CGRect, heightFit: CGRect
        public var separators: [CGRect]
    }

    /// v9 order: tabs (flexible) | timecode, Snapping, Linked selection, Add marker, Fit. The Normal | Fast Cut switch sits
    /// left of the timecode and is always there (decision 2026-10-10), so the mode shows and one click changes it.
    /// Zoom in / out, the track height commands and Place Sequences as Clips are rows of the Fit popup.
    public static func frames(width: CGFloat, height: CGFloat = TimelineHeaderBar.height,
                              showsEditMode: Bool = true) -> Frames {
        let f = TimelineHeaderLayout.frames(width: width, height: height, modeWidth: modeWidth, showsEditMode: showsEditMode)
        return Frames(tabs: f.tabs, timecode: f.timecode, snap: f.snap, link: f.link, marker: f.marker, editMode: f.editMode,
                      zoomOut: .zero, zoomIn: .zero, fit: f.fit,
                      heightShorter: .zero, heightTaller: .zero, heightFit: .zero, separators: [])
    }

    // MARK: State

    private(set) var snapButton = TimelineToolSlotButton(frame: .zero)
    private(set) var linkButton = TimelineToolSlotButton(frame: .zero)
    private(set) var markerButton = TimelineToolSlotButton(frame: .zero)
    /// Add marker was clicked; the owner adds one at the playhead (one undo step).
    public var onAddMarker: (() -> Void)?
    private(set) var modeControl = TimelineModeChip(frame: .zero)
    /// The user picked a mode in the capsule's menu; the owner makes it one undo step (`EditorSession.setTimelineEditMode`).
    public var onEditModeRequest: ((TimelineEditMode) -> Void)?
    /// The active sequence's mode, shown on the switch.
    public var editMode: TimelineEditMode = .normal { didSet { syncButtons(); if editMode != oldValue { needsLayout = true } } }
    private(set) var placeClipsButton = TimelineToolSlotButton(frame: .zero)
    private let zoomOutButton = TimelineToolSlotButton(frame: .zero)
    private let zoomInButton = TimelineToolSlotButton(frame: .zero)
    private(set) var fitButton = TimelineToolSlotButton(frame: .zero)
    private(set) var heightShorterButton = TimelineToolSlotButton(frame: .zero)
    private(set) var heightTallerButton = TimelineToolSlotButton(frame: .zero)
    private(set) var heightFitButton = TimelineToolSlotButton(frame: .zero)
    private weak var timeline: TimelineView?
    private var tabsView: NSView?
    private let timecodeLabel = NSTextField(labelWithString: "")

    public var toolState = ToolState() { didSet { syncButtons() } }

    public nonisolated override var isFlipped: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    /// The sequence tab strip lives in the bar's left part.
    public func setTabs(_ view: NSView) {
        tabsView?.removeFromSuperview()
        tabsView = view
        addSubview(view)
        needsLayout = true
    }

    /// Mirrors `timeline.toolState` and sends clicks back to it.
    public func bind(to timeline: TimelineView) {
        self.timeline = timeline
        toolState = timeline.toolState
        let previous = timeline.onToolStateChange
        timeline.onToolStateChange = { [weak self] s in previous?(s); self?.toolState = s }
        let previousShown = timeline.onPlayheadShown
        timeline.onPlayheadShown = { [weak self] t in previousShown?(t); self?.showTimecode(t) }
        showTimecode(timeline.playhead)
        let previousFit = timeline.onFitTracksChange
        timeline.onFitTracksChange = { [weak self] in previousFit?($0); self?.syncButtons() }
        syncButtons()
    }

    /// Formats the playhead like the ruler (drop-frame only where the rate has it).
    private func showTimecode(_ t: Time) {
        guard let timeline else { return }
        var format = TimecodeFormat(frameDuration: timeline.geometry.frameDuration)
        format.startFrame = timeline.timecodeStart.frameIndex(frameDuration: timeline.geometry.frameDuration)
        format.framesOnly = timeline.timecodeFramesOnly
        timecodeLabel.stringValue = format.string(for: t, frameDuration: timeline.geometry.frameDuration)
    }

    // MARK: Build

    private func build() {
        snapButton = makeButton(symbol: .snap, title: "Snapping", action: #selector(snapClicked))
        linkButton = makeButton(symbol: .link, title: "Linked selection", action: #selector(linkClicked))
        markerButton = makeButton(symbol: .marker, title: "Add marker", action: #selector(markerClicked))
        markerButton.setButtonType(.momentaryPushIn)
        markerButton.style = .toggle
        markerButton.contentTintColor = Theme.Colors.label2
        timecodeLabel.font = Theme.Typography.ns(11, .regular)
        timecodeLabel.textColor = Theme.Colors.label3
        timecodeLabel.alignment = .right
        timecodeLabel.isSelectable = false
        timecodeLabel.setAccessibilityLabel("Playhead timecode")
        addSubview(timecodeLabel)
        modeControl.onPick = { [weak self] in self?.modePicked($0) }
        modeControl.setAccessibilityLabel("Edit mode")
        addSubview(modeControl)
        placeClipsButton = makeButton(symbol: .columns3, title: "Place Sequences as Clips", action: #selector(placeClipsClicked))
        placeClipsButton.style = .toggle
        snapButton.style = .toggle
        linkButton.style = .toggle
        for (b, symbol, title, action) in [
            (zoomOutButton, .minus, "Zoom Out", #selector(zoomOutClicked)),
            (zoomInButton, .plus, "Zoom In", #selector(zoomInClicked)),
            (fitButton, .moveHorizontal, "Fit", #selector(fitClicked)),
        ] as [(TimelineToolSlotButton, SQIcon, String, Selector)] {
            configure(b, symbol: symbol, title: title, action: action)
            b.setButtonType(.momentaryPushIn)
            b.contentTintColor = Theme.Colors.label2
            b.style = b === fitButton ? .popup : .toggle
            addSubview(b)
        }
        fitButton.title = "Fit"
        fitButton.image = nil
        for (b, symbol, title, action) in [
            (heightShorterButton, .foldVertical, "Zoom Out Vertically", #selector(heightShorterClicked)),
            (heightTallerButton, .unfoldVertical, "Zoom In Vertically", #selector(heightTallerClicked)),
            (heightFitButton, .moveVertical, "Fit All Tracks to Height", #selector(heightFitClicked)),
        ] as [(TimelineToolSlotButton, SQIcon, String, Selector)] {
            configure(b, symbol: symbol, title: title, action: action)
            b.setButtonType(b === heightFitButton ? .pushOnPushOff : .momentaryPushIn)
            b.contentTintColor = Theme.Colors.label2
            b.style = .toggle
            addSubview(b)
        }
        refreshTips()
        syncButtons()
    }

    private func makeButton(symbol: SQIcon, title: String, action: Selector) -> TimelineToolSlotButton {
        let b = TimelineToolSlotButton(frame: .zero)
        configure(b, symbol: symbol, title: title, action: action)
        b.setButtonType(.pushOnPushOff)
        addSubview(b)
        return b
    }

    private func configure(_ b: TimelineToolSlotButton, symbol: SQIcon, title: String, action: Selector) {
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.image = Theme.symbol(symbol, size: Theme.Typography.symbolChrome, label: title)
        b.sqToolTip = title
        b.setAccessibilityLabel(title)
        b.focusRingType = .none
        b.target = self
        b.action = action
    }

    /// Name plus current key for the buttons that have a command (re-read on every state sync, so a rebinding shows).
    private func refreshTips() {
        zoomOutButton.sqToolTip = Tooltip.text("Zoom Out", command: .zoomOut)
        zoomInButton.sqToolTip = Tooltip.text("Zoom In", command: .zoomIn)
        fitButton.sqToolTip = Tooltip.text("Zoom", command: .zoomFit) + " · Fit the whole sequence."
        markerButton.sqToolTip = Tooltip.text("Add marker", command: .addMarker)
        heightShorterButton.sqToolTip = Tooltip.text("Zoom Out Vertically", command: .allTracksShorter)
        heightTallerButton.sqToolTip = Tooltip.text("Zoom In Vertically", command: .allTracksTaller)
        heightFitButton.sqToolTip = Tooltip.text("Fit All Tracks to Height", command: .toggleFitTracks)
        snapButton.sqToolTip = Tooltip.text("Snapping", command: .toggleSnapping) + " · Clips snap to edits, markers and the playhead."
        linkButton.sqToolTip = Tooltip.text("Linked selection", command: .toggleLinkedSelection) + " · Video and its audio select together."
        placeClipsButton.sqToolTip = "Place Sequences as Clips: a sequence dropped or inserted lands as its own clips, not one combined clip"
        modeControl.sqToolTip = editMode == .magnetic
            ? Tooltip.text("Fast Cut", command: .toggleMagnetic) + " · The main track closes gaps by itself; clips above and below stay attached. Click to change the mode."
            : "Normal · Classic tracks, every edit stays where you put it. Click to change the mode."
    }

    // MARK: Actions

    private func commit(_ s: ToolState) {
        guard let timeline else { toolState = s; return }
        timeline.toolState = s                      // mirrors back through onToolStateChange
        timeline.window?.makeFirstResponder(timeline)
    }

    @objc private func snapClicked() {
        var s = toolState
        s.snapping.toggle()
        commit(s)
        timeline?.onToggleChange?(s.snapping, s.linkedSelection)
    }

    @objc private func linkClicked() {
        var s = toolState
        s.linkedSelection.toggle()
        commit(s)
        timeline?.onToggleChange?(s.snapping, s.linkedSelection)
    }

    /// A row of the capsule's menu was picked. The sequence decides; the capsule follows `editMode`.
    func modePicked(_ mode: TimelineEditMode) {
        guard mode != editMode else { return }
        onEditModeRequest?(mode)
        timeline?.window?.makeFirstResponder(timeline)
    }

    @objc private func placeClipsClicked() {
        var s = toolState
        s.placeSequencesAsClips.toggle()
        commit(s)
        timeline?.onToggleChange?(s.snapping, s.linkedSelection)
    }

    @objc private func zoomOutClicked() { timeline?.zoomOut() }
    @objc private func zoomInClicked() { timeline?.zoomIn() }
    @objc private func markerClicked() {
        onAddMarker?()
        timeline?.window?.makeFirstResponder(timeline)
    }

    /// The Fit popup (v9 flat popup): Fit first, then what the bar no longer shows as buttons.
    func fitItems(map: CommandMap = .current) -> [SQMenuItem] {
        func key(_ c: EditorCommand) -> String { map.binding(for: c).map { KeyboardListing.text(for: $0) } ?? "" }
        let fits = timeline?.fitsTracks ?? false
        return [
            .header("Zoom"),
            SQMenuItem(title: "Fit Sequence", shortcut: key(.zoomFit)) { [weak self] in self?.timeline?.zoomToFit() },
            SQMenuItem(title: "Zoom In", shortcut: key(.zoomIn)) { [weak self] in self?.timeline?.zoomIn() },
            SQMenuItem(title: "Zoom Out", shortcut: key(.zoomOut)) { [weak self] in self?.timeline?.zoomOut() },
            .separator,
            .header("Track Height"),
            SQMenuItem(title: "Taller Tracks", shortcut: key(.allTracksTaller)) { [weak self] in self?.heightTallerClicked() },
            SQMenuItem(title: "Shorter Tracks", shortcut: key(.allTracksShorter)) { [weak self] in self?.heightShorterClicked() },
            SQMenuItem(title: "Fit All Tracks to Height", shortcut: key(.toggleFitTracks), isChecked: fits) { [weak self] in self?.heightFitClicked() },
            .separator,
            SQMenuItem(title: "Place Sequences as Clips", isChecked: toolState.placeSequencesAsClips,
                       help: "A sequence dropped or inserted lands as its own clips, not one combined clip") { [weak self] in self?.placeClipsClicked() },
        ]
    }

    @objc private func fitClicked() { SQContextMenu.popUp(items: fitItems(), belowTrailing: fitButton) }
    @objc private func heightShorterClicked() { timeline?.sizeTracks(nil, direction: -1) }
    @objc private func heightTallerClicked() { timeline?.sizeTracks(nil, direction: 1) }
    @objc private func heightFitClicked() { timeline?.setFitsTracks(!(timeline?.fitsTracks ?? false)) }

    // MARK: Sync and layout

    /// Snap / Linked Selection on = accent glyph, off = dim glyph, no fill.
    private func syncButtons() {
        refreshTips()
        for (b, on, name) in [(snapButton, toolState.snapping, "Snapping"), (linkButton, toolState.linkedSelection, "Linked selection"),
                              (placeClipsButton, toolState.placeSequencesAsClips, "Place Sequences as Clips")] {
            b.state = on ? .on : .off
            b.contentTintColor = on ? Theme.Colors.accent : Theme.Colors.label2
            b.setAccessibilityValue(on ? "on" : "off")
        }
        modeControl.mode = editMode
        let fits = timeline?.fitsTracks ?? false
        heightFitButton.state = fits ? .on : .off
        heightFitButton.contentTintColor = fits ? Theme.Colors.accent : Theme.Colors.label2
        heightFitButton.setAccessibilityValue(fits ? "on" : "off")
    }

    public override func layout() {
        super.layout()
        let f = Self.frames(width: bounds.width, height: bounds.height)
        tabsView?.frame = f.tabs
        // Not on the bar (v9 has no buttons for them): rows of the Fit popup.
        for v in [placeClipsButton, zoomOutButton, zoomInButton, heightShorterButton, heightTallerButton, heightFitButton] as [NSView] { v.isHidden = true }
        let th = timecodeLabel.intrinsicContentSize.height
        timecodeLabel.frame = CGRect(x: f.timecode.minX, y: ((f.timecode.height - th) / 2 + f.timecode.minY).rounded(),
                                     width: f.timecode.width, height: th)
        snapButton.frame = f.snap; linkButton.frame = f.link; markerButton.frame = f.marker
        modeControl.frame = f.editMode; fitButton.frame = f.fit
    }

    public override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.panel.setFill()
        bounds.fill()
        Theme.Colors.separator.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

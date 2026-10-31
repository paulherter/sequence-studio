import Foundation
import SQAudioFX
import SQCore
import SQDrawKit
import SQEditorSession
import SQUIKit

/// The Program / Source monitor on the shared toolkit: MonitorPanelView translated to the canvas. The state, menus and
/// command routing are the Mac `MonitorPanelModel` (the host wires its callbacks exactly as App/Sources/EditorPanels.swift
/// does); this class only lays out, draws and turns pointer events into model calls. Header: title, content popup (the
/// sequence or the Source clip), Platform Safe Zone while one is on, Zoom, Playback Quality and the "..." monitor menu.
/// Picture: zoomed and panned through `MonitorViewMapping` (wheel pans, Ctrl / Alt + wheel zooms about the pointer, as
/// the Mac trackpad), safe margins, aspect frame, platform zone, rulers and guides, drop dot and resolution badge.
/// Footer: `MonitorFooter`. Coordinates: window points; events arrive in pixels.
@MainActor
public final class MonitorPanel {
    public let model: MonitorPanelModel
    public var theme = DrawTheme()
    /// "Program" / "Source": the header title (the Mac tab strip's label).
    public var title: String
    /// Card in window points.
    public private(set) var frame: CGRect = .zero
    public private(set) var scale: Float = 1
    /// Picture size in pixels (the sequence format, or the Source clip): aspect and zoom percentages.
    public var sequenceSize = CGSize(width: 1920, height: 1080) { didSet { layerOverlay.sequenceSize = sequenceSize } }
    /// The host has a decoded frame bound to the video quad.
    public var hasPicture = false
    /// The bound picture keeps its alpha (a transparent composite, blended over what lies under the video quad): the
    /// Transparency Grid option shows a checkerboard behind it. Off while the host's picture is opaque: Windows lays
    /// the composite over the checker on the GPU (WinCompositor `transparent`), so it leaves this off.
    public var pictureHasAlpha = false
    /// A Slip drag runs: the two-up (first and last frame of the slipped clip) instead of the picture.
    public var slipTwoUp: SlipTwoUpPicture?
    /// Platform UI zone (frame fractions) and its UI mock: the host computes them from the model's `safeZone`.
    public var platformZone: NormRect?
    public var platformMock: [PlatformUIMock.Element] = []
    /// Popups and right-click menus: rows, the control (or point) they open from in window points, and the pointer for a
    /// right click. The host opens them in the shell's one menu system.
    public var onMenu: ((_ items: [SQMenuItem], _ anchor: CGRect, _ pointer: CGPoint?) -> Void)?
    /// A wheel zoom or pan changed the shown zoom (the Mac `onZoomGesture`).
    public var onZoomGesture: ((ViewerZoom) -> Void)?
    /// Transform box, Crop handles and motion path of the selected clip (Program monitor; the host fills it).
    public let overlay = TransformOverlay()
    /// The layers of the selected graphic (text, shapes): picked, boxed and moved one by one, above the clip's box.
    public let layerOverlay = GraphicsLayerOverlay()
    /// A click on the picture that no overlay or guide took (ProgramSurfaceView's Select tool `onPickClip`): the position
    /// in sequence px from the canvas center; the host selects the topmost clip there (`TextHitTest.topmostVisualClip`).
    public var onPickClip: ((Vec2) -> Void)?
    /// Where the pointer rests on the picture (sequence px from the canvas center), nil beside it: the host previews the
    /// Magic tool's object on the clip under it.
    public private(set) var pointerSequencePosition: Vec2?
    private var lastPointer: CGPoint?
    /// The overlay learned of a pointer that has not moved since (a layer that appeared under it): it hears the position again.
    public func repeatPointerOverlay() {
        if let p = lastPointer, !overlay.isDragging { overlay.pointerMoved(p, canvasRect: canvasRect) }
    }
    /// Program | Source tabs in the header instead of the title (empty = the title); `selectedTab` is this panel's.
    public var tabs: [String] = []
    public var selectedTab = 0
    public var onSelectTab: ((Int) -> Void)?
    var tabRects: [CGRect] = []
    /// A press on the Source waveform view is scrubbing.
    var pressInWave = false
    /// Source monitor drag of the picture or a stream handle onto the timeline (MonitorPanel+SourceDrag.swift): streams,
    /// phase and the pointer in window pixels. Nil: the Source picture is not a drag source.
    public var onSourceDrag: ((_ streams: SourceStreams, _ phase: MonitorDragPhase, _ x: Float, _ y: Float) -> Void)?
    var sourceDrag: SourceDragState?
    /// The Source player's meter feed for audio-only media (SourceWaveformView.meterReading); nil: no meter column.
    public var waveMeterReading: (() -> (source: ObjectIdentifier, sequence: Int, peaks: [Float])?)?
    public var waveMeter = SourceWaveMeter()
    /// Solo / Mute from the waveform meter's labels: the host hands it to the Source player's output.
    public var onWaveChannelMonitorChange: ((ChannelMonitor) -> Void)?
    /// The on-canvas text field (MonitorPanel+Text.swift) and the Type tool's click / drag-out on the picture.
    public let textField = MonitorTextField()
    public var typeToolOn: () -> Bool = { false }
    public var onTypeClick: ((Vec2) -> Void)?
    public var onTypeBox: ((_ center: Vec2, _ size: Vec2) -> Void)?
    /// A double-click on the picture (Select tool): the host edits the text under it.
    public var onTextDoubleClick: ((Vec2) -> Void)?
    var typePress: (start: CGPoint, now: CGPoint)?
    /// Hand tool (ProgramSurfaceView `.hand`): a drag pans the shown picture, a double-click fits it. `handLast` is the
    /// pointer of the running pan.
    public var handToolOn: () -> Bool = { false }
    var handLast: CGPoint?
    var lastPress: (time: Double, p: CGPoint)?
    public var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Create tool on the picture (MonitorPanel+PictureTools.swift): the mode now (nil = not the Create tool) and what a
    /// drag makes, in sequence px from the canvas center (ProgramSurfaceView `onCreateShape` / `onCreateStroke`).
    public var createModeNow: () -> CreateToolMode? = { nil }
    public var onCreateShape: ((ShapeKind, Vec2, Vec2) -> Void)?
    public var onCreateStroke: ((_ points: [Vec2], _ tolerance: Double) -> Void)?
    var createDrag: CreateToolDrag?
    /// Captions on the picture (Select tool): hit test, press (true = the host selected it), drag by a sequence px delta
    /// with a snap distance (0 = off, Alt) returning the guides to show, release, double-click to edit.
    public var captionHitTest: ((Vec2) -> Bool)?
    public var onCaptionDragBegan: ((Vec2) -> Bool)?
    public var onCaptionDragMoved: ((Vec2, Double) -> SnapGuides.Result)?
    public var onCaptionDragEnded: (() -> Void)?
    public var onCaptionDoubleClick: ((Vec2) -> Void)?
    var captionPress: (start: CGPoint, moved: Bool, guides: SnapGuides.Result)?
    /// Dynamic Zoom editor and Color Step window over the picture (the host sets and clears them).
    public var zoomEdit: ZoomEditOverlay?
    public var stepWindowEdit: StepWindowOverlay?
    /// The angle tile under the pointer in the multi-angle Source view.
    var angleHover: Int?

    /// The zoom the picture is shown at: the popup's value, or the last wheel / pinch value.
    public private(set) var viewerZoom: ViewerZoom = .fit
    private var shownModelZoom: MonitorZoom = .fit
    public private(set) var footer = MonitorFooter()
    public private(set) var headerRect: CGRect = .zero
    /// The viewer slot (picture area inside the 12 pt margin at Fit) and the picture in it.
    public private(set) var slot: CGRect = .zero
    public private(set) var canvasRect: CGRect = .zero

    public enum HeaderControl: Hashable, Sendable { case content, zone, zoom, quality, options }
    /// Header popups in drawing order (laid out while drawing: their widths come from the glyphs).
    public private(set) var headerControls: [(HeaderControl, CGRect)] = []
    private var hoveredControl: HeaderControl?
    /// Press in progress: the footer (scrub, grips, buttons) or a guide.
    private var pressInFooter = false
    /// The rejected-timecode hint (the Mac `SQToast` over the monitor); the host shows it in its status line.
    public var onHint: ((String) -> Void)?
    /// Program loudness readout (bottom left of the picture, the Mac `loudnessLabel`): short-term and integrated LUFS while
    /// the engine measures; the host sets the provider on the Program monitor only.
    public var loudnessProvider: (() -> LoudnessReading?)?
    public var loudnessTargetProvider: (() -> LoudnessTarget)?
    /// Project items dragged over the monitor (the Mac panel's drop highlight): a focus ring and a tint; the Program monitor
    /// also names the half under the pointer (Insert left, Overwrite right). The host sets both from its drag callbacks.
    public var dropHighlight = false
    public var dropZone: MonitorDropZone?
    /// The "New Sequence..." button of the empty Program monitor (laid out while drawing, like the header popups).
    public private(set) var newSequenceRect: CGRect = .zero
    /// Draws Pip into the Program empty state (the Mac `SQMascotPlace.programEmpty`); the host owns the animation (SQDrawShell).
    public var emptyMascot: ((inout Canvas, CGRect) -> Void)?
    /// The monitor has keyboard focus: its header line turns accent (the Mac `PanelContainerView.isFocused`).
    public var isFocused = false
    public static let activeLineThickness: CGFloat = 2
    /// `PanelActiveMarker.lineFrame(in:headerHeight:)`: inset `sm` each side, the header's bottom 2 pt.
    public static func activeLineRect(header: CGRect) -> CGRect {
        let inset = CGFloat(DrawTheme.Spacing.sm)
        return CGRect(x: header.minX + inset, y: header.maxY - activeLineThickness, width: max(header.width - 2 * inset, 0), height: activeLineThickness)
    }
    /// Where the last draw put Pip (zero when none).
    public private(set) var emptyMascotRect: CGRect = .zero
    /// `SQMascotPlace.programEmpty.side`.
    public static let emptyMascotSide: CGFloat = 72
    private var newSequenceHover = false
    private var newSequencePressed = false
    /// Caret offsets of the open timecode field as last drawn (the canvas measures glyphs only while drawing).
    var timecodeCarets: [CGFloat] = []
    var activeGuide: (axis: MonitorGuides.Axis, index: Int)?

    public init(model: MonitorPanelModel, title: String? = nil) {
        self.model = model
        self.title = title ?? (model.mode == .program ? "Program" : "Source")
    }

    public var isDragging: Bool { pressInFooter || pressInWave || activeGuide != nil || overlay.isDragging || layerOverlay.isDragging || handLast != nil || sourceDrag != nil || typePress != nil || pictureToolDragging }

    // MARK: Layout

    static let headerHeight = CGFloat(DrawTheme.Metrics.monitorHeader)
    static let footerHeight = CGFloat(DrawTheme.Metrics.monitorFooter)
    /// MonitorPanelView.viewerMargin: 12 pt around the picture at Fit, none once zoomed.
    public static func viewerMargin(for zoom: ViewerZoom) -> CGFloat { zoom.isFit ? CGFloat(DrawTheme.Spacing.md) : 0 }

    /// Lays the card out in `r` (pixels, as the screen hands out its rects).
    public func layout(_ r: DrawRect, scale: Float) {
        self.scale = max(scale, 0.01)
        let k = CGFloat(self.scale)
        frame = CGRect(x: CGFloat(r.x) / k, y: CGFloat(r.y) / k, width: CGFloat(r.w) / k, height: CGFloat(r.h) / k)
        if model.zoom != shownModelZoom {                // the popup (or a key) picked a zoom
            shownModelZoom = model.zoom
            viewerZoom = Self.viewerZoom(for: model.zoom)
        }
        headerRect = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Self.headerHeight)
        let footerRect = CGRect(x: frame.minX, y: frame.maxY - Self.footerHeight, width: frame.width, height: Self.footerHeight)
        let pic = CGRect(x: frame.minX, y: headerRect.maxY, width: frame.width, height: max(0, footerRect.minY - headerRect.maxY))
        let m = Self.viewerMargin(for: viewerZoom)
        slot = pic.insetBy(dx: min(m, pic.width / 2), dy: min(m, pic.height / 2))
        canvasRect = mapping.canvasRect.offsetBy(dx: slot.minX, dy: slot.minY)
        footer.layout(footerRect, footerState, durationWidth: 0)
    }

    /// The picture placement for the slot (the Mac `MonitorViewMapping` of the surface).
    public var mapping: MonitorViewMapping {
        MonitorViewMapping(viewSize: slot.size, backingScale: CGFloat(scale), sequenceSize: sequenceSize, zoom: viewerZoom)
    }

    /// The popup's zoom as the presenter's (EditorPanels `onZoomChange`).
    public static func viewerZoom(for z: MonitorZoom) -> ViewerZoom {
        switch z {
        case .fit: .fit
        case .percent(let p), .custom(let p): .percent(p)
        }
    }

    /// The footer's state from the model (the fields the host keeps current).
    public var footerState: MonitorFooterState {
        var f = MonitorFooterState(mode: model.mode, frameDuration: model.frameDuration, dropFrame: model.dropFrame)
        f.currentTime = model.currentTime
        f.duration = model.duration
        f.markIn = model.markIn
        f.markOut = model.markOut
        f.markerTimes = model.markerTimes
        f.isPlaying = model.isPlaying
        f.marksEditable = model.marksEditable
        f.sourceFileView = model.sourceFileView
        return f
    }

    /// Program with nothing to show, or Source with no clip: the empty state instead of the picture.
    public var emptyText: (title: String?, hint: String)? {
        if model.mode == .program {
            let k = model.programEmptyState
            return k == .none ? nil : (nil, k.hint)
        }
        return model.sourceItems.isEmpty ? ("No clip in Source", "Double-click a clip in the Project panel, or drag it here") : nil
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme
        c.fill(roundedRect: frame, radius: CGFloat(DrawTheme.Radius.panel), t.panel)
        drawHeader(&c)
        // The Mac `pic` view (header to footer, edge to edge) carries the backdrop too: the picture margin is not panel colored.
        c.fill(CGRect(x: frame.minX, y: headerRect.maxY, width: frame.width, height: max(0, footer.frame.minY - headerRect.maxY)), t.monitorBackdrop)
        c.saveGState()
        c.clip(to: slot)
        c.fill(slot, t.monitorBackdrop)
        newSequenceRect = .zero
        emptyMascotRect = .zero
        if showsAnglesGrid {
            drawAnglesGrid(&c)
        } else if let empty = emptyText, let title = empty.title {
            // Source with no clip: the Mac `EmptyStateView` (15 pt semibold title, body hint).
            c.drawEmptyState(title: SQL10n.string(title), hint: SQL10n.string(empty.hint), in: slot, theme: t)
        } else if let empty = emptyText {
            // ProgramEmptyView: Pip (72 pt, the host draws him), 14 pt gap, the hint, 14 pt gap, the button, centered as one stack.
            let showsPip = model.mode == .program && emptyMascot != nil
            var y = slot.midY - (empty.title == nil ? 8 : 18)
            emptyMascotRect = .zero
            if showsPip {
                let lineCount = c.wrap(empty.hint, width: min(220, slot.width - 48), fontSize: 11).count
                let button = model.programEmptyState == .noSequence && model.onNewSequence != nil
                let total = Self.emptyMascotSide + 14 + CGFloat(lineCount) * 16 + (button ? 14 + 24 : 0)
                let top = (slot.midY - total / 2).rounded()
                emptyMascotRect = CGRect(x: (slot.midX - Self.emptyMascotSide / 2).rounded(), y: max(top, slot.minY + 4),
                                         width: Self.emptyMascotSide, height: Self.emptyMascotSide)
                emptyMascot?(&c, emptyMascotRect)
                y = emptyMascotRect.maxY + 14
            }
            if let title = empty.title {
                c.draw(title, in: CGRect(x: slot.minX, y: y, width: slot.width, height: 18), fontSize: 13, t.label2, align: .center)
                y += 20
            }
            let lines = c.wrap(empty.hint, width: min(220, slot.width - 48), fontSize: 11)
            for line in lines {
                c.draw(line, in: CGRect(x: slot.minX, y: y, width: slot.width, height: 16), fontSize: 11, t.label3, align: .center)
                y += 16
            }
            // ProgramEmptyView: the large "New Sequence..." button under the hint while no sequence is open.
            if model.mode == .program, model.programEmptyState == .noSequence, model.onNewSequence != nil {
                let title = "New Sequence…", w = InspectorDraw.buttonWidth(c, title: title)
                newSequenceRect = CGRect(x: (slot.midX - w / 2).rounded(), y: y + 14, width: w, height: 24)
                InspectorDraw.button(&c, title: title, in: newSequenceRect, hovering: newSequenceHover, pressed: newSequencePressed,
                                        enabled: true, height: 24, t)
            }
        } else if showsWaveform {
            drawWaveform(&c)
            drawWaveMeter(&c)
        } else if let two = slipTwoUp {
            drawSlipTwoUp(&c, two)
        } else {
            // Offline media: the Mac monitor shows its gray backdrop under the card, not a black frame.
            if showsCheckerboard { drawCheckerboard(&c, canvasRect) } else if model.offlineFileName == nil { c.fill(canvasRect, .black) }
            if hasPicture { c.list.video(c.px(canvasRect)) }
            if !model.overlaysHidden { drawOverlays(&c, in: canvasRect) }
            overlay.draw(&c, canvasRect: canvasRect, theme: t)
            layerOverlay.draw(&c, canvasRect: canvasRect, theme: t)
            drawTextTools(&c)
            drawPictureTools(&c)
            drawOfflineCard(&c)
            drawBadges(&c)
        }
        c.restoreGState()
        drawDropTarget(&c)
        let st = footerState
        var f = footer
        f.layout(footer.frame, st, durationWidth: c.size(of: st.footerDurationText, fontSize: 12).width)
        f.draw(&c, st, theme: t)
        if let e = footer.timecodeEdit {
            let semibold = c.semibold
            timecodeCarets = MonitorFooter.timecodeCarets(e.string) { c.size(of: $0, fontSize: 12, face: semibold).width }
        }
    }

    /// v9 header: title, the content popup, then at the right the zone (while on), Zoom, Quality and "...". Flat popups:
    /// text and chevron, a fill only on hover.
    private func drawHeader(_ c: inout Canvas) {
        let t = theme
        let body: CGFloat = 11, box: CGFloat = 24, pad = CGFloat(DrawTheme.Spacing.md)
        let midY = headerRect.midY
        // The active mark of a panel with a header of its own (`PanelFocusRule`, `PanelActiveMarker.lineFrame`): the 2 pt line at the
        // header's bottom, accent while the monitor has focus, quiet gray otherwise.
        // With Program | Source tabs the header is the dock's tab strip (`ShellDock.draw`): a 1 pt separator and the line only
        // under the selected tab, drawn by `drawTitleOrTabs`.
        if tabs.isEmpty {
            c.fill(roundedRect: Self.activeLineRect(header: headerRect), radius: Self.activeLineThickness / 2, isFocused ? t.accent : t.label3)
        } else {
            c.fill(CGRect(x: headerRect.minX, y: headerRect.maxY - 1, width: headerRect.width, height: 1), t.separator)
        }
        let titleW = drawTitleOrTabs(&c, x: headerRect.minX + pad, fontSize: body)
        headerControls = []
        func popupWidth(_ s: String) -> CGFloat { (c.size(of: s, fontSize: body).width + 8 + 10 + 8 + 4).rounded(.up) }
        var right = headerRect.maxX - pad
        var controls: [(HeaderControl, CGRect, String?)] = []
        right -= box
        controls.append((.options, CGRect(x: right, y: midY - box / 2, width: box, height: box), nil))
        let showsTools = model.mode == .source ? model.viewerMode != .waveform : model.hasSequence
        if showsTools {
            for (ctl, text) in [(HeaderControl.quality, model.qualityBadgeText), (.zoom, model.badgeText)] {
                let w = popupWidth(text)
                right -= w + CGFloat(DrawTheme.Spacing.xs)
                controls.append((ctl, CGRect(x: right, y: midY - box / 2, width: w, height: box), text))
            }
        }
        if model.mode == .program, model.safeZone != .off {
            let text = model.safeZone.badgeTitle, w = popupWidth(text)
            right -= w + CGFloat(DrawTheme.Spacing.xs)
            controls.append((.zone, CGRect(x: right, y: midY - box / 2, width: w, height: box), text))
        }
        let contentText: String? = model.mode == .source
            ? MonitorMenus.sourceTitle(model.sourceItems, current: model.sourceCurrent)
            : (model.hasSequence ? MonitorMenus.sequenceTitle(model.sequenceItems, current: model.sequenceCurrent,
                                                              fallback: model.sequenceName) : nil)
        if let text = contentText {
            // The Mac strip lays the content popup right-aligned, next to Zoom and Quality (not after the tabs).
            let minX = headerRect.minX + pad + titleW + CGFloat(DrawTheme.Spacing.sm)
            let w = min(popupWidth(text), max(56, right - CGFloat(DrawTheme.Spacing.xs) - minX))
            if w >= min(40, popupWidth(text)) { controls.append((.content, CGRect(x: right - CGFloat(DrawTheme.Spacing.xs) - w, y: midY - box / 2, width: w, height: box), text)) }
        }
        for (ctl, r, text) in controls {
            headerControls.append((ctl, r))
            if hoveredControl == ctl { c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
            guard let text else {
                c.draw(icon: .ellipsis, at: CGPoint(x: r.midX - 7, y: r.midY - 7), size: 14, t.label2)
                continue
            }
            let enabled = ctl != .content || model.mode == .program || !model.sourceItems.isEmpty
            c.saveGState()
            c.clip(to: CGRect(x: r.minX, y: r.minY, width: r.width - 18, height: r.height))
            c.draw(text, in: r, fontSize: body, enabled ? t.label : t.label3, inset: 8)
            c.restoreGState()
            c.draw(icon: .chevronDown, at: CGPoint(x: r.maxX - 8 - 10, y: r.midY - 5), size: 10, t.label3)
        }
    }

    /// The "Media offline" card (AppKit `MonitorPanelView.offlineCard`): centered on the slot, HUD fill, 12 pt title over
    /// the 10 pt "<file> was moved or renamed", 16 pt side and 6 pt top/bottom padding, at most the slot less 16 pt a side.
    /// nil while the model names no offline file.
    public func offlineCardRect(titleWidth: CGFloat, detailWidth: CGFloat) -> CGRect? {
        guard model.offlineFileName != nil else { return nil }
        let side = CGFloat(DrawTheme.Spacing.lg), w = min(max(titleWidth, detailWidth) + side * 2, slot.width - side * 2)
        let h = Self.offlineCardHeight
        return CGRect(x: (slot.midX - w / 2).rounded(), y: (slot.midY - h / 2).rounded(), width: w, height: h)
    }

    /// 6 + 15 (12 pt line) + 4 + 13 (10 pt line) + 6.
    static let offlineCardHeight: CGFloat = 44

    private func drawOfflineCard(_ c: inout Canvas) {
        let t = theme, title = model.offlineCardTitle, detail = model.offlineCardDetail ?? ""
        let dw = c.size(of: detail, fontSize: 10).width
        guard let r = offlineCardRect(titleWidth: c.size(of: title, fontSize: 12, face: c.semibold).width, detailWidth: dw) else { return }
        c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), t.viewerHUD)
        let side = CGFloat(DrawTheme.Spacing.lg), inner = r.insetBy(dx: side, dy: 0)
        c.draw(title, in: CGRect(x: inner.minX, y: r.minY + 6, width: inner.width, height: 15), fontSize: 12, t.label, align: .center,
               face: c.semibold)
        c.saveGState()
        c.clip(to: inner)
        // shortcut: a too long detail is cut at the card's right edge instead of truncated in the middle; add middle
        // truncation to Canvas when long file names show up in use.
        c.draw(detail, in: CGRect(x: inner.minX, y: r.minY + 25, width: inner.width, height: 13), fontSize: 10, t.label2,
               align: dw > inner.width ? .left : .center)
        c.restoreGState()
    }

    /// MonitorPanelView.setDropHighlight / showDropZone: drop tint and focus ring over the card, and the Program half under
    /// the pointer with its action name.
    private func drawDropTarget(_ c: inout Canvas) {
        guard dropHighlight else { return }
        let t = theme
        c.fill(frame, t.accent.alpha(0.10))
        if model.mode == .program, let zone = dropZone {
            let r = zone.rect(in: frame.size).offsetBy(dx: frame.minX, dy: frame.minY)
            c.fill(r, t.accent.alpha(0.10))
            c.draw(zone.title, in: r, fontSize: 11, t.label, align: .center)
        }
        c.stroke(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), radius: CGFloat(DrawTheme.Radius.panel), width: 1, t.accent.alpha(0.55))
    }

    /// Drop dot (bottom left), loudness readout, scrub latency (top left) and resolution badge (bottom right) on the slot.
    private func drawBadges(_ c: inout Canvas) {
        let t = theme
        let inset = CGFloat(DrawTheme.Spacing.sm)
        let h14: CGFloat = 14
        if let latency = model.latencyText {
            let s = " \(latency) ", w = c.size(of: s, fontSize: 10).width
            let r = CGRect(x: slot.minX + 10, y: slot.minY + 10, width: w, height: h14)
            c.fill(r, t.viewerHUD)
            c.draw(s, in: r, fontSize: 10, t.label2)
        }
        if let reading = loudnessProvider?(), let text = LoudnessReadout.text(reading) {
            let over = LoudnessReadout.isOver(reading, target: loudnessTargetProvider?() ?? .default)
            let s = " \(text) ", w = c.size(of: s, fontSize: 10).width
            // The Mac label shares the corner with the drop dot; here it sits right of the dot so both stay readable.
            let dot: CGFloat = model.mode == .program && model.dropIndicatorEnabled ? 14 + 4 : 0
            let r = CGRect(x: slot.minX + inset + dot, y: slot.maxY - inset - h14, width: w, height: h14)
            c.fill(r, t.viewerHUD)
            c.draw(s, in: r, fontSize: 10, over ? t.yellow : t.label2)
        }
        if model.mode == .program, model.dropIndicatorEnabled {
            let size: CGFloat = 14, d: CGFloat = 6
            let o = CGPoint(x: slot.minX + inset, y: slot.maxY - inset - size)
            let warning = Self.color(t.palette.warning)
            c.fill(ellipseIn: CGRect(x: o.x + (size - d) / 2, y: o.y + (size - d) / 2, width: d, height: d),
                   model.dropAmber || model.dropRealtimeNotAchieved ? warning : t.label3.alpha(0.5))
            if let text = model.dropBadgeText {
                c.draw(text, in: CGRect(x: o.x + size, y: o.y, width: 200, height: size), fontSize: 10,
                       model.dropRealtimeNotAchieved ? warning : t.label2)
            }
        }
        if let text = model.resolutionBadgeText {
            let s = " \(text) ", w = c.size(of: s, fontSize: 10).width, h: CGFloat = 14
            let r = CGRect(x: slot.maxX - inset - w, y: slot.maxY - inset - h, width: w, height: h)
            c.fill(r, t.viewerHUD)
            c.draw(s, in: r, fontSize: 10, t.label2)
        }
    }

    /// The Transparency Grid behind a picture with alpha (Program monitor option).
    public var showsCheckerboard: Bool { model.mode == .program && model.showsTransparencyGrid && pictureHasAlpha }

    /// 8 pt squares over `r` in the color picker's checker grays (`Theme.Palette.checker`).
    func drawCheckerboard(_ c: inout Canvas, _ r: CGRect) {
        let cell: CGFloat = 8
        c.fill(r, DrawColor(0.30, 0.30, 0.30))
        c.saveGState()
        c.clip(to: r)
        var y = r.minY, row = 0
        while y < r.maxY {
            var x = r.minX + (row % 2 == 0 ? cell : 0)
            while x < r.maxX { c.fill(CGRect(x: x, y: y, width: cell, height: cell), DrawColor(0.45, 0.45, 0.45)); x += cell * 2 }
            y += cell; row += 1
        }
        c.restoreGState()
    }

    static func color(_ p: PaletteColor) -> DrawColor {
        DrawColor(Float(p.r) / 255, Float(p.g) / 255, Float(p.b) / 255, Float(p.a))
    }

    // MARK: Input

    /// True when the event was the monitor's. Moves are never kept (other panels clear their hover).
    public func handle(_ e: InputEvent) -> Bool {
        let k = CGFloat(scale)
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k) }
        switch e {
        case .mouseDown(let x, let y, let mods):
            let p = pt(x, y)
            guard frame.contains(p) else { return false }
            let right = mods.contains(.secondary)
            if !right, newSequenceRect.contains(p) { newSequencePressed = true; return true }
            if !right, let h = footer.streamHandle(at: p), beginSourceDragPress(h, at: p) { return true }
            if footer.frame.contains(p) {
                pressInFooter = !right
                let carets = timecodeCarets
                apply(footer.mouseDown(p, footerState, right: right) { MonitorFooter.caretIndex(at: $0, carets: carets) })
                return true
            }
            if !right, let i = tab(at: p) {
                if i != selectedTab { onSelectTab?(i) }
                return true
            }
            if let (ctl, r) = headerControls.first(where: { $0.1.contains(p) }) {
                if !right { openHeader(ctl, r) }
                return true
            }
            if slot.contains(p) {
                if right {
                    if let items = model.contextMenuBuilder?(), !items.isEmpty { onMenu?(items, CGRect(origin: p, size: .zero), p) }
                } else if showsWaveform {
                    let mr = waveMeterRect
                    if mr.contains(p) {
                        if waveMeter.click(CGPoint(x: p.x - mr.minX, y: p.y - mr.minY), height: mr.height, alt: mods.contains(.option)) {
                            onWaveChannelMonitorChange?(waveMeter.channelMonitor)
                        }
                        return true
                    }
                    pressInWave = true
                    scrubWaveform(began: true, at: p)
                } else if model.mode == .program, handToolOn() {
                    beginHandPress(at: p)
                    if handLast != nil { HostHover.current.request(.closedHand) }
                } else if textField.isEditing, textField.mouseDown(p, modifiers: mods, canvasRect: canvasRect) {
                    // the caret moved inside the open text field (a press outside ended it and goes on below)
                } else if beginPictureToolPress(at: p, modifiers: mods) {
                    // Dynamic Zoom / Step window editor, the angle tiles, the Create tool or a caption took it
                } else if guideTarget(at: p) != nil {
                    beginGuideDrag(at: p)            // rulers and guides first, then the transform box, then the picture
                } else if model.mode == .source, beginSourceDragPress(.both, at: p) {
                    // the Source picture is the Video and Audio drag source (StreamDragView over the viewer)
                } else if beginTextPress(at: p) {
                    // Type tool press, or the second press of a double-click on the picture
                } else if overlay.maskTool == nil, !textField.isEditing, layerOverlay.mouseDown(p, modifiers: mods, canvasRect: canvasRect) {
                    // a layer of the selected graphic, its handle, or the empty canvas while layers are selected
                } else if !overlay.mouseDown(p, modifiers: mods, canvasRect: canvasRect),
                          let pos = mapping.clickPosition(CGPoint(x: p.x - slot.minX, y: p.y - slot.minY)) {
                    onPickClip?(pos)
                }
                requestDragCursor()
            }
            return true
        case .mouseDragged(let x, let y):
            let p = pt(x, y)
            if pictureToolDragging { pictureToolDragged(p); requestDragCursor(); return true }
            if overlay.isDragging { overlay.mouseDragged(p); requestDragCursor(); return true }
            if let last = handLast { handLast = p; HostHover.current.request(.closedHand); zoomGesture(mapping.panned(byViewDelta: CGSize(width: p.x - last.x, height: p.y - last.y))); return true }
            if layerOverlay.isDragging { layerOverlay.mouseDragged(p, modifiers: overlay.modifiersNow?()); requestDragCursor(); return true }
            if sourceDrag != nil { sourceDragMoved(p, x: x, y: y); return true }
            if typePress != nil { typePress?.now = p; return true }
            if pressInWave { scrubWaveform(began: false, at: p); return true }
            if activeGuide != nil { dragGuide(to: p); return true }
            guard pressInFooter else { return false }
            apply(footer.mouseDragged(p, footerState))
            return true
        case .mouseUp(let x, let y):
            let p = pt(x, y)
            defer { requestHoverCursor(at: p) }
            if newSequencePressed {
                newSequencePressed = false
                if newSequenceRect.contains(p) { model.onNewSequence?() }
                return true
            }
            if pictureToolDragging { pictureToolEnded(p); return true }
            if overlay.isDragging { overlay.mouseUp(p); return true }
            if handLast != nil { handLast = nil; return true }
            if layerOverlay.isDragging { layerOverlay.mouseUp(p); return true }
            if sourceDrag != nil { sourceDragEnded(x: x, y: y); return true }
            if typePress != nil { endTypePress(at: p); return true }
            if pressInWave { pressInWave = false; model.onScrubEnded?(); return true }
            if activeGuide != nil { endGuideDrag(at: p); return true }
            guard pressInFooter else { return false }
            pressInFooter = false
            apply(footer.mouseUp(p, footerState))
            return true
        case .mouseMoved(let x, let y):
            let p = pt(x, y)
            footer.mouseMoved(p)
            newSequenceHover = newSequenceRect.contains(p)
            if let a = footer.hovered, let title = a.buttonTitle(playing: model.isPlaying) { HostHover.current.offerTip(a.tip(title)) }
            hoveredControl = headerControls.first { $0.1.contains(p) }?.0
            if let ctl = hoveredControl { HostHover.current.offerTip(headerTip(ctl)) }
            angleHover = showsAnglesGrid ? AnglesGridLayout.index(at: p, cells: angleCells) : nil
            lastPointer = p
            pointerSequencePosition = slot.contains(p) ? mapping.clickPosition(CGPoint(x: p.x - slot.minX, y: p.y - slot.minY)) : nil
            if !overlay.isDragging { overlay.pointerMoved(p, canvasRect: canvasRect) }
            requestHoverCursor(at: p)
            return false
        case .scroll(let x, let y, let dx, let dy, let mods):
            let p = pt(x, y)
            guard frame.contains(p) else { return false }
            guard slot.contains(p), emptyText == nil else { return true }
            let local = CGPoint(x: p.x - slot.minX, y: p.y - slot.minY)
            // ProgramSurfaceView.scrollWheel / magnify with the AppKit deltas: a wheel line counts 8 trackpad points.
            let g = ScrollGesture.current(pixelsX: dx, pixelsY: dy)
            switch g.kind {
            case .magnify(let m): zoomGesture(mapping.zoomed(by: 1 + CGFloat(m), about: local))
            case .smartMagnify: break
            case .scroll:
                let k = g.precise ? 1.0 : 8.0
                if mods.contains(.command) || mods.contains(.option) {
                    // Cmd / Option + scroll zooms about the pointer (Ctrl / Alt on Windows).
                    zoomGesture(mapping.zoomed(by: CGFloat(exp(g.deltaY * k * 0.01)), about: local))
                } else if !viewerZoom.isFit {                // nothing to pan at Fit
                    zoomGesture(mapping.panned(byViewDelta: CGSize(width: g.deltaX * k, height: g.deltaY * k)))
                }
            }
            return true
        case .keyDown(let key, let mods):
            if textField.isEditing { return textField.key(key, modifiers: mods) }
            if let events = footer.timecodeKey(key, modifiers: mods) { apply(events); return true }
            if pictureToolKey(key, modifiers: mods) { return true }
            if key == .escape, typePress != nil { typePress = nil; return true }
            if key == .escape, activeSourceDrag != nil { sourceDragEnded(x: 0, y: 0, canceled: true); return true }
            return key == .escape && overlay.cancelDrag()
        }
    }

    /// The shape the picture asks for at `p` while no drag runs (Hand, Create, layer handles, transform box).
    func requestHoverCursor(at p: CGPoint) {
        if model.mode == .program, handToolOn(), slot.contains(p) {
            HostHover.current.request(handLast != nil ? .closedHand : .openHand)
        } else if !overlay.isDragging, !layerOverlay.isDragging, overlay.maskTool == nil, !textField.isEditing,
                  let c = layerOverlay.hoverCursor(at: p, canvasRect: canvasRect) {
            HostHover.current.request(c)
        } else if !overlay.isDragging, let c = overlay.hoverCursor(at: p, canvasRect: canvasRect) {
            HostHover.current.request(c)
        } else if model.mode == .program, slot.contains(p), let m = createModeNow(), m != .text, !overlay.isDragging {
            HostHover.current.request(.crosshair)       // Create tool: shapes, lines and strokes (resetCursorRects)
        }
    }

    /// A press or drag keeps the shape of what it holds (HostHover forgets it on every drag event).
    func requestDragCursor() {
        if overlay.isDragging { HostHover.current.request(overlay.dragCursor) }
        else if createDrag != nil { HostHover.current.request(.crosshair) }
    }

    /// A wheel zoom or pan: show it, put its value in the zoom popup without reporting it back (EditorPanels
    /// `surface.onZoomGesture`).
    public func zoomGesture(_ v: ViewerZoom) {
        viewerZoom = v
        switch v {
        case .fit: model.displayZoom(.fit)
        case .percent(let p): model.displayZoom(.percent(p))
        case .view(let s, _, _): model.displayZoom(.custom(Int((s * 100).rounded())))
        }
        shownModelZoom = model.zoom
        let m = Self.viewerMargin(for: viewerZoom)
        let pic = CGRect(x: frame.minX, y: headerRect.maxY, width: frame.width,
                         height: max(0, footer.frame.minY - headerRect.maxY))
        slot = pic.insetBy(dx: min(m, pic.width / 2), dy: min(m, pic.height / 2))
        canvasRect = mapping.canvasRect.offsetBy(dx: slot.minX, dy: slot.minY)
        onZoomGesture?(v)
    }

    /// Rows of a header popup.
    public func headerItems(_ ctl: HeaderControl) -> [SQMenuItem] {
        switch ctl {
        case .content:
            if model.mode == .source {
                return MonitorMenus.sourceItems(model.sourceItems, current: model.sourceCurrent,
                                                pick: { [weak model] id in model?.onPickSource?(id) },
                                                close: { [weak model] in model?.onCloseSource?() },
                                                closeAll: { [weak model] in model?.onCloseAllSources?() })
            }
            return MonitorMenus.sequenceItems(model.sequenceItems, current: model.sequenceCurrent,
                                              pick: { [weak model] id in model?.onPickSequence?(id) })
        case .zone: return model.safeZoneMenu()
        case .zoom: return model.zoomMenu()
        case .quality: return model.qualityMenu()
        case .options: return model.optionItems()
        }
    }

    /// Go to Timecode (the Mac `focusTimecodeField`): opens the footer's timecode with its text selected; Return
    /// commits, Esc or a press elsewhere puts the time back.
    public func focusTimecodeField() { footer.beginTimecodeEdit(footerState) }

    public var isEditingTimecode: Bool { footer.isEditingTimecode }

    /// Ends the field's edit without seeking (a press outside the monitor).
    public func endTimecodeEdit() { footer.endTimecodeEdit() }

    private func openHeader(_ ctl: HeaderControl, _ r: CGRect) {
        let items = headerItems(ctl)
        if !items.isEmpty { onMenu?(items, r, nil) }
    }

    /// Footer events as model calls (MonitorScrubBar and the transport buttons on the Mac).
    func apply(_ events: [MonitorFooterEvent]) {
        for ev in events {
            switch ev {
            case .action(let a): model.perform(a)
            case .scrubBegan: model.onScrubBegan?()
            case .scrub(let t): if let s = model.onScrub { s(t) } else { model.onSeek?(t) }
            case .scrubEnded: model.onScrubEnded?()
            case .previewMark(let h, let t): model.previewMark(h, frame: t)
            case .previewRange(let i, let o): model.previewRange(markIn: i, markOut: o)
            case .commitMark(let h): model.commitMark(h)
            case .commitRange(let part): model.commitRange(part == .newRange ? .newRange : .body)
            case .commitTimecode(let typed):
                // `MonitorPanelView.commitTimecode`: a rejected text keeps the time and shows the hint.
                if !model.commitTimecodeText(typed) {
                    let hint = MonitorPanelModel.timecodeHint(for: typed)
                    if !hint.isEmpty { onHint?(SQL10n.string(hint)) }
                }
            case .markMenu(let x, let y):
                let p = CGPoint(x: x, y: y)
                onMenu?(model.markMenu(), CGRect(origin: p, size: .zero), p)
            }
        }
    }
}

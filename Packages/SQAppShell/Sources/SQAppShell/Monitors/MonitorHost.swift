import Foundation
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQEditorSession
import SQInspectorUI
import SQText
import SQUIKit

/// The Program monitor of the shared shell (Windows app, Mac `SQ_SHARED_UI`): SQDrawMonitor's `MonitorPanel` (the Mac MonitorPanelView translated) on the
/// screen's monitor card, driven by the shared `MonitorPanelModel` and wired to the session as the Mac host wires it
/// (App/Sources/EditorPanels.swift: onAction, onMarkEdit / onRangeEdit, scrub, zoom, platform zone, program menu).
@MainActor
public final class MonitorHost {
    public let model: MonitorPanelModel
    public let panel: MonitorPanel
    public let session: EditorSession
    /// Monitor commands go through the app's routing (MonitorCardHost.applyMonitor), so keys, menus and buttons agree.
    public var onAction: ((MonitorAction) -> Void)?
    /// Shell commands from the menu (Show in Source / Show in Timeline run in the Source host).
    public var onCommand: ((EditorCommand) -> Void)?
    public var onStatus: ((String) -> Void)?
    private var isDragging = false
    /// Effect Controls' model: the overlay writes the selected clip's Motion and Crop through it (one undo step per drag).
    weak var effects: EffectControlsModel?
    /// The clip the overlay shows and the display transform at the press of the running gesture.
    private(set) var overlayTarget: OverlayTarget?
    private var overlayGesture: (target: OverlayTarget, start: ClipTransform)?
    /// A text clip's scale-handle drag (EditorPanels.textResizeStart): the template at the press, the undo depth and
    /// whether the first font-size write is still to come.
    private var textResize: (template: TextTemplate, animations: AnimationSet?, depth: Int, first: Bool)?
    /// The clip a mask handle gesture started on (nil: none open, or it was refused), EditorPanels.maskGestureClip.
    private var maskGestureClip: Clip.ID?
    /// The Mask tool's mode while the Mask tool is on (the timeline's tool state), else nil.
    public var maskToolNow: () -> MaskToolMode? = { nil }
    /// The Mask tool's Magic mode (a platform segmenter; nil: Magic clicks only tell the status line).
    public var magic: (any AppMagicMasks)?
    private var magicWasOn = false
    /// The Slip drag's two-up (the host makes it with the Program engine); drawn instead of the picture while it shows.
    public var slip: SlipTwoUpHost?
    /// Mask Tint's picture for the renderer (slot, coverage, generation); nil: no tint (MonitorHost+MaskTint.swift).
    public internal(set) var maskTint: (Int, RGBAImage, Int)?
    /// Where the Mask Tint switch lives (tests use their own suite).
    public var maskTintDefaults = UserDefaults.standard
    /// Type tool, double-click text editing and the graphic text pick (MonitorTextHost.swift).
    public private(set) lazy var text = MonitorTextHost(session: session, panel: panel)
    /// Picture tools (MonitorHost+PictureTools.swift): the running caption drag and the Dynamic Zoom editor's clip.
    var captionDrag: (id: CaptionItem.ID, start: CaptionPosition, textRect: CGRect, started: Bool)?
    var zoomEditRun: (clip: Clip.ID, ease: ZoomEase, dragging: Bool, wrote: Bool)?
    /// Re-applies the Preferences quality (set by `rememberQuality`; Preferences changes call it).
    public internal(set) var applyQuality: ((AppSettings) -> Void)?
    /// The Color page: the picture is the graded frame, no transform box, handles or masks over it (the Mac
    /// `EditorPanels.updateOverlay` on `colorPageActive`); the target stays for the Step window.
    public var hidesTransformBox = false
    /// The clip the Source monitor shows (Show in Timeline needs one, as on the Mac).
    public var sourceMediaID: () -> MediaRef.ID? = { nil }

    public init(session: EditorSession, menus: MenuController) {
        self.session = session
        let fd = session.activeTimeline?.frameDuration ?? Time(1, 25)
        model = MonitorPanelModel(frameDuration: fd, mode: .program)
        panel = MonitorPanel(model: model, title: "Program")
        model.onAction = { [weak self] a in
            guard let self else { return }
            if a == .toggleSafeMargins { model.safeMargins.toggle(); return }
            onAction?(a)
        }
        model.onSeek = { [weak session] t in session?.seek(to: t) }
        model.onScrubBegan = { [weak session] in session?.beginScrub() }
        model.onScrub = { [weak session] t in session?.scrub(to: t) }
        model.onScrubEnded = { [weak session] in session?.endScrub() }
        model.onMarkEdit = { [weak self] end, t in
            guard let self else { return }
            let fd = session.activeTimeline?.frameDuration ?? model.frameDuration
            switch end {
            case .markIn: session.setInPoint(at: t)
            case .markOut: session.setOutPoint(at: t - fd)       // the strip reports the stored end, one frame past Out
            case .playhead: break
            }
        }
        model.onRangeEdit = { [weak session] markIn, markOut, part in
            session?.moveInOut(to: TimeRange(start: markIn, end: markOut), part: part)
        }
        // Quality popup and the Auto governor's steps reach the engine (EditorPanels: engine.quality = q.decodeScale).
        model.onQualityChange = { [weak session] q in session?.engine.quality = q.decodeScale }
        model.onSafeZoneChange = { [weak self] _ in self?.syncZone() }
        model.contextMenuBuilder = { [weak self] in self?.programMenuItems() ?? [] }
        panel.onMenu = { [weak menus] items, anchor, pointer in
            guard let menus else { return }
            if let pointer { menus.present(items: items, at: pointer, pointer: pointer) }
            else { menus.present(items: items, at: CGPoint(x: anchor.minX, y: anchor.maxY), anchor: anchor) }
        }
        // The session's change hook is shared: keep whoever set it before.
        let previous = session.onChange
        session.onChange = { [weak self] change in
            previous?(change)
            if change.contains(.project) { self?.syncSequence() }
        }
        syncSequence()
    }

    /// EditorPanels' `.project` sync for the Program monitor.
    public func syncSequence() {
        let t = session.activeTimeline
        let fd = t?.frameDuration ?? model.frameDuration
        model.frameDuration = fd
        model.dropFrame = fd == Time(1001, 30000) || fd == Time(1001, 60000)
        model.duration = t?.duration ?? .zero
        model.hasSequence = t != nil
        model.timelineIsEmpty = t.map { $0.tracks.allSatisfy { $0.clips.isEmpty } && $0.captionTracks.allSatisfy { $0.items.isEmpty } } ?? false
        model.markIn = t?.inOut?.start
        model.markOut = t?.inOut?.end
        model.markerTimes = t?.markers.map(\.time) ?? []
        if let t { panel.sequenceSize = CGSize(width: t.format.displayWidth, height: t.format.height) }
        model.syncFormats(from: session)            // the header's sequence popup and the format switcher
        syncZone()
    }

    /// The platform safe zone and its UI mock for the sequence's frame (EditorPanels' zone providers).
    private func syncZone() {
        guard let t = session.activeTimeline else { panel.platformZone = nil; panel.platformMock = []; return }
        let aspect = Double(t.format.displayWidth) / Double(max(t.format.height, 1))
        panel.platformZone = model.safeZone.normRect(frameAspect: aspect)
        panel.platformMock = model.showsPlatformMock ? model.safeZone.uiMock(frameAspect: aspect) : []
    }

    /// The Program monitor's right-click menu: `EditorPanels.programMenuItems` row for row (enabled states, masks,
    /// Subject Mask Edges, Loop Playback, Zoom).
    func programMenuItems() -> [SQMenuItem] {
        let io = session.activeTimeline?.inOut != nil
        func row(_ c: EditorCommand, _ a: MonitorAction, _ enabled: Bool = true) -> SQMenuItem {
            SQMenuItem(title: c.title, shortcut: MonitorMenus.shortcut(of: a), isEnabled: enabled,
                       action: { [weak self] in self?.model.onAction?(a) })
        }
        func cmd(_ c: EditorCommand, _ enabled: Bool = true, state: Bool = false) -> SQMenuItem {
            SQMenuItem(title: c.title, shortcut: CommandMap.current.binding(for: c).map { KeyBindingText.text($0) } ?? "",
                       isEnabled: enabled, isChecked: state, action: { [weak self] in self?.onCommand?(c) })
        }
        let maskClip = effects?.clip?.kind == .video
        func mask(_ title: String, _ enabled: Bool, _ run: @escaping @MainActor (EffectControlsModel) -> Void) -> SQMenuItem {
            SQMenuItem(title: title, isEnabled: enabled, action: { [weak self] in if let fx = self?.effects { run(fx) } })
        }
        // C6: the other video tracks, nearest above first; the default is checked.
        let pictureChoices = maskClip ? (effects?.pictureTrackChoices() ?? []).filter { $0.track != nil } : []
        let pictureDefault = effects?.defaultPictureTrack
        let picture = SQMenuItem(title: "Add Picture Mask", isEnabled: !pictureChoices.isEmpty, submenu: pictureChoices.map { c in
            SQMenuItem(title: c.title, isChecked: c.track == pictureDefault) { [weak self] in _ = self?.effects?.addPictureMask(track: c.track) }
        })
        let quality = SubjectMaskQualityMenu.item { [weak self] q in
            self?.onStatus?(SQL10n.format("Subject mask edges: %@. Track the mask again to change frames that are already tracked.", SQL10n.string(q.title)))
        }
        return [
            row(.markIn, .markIn), row(.markOut, .markOut), row(.goToIn, .goToIn, io), row(.goToOut, .goToOut, io),
            row(.clearInOut, .clearInOut, io), .separator,
            row(.addMarker, .addMarker), row(.lift, .lift, io), row(.extract, .extract, io), .separator,
            cmd(.matchFrame), cmd(.reverseMatchFrame, sourceMediaID() != nil), row(.exportFrame, .exportFrame), .separator,
            mask("Add Rectangle Mask", maskClip) { _ = $0.addMask(.rectangle) },
            mask("Add Ellipse Mask", maskClip) { _ = $0.addMask(.ellipse) },
            picture,
            mask("Add Color Range Mask", maskClip) { _ = $0.addColorRangeMask() },
            cmd(.addSubjectMask, session.addSubjectMaskEnabled),
            mask("Delete Masks", maskClip && !(effects?.clip?.masks.isEmpty ?? true)) { $0.removeAllMasks() },
            .separator,
            SQMenuItem(title: "Safe Margins", isChecked: model.safeMargins, action: { [weak self] in self?.model.safeMargins.toggle() }),
            SQMenuItem(title: "Mask Tint", isChecked: showsMaskTint, action: { [weak self] in self?.showsMaskTint.toggle() }),
            quality,
            cmd(.toggleLoop, state: session.bounds.loop), .separator,
            SQMenuItem(title: "Zoom", submenu: MonitorMenus.zoomItems(current: model.zoom) { [weak self] in self?.model.setZoom($0) }),
        ]
    }

    /// Per frame: playhead and play state (the Mac host's playhead observer), then the card (pixels).
    /// `dropped`: the engine's skipped frame positions since play (drop dot and the Auto quality governor, whose steps
    /// lower the engine's picture size through `model.onQualityChange`).
    public func layout(_ card: DrawRect, scale: Float, playhead: Time, isPlaying: Bool, hasPicture: Bool, dropped: Int = 0) {
        model.currentTime = playhead
        model.isPlaying = isPlaying
        syncOverlay(isPlaying: isPlaying)
        syncMaskTint(isPlaying: isPlaying)
        refreshDynamicZoomEdit()
        text.sync()
        model.updateDrops(dropped: dropped, isPlaying: isPlaying, now: ProcessInfo.processInfo.systemUptime)
        panel.slipTwoUp = slip?.tick()
        panel.hasPicture = hasPicture
        panel.layout(card, scale: scale)
    }

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        panel.theme = theme
        panel.draw(&c)
    }

    /// Routes one event in pixels (the panel converts with its scale); true when the panel took it.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        let k = CGFloat(max(scale, 0.01))
        func inside(_ x: Float, _ y: Float) -> Bool { panel.frame.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)) }
        switch e {
        case .mouseDown(let x, let y, _): guard inside(x, y) else { return false }; isDragging = true
        case .mouseDragged: guard isDragging else { return false }
        case .mouseUp: guard isDragging else { return false }; isDragging = false
        case .mouseMoved: _ = panel.handle(e); return false      // hover also reaches the screen
        case .scroll(let x, let y, _, _, _): guard inside(x, y) else { return false }
        case .keyDown: return panel.handle(e)          // Esc cancels a running overlay drag
        }
        _ = panel.handle(e)
        return true
    }

    /// While the on-canvas text field is open: keys go to it before every panel (no shortcut runs under the caret), a
    /// press outside the monitor ends it. True when the event was taken.
    /// The footer's timecode field (Go to Timecode) is routed the same way.
    public func routeTextEditing(_ e: InputEvent, scale: Float) -> Bool {
        if panel.isEditingTimecode { return Self.routeTimecode(e, scale: scale, panel: panel) }
        guard text.isEditing else { return false }
        switch e {
        case .keyDown: return panel.handle(e)
        case .mouseDown(let x, let y, _):
            let k = CGFloat(max(scale, 0.01))
            if !panel.frame.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)) { text.pressOutside() }
            return false
        default: return false
        }
    }

    /// While a monitor's timecode field is open: keys go to it before every panel, a press outside the monitor puts
    /// the time back (the Mac field resigns and shows the time again).
    static func routeTimecode(_ e: InputEvent, scale: Float, panel: MonitorPanel) -> Bool {
        switch e {
        case .keyDown: return panel.handle(e)
        case .mouseDown(let x, let y, _):
            let k = CGFloat(max(scale, 0.01))
            if !panel.frame.contains(CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)) { panel.endTimecodeEdit() }
            return false
        default: return false
        }
    }
}

// MARK: - Transform overlay (EditorPanels.wireOverlay / updateOverlay / updateCropHandles)

extension MonitorHost {
    /// Hooks the panel's transform overlay to Effect Controls. `modifiers` reads the keys held now (drags carry none).
    public func attachOverlay(effects: EffectControlsModel, modifiers: @escaping () -> InputModifiers) {
        self.effects = effects
        let o = panel.overlay
        o.modifiersNow = modifiers
        o.onTransform = { [weak self] phase, t in self?.overlayTransform(phase, t) }
        o.onPathEdit = { [weak self] phase, edit in
            guard let self, let fx = self.effects, fx.clip?.id == overlayTarget?.clip else { return }
            switch phase {
            case .began: fx.beginGesture()
            case .changed: fx.editPositionKey(edit.key, position: edit.position, tangents: edit.tangents)
            case .ended: fx.editPositionKey(edit.key, position: edit.position, tangents: edit.tangents); fx.endGesture()
            }
        }
        o.onCrop = { [weak self] phase, edge, fraction in
            guard let self, let fx = self.effects, let target = overlayTarget, fx.clip?.id == target.clip,
                  let crop = Self.cropSection(fx) else { return }
            if phase == .began { fx.beginGesture(); return }
            _ = fx.setValue(.fx(crop, kind: ClipEffect.cropKind, key: edge.effectKey), to: fraction * 100)
            if phase == .ended { fx.endGesture() }
        }
        o.onDragCanceled = { [weak self] in
            guard let self else { return }
            self.effects?.cancelGesture()
            if let r = textResize, !r.first { session.rewindUndo(toDepth: r.depth) }   // Esc restores the font size too
            textResize = nil
            overlayGesture = nil
            maskGestureClip = nil
        }
        attachMasks(o)
        o.onPointHandle = { [weak self] phase, id, offset in self?.pointHandleDrag(phase, id, offset) }
        // Select tool click: the topmost clip under the pointer, unless a graphic's text layer lies above it.
        panel.onPickClip = { [weak self] p in
            guard let self, let tl = session.displayTimeline else { return }
            let picked = TextHitTest.topmostVisualClip(at: p, in: tl, project: session.project, time: session.playhead,
                                                       variant: session.activeVariantID)
            let track = picked.flatMap { id in tl.tracks.firstIndex { $0.clips.contains { $0.id == id } } }
            if text.pickGraphicText(at: p, above: track) { return }
            guard let picked else { return }
            session.select(clips: [picked])
        }
    }

    /// Handle id = effect id + "|" + parameter key (EditorPanels.pointProperty).
    private func pointProperty(_ id: String, in clip: Clip) -> EffectProperty? {
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let eid = UUID(uuidString: parts[0]),
              let e = clip.effects.first(where: { $0.id == eid }) else { return nil }
        return .fx(eid, kind: e.kind, key: parts[1])
    }

    /// Point parameters of the selected clip's enabled effects (EditorPanels.updatePointHandles): px from the layer
    /// center through the clip's transform; Corner Warp only while its section is selected.
    private func pointHandles(_ fx: EffectControlsModel, clip: Clip, target: OverlayTarget) -> [PointHandle] {
        var handles: [PointHandle] = []
        for e in clip.effects where e.enabled {
            for p in EffectCatalog.spec(for: e.kind)?.params ?? [] {
                guard case .point = p.kind, PointHandleMapping.hasHandle(kind: e.kind, key: p.key) else { continue }
                var v = fx.vectorValue(.fx(e.id, kind: e.kind, key: p.key))
                if PointHandleMapping.isCornerOffset(kind: e.kind) {
                    guard case .effect(let sid, _)? = fx.selectedSection, sid == e.id else { continue }
                    v = PointHandleMapping.cornerLocal(key: p.key, value: v, frame: target.size)
                }
                handles.append(PointHandle(id: "\(e.id.uuidString)|\(p.key)",
                                           offset: PointHandleMapping.offset(kind: e.kind, local: v, transform: target.displayTransform)))
            }
        }
        return handles
    }

    /// A point handle drag writes the value at the playhead, one undo step per gesture.
    private func pointHandleDrag(_ phase: TransformOverlay.Phase, _ id: String, _ offset: Vec2) {
        guard let fx = effects, let target = overlayTarget, fx.clip?.id == target.clip,
              let clip = fx.clip, let prop = pointProperty(id, in: clip) else { return }
        if phase == .began { session.stopPlayback(); fx.beginGesture(); return }
        let kind = clip.effects.first { id.hasPrefix($0.id.uuidString) }?.kind ?? ""
        var local = PointHandleMapping.local(kind: kind, offset: offset, transform: target.displayTransform)
        if PointHandleMapping.isCornerOffset(kind: kind), case .fx(_, _, let key) = prop {
            local = PointHandleMapping.cornerValue(key: key, local: local, frame: target.size)
        }
        _ = fx.setVector(prop, to: local)
        if phase == .ended { fx.endGesture() }
    }

    /// The Crop effect while its section is selected and enabled (its edge handles replace the scale handles).
    static func cropSection(_ fx: EffectControlsModel) -> ClipEffect.ID? {
        guard case .effect(let id, kind: let kind)? = fx.selectedSection, kind == ClipEffect.cropKind,
              fx.clip?.effects.first(where: { $0.id == id })?.enabled == true else { return nil }
        return id
    }

    /// The segmenter follows the overlay while Magic is on (and hears once that it went off).
    private func refreshMagic(isPlaying: Bool) {
        guard let magic else { return }
        let on = panel.overlay.maskTool == .magic
        guard on || magicWasOn else { return }
        magicWasOn = on
        magic.refresh(target: overlayTarget?.clip, magicOn: on, isPlaying: isPlaying)
    }

    /// Per frame: the selected picture clip under the playhead, as the Mac `updateOverlay` finds it (not while playing,
    /// not on a Color solo view). A running drag keeps its own live transform.
    func syncOverlay(isPlaying: Bool) {
        let o = panel.overlay
        guard !o.isDragging else { return }
        guard !isPlaying, let fx = effects, let tl = session.displayTimeline, session.colorSoloClip == nil,
              let clip = session.displayedSelectedClip, fx.clip?.id == clip.id,
              let target = OverlayTarget.make(clip: clip, project: session.project, timeline: tl, at: session.playhead,
                                              variant: session.activeVariantID) else {
            overlayTarget = nil; o.isShown = false; o.pointHandles = []; o.masks = []; o.maskTool = nil
            refreshMagic(isPlaying: isPlaying)
            return
        }
        overlayTarget = target
        if hidesTransformBox {
            o.isShown = false; o.pointHandles = []; o.masks = []; o.maskTool = nil
            refreshMagic(isPlaying: isPlaying)
            return
        }
        o.masks = fx.maskOverlays
        o.maskTool = maskToolNow()
        refreshMagic(isPlaying: isPlaying)
        o.pointHandles = pointHandles(fx, clip: clip, target: target)
        let canvas = CGSize(width: tl.format.displayWidth, height: tl.format.height)
        var others: [OverlayTarget] = []
        for c in tl.tracks.filter({ $0.kind == .video && $0.isVisible }).flatMap(\.clips) where c.id != clip.id {
            if let other = OverlayTarget.make(clip: c, project: session.project, timeline: tl, at: session.playhead,
                                              variant: session.activeVariantID) { others.append(other) }
        }
        let areas: [SafeArea] = model.safeMargins ? [.action, .title] : []
        let zone = model.safeZone.offsetRect(canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height))
        o.isShown = true
        o.sequenceSize = canvas
        o.mediaPixelSize = target.size
        o.transform = target.displayTransform
        o.positionTrack = target.positionTrack
        o.selectedKey = fx.selectedKeyIDs(.position).first
        o.uniformScale = fx.uniformScale
        o.neighborBounds = SnapGuides.otherBounds(others)
        o.snapTargets = SnapGuides.targets(canvas: canvas, others: o.neighborBounds, safeAreas: areas, zone: zone)
        // Safe Margins already draws the 90 / 80 % frames over the picture; the overlay does not draw them twice.
        o.safeAreas = []
        if let crop = Self.cropSection(fx) {
            func v(_ key: String) -> Double { fx.scalarValue(.fx(crop, kind: ClipEffect.cropKind, key: key)) / 100 }
            o.cropInsets = CropInsets(left: v(ClipEffect.cropLeftKey), top: v(ClipEffect.cropTopKey),
                                      right: v(ClipEffect.cropRightKey), bottom: v(ClipEffect.cropBottomKey))
        } else {
            o.cropInsets = nil
        }
    }

    /// EditorPanels.overlayTransform: one gesture = one undo step through Effect Controls. A text clip's scale handles
    /// change its font size (sequence px) and keep Scale; the drag folds into one "Resize Text" step.
    private func overlayTransform(_ phase: TransformOverlay.Phase, _ t: ClipTransform) {
        guard let fx = effects else { return }
        switch phase {
        case .began:
            guard let target = overlayTarget, fx.clip?.id == target.clip else { return }
            session.stopPlayback()
            overlayGesture = (target, t)
            textResize = nil
            if target.isText, !target.isGraphics, let ref = session.displayedSelectedClip?.generator, ref.kind == GeneratorRef.text,
               let (template, animations) = try? TextGenerator.decode(ref) {
                textResize = (template, animations, session.undoDepth, true)
            }
            fx.beginGesture()
        case .changed, .ended:
            guard let g = overlayGesture else { return }
            var t = t
            if var r = textResize, t.scale != g.start.scale {
                let ratio = TextTemplate.resizeFactor(from: g.start.scale, to: t.scale)
                session.updateTextClip(g.target.clip, template: r.template.resized(by: ratio), animations: r.animations,
                                       continuesGesture: !r.first)
                r.first = false
                textResize = r
                t.scale = g.start.scale
            }
            let wrote = fx.setTransform(g.target.baseTransform(fromDisplay: t), from: g.target.baseTransform(fromDisplay: g.start))
            if !wrote || phase == .ended {   // animated and the playhead outside the clip: nothing to write, end here
                fx.endGesture(); overlayGesture = nil
                if phase == .ended, let r = textResize, !r.first, session.undoDepth > r.depth + 1 {
                    session.foldUndo(fromDepth: r.depth, name: "Resize Text")
                }
                textResize = nil
            }
        }
    }
}

// MARK: - Masks on the picture (EditorPanels.maskGesture / wireMaskTool / applyMaskEdit)

extension MonitorHost {
    fileprivate func attachMasks(_ o: TransformOverlay) {
        o.onMaskVertex = { [weak self] phase, id, index, point in
            self?.maskGesture(phase, id) { $0.moveMaskVertex(id, index: index, to: point) }
        }
        o.onMaskEdit = { [weak self] phase, edit in
            self?.maskGesture(phase, edit.maskID, needsPlayhead: edit.editsAtPlayhead) { Self.apply(edit, to: $0) }
        }
        o.onMaskSelect = { [weak self] id in
            guard let self, let fx = effects, fx.clip?.id == overlayTarget?.clip else { return }
            fx.selectMask(id)
        }
        o.onMaskShapeDrawn = { [weak self] kind, path in
            guard let self, let fx = effects else { return }
            session.stopPlayback()
            guard fx.playheadInClip else { onStatus?("Put the playhead on the clip to draw a mask there."); return }
            _ = fx.addDrawnMask(kind, path: path)
        }
        o.onMaskToolHover = { [weak self] p in
            guard let self, let magic else { return }
            magic.hover(p, target: overlayTarget?.clip)
        }
        o.onMaskToolClick = { [weak self] p, mods in
            guard let self, let fx = effects, let mode = maskToolNow() else { return }
            session.stopPlayback()
            if mode == .magic {
                guard let magic else {
                    onStatus?("Magic masks are not available on this platform yet: use Pen, Ellipse or Rectangle.")
                    return
                }
                magic.click(p, target: overlayTarget?.clip, subtract: mods.contains(.option), newMask: mods.contains(.shift))
                return
            }
            guard fx.playheadInClip else { onStatus?("Put the playhead on the clip to draw a mask there."); return }
            _ = fx.maskToolClick(mode, at: p, subtract: mods.contains(.option), newMask: mods.contains(.shift))
        }
    }

    /// One mask handle gesture: refused up front for an animated path while the playhead is outside the clip, else one
    /// undo step from `.began` to `.ended`.
    private func maskGesture(_ phase: TransformOverlay.Phase, _ id: ClipMask.ID, needsPlayhead: Bool = true,
                             _ edit: (EffectControlsModel) -> Void) {
        guard let fx = effects else { return }
        switch phase {
        case .began:
            maskGestureClip = nil
            guard let clip = fx.clip, clip.id == overlayTarget?.clip else { return }
            if needsPlayhead, fx.maskEditNeedsPlayhead(id) {
                onStatus?("Put the playhead on the clip to edit an animated mask path there.")
                return
            }
            maskGestureClip = clip.id
            session.stopPlayback(); fx.beginGesture()
        case .changed:
            guard maskGestureClip != nil, maskGestureClip == fx.clip?.id else { return }
            edit(fx)
        case .ended:
            guard let started = maskGestureClip else { return }
            maskGestureClip = nil
            if started == fx.clip?.id { edit(fx) }
            fx.endGesture()
        }
    }

    static func apply(_ edit: MaskHandleEdit, to fx: EffectControlsModel) {
        switch edit {
        case .tangent(let id, let v, let out, let offset, let independent):
            fx.moveMaskTangent(id, index: v, out: out, to: offset, independent: independent)
        case .move(let id, let delta): fx.moveMask(id, by: delta)
        case .insert(let id, let segment, let t): fx.insertMaskVertex(id, segment: segment, at: t)
        case .pen(let id, let segment, let t, let handle, let independent):
            fx.placeMaskVertex(id, segment: segment, at: t, handle: handle, independent: independent)
        case .remove(let id, let v): fx.removeMaskVertex(id, index: v)
        case .toggleSmooth(let id, let v): fx.toggleMaskVertexSmooth(id, index: v)
        }
    }
}

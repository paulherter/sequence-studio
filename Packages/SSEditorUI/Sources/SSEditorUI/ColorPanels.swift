import AppKit
import SSCore
import SSRender

/// Color inspector panel of the Color page: the colour controls of the selected picture clip.
/// Edits `Clip.color` through `session.replaceClip` (one undo step per gesture); the Program monitor follows because the
/// session pushes the timeline to the engine after every edit. The per-clip model only holds UI state (wheels, bypass
/// restore) and is reloaded from the clip on every session change.
@MainActor
public final class ColorInspectorPanelView: NSView {
    public let session: EditorSession
    public private(set) var colorModels: [Clip.ID: ColorInspectorModel] = [:]
    /// A control changed (the scopes may need a refresh).
    public var onChange: (() -> Void)?

    private let emptyLabel = NSTextField(wrappingLabelWithString: "Select a picture clip to adjust its color.")
    private var views: [Clip.ID: InspectorScroll] = [:]
    private var clipID: Clip.ID?
    private var shown: NSView?

    public override var isFlipped: Bool { true }

    public init(session: EditorSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        emptyLabel.font = Theme.Fonts.small
        emptyLabel.textColor = Theme.Colors.label3
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Color")
        sync([.project, .selection])
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    private var thumbnailScheduled = false

    /// Refreshes the Creative look preview from the Program monitor's frame shortly after the last request (coalesced).
    /// Only while the playhead is over the shown clip; otherwise the synthetic picture is used.
    private func scheduleThumbnail() {
        guard window != nil, !thumbnailScheduled else { return }
        thumbnailScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.thumbnailScheduled = false
                guard let id = self.clipID, let model = self.colorModels[id] else { return }
                let over = self.session.singleSelectedClip.map { $0.timeline.contains(self.session.playhead) } ?? false
                model.frameThumbnail = over ? self.session.engine.lastRenderedTexture.flatMap { FrameSampler.thumbnail(of: $0) } : nil
            }
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scheduleThumbnail() }
    }

    public func sync(_ change: EditorSession.Change) {
        if change.contains(.playhead) || change.contains(.project) || change.contains(.selection) { scheduleThumbnail() }
        guard change.contains(.project) || change.contains(.selection) else { return }
        let ids = Set(session.activeTimeline?.tracks.flatMap { $0.clips.map(\.id) } ?? [])
        for id in colorModels.keys where !ids.contains(id) { colorModels[id] = nil; views[id] = nil }
        let clip = session.singleSelectedClip
        clipID = clip.flatMap { $0.kind == .audio ? nil : $0.id }
        if let id = clipID, views[id] == nil {
            let model = ColorInspectorModel()
            model.onGestureBegan = { [weak self] in self?.beginGesture() }
            model.onGestureEnded = { [weak self] in self?.endGesture() }
            model.onChange = { [weak self] _ in self?.commit(id) }
            model.onAutoTone = { [weak self] effect in self?.autoTone(clip: id, effect: effect) }
            model.onPickWhiteBalance = { [weak self] effect in self?.pickWhiteBalance(clip: id, effect: effect) }
            colorModels[id] = model
            views[id] = InspectorScroll(content: ColorInspectorView(model: model))
        }
        if let clip, let id = clipID, let model = colorModels[id] {
            model.load(clip.color, mediaID: clip.media, info: session.media.info(of: clip.media))
        }
        let page = clipID.flatMap { views[$0] }
        if shown !== page {
            shown?.removeFromSuperview()
            shown = page
            if let page { addSubview(page) }
        }
        emptyLabel.isHidden = page != nil
        needsLayout = true
    }

    /// White-balance eyedropper: the next click on the Program monitor samples the rendered frame; Temperature and Tint
    /// are set so the picked colour becomes neutral (one undo step).
    private func pickWhiteBalance(clip id: Clip.ID, effect: Int) {
        ColorPickHub.shared.begin { [weak self] pos in
            guard let self, let pos, let model = self.colorModels[id],
                  let tex = self.session.engine.lastRenderedTexture,
                  let rgb = FrameSampler.meanColor(of: tex, at: pos),
                  let r = WhiteBalanceSolver.solve(picked: rgb, temperature: model.value(effect, .temperature),
                                                   tint: model.value(effect, .tint)) else { NSSound.beep(); return }
            model.setWhiteBalance(effect, temperature: r.temperature, tint: r.tint)
        }
    }

    /// Basic Correction Auto: analyses the Program frame as shown (when the playhead is over the clip).
    private func autoTone(clip id: Clip.ID, effect: Int) {
        guard let model = colorModels[id], let clip = session.singleSelectedClip, clip.id == id, clip.timeline.contains(session.playhead),
              let tex = session.engine.lastRenderedTexture, let luma = FrameSampler.lumaSamples(of: tex),
              let e = model.color.effect(effect), let b = AutoTone.solve(luma: luma, current: e.basic) else { NSSound.beep(); return }
        model.setAutoTone(effect, b)
    }

    private var gestureDepth = 0
    private var gestureHasEdit = false

    private func beginGesture() {
        if gestureDepth == 0 { gestureHasEdit = false }
        gestureDepth += 1
    }

    private func endGesture() { gestureDepth = max(gestureDepth - 1, 0) }

    /// Writes the model's settings to the clip. Edits of one gesture merge into one undo step; unchanged values
    /// (wheels, which are not stored yet) do not create a step.
    private func commit(_ id: Clip.ID) {
        guard let model = colorModels[id], var clip = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })
        else { return }
        let color = model.clipColor()
        guard color != clip.color else { return }
        clip.color = color
        let continuing = gestureDepth > 0 && gestureHasEdit
        if gestureDepth > 0 { gestureHasEdit = true }
        session.replaceClip(clip, name: "Color", continuesGesture: continuing)
        onChange?()
    }

    public override func layout() {
        super.layout()
        shown?.frame = bounds
        emptyLabel.frame = CGRect(x: Theme.Spacing.lg, y: bounds.midY - 24, width: max(bounds.width - 2 * Theme.Spacing.lg, 0), height: 48)
    }
}

/// Scopes panel of the Color page: the scope of the frame the Program monitor last rendered.
@MainActor
public final class ScopesPanelView: NSView {
    public let session: EditorSession
    private let scopes = ScopesView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Scopes are not available on this Mac.")
    private var refreshScheduled = false

    public override var isFlipped: Bool { true }

    public init(session: EditorSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        emptyLabel.font = Theme.Fonts.small
        emptyLabel.textColor = Theme.Colors.label3
        emptyLabel.alignment = .center
        if let scopes { addSubview(scopes) } else { addSubview(emptyLabel) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Scopes")
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public func sync(_ change: EditorSession.Change) {
        if change.contains(.playhead) || change.contains(.project) || change.contains(.media) { scheduleRefresh() }
    }

    /// Refreshes shortly after the last request (coalesced), only while the panel is on screen.
    public func scheduleRefresh() {
        guard window != nil, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                if self.window != nil, let tex = self.session.engine.lastRenderedTexture { self.scopes?.update(frame: tex) }
            }
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scheduleRefresh() }
    }

    public override func layout() {
        super.layout()
        scopes?.frame = bounds
        emptyLabel.frame = CGRect(x: Theme.Spacing.lg, y: bounds.midY - 12, width: max(bounds.width - 2 * Theme.Spacing.lg, 0), height: 24)
    }
}

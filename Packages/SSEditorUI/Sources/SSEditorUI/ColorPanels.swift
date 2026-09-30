import AppKit
import SSCore

/// Color inspector panel of the Color page: the colour controls of the selected picture clip.
/// Not persisted yet: per-clip state lives in a side store until `ColorCorrection` is part of the project model (PHASE3 slice 9).
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

    public func sync(_ change: EditorSession.Change) {
        guard change.contains(.project) || change.contains(.selection) else { return }
        let ids = Set(session.activeTimeline?.tracks.flatMap { $0.clips.map(\.id) } ?? [])
        for id in colorModels.keys where !ids.contains(id) { colorModels[id] = nil; views[id] = nil }
        let clip = session.singleSelectedClip
        clipID = clip.flatMap { $0.kind == .audio ? nil : $0.id }
        if let id = clipID, views[id] == nil {
            let model = ColorInspectorModel()
            model.onChange = { [weak self] _ in self?.onChange?() }
            colorModels[id] = model
            views[id] = InspectorScroll(content: ColorInspectorView(model: model))
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

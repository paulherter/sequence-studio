import AppKit
import SQCore
import SQMonitorUI
import SQRender
import SQUIKit

/// Color panel of the Color page (design boards "Color", "ColorClips" and Panels "Color"): the grading controls of what
/// is being graded. The logic (target, commits, gestures, keyframes, compare, viewer aids, grade copy and links) is the
/// shared `ColorGradeController`, which the Windows Color page uses too; this view is its AppKit face: the per-target
/// Simple / Pro pages, the viewer header, the Simple | Pro control, the Steps graph and the panels' header buttons.
@MainActor
public final class ColorInspectorPanelView: NSView {
    public let controller: ColorGradeController
    public var session: EditorSession { controller.session }
    public var colorModels: [UUID: ColorInspectorModel] { controller.colorModels }
    /// A control changed (the scopes may need a refresh).
    public var onChange: (() -> Void)? { get { controller.onChange } set { controller.onChange = newValue } }
    /// "On screen: X" for the Scopes panel (nil = the monitor shows the target).
    public var onScreenHintChange: ((String?) -> Void)? {
        get { controller.onScreenHintChange } set { controller.onScreenHintChange = newValue }
    }
    public var gradeOutline: Set<Clip.ID> { controller.gradeOutline }
    public var onGradeOutlineChange: ((Set<Clip.ID>) -> Void)? {
        get { controller.onGradeOutlineChange } set { controller.onGradeOutlineChange = newValue }
    }
    public var headerDetail: String? { controller.headerDetail }
    public var onHeaderDetailChange: ((String?) -> Void)? {
        get { controller.onHeaderDetailChange } set { controller.onHeaderDetailChange = newValue }
    }
    /// Simple | Pro of the target's grade (Color Pro mode): the shell puts it in the panel header. Exclusive; the other
    /// grade keeps its values.
    static let gradeSegmentWidth: CGFloat = 76
    static let gradeIconSize: CGFloat = 14
    public private(set) lazy var gradeSwitch: SQSegmented = {
        let s = SQSegmented(labels: ["Simple", "Pro"], segmentWidth: Self.gradeSegmentWidth, target: self, action: #selector(gradeSwitchChanged(_:)))
        // Variant B (windows plan section 7): wand for Simple, sliders for Pro, 14 px icons, 6 to the text.
        s.images = [SQIcon.toolMask.image(size: Self.gradeIconSize), SQIcon.slidersHorizontal.image(size: Self.gradeIconSize)]
        s.showsIconBesideLabel = true
        s.acceptsKeyboard = true
        s.setToolTip("Simple: the guided controls. The Pro grade keeps its values", forSegment: 0)
        s.setToolTip("Pro: the Color Graph of Steps. The Simple grade keeps its values", forSegment: 1)
        s.setAccessibilityLabel("Grade mode")
        s.sqToolTip = "Simple: the guided controls. Pro: the Color Graph of Steps. The other grade keeps its values."
        return s
    }()
    /// The Program monitor shows Split (a bypass in split mode is active): the shell draws the divider line.
    public var onSplitShownChange: ((Bool) -> Void)? {
        get { controller.onSplitShownChange } set { controller.onSplitShownChange = newValue }
    }
    public var splitShown: Bool { controller.splitShown }
    /// What the target is called, whether it is linked to its source, and what the monitor shows instead of it.
    var targetContent: ColorTargetBarContent { controller.targetContent }
    public var target: ColorTargetState { controller.target }
    public var resolution: ColorTargetResolution { controller.resolution }

    /// Shown instead of the controls when there is nothing to grade (`ColorTargetState.emptyState`).
    let emptyState = EmptyStateView(title: "")
    /// The "Color" line above the empty state (the place of the first effect's actions line).
    private let emptyHeader = ColorActionRow(title: "Color", controls: [])
    /// The viewer header of the Color page: the shell puts it above the Program monitor.
    public private(set) lazy var viewerHeader: ColorViewerHeaderView = {
        let h = ColorViewerHeaderView()
        h.setCompare(compare)
        h.onCompareChange = { [weak self] m in self?.setCompare(m) }
        return h
    }()
    /// Before | After | Split of the viewer header (monitor only, never stored).
    public var compare: ColorCompareMode { controller.compare }
    /// The Color page is showing: only then does Before / Split reach the Program monitor (the shell sets it).
    public var isOnColorPage: Bool { get { controller.isOnColorPage } set { controller.isOnColorPage = newValue } }
    /// The Steps graph of the Color page's Steps panel (Pro grade).
    public private(set) lazy var stepsGraph = ColorStepsGraphView()
    /// Header buttons of the Steps, Sources and Timeline panels of the Color page (a view has one superview: one set each).
    public private(set) lazy var stepsTools = makeTools(addsStep: true)
    public private(set) lazy var sourcesTools = makeTools(addsStep: false)
    public private(set) lazy var timelineTools = makeTools(addsStep: false)
    private func makeTools(addsStep: Bool) -> ColorGradeTools {
        let t = ColorGradeTools(addsStep: addsStep)
        t.onCopy = { [weak self] in if self?.copyGrade() != true { NSSound.beep() } }
        t.onPaste = { [weak self] in if self?.pasteGrade() != true { NSSound.beep() } }
        t.onAddStep = { [weak self] anchor in
            guard let self, let model = self.controller.model else { NSSound.beep(); return }
            if let menus = self.stepsGraph.menus { menus.showAddMenu(at: anchor) } else { model.addStep(after: model.selectedStep) }
        }
        t.setActions(canCopy: canCopyGrade, canPaste: canPasteGrade, canAdd: false)
        return t
    }
    /// The quiet text in the header of the Steps panel ("Color Graph", "Color Graph · not active").
    public var stepsDetail: String { controller.stepsDetail }
    public var onStepsDetailChange: ((String) -> Void)? {
        get { controller.onStepsDetailChange } set { controller.onStepsDetailChange = newValue }
    }
    /// What the header of the Timeline and Sources panels says a click does there.
    public static var timelineHint: String { ColorGradeController.timelineHint }
    /// The Timeline panel's header text: the hint only while nothing gradable is picked.
    public static func timelineDetail(for resolution: ColorTargetResolution) -> String {
        ColorGradeController.timelineDetail(for: resolution)
    }
    public var timelineDetail: String { controller.timelineDetail }
    public var onTimelineDetailChange: ((String) -> Void)? {
        get { controller.onTimelineDetailChange } set { controller.onTimelineDetailChange = newValue }
    }
    public static var sourcesHint: String { ColorGradeController.sourcesHint }
    /// The Steps panel is the visible tab of its group (the shell sets it on every layout change).
    public var stepsShown: Bool { get { controller.stepsShown } set { controller.stepsShown = newValue } }
    /// The Sources panel is the visible tab of its group: the monitor isolates the picked clip's source.
    public var sourcesShown: Bool { get { controller.sourcesShown } set { controller.sourcesShown = newValue } }
    /// The Clips strip is on screen (the Timeline group is shown on the Color page).
    public var stripVisible: Bool { get { controller.stripVisible } set { controller.stripVisible = newValue } }
    /// The Pro page shows (the Color Graph, or its empty page): the shell shows the Scopes panel beside the monitor then.
    public var proShown: Bool { controller.proShown }
    public var onProShownChange: ((Bool) -> Void)? {
        get { controller.onProShownChange } set { controller.onProShownChange = newValue }
    }
    /// The user picked Pro in the Simple | Pro control (not a clip selection that happens to be Pro).
    public var onUserChoseProGrade: (() -> Void)? {
        get { controller.onUserChoseProGrade } set { controller.onUserChoseProGrade = newValue }
    }
    /// The status bar's grade text.
    public var gradeStatus: String { controller.gradeStatus }

    /// The Steps page's graph, strip and buttons follow the target's Pro grade.
    private func applyStepsPage() {
        let key = controller.key
        let model = controller.model
        if proShown {
            stepsGraph.model = model
            stepsGraph.menus = key.flatMap { inspectors[$0] }?.proPage
            for (k, v) in inspectors { v.proPage.showsStrip = !(k == key && stepsShown) }
        }
        stepsTools.setActions(canCopy: canCopyGrade, canPaste: canPasteGrade, canAdd: model?.graph != nil)
    }

    /// The Color panel header's menu: the monitor layout, the grade's copy, paste and reset, and what else acts on the
    /// whole grade.
    public func showMoreMenu(at p: NSPoint) {
        let more = controller.key.flatMap { inspectors[$0] }?.simpleActionItems() ?? []
        SQMenuController.shared.present(items: controller.moreMenuItems(simpleExtra: more), at: p)
    }
    /// The Clips strip (it shares this panel's target).
    public private(set) lazy var clipsPanel: ColorClipsPanelView = {
        let l = ColorClipsPanelView(session: session)
        l.onPickSource = { [weak self] item in self?.pickSource(item) }
        l.onCopy = { [weak self] in _ = self?.copyGrade() }
        l.onPaste = { [weak self] in if self?.pasteGrade() != true { NSSound.beep() } }
        l.canPaste = { [weak self] in self?.canPasteGrade ?? false }
        l.onLinkAll = { [weak self] item in self?.controller.linkAllUses(item) }
        return l
    }()
    private var views: [UUID: InspectorScroll] = [:]
    private var inspectors: [UUID: ColorInspectorView] = [:]
    private var shown: NSView?

    public override var isFlipped: Bool { true }

    /// False while the Color page is hidden (Edit page): playhead / transport ticks are collected and caught up once
    /// when the page shows. Edits (project, selection) always sync.
    public var isActive: Bool { get { controller.isActive } set { controller.isActive = newValue } }
    var pendingWhileInactive: EditorSession.Change { controller.pendingWhileInactive }
    var skippedSyncs: Int { controller.skippedSyncs }

    public init(session: EditorSession) {
        controller = ColorGradeController(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        addSubview(emptyState)
        addSubview(emptyHeader)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Color")
        wireController(session)
        sync([.project, .selection])
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    private func wireController(_ session: EditorSession) {
        let c = controller
        c.beep = { NSSound.beep() }
        c.confirmStopAnimating = { Self.confirmStopAnimating($0) }
        let engine = session.engine
        c.pickScreenColor = { picked, done in
            let hover: ColorPickHub.HoverSampler = { pos, done in FrameSampler.sampleGrid(engine: engine, at: pos, done) }
            ColorPickHub.shared.begin(hoverSampler: hover) { pos in
                guard let pos else { return }
                picked()
                FrameSampler.sampleColor(engine: engine, at: pos, done)
            }
        }
        c.sampleProgramFrame = { width, done in
            FrameSampler.sampleScaled(engine: engine, width: width, key: "color.auto") { done($0?.linear) }
        }
        c.onModelMade = { [weak self] k, model in
            let inspector = ColorInspectorView(model: model)
            self?.inspectors[k] = inspector
            self?.views[k] = InspectorScroll(content: inspector)
        }
        c.onModelsDropped = { [weak self] keys in for k in keys { self?.views[k] = nil; self?.inspectors[k] = nil } }
        c.onGradeSwitchChange = { [weak self] in self?.updateGradeSwitch() }
        c.onStepsPageChange = { [weak self] in self?.applyStepsPage() }
        c.onCompareChange = { [weak self] m in
            guard let self, self.viewerHeader.compare != m else { return }
            self.viewerHeader.setCompare(m)
        }
        c.onHeaderRefresh = { [weak self] in
            guard let self else { return }
            self.viewerHeader.show(self.controller.viewerHeaderContent)
            for t in [self.timelineTools, self.sourcesTools] { t.setActions(canCopy: self.canCopyGrade, canPaste: self.canPasteGrade) }
            self.stepsTools.setActions(canCopy: self.canCopyGrade, canPaste: self.canPasteGrade,
                                       canAdd: self.controller.model?.graph != nil)
        }
        c.onSynced = { [weak self] in self?.applySync() }
    }

    /// After a structural sync: the empty state, the Sources list and the shown page.
    private func applySync() {
        if let e = controller.emptyState {
            emptyState.title = e.title
            emptyState.hint = e.hint
        }
        clipsPanel.reload(wholeSequence: controller.isWholeSequence, picked: controller.target.pick, format: controller.format)
        let page = controller.key.flatMap { views[$0] }
        if shown !== page {
            shown?.removeFromSuperview()
            shown = page
            if let page { addSubview(page) }
        }
        emptyState.isHidden = page != nil
        emptyHeader.isHidden = page != nil
        needsLayout = true
    }

    // MARK: Target

    /// Grades clip `id`: selects it in the timeline and moves the playhead onto it when it is elsewhere.
    public func pick(_ id: Clip.ID) { controller.pick(id) }
    public func updateSolo() { controller.updateSolo() }
    public func pickSource(_ item: ColorSourceListItem) { controller.pickSource(item) }
    public func pickWholeSequence() { controller.pickWholeSequence() }
    public func sync(_ change: EditorSession.Change) { controller.sync(change) }

    // MARK: Compare and viewer aids

    public func setCompare(_ mode: ColorCompareMode) { controller.setCompare(mode) }
    func updateCompare() { controller.updateCompare() }
    public typealias WindowEditTarget = ColorGradeController.WindowEditTarget
    public var windowEdit: WindowEditTarget? { controller.windowEdit }
    public var onWindowEditChange: ((WindowEditTarget?) -> Void)? {
        get { controller.onWindowEditChange } set { controller.onWindowEditChange = newValue }
    }
    public func updateViewerAids() { controller.updateViewerAids() }
    public func beginWindowEdit() { controller.beginWindowEdit() }
    public func changeWindowEdit(_ w: StepWindow) { controller.changeWindowEdit(w) }
    public func endWindowEdit() { controller.endWindowEdit() }

    // MARK: Rules (shared, `ColorGradeController`)

    static func nestedClips(of c: Clip, in project: Project) -> Set<Clip.ID> { ColorGradeController.nestedClips(of: c, in: project) }
    static func colorBypass(_ mode: ColorCompareMode, target: Clip.ID?, linked: [Clip.ID]) -> ColorBypass? {
        ColorGradeController.colorBypass(mode, target: target, linked: linked)
    }
    static func soloClip(clipsMode: Bool, stripVisible: Bool, picked: Clip.ID?) -> Clip.ID? {
        ColorGradeController.soloClip(clipsMode: clipsMode, stripVisible: stripVisible, picked: picked)
    }
    static func samplingBlockReason(timeline: Timeline, clip: Clip, playhead: Time) -> String? {
        ColorGradeController.samplingBlockReason(timeline: timeline, clip: clip, playhead: playhead)
    }
    static func compareBlockReason(_ mode: ColorCompareMode) -> String? { ColorGradeController.compareBlockReason(mode) }
    static func headerDetail(_ r: ColorTargetResolution, session: EditorSession) -> String? {
        ColorGradeController.headerDetail(r, session: session)
    }
    static func local(_ clip: Clip, _ playhead: Time, frameDuration: Time) -> Time {
        ColorGradeController.local(clip, playhead, frameDuration: frameDuration)
    }
    static func hasAnimatedGrade(_ clip: Clip) -> Bool { ColorGradeController.hasAnimatedGrade(clip) }

    // MARK: Simple | Pro

    @objc private func gradeSwitchChanged(_ s: SQSegmented) { controller.chooseGrade(pro: s.selectedSegment == 1) }

    private func updateGradeSwitch() {
        let model = controller.model
        gradeSwitch.isEnabled = model != nil
        let i = model?.shownGrade == .pro ? 1 : 0
        if gradeSwitch.selectedSegment != i { gradeSwitch.selectedSegment = i }
    }

    // MARK: Keyframes

    func keyframe(_ action: ColorKeyAction, _ id: ColorKeyID, key k: UUID) { controller.keyframe(action, id, key: k) }

    /// Asks before animation is turned off (it removes every key). Replaceable in tests.
    static var confirmStopAnimating: @MainActor (String) -> Bool = { EffectControlsView.confirmRemoveKeyframes(title: $0) }

    public override func layout() {
        super.layout()
        shown?.frame = bounds
        let hh = min(ColorActionRow.height, bounds.height)
        emptyHeader.frame = CGRect(x: 0, y: 0, width: bounds.width, height: hh)
        emptyState.frame = CGRect(x: 0, y: hh, width: bounds.width, height: bounds.height - hh)
    }

    // MARK: Grades: copy/paste, links, ranges (COLOR-GRADE-LINKS)

    @discardableResult public func copyGrade() -> Bool { controller.copyGrade() }
    @discardableResult public func pasteGrade(onTop: Bool = false) -> Bool { controller.pasteGrade(onTop: onTop) }
    public var canCopyGrade: Bool { controller.canCopyGrade }
    public var canPasteGrade: Bool { controller.canPasteGrade }
    func gradeAction(_ a: ColorGradeAction, clip id: Clip.ID) { controller.gradeAction(a, clip: id) }
}

/// Scopes panel of the Color page: the scopes of the frame the Program monitor last rendered (`ScopesView`). When that frame is not the
/// clip the Color panel grades, a line says what is measured instead (`hint`, set by the Color panel).
@MainActor
public final class ScopesPanelView: NSView {
    public let session: EditorSession
    private let scopes = ScopesView()
    /// No scopes on this Mac, or no sequence to measure (INTERACTION-AUDIT §10).
    let emptyState = EmptyStateView(title: "")
    /// Refreshes are coalesced over this delay (seconds).
    static let refreshDelay: TimeInterval = 0.06
    private let hintLabel = NSTextField(labelWithString: "")
    private var refreshScheduled = false

    /// "On screen: X" (the scopes measure X, not the graded clip); nil hides the line.
    public var hint: String? {
        didSet {
            hintLabel.stringValue = hint.map { "Measuring \($0.replacingOccurrences(of: "On screen: ", with: "")), not the graded clip" } ?? ""
            hintLabel.isHidden = hint == nil
            needsLayout = true
        }
    }

    public override var isFlipped: Bool { true }

    /// The scope the header's tabs show (Color page with the Pro grade: Parade | Waveform | Vectorscope | Histogram).
    public var kind: ScopeKind { scopes?.kind ?? .waveform }
    public func select(_ k: ScopeKind) { scopes?.select(k) }
    static let tabKinds: [ScopeKind] = [.parade, .waveform, .vectorscope, .histogram]
    /// The panel header of the Color page with the Pro grade: Parade | Waveform | Vectorscope | Histogram.
    public private(set) lazy var tabHeader: ColorTabHeaderView = {
        let h = ColorTabHeaderView(tabs: Self.tabKinds.map(\.title))
        h.onSelect = { [weak self] i in self?.select(Self.tabKinds[i]) }
        return h
    }()
    /// Stack with popups (Edit page), row of three (Color page, Simple) or one scope under header tabs (Color page, Pro).
    public var arrangement: ScopesView.Arrangement {
        get { scopes?.arrangement ?? .stacked }
        set {
            scopes?.arrangement = newValue
            if newValue == .single { select(Self.tabKinds[tabHeader.selected]) }
            needsLayout = true
        }
    }

    public init(session: EditorSession, captureKey: String = "scopes") {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        scopes?.captureKey = captureKey
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        hintLabel.font = Theme.Typography.caption
        hintLabel.textColor = Theme.Colors.warning
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.isHidden = true
        if let scopes { addSubview(scopes) }
        addSubview(emptyState)
        updateEmptyState()
        addSubview(hintLabel)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Scopes")
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    /// What the empty state says (nil = the scopes are shown).
    static func emptyState(scopesAvailable: Bool, hasSequence: Bool) -> (title: String, hint: String)? {
        if !scopesAvailable { return ("Scopes unavailable", "Scopes are not available on this Mac.") }
        if !hasSequence { return ("No picture to measure", "Open a sequence to see its scopes.") }
        return nil
    }

    private func updateEmptyState() {
        let e = Self.emptyState(scopesAvailable: scopes != nil, hasSequence: session.activeTimeline != nil)
        // Without a picture the first scope's box says so; only a Mac without scopes shows the plain empty state.
        emptyState.isHidden = e == nil || scopes != nil
        scopes?.emptyText = e
        if let e, emptyState.title != e.title { emptyState.title = e.title; emptyState.hint = e.hint }
    }

    public func sync(_ change: EditorSession.Change) {
        if change.contains(.project) { updateEmptyState() }
        if Self.refreshes(for: change) { scheduleRefresh() }
    }

    /// The changes after which the monitor shows a new picture (also while the Color solo is active: the monitor
    /// renders the raw source file there, and playhead moves of the file view arrive as `.playhead`).
    static func refreshes(for change: EditorSession.Change) -> Bool {
        !change.isDisjoint(with: [.playhead, .project, .media, .monitorPicture])
    }

    /// Refreshes shortly after the last request (coalesced), only while the panel is on screen.
    public func scheduleRefresh() {
        guard window != nil, !isHiddenOrHasHiddenAncestor, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                if self.window != nil { self.scopes?.requestUpdate(from: self.session.engine) }
            }
        }
    }

    public override func viewDidUnhide() { super.viewDidUnhide(); scheduleRefresh() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scheduleRefresh() }
    }

    public override func layout() {
        super.layout()
        let lh = ceil(hintLabel.intrinsicContentSize.height)
        let top: CGFloat = hintLabel.isHidden ? 0 : lh + Theme.Spacing.xs
        hintLabel.frame = CGRect(x: Theme.Spacing.md, y: Theme.Spacing.xs, width: max(bounds.width - 2 * Theme.Spacing.md, 0), height: lh)
        scopes?.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top, 0))
        emptyState.frame = bounds
    }
}

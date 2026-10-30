import Foundation
import SQCore
import SQEditorSession
import SQRender
import SQUIKit

/// The logic of the Color page's Color panel, shared by the Mac `ColorInspectorPanelView` and the Windows draw-list
/// Color page (the Windows port plan "Panel status: Color"). What is graded is picked by clicking a clip, an adjustment
/// layer or the sequence grade layer in the timeline, or a source tile in the Sources panel (a tile grades every use of
/// its source through the grade links). The target comes from `ColorTargetState` (strip pick and timeline selection kept
/// in sync, see there), not from the clip under the playhead; the eyedropper and Auto measure the target only when it is
/// on screen.
///
/// A view on the target's Color effects (`Clip.color(atLocal:)`): shows the values at the playhead and writes through
/// `session.editClipColor` / `editSequenceGrade` (one undo step per gesture; only the values an edit changed are written,
/// keyframed ones as a key at the playhead the gesture began at). The per-target model (keyed by the clip id, or the
/// sequence id for the sequence-wide grade, so it survives the layer being created mid-gesture) only holds UI state and
/// is reloaded on every session change outside a gesture. The platform views listen to the `on…` hooks; the frame
/// sampling (eyedropper, Auto) and the beep are platform seams.
@MainActor
public final class ColorGradeController {
    public let session: EditorSession
    public private(set) var colorModels: [UUID: ColorInspectorModel] = [:]

    // MARK: Hooks (outputs)

    /// A control changed (the scopes may need a refresh).
    public var onChange: (() -> Void)?
    /// "On screen: X" for the Scopes panel (nil = the monitor shows the target).
    public var onScreenHintChange: ((String?) -> Void)?
    /// The current "On screen: X" (what `onScreenHintChange` last said), for hosts that read it each frame.
    public var onScreenHint: String? { targetContent.onScreen }
    /// The clips the timeline outlines (the target and the clips sharing its grade); the shell shows it on the Color page.
    public private(set) var gradeOutline: Set<Clip.ID> = []
    public var onGradeOutlineChange: ((Set<Clip.ID>) -> Void)?
    /// What the panel header shows after "Color": "2 uses" for a clip, "Whole sequence" for the sequence-wide grade,
    /// nil when nothing is graded.
    public private(set) var headerDetail: String?
    public var onHeaderDetailChange: ((String?) -> Void)?
    /// The Program monitor shows Split (a bypass in split mode is active): the shell draws the divider line.
    public var onSplitShownChange: ((Bool) -> Void)?
    public private(set) var splitShown = false
    /// The quiet text in the header of the Steps panel ("Color Graph", "Color Graph · not active").
    public private(set) var stepsDetail = "Color Graph"
    public var onStepsDetailChange: ((String) -> Void)?
    public private(set) var timelineDetail = ColorGradeController.timelineHint
    public var onTimelineDetailChange: ((String) -> Void)?
    /// The Pro page shows (the Color Graph, or its empty page): the shell shows the Scopes panel beside the monitor then.
    public private(set) var proShown = false
    public var onProShownChange: ((Bool) -> Void)?
    /// The user picked Pro in the Simple | Pro control (not a clip selection that happens to be Pro).
    public var onUserChoseProGrade: (() -> Void)?
    /// The handles' target changed (nil: hide them).
    public var onWindowEditChange: ((WindowEditTarget?) -> Void)?
    /// Before | After | Split changed (the viewer header follows).
    public var onCompareChange: ((ColorCompareMode) -> Void)?

    /// View hooks of the platform panel: a model was made (build its page), models were dropped, a structural sync ended
    /// (empty state, page swap, Sources list), the Simple | Pro state may differ, the Steps page and the header buttons.
    public var onModelMade: ((UUID, ColorInspectorModel) -> Void)?
    public var onModelsDropped: ((Set<UUID>) -> Void)?
    public var onSynced: (() -> Void)?
    public var onGradeSwitchChange: (() -> Void)?
    public var onStepsPageChange: (() -> Void)?
    public var onHeaderRefresh: (() -> Void)?

    // MARK: Platform seams

    /// Refused action (NSSound.beep on the Mac, MessageBeep on Windows).
    public var beep: () -> Void = {}
    /// Asks before animation is turned off (it removes every key).
    public var confirmStopAnimating: (String) -> Bool = { _ in true }
    /// White-balance eyedropper: waits for a click on the Program monitor, calls `picked` on the click, then `done` with
    /// the mean linear RGB there (nil = canceled or unreadable). Nil = no eyedropper on this platform (beep).
    public var pickScreenColor: ((_ picked: @escaping @MainActor () -> Void,
                                  _ done: @escaping @MainActor (SIMD3<Float>?) -> Void) -> Void)?
    /// Auto: the Program frame as shown, scaled to about `width` px, as linear RGB samples (nil = unreadable). Nil = no
    /// frame readback on this platform (beep).
    public var sampleProgramFrame: ((_ width: Int, _ done: @escaping @MainActor ([SIMD3<Float>]?) -> Void) -> Void)?

    // MARK: State

    /// What the target is called, whether it is linked to its source, and what the monitor shows instead of it.
    private(set) var targetContent = ColorTargetBarContent(title: "")
    public private(set) var target = ColorTargetState()
    public private(set) var resolution: ColorTargetResolution = .message("")
    public private(set) var format: ColorPageFormat = .landscape
    /// The empty state of the current message (nil while something is graded).
    public private(set) var emptyState: (title: String, hint: String)?
    /// Before | After | Split of the viewer header (monitor only, never stored).
    public private(set) var compare = ColorCompareMode.after
    /// The Color page is showing: only then does Before / Split reach the Program monitor (the shell sets it).
    public var isOnColorPage = false { didSet { if oldValue != isOnColorPage { updateCompare() } } }
    /// The Steps panel is the visible tab of its group (the shell sets it on every layout change): the Color panel then
    /// hides its own step strip, the graph is the step list.
    public var stepsShown = false { didSet { if oldValue != stepsShown { updateLowerPage() } } }
    /// The Sources panel is the visible tab of its group: the monitor isolates the picked clip's source (`updateSolo`).
    public var sourcesShown = false { didSet { if oldValue != sourcesShown { updateSolo() } } }
    /// The Clips strip is on screen (the Timeline group is shown on the Color page). The solo needs it: with the strip
    /// hidden the isolated clip would have no visible Clips UI to explain or end it. The shell sets it on every layout change.
    public var stripVisible = true { didSet { if oldValue != stripVisible { updateSolo() } } }
    /// The model key of the target (clip id, or sequence id for the Timeline grade); nil = a message is shown.
    public private(set) var key: UUID?
    /// The model of the target (nil = a message is shown).
    public var model: ColorInspectorModel? { key.flatMap { colorModels[$0] } }

    /// False while the Color page is hidden (Edit page): playhead / transport ticks are not synced, they are collected
    /// and caught up once when the page shows. Edits (project, selection) always sync.
    public var isActive = true {
        didSet {
            guard isActive, !oldValue, !pendingWhileInactive.isEmpty else { return }
            let pending = pendingWhileInactive
            pendingWhileInactive = []
            sync(pending)
        }
    }
    public private(set) var pendingWhileInactive: EditorSession.Change = []
    public private(set) var skippedSyncs = 0

    private var lastHint: String??
    private var pickedClip: Clip.ID? { if case .clip(let id) = resolution { return id }; return nil }

    public init(session: EditorSession) {
        self.session = session
        target.selectionChanged(session.selection, in: session.activeTimeline)
    }

    /// The status bar's grade text: "Simple grade active", "No Simple grade", "Pro grade active, 4 steps",
    /// "No Pro grade" (the empty Pro page), "".
    public var gradeStatus: String {
        guard let model else { return "" }
        if model.shownGrade == .pro, model.graph == nil { return "No Pro grade" }
        if model.activeGrade == .pro {
            let n = model.graph?.steps.count ?? 0
            return "Pro grade active, \(n) \(n == 1 ? "step" : "steps")"
        }
        return (targetClip?.colorGradeEffects.isEmpty ?? true) ? "No Simple grade" : "Simple grade active"
    }

    // MARK: Simple | Pro and the Steps page

    /// The Simple | Pro control picked Pro (`pro`) or Simple.
    public func chooseGrade(pro: Bool) {
        guard let model else { onGradeSwitchChange?(); return }
        if pro { onUserChoseProGrade?() }
        model.setActiveGrade(pro ? .pro : .simple)
        onGradeSwitchChange?()
    }

    private func applyStepsPage() {
        if proShown {
            let detail = model?.graph != nil ? "Color Graph" : "Color Graph \u{00B7} not active"
            if detail != stepsDetail { stepsDetail = detail; onStepsDetailChange?(detail) }
        }
        onStepsPageChange?()
    }

    /// Follows the target's grade: the Steps panel shows with the Pro grade (the shell reads `proShown`).
    private func updateLowerPage() {
        let pro = model?.shownGrade == .pro
        let changed = pro != proShown
        proShown = pro
        applyStepsPage()
        if changed { onProShownChange?(pro) }
    }

    /// The Color panel header's menu: the monitor layout, the grade's copy, paste and reset, and what else acts on the
    /// whole grade. `simpleExtra` = the Simple page's own actions (shown while the Simple grade shows).
    public func moreMenuItems(simpleExtra: [SQMenuItem] = []) -> [SQMenuItem] {
        let model = self.model
        let id = targetClip?.id
        var items: [SQMenuItem] = [.header("Layout")]
        for m in ColorCompareMode.allCases {
            items.append(SQMenuItem(title: m.layoutTitle, isChecked: compare == m) { [weak self] in self?.setCompare(m) })
        }
        if let model, model.activeGrade == .pro {
            items.append(SQMenuItem(title: "Picture and matte", isChecked: model.showsMatte) { model.showsMatte.toggle() })
        }
        items += [
            .separator,
            SQMenuItem(title: "Copy Grade", shortcut: "\u{2318}C", isEnabled: canCopyGrade) { [weak self] in
                _ = self?.copyGrade()
            },
            SQMenuItem(title: "Paste grade", shortcut: "\u{2318}V", isEnabled: canPasteGrade) { [weak self] in
                if self?.pasteGrade() != true { self?.beep() }
            },
            SQMenuItem(title: "Paste grade on top", isEnabled: canPasteGrade) { [weak self] in
                if self?.pasteGrade(onTop: true) != true { self?.beep() }
            },
            SQMenuItem(title: "Save grade to memory", submenu: (1...ColorClipboard.memorySlots).map { n in
                SQMenuItem(title: "Memory \(n)", isEnabled: ColorClipboard.shared.hasColor) { _ = ColorClipboard.shared.saveMemory(n) }
            }),
            SQMenuItem(title: "Load grade from memory", submenu: (1...ColorClipboard.memorySlots).map { n in
                SQMenuItem(title: "Memory \(n)", isEnabled: ColorClipboard.shared.hasMemory(n)) { _ = ColorClipboard.shared.loadMemory(n) }
            }),
            SQMenuItem(title: "Reset this grade", isEnabled: model != nil && id != nil) { model?.onResetAll?() },
            .separator,
            SQMenuItem(title: "Send Simple grade into Pro (copy)", isEnabled: model?.canSendToPro ?? false) { model?.sendToPro() },
            .separator,
        ]
        if let model, model.shownGrade != .pro, !simpleExtra.isEmpty { items += simpleExtra + [.separator] }
        items += [
            SQMenuItem(title: "Grade Whole Sequence") { [weak self] in self?.pickWholeSequence() },
            SQMenuItem(title: "Link Grade to Selected Clips", isEnabled: id != nil) { [weak self] in
                if let id { self?.gradeAction(.linkSelected, clip: id) }
            },
            SQMenuItem(title: "Link All Clips of This Source", isEnabled: id != nil) { [weak self] in
                if let id { self?.gradeAction(.linkSource, clip: id) }
            },
            SQMenuItem(title: "Unlink Grade", isEnabled: (model?.linkedClipCount ?? 0) > 1) { [weak self] in
                if let id { self?.gradeAction(.unlink, clip: id) }
            },
            SQMenuItem(title: "Add Range Grade", isEnabled: id != nil) { [weak self] in
                if let id { self?.gradeAction(.addRange, clip: id) }
            },
        ]
        return items
    }

    // MARK: Target

    /// The clip the panel edits now: the picked clip, or the Timeline grade layer (nil before it exists).
    public var targetClip: Clip? {
        switch resolution {
        case .clip(let id): return clip(id)
        case .sequence(_, let layer): return layer.flatMap(clip)
        case .message: return nil
        }
    }

    /// Grades clip `id`: selects it in the timeline and moves the playhead onto it when it is elsewhere, so the monitor
    /// and the scopes show what is graded.
    public func pick(_ id: Clip.ID) {
        target.listPicked(id)
        session.select(clips: [id])
        if let c = clip(id), !c.timeline.contains(session.playhead) { session.seekSequence(to: c.start) }
        updateSolo()
        sync([.selection, .playhead])
    }

    /// Lower panel on Clips with a picture clip picked: the Program monitor shows that clip's whole source file
    /// (`EditorSession.colorSourceView`; the clip alone when it has no file); otherwise the normal composite.
    public func updateSolo() {
        var picked: Clip.ID?
        if case .clip(let id) = resolution, clip(id) != nil { picked = id }
        session.colorSoloClip = Self.soloClip(clipsMode: sourcesShown, stripVisible: stripVisible, picked: picked)
    }

    /// A source tile: grades its picked cut, else its first linked cut (`clipToGrade`); the uses of the source share
    /// that grade through the grade links.
    public func pickSource(_ item: ColorSourceListItem) {
        pick(item.clipToGrade(picked: target.pick, in: session.project))
    }

    /// "Link all uses" of a source tile.
    public func linkAllUses(_ item: ColorSourceListItem) {
        gradeAction(.linkSource, clip: item.clipToGrade(picked: target.pick, in: session.project))
    }

    /// Grades the whole sequence (the sequence grade layer, created by the first edit) and selects the layer in the
    /// timeline when it exists.
    public func pickWholeSequence() {
        target.wholeSequencePicked()
        if let g = session.activeTimeline?.sequenceGradeClip { session.select(clips: [g.id]) } else { session.select(clips: []) }
        sync([.selection, .project])
    }

    /// The Sources list is on the whole sequence (no tile picked).
    public var isWholeSequence: Bool { if case .sequence = resolution { true } else { false } }

    /// The target is what the Program monitor shows at the playhead (a clip under it, or the sequence while inside it).
    private var onScreen: Bool {
        switch resolution {
        case .clip(let id): return clip(id)?.timeline.contains(session.playhead) == true
        case .sequence: return session.playhead < (session.activeTimeline?.duration ?? .zero)
        case .message: return false
        }
    }

    // MARK: Compare (Before | After | Split)

    /// Shows `mode` in the viewer header and applies it to the Program monitor.
    public func setCompare(_ mode: ColorCompareMode) {
        let changed = compare != mode
        compare = mode
        if changed { onCompareChange?(mode) }
        updateCompare()
    }

    /// Hands the engine what to draw ungraded: the target and the clips sharing its grade, while the page shows.
    public func updateCompare() {
        refreshSamplingBlock()
        var bypass: ColorBypass?
        if isOnColorPage {
            if let id = targetClip?.id {
                bypass = Self.colorBypass(compare, target: id, linked: session.gradeLinkMembers(of: id))
            } else if case .message = resolution, session.selection.count == 1, let id = session.selection.first, let c = clip(id), c.isNested {
                // A nest is graded inside: compare everything in it (the panel shows the nested notice).
                let inside = Self.nestedClips(of: c, in: session.project)
                if let first = inside.first {
                    bypass = Self.colorBypass(compare, target: first, linked: Array(inside))
                }
            }
        }
        session.engine.setColorBypass(bypass)
        updateViewerAids()
        let split = bypass?.mode == .split
        if split != splitShown { splitShown = split; onSplitShownChange?(split) }
    }

    // MARK: Viewer aids (Pro grade: matte preview and window handles)

    /// The window of the selected Step, to draw handles for over the Program monitor.
    public struct WindowEditTarget: Equatable, Sendable {
        public var clip: Clip.ID
        public var window: StepWindow
    }

    public private(set) var windowEdit: WindowEditTarget?

    /// Matte preview (`EditorSession.colorMattePreview`) and window handles follow the Color page, the Pro grade and
    /// the selected Step. Called after every sync, a Step selection and the matte toggle.
    public func updateViewerAids() {
        var preview: ColorMattePreview?
        var edit: WindowEditTarget?
        if isOnColorPage, let model, let clip = targetClip, model.activeGrade == .pro,
           let id = model.selectedStep, let step = model.step(id) {
            if model.showsMatte, step.qualifier != nil || step.window != nil {
                preview = ColorMattePreview(clip: clip.id, step: id)
            }
            if let t = model.windowEditTarget { edit = WindowEditTarget(clip: clip.id, window: t.window) }
        }
        if session.colorMattePreview != preview { session.colorMattePreview = preview }
        if windowEdit != edit {
            windowEdit = edit
            onWindowEditChange?(edit)
        }
    }

    /// A handle drag on the monitor: begin, change* with the dragged window, end. One "Color Graph" undo step.
    public func beginWindowEdit() { model?.onGestureBegan?() }
    public func changeWindowEdit(_ w: StepWindow) {
        guard let model, let id = model.selectedStep else { return }
        model.setStepWindowGeometry(id, w)
    }
    public func endWindowEdit() { model?.onGestureEnded?() }

    // MARK: Sampling block

    private func refreshSamplingBlock() {
        guard let model, let t = session.activeTimeline else { return }
        var r: String?
        if let clip = targetClip { r = Self.samplingBlockReason(timeline: t, clip: clip, playhead: session.playhead) }
        else { r = onScreen ? nil : "Move the playhead into the sequence to measure it." }
        // Before / Split show the picture without (part of) the grade: measuring it would count the grade twice.
        if r == nil, isOnColorPage { r = Self.compareBlockReason(compare) }
        if model.samplingBlock != r { model.samplingBlock = r }
    }

    // MARK: Sync

    public func sync(_ change: EditorSession.Change) {
        if !isActive, change.isDisjoint(with: [.project, .selection]) {
            pendingWhileInactive.formUnion(change.intersection([.playhead, .transport]))
            skippedSyncs += 1
            return
        }
        defer {
            updateViewerAids()
            if change.contains(.playhead) || change.contains(.project) || change.contains(.selection) || change.contains(.transport) {
                refreshSamplingBlock()
                refreshHeader(structural: change.contains(.project) || change.contains(.selection) || barBase == nil)
                refreshKeyframeStates()
            }
        }
        // A keyframed grade shows the values at the playhead: reloaded when they differ from what is shown, never while
        // a gesture runs (the drag keeps the values and the time it started with).
        let structural = change.contains(.project) || change.contains(.selection)
        if !structural {
            guard change.contains(.playhead), gestureDepth == 0, let k = key, let clip = targetClip,
                  Self.hasAnimatedGrade(clip), let model = colorModels[k] else { return }
            let now = clip.color(atLocal: displayTime(clip))
            guard now != model.clipColor() else { return }
            model.load(now, mediaID: clip.media, info: session.media.info(of: clip.media))
            shownColor[k] = now
            return
        }
        if change.contains(.selection) { target.selectionChanged(session.selection, in: session.activeTimeline) }
        let timeline = session.activeTimeline
        format = ColorPageFormat(timeline?.format)
        resolution = target.resolve(in: timeline)
        var keep = Set(timeline?.tracks.flatMap { $0.clips.map(\.id) } ?? [])
        if let timeline { keep.insert(timeline.id) }
        let dropped = Set(colorModels.keys.filter { !keep.contains($0) })
        for k in dropped { colorModels[k] = nil; shownColor[k] = nil }
        if !dropped.isEmpty { onModelsDropped?(dropped) }
        switch resolution {
        case .clip(let id): key = id; emptyState = nil
        case .sequence(let tl, _): key = tl; emptyState = nil
        case .message(let m):
            key = nil
            emptyState = ColorTargetState.emptyState(m)
        }
        if let k = key, colorModels[k] == nil { makeModel(k) }
        // During a gesture the model keeps what it shows (its own edits come back here as project changes).
        if let k = key, let model = colorModels[k], gestureDepth == 0 || shownColor[k] == nil {
            let c = targetClip.map { $0.color(atLocal: displayTime($0)) } ?? .default
            model.load(c, mediaID: targetClip?.media ?? k, info: targetClip.flatMap { session.media.info(of: $0.media) })
            shownColor[k] = c
            model.loadGraph(targetClip?.colorGraph)
            model.loadSharpen(targetClip?.sharpenAmount ?? 0)
        }
        onGradeSwitchChange?()
        if let model { updateGradeInfo(targetClip, model) }
        if let model, model.projectInput != session.project.inputColorSpace {
            model.projectInput = session.project.inputColorSpace
        }
        updateLowerPage()
        onSynced?()
    }

    private func makeModel(_ k: UUID) {
        let model = ColorInspectorModel()
        model.lutStore = .shared
        model.onGestureBegan = { [weak self] in self?.beginGesture() }
        model.onGestureEnded = { [weak self] in self?.endGesture() }
        model.onGestureCancelled = { [weak self] in self?.cancelGesture() }
        model.onChange = { [weak self] _ in self?.commit(k) }
        model.onGraphChange = { [weak self] g in self?.commitGraph(k, g) }
        model.onSharpenSet = { [weak self] v in self?.commitSharpen(k, v) }
        model.onGradeViewChange = { [weak self] in
            guard let self, k == self.key else { return }
            self.onGradeSwitchChange?()
            self.updateLowerPage()
            self.onChange?()
        }
        model.onViewerAidChange = { [weak self] in self?.updateViewerAids() }
        model.onCopyColor = { [weak self] in _ = self?.copyGrade() }
        model.onPasteColor = { [weak self] in if self?.pasteGrade() != true { self?.beep() } }
        model.onGradeAction = { [weak self] a in
            guard let self else { return }
            guard let id = self.targetClip?.id else { self.beep(); return }
            self.gradeAction(a, clip: id)
        }
        model.onGradeWholeSequence = { [weak self] in self?.pickWholeSequence() }
        model.onResetAll = { [weak self] in
            guard let self, let id = self.targetClip?.id else { return }
            _ = self.session.resetColor(of: id)
        }
        model.onProjectInputChange = { [weak self] in self?.session.setProjectInputColorSpace($0) }
        model.onAutoTone = { [weak self] effect in self?.autoTone(key: k, effect: effect) }
        model.onPickWhiteBalance = { [weak self] effect in self?.pickWhiteBalance(key: k, effect: effect) }
        model.onKeyframe = { [weak self] action, id in self?.keyframe(action, id, key: k) }
        colorModels[k] = model
        onModelMade?(k, model)
    }

    // MARK: Header

    /// The target's description without its "On screen" line: rebuilt only on project or selection changes (the link
    /// state walks the project), not on playhead ticks.
    private var barBase: ColorTargetBarContent?

    /// The viewer header, the panel header detail, the lower panel's buttons and the Scopes hint. Playhead ticks only
    /// update the "On screen" line.
    private func refreshHeader(structural: Bool) {
        let t = session.activeTimeline
        if structural {
            switch resolution {
            case .clip(let id): barBase = clip(id).map { .clip($0, project: session.project) }
            case .sequence: barBase = t.map { .wholeSequence($0) }
            case .message: barBase = ColorTargetBarContent(title: "")
            }
            viewerHeaderContent = .make(resolution, timeline: t)
            let outline = ColorGradeOutline.clips(resolution, project: session.project)
            if outline != gradeOutline { gradeOutline = outline; onGradeOutlineChange?(outline) }
            updateSolo()
            updateCompare()
            let detail = Self.headerDetail(resolution, session: session)
            if detail != headerDetail {
                headerDetail = detail
                onHeaderDetailChange?(detail)
            }
            let tlDetail = Self.timelineDetail(for: resolution)
            if tlDetail != timelineDetail { timelineDetail = tlDetail; onTimelineDetailChange?(tlDetail) }
            onHeaderRefresh?()
        }
        guard var c = barBase else { return }
        if case .clip = resolution {
            c.onScreen = ColorTargetState.onScreenHint(target: resolution, timeline: t, playhead: session.playhead)
        }
        targetContent = c
        if lastHint != .some(c.onScreen) {
            lastHint = .some(c.onScreen)
            onScreenHintChange?(c.onScreen)
        }
    }

    /// What the viewer header shows (name, "n of m", format), rebuilt on structural syncs.
    public private(set) var viewerHeaderContent = ColorViewerHeaderContent.make(.message(""), timeline: nil)

    // MARK: Measuring (eyedropper, Auto)

    /// White-balance eyedropper: the next click on the Program monitor samples the rendered frame; Temperature and Tint
    /// are set so the picked color becomes neutral (one undo step).
    private func pickWhiteBalance(key k: UUID, effect: Int) {
        guard colorModels[k]?.samplingBlock == nil, let pickScreenColor else { beep(); return }
        var at: EditTime?
        pickScreenColor({ [weak self] in at = self?.editTime(k) }) { [weak self] rgb in   // the frame that is sampled
            guard let self, let model = self.colorModels[k], let rgb, model.samplingBlock == nil,
                  let r = WhiteBalanceSolver.solve(picked: rgb, temperature: model.value(effect, .temperature),
                                                   tint: model.value(effect, .tint)) else { self?.beep(); return }
            self.withEditTime(at ?? self.editTime(k)) { model.setWhiteBalance(effect, temperature: r.temperature, tint: r.tint) }
        }
    }

    /// Basic Correction Auto: analyzes the Program frame as shown (asynchronously; only when the target is alone there).
    private func autoTone(key k: UUID, effect: Int) {
        guard let model = colorModels[k], model.autoToneBlock(effect) == nil, let sampleProgramFrame else { beep(); return }
        let at = editTime(k)                                            // the frame that is analyzed
        sampleProgramFrame(96) { [weak self] linear in
            guard let self, let model = self.colorModels[k], let linear, model.autoToneBlock(effect) == nil,
                  let e = model.color.effect(effect),
                  let b = AutoTone.solve(linear: linear, current: e.basic) else { self?.beep(); return }
            self.withEditTime(at) { model.setAutoTone(effect, b) }
        }
    }

    // MARK: Gestures and commits

    private var gestureDepth = 0
    private var gestureHasEdit = false
    /// The grade the model showed before its pending edit, per target: an edit writes only what differs from it.
    private var shownColor: [UUID: ClipColor] = [:]
    /// Clip-local edit time captured when a gesture began, or when an asynchronous edit (Auto, eyedropper) was asked for.
    private var pinnedEditTime: EditTime?
    /// Undo depth when the running gesture began (its edits are the steps above it).
    private var gestureStartDepth = 0

    private struct EditTime { var local: Time? }

    private func clip(_ id: Clip.ID) -> Clip? {
        session.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id }
    }

    private var frameDuration: Time { session.activeTimeline?.frameDuration ?? Time(1, 30) }

    /// Clip-local time keyed values are edited at: the playhead on the target's frames, nil when it is not over it. The
    /// Timeline grade before its layer exists starts at zero (it will cover the sequence).
    private func editTime(_ k: UUID) -> EditTime {
        if k == session.activeTimelineID, targetClip == nil {
            return EditTime(local: session.playhead < (session.activeTimeline?.duration ?? .zero) ? session.playhead : nil)
        }
        return EditTime(local: targetClip?.colorEditTime(atPlayhead: session.playhead, frameDuration: frameDuration))
    }

    private func withEditTime(_ t: EditTime, _ body: () -> Void) {
        let saved = pinnedEditTime
        pinnedEditTime = t
        body()
        pinnedEditTime = saved
    }

    private func beginGesture() {
        if gestureDepth == 0 {
            gestureHasEdit = false
            gestureStartDepth = session.undoDepth
            if pinnedEditTime == nil, let k = key { pinnedEditTime = editTime(k) }
        }
        gestureDepth += 1
    }

    /// Esc during a drag: the gesture ends and every step it made is withdrawn (values, keys, a created Color effect or
    /// Timeline grade layer, clips that joined a link), so no undo step is left. The panel shows the target again.
    private func cancelGesture() {
        guard gestureDepth > 0 else { return }
        let hadEdit = gestureHasEdit
        gestureDepth = 0
        gestureHasEdit = false
        pinnedEditTime = nil
        if hadEdit { session.rewindUndo(toDepth: gestureStartDepth) }
        sync([.project])
        if hadEdit { onChange?() }
    }

    private func endGesture() {
        gestureDepth = max(gestureDepth - 1, 0)
        if gestureDepth == 0 { pinnedEditTime = nil }
    }

    /// Writes the model's edit to the target: only the values that changed against what the model showed, keyed values at
    /// the time the gesture began. Edits of one gesture merge into one undo step; unchanged values make no step. A keyed
    /// edit with the playhead outside the clip is refused (beep) and the panel shows the target again. A clip edit while
    /// "Linked" grades its source's clips too; the first Timeline edit creates the Timeline grade layer.
    private func commit(_ k: UUID) {
        guard k == key, let model = colorModels[k] else { return }
        let color = model.clipColor()
        let before = shownColor[k] ?? targetClip.map { $0.color(atLocal: displayTime($0)) } ?? .default
        guard color != before else { return }
        let t = pinnedEditTime ?? editTime(k)
        var refused = false
        let edit: (inout Clip) -> Bool = { c in
            guard c.setColor(color, editedFrom: before, atLocal: t.local) else { refused = true; return false }
            return true
        }
        let continuing = gestureDepth > 0 && gestureHasEdit
        let changed: Bool
        switch resolution {
        case .clip(let id): changed = session.editClipColor(id, continuesGesture: continuing, edit)
        case .sequence:
            changed = session.editSequenceGrade(continuesGesture: continuing, edit)
            // The first edit created the layer: the timeline shows what is graded.
            if let g = session.activeTimeline?.sequenceGradeClip, session.selection != [g.id] { session.select(clips: [g.id]) }
        case .message: return
        }
        if refused {
            beep()
            let back = targetClip.map { $0.color(atLocal: displayTime($0)) } ?? .default
            model.load(back, mediaID: targetClip?.media ?? k, info: targetClip.flatMap { session.media.info(of: $0.media) })
            shownColor[k] = back
            return
        }
        shownColor[k] = color
        guard changed else { return }
        // Interpret As on a selection of clips: the same space goes to every selected clip (one more undo step).
        if case .clip(let id) = resolution, color.source != before.source, session.selection.count > 1, session.selection.contains(id) {
            session.setInterpretation(color.source, for: Array(session.selection))
        }
        if gestureDepth > 0 { gestureHasEdit = true }
        onChange?()
    }

    /// Writes the model's Color Graph to the target (one undo step per gesture, like `commit`). Not keyframed.
    private func commitGraph(_ k: UUID, _ g: ColorGraph) {
        guard k == key else { return }
        let edit: (inout Clip) -> Bool = { c in
            guard c.colorGraph != g else { return false }
            c.colorGraph = g
            return true
        }
        let continuing = gestureDepth > 0 && gestureHasEdit
        let changed: Bool
        switch resolution {
        case .clip(let id): changed = session.editClipColor(id, name: "Color Graph", continuesGesture: continuing, edit)
        case .sequence:
            changed = session.editSequenceGrade(name: "Color Graph", continuesGesture: continuing, edit)
            if let l = session.activeTimeline?.sequenceGradeClip, session.selection != [l.id] { session.select(clips: [l.id]) }
        case .message: return
        }
        guard changed else { return }
        if gestureDepth > 0 { gestureHasEdit = true }
        onGradeSwitchChange?()
        updateLowerPage()
        onChange?()
    }

    /// Writes the Basic Sharpen row to the target's Sharpen effect (one undo step per gesture; the Timeline grade layer
    /// is created by the first non-zero value). shortcut: only the target clip, a "Linked" source's other cuts keep their
    /// own Sharpen; upgrade when Sharpen joins the grade link (needs a ProjectFile change).
    private func commitSharpen(_ k: UUID, _ v: Float) {
        guard k == key else { return }
        let edit: (inout Clip) -> Bool = { $0.setSharpenAmount(v) }
        let continuing = gestureDepth > 0 && gestureHasEdit
        let changed: Bool
        switch resolution {
        case .clip(let id): changed = session.editClipColor(id, name: "Sharpen", continuesGesture: continuing, edit)
        case .sequence:
            changed = session.editSequenceGrade(name: "Sharpen", continuesGesture: continuing, edit)
            if let l = session.activeTimeline?.sequenceGradeClip, session.selection != [l.id] { session.select(clips: [l.id]) }
        case .message: return
        }
        guard changed else { return }
        if gestureDepth > 0 { gestureHasEdit = true }
        onChange?()
    }

    // MARK: Keyframes (INTERACTION-AUDIT rule 2)

    /// The keyframe rings and navigation of the target: the state of every animated control at the playhead.
    private func refreshKeyframeStates() {
        guard let k = key, let model = colorModels[k] else { return }
        let clip = targetClip
        let states = ColorKeyTarget.states(of: clip, local: clip.map { session.playhead - $0.start } ?? .zero,
                                           playheadInRange: editTime(k).local != nil)
        if model.keyframeStates != states { model.keyframeStates = states }
    }

    /// A click on a color control's ring or navigation. Turning animation off removes every key of the control and asks
    /// first; a key is added or removed at the playhead (beep when it is not over the target).
    public func keyframe(_ action: ColorKeyAction, _ id: ColorKeyID, key k: UUID) {
        guard k == key, gestureDepth == 0 else { return }
        let keys = id.target.parameterKeys, n = id.effect, name = id.target.name
        let clip = targetClip
        switch action {
        case .previous, .next:
            guard let clip else { beep(); return }
            let local = session.playhead - clip.start
            let times = ColorKeyTarget.navigableTimes(clip, effect: n, target: id.target)
            let t = action == .previous ? times.last { $0 < local } : times.first { $0 > local }
            guard let t else { beep(); return }
            session.seek(to: clip.start + t)
            sync([.playhead])
        case .toggleAnimation:
            if let clip, clip.isColorAnimated(effect: n, keys: keys) {
                guard confirmStopAnimating(name) else { return }
                let at = displayTime(clip)
                editKeys("Stop Animating \(name)") { $0.setColorAnimated(false, effect: n, keys: keys, atLocal: at) }
            } else {
                guard let at = editTime(k).local else { beep(); return }
                editKeys("Animate \(name)") { $0.setColorAnimated(true, effect: n, keys: keys, atLocal: at) }
            }
        case .toggleKey:
            guard let at = editTime(k).local else { beep(); return }
            let has = clip?.hasColorKey(effect: n, keys: keys, atLocal: at) ?? false
            editKeys(has ? "Remove \(name) Keyframe" : "Add \(name) Keyframe") {
                $0.toggleColorKey(effect: n, keys: keys, atLocal: at)
            }
        }
    }

    /// One undo step `name` on the target (the Timeline grade layer is created by its first edit).
    private func editKeys(_ name: String, _ body: (inout Clip) -> Bool) {
        let changed: Bool
        let name = SQL10n.undoName(name)
        switch resolution {
        case .clip(let id): changed = session.editClipColor(id, name: name, continuesGesture: false, body)
        case .sequence:
            changed = session.editSequenceGrade(name: name, continuesGesture: false, body)
            if let g = session.activeTimeline?.sequenceGradeClip, session.selection != [g.id] { session.select(clips: [g.id]) }
        case .message: return
        }
        guard changed else { beep(); return }
        sync([.project])
        onChange?()
    }

    /// Clip-local time the panel shows: the playhead, kept on the clip's frames (outside it, the first or last frame).
    private func displayTime(_ clip: Clip) -> Time { Self.local(clip, session.playhead, frameDuration: frameDuration) }

    // MARK: Grades: copy/paste, links, ranges (COLOR-GRADE-LINKS)

    /// Copies the target's grade (Copy while the Color panel has focus). False when nothing is shown.
    @discardableResult
    public func copyGrade() -> Bool {
        guard key != nil else { return false }
        ColorClipboard.shared.copy(targetClip?.colorGradeEffects ?? [], graph: targetClip?.colorGraph)
        return true
    }

    /// Pastes the copied grade: for "Whole sequence" onto the Timeline grade, else onto every selected picture clip (the
    /// picked clip when nothing is selected). One undo step. False when nothing changed.
    @discardableResult
    public func pasteGrade(onTop: Bool = false) -> Bool {
        guard let fx = ColorClipboard.shared.effects else { return false }
        let g = ColorClipboard.shared.graph
        if case .sequence = resolution { return session.pasteSequenceGrade(effects: fx, graph: .some(g), onTop: onTop) }
        if session.selection.isEmpty, let p = target.pick {
            return session.pasteColor(effects: fx, graph: .some(g), to: [p], onTop: onTop) > 0
        }
        return session.pasteColor(effects: fx, graph: .some(g), onTop: onTop) > 0
    }

    public var canCopyGrade: Bool { key != nil }
    public var canPasteGrade: Bool {
        guard ColorClipboard.shared.hasColor else { return false }
        if case .sequence = resolution { return true }
        return !session.selection.isEmpty || target.pick != nil
    }

    public func gradeAction(_ a: ColorGradeAction, clip id: Clip.ID) {
        let ok: Bool
        switch a {
        case .linkSelected: ok = session.linkGrades(source: id) != nil
        case .linkSource: ok = session.linkAllClipsOfSource(id) != nil
        case .unlink: ok = session.setGradeLinkedToSource(id, false)
        case .addRange: ok = session.addRangeGrade(to: id) != nil
        case .setRangeToInOut(let n), .wholeClip(let n):
            guard let all = clip(id)?.colorGradeEffects, all.indices.contains(n - 1) else { ok = false; break }
            let fx = all[n - 1]
            if case .wholeClip = a { ok = session.setColorRange(of: fx.id, in: id, wholeClip: true) }
            else { ok = session.setColorRange(of: fx.id, in: id, wholeClip: false) }
        }
        if !ok { beep() }
    }

    /// Range texts and the link size for the panel titles.
    private func updateGradeInfo(_ clip: Clip?, _ model: ColorInspectorModel) {
        var labels: [Int: String] = [:]
        for (n, e) in (clip?.colorGradeEffects ?? []).enumerated() {
            guard let r = e.colorRange else { continue }
            labels[n + 1] = "\(MarkersPanelModel.timecode(r.start, frameDuration: frameDuration))\u{2013}\(MarkersPanelModel.timecode(r.end, frameDuration: frameDuration))"
        }
        if model.effectRangeLabels != labels { model.effectRangeLabels = labels }
        let n = clip.map { session.gradeLinkMembers(of: $0.id).count } ?? 0
        if model.linkedClipCount != n { model.linkedClipCount = n }
    }
}

// MARK: Rules (pure, shared by both platforms and the tests)

extension ColorGradeController {
    /// What the header of the Timeline and Sources panels says a click does there.
    public static let timelineHint = "Click a clip or the adjustment layer to grade it"
    public static let sourcesHint = "Every source once \u{00B7} grading one grades every use in the sequence"

    /// The Timeline panel's header text: the hint only while nothing gradable is picked.
    public static func timelineDetail(for resolution: ColorTargetResolution) -> String {
        if case .message = resolution { return timelineHint }
        return ""
    }

    /// Every clip inside nested clip `c`'s sequence, deeper nests included (empty for a plain clip). Cycles are cut.
    public static func nestedClips(of c: Clip, in project: Project) -> Set<Clip.ID> {
        var out = Set<Clip.ID>()
        var seen = Set<Timeline.ID>()
        var queue = [c.sequence].compactMap { $0 }
        while let tid = queue.popLast() {
            guard seen.insert(tid).inserted, let t = project.timeline(tid) else { continue }
            for clip in t.tracks.flatMap(\.clips) {
                out.insert(clip.id)
                if let s = clip.sequence { queue.append(s) }
            }
        }
        return out
    }

    /// Before = the target (and every clip sharing its grade) ungraded; Split = the same on the left half; After or no
    /// target = nil (graded).
    public static func colorBypass(_ mode: ColorCompareMode, target: Clip.ID?, linked: [Clip.ID]) -> ColorBypass? {
        guard let target else { return nil }
        let clips = Set(linked).union([target])
        switch mode {
        case .after: return nil
        case .before: return ColorBypass(clips: clips, mode: .before)
        case .split: return ColorBypass(clips: clips, mode: .split)
        }
    }

    /// Which clip the monitor isolates: only while the lower panel is on Clips, the strip is visible and a clip is picked.
    public static func soloClip(clipsMode: Bool, stripVisible: Bool, picked: Clip.ID?) -> Clip.ID? {
        clipsMode && stripVisible ? picked : nil
    }

    /// Why the eyedropper and Auto cannot measure the selected clip alone right now (nil = they can). They read the
    /// Program monitor's composite, so anything else visible there, or later Color effects, would be measured too.
    public static func samplingBlockReason(timeline: Timeline, clip: Clip, playhead: Time) -> String? {
        guard clip.timeline.contains(playhead) else { return "Move the playhead over the clip to measure it." }
        // Auto and the eyedropper set Simple values; the Pro grade on screen would be measured with them.
        if clip.activeGrade == .pro { return "The Pro grade is on; the measurement would include its Color Graph. Switch to Simple to measure." }
        // The Timeline grade measures the finished picture: everything below it is its input.
        if clip.isSequenceGrade { return nil }
        let layers = timeline.videoLayers(at: playhead).filter { $0.matteFor == nil }     // mattes are never drawn
        if layers.count > 1 {
            let others = layers.filter { $0.clip != clip.id }
            if let g = timeline.sequenceGradeClip, others.allSatisfy({ $0.clip == g.id }) {
                return "The Timeline grade is on screen too; the measurement would include it. Turn its track off to measure the clip."
            }
            return "Other layers are visible at the playhead; the measurement would include them. Hide the other tracks or move the playhead."
        }
        if clip.effects.filter({ $0.isColor && $0.enabled }).count > 1 { return "This clip has more than one Color effect; the measurement would include the later ones." }
        return nil
    }

    /// Why the eyedropper and Auto cannot measure while the viewer compares (nil on After).
    public static func compareBlockReason(_ mode: ColorCompareMode) -> String? {
        switch mode {
        case .after: nil
        case .before: "The viewer shows Before; the measurement would miss the grade. Switch the viewer to After to measure."
        case .split: "The viewer shows Split; the measurement would miss part of the grade. Switch the viewer to After to measure."
        }
    }

    /// "n uses" for a clip: the clips that share its grade (itself alone when it is not linked).
    public static func headerDetail(_ r: ColorTargetResolution, session: EditorSession) -> String? {
        switch r {
        case .clip(let id):
            let p = session.project
            var n = session.gradeLinkMembers(of: id).count
            // Uses of a source share its grade before the first edit writes the link.
            if p.isGradeLinkedToSource(id), let media = p.timelines.lazy.flatMap(\.tracks).flatMap(\.clips).first(where: { $0.id == id })?.media {
                var uses = 0
                for t in p.timelines { for tr in t.tracks { uses += tr.clips.count(where: { $0.media == media && $0.isSourceGradeable && p.isGradeLinkedToSource($0.id) }) } }
                n = max(n, uses)
            }
            return ColorUses.text(max(n, 1))
        case .sequence: return "Whole sequence"
        case .message: return nil
        }
    }

    public static func local(_ clip: Clip, _ playhead: Time, frameDuration: Time) -> Time {
        min(max(playhead - clip.start, .zero), max(clip.duration - frameDuration, .zero))
    }

    public static func hasAnimatedGrade(_ clip: Clip) -> Bool {
        clip.effects.contains { $0.isColor && $0.parameters.values.contains(where: \.isAnimated) }
    }
}

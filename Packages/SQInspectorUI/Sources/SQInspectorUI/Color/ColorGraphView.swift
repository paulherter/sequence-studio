import AppKit
import SQCore
import UniformTypeIdentifiers

/// The Pro page of the Color panel: the layer list, then the selected Step's inspector (name line with Reset and its
/// menu, the primaries, the Step's LUT pill and intensity, then curves, hue curves, qualifier and window).
@MainActor
final class ColorGraphPage: NSStackView, NSTextFieldDelegate {
    let model: ColorInspectorModel
    let list = ColorLayerListView(frame: NSRect(x: 0, y: 0, width: 320, height: ColorLayerListView.footerHeight))
    private var actions: ColorActionRow!
    /// The lower panel of the Color page shows the same Steps as a graph: the layer list here hides then.
    var showsStrip = true { didSet { if showsStrip != oldValue { applyEmpty() } } }
    /// Version 9, Pro on a clip without a Color Graph: the page only says so. The Steps panel below holds the two
    /// start buttons; they show here while that panel shows something else.
    private let empty = EmptyStateView(title: "No Pro grade yet", hint: "Start from the graph below. Nothing in your Simple grade changes.")
    private lazy var startRow = ColorActionRow(title: "", controls: [
        SQButton(title: "Start empty", target: self, action: #selector(startEmptyPressed), style: .accent),
        SQButton(title: "Start from Simple grade", target: self, action: #selector(startFromSimplePressed)),
    ])
    private(set) var isEmpty = false
    static let emptyHeight: CGFloat = 96
    static let tabTitles = ["Primaries", "Curves", "Qualifier", "Window", "LUT", "Effects"]
    /// Posted with the tab index as `object`: the render harness shows each Step tab (nothing else posts it).
    static let selectTabNote = Notification.Name("sq.color.selectProTab")
    let tabs = ColorTabHeaderView(tabs: ColorGraphPage.tabTitles)
    private let eye = SQButton(symbol: .eye, label: "Step on", target: nil, action: nil, size: 12)
    /// Key wires and free wiring are stored but the renderer does not apply them: say so (never pretend).
    private lazy var wiringRow = ColorActionRow(title: Self.wiringNotice, controls: [])
    static let wiringNotice = "Free wiring is saved. The picture still follows the Step order."
    private lazy var offRow = ColorActionRow(title: "This Step is off. Its values are kept.", controls: [SQButton(title: "Turn On", target: self, action: #selector(eyePressed))])
    private var lutRows: [NSView] = []
    private lazy var detail = ColorStepDetailView(model: model)
    private var rows: [StepParam: ColorParamRow] = [:]
    private let lutPill = SQButton(title: "None", target: nil, action: nil)
    private let lutImport = SQButton(title: "Import\u{2026}", target: nil, action: nil, style: .standard)

    override var isFlipped: Bool { true }

    init(model: ColorInspectorModel) {
        self.model = model
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        build()
        NotificationCenter.default.addObserver(forName: Self.selectTabNote, object: nil, queue: .main) { [weak self] n in
            guard let i = n.object as? Int else { return }
            MainActor.assumeIsolated { self?.tabs.select(i); self?.applyTab() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func pin(_ v: NSView) {
        addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func build() {
        list.onSelect = { [weak self] id in self?.model.selectedStep = id }
        list.onAdd = { [weak self] in self?.model.addLayerOnTop() }
        list.onToggle = { [weak self] id in
            guard let self, let s = self.model.step(id) else { return }
            self.model.setStepEnabled(id, !s.enabled)
        }
        list.onBlend = { [weak self] id, b in self?.model.setStepBlend(id, b) }
        list.onMove = { [weak self] id, row in self?.model.moveStep(id, toListRow: row) }
        list.onMix = { [weak self] id, v in self?.model.setStep(id, .mix, v) }
        list.onMixBegin = { [weak self] in self?.model.onGestureBegan?() }
        list.onMixEnd = { [weak self] in self?.model.onGestureEnded?() }
        offRow.isWarning = true
        wiringRow.isWarning = true
        tabs.showsBottomRule = false
        for r in [startRow, offRow, wiringRow] { r.showsRules = false }
        list.onStepMenu = { [weak self] id, p in self?.showStepMenu(id, at: p) }
        list.onChip = { [weak self] slot, p in self?.showLUTMenu(slot == .input ? .graphInput : .graphOutput, at: p) }
        empty.heightAnchor.constraint(equalToConstant: Self.emptyHeight).isActive = true
        empty.titleLabel.font = Theme.Typography.emptyHeading      // version 9 `.gempty b`: 15 semibold
        pin(empty)
        pin(startRow)
        pin(list)

        // Version 9 path line: the Step's number and name, its eye, and its menu (Reset Step is in there).
        eye.target = self; eye.action = #selector(eyePressed)
        eye.contentTintColor = Theme.Colors.label2
        let more = SQButton(symbol: .ellipsis, label: "More Step actions", target: self, action: #selector(morePressed(_:)), size: 12)
        more.contentTintColor = Theme.Colors.label2
        actions = ColorActionRow(title: "", controls: [eye, more])
        actions.showsRules = false
        pin(actions)
        pin(offRow)
        pin(wiringRow)
        tabs.onSelect = { [weak self] i in self?.tabs.select(i); self?.applyTab() }
        tabs.heightAnchor.constraint(equalToConstant: ColorHeaderMetrics.height).isActive = true
        pin(tabs)

        // Version 9: the Primaries tab (wheels, Saturation, Contrast, Pivot) is built by `ColorStepDetailView`.
        lutPill.target = self; lutPill.action = #selector(lutPillPressed(_:))
        lutPill.setAccessibilityLabel("Step LUT")
        lutPill.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lutImport.target = self; lutImport.action = #selector(lutImportPressed)
        lutImport.setAccessibilityLabel("Import LUT file")
        // Version 9: a wide chooser and Import…; "None" in the chooser (or the Step menu) clears the LUT.
        let lutRow = ColorFormRow(controls: [lutPill, lutImport], stretchFirst: true)
        let intensity = row(.lutIntensity)
        let note = ColorFootnote("Supports .cube and .3dl. Imported files are kept with the project.")
        lutRows = [lutRow, intensity, note]
        pin(lutRow)
        pin(intensity)
        pin(note)
        pin(detail)
        applyTab()
    }

    /// Shows the rows of the selected tab: Primaries, Curves (RGB and hue), Qualifier (with the matte preview), Window, LUT.
    private func applyTab() {
        let t = tabs.selected
        for r in lutRows { r.isHidden = isEmpty || t != 4 }
        detail.show(tab: t)
    }

    private func applyEmpty() {
        empty.isHidden = !isEmpty
        empty.hint = showsStrip ? "Nothing in your Simple grade changes." : "Start from the graph below. Nothing in your Simple grade changes."
        startRow.isHidden = !isEmpty || !showsStrip
        list.isHidden = isEmpty || !showsStrip
        actions.isHidden = isEmpty
        tabs.isHidden = isEmpty
        detail.isHidden = isEmpty
        if isEmpty { offRow.isHidden = true; wiringRow.isHidden = true }
        applyTab()
    }

    @objc private func startEmptyPressed() { model.startEmptyGraph(); SQToast.show("Color Graph added to this clip", in: self) }
    @objc private func startFromSimplePressed() { model.startFromSimple(); SQToast.show("Copied from Simple. Simple is unchanged.", in: self) }

    @objc private func eyePressed() {
        guard let id = model.selectedStep, let s = model.step(id) else { return }
        model.setStepEnabled(id, !s.enabled)
    }

    private func row(_ p: StepParam) -> ColorParamRow {
        let r = ColorParamRow(nil, title: p.title, range: p.range, neutral: p.neutral, decimals: p.decimals)
        r.setActive(true)
        r.onBegin = { [weak self] in self?.model.onGestureBegan?() }
        r.onEnd = { [weak self] in self?.model.onGestureEnded?() }
        r.onCancel = { [weak self] in self?.model.onGestureCancelled?() }
        r.onSet = { [weak self] v in guard let self, let id = self.model.selectedStep else { return }; self.model.setStep(id, p, v) }
        r.onReset = { [weak self] in guard let self, let id = self.model.selectedStep else { return }; self.model.resetStepValue(id, p) }
        rows[p] = r
        return r
    }

    func refresh() {
        let g = model.graph
        if isEmpty != (g == nil) || empty.isHidden == isEmpty { isEmpty = g == nil; applyEmpty() }
        list.items = (g?.listSteps ?? []).map { st in
            .init(id: st.id, label: st.label, enabled: st.enabled, hasLUT: st.lut != nil, blend: g?.blend(of: st.id) ?? .series,
                  mix: st.mix, isBase: st.id == g?.steps.first?.id)
        }
        list.isEditable = g?.allowsListEdit ?? true
        list.selected = model.selectedStep
        list.inLUT = model.graphLUTChoice(.input)?.name
        list.outLUT = model.graphLUTChoice(.output)?.name
        let step = model.selectedStep.flatMap(model.step)
        let number = step.flatMap { s in g?.steps.firstIndex { $0.id == s.id } }.map { String(format: "%02d", $0 + 1) }
        actions.title.stringValue = step.map { "\(number ?? "")   \($0.label)" } ?? ""
        let on = step?.enabled ?? true
        eye.image = Theme.symbol(on ? .eye : .eyeOff, size: 12, label: on ? "Step on" : "Step off")
        eye.isEnabled = step != nil
        offRow.isHidden = on || isEmpty
        let notice = Self.wiringNotice(g, selected: step?.id)
        wiringRow.title.stringValue = notice ?? ""
        wiringRow.isHidden = notice == nil || isEmpty
        for (p, r) in rows {
            r.show(step.map(p.read) ?? p.neutral)
            r.setActive(step != nil && (p != .lutIntensity || step?.lut != nil))
        }
        detail.refresh()
        let lut = model.selectedStep.flatMap(model.stepLUTChoice)
        lutPill.title = lut?.name ?? "Choose LUT\u{2026}"
        lutPill.isEnabled = step != nil
        lutImport.isEnabled = step != nil
    }

    // MARK: Menus

    @objc private func morePressed(_ b: SQButton) {
        guard let id = model.selectedStep, let w = b.window else { return }
        showStepMenu(id, at: w.convertPoint(toScreen: b.convert(NSPoint(x: 0, y: b.bounds.maxY), to: nil)))
    }

    @objc private func lutPillPressed(_ b: SQButton) {
        guard let w = b.window else { return }
        showLUTMenu(.step, at: w.convertPoint(toScreen: b.convert(NSPoint(x: 0, y: b.bounds.maxY), to: nil)))
    }

    @objc private func lutImportPressed() {
        guard let id = model.selectedStep, let path = Self.chooseLUTFile() else { return }
        model.setStepLUT(id, .file(path))
    }

    private static func chooseLUTFile() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["cube", "3dl"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .cube or .3dl LUT"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    typealias LUTTarget = ColorGraphMenus.LUTTarget

    /// The shared menu builders, with this page's file chooser, renaming, Tidy Up and decision import.
    var menuBuilder: ColorGraphMenus {
        var m = ColorGraphMenus(model: model, tidyUp: { [weak self] in self?.tidyUp() })
        m.chooseLUTFile = { done in done(Self.chooseLUTFile()) }
        m.rename = { [weak self] id in self?.rename(id) }
        m.importDecision = { [weak self] id in self?.importDecision(into: id) }
        return m
    }

    func lutItems(_ t: LUTTarget) -> [SQMenuItem] { menuBuilder.lutItems(t) }

    func showLUTMenu(_ t: LUTTarget, at p: NSPoint) {
        guard model.graph != nil else { return }
        SQMenuController.shared.present(items: lutItems(t), at: p)
    }

    func stepMenuItems(_ id: UUID) -> [SQMenuItem] { menuBuilder.stepMenuItems(id) }

    static func wiringNotice(_ g: ColorGraph?, selected: UUID?) -> String? {
        guard let g else { return nil }
        if g.hasCustomWiring { return wiringNotice }
        return nil
    }

    static func kindTitle(_ k: StepKind) -> String { ColorGraphMenus.kindTitle(k) }

    func addMenuItems() -> [SQMenuItem] { menuBuilder.addMenuItems() }

    func showAddMenu(at p: NSPoint) {
        guard model.graph != nil else { return }
        SQMenuController.shared.present(items: addMenuItems(), at: p)
    }

    func showInsertMenu(after id: UUID, at p: NSPoint) {
        SQMenuController.shared.present(items: menuBuilder.insertMenuItems(after: id), at: p)
    }

    /// Right-click on a mixer box.
    func showMixerMenu(_ head: UUID, at p: NSPoint) {
        SQMenuController.shared.present(items: menuBuilder.mixerMenuItems(head), at: p)
    }

    /// Right-click on empty canvas.
    func showCanvasMenu(at p: NSPoint) {
        SQMenuController.shared.present(items: menuBuilder.canvasMenuItems(), at: p)
    }

    private func tidyUp() {
        if let v = stepsGraphView, !showsStrip { v.tidyUp() } else { model.tidyUpSteps() }
    }

    /// The Steps graph that shows this page's Steps, when the lower panel has it up.
    weak var stepsGraphView: ColorStepsGraphView?

    /// Rename: in the Steps graph when it shows, else in the Step's name line above the tabs.
    func rename(_ id: UUID) {
        model.selectedStep = id
        if showsStrip {
            let t = actions.title
            t.stringValue = model.step(id)?.label ?? ""
            t.isEditable = true
            t.isSelectable = true
            t.drawsBackground = true
            t.backgroundColor = Theme.Colors.content
            t.delegate = self
            t.window?.makeFirstResponder(t)
            t.selectText(nil)
            renamingLine = id
        } else {
            model.beginRename(id)
        }
    }

    private var renamingLine: UUID?

    private func endLineRename(commit: Bool) {
        guard let id = renamingLine else { return }
        renamingLine = nil
        let t = actions.title
        let text = t.stringValue
        t.isEditable = false
        t.isSelectable = false
        t.drawsBackground = false
        t.delegate = nil
        if commit { model.renameStep(id, to: text) }
        refresh()
    }

    func showStepMenu(_ id: UUID, at p: NSPoint) {
        let items = stepMenuItems(id)
        guard !items.isEmpty else { return }
        SQMenuController.shared.present(items: items, at: p)
    }

    private func importDecision(into id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["cdl", "cc", "ccc", "edl"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a color decision file (ASC CDL or CMX EDL)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let n = try model.importColorDecision(try Data(contentsOf: url), fileExtension: url.pathExtension, into: id)
            if let notice = Self.importNotice(found: n) { SQDialog.info(notice, message: "The other decisions were not applied.", in: window) }
        } catch {
            SQDialog.warn(SQL10n.format("Could not import “%@”", url.lastPathComponent), message: Self.importFailure(error), in: window)
        }
    }

    /// The name line's editor: Return keeps the name, Escape or leaving the field ends it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { endLineRename(commit: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endLineRename(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { endLineRename(commit: true) }

    /// The notice after an import that found more than one decision (nil for one).
    static func importNotice(found n: Int) -> String? {
        n > 1 ? "\(n) color decisions found, applied the first" : nil
    }

    /// Why an import failed, in words.
    static func importFailure(_ error: Error) -> String {
        switch error as? ColorDecisionImport.ImportError {
        case .noDecisions?: "The file holds no color decision (ASC CDL Slope / Offset / Power / Saturation)."
        case .badValue(let what)?: "A \(what) value is not a number."
        case nil: SQL10n.errorText(error)
        }
    }
}

import Foundation
import SQCore

/// A value of a Step the step inspector edits. The four primaries set all three channels together (master).
public enum StepParam: Int, CaseIterable, Sendable {
    case lift, gamma, gain, offset, contrast, pivot, saturation, mix, lutIntensity

    public var title: String {
        switch self {
        case .lift: "Lift"
        case .gamma: "Gamma"
        case .gain: "Gain"
        case .offset: "Offset"
        case .contrast: "Contrast"
        case .pivot: "Pivot"
        case .saturation: "Saturation"
        case .mix: "Mix"
        case .lutIntensity: "Intensity"
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .lift: StepPrimaries.liftRange
        case .offset: StepPrimaries.offsetRange
        case .gamma: StepPrimaries.gammaRange
        case .gain: StepPrimaries.gainRange
        case .saturation: StepPrimaries.saturationRange
        case .contrast: StepPrimaries.contrastRange
        case .pivot: StepPrimaries.pivotRange
        case .mix, .lutIntensity: 0...100
        }
    }

    public var neutral: Float {
        switch self {
        case .lift, .offset: 0
        case .gamma, .gain, .contrast, .saturation: 1
        case .pivot: 0.435
        case .mix, .lutIntensity: 100
        }
    }

    public var decimals: Int { self == .mix ? 0 : self == .lutIntensity ? 1 : 3 }

    /// The master value: the channel mean of a triple.
    public func read(_ s: ColorStep) -> Float {
        func mean(_ t: ColorTriple) -> Float { (t.r + t.g + t.b) / 3 }
        switch self {
        case .lift: return mean(s.primaries.lift)
        case .gamma: return mean(s.primaries.gamma)
        case .gain: return mean(s.primaries.gain)
        case .offset: return mean(s.primaries.offset)
        case .contrast: return s.primaries.contrast
        case .pivot: return s.primaries.pivot
        case .saturation: return s.primaries.saturation
        case .mix: return s.mix
        case .lutIntensity: return s.lutIntensity
        }
    }

    /// Clamps to `range` and writes (a triple gets the value on every channel).
    public func write(_ value: Float, into s: inout ColorStep) {
        let v = min(max(value, range.lowerBound), range.upperBound)
        switch self {
        case .lift: s.primaries.lift = ColorTriple(all: v)
        case .gamma: s.primaries.gamma = ColorTriple(all: v)
        case .gain: s.primaries.gain = ColorTriple(all: v)
        case .offset: s.primaries.offset = ColorTriple(all: v)
        case .contrast: s.primaries.contrast = v
        case .pivot: s.primaries.pivot = v
        case .saturation: s.primaries.saturation = v
        case .mix: s.mix = v
        case .lutIntensity: s.lutIntensity = v
        }
    }
}

/// Where a wire of the Steps canvas starts or ends: the graph's source or sink, a Step, or the mixer box of a stack
/// (named by the stack's first Step).
public typealias StepsPort = GraphPort

/// The two LUT chips at the ends of the Color Graph.
public enum GraphLUTSlot: Sendable { case input, output }

extension ColorInspectorModel {
    /// Simple | Pro of the shown clip.
    public var activeGrade: ActiveGrade { graph?.isActive == true ? .pro : .simple }

    /// Shows the target's graph (no callbacks). The selection stays while its Step exists, else the first Step.
    public func loadGraph(_ g: ColorGraph?) {
        if graph != g { graph = g }
        guard let g else { if selectedStep != nil { selectedStep = nil }; return }
        if selectedStep.flatMap(g.step) == nil { selectedStep = g.steps.first?.id }
    }

    /// One graph edit as one undo step (slider drags run inside the row's own gesture).
    func editGraph(_ body: (inout ColorGraph) -> Void) {
        guard var g = graph else { return }
        body(&g)
        commitGraph(g)
    }

    /// One edit of one Step (an undo step; inside a slider or curve drag the host's gesture groups the changes).
    func editStep(_ id: UUID, _ body: (inout ColorStep) -> Void) { editGraph { $0.update(id, body) } }

    private func commitGraph(_ g: ColorGraph) {
        guard g != graph else { return }
        gesture {
            graph = g
            if selectedStep.flatMap(g.step) == nil { selectedStep = g.steps.first?.id }
            onGraphChange?(g)
        }
    }

    /// The page the panel shows: Pro while the Color Graph is the grade, and while the empty Pro page is open on a clip
    /// that has no graph yet (the Simple grade stays the clip's grade then).
    public var shownGrade: ActiveGrade { activeGrade == .pro || (showsEmptyPro && graph == nil) ? .pro : .simple }

    /// Makes Simple or Pro the clip's grade; the other keeps its values. Pro on a clip without a graph only opens the
    /// empty Pro page: the graph is added by `startEmptyGraph` or `startFromSimple`.
    public func setActiveGrade(_ m: ActiveGrade) {
        guard var g = graph else { showsEmptyPro = m == .pro; return }
        showsEmptyPro = false
        g.isActive = m == .pro
        commitGraph(g)
    }

    /// "Start empty": an active Color Graph with one neutral Step (one undo step). A clip that has a graph keeps it.
    public func startEmptyGraph() {
        var g = graph ?? ColorGraph()
        g.isActive = true
        showsEmptyPro = false
        commitGraph(g)
    }

    /// "Start from Simple grade": an active Color Graph whose Steps reproduce the Simple grade (one undo step). The
    /// Color effects keep their values. A clip that has a graph keeps it.
    public func startFromSimple() {
        guard graph == nil else { startEmptyGraph(); return }
        var g = ColorGraph(simple: color)
        let ids = g.steps.map(\.id)
        for (n, id) in ids.enumerated() { g.update(id) { $0.label = ids.count == 1 ? "From Simple" : "From Simple \(n + 1)" } }
        showsEmptyPro = false
        commitGraph(g)
    }

    /// Send to Pro is offered while the Simple grade is on and the clip has no Pro values worth keeping.
    public var canSendToPro: Bool { activeGrade == .simple && (graph == nil || graph?.isNeutral == true) }

    /// Makes the Simple grade's values Step 1 of an active Color Graph (one undo step). The Color effects keep all their
    /// values, dimmed by the exclusive rule (`Clip.renderColor` skips them while Pro is active).
    public func sendToPro() {
        guard canSendToPro else { return }
        var g = ColorGraph(simple: color)
        if let old = graph { g.outputLUT = old.outputLUT; g.outputLUTIntensity = old.outputLUTIntensity }
        commitGraph(g)
    }

    public func step(_ id: UUID) -> ColorStep? { graph?.step(id) }

    /// Adds a neutral Step of `kind` behind `id` (nil: at the end) and selects it (one undo step). A Parallel or Layer
    /// Step needs a Step before it: at the front it becomes a serial Step.
    public func addStep(after id: UUID?, kind: StepKind = .serial) {
        guard var g = graph else { return }
        let new = g.addStep(after: id, kind: kind)
        // The new Step gets its own place on the canvas: where the layout would put it, clear of every other box.
        let cols = g.columns.map { $0.map(\.id) }
        let pos = Dictionary(uniqueKeysWithValues: g.steps.compactMap { st in st.position.map { (st.id, $0) } })
        let mix = Dictionary(uniqueKeysWithValues: g.steps.compactMap { st in st.mixerPosition.map { (st.id, $0) } })
        if let p = StepsCanvas.freeSpot(for: new, columns: cols, positions: pos, mixerPositions: mix) { g.setPosition(new, p) }
        selectedStep = new
        selectedMixer = nil
        commitGraph(g)
    }

    /// Adds a Step of `kind` at the end of the graph.
    public func addStepAtEnd(kind: StepKind = .serial) { addStep(after: graph?.steps.last?.id, kind: kind) }

    /// Layer list: how the Step joins the rows below (Series, Parallel or a Layer mix). The base row and custom wiring refuse.
    public func setStepBlend(_ id: UUID, _ blend: StepBlend) {
        guard let g = graph, g.allowsListEdit else { return }
        editGraph { $0.setBlend(id, blend) }
    }

    /// Layer list: moves the Step to list row `row` (0 = top) and keeps it selected.
    public func moveStep(_ id: UUID, toListRow row: Int) {
        guard let g = graph, g.allowsListEdit else { return }
        editGraph { $0.moveStep(id, toListRow: row) }
        selectedStep = id
    }

    /// Layer list "+": a new Layer Step on top of the list.
    public func addLayerOnTop() { addStep(after: graph?.steps.last?.id, kind: .layer) }

    /// Changes how the Step joins the one before it (serial, parallel, layer).
    public func setStepKind(_ id: UUID, _ kind: StepKind) { editGraph { $0.setKind(id, kind) } }

    /// Renames a Step (blank names are ignored).
    public func renameStep(_ id: UUID, to name: String) { editGraph { $0.rename(id, to: name) } }

    /// Copies a Step right behind itself (kind, values, name + " copy") and selects the copy (one undo step).
    public func duplicateStep(_ id: UUID) {
        guard var g = graph, let s = g.step(id) else { return }
        let new = g.addStep(after: id, kind: s.kind)
        g.update(new) { c in
            let keep = c.id
            c = s
            c.id = keep
            c.label = s.label + " copy"
        }
        selectedStep = new
        commitGraph(g)
    }

    /// Asks the Steps graph to edit the Step's name in place (the Step menu's Rename).
    public func beginRename(_ id: UUID) {
        guard step(id) != nil else { return }
        selectedStep = id
        renamingStep = id
    }

    public func removeStep(_ id: UUID) { editGraph { $0.removeStep(id) } }

    /// Moves a Step `delta` places (clamped to the graph).
    public func moveStep(_ id: UUID, by delta: Int) {
        editGraph { g in
            guard let i = g.steps.firstIndex(where: { $0.id == id }) else { return }
            g.moveStep(id, to: i + delta)
        }
    }

    /// Stores where the Step sits on the Steps canvas (one undo step).
    public func setStepPosition(_ id: UUID, _ p: StepPosition?) { editGraph { $0.setPosition(id, p) } }

    /// Drops the Step on a wire of the Steps canvas: its own column between the columns around `gap`.
    public func moveStep(_ id: UUID, toGap gap: Int) {
        editGraph { $0.moveToGap(id, gap: gap) }
        selectedStep = id
    }

    // MARK: Mixer boxes and wires

    /// Deletes a mixer box: the Steps in its stack become serial Steps (one undo step).
    public func removeMixer(_ head: UUID) {
        editGraph { $0.dissolveMixer(head) }
        if selectedMixer == head { selectedMixer = nil }
    }

    /// Stores where a mixer box sits (one undo step); nil = automatic.
    public func setMixerPosition(_ head: UUID, _ p: StepPosition?) { editGraph { $0.setMixerPosition(head, p) } }

    /// Wires the output of `from` into the input of `to` (one undo step). Nil when done, else why it was refused (nothing
    /// changed). A Step's input holds one wire (the new one replaces it), a mixer box takes several, an output feeds any number.
    @discardableResult
    public func connect(_ from: StepsPort, to: StepsPort) -> LinkRefusal? {
        guard var g = graph else { return .unknownBox }
        if let r = g.connect(from, to: to) { return r }
        if case .step(let b) = to { selectedStep = b } else if case .step(let x) = from { selectedStep = x }
        selectedMixer = nil
        commitGraph(g)
        return nil
    }

    /// Takes one image wire away (one undo step).
    public func disconnect(_ link: GraphLink) { editGraph { $0.disconnect(link) } }

    /// Moves the end of a wire: `link` is taken off and `from` is wired to `to` in one undo step. Nothing changes when the
    /// new wire is refused (the refusal is returned).
    @discardableResult
    public func rewire(_ link: GraphLink, from: StepsPort, to: StepsPort) -> LinkRefusal? {
        guard var g = graph else { return .unknownBox }
        g.disconnect(link)
        if let r = g.connect(from, to: to) { return r }
        commitGraph(g)
        return nil
    }

    /// Wires the key output of Step `from` into the key input of a Step or mixer box (one undo step).
    @discardableResult
    public func connectKey(from: UUID, to: StepsPort) -> LinkRefusal? {
        guard var g = graph else { return .unknownBox }
        if let r = g.connectKey(from: from, to: to) { return r }
        commitGraph(g)
        return nil
    }

    /// Moves the end of a key wire (one undo step); nothing changes when the new wire is refused.
    @discardableResult
    public func rewireKey(_ link: GraphLink, from: StepsPort, to: StepsPort) -> LinkRefusal? {
        guard var g = graph, let id = from.stepID else { return .unknownBox }
        g.disconnectKey(link)
        if let r = g.connectKey(from: id, to: to) { return r }
        commitGraph(g)
        return nil
    }

    public func disconnectKey(_ link: GraphLink) { editGraph { $0.disconnectKey(link) } }

    /// Drops the Step on a wire: it goes between the wire's ends and the gap it left closes (one undo step).
    @discardableResult
    public func insertStep(_ id: UUID, onto link: GraphLink) -> Bool {
        guard var g = graph, g.insert(id, onto: link) else { return false }
        g.setPosition(id, nil)
        selectedStep = id
        selectedSteps = [id]
        commitGraph(g)
        return true
    }

    /// Shift-drag: the Step leaves its wires (they close up around it) and stays at `p` (one undo step).
    public func extractStep(_ id: UUID, at p: StepPosition) {
        editGraph { g in
            g.extract(id)
            g.setPosition(id, p)
        }
    }

    /// Stores several positions in one undo step (a group of Steps moved together).
    public func setStepPositions(_ positions: [UUID: StepPosition]) {
        editGraph { g in for (id, p) in positions { g.setPosition(id, p) } }
    }

    /// Freezes a stack's mixer box where it sits, so moving a Step of the stack does not move the box (one undo step with
    /// the positions).
    public func placeSteps(_ positions: [UUID: StepPosition], freezingMixers frozen: [UUID: StepPosition]) {
        editGraph { g in
            for (head, p) in frozen where g.step(head)?.mixerPosition == nil { g.setMixerPosition(head, p) }
            for (id, p) in positions { g.setPosition(id, p) }
        }
    }

    // MARK: Selection

    /// Selects one Step (the inspector shows it) or, with `extend`, adds it to / takes it from the selection.
    public func selectStep(_ id: UUID, extend: Bool = false) {
        selectedMixer = nil
        if extend {
            if selectedSteps.contains(id) {
                selectedSteps.remove(id)
                if selectedStep == id { selectedStep = selectedSteps.first }
            } else {
                selectedSteps.insert(id)
                selectedStep = id
            }
        } else {
            selectedSteps = [id]
            selectedStep = id
        }
    }

    /// Replaces the selection (the rectangle); the inspector shows the first of them.
    public func selectSteps(_ ids: Set<UUID>, extend: Bool = false) {
        selectedMixer = nil
        let all = extend ? selectedSteps.union(ids) : ids
        selectedSteps = all
        if let s = selectedStep, all.contains(s) { return }
        if let first = graph?.steps.first(where: { all.contains($0.id) }) { selectedStep = first.id }
    }

    /// The Steps a command works on: the selection, else the shown Step.
    public var commandSteps: [UUID] {
        guard let g = graph else { return [] }
        let ids = g.steps.map(\.id).filter { selectedSteps.contains($0) }
        if !ids.isEmpty { return ids }
        return selectedStep.map { [$0] } ?? []
    }

    /// Deletes the selected Steps; the wires close up around them (one undo step). The last Step only resets.
    public func removeSelectedSteps() {
        let ids = commandSteps
        guard !ids.isEmpty else { return }
        editGraph { g in for id in ids { g.removeStep(id) } }
        selectedSteps = selectedStep.map { [$0] } ?? []
    }

    /// Turns the selected Steps off, or on when all of them are off (one undo step).
    public func toggleSelectedSteps() {
        let ids = commandSteps
        guard let g = graph, !ids.isEmpty else { return }
        let target = !ids.allSatisfy { g.step($0)?.enabled == true }
        editGraph { g in for id in ids { g.setEnabled(id, target) } }
    }

    /// Adds a Step in front of `id` (serial; before the first Step it becomes the new first Step).
    public func addStepBefore(_ id: UUID) {
        guard var g = graph, let i = g.steps.firstIndex(where: { $0.id == id }) else { return }
        let new = i == 0 ? g.addStep(after: nil) : g.addStep(after: g.steps[i - 1].id)
        if i == 0 { g.moveStep(new, to: 0) }
        let cols = g.columns.map { $0.map(\.id) }
        let pos = Dictionary(uniqueKeysWithValues: g.steps.compactMap { st in st.position.map { (st.id, $0) } })
        let mix = Dictionary(uniqueKeysWithValues: g.steps.compactMap { st in st.mixerPosition.map { (st.id, $0) } })
        if let p = StepsCanvas.freeSpot(for: new, columns: cols, positions: pos, mixerPositions: mix) { g.setPosition(new, p) }
        selectedStep = new
        commitGraph(g)
    }

    /// Tidy up: every Step goes back to the automatic layout.
    public func tidyUpSteps() { editGraph { $0.tidyUp() } }

    public func setStepEnabled(_ id: UUID, _ on: Bool) { editGraph { $0.setEnabled(id, on) } }

    public func resetStep(_ id: UUID) { editGraph { $0.update(id) { $0.reset() } } }

    public func stepValue(_ id: UUID, _ p: StepParam) -> Float { step(id).map(p.read) ?? p.neutral }

    public func setStep(_ id: UUID, _ p: StepParam, _ v: Float) { editGraph { $0.update(id) { p.write(v, into: &$0) } } }

    public func resetStepValue(_ id: UUID, _ p: StepParam) { setStep(id, p, p.neutral) }

    // MARK: LUTs

    public func graphLUTChoice(_ slot: GraphLUTSlot) -> LUTChoice? {
        let r = slot == .input ? graph?.inputLUT : graph?.outputLUT
        return r.map(choice)
    }

    /// In LUT: nil = none (built-in conversion), `.automatic` = the Simple rules. Out LUT: nil = none.
    public func setGraphLUT(_ slot: GraphLUTSlot, _ c: LUTChoice?) {
        let r = c.flatMap(ref)
        noteRecent(c)
        editGraph { g in
            switch slot {
            case .input: g.inputLUT = r
            case .output: g.outputLUT = r == .automatic ? nil : r
            }
        }
    }

    public func stepLUTChoice(_ id: UUID) -> LUTChoice? { step(id)?.lut.map(choice) }

    public func setStepLUT(_ id: UUID, _ c: LUTChoice?) {
        let r = c.flatMap(ref)
        noteRecent(c)
        editGraph { $0.update(id) { $0.lut = r == .automatic ? nil : r } }
    }

    private func noteRecent(_ c: LUTChoice?) {
        guard let path = c?.filePath else { return }
        recents.add(path); recentLUTs = recents.paths
    }

    // MARK: Color decisions (ASC CDL, CMX EDL)

    /// Sets the Step's primaries from the first decision in the file (clamped to the Step ranges). One undo step;
    /// returns how many decisions the file holds; throws when nothing is readable.
    @discardableResult
    public func importColorDecision(_ data: Data, fileExtension ext: String, into id: UUID) throws -> Int {
        let d = try ColorDecisionImport.parse(data, fileExtension: ext)
        guard let first = d.first else { throw ColorDecisionImport.ImportError.noDecisions }
        editGraph { $0.update(id) { $0.primaries = first.primaries } }
        return d.count
    }
}

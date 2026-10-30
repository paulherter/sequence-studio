import AppKit
import Testing
import SQCore
import SQLibrary
import SQRender
@testable import SQInspectorUI

/// Color Pro mode phase 1 (docs/research/COLOR-DESIGN-NOTES.md): the Simple | Pro switch and the Step edits of the
/// Color panel model. The host writes `onGraphChange` to `Clip.colorGraph`.
@MainActor @Suite struct ColorGraphModelTests {
    final class Sink { var graphs: [ColorGraph] = []; var gestures = 0 }

    func model() -> (ColorInspectorModel, Sink) {
        let m = ColorInspectorModel()
        m.recents = RecentLUTs(defaults: UserDefaults(suiteName: "ColorGraphModelTests-\(UUID())")!)
        m.recentLUTs = []
        let s = Sink()
        m.onGraphChange = { s.graphs.append($0) }
        m.onGestureBegan = { s.gestures += 1 }
        return (m, s)
    }

    @Test func switchingToProOnlyOpensTheEmptyPageUntilAStartButtonAddsTheGraph() throws {
        let (m, s) = model()
        var views = 0
        m.onGradeViewChange = { views += 1 }
        #expect(m.activeGrade == .simple && m.shownGrade == .simple && m.graph == nil)
        m.setActiveGrade(.pro)
        #expect(s.graphs.isEmpty && m.graph == nil, "the switch writes nothing to the clip")
        #expect(m.shownGrade == .pro && m.activeGrade == .simple && views == 1)
        m.setActiveGrade(.simple)
        #expect(m.shownGrade == .simple && s.graphs.isEmpty && views == 2)
        m.setActiveGrade(.pro)
        m.startEmptyGraph()
        let g = try #require(s.graphs.last)
        #expect(s.graphs.count == 1 && g.isActive && g.steps.count == 1 && g.steps[0].isNeutral)
        #expect(m.activeGrade == .pro && m.shownGrade == .pro && !m.showsEmptyPro)
        #expect(m.selectedStep == g.steps[0].id, "the first Step is selected")
        m.setStep(g.steps[0].id, .contrast, 1.4)
        m.setActiveGrade(.simple)
        let back = try #require(s.graphs.last)
        #expect(!back.isActive && back.steps[0].primaries.contrast == 1.4, "the inactive grade keeps its values")
        #expect(m.shownGrade == .simple)
        let n = s.graphs.count
        m.setActiveGrade(.simple)
        #expect(s.graphs.count == n, "no change, no edit")
        m.setActiveGrade(.pro)
        #expect(s.graphs.last?.isActive == true && s.graphs.last?.steps[0].primaries.contrast == 1.4, "a clip with a graph switches at once")
        // Simple on a clip without a graph adds nothing.
        let (m2, s2) = model()
        m2.setActiveGrade(.simple)
        #expect(s2.graphs.isEmpty && m2.graph == nil)
    }

    @Test func startFromSimpleCopiesTheSimpleGradeIntoANamedStep() throws {
        let (m, s) = model()
        let e = try #require(m.effects.first?.id)
        m.set(e, .contrast, 40)
        let simple = m.color
        m.setActiveGrade(.pro)
        m.startFromSimple()
        let g = try #require(s.graphs.last)
        #expect(s.graphs.count == 1 && g.isActive && g.steps.count == 1)
        #expect(g.steps[0].label == "From Simple" && !g.steps[0].isNeutral)
        #expect(g.steps[0].primaries == ColorGraph(simple: simple).steps[0].primaries)
        #expect(m.color == simple, "Simple is unchanged")
        #expect(m.shownGrade == .pro && !m.showsEmptyPro)
    }

    @Test func loadKeepsTheSelectionWhileTheStepExists() {
        let (m, _) = model()
        var g = ColorGraph(); g.isActive = true
        let second = g.addStep(after: g.steps[0].id)
        m.loadGraph(g)
        #expect(m.selectedStep == g.steps[0].id)
        m.selectedStep = second
        m.loadGraph(g)
        #expect(m.selectedStep == second)
        g.removeStep(second)
        m.loadGraph(g)
        #expect(m.selectedStep == g.steps[0].id)
        m.loadGraph(nil)
        #expect(m.selectedStep == nil && m.activeGrade == .simple)
    }

    @Test func stepEditsAddRemoveMoveAndReset() throws {
        let (m, s) = model()
        m.startEmptyGraph()
        let first = try #require(m.graph?.steps.first?.id)
        m.addStep(after: first)
        let g = try #require(s.graphs.last)
        #expect(g.steps.count == 2 && g.steps[1].label == "Step 2" && m.selectedStep == g.steps[1].id)
        let second = g.steps[1].id
        m.moveStep(second, by: -1)
        #expect(m.graph?.steps.map(\.id) == [second, first])
        m.moveStep(second, by: -1)
        #expect(m.graph?.steps.map(\.id) == [second, first], "the first stays first")
        m.setStepEnabled(second, false)
        #expect(m.graph?.step(second)?.enabled == false)
        m.setStep(first, .gain, 1.5)
        m.setStep(first, .saturation, 9)
        let p = try #require(m.graph?.step(first)?.primaries)
        #expect(p.gain == ColorTriple(all: 1.5) && p.saturation == 4, "master sets all three channels; values clamp")
        #expect(m.stepValue(first, .gain) == 1.5)
        m.resetStep(first)
        #expect(m.graph?.step(first)?.isNeutral == true)
        m.removeStep(second)
        #expect(m.graph?.steps.map(\.id) == [first] && m.selectedStep == first)
    }

    @Test func lutSlotsOfTheGraph() throws {
        let (m, _) = model()
        m.startEmptyGraph()
        #expect(m.graphLUTChoice(.input) == .automatic && m.graphLUTChoice(.output) == nil)
        m.setGraphLUT(.output, .file("/l/out.cube"))
        #expect(m.graph?.outputLUT == .file("/l/out.cube"))
        m.setGraphLUT(.input, nil)
        #expect(m.graph?.inputLUT == nil)
        let id = try #require(m.selectedStep)
        m.setStepLUT(id, .file("/l/step.cube"))
        #expect(m.graph?.step(id)?.lut == .file("/l/step.cube") && m.stepLUTChoice(id)?.filePath == "/l/step.cube")
        m.setStep(id, .lutIntensity, 40)
        #expect(m.graph?.step(id)?.lutIntensity == 40)
        m.setStepLUT(id, nil)
        #expect(m.graph?.step(id)?.lut == nil)
    }

    @Test func colorDecisionImportSetsTheStepPrimaries() throws {
        let (m, s) = model()
        m.startEmptyGraph()
        let id = try #require(m.selectedStep)
        let xml = """
        <ColorDecisionList><ColorDecision><ColorCorrection id="a"><SOPNode>
        <Slope>1.2 1.1 1.0</Slope><Offset>0.01 0 -0.01</Offset><Power>0.9 1 1.1</Power></SOPNode>
        <SatNode><Saturation>0.8</Saturation></SatNode></ColorCorrection></ColorDecision></ColorDecisionList>
        """
        let gestures = s.gestures
        try m.importColorDecision(Data(xml.utf8), fileExtension: "cdl", into: id)
        let p = try #require(m.graph?.step(id)?.primaries)
        #expect(p.gain == ColorTriple(1.2, 1.1, 1.0) && p.gamma == ColorTriple(0.9, 1, 1.1) && p.saturation == 0.8)
        #expect(s.gestures == gestures + 1, "one undo step")
        let ccc = """
        <ColorCorrectionCollection><ColorCorrection id="a"><SOPNode><Slope>2 2 2</Slope></SOPNode></ColorCorrection>
        <ColorCorrection id="b"><SOPNode><Slope>3 3 3</Slope></SOPNode></ColorCorrection></ColorCorrectionCollection>
        """
        #expect(try m.importColorDecision(Data(ccc.utf8), fileExtension: "ccc", into: id) == 2, "reports how many it found")
        #expect(m.step(id)?.primaries.gain == ColorTriple(all: 2), "the first one is applied")
        #expect(ColorGraphPage.importNotice(found: 2)?.contains("first") == true)
        #expect(ColorGraphPage.importNotice(found: 1) == nil)
        #expect(throws: ColorDecisionImport.ImportError.noDecisions) {
            try m.importColorDecision(Data("<x/>".utf8), fileExtension: "cc", into: id)
        }
    }

    @Test func proPageShowsTheGraphAndItsMenus() throws {
        let (m, _) = model()
        let view = ColorInspectorView(model: m)
        #expect(view.proPage.isHidden, "Simple shows the effects")
        m.startEmptyGraph()
        view.refresh()
        #expect(!view.proPage.isHidden)
        let page = view.proPage
        let g = try #require(m.graph)
        #expect(page.list.items.map(\.id) == g.listSteps.map(\.id) && page.list.selected == g.steps[0].id)
        #expect(page.list.items.first?.isBase == true && page.list.items.count == g.steps.count)
        let titles = page.stepMenuItems(g.steps[0].id).map(\.title)
        #expect(titles.contains("Add Serial Step") && titles.contains("Add Step Before") && titles.contains("Import Color Decision…") && titles.contains("Move Left"))
        let inMenu = page.lutItems(.graphInput).map(\.title)
        #expect(inMenu.first == "Automatic" && inMenu.contains("Choose File…"))
        #expect(page.lutItems(.graphOutput).first?.title == "None")
    }

    @Test func layerListEditsBlendOpacityAndOrder() throws {
        let (m, s) = model()
        m.startEmptyGraph()
        let base = try #require(m.selectedStep)
        m.addLayerOnTop()
        let top = try #require(m.selectedStep)
        let page = ColorInspectorView(model: m).proPage
        page.refresh()
        #expect(page.list.items.map(\.id) == [top, base], "topmost layer first")
        #expect(page.list.items[0].blend == .layer(.normal) && page.list.items[1].isBase)
        #expect(page.list.blendPopup(base)?.isHidden == true, "the base row has no blend")
        let titles = page.list.blendItems(for: page.list.items[0]).map(\.title)
        #expect(titles == ["Series", "Parallel", "Layer", "Add", "Subtract", "Multiply", "Screen", "Lighten", "Darken"])
        let g0 = s.gestures
        page.list.onBlend?(top, .layer(.screen))
        #expect(m.graph?.blend(of: top) == .layer(.screen) && s.gestures == g0 + 1)
        page.list.onMixBegin?(); page.list.onMix?(top, 40); page.list.onMixEnd?()
        #expect(m.step(top)?.mix == 40, "the drag runs in the host gesture like every slider")
        page.list.onMove?(top, 1)
        #expect(m.graph?.steps.map(\.id) == [top, base] && m.graph?.steps[0].kind == .serial)
        let pipeline = try ops(s)
        #expect(!pipeline.isEmpty || m.graph?.isNeutral == true)
    }

    // MARK: Curves, qualifier and window per Step

    /// The pipeline the renderer builds for the last graph the model reported.
    private func ops(_ s: Sink) throws -> [ColorOp] {
        var c = ClipColor()
        c.graph = try #require(s.graphs.last)
        return ColorPipeline.from(clipColor: c, mediaID: UUID(), mediaInfo: nil, lutProvider: nil).ops
    }

    @Test func stepCurvesReachTheRenderPathInOneUndoStepPerDrag() throws {
        let (m, s) = model()
        m.startEmptyGraph()
        let id = try #require(m.selectedStep)
        var c = RGBCurves()
        c.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.7), CurvePoint(1, 1)]
        let g0 = s.gestures
        m.setStepCurves(id, c)
        #expect(s.gestures == g0 + 1 && m.stepCurves(id) == c)
        let found = try ops(s).contains { if case .curves(let k) = $0 { return k == c } else { return false } }
        #expect(found, "the Step's curves are a curves op")
        m.setStepHueCurve(id, .hueVsSat, [CurvePoint(0, 0.5), CurvePoint(0.3, 0.9), CurvePoint(1, 0.5)])
        #expect(m.stepHueCurve(id, .hueVsSat)[1].y == 0.9)
        let hue = try ops(s).contains { if case .hueCurves(let h) = $0 { return h.hueVsSat.count == 3 } else { return false } }
        #expect(hue)
        // Hue-keyed curves wrap: moving the last point moves the first.
        m.setStepHueCurve(id, .hueVsSat, [CurvePoint(0, 0.5), CurvePoint(0.3, 0.9), CurvePoint(1, 0.8)])
        #expect(m.stepHueCurve(id, .hueVsSat).first?.y == 0.8)
    }

    @Test func stepQualifierSharesTheColorRangeParams() throws {
        let (m, s) = model()
        m.startEmptyGraph()
        let id = try #require(m.selectedStep)
        #expect(m.step(id)?.qualifier == nil)
        m.setStepQualifierEnabled(id, true)
        #expect(m.step(id)?.qualifier == ColorQualifier())
        let g0 = s.gestures
        m.setStepQualifier(id, .hueCenter, 200)
        m.setStepQualifier(id, .satMin, 80)     // satMax stays 100
        m.setStepQualifier(id, .satMax, 50)     // pulls satMin down with it
        let q = try #require(m.step(id)?.qualifier)
        #expect(q.hueCenter == 200 && q.satMax == 50 && q.satMin == 50)
        #expect(s.gestures == g0 + 3)
        m.setStepQualifierInvert(id, true)
        #expect(m.step(id)?.qualifier?.invert == true)
        #expect(m.stepQualifierValue(id, .hueCenter) == 200)
        // A Step with a qualifier but no primaries changes nothing, so give it a primary: the pair is emitted.
        m.setStep(id, .saturation, 1.5)
        let limited = try ops(s).contains { if case .stepEnd(let qq, _, _) = $0 { return qq?.hueCenter == 200 } else { return false } }
        #expect(limited)
        m.setStepQualifierEnabled(id, false)
        #expect(m.step(id)?.qualifier == nil)
        // Reset of one value goes back to the default, without a qualifier nothing is created.
        m.resetStepQualifierParameter(id, .hueCenter)
        #expect(m.step(id)?.qualifier == nil)
        // With a qualifier on, reset returns to the value a freshly enabled qualifier has.
        m.setStepQualifierEnabled(id, true)
        m.setStepQualifier(id, .hueCenter, 200)
        m.resetStepQualifierParameter(id, .hueCenter)
        #expect(m.step(id)?.qualifier?.hueCenter == ColorQualifier().hueCenter)
        m.setStepQualifier(id, .softness, 70)
        m.resetStepQualifierParameter(id, .softness)
        #expect(m.step(id)?.qualifier?.softness == ColorQualifier().softness)
    }

    @Test func stepWindowEditsAndRender() throws {
        let (m, s) = model()
        m.startEmptyGraph()
        let id = try #require(m.selectedStep)
        m.setStep(id, .gain, 1.2)
        m.setStepWindowEnabled(id, true)
        #expect(m.step(id)?.window == StepWindow())
        m.setStepWindowShape(id, .rectangle)
        m.setStepWindow(id, .centerX, 25)        // percent in the panel, a fraction in the model
        m.setStepWindow(id, .rotation, 45)
        m.setStepWindow(id, .softness, 500)      // clamped
        m.setStepWindowInvert(id, true)
        let w = try #require(m.step(id)?.window)
        #expect(w.shape == .rectangle && w.centerX == 0.25 && w.rotation == 45 && w.softness == 1 && w.invert)
        #expect(m.stepWindowValue(id, .centerX) == 25)
        let found = try ops(s).contains { if case .stepEnd(_, let ww, _) = $0 { return ww == w } else { return false } }
        #expect(found)
        m.resetStepWindowParameter(id, .centerX)
        #expect(m.step(id)?.window?.centerX == 0.5)
        m.setStepWindowEnabled(id, false)
        #expect(m.step(id)?.window == nil)
    }

    @Test func monitorHandlesWriteOnlyPositionSizeAndAngle() throws {
        let (m, s) = model()
        m.startEmptyGraph()
        let id = try #require(m.selectedStep)
        #expect(m.windowEditTarget == nil, "no window yet: no handles")
        m.setStepWindowEnabled(id, true)
        m.setStepWindowShape(id, .rectangle)
        m.setStepWindow(id, .softness, 30)
        m.setStepWindowInvert(id, true)
        #expect(m.windowEditTarget?.step == id)
        var dragged = StepWindow(shape: .ellipse)
        dragged.centerX = 0.2; dragged.centerY = 0.7; dragged.width = 0.9; dragged.height = 0.1; dragged.rotation = -40
        dragged.softness = 0; dragged.invert = false
        let before = s.graphs.count
        m.setStepWindowGeometry(id, dragged)
        let w = try #require(m.step(id)?.window)
        #expect(w.centerX == 0.2 && w.centerY == 0.7 && w.width == 0.9 && w.height == 0.1 && w.rotation == -40)
        #expect(w.shape == .rectangle && w.softness == 0.3 && w.invert, "shape, softness and invert are the panel's")
        #expect(s.graphs.count == before + 1)
        m.setStepWindowGeometry(id, w)
        #expect(s.graphs.count == before + 1, "an unchanged window is no edit")
        m.setStepWindowEnabled(id, false)
        m.setStepWindowGeometry(id, dragged)
        #expect(m.step(id)?.window == nil, "the handles never switch the window on")
    }

    @Test func viewerAidsReportSelectionAndMatteChanges() throws {
        let (m, _) = model()
        m.startEmptyGraph()
        var calls = 0
        m.onViewerAidChange = { calls += 1 }
        let first = try #require(m.selectedStep)
        m.showsMatte = true
        #expect(calls == 1)
        m.showsMatte = true
        #expect(calls == 1)
        m.addStep(after: first)
        #expect(m.selectedStep != first && calls >= 2)
        let n = calls
        m.selectedStep = first
        #expect(calls == n + 1)
        m.setActiveGrade(.simple)
        #expect(m.windowEditTarget == nil)
    }

    @Test func resettingAStepClearsCurvesQualifierAndWindow() throws {
        let (m, _) = model()
        m.startEmptyGraph()
        let id = try #require(m.selectedStep)
        m.setStepQualifierEnabled(id, true)
        m.setStepWindowEnabled(id, true)
        var c = RGBCurves(); c.master = [CurvePoint(0, 0.1), CurvePoint(1, 1)]
        m.setStepCurves(id, c)
        m.resetStep(id)
        let st = try #require(m.step(id))
        #expect(st.isNeutral && st.qualifier == nil && st.window == nil && st.curves.isNeutral)
    }
}


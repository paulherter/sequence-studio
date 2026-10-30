import Foundation
import CoreGraphics
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

@MainActor @Suite struct ColorGradeDrawTests {
    func rig() throws -> (EditorSession, ColorGradeDraw, Clip) {
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])
        var p = Project(name: "P", timelines: [t])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(2, 1), detectedColorSpace: .sLog3SGamut3Cine, embeddedLUTName: "Look"))]
        let session = EditorSession(project: p, engine: StubProgramEngine())
        session.select(clips: [clip.id])
        let controller = ColorGradeController(session: session)
        controller.sync([.project, .selection])
        let panel = ColorGradeDraw(controller: controller)
        panel.size = CGSize(width: 340, height: 4000)
        // Open every section (the Mac default folds all but Basic and Creative).
        if let m = controller.model { for e in m.effects { for k in ColorSectionKind.allCases { m.setCollapsed(ColorPanelKey(e.id, k), false) } } }
        return (session, panel, clip)
    }

    func current(_ s: EditorSession, _ id: Clip.ID) -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }

    func center(_ panel: ColorGradeDraw, _ k: ColorGradeDraw.Control) throws -> CGPoint {
        let f = try #require(panel.frame(k))
        return CGPoint(x: f.midX, y: f.midY - panel.scrollY)
    }

    @Test func simplePageListsEverySectionWithItsControls() throws {
        let (_, panel, _) = try rig()
        let model = try #require(panel.model)
        let id = try #require(model.effects.first?.id)
        let rows = panel.rows
        let sections = rows.filter { $0.style == .section }.compactMap(\.label)
        #expect(sections == ColorSectionText.order.map(\.title) + ["Input color"])
        let all = rows.flatMap { $0.controls.map(\.0) }
        #expect(all.contains(.lut(id, .input)) && all.contains(.lut(id, .look)))
        #expect(all.contains(.slider(.param(id, .exposure))) && all.contains(.slider(.sharpen)))
        #expect(all.contains(.wheel(.slot(id, .midtones))) && all.contains(.master(.slot(id, .midtones))))
        // The tint wheels are not on the Mac Simple page.
        #expect(!all.contains(.wheel(.slot(id, .shadowTint))) && !all.contains(.wheel(.slot(id, .highlightTint))))
        #expect(all.contains(.curve(.rgb(id))) && all.contains(.curve(.hue(id))))
        #expect(all.contains(.wheel(.zone(id, .global))))
        // The look intensity shows only with a look set; the input LUT intensity never on the primary effect.
        #expect(!all.contains(.slider(.param(id, .lookIntensity))))
        #expect(!all.contains(.slider(.param(id, .inputLUTIntensity))))
    }

    @Test func sliderDragIsOneUndoStepAndDoubleClickResets() throws {
        let (session, panel, clip) = try rig()
        let id = try #require(panel.model?.effects.first?.id)
        let k = ColorGradeDraw.Control.slider(.param(id, .exposure))
        let f = try #require(panel.frame(k))
        let track = panel.sliderParts(f).track
        panel.mouseDown(at: CGPoint(x: track.midX, y: f.midY), clickCount: 1)
        panel.mouseDragged(to: CGPoint(x: track.maxX - 1, y: f.midY))
        panel.mouseUp(at: CGPoint(x: track.maxX - 1, y: f.midY))
        let exposure = current(session, clip.id).color.effects[0].basic.exposure
        #expect(exposure > 0)
        #expect(session.undoName == "Color")
        session.undo()
        #expect(current(session, clip.id).color.effects[0].basic.exposure == 0)
        session.redo()
        panel.mouseDown(at: CGPoint(x: track.midX, y: f.midY), clickCount: 2)
        panel.mouseUp(at: CGPoint(x: track.midX, y: f.midY))
        #expect(current(session, clip.id).color.effects[0].basic.exposure == 0)
    }

    /// The Mac `ColorGrid` geometry of the expanded Simple sections (round 15, compared with the AppKit render).
    @Test func expandedSectionsFollowTheMacGrid() throws {
        let (_, panel, _) = try rig()
        let model = try #require(panel.model)
        let id = try #require(model.effects.first?.id)
        // Curves: boxes inset 12, 150 / 90 high, the plot 6 pt inside; the channel dots 19 apart centered on the panel.
        let rgb = try #require(panel.frame(.curve(.rgb(id)))), hue = try #require(panel.frame(.curve(.hue(id))))
        #expect(rgb.minX == 12 && rgb.width == 340 - 24 && rgb.height == 150 && hue.height == 90)
        let plot = ColorGradeDraw.curvePlot(rgb)
        #expect(plot.minX == 18 && plot.width == rgb.width - 12 && plot.height == 138)
        let dots = try (0..<4).map { try #require(panel.frame(.channel(.rgb(id), $0))) }
        #expect(dots.allSatisfy { $0.width == 19 } && dots[1].minX - dots[0].minX == 19)
        #expect(abs((dots[0].minX + dots[3].maxX) / 2 - 170) <= 1)
        // Wheels: the disc is the cell minus the 24 pt master column, the master a 14 pt vertical slider 10 pt right of it.
        let disc = try #require(panel.frame(.wheel(.slot(id, .midtones)))), master = try #require(panel.frame(.master(.slot(id, .midtones))))
        #expect(disc.width == 62 && disc.height == 62 && master.width == 14 && master.height == 62 && master.minX == disc.maxX + 10)
        let zone = try #require(panel.frame(.wheel(.zone(id, .global))))
        #expect(zone.width == 42)
        #expect(panel.titleLead(.slot(id, .midtones)) == 33 && panel.titleLead(.step(UUID(), .lift)) == 20)
        // Color Range: the Invert checkbox row carries its text, so its control spans the control column.
        let invert = try #require(panel.frame(.invert(id)))
        #expect(invert.minX == 124 && invert.width == 340 - 12 - 124)
    }

    @Test func inputColorRowsSitOnTheTopGrid() throws {
        let (_, panel, _) = try rig()
        panel.inputOpen = true
        let model = try #require(panel.model)
        _ = model
        let interpret = try #require(panel.frame(.input(.interpret))), conform = try #require(panel.frame(.conform))
        #expect(interpret.minX == 104 && interpret.maxX == 340 - 12)
        #expect(conform.minX == 104 && conform.height == 30)
        #expect(panel.rows.first { $0.label == "Interpret As" }?.labelX == 12)
    }

    @Test func curveHitTestingUsesThePlotInsideTheBox() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.model)
        let id = try #require(model.effects.first?.id)
        let box = try #require(panel.frame(.curve(.rgb(id))))
        let plot = ColorGradeDraw.curvePlot(box)
        // Dragging the first point to the plot's top-left corner reaches (0, 1) exactly.
        let start = CGPoint(x: plot.minX, y: plot.maxY - panel.scrollY)
        panel.mouseDown(at: start, clickCount: 1)
        panel.mouseDragged(to: CGPoint(x: plot.minX, y: plot.minY - panel.scrollY))
        panel.mouseUp(at: CGPoint(x: plot.minX, y: plot.minY - panel.scrollY))
        let pts = current(session, clip.id).color.effects[0].curves.master
        #expect(pts.first.map { $0.x == 0 && $0.y == 1 } == true)
    }

    @Test func wheelDragMovesThePuckAndTheMasterSetsLuma() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.model)
        let id = try #require(model.effects.first?.id)
        let w = ColorGradeDraw.Wheel.slot(id, .midtones)
        let f = try #require(panel.frame(.wheel(w)))
        let start = CGPoint(x: f.midX, y: f.midY - panel.scrollY)
        panel.mouseDown(at: start, clickCount: 1)
        panel.mouseDragged(to: CGPoint(x: start.x + f.width / 4, y: start.y))
        panel.mouseUp(at: CGPoint(x: start.x + f.width / 4, y: start.y))
        #expect(model.wheel(id, .midtones).value.amount > 0.1)
        let m = try #require(panel.frame(.master(w)))
        #expect(m.height > m.width)       // the Simple page's master is the Mac's vertical slider beside the disc
        panel.mouseDown(at: CGPoint(x: m.midX, y: m.minY + 1 - panel.scrollY), clickCount: 1)
        panel.mouseUp(at: CGPoint(x: m.midX, y: m.minY + 1 - panel.scrollY))
        #expect(model.wheel(id, .midtones).luma > 50)
        panel.mouseDown(at: CGPoint(x: m.midX, y: m.midY - panel.scrollY), clickCount: 2)
        panel.mouseUp(at: CGPoint(x: m.midX, y: m.midY - panel.scrollY))
        #expect(model.wheel(id, .midtones).luma == 0 && model.wheel(id, .midtones).value.amount == 0)
        _ = (session, clip)
    }

    @Test func curveClickAddsAPointThatDragsAndOptionClickRemoves() throws {
        let (_, panel, _) = try rig()
        let model = try #require(panel.model)
        let id = try #require(model.effects.first?.id)
        let f = try #require(panel.frame(.curve(.rgb(id))))
        let before = model.curves(id).master.count
        let p = CGPoint(x: f.minX + f.width * 0.5, y: f.minY + f.height * 0.3 - panel.scrollY)
        panel.mouseDown(at: p, clickCount: 1)
        panel.mouseDragged(to: CGPoint(x: p.x, y: p.y - 10))
        panel.mouseUp(at: CGPoint(x: p.x, y: p.y - 10))
        #expect(model.curves(id).master.count == before + 1)
        panel.mouseDown(at: CGPoint(x: p.x, y: p.y - 10), modifiers: [.option], clickCount: 1)
        panel.mouseUp(at: CGPoint(x: p.x, y: p.y - 10))
        #expect(model.curves(id).master.count == before)
    }

    @Test func sectionHeaderFoldsAndItsMenuTurnsItOff() throws {
        let (_, panel, _) = try rig()
        let model = try #require(panel.model)
        let id = try #require(model.effects.first?.id)
        panel.mouseDown(at: try center(panel, .section(id, .curves)), clickCount: 1)
        #expect(model.isCollapsed(ColorPanelKey(id, .curves)))
        #expect(!panel.rows.flatMap { $0.controls.map(\.0) }.contains(.curve(.rgb(id))))
        let items = panel.sectionMenu(id, .curves)
        #expect(items.map(\.title).contains("Hold Saturation Legal"))
        items.first?.action?()
        #expect(model.effects.first?.isEnabled(.curves) == false)
    }

    @Test func lutMenuFollowsTheBoardOrder() throws {
        let (_, panel, _) = try rig()
        let model = try #require(panel.model)
        let id = try #require(model.effects.first?.id)
        let titles = panel.lutMenu(id, .input).map(\.title)
        #expect(Array(titles.prefix(3)) == ["Automatic", "Embedded: Look", "None"])
        #expect(titles.contains("Choose File…"))
        // The Look slot has no Automatic / Embedded entries.
        #expect(panel.lutMenu(id, .look).first?.title == "None")
        panel.lutMenu(id, .look).first(where: { $0.title == "None" })?.action?()
        #expect(model.lutChoice(id, .look) == nil)
    }

    @Test func gradeSwitchShowsTheProStepPage() throws {
        let (_, panel, _) = try rig()
        let model = try #require(panel.model)
        // The switch lives in the Color tab's strip (the Mac PanelHeaderItems), not in the panel body.
        let tools = ColorStripToolsDraw(controller: panel.controller)
        let strip = CGRect(x: 0, y: 0, width: 800, height: 28)
        let pro = try #require(tools.frames(.colorInspector, strip: strip).first { $0.0 == .pro }).1
        let at = CGPoint(x: pro.midX, y: pro.midY)
        #expect(tools.mouseDown(panel: .colorInspector, strip: strip, at: at))
        tools.mouseUp(panel: .colorInspector, strip: strip, at: at)
        #expect(model.shownGrade == .pro)
        model.startEmptyGraph()
        if let first = model.graph?.steps.first?.id { model.selectStep(first, extend: false) }
        let id = try #require(model.selectedStep)
        let all = panel.rows.flatMap { $0.controls.map(\.0) }
        #expect(all.contains(.wheel(.step(id, .lift))) && all.contains(.slider(.primary(id, .contrast))))
        #expect(!all.contains(.curve(.stepRGB(id))))
        panel.proTab = 1
        #expect(panel.rows.flatMap { $0.controls.map(\.0) }.contains(.curve(.stepRGB(id))))
    }
}

@MainActor @Suite struct ColorProPageTests {
    func rig() throws -> (ColorGradeDraw, ColorInspectorModel, UUID) {
        let (_, panel, _) = try ColorGradeDrawTests().rig()
        let model = try #require(panel.model)
        model.setActiveGrade(.pro)
        model.startEmptyGraph()
        if let first = model.graph?.steps.first?.id { model.selectStep(first, extend: false) }
        panel.size = CGSize(width: 320, height: 800)
        return (panel, model, try #require(model.selectedStep))
    }
    func controls(_ p: ColorGradeDraw) -> [ColorGradeDraw.Control] { p.rows.flatMap { $0.controls.map(\.0) } }
    func click(_ p: ColorGradeDraw, _ k: ColorGradeDraw.Control) throws {
        let f = try #require(p.frame(k))
        let at = CGPoint(x: f.midX, y: f.midY - p.scrollY)
        p.mouseDown(at: at, clickCount: 1)
        p.mouseUp(at: at)
    }

    @Test func primariesAreATwoByTwoGridOfNinetySixPointWheels() throws {
        let (panel, _, id) = try rig()
        let frames = try PrimaryWheel.allCases.map { try #require(panel.frame(.wheel(.step(id, $0)))) }
        #expect(frames.allSatisfy { $0.width == 96 && $0.height == 96 })
        #expect(frames[0].minY == frames[1].minY && frames[2].minY == frames[3].minY && frames[2].minY > frames[0].maxY)
        #expect(frames[0].minX < frames[1].minX && frames[0].minX == frames[2].minX)
    }

    @Test func primaryRowsShowTheScaledValue() throws {
        let (panel, model, id) = try rig()
        model.setStep(id, .contrast, 1.5)
        #expect(panel.value(.primary(id, .contrast)) == Double(1.5 * StepPrimaryRow.contrast.scale))
        panel.set(.primary(id, .contrast), 100)
        #expect(abs(model.stepValue(id, .contrast) - 100 / StepPrimaryRow.contrast.scale) < 1e-4)
    }

    @Test func tabsSwitchTheBody() throws {
        let (panel, _, id) = try rig()
        #expect(controls(panel).filter { if case .proTab = $0 { true } else { false } }.count == 6)
        try click(panel, .proTab(2))
        #expect(panel.proTab == 2 && controls(panel).contains(.rangeBar(.hue)) && !controls(panel).contains(.wheel(.step(id, .lift))))
        try click(panel, .proTab(3))
        #expect(controls(panel).contains(.shapeChip(0)) && controls(panel).contains(.slider(.window(id, .width))))
        try click(panel, .proTab(4))
        #expect(controls(panel).contains(.lutPill) && controls(panel).contains(.slider(.step(id, .lutIntensity))))
        try click(panel, .proTab(5))
        #expect(controls(panel).contains(.addEffect))
    }

    @Test func listEyeBypassesAndAddMakesALayer() throws {
        let (panel, model, id) = try rig()
        try click(panel, .listEye(id))
        #expect(model.step(id)?.enabled == false)
        #expect(controls(panel).contains(.turnOn))
        try click(panel, .turnOn)
        #expect(model.step(id)?.enabled == true)
        let n = model.graph?.steps.count ?? 0
        try click(panel, .listAdd)
        #expect(model.graph?.steps.count == n + 1)
    }

    @Test func qualifierSwitchAndRangeBarWriteTheStep() throws {
        let (panel, model, id) = try rig()
        panel.proTab = 2
        try click(panel, .qualOn)
        #expect(model.step(id)?.qualifier != nil)
        let f = try #require(panel.frame(.rangeBar(.luma)))
        let math = RangeBarMath(maximum: 100, minX: f.minX, width: f.width)
        panel.mouseDown(at: CGPoint(x: math.x(0) + 1, y: f.midY - panel.scrollY), clickCount: 1)
        panel.mouseDragged(to: CGPoint(x: math.x(40), y: f.midY - panel.scrollY))
        panel.mouseUp(at: CGPoint(x: math.x(40), y: f.midY - panel.scrollY))
        #expect(abs(model.stepQualifierValue(id, .lumMin) - 40) < 2)
    }

    @Test func windowChipAddsTheWindowAndRemoveClearsIt() throws {
        let (panel, model, id) = try rig()
        panel.proTab = 3
        try click(panel, .shapeChip(0))
        #expect(model.step(id)?.window != nil)
        try click(panel, .windowRemove)
        #expect(model.step(id)?.window == nil)
    }

    @Test func rangeBarMathMapsEdgesAndMoves() {
        let m = RangeBarMath(maximum: 360, minX: 100, width: 180)
        #expect(m.value(at: 190) == 180)
        #expect(m.grab(at: m.x(100) + 2, low: 100, high: 200) == .low)
        #expect(m.apply(.move(offset: 10, width: 50), at: m.x(400), low: 0, high: 0).high == 360)
        #expect(StepRangeKind.params(.hue, low: 20, high: 60).map { $0.1 } == [40, 40])
        #expect(StepRangeKind.bounds(.hue, first: 10, second: 40) == (0, 30))
    }
}

@MainActor @Suite struct ColorStepsDrawTests {
    func rig() throws -> (ColorStepsDraw, ColorInspectorModel) {
        let (_, grade, _) = try ColorGradeDrawTests().rig()
        let steps = ColorStepsDraw(controller: grade.controller)
        steps.size = CGSize(width: 600, height: 320)
        let model = try #require(grade.model)
        model.setActiveGrade(.pro)
        return (steps, model)
    }

    @Test func startButtonAddsAGraphAndTheCanvasShowsIt() throws {
        let (steps, model) = try rig()
        #expect(steps.offersStart && !steps.showsCanvas)
        let b = try #require(steps.buttonFrames()[.startEmpty])
        steps.mouseDown(at: CGPoint(x: b.midX, y: b.midY), clickCount: 1)
        steps.mouseUp(at: CGPoint(x: b.midX, y: b.midY))
        #expect(model.graph?.steps.count == 1 && steps.showsCanvas)
    }

    @Test func clickSelectsEyeBypassesDeleteRemoves() throws {
        let (steps, model) = try rig()
        model.startEmptyGraph()
        model.addStepAtEnd()
        steps.refresh()
        let ids = try #require(model.graph?.steps.map(\.id))
        let l = steps.canvas.layout()
        let r = steps.canvas.viewRect(try #require(l.rects[ids[1]])).offsetBy(dx: steps.well.minX, dy: steps.well.minY)
        let p = CGPoint(x: r.minX + 20, y: r.midY + 6)
        steps.mouseDown(at: p, clickCount: 1)
        steps.mouseUp(at: p)
        #expect(model.selectedStep == ids[1])
        let eye = StepsCanvas.eyeRect(r)
        steps.mouseDown(at: CGPoint(x: eye.midX, y: eye.midY), clickCount: 1)
        steps.mouseUp(at: CGPoint(x: eye.midX, y: eye.midY))
        #expect(model.step(ids[1])?.enabled == false)
        var menu: [SQMenuItem] = []
        steps.onMenu = { items, _ in menu = items }
        steps.mouseDown(at: p, modifiers: [.secondary], clickCount: 1)
        #expect(menu.map(\.title).contains("Add Parallel Step"))
        #expect(steps.key(.delete, modifiers: []))
        #expect(model.graph?.steps.count == 1)
    }
}

@MainActor @Suite struct ColorSourcesDrawTests {
    func rig() throws -> (EditorSession, ColorSourcesDraw, [Clip]) {
        let a = UUID(), b = UUID()
        let c1 = Clip(name: "A1", media: a, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let c2 = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(2, 1))
        let c3 = Clip(name: "A2", media: a, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(4, 1))
        var v = Track(kind: .video)
        for c in [c1, c2, c3] { try v.overwrite(c) }
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])
        var p = Project(name: "P", timelines: [t])
        p.media = [a, b].map { MediaRef(id: $0, name: $0 == a ? "a.mp4" : "b.mp4", path: "/nonexistent", fingerprint: MediaFingerprint(size: 1),
                                        info: MediaInfo(duration: Time(2, 1))) }
        let session = EditorSession(project: p, engine: StubProgramEngine())
        let controller = ColorGradeController(session: session)
        controller.sync([.project, .selection])
        let panel = ColorSourcesDraw(controller: controller)
        panel.size = CGSize(width: 300, height: 200)
        return (session, panel, [c1, c2, c3])
    }

    @Test func oneTilePerSourceClickGradesItAndArrowsStep() throws {
        let (_, panel, clips) = try rig()
        #expect(panel.items.count == 2)
        let r = panel.tileRect(1)
        panel.mouseDown(at: CGPoint(x: r.midX, y: r.midY))
        #expect(panel.highlighted == 1)
        #expect(panel.controller.target.pick == clips[1].id)
        #expect(panel.key(.left, modifiers: []))
        #expect(panel.highlighted == 0)
        // The second tile sits past the 300 pt panel: stepping right scrolls it into view.
        #expect(panel.key(.right, modifiers: []))
        #expect(panel.scrollX > 0 && panel.tileRect(1).maxX <= panel.size.width)
    }

    @Test func secondaryClickOffersGradeMenuWithLinkAllCuts() throws {
        let (_, panel, _) = try rig()
        var titles: [String] = []
        panel.onMenu = { items, _ in titles = items.map(\.title) }
        let r = panel.tileRect(0)
        panel.mouseDown(at: CGPoint(x: r.midX, y: r.midY), modifiers: [.secondary])
        #expect(titles.contains("Copy Grade") && titles.contains("Paste Grade") && titles.contains("Link All Cuts"))
        #expect(ColorSourcesLayout.emptyState(hasSequence: true, itemCount: 0)?.title == "No video clips")
        #expect(ColorSourcesLayout.steppedIndex(from: nil, count: 3, forward: false) == 2)
    }

    @Test func tilesShowTheFirstCutsFrameAspectFilled() throws {
        let (_, panel, clips) = try rig()
        var asked: [(UUID, Time?)] = []
        panel.thumbnail = { media, at in
            asked.append((media, at))
            // A 16:9 atlas cell in the left half of slot 0.
            return ColorSourcesDraw.Thumbnail(slot: 0, source: (0, 0, 0.5, 1), pixelSize: CGSize(width: 160, height: 90))
        }
        panel.size = CGSize(width: 900, height: 200)
        var c = Canvas(width: 900, height: 200, atlas: nil, scale: 1)
        panel.draw(&c)
        // The middle of the first cut's source range (the frame the cut is about, not the poster).
        #expect(asked.first?.0 == clips[0].media && asked.first?.1 == Time(1, 1))
        let images = c.list.quads.filter { $0.kind == DrawQuad.Kind.image.rawValue }
        #expect(images.count == 2)
        let tile = ColorSourcesLayout.thumbSize(panel.controller.format)
        let q = try #require(images.first)
        #expect(q.w == Float(tile.width) && q.h == Float(tile.height))
        // A 16:9 cell is a little wider than the 184 x 104 tile: its sides are cut inside the cell, the height is kept.
        #expect(q.v0 == 0 && q.v1 == 1 && q.u0 > 0 && q.u1 < 0.5 && abs((q.u0 + q.u1) - 0.5) < 1e-5)
    }

    @Test func fillSourceCutsTheLongerSide() {
        let wide = ColorSourcesLayout.fillSource(pixelSize: CGSize(width: 200, height: 100), box: CGSize(width: 100, height: 100))
        #expect(wide == (0.25, 0, 0.75, 1))
        let tall = ColorSourcesLayout.fillSource(pixelSize: CGSize(width: 100, height: 200), box: CGSize(width: 100, height: 100))
        #expect(tall == (0, 0.25, 1, 0.75))
        let same = ColorSourcesLayout.fillSource(pixelSize: CGSize(width: 16, height: 9), box: CGSize(width: 160, height: 90),
                                                 source: (0.1, 0.2, 0.3, 0.4))
        #expect(same == (0.1, 0.2, 0.3, 0.4))
    }
}

@MainActor @Suite struct ColorViewerHeaderDrawTests {
    @Test func segmentSetsCompareAndMoreOpensTheGradeMenu() throws {
        let (_, grade, _) = try ColorGradeDrawTests().rig()
        let header = ColorViewerHeaderDraw(controller: grade.controller)
        header.size = CGSize(width: 500, height: 30)
        let frames = Dictionary(uniqueKeysWithValues: header.frames())
        let split = try #require(frames[.compare(.split)])
        header.mouseDown(at: CGPoint(x: split.midX, y: split.midY))
        #expect(grade.controller.compare == .split)
        var titles: [String] = []
        header.onMenu = { items, _ in titles = items.map(\.title) }
        let more = try #require(frames[.more])
        header.mouseDown(at: CGPoint(x: more.midX, y: more.midY))
        #expect(titles == ["Copy Grade", "Paste Grade"])
        #expect(more.maxX <= 500 && split.maxX <= more.minX)
    }
}

/// The Simple page's geometry is the Mac `ColorGrid` (round 14: label 28, controls from 124, values 56 from the right,
/// 24 pt rows, 28 pt popup rows, the 25 pt section header under a 4 pt gap, no band for a single effect).
@MainActor @Suite struct ColorSimpleMacGeometryTests {
    @Test func rowsAndColumnsFollowTheMacGrid() throws {
        let (_, panel, _) = try ColorGradeDrawTests().rig()
        let model = try #require(panel.model)
        let id = try #require(model.effects.first?.id)
        let rows = panel.rows
        // One effect: no effect band, the first row is Basic's header (4 gap + 25).
        #expect(rows.first?.style == .section && rows.first?.height == 29)
        #expect(!rows.contains { $0.style == .effect })
        // Slider rows are 24 high, the slider 20 from x 124 to the inset, the number 48 wide at the right end.
        let row = try #require(rows.first { $0.controls.contains { $0.0 == .slider(.param(id, .temperature)) } })
        #expect(row.height == 24)
        let f = try #require(panel.frame(.slider(.param(id, .temperature))))
        #expect(f.minX == 124 && f.maxX == 340 - 12 && f.height == 20)
        let parts = panel.sliderParts(f)
        #expect(parts.track.maxX == 340 - 12 - 56 && parts.field.width == 48 && parts.field.maxX == 340 - 12)
        // The LUT row is 28 high: the popup ends 65 before the edge, the star sits at the inset.
        let lut = try #require(rows.first { $0.controls.contains { $0.0 == .lut(id, .input) } })
        #expect(lut.height == 28)
        let pop = try #require(panel.frame(.lut(id, .input))), star = try #require(panel.frame(.lutStar(id, .input)))
        #expect(pop.minX == 124 && pop.maxX == 340 - 65 && pop.height == 22 && star.maxX == 340 - 12 && star.width == 24)
        // The white balance picker is an icon in Basic's header, not a row; no group captions, no Auto row.
        let eye = try #require(panel.frame(.eyedropper(id)))
        #expect(eye.maxX == 340 - 12 && eye.minY < rows[0].height)
        #expect(!rows.contains { $0.style == .group && ($0.label == "Color" || $0.label == "Light" || $0.label == "Adjustments") })
        #expect(!rows.contains { $0.label == "White Balance" })
    }

    @Test func aSecondEffectGetsItsBand() throws {
        let (_, panel, _) = try ColorGradeDrawTests().rig()
        let model = try #require(panel.model)
        model.addEffect()
        #expect(panel.rows.filter { $0.style == .effect }.count == 2)
    }

    @Test func starTogglesOnlyAFileLUT() throws {
        let (_, panel, _) = try ColorGradeDrawTests().rig()
        let id = try #require(panel.model?.effects.first?.id)
        // "Automatic" is no file: the star does nothing and no crash.
        panel.mouseDown(at: try ColorGradeDrawTests().center(panel, .lutStar(id, .input)), clickCount: 1)
        #expect(panel.model?.lutChoice(id, .input)?.filePath == nil)
    }

    @Test func colorTabStripHoldsTheSwitchAndMoreLikeTheMac() throws {
        let (_, panel, _) = try ColorGradeDrawTests().rig()
        let tools = ColorStripToolsDraw(controller: panel.controller)
        let strip = CGRect(x: 0, y: 0, width: 400, height: 28)
        let fr = tools.frames(.colorInspector, strip: strip)
        #expect(fr.map(\.0) == [.simple, .pro, .more])
        // Two 76 pt segments that touch, 5 pt, then the 24 pt "..." 10 pt before the strip's end.
        #expect(fr[0].1.width == 76 && fr[0].1.maxX == fr[1].1.minX && fr[1].1.width == 76)
        #expect(fr[2].1.maxX == 390 && fr[2].1.minX - fr[1].1.maxX == 5)
        // The grade panel offers the menu the strip's "..." opens.
        #expect(!panel.panelMenuItems().isEmpty)
    }

    @Test func sliderKnobTravelsFiveInFromEachEnd() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 20)
        #expect(InspectorDraw.colorSliderFraction(x: 5, in: r) == 0 && InspectorDraw.colorSliderFraction(x: 95, in: r) == 1)
    }
}

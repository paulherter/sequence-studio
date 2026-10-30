import Foundation
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQEditorSession
import SQInspectorUI
import SQUIKit
import Testing

@MainActor
@Suite struct ColorPageHostTests {
    func rig() throws -> (EditorSession, ShellHost, ColorPageHost) {
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        var p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])])
        p.media = [MediaRef(id: media, name: "a.mp4", path: "/nonexistent", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(2, 1)))]
        let s = EditorSession(project: p, fileURL: nil, engine: StubProgramEngine())
        s.select(clips: [clip.id])
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        shell.dock.frame = CGRect(x: 0, y: 44, width: 1600, height: 900)
        shell.dock.layout()
        let host = ColorPageHost(session: s, menus: MenuController(), shell: shell)
        host.layoutSwitch(after: 300, barHeight: 44)
        return (s, shell, host)
    }

    @Test func pageSwitchCentersInTheBar() throws {
        let (_, _, host) = try rig()
        host.layoutSwitch(centeredIn: 1600, barHeight: 44)
        let sw = try #require(host.frames[.pageSwitch])
        #expect(sw.midX == 800 && sw.midY == 22)
        host.layoutSwitch(centeredIn: 1600, barHeight: 44, shown: false)
        #expect(host.frames[.pageSwitch] == nil)
    }

    @Test func pageSwitchShowsTheColorPanelsAndTheViewerHeader() throws {
        let (_, shell, host) = try rig()
        _ = host.monitorCard(shell.dock.cardFrame(.programMonitor))
        host.layout()
        #expect(host.frames[.grade] == nil && host.frames[.header] == nil)
        let sw = try #require(host.frames[.pageSwitch])
        // The right half is Color.
        #expect(host.handle(.mouseDown(x: Float(sw.maxX - 10), y: Float(sw.midY), modifiers: []), scale: 1))
        #expect(shell.dock.store.page == .color)
        let card = try #require(shell.dock.cardFrame(.programMonitor))
        let monitor = try #require(host.monitorCard(card))
        host.layout()
        #expect(host.controller.isOnColorPage)
        #expect(host.frames[.grade] == shell.dock.contentFrame(.colorInspector))
        #expect(host.frames[.header]?.maxY == monitor.minY && monitor.maxY == card.maxY)
        // Back to Edit: the monitor gets its whole card again.
        #expect(host.handle(.mouseDown(x: Float(sw.minX + 10), y: Float(sw.midY), modifiers: []), scale: 1))
        #expect(shell.dock.store.page == .edit)
        #expect(host.monitorCard(card) == card)
    }

    @Test func ctrlCAndCtrlVCopyAndPasteTheGradeOfTheFocusedPanel() throws {
        let (_, shell, host) = try rig()
        shell.dock.setPage(.color)
        _ = host.monitorCard(shell.dock.cardFrame(.programMonitor))
        host.layout()
        let g = try #require(host.frames[.grade])
        _ = host.handle(.mouseDown(x: Float(g.maxX - 4), y: Float(g.maxY - 4), modifiers: []), scale: 1)
        _ = host.handle(.mouseUp(x: Float(g.maxX - 4), y: Float(g.maxY - 4)), scale: 1)
        #expect(host.focus == .grade)
        #expect(!host.controller.canPasteGrade)
        #expect(host.handle(.keyDown(.character("c"), modifiers: [.command]), scale: 1))
        #expect(host.controller.canPasteGrade)
    }

    @Test func selectedStepWindowShowsHandlesOnTheMonitorAndADragIsOneUndoStep() throws {
        let (s, shell, host) = try rig()
        shell.dock.setPage(.color)
        host.layout()
        let model = try #require(host.controller.model)
        model.setActiveGrade(.pro)
        model.startEmptyGraph()
        let id = try #require(model.graph?.steps.first?.id)
        model.selectStep(id, extend: false)
        model.setStepWindowEnabled(id, true)
        host.controller.sync([.project])
        #expect(host.controller.windowEdit != nil)
        let panel = MonitorPanel(model: MonitorPanelModel(frameDuration: Time(1, 30), mode: .program))
        host.refreshStepWindow(panel: panel, isEditingText: false)
        let overlay = try #require(panel.stepWindowEdit)
        var w = overlay.stepWindow
        w.centerX = 0.25
        overlay.onChange?(.began, w)
        overlay.onChange?(.ended, w)
        #expect(model.step(id)?.window?.centerX == 0.25)
        #expect(s.undoName == "Color Graph")
        // Typing text on the monitor hides the handles.
        host.refreshStepWindow(panel: panel, isEditingText: true)
        #expect(panel.stepWindowEdit == nil)
    }

    /// A Program monitor card laid out at 800 x 500 points with a 1920 x 1080 picture.
    func monitor(_ host: ColorPageHost) -> MonitorPanel {
        let panel = MonitorPanel(model: MonitorPanelModel(frameDuration: Time(1, 30), mode: .program))
        panel.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        host.refreshStepWindow(panel: panel, isEditingText: false)
        return panel
    }

    @Test func eyedropperWaitsForAClickOnTheProgramPictureAndSetsTheWhiteBalance() throws {
        let (s, shell, host) = try rig()
        shell.dock.setPage(.color)
        host.layout()
        var beeps = 0
        host.controller.beep = { beeps += 1 }
        let model = try #require(host.controller.model)
        let e = try #require(model.effects.first?.id)
        model.onPickWhiteBalance?(e)
        #expect(beeps == 1 && !host.isPicking, "no read-back: the eyedropper beeps")
        var reads: [Int?] = []
        host.readProgramFrame = { width in
            reads.append(width)
            return ProgramLinearFrame(width: 4, height: 4, pixels: Array(repeating: SIMD3(0.5, 0.4, 0.3), count: 16))
        }
        let panel = monitor(host)
        let r = panel.canvasRect
        #expect(r.width > 0)
        model.onPickWhiteBalance?(e)
        #expect(host.isPicking)
        #expect(host.handle(.mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: []), scale: 1))
        #expect(!host.isPicking && reads == [nil])
        #expect(model.value(e, .temperature) < 0, "a warm pick cools the picture")
        #expect(s.undoName != nil)
        // Escape, or a click beside the picture, cancels without sampling.
        model.onPickWhiteBalance?(e)
        #expect(host.handle(.keyDown(.escape, modifiers: []), scale: 1) && !host.isPicking)
        model.onPickWhiteBalance?(e)
        _ = host.handle(.mouseDown(x: Float(r.maxX + 20), y: Float(r.midY), modifiers: []), scale: 1)
        #expect(!host.isPicking && reads.count == 1)
    }

    @Test func autoAnalyzesAScaledProgramFrame() throws {
        let (_, shell, host) = try rig()
        shell.dock.setPage(.color)
        host.layout()
        var beeps = 0
        host.controller.beep = { beeps += 1 }
        var reads: [Int?] = []
        host.readProgramFrame = { width in
            reads.append(width)
            let n = 96 * 54
            return ProgramLinearFrame(width: 96, height: 54, pixels: (0..<n).map { i in
                let v = 0.02 + 0.2 * Float(i) / Float(n)
                return SIMD3(v, v, v)
            })
        }
        let model = try #require(host.controller.model)
        let e = try #require(model.effects.first?.id)
        let before = model.color
        model.onAutoTone?(e)
        #expect(reads == [96] && beeps == 0)
        #expect(model.color != before, "a dim, flat frame gets a correction")
    }

    @Test func stepsLeaveTheLayoutWhileTheGradeIsSimple() throws {
        let (_, shell, host) = try rig()
        shell.dock.setPage(.color)
        host.layout()
        let model = try #require(host.controller.model)
        model.setActiveGrade(.pro)
        model.startEmptyGraph()
        host.controller.sync([.project])
        host.layout()
        shell.dock.show(.steps)
        host.layout()
        #expect(shell.dock.shows(.steps) && host.frames[.steps] != nil && host.controller.stepsShown)
        model.setActiveGrade(.simple)
        host.controller.sync([.project])
        host.layout()
        #expect(!shell.dock.shows(.steps) && host.frames[.steps] == nil && !host.controller.stepsShown)
        #expect(shell.dock.store.current.isVisible(.steps), "shown, not stored")
        // Back on the Edit page nothing is hidden.
        shell.dock.setPage(.edit)
        host.layout()
        #expect(shell.dock.transientlyHidden.isEmpty)
    }

    @Test func linearFrameAveragesThePatchAndCutsItAtTheEdge() throws {
        var px = [SIMD3<Float>](repeating: .zero, count: 100)
        px[0] = SIMD3(9, 9, 9)
        let f = ProgramLinearFrame(width: 10, height: 10, pixels: px)
        // Top-left corner: a 3 x 3 patch (radius 2 cut at the edge) holding the one bright pixel.
        #expect(ProgramLinearFrame.patch(width: 10, height: 10, at: SIMD2(0, 0), radius: 2)! == (0, 0, 3, 3))
        #expect(f.average(at: SIMD2(0, 0)) == SIMD3(1, 1, 1))
        #expect(f.average(at: SIMD2(1.2, 0.5)) == nil)
        #expect(ProgramLinearFrame.scaledSize(width: 96, sourceWidth: 1920, sourceHeight: 1080)! == (96, 54))
        // Half floats: 1.0 = 0x3C00, 0.5 = 0x3800, 2.0 = 0x4000.
        let bytes: [UInt8] = [0x00, 0x3C, 0x00, 0x38, 0x00, 0x40, 0x00, 0x3C]
        #expect(ProgramLinearFrame(halfRGBA: bytes, width: 1, height: 1)?.pixels == [SIMD3(1, 0.5, 2)])
    }

    @Test func aLaterProgramFrameStillFinishesThePickAndAuto() throws {
        let (_, shell, host) = try rig()
        shell.dock.setPage(.color)
        host.layout()
        var beeps = 0
        host.controller.beep = { beeps += 1 }
        var pending: [(Int?, @MainActor (ProgramLinearFrame?) -> Void)] = []
        host.requestProgramFrame = { width, done in pending.append((width, done)) }
        let model = try #require(host.controller.model)
        let e = try #require(model.effects.first?.id)
        let panel = monitor(host)
        let r = panel.canvasRect
        model.onPickWhiteBalance?(e)
        #expect(host.isPicking && beeps == 0)
        #expect(host.handle(.mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: []), scale: 1))
        #expect(!host.isPicking && pending.count == 1 && pending[0].0 == nil)
        let before = model.value(e, .temperature)
        pending.removeFirst().1(ProgramLinearFrame(width: 4, height: 4, pixels: Array(repeating: SIMD3(0.5, 0.4, 0.3), count: 16)))
        #expect(model.value(e, .temperature) < before, "the warm pick lands when the frame arrives")
        let color = model.color
        model.onAutoTone?(e)
        #expect(pending.count == 1 && pending[0].0 == 96 && model.color == color, "Auto waits for the frame")
        let n = 96 * 54
        pending.removeFirst().1(ProgramLinearFrame(width: 96, height: 54, pixels: (0..<n).map { i in
            let v = 0.02 + 0.2 * Float(i) / Float(n)
            return SIMD3(v, v, v)
        }))
        #expect(model.color != color && beeps == 0)
    }
}

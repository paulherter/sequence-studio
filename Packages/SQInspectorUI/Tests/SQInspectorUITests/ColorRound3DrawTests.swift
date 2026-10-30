import Foundation
import CoreGraphics
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// Color page on the shared toolkit, round 3: the red flash of a refused wire, the hover tips and the strip tools.
@MainActor @Suite struct ColorRound3DrawTests {
    func steps() throws -> (ColorStepsDraw, ColorInspectorModel, [UUID]) {
        let (s, model) = try ColorStepsDrawTests().rig()
        model.startEmptyGraph()
        model.addStepAtEnd()
        s.refresh()
        return (s, model, try #require(model.graph?.steps.map(\.id)))
    }

    /// The first point (window coordinates) whose hit is `h`, scanned over the well.
    func point(_ s: ColorStepsDraw, _ h: StepsCanvas.Hit) -> CGPoint? {
        let w = s.well
        var y = w.minY
        while y < w.maxY {
            var x = w.minX
            while x < w.maxX {
                let p = CGPoint(x: x, y: y)
                if s.hit(at: p) == h { return p }
                x += 1
            }
            y += 1
        }
        return nil
    }

    @Test func aRefusedWireRingsItsTargetRedForSevenTenthsOfASecond() throws {
        let (s, model, ids) = try steps()
        var now = 100.0
        s.clock = { now }
        let before = model.graph
        // The second Step's output back into the first Step's input would be a loop: refused.
        let from = try #require(point(s, .dotOut(.step(ids[1]))))
        let to = try #require(point(s, .dotIn(.step(ids[0]))))
        s.mouseDown(at: from, clickCount: 1)
        s.mouseDragged(to: to)
        s.mouseUp(at: to)
        #expect(model.graph == before)
        #expect(s.refusedFlash?.port == .step(ids[0]) && s.isFlashing)
        now += ColorStepsDraw.refusedFlashSeconds - 0.01
        #expect(s.isFlashing)
        now += 0.02
        #expect(!s.isFlashing)
        s.mouseDown(at: from, clickCount: 1)
        #expect(s.refusedFlash == nil)
    }

    @Test func stepsTipsNameButtonsStepsAndDots() throws {
        let (empty, _) = try ColorStepsDrawTests().rig()
        let b = try #require(empty.buttonFrames()[.startEmpty])
        #expect(empty.help(at: CGPoint(x: b.midX, y: b.midY)) == "Start a Color Graph with one empty Step")
        let (s, model, ids) = try steps()
        let dot = try #require(point(s, .dotOut(.step(ids[0]))))
        #expect(s.help(at: dot) == "Drag to an input to wire")
        let box = try #require(point(s, .step(ids[1])))
        #expect(s.help(at: box) == model.step(ids[1])?.label)
        let eye = try #require(point(s, .eye(ids[1])))
        #expect(s.help(at: eye) == "Turn this Step off")
        #expect(s.addMenuItems()?.isEmpty == false)
        #expect(empty.addMenuItems() == nil)
    }

    @Test func sourcesTipIsTheTileName() throws {
        let (_, panel, clips) = try ColorSourcesDrawTests().rig()
        let i = try #require(panel.items.indices.first)
        let f = try #require(Optional(panel.tileRect(i)))
        #expect(panel.help(at: CGPoint(x: f.midX, y: f.midY)) == panel.items[i].name)
        #expect(!clips.isEmpty)
    }

    @Test func viewerHeaderTipsTheCompareModesAndTheClipName() throws {
        let (_, grade, _) = try ColorGradeDrawTests().rig()
        let h = ColorViewerHeaderDraw(controller: grade.controller)
        let fr = h.frames()
        let split = try #require(fr.first { $0.0 == .compare(.split) }?.1)
        #expect(h.help(at: CGPoint(x: split.midX, y: split.midY)) == "Split: ungraded on the left, graded on the right")
        let more = try #require(fr.first { $0.0 == .more }?.1)
        #expect(h.help(at: CGPoint(x: more.midX, y: more.midY)) == "More viewer actions")
        #expect(h.help(at: CGPoint(x: 20, y: 10)) == grade.controller.viewerHeaderContent.name)
    }

    @Test func stripToolsLayOutCopyAndBeepWhenRefused() throws {
        let (session, grade, clip) = try ColorGradeDrawTests().rig()
        let c = grade.controller
        let tools = ColorStripToolsDraw(controller: c)
        var beeps = 0
        c.beep = { beeps += 1 }
        #expect(ColorStripToolsDraw.buttons(.steps) == [.addStep, .copy, .paste])
        #expect(ColorStripToolsDraw.buttons(.sources) == [.copy, .paste])
        #expect(ColorStripToolsDraw.buttons(.colorInspector) == [.simple, .pro, .more])
        // Width: buttons + gap + right margin + the detail (capped).
        let w = tools.width(.sources, measure: { _ in 1000 })
        #expect(w == 2 * 24 + 2 + ColorStripToolsDraw.detailMax + 2 * ColorStripToolsDraw.detailGap + ColorStripToolsDraw.right)
        let strip = CGRect(x: 0, y: 0, width: 800, height: 28)
        let fr = tools.frames(.sources, strip: strip)
        #expect(fr.map(\.0) == [.copy, .paste] && fr.last!.1.maxX == strip.maxX - ColorStripToolsDraw.right)
        #expect(tools.help(panel: .sources, strip: strip, at: CGPoint(x: fr[0].1.midX, y: fr[0].1.midY)) == "Copy the grade of what is being graded")
        #expect(tools.help(panel: .sources, strip: strip, at: CGPoint(x: 10, y: 10)) == ColorGradeController.sourcesHint)
        // Copy, then paste: both act on release over the button.
        #expect(c.canCopyGrade)
        let copy = CGPoint(x: fr[0].1.midX, y: fr[0].1.midY)
        #expect(tools.mouseDown(panel: .sources, strip: strip, at: copy))
        tools.mouseUp(panel: .sources, strip: strip, at: copy)
        #expect(c.canPasteGrade && beeps == 0)
        // Add Step without a graph: refused with a beep, no menu.
        var menus = 0
        tools.onMenu = { _, _ in menus += 1 }
        tools.addMenuItems = { nil }
        tools.press(.addStep, anchor: .zero)
        #expect(beeps == 1 && menus == 0)
        tools.addMenuItems = { [SQMenuItem(title: "Step") {}] }
        tools.press(.addStep, anchor: .zero)
        #expect(menus == 1)
        _ = session; _ = clip
    }
}

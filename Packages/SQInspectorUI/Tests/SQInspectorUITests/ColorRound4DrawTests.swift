import Foundation
import CoreGraphics
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// Color page on the shared toolkit, round 4: the Timeline strip's tools and the Steps graph's In / Out tips.
@MainActor @Suite struct ColorRound4DrawTests {
    @Test func theTimelineStripShowsItsHintAndCopyPasteGrade() throws {
        let (s, _) = try ColorStepsDrawTests().rig()
        let tools = ColorStripToolsDraw(controller: s.controller)
        #expect(ColorStripToolsDraw.buttons(.timeline) == [.copy, .paste])
        // A picked clip: no hint (the Mac `timelineDetail`); with nothing gradable picked the hint says what a click does.
        #expect(s.controller.timelineDetail.isEmpty && tools.detail(.timeline) == nil)
        #expect(ColorGradeController.timelineDetail(for: .message("")) == ColorGradeController.timelineHint)
        let strip = CGRect(x: 0, y: 0, width: 600, height: 26)
        let fr = tools.frames(.timeline, strip: strip)
        #expect(fr.map(\.0) == [.copy, .paste])
        #expect(fr.last?.1.maxX == strip.maxX - ColorStripToolsDraw.right)
        let paste = try #require(fr.last?.1)
        #expect(tools.help(panel: .timeline, strip: strip, at: CGPoint(x: paste.midX, y: paste.midY))
                == SQL10n.string("Paste the copied grade onto the selected clips"))
        // The room the dock leaves: two buttons and the right inset (no detail).
        #expect(tools.width(.timeline) { _ in 50 } == 2 * 24 + 2 + ColorStripToolsDraw.right)
    }

    @Test func theGraphsInAndOutSlotsTellTheirLUT() throws {
        let r3 = ColorRound3DrawTests()
        let (s, model, _) = try r3.steps()
        let inP = try #require(r3.point(s, .input))
        let outP = try #require(r3.point(s, .output))
        // An untouched graph's input is Automatic (the clip's own conversion); the output has none.
        let input = try #require(model.graphLUTChoice(.input)).name
        #expect(s.help(at: inP) == SQL10n.format("In LUT: %@", SQL10n.string(input)))
        #expect(s.help(at: outP) == SQL10n.format("Out LUT: %@", SQL10n.string("None")))
        model.setGraphLUT(.output, ColorInspectorModel.LUTChoice(id: "file:/l/look.cube", name: "look"))
        s.refresh()
        if let name = model.graphLUTChoice(.output)?.name {
            #expect(s.help(at: outP) == SQL10n.format("Out LUT: %@", SQL10n.string(name)))
        }
    }
}

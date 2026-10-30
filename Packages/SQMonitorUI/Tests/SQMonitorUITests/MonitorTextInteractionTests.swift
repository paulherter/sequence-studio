import Testing
@testable import SQMonitorUI

@Suite("Monitor text interaction table")
struct MonitorTextInteractionTests {
    typealias M = MonitorTextInteraction

    @Test func typeToolAlwaysShowsIBeam() {
        for hit in [M.Hit.empty, .textLayer, .handle] {
            for editing in [false, true] {
                #expect(M.cursor(tool: .type, hit: hit, editing: editing) == .iBeam)
            }
        }
    }

    @Test func selectToolCursors() {
        #expect(M.cursor(tool: .select, hit: .textLayer, editing: false) == .move)
        #expect(M.cursor(tool: .select, hit: .handle, editing: false) == .overlay)
        #expect(M.cursor(tool: .select, hit: .empty, editing: false) == .arrow)
        #expect(M.cursor(tool: .hand, hit: .textLayer, editing: false) == .openHand)
    }

    @Test func frameVisibility() {
        #expect(M.frameVisible(tool: .select, hasTextTarget: true, editing: false))
        #expect(M.frameVisible(tool: .type, hasTextTarget: true, editing: false))
        #expect(M.frameVisible(tool: .type, hasTextTarget: true, editing: true))
        #expect(M.frameVisible(tool: .select, hasTextTarget: true, editing: true))
        #expect(!M.frameVisible(tool: .select, hasTextTarget: false, editing: false))
        #expect(!M.frameVisible(tool: .hand, hasTextTarget: true, editing: false))
    }

    @Test func frameIsOnlyInteractiveWithSelectToolWhileIdle() {
        #expect(M.frameIsInteractive(tool: .select, editing: false))
        #expect(!M.frameIsInteractive(tool: .select, editing: true))
        #expect(!M.frameIsInteractive(tool: .type, editing: false))
    }

    @Test func typeClickOnEmptyCreatesText() {
        #expect(M.actions(tool: .type, hit: .empty, editing: false, event: .click) == [.createText])
        #expect(M.actions(tool: .type, hit: .empty, editing: true, event: .click) == [.endEditing, .createText])
    }

    @Test func typeClickOnTextEditsWithCaretAtClick() {
        #expect(M.actions(tool: .type, hit: .textLayer, editing: false, event: .click) == [.editText(caretAtClick: true)])
        #expect(M.actions(tool: .type, hit: .textLayer, editing: true, event: .click) == [.endEditing, .editText(caretAtClick: true)])
    }

    @Test func selectDoubleClickEntersEditing() {
        #expect(M.actions(tool: .select, hit: .textLayer, editing: false, event: .doubleClick) == [.editText(caretAtClick: false)])
        #expect(M.actions(tool: .select, hit: .textLayer, editing: false, event: .click).isEmpty)
    }

    @Test func clickOutsideAndEscapeEndEditingOnly() {
        #expect(M.actions(tool: .select, hit: .empty, editing: true, event: .click) == [.endEditing])
        #expect(M.actions(tool: .select, hit: .empty, editing: true, event: .doubleClick) == [.endEditing])
        #expect(M.actions(tool: .select, hit: .empty, editing: false, event: .click).isEmpty)
        for tool in [ProgramSurfaceView.Tool.select, .type] {
            #expect(M.actions(tool: tool, hit: .empty, editing: true, event: .escape) == [.endEditing])
            #expect(M.actions(tool: tool, hit: .empty, editing: false, event: .escape).isEmpty)
        }
    }

    @Test func handToolAndHoverDoNothing() {
        #expect(M.actions(tool: .hand, hit: .textLayer, editing: false, event: .click).isEmpty)
        #expect(M.actions(tool: .type, hit: .textLayer, editing: false, event: .hover).isEmpty)
    }
}

@Suite("Monitor text interaction, graphic selected")
struct MonitorTextInteractionGraphicTests {
    typealias M = MonitorTextInteraction

    @Test func typeToolCreatesOrEditsLayers() {
        #expect(M.actions(tool: .type, hit: .empty, editing: false, event: .click, inGraphic: true) == [.createLayerText])
        #expect(M.actions(tool: .type, hit: .textLayer, editing: false, event: .click, inGraphic: true) == [.editLayerText(caretAtClick: true)])
        #expect(M.actions(tool: .type, hit: .empty, editing: true, event: .click, inGraphic: true) == [.endEditing, .createLayerText])
    }

    @Test func selectDoubleClickEditsOnlyTextLayers() {
        #expect(M.actions(tool: .select, hit: .textLayer, editing: false, event: .doubleClick, inGraphic: true) == [.editLayerText(caretAtClick: false)])
        #expect(M.actions(tool: .select, hit: .empty, editing: false, event: .doubleClick, inGraphic: true).isEmpty)
        #expect(M.actions(tool: .select, hit: .textLayer, editing: true, event: .doubleClick, inGraphic: true) == [.endEditing])
    }

    @Test func escapeEndsEditingAndHandIsInert() {
        #expect(M.actions(tool: .type, hit: .empty, editing: true, event: .escape, inGraphic: true) == [.endEditing])
        #expect(M.actions(tool: .type, hit: .empty, editing: false, event: .escape, inGraphic: true).isEmpty)
        #expect(M.actions(tool: .hand, hit: .textLayer, editing: false, event: .click, inGraphic: true).isEmpty)
    }

    @Test func newTextReclaimsFocusOnlyWhenNobodyTookItOnPurpose() {
        #expect(M.reclaimsFocus(protectedUntil: 10, now: 5, causedByMouseDown: false, newResponderIsText: false))
        #expect(!M.reclaimsFocus(protectedUntil: 10, now: 11, causedByMouseDown: false, newResponderIsText: false))
        #expect(!M.reclaimsFocus(protectedUntil: 10, now: 5, causedByMouseDown: true, newResponderIsText: false))
        #expect(!M.reclaimsFocus(protectedUntil: 10, now: 5, causedByMouseDown: false, newResponderIsText: true))
        #expect(!M.reclaimsFocus(protectedUntil: nil, now: 5, causedByMouseDown: false, newResponderIsText: false))
    }

    @Test func defaultStaysTheTextClipTable() {
        #expect(M.actions(tool: .type, hit: .empty, editing: false, event: .click) == [.createText])
    }
}

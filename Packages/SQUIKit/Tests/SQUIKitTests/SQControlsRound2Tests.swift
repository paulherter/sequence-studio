import AppKit
import Testing
@testable import SQUIKit

@Suite @MainActor struct SQRadioTests {
    @Test func stepWrapsAndSkipsDisabled() {
        let en = [true, false, true]
        #expect(SQRadioLogic.step(from: 0, direction: .next, enabled: en) == 2)
        #expect(SQRadioLogic.step(from: 2, direction: .next, enabled: en) == 0)
        #expect(SQRadioLogic.step(from: 0, direction: .previous, enabled: en) == 2)
        #expect(SQRadioLogic.step(from: nil, direction: .next, enabled: en) == 0)
        #expect(SQRadioLogic.step(from: nil, direction: .previous, enabled: en) == 2)
        #expect(SQRadioLogic.step(from: 0, direction: .next, enabled: [false, false]) == nil)
        #expect(SQRadioLogic.step(from: nil, direction: .next, enabled: []) == nil)
    }

    @Test func groupKeepsOneSelected() {
        var changes: [Int?] = []
        let (g, rs) = SQRadioGroup.make(titles: ["A", "B", "C"], selected: 0) { changes.append($0) }
        #expect(g.selectedIndex == 0)
        rs[2].select()
        #expect(g.selectedIndex == 2)
        #expect(rs.filter { $0.isSelected }.count == 1)
        #expect(changes == [2])
        rs[2].select()          // already selected: no change event
        #expect(changes == [2])
    }

    @Test func disabledRadioDoesNotSelect() {
        let (g, rs) = SQRadioGroup.make(titles: ["A", "B"], selected: 0)
        rs[1].isEnabled = false
        rs[1].select()
        #expect(g.selectedIndex == 0)
    }

    @Test func arrowMovesInsideGroup() {
        let (g, rs) = SQRadioGroup.make(titles: ["A", "B", "C"], selected: 0)
        rs[1].isEnabled = false
        g.move(from: rs[0], .next)
        #expect(g.selectedIndex == 2)
        g.move(from: rs[2], .previous)
        #expect(g.selectedIndex == 0)
    }

    @Test func sizeAndFill() {
        let r = SQRadio(title: "")
        #expect(r.intrinsicContentSize == NSSize(width: 14, height: 14))
        let t = SQRadio(title: "Option")
        #expect(t.intrinsicContentSize.width > 20)
        #expect(SQRadio.boxFill(hovered: false, pressed: false) == Theme.State.controlRest)
        #expect(SQRadio.boxFill(hovered: true, pressed: false) == Theme.State.controlHover)
        #expect(SQRadio.boxFill(hovered: true, pressed: true) == Theme.State.pressed)
    }
}

@Suite @MainActor struct SQScrollerTests {
    @Test func knobIsThinAndHugsTheEdge() {
        let bounds = NSRect(x: 0, y: 0, width: 9, height: 200)
        let k = SQScrollerMetrics.knob(in: NSRect(x: 0, y: 40, width: 9, height: 60), vertical: true, bounds: bounds)
        #expect(k.width == 5)
        #expect(k.maxX == 7)
        #expect(k.minY == 40 && k.height == 60)
        let tiny = SQScrollerMetrics.knob(in: NSRect(x: 0, y: 0, width: 9, height: 4), vertical: true, bounds: bounds)
        #expect(tiny.height == 20)
        let h = SQScrollerMetrics.knob(in: NSRect(x: 30, y: 0, width: 80, height: 9), vertical: false, bounds: NSRect(x: 0, y: 0, width: 300, height: 9))
        #expect(h.height == 5 && h.width == 80 && h.minX == 30)
    }

    @Test func alphaAndWidth() {
        #expect(SQScrollerMetrics.knobAlpha(active: false) < SQScrollerMetrics.knobAlpha(active: true))
        #expect(SQScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) == 12)
    }

    @Test func applyInstallsOnBothAxes() {
        let sv = NSScrollView()
        SQScrollView.apply(to: sv)
        #expect(sv.verticalScroller is SQScroller)
        #expect(sv.horizontalScroller is SQScroller)
        #expect(sv.scrollerStyle == .overlay)
        SQScrollView.apply(to: sv)   // idempotent
        #expect(sv.verticalScroller is SQScroller)
    }
}

@Suite @MainActor struct SQTooltipTests {
    @Test func sizeAddsPadding() {
        #expect(SQTooltipLayout.size(forText: NSSize(width: 40.2, height: 12)) == NSSize(width: 65, height: 28))
    }

    @Test func placementBelowRightAndFlips() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: 100, height: 20)
        let normal = SQTooltipLayout.frame(size: size, pointer: NSPoint(x: 200, y: 400), screen: screen)
        #expect(normal.minX == 210 && normal.maxY == 400 - 18)
        let right = SQTooltipLayout.frame(size: size, pointer: NSPoint(x: 990, y: 400), screen: screen)
        #expect(right.maxX <= 996 && right.maxX < 990)
        let bottom = SQTooltipLayout.frame(size: size, pointer: NSPoint(x: 200, y: 10), screen: screen)
        #expect(bottom.minY >= 4 && bottom.minY > 10)
        let inside = SQTooltipLayout.frame(size: size, pointer: NSPoint(x: 995, y: 795), screen: screen)
        #expect(screen.insetBy(dx: 4, dy: 4).contains(inside))
    }

    @Test func attachSetAndRemove() {
        let v = NSView()
        #expect(v.sqToolTip == nil)
        v.sqToolTip = "Play"
        #expect(v.sqToolTip == "Play")
        v.sqToolTip = "Pause"
        #expect(v.sqToolTip == "Pause")
        #expect(v.trackingAreas.count == 1)
        v.sqToolTip = nil
        #expect(v.sqToolTip == nil)
        #expect(v.trackingAreas.isEmpty)
    }

    @Test func neverTwoAtOnce() {
        let t = SQTooltip.shared
        t.show(text: "One")
        t.show(text: "Two")
        #expect(t.currentText == "Two")
        t.hide()
        #expect(!t.isShown && t.currentText == nil)
    }
}

@Suite @MainActor struct SQTextFieldMenuTests {
    @Test func itemsAndOrder() {
        let items = SQTextFieldMenu.items(for: .init(isEditable: true, hasSelection: true, hasText: true, canPaste: true))
        #expect(items.map { $0.title } == ["Cut", "Copy", "Paste", "", "Select All"])
        #expect(items[3].kind == .separator)
        #expect(items.map { $0.shortcut } == ["⌘X", "⌘C", "⌘V", "", "⌘A"])
        #expect(items.filter { $0.kind == .action }.allSatisfy { $0.isEnabled })
    }

    @Test func enabledStates() {
        let none = SQTextFieldMenu.items(for: .init(isEditable: true, hasSelection: false, hasText: false, canPaste: false))
        #expect(none.filter { $0.kind == .action }.allSatisfy { !$0.isEnabled })
        let readOnly = SQTextFieldMenu.items(for: .init(isEditable: false, hasSelection: true, hasText: true, canPaste: true))
        #expect(!readOnly[0].isEnabled && readOnly[1].isEnabled && !readOnly[2].isEnabled && readOnly[4].isEnabled)
        let noSel = SQTextFieldMenu.items(for: .init(isEditable: true, hasSelection: false, hasText: true, canPaste: true))
        #expect(!noSel[0].isEnabled && !noSel[1].isEnabled && noSel[2].isEnabled && noSel[4].isEnabled)
    }

    @Test func actionsAreWired() {
        var log: [String] = []
        let a = SQTextFieldMenu.Actions(cut: { log.append("cut") }, copy: { log.append("copy") },
                                        paste: { log.append("paste") }, selectAll: { log.append("all") })
        let items = SQTextFieldMenu.items(for: .init(isEditable: true, hasSelection: true, hasText: true, canPaste: true), actions: a)
        for i in items where i.kind == .action { i.action?() }
        #expect(log == ["cut", "copy", "paste", "all"])
    }

    @Test func installSetsEmptyMenu() {
        let f = NSTextField()
        _ = f
        SQTextFieldMenu.install(on: f)
        #expect(f.menu == nil)
    }
}

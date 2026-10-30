import AppKit
import Testing
@testable import SQUIKit

@Suite struct SQModalTests {
    typealias M = SQDialogModel
    private func model(_ b: [(String, M.Role)]) -> M { M(buttons: b.map { M.Button(title: $0.0, role: $0.1) }) }
    private func key(_ m: M, _ code: UInt16, cmd: Bool = false, ch: String? = nil, other: Bool = false, focus: Int? = nil) -> M.Response? {
        SQModal.response(for: m, keyCode: code, command: cmd, otherModifiers: other, character: ch, focusedIndex: focus)
    }

    @MainActor @Test func sheetHeaderIsExactly56ForATitleOnlyHeader() {
        let d = SQDialog()
        d.messageText = "Audio Gain"
        d.accessoryView = SQDialogForm(rows: [])
        d.addButton("OK", role: .default)
        let w = d.layout()
        w.contentView?.layoutSubtreeIfNeeded()
        func find(_ v: NSView) -> NSView? { v is SQDialogText ? v : v.subviews.lazy.compactMap(find).first }
        let header = find(w.scrim)?.superview?.superview
        #expect(header != nil)
        #expect(abs((header?.frame.height ?? 0) - Theme.Modal.headerHeight) < 0.5)
    }

    @MainActor @Test func backdropStartsAtFinalFrameAndSheetCardDoesNotDim() {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let b = SQModalBackdropView.show(over: host)
        #expect(b != nil)
        #expect(b?.frame == host.contentView?.bounds)
        #expect(b?.autoresizingMask == [.width, .height])
        #expect(Theme.Modal.dimFade == 0 && Theme.Modal.dimFadeOut == 0)   // no fade: the dim shows at once
        let win = SQDialogWindow(card: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        win.attachBackdrop(to: host)
        #expect(win.scrim.dimsItself == false)
        #expect(win.scrim.layer?.backgroundColor == NSColor.clear.cgColor)
        win.removeBackdrop()
        b?.removeFromSuperview()
    }

    @MainActor @Test func formRowsShareOneLabelColumn() {
        #expect(SQDialogMetrics.labelWidth == Theme.Modal.labelColumn && Theme.Modal.labelColumn == Theme.Sheet.labelColumn)
        let field = NSView()
        let rows = ["A", "Longer Label"].map { SQDialog.formRow($0, field) }
        let form = SQDialogForm(rows: rows)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
        host.addSubview(form)
        form.frame = host.bounds
        form.layoutSubtreeIfNeeded()
        let lefts = rows.map { r in r.subviews.last.map { r.convert($0.frame, to: nil).minX } ?? -1 }
        #expect(lefts[0] == lefts[1])
        #expect(abs(lefts[0] - (SQDialogMetrics.sidePad + Theme.Modal.labelColumn + SQDialogMetrics.labelGap)) < 1.5)
        #expect(rows.allSatisfy { abs($0.frame.height - Theme.Sheet.controlHeight) < 0.5 })
    }

    /// Feedback 2026-10-17: a gray scrim lifted the near-black UI into a flat bluish area behind every pop-up. Black, low alpha only.
    @Test func scrimIsNeutralBlackAndSubtle() {
        let c = Theme.Modal.scrimColor.usingColorSpace(.deviceRGB)
        #expect(c != nil)
        #expect(c?.redComponent == 0 && c?.greenComponent == 0 && c?.blueComponent == 0)
        #expect(Theme.Modal.scrimAlpha <= 0.4)
    }

    // Sizes and placement
    @Test func sizesFollowTheProposal() {
        #expect(SQModal.Size.xs.width == 360 && SQModal.Size.s.width == 440 && SQModal.Size.sList.width == 480 && SQModal.Size.m.width == 600)
        #expect(SQModal.Size.l.width == 860 && SQModal.Size.l.height == 640 && SQModal.Size.s.height == nil)
        #expect(SQModal.Size.l.labelColumn == 132 && SQModal.Size.m.labelColumn == 104)
        #expect(Theme.Modal.scrimAlpha == 0.35 && Theme.Modal.radius == 14)
        #expect(Theme.Modal.headerHeight == 56 && Theme.Modal.footerHeight == 68)
    }

    @Test func cardIsCenteredAndClampedToTheWindow() {
        let r = SQModal.cardFrame(size: NSSize(width: 440, height: 200), in: NSRect(x: 0, y: 0, width: 1200, height: 800))
        #expect(r == NSRect(x: 380, y: 300, width: 440, height: 200))
        let small = SQModal.cardFrame(size: NSSize(width: 860, height: 640), in: NSRect(x: 0, y: 0, width: 600, height: 500))
        #expect(small.width == 552 && small.height == 452 && small.midX == 300)
    }

    // Button order
    @Test func footerOrderIsFixed() {
        let save = model([("Save", .save), ("Cancel", .cancel), ("Don’t Save", .dontSave)])
        #expect(save.displayOrder.map { save.buttons[$0].title } == ["Don’t Save", "Cancel", "Save"])
        let many = model([("Replace", .default), ("Skip", .normal), ("Cancel", .cancel)])
        #expect(many.displayOrder.map { many.buttons[$0].title } == ["Skip", "Cancel", "Replace"])
        let del = model([("Delete", .destructive), ("Cancel", .cancel)])
        #expect(del.displayOrder.map { del.buttons[$0].title } == ["Cancel", "Delete"])
    }

    // Keys
    @Test func returnPressesMainActionEscapeCancel() {
        let m = model([("Save", .save), ("Cancel", .cancel), ("Don’t Save", .dontSave)])
        #expect(key(m, 36) == .first && key(m, 76) == .first)
        #expect(key(m, 53) == .second)
        #expect(key(m, 47, cmd: true, ch: ".") == .second)
        #expect(key(m, 2, cmd: true, ch: "d") == .third)
        #expect(key(m, 1, cmd: true, ch: "s") == .first)
        #expect(key(m, 36, other: true) == nil)
        #expect(key(m, 0) == nil)
    }

    @Test func returnNeverPressesDestructiveAndFocusStartsOnCancel() {
        let m = model([("Delete", .destructive), ("Cancel", .cancel)])
        #expect(key(m, 36) == .second)
        #expect(m.initialFocusIndex == 1)
        let alone = model([("Delete", .destructive)])
        #expect(key(alone, 36) == .first)
        #expect(model([("OK", .default), ("Cancel", .cancel)]).initialFocusIndex == nil)
    }

    @Test func returnPressesTheFocusedButton() {
        let m = model([("Save", .save), ("Cancel", .cancel), ("Don’t Save", .dontSave)])
        #expect(key(m, 36, focus: 2) == .third)
    }

    @Test func cmdDAndCmdSNeedTheirRoles() {
        let m = model([("OK", .default), ("Cancel", .cancel)])
        #expect(key(m, 2, cmd: true, ch: "d") == nil && key(m, 1, cmd: true, ch: "s") == nil)
    }

    // The shell as built by SQDialog
    @MainActor @Test func dialogCoversTheWindowAndCentersItsCard() throws {
        let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let d = SQDialog()
        d.messageText = "Delete Clip?"
        d.addButton("Delete", role: .destructive)
        d.addButton("Cancel", role: .cancel)
        var got: SQDialogModel.Response?
        d.beginSheetModal(for: host) { got = $0 }
        let w = try #require(host.sqAttachedSheet as? SQDialogWindow)
        #expect(w.frame.size == host.frame.size)
        w.scrim.layoutSubtreeIfNeeded()
        let card = w.scrim.card.frame
        #expect(card.width == 440)
        #expect(abs(card.midX - w.scrim.bounds.midX) <= 1 && abs(card.midY - w.scrim.bounds.midY) <= 1)
        #expect((w.firstResponder as? SQButton)?.title == SQL10n.string("Cancel"))
        d.press(.second)
        #expect(got == .second)
        #expect(host.sqAttachedSheet == nil)
    }
}

@Suite struct SQUnhandledKeyTests {
    @Test func deleteKeysAreSilent() {
        #expect(SQUnhandledKey.isSilent(keyCode: 51) && SQUnhandledKey.isSilent(keyCode: 117))
        #expect(!SQUnhandledKey.isSilent(keyCode: 53) && !SQUnhandledKey.isSilent(keyCode: 0))
    }
}

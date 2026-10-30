import Foundation
import Testing
import SQDrawKit
import SQUIKit

@Suite("Inspector controls")
struct InspectorControlsTests {
    private func red(_ img: RGBAImage, _ x: Int, _ y: Int) -> UInt8 { img.pixels[(y * img.width + x) * 4] }

    // MARK: Controls key switch and key button

    @Test func animateSwitchIsHollowWhenStaticAndSolidWhenAnimated() {
        let t = DrawTheme()
        var hollow = Canvas(width: 20, height: 20, atlas: nil, scale: 1)
        InspectorDraw.animateSwitch(&hollow, animated: false, hovering: false, center: CGPoint(x: 10, y: 10), t)
        var solid = Canvas(width: 20, height: 20, atlas: nil, scale: 1)
        InspectorDraw.animateSwitch(&solid, animated: true, hovering: false, center: CGPoint(x: 10, y: 10), t)
        let h = SoftwareRenderer.render(hollow.list, width: 20, height: 20, clear: .black, atlas: nil)
        let f = SoftwareRenderer.render(solid.list, width: 20, height: 20, clear: .black, atlas: nil)
        func lum(_ img: RGBAImage, _ x: Int, _ y: Int) -> Int { (0..<3).reduce(0) { $0 + Int(img.pixels[(y * img.width + x) * 4 + $1]) } }
        #expect(lum(h, 10, 10) == 0 && lum(h, 10, 5) + lum(h, 10, 6) > 0)      // no dot, the outline is there
        #expect(lum(f, 10, 10) > 0 && lum(f, 10, 7) > 0)                       // filled
    }

    @Test func keyButtonCutsTheDotOutOfTheFilledDiamond() {
        let t = DrawTheme()
        var c = Canvas(width: 40, height: 20, atlas: nil, scale: 1)
        let s = KeyframeControlState(ring: .onKey, showsNavigation: true, canGoPrevious: true, canGoNext: true,
                                     canToggleKey: true, keyIsOn: true)
        InspectorDraw.navigation(&c, s, in: CGRect(x: 0, y: 0, width: 36, height: 20), enabled: true, behind: .black, t)
        let img = SoftwareRenderer.render(c.list, width: 40, height: 20, clear: .black, atlas: nil)
        func lum(_ x: Int, _ y: Int) -> Int { (0..<3).reduce(0) { $0 + Int(img.pixels[(y * img.width + x) * 4 + $1]) } }
        #expect(lum(18, 10) < lum(18, 7) / 3)   // the dot shows the row, the diamond body is around it
    }

    // MARK: Canvas polygon

    @Test func polygonFillCoversTheInsideOnly() {
        var c = Canvas(width: 20, height: 20, atlas: nil, scale: 1)
        c.fill(polygon: InspectorDraw.diamond(CGPoint(x: 10, y: 10), size: 16), .white)
        let img = SoftwareRenderer.render(c.list, width: 20, height: 20, clear: .black, atlas: nil)
        #expect(red(img, 10, 10) == 255)
        #expect(red(img, 10, 3) == 255)
        #expect(red(img, 3, 3) == 0)        // outside the diamond's corner cut
        #expect(red(img, 17, 17) == 0)
    }

    // MARK: Text editing (IME-free)

    @Test func typingReplacesTheInitialSelection() {
        var e = TextEditState("12.5")
        #expect(e.selection == 0..<4)
        e.handle(.character("4")); e.handle(.character("0"))
        #expect(e.string == "40")
        e.handle(.left); e.handle(.backspace)
        #expect(e.string == "0" && e.caret == 0)
        e.handle(.end); e.handle(.left, modifiers: .shift)
        #expect(e.selection == 0..<1)
        e.handle(.delete)
        #expect(e.string == "")
        #expect(e.handle(.enter) == .commit)
        #expect(e.handle(.escape) == .cancel)
    }

    @Test func commandAAndCommandBackspace() {
        var e = TextEditState("abc", selectAll: false)
        e.handle(.character("a"), modifiers: .command)
        #expect(e.selection == 0..<3)
        e.place(2)
        e.handle(.backspace, modifiers: .command)
        #expect(e.string == "c")
    }

    // MARK: Scrub field (ScrubField rules)

    @Test func dragScrubsWithModifiersAndEndsOnce() {
        var f = ScrubFieldControl(value: 10)
        f.step = 1
        #expect(f.mouseDown(x: 100, clickCount: 1).isEmpty)
        #expect(f.mouseDragged(x: 101, modifiers: []).isEmpty)       // under the 3 px threshold
        let ev = f.mouseDragged(x: 110, modifiers: [])
        #expect(ev.first == .begin)
        let base = f.value
        _ = f.mouseDragged(x: 111, modifiers: .shift)
        #expect(f.value > base)
        #expect(f.mouseUp() == [.end(f.value)])
        #expect(!f.isEditing)
    }

    /// The host pins the pointer while a field scrubs (the Mac ScrubField's pointer lock), from the drag's start to its
    /// end, cancel or focus loss.
    @Test func scrubDragRequestsPointerLockUntilItEnds() {
        let req = HostRequests()
        HostRequests.$current.withValue(req) {
            var f = ScrubFieldControl(value: 10)
            _ = f.mouseDown(x: 100, clickCount: 1)
            _ = f.mouseDragged(x: 101, modifiers: [])
            #expect(!req.pointerLock)                                   // under the threshold: a click so far
            _ = f.mouseDragged(x: 110, modifiers: [])
            #expect(req.pointerLock)
            _ = f.mouseUp()
            #expect(!req.pointerLock)
            _ = f.mouseDown(x: 0, clickCount: 1); _ = f.mouseDragged(x: 20, modifiers: [])
            #expect(req.pointerLock)
            _ = f.key(.escape, modifiers: [], now: 0)
            #expect(!req.pointerLock)
            _ = f.mouseDown(x: 0, clickCount: 1); _ = f.mouseDragged(x: 20, modifiers: [])
            _ = f.resignFocus()
            #expect(!req.pointerLock)
        }
    }

    /// The input method's composition draws inline at the caret (a box from the caret, an underline), only while both exist.
    @Test func compositionDrawsAtTheCaretOnlyWhileComposing() {
        let req = HostRequests()
        var c = Canvas(width: 400, height: 200, atlas: nil, scale: 2)
        req.composition = "ni"
        req.drawComposition(&c, theme: DrawTheme())
        #expect(c.list.quads.isEmpty)                                   // no editor drawn this frame
        req.caret = DrawRect(x: 100, y: 40, w: 0, h: 36)
        req.composition = ""
        req.drawComposition(&c, theme: DrawTheme())
        #expect(c.list.quads.isEmpty)
        req.composition = "ni"
        req.drawComposition(&c, theme: DrawTheme())
        #expect(!c.list.quads.isEmpty)                                 // no atlas here: the box only
        #expect(c.list.quads.first.map { $0.x == 100 && $0.y == 40 && $0.h == 36 } == true)
    }

    /// An open editor reports its caret in device px (IME placement); a selection reports its start.
    @Test func openEditorsReportTheirCaret() {
        let req = HostRequests()
        HostRequests.$current.withValue(req) {
            var c = Canvas(width: 400, height: 200, atlas: nil, scale: 2)
            c.translateBy(x: 10, y: 20)
            var e = TextEditState("ab\ncd", selectAll: false)
            e.place(5)
            InspectorDraw.editLines(&c, e, in: CGRect(x: 0, y: 0, width: 100, height: 60), lineHeight: 20, fontSize: 10,
                                    color: .white, DrawTheme())
            #expect(req.caret.map { $0.y > 40 && $0.x > 20 } == true)           // second line, translated, at 2x
            req.caret = nil
            InspectorDraw.editText(&c, TextEditState("abc", selectAll: true), in: CGRect(x: 0, y: 0, width: 100, height: 20),
                                   fontSize: 10, color: .white, alignRight: false, DrawTheme())
            #expect(req.caret?.x == 20)                                 // selection start: the left edge
        }
    }

    @Test func clickTypesAndEnterCommitsMath() {
        var f = ScrubFieldControl(value: 10)
        _ = f.mouseDown(x: 0, clickCount: 1)
        #expect(f.mouseUp().isEmpty)
        #expect(f.isEditing)
        for ch in "*2" { _ = f.key(.character(ch), modifiers: [], now: 0) }
        // A leading operator applies to the current value (ScrubMath.evaluate).
        #expect(f.key(.enter, modifiers: [], now: 0) == [.begin, .change(20), .end(20)])
        f.beginEditing()
        for ch in "abc" { _ = f.key(.character(ch), modifiers: [], now: 0) }
        #expect(f.key(.enter, modifiers: [], now: 0).isEmpty)       // invalid text keeps the value
        #expect(f.value == 20 && !f.isEditing)
    }

    @Test func escapeReturnsADragToItsStart() {
        var f = ScrubFieldControl(value: 5)
        _ = f.mouseDown(x: 0, clickCount: 1)
        _ = f.mouseDragged(x: 20, modifiers: [])
        #expect(f.value != 5)
        #expect(f.key(.escape, modifiers: [], now: 0) == [.cancel(5)])
        #expect(f.value == 5 && !f.isDragging)
    }

    @Test func doubleClickResetsToTheDefault() {
        var f = ScrubFieldControl(value: 50)
        f.defaultValue = 100
        _ = f.mouseDown(x: 0, clickCount: 1); _ = f.mouseUp()
        #expect(f.isEditing)
        #expect(f.mouseDown(x: 0, clickCount: 2) == [.begin, .change(100), .end(100)])
        #expect(!f.isEditing)
    }

    @Test func arrowBurstIsOneGestureUntilIdle() {
        var f = ScrubFieldControl(value: 0)
        #expect(f.key(.up, modifiers: [], now: 0) == [.begin, .change(1)])
        #expect(f.key(.up, modifiers: .shift, now: 0.1) == [.change(11)])
        #expect(f.tick(now: 0.3).isEmpty)
        #expect(f.tick(now: 0.7) == [.end(11)])
    }

    @Test func optionWheelStepsOnlyWhenHoveredOrFocused() {
        var f = ScrubFieldControl(value: 0)
        #expect(f.scroll(delta: 1, precise: false, modifiers: .option, focused: false, now: 0).used == false)
        f.hovering = true
        let r = f.scroll(delta: 1, precise: false, modifiers: .option, focused: false, now: 0)
        #expect(r.used && r.events == [.begin, .change(1)])
        #expect(f.scroll(delta: 1, precise: false, modifiers: [], focused: false, now: 0).used == false)
    }

    @Test func clickCounterCountsNearbyQuickPresses() {
        var k = ClickCounter()
        #expect(k.press(x: 0, y: 0, now: 0) == 1)
        #expect(k.press(x: 1, y: 1, now: 0.2) == 2)
        #expect(k.press(x: 30, y: 1, now: 0.3) == 1)
        #expect(k.press(x: 30, y: 1, now: 1.5) == 1)
    }

    @Test func sliderFractionInvertsTheKnobPosition() {
        let r = CGRect(x: 0, y: 0, width: 110, height: 20)
        #expect(InspectorDraw.sliderFraction(x: 5, in: r) == 0)
        #expect(InspectorDraw.sliderFraction(x: 55, in: r) == 0.5)
        #expect(InspectorDraw.sliderFraction(x: 200, in: r) == 1)
    }

    @Test func checkboxOnDrawsAccentAndAWhiteCheck() {
        var c = Canvas(width: 20, height: 20, atlas: nil, scale: 1)
        let t = DrawTheme()
        InspectorDraw.checkbox(&c, .on, box: CGRect(x: 3, y: 3, width: 14, height: 14), hovering: false, pressed: false,
                               enabled: true, t)
        let img = SoftwareRenderer.render(c.list, width: 20, height: 20, clear: .black, atlas: nil)
        #expect(img.pixels[(10 * 20 + 4) * 4 + 2] > 100)     // accent (blue) body at the left edge
        #expect(red(img, 0, 0) == 0)
    }
}

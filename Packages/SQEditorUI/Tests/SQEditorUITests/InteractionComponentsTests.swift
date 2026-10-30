import AppKit
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQUIKit

/// WP-A (docs/INTERACTION-AUDIT.md): shared components and their rule behavior.
@MainActor @Suite struct InteractionComponentsTests {
    private func field() -> ScrubField {
        let f = ScrubField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        f.range = 0...100; f.value = 40
        return f
    }

    // MARK: ScrubMath

    @Test func dragModifiers() {
        #expect(ScrubMath.value(start: 10, deltaPixels: 3, step: 1, shift: false, option: false, range: 0...100) == 13)
        #expect(ScrubMath.value(start: 10, deltaPixels: 3, step: 1, shift: true, option: false, range: 0...100) == 40)
        #expect(ScrubMath.value(start: 10, deltaPixels: 3, step: 1, shift: false, option: true, range: 0...100) == 10.3)
        #expect(ScrubMath.value(start: 10, deltaPixels: 30, step: 1, shift: true, option: false, range: 0...100) == 100)
    }

    @Test func wheelGateNeedsOptionAndHoverOrFocus() {
        #expect(!ScrubMath.wheelAccepts(option: false, hovered: true, focused: true))
        #expect(!ScrubMath.wheelAccepts(option: true, hovered: false, focused: false))
        #expect(ScrubMath.wheelAccepts(option: true, hovered: true, focused: false))
        #expect(ScrubMath.wheelAccepts(option: true, hovered: false, focused: true))
    }

    @Test func wheelMultiplierAndValue() {
        #expect(ScrubMath.wheelMultiplier(shift: false, command: false) == 1)
        #expect(ScrubMath.wheelMultiplier(shift: true, command: false) == 10)
        #expect(ScrubMath.wheelMultiplier(shift: false, command: true) == 0.1)
        #expect(ScrubMath.wheelValue(5, notches: 2, step: 1, shift: false, command: false, range: 0...100) == 7)
        #expect(ScrubMath.wheelValue(5, notches: -1, step: 1, shift: true, command: false, range: 0...100) == 0)
        #expect(ScrubMath.wheelValue(5, notches: 3, step: 1, shift: false, command: true, range: 0...100) == 5.3)
    }

    @Test func wheelAccumulatorNotches() {
        var a = ScrubMath.WheelAccumulator()
        #expect(a.add(delta: 1, precise: false) == 1)
        #expect(a.add(delta: -2, precise: false) == -2)
        // Trackpad: 8 pt per notch, remainder kept.
        #expect(a.add(delta: 5, precise: true) == 0)
        #expect(a.add(delta: 5, precise: true) == 1)
        #expect(a.add(delta: 6, precise: true) == 1)
        #expect(ScrubMath.wheelDelta(deltaX: 0, deltaY: 2) == 2)
        #expect(ScrubMath.wheelDelta(deltaX: -3, deltaY: 0) == 3)     // Shift turns a mouse wheel sideways
    }

    @Test func resetTarget() {
        #expect(ScrubMath.resetTarget(current: 40, default: 10, range: 0...100) == 10)
        #expect(ScrubMath.resetTarget(current: 10, default: 10, range: 0...100) == nil)
        #expect(ScrubMath.resetTarget(current: 40, default: 200, range: 0...100) == 100)
        #expect(ScrubMath.resetTarget(current: 40, default: nil, range: 0...100) == nil)
    }

    // MARK: ScrubField gestures

    @Test func escapeCancelsDragBackToStart() {
        let f = field()
        var log: [String] = []
        f.onBegin = { log.append("begin") }
        f.onChange = { log.append("changed \($0)") }
        f.onEnd = { log.append("end \($0)") }
        f.beginDragForTesting()
        f.dragForTesting(pixels: 5)
        #expect(f.value == 45)
        f.cancelGesture()
        #expect(f.value == 40 && !f.isDragging)
        #expect(log == ["begin", "changed 45.0", "changed 40.0", "end 40.0"])
    }

    @Test func escapeCancelUsesOnCancelWhenSet() {
        let f = field()
        var log: [String] = []
        f.onBegin = { log.append("begin") }
        f.onEnd = { log.append("end \($0)") }
        f.onCancel = { log.append("cancel \($0)") }
        f.beginDragForTesting()
        f.dragForTesting(pixels: 3, shift: true)
        #expect(f.value == 70)
        f.cancelGesture()
        #expect(f.value == 40)
        #expect(log == ["begin", "cancel 40.0"])
    }

    @Test func escapeCancelsArrowBurst() {
        let f = field()
        var ends = 0, cancels: [Double] = []
        f.onEnd = { _ in ends += 1 }
        f.onCancel = { cancels.append($0) }
        f.stepForTesting(+1); f.stepForTesting(+1)
        #expect(f.value == 42)
        f.cancelGesture()
        #expect(f.value == 40 && cancels == [40] && ends == 0)
        f.endStepBurst()                 // nothing left open
        #expect(ends == 0)
    }

    @Test func cancelWithoutGestureDoesNothing() {
        let f = field()
        var calls = 0
        f.onBegin = { calls += 1 }; f.onEnd = { _ in calls += 1 }; f.onCancel = { _ in calls += 1 }
        f.cancelGesture()
        #expect(calls == 0 && f.value == 40)
    }

    @Test func wheelNeedsOptionAndIsOneUndoStep() {
        let f = field()
        var log: [String] = []
        f.onBegin = { log.append("begin") }
        f.onChange = { _ in log.append("changed") }
        f.onEnd = { _ in log.append("end") }
        // No Option: the wheel is not ours (the panel scrolls).
        #expect(!f.wheelForTesting(delta: 1, precise: false, option: false, hovered: true))
        #expect(f.value == 40 && log.isEmpty)
        #expect(f.wheelForTesting(delta: 1, precise: false, option: true, hovered: true))
        #expect(f.wheelForTesting(delta: 2, precise: false, option: true, hovered: true, shift: true))
        #expect(f.value == 61)
        f.endStepBurst()
        #expect(log == ["begin", "changed", "changed", "end"])
    }

    @Test func doubleClickResetStillOneTriple() {
        let f = field(); f.defaultValue = 0
        var log: [String] = []
        f.onBegin = { log.append("begin") }
        f.onEnd = { log.append("end \($0)") }
        f.resetToDefault()
        #expect(f.value == 0 && log == ["begin", "end 0.0"])
    }

    // MARK: SQSlider / NumericSlider

    @Test func sliderDragMathWithModifiers() {
        // 100 pt track over 0...1: 10 pt = 0.1, Shift x10, Option x0.1, clamped.
        #expect(abs(SQSlider.dragValue(start: 0.5, deltaX: 10, trackWidth: 100, min: 0, max: 1, shift: false, option: false) - 0.6) < 1e-9)
        #expect(abs(SQSlider.dragValue(start: 0.5, deltaX: 10, trackWidth: 100, min: 0, max: 1, shift: false, option: true) - 0.51) < 1e-9)
        #expect(SQSlider.dragValue(start: 0.5, deltaX: 10, trackWidth: 100, min: 0, max: 1, shift: true, option: false) == 1)
        #expect(SQSlider.dragValue(start: 0.5, deltaX: -100, trackWidth: 100, min: 0, max: 1, shift: false, option: false) == 0)
    }

    @Test func sliderResetIsOneTriple() {
        let s = SQSlider(value: 0.8, minValue: 0, maxValue: 1)
        s.defaultValue = 0.25
        var log: [String] = []
        s.onBegin = { log.append("begin") }
        s.onChange = { log.append("changed \($0)") }
        s.onEnd = { log.append("end \($0)") }
        s.resetToDefault()
        #expect(s.doubleValue == 0.25)
        #expect(log == ["begin", "changed 0.25", "end 0.25"])
        log = []
        s.resetToDefault()
        #expect(log.isEmpty)
    }

    @Test func numericSliderCouplesFieldAndSlider() {
        let n = NumericSlider(value: 50, range: 0...100, defaultValue: 0, step: 1, decimals: 0, unit: "%")
        var ends: [Double] = []
        n.onEnd = { ends.append($0) }
        n.field.onBegin?(); n.field.value = 70; n.field.onChange?(70); n.field.onEnd?(70)
        #expect(n.value == 70 && n.slider.doubleValue == 70 && ends == [70])
        n.slider.resetToDefault()
        #expect(n.value == 0 && n.field.value == 0 && ends == [70, 0])
        n.value = 33
        #expect(n.field.value == 33 && n.slider.doubleValue == 33)
        n.isEnabled = false
        #expect(!n.field.isEnabled && !n.slider.isEnabled)
    }

    // MARK: Keyframe controls

    @Test func keyframeStateMapping() {
        let off = KeyframeControlState.resolve(animated: false, onKey: false, hasPrevious: true, hasNext: true, playheadInRange: true)
        #expect(off == .off && off.ring == .none && !off.showsNavigation)
        let onKey = KeyframeControlState.resolve(animated: true, onKey: true, hasPrevious: false, hasNext: true, playheadInRange: true)
        #expect(onKey.ring == .onKey && onKey.keyIsOn && onKey.showsNavigation)
        #expect(!onKey.canGoPrevious && onKey.canGoNext && onKey.canToggleKey)
        let between = KeyframeControlState.resolve(animated: true, onKey: false, hasPrevious: true, hasNext: false, playheadInRange: false)
        #expect(between.ring == .between && !between.keyIsOn && between.canGoPrevious && !between.canGoNext && !between.canToggleKey)
    }

    @Test func keyframeControlsApplyState() {
        var fired: [String] = []
        let k = KeyframeControls(propertyName: "Scale", onToggleAnimation: { fired.append("anim") },
                                 onPrevious: { fired.append("prev") }, onToggleKey: { fired.append("key") },
                                 onNext: { fired.append("next") })
        #expect(k.navigation.isHidden && k.ring.keyState == .none)
        k.state = .resolve(animated: true, onKey: true, hasPrevious: true, hasNext: false, playheadInRange: true)
        #expect(!k.navigation.isHidden && k.ring.keyState == .onKey)
        #expect(k.navigation.previous.isEnabled && !k.navigation.next.isEnabled && k.navigation.key.isEnabled)
        #expect(k.navigation.key.contentTintColor == Theme.Colors.accent)
        k.navigation.previous.handler?()
        k.navigation.key.handler?()
        _ = k.ring.accessibilityPerformPress()
        #expect(fired == ["prev", "key", "anim"])
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        k.install(in: row)
        k.layout(rowBounds: row.bounds)
        #expect(k.ring.frame.minX == ControlsGrid.toggleX)
        #expect(k.navigation.frame.maxX == 300 - Theme.Inspector.trailing)
        #expect(k.navigation.frame.width == KeyframeNavigationView.width)
    }

    // MARK: Tooltips

    @Test func tooltipFormatting() {
        #expect(Tooltip.text("Mark In", shortcut: "I") == "Mark In (I)")
        #expect(Tooltip.text("Snap", shortcut: nil) == "Snap")
        #expect(Tooltip.text("  Snap  ", shortcut: "") == "Snap")
        #expect(Tooltip.text("Reset the value.", shortcut: "⌥R") == "Reset the value (⌥R)")
        #expect(Tooltip.text("Undo", binding: KeyBinding(.char("z"), [.command])) == "Undo (⌘Z)")
        #expect(Tooltip.text("Nothing", binding: nil) == "Nothing")
    }

    @Test func tooltipFromCommandMatchesKeyboardListing() {
        let map = CommandMap.current
        #expect(Tooltip.text("Mark In", command: .markIn, map: map) == KeyboardListing.tip("Mark In", .markIn, map: map))
    }

    // MARK: Tokens

    @Test func motionTokens() {
        #expect(Theme.Motion.fast < Theme.Motion.standard && Theme.Motion.standard < Theme.Motion.slow)
        #expect(ZoomAnimation.duration == Theme.Motion.fast)
        for c in [Theme.Motion.Curve.linear, .easeOut, .easeInOut] {
            #expect(c.value(0) == 0 && c.value(1) == 1)
            var last = -1.0
            for i in 0...20 { let v = c.value(Double(i) / 20); #expect(v >= last); last = v }
        }
        #expect(ZoomAnimation.ease(0.3) == Theme.Motion.Curve.easeOut.value(0.3))
        #expect(Theme.Motion.duration(0.2, reduceMotion: true) == 0)
        #expect(Theme.Motion.duration(0.2, reduceMotion: false) == 0.2)
    }

    @Test func selectionIsNeutral() {
        #expect(Theme.Selection.fill != Theme.Colors.accentTint)
        #expect(Theme.Selection.fillFocused != Theme.Colors.accentTint)
        #expect(Theme.Selection.fill != Theme.Selection.fillFocused)
        let r = FlatSelectionRowView()
        #expect(r.selectionFill(focused: false) == Theme.Selection.fill)
        #expect(r.selectionFill(focused: true) == Theme.Selection.fillFocused)
    }

    // MARK: Icon button, empty state, inspector, divider

    @Test func iconButtonStates() {
        var hits = 0
        let b = IconButton(symbol: .chevronLeft, label: "Previous Keyframe") { hits += 1 }
        // No NSApp under swift test, so sendAction cannot dispatch: check the wiring, run the handler.
        #expect(b.action != nil && b.target === b)
        b.handler?()
        #expect(hits == 1)
        #expect(b.toolTip == "Previous Keyframe")
        #expect(b.fillColor == nil)                         // rest: no fill
        b.setHoveredForTesting(true)
        #expect(b.fillColor == nil && b.foreground == Theme.Colors.label)   // hover: glyph only, no fill
        b.setHoveredForTesting(false)
        b.isSelected = true
        #expect(b.fillColor == nil && b.foreground == Theme.Colors.accent)
        b.fillsWhenSelected = true
        #expect(b.fillColor == Theme.Selection.fill)
        b.fillsWhenSelected = false
        b.isSelected = false
        b.isEnabled = false
        #expect(b.fillColor == nil)
        #expect(b.foreground.alphaComponent < Theme.Colors.label2.alphaComponent)
        let legacy: ClosureButton = ClosureButton(keyDiamondLabel: "Key") {}
        #expect(legacy is IconButton)
    }

    @Test func emptyStateTexts() {
        let e = EmptyStateView(title: "No markers", hint: "Press M to add one")
        #expect(e.titleLabel.stringValue == "No markers" && e.hintLabel.stringValue == "Press M to add one")
        #expect(!e.hintLabel.isHidden)
        e.hint = nil
        #expect(e.hintLabel.isHidden)
    }

    @Test func inspectorSectionTogglesAndPersists() {
        let key = "wpaTest.\(UUID().uuidString)"
        let s = InspectorSection(title: "Motion", key: key, defaultOpen: true)
        #expect(s.isExpanded && !s.body.isHidden)
        var toggles: [Bool] = []
        s.header.onToggleExpanded = { toggles.append($0) }
        s.header.toggleExpanded()
        #expect(!s.isExpanded && s.body.isHidden && toggles == [false])
        #expect(UserDefaults.standard.object(forKey: InspectorSection.defaultsKey(key)) as? Bool == false)
        UserDefaults.standard.removeObject(forKey: InspectorSection.defaultsKey(key))
    }

    @Test func inspectorRowGeometry() {
        let control = ScrubField()
        let k = KeyframeControls(propertyName: "Scale", onToggleAnimation: {}, onPrevious: {}, onToggleKey: {}, onNext: {})
        let row = InspectorRow(title: "Scale", control: control, controlWidth: 64, keyframes: k)
        row.frame = NSRect(x: 0, y: 0, width: 320, height: Theme.Inspector.rowHeight)
        row.layoutSubtreeIfNeeded(); row.layout()
        #expect(row.nameLabel.frame.minX == ControlsGrid.labelX)
        #expect(control.frame.minX == ControlsGrid.valueX && control.frame.width == ControlsGrid.valueWidth)
        #expect(k.ring.frame.minX == ControlsGrid.toggleX)
        #expect(row.backgroundFill == nil)
        row.isSelected = true
        #expect(row.backgroundFill == Theme.Selection.fill)
    }

    @Test func dividerIsOnePoint() {
        let h = SQDivider(orientation: .horizontal), v = SQDivider(orientation: .vertical, style: .pane)
        #expect(h.intrinsicContentSize.height == Theme.Separator.width)
        #expect(v.intrinsicContentSize.width == Theme.Separator.width)
        #expect(h.color == Theme.Separator.hairline && v.color == Theme.Separator.divider)
    }
}

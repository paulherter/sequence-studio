import AppKit
import Testing
import SQCore
import SQTimelineUI
@testable import SQInspectorUI

@MainActor @Suite struct EffectControlsViewTests {
    func setup(kind: TrackKind = .video) -> (EffectControlsModel, EffectControlsView) {
        let m = EffectControlsModel()
        m.setClip(Clip(name: "c", media: UUID(), kind: kind,
                       source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1)))
        m.playhead = Time(5, 1)
        let v = EffectControlsView(model: m)
        v.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        v.layoutSubtreeIfNeeded()
        return (m, v)
    }

    func scrubFields(_ v: NSView) -> [ScrubField] {
        var out: [ScrubField] = []
        func walk(_ n: NSView) { for s in n.subviews { if let f = s as? ScrubField { out.append(f) }; walk(s) } }
        walk(v); return out
    }

    @Test func videoClipShowsMotionAndOpacityFields() {
        let (_, v) = setup()
        // position 2, scale 1, rotation 1, anchor 2, opacity 1, shutter angle 1, crop left / right / top / bottom / softness 5
        // (effects only once applied)
        // plus tilt X / Y (2), Anti-flicker Filter (1)
        #expect(scrubFields(v).count == 16)
    }

    @Test func audioClipShowsOnlyVolume() {
        let (_, v) = setup(kind: .audio)
        #expect(scrubFields(v).count == 1)
    }

    @Test func fieldEditGoesThroughModelAsOneGesture() {
        let (m, v) = setup()
        var log: [(String, Bool)] = []
        m.onEdit = { _, n, c in log.append((n, c)) }
        let rotation = scrubFields(v)[3]        // position x, y, scale, rotation ...
        #expect(rotation.accessibilityLabel() == "Rotation")
        rotation.onBegin?(); rotation.onChange?(10); rotation.onChange?(20); rotation.onEnd?(20)
        #expect(m.clip!.animation.rotation.value == -20)      // shown counterclockwise, stored clockwise
        #expect(log.map(\.1) == [false, true])
    }

    func diamonds(_ v: NSView) -> [AnimateDiamondView] {
        var out: [AnimateDiamondView] = []
        func walk(_ n: NSView) { for s in n.subviews { if let f = s as? AnimateDiamondView { out.append(f) }; walk(s) } }
        walk(v); return out
    }

    // Every animatable row has exactly one animate diamond, in the grid's toggle column.
    @Test func everyAnimatableRowHasOneDiamondInItsSlot() {
        let (_, v) = setup()
        let r = diamonds(v)
        #expect(r.count == 14)     // position, scale, rotation, tilt X / Y, anchor, opacity, shutter angle, anti-flicker, 5 crop rows
        #expect(r.allSatisfy { $0.frame.midX == ControlsGrid.toggleMidX && $0.frame.width == ControlsGrid.toggleWidth }, "\(r.map(\.frame))")
    }

    // The switch: off -> on sets the first key; on -> off asks, then removes every key in one undo step and keeps the value.
    @Test func animationSwitchSetsFirstKeyThenAsksBeforeRemovingAll() {
        let (m, v) = setup()
        let opacity = diamonds(v).first { $0.accessibilityLabel()?.contains("Opacity") == true }!
        opacity.onClick?()
        #expect(m.isAnimated(.opacity) && m.track(.opacity)?.keyIDs.count == 1)
        _ = m.toggleKeyAtPlayhead(.opacity)                       // on a key: removes it again, still no second key by the switch
        opacity.onClick?()                                         // not animated any more: first key again
        #expect(m.track(.opacity)?.keyIDs.count == 1)
        let shown = m.scalarValue(.opacity)
        var asked = 0
        v.confirmRemoval = { _ in asked += 1; return false }
        opacity.onClick?()
        #expect(asked == 1 && m.track(.opacity)?.keyIDs.count == 1)     // declined: nothing changed
        v.confirmRemoval = { _ in asked += 1; return true }
        opacity.onClick?()
        #expect(asked == 2 && !m.isAnimated(.opacity) && m.scalarValue(.opacity) == shown)
    }

    // v9 clip line: name, then sequence, track and the clip's range.
    @Test func clipLineShowsNameThenSequenceTrackAndRange() {
        let (_, v) = setup()
        #expect(v.clipNameLabel.stringValue == "c")
        #expect(v.clipInfoLabel.stringValue.contains(" \u{2013} "))
        #expect(EffectControlsView.clipInfo(kind: .audio, duration: Time(1, 1), frameDuration: Time(1, 25)).hasPrefix("Audio"))
        let meta = EffectControlsView.clipMeta(sequence: "Main", track: "V1", start: Time(15, 1), end: Time(17, 1), frameDuration: Time(1, 25))
        #expect(meta == "Main \u{00B7} V1 \u{00B7} 00:00:15:00 \u{2013} 00:00:17:00")
        let text = EffectControlsView.clipMeta(sequence: nil, track: nil, start: .zero, end: Time(1, 1), frameDuration: Time(1, 25), kindName: "Text")
        #expect(text == "Text \u{00B7} 00:00:00:00 \u{2013} 00:00:01:00")
    }

    @Test func miniRulerLabelsDropLeadingZeroGroups() {
        #expect(KeyframeRulerView.shortLabel("00:00:15:00") == "15:00")
        #expect(KeyframeRulerView.shortLabel("00:01:05:12") == "1:05:12")
        #expect(KeyframeRulerView.shortLabel("00:00:00:00") == "00:00")
    }

    @Test func emptyStateNamesControls() {
        let v = EffectControlsView(model: EffectControlsModel())
        #expect(v.emptyState.title == "No clip selected")
        #expect(v.emptyState.hint == "Select a clip in the timeline to see its Controls.")
    }

    @Test func closedSpeedSectionSaysDirection() {
        let (m, _) = setup()
        m.collapsedSections.insert(.speed)
        #expect(m.sectionSummary(.speed) == "100 % \u{00B7} Forward")
    }

    // The zoom bar stays visible with a clip, also fully zoomed out.
    @Test func zoomBarStaysVisibleFullyZoomedOut() {
        let (m, v) = setup()
        #expect(v.showsZoomBar)
        m.zoom(by: 4, around: 0.5)
        #expect(v.showsZoomBar)
    }

    // Nothing may move on hover: the eye and reset slots are reserved, so the frames of every element are identical.
    @Test func hoverMovesNothingInHeaderAndPropertyRows() async {
        let (m, v) = setup()
        func frames(_ row: NSView) -> [NSRect] { row.subviews.map(\.frame) }
        for collapsed in [false, true] {
            m.collapsedSections = collapsed ? [.motion] : []
            try? await Task.sleep(for: .milliseconds(50))
            v.layoutSubtreeIfNeeded()
            let headers = v.allSubviews(of: SectionHeaderRow.self)
            #expect(!headers.isEmpty)
            for h in headers {
                let before = frames(h), probe = h.rowProbe.tail
                h.isHovering = true; h.layoutSubtreeIfNeeded()
                #expect(frames(h) == before)
                #expect(h.rowProbe.tail == probe)
                h.isHovering = false; h.layoutSubtreeIfNeeded()
                #expect(frames(h) == before)
            }
        }
        m.collapsedSections = []
        try? await Task.sleep(for: .milliseconds(50))
        v.layoutSubtreeIfNeeded()
        for r in v.allSubviews(of: PropertyRow.self) {
            let before = frames(r)
            if let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                r.mouseEntered(with: enter)
            }
            r.layoutSubtreeIfNeeded()
            #expect(frames(r) == before)
        }
    }

    // The playhead line has one thickness over every row; the Controls ruler carries the timeline's head.
    @Test func playheadLineIsTwoPointsEverywhere() {
        #expect(PlayheadLineView.frame(centerX: 100.4, height: 50) == NSRect(x: 99, y: 0, width: 2, height: 50))
        #expect(PlayheadHeadView.size == Theme.PlayheadSkin.headSize)
        #expect(Theme.PlayheadSkin.headPath(centerX: 6).boundingBox.width == 12)
    }

    // An opened curve closes itself once fewer than two keys are left (the arrow is gone with the keys).
    @Test func openedCurveClosesWhenKeysDropBelowTwo() {
        let (m, _) = setup()
        _ = m.toggleStopwatch(.opacity)
        m.playhead = Time(6, 1)
        _ = m.toggleKeyAtPlayhead(.opacity)
        m.toggleOpen(.opacity)
        #expect(m.expanded.contains(.opacity))
        _ = m.toggleKeyAtPlayhead(.opacity)                      // removes the second key: one left, no curve
        #expect(!m.expanded.contains(.opacity))
    }

    // Every parameter row carries its own reset in the fixed trailing slot, dimmed at the default.
    @Test func propertyRowResetSlotIsAlwaysThereAndDimsAtDefault() {
        let (m, v) = setup()
        let row = v.allSubviews(of: PropertyRow.self).first { $0.property == .rotation }!
        let reset = row.keyframes.reset!
        #expect(reset.superview === row)
        #expect(reset.frame == ControlsGrid(width: row.bounds.width).resetFrame(height: row.bounds.height))
        #expect(!reset.isEnabled)
        m.setValue(.rotation, component: .all, to: 30)
        row.update()
        #expect(reset.isEnabled)
        reset.handler?()
        #expect(m.isDefault(.rotation))
    }

    @Test func sectionRowHasEyeSummaryAndCollapsesOnChevron() async {
        let (m, v) = setup()
        var headers: [SectionHeaderRow] = []
        func walk(_ n: NSView) { for s in n.subviews { if let f = s as? SectionHeaderRow { headers.append(f) }; walk(s) } }
        walk(v)
        let motion = headers.first { $0.section == .motion }!
        #expect(motion.frame.height == ControlsMetrics.section)
        #expect(motion.chevron.frame.minX == ControlsMetrics.sectionLeading)
        motion.toggleCollapsed()
        #expect(m.collapsedSections.contains(.motion))
        #expect(m.sectionSummary(.motion) != nil)      // a closed section still says what it does
        motion.toggleCollapsed()
        #expect(!m.collapsedSections.contains(.motion) && m.sectionSummary(.motion) == nil)
    }

    // The header value belongs to the rebuilt structure: a model change alone must not show or hide it ahead of the body rows.
    @Test func headerValueFollowsTheBuiltStructureNotTheLiveModel() async {
        let (m, v) = setup()
        func motionHeader() -> SectionHeaderRow? {
            var found: SectionHeaderRow?
            func walk(_ n: NSView) { for s in n.subviews { if let f = s as? SectionHeaderRow, f.section == .motion { found = f }; walk(s) } }
            walk(v); return found
        }
        let open = motionHeader()!
        #expect(open.summary.stringValue.isEmpty)
        m.collapsedSections = [.motion]          // model flips; the rows are not rebuilt yet
        open.update()
        #expect(open.summary.stringValue.isEmpty && !open.builtCollapsed)
        try? await Task.sleep(for: .milliseconds(50))
        v.layoutSubtreeIfNeeded()
        let closed = motionHeader()!
        #expect(closed.builtCollapsed && !closed.summary.stringValue.isEmpty)
        m.collapsedSections = []
        closed.update()
        #expect(!closed.summary.stringValue.isEmpty)    // still the old structure until the rebuild
        try? await Task.sleep(for: .milliseconds(50))
        #expect(motionHeader()!.summary.stringValue.isEmpty)
    }

    @Test func openedRowShowsSpeedGraphAndEasePane() async {
        let (m, v) = setup()
        m.toggleStopwatch(.opacity)
        m.toggleOpen(.opacity)
        try? await Task.sleep(for: .milliseconds(50))
        v.layoutSubtreeIfNeeded()
        let row = v.firstSubview(of: SpeedGraphRow.self)!
        #expect(row.frame.height == 120)
        #expect(!row.speedGraph.isHidden && row.speedGraph.frame.minX == row.pane.frame.maxX)
        m.graphMode = .value
        row.update()
        #expect(row.speedGraph.isHidden)
    }

    @Test func collapsedSectionAddsNoRowsAndExpandAddsGraph() async {
        let (m, v) = setup()
        m.collapsedSections = [.motion]
        try? await Task.sleep(for: .milliseconds(50))    // observation re-arms on the main actor
        v.layoutSubtreeIfNeeded()
        #expect(scrubFields(v).count == 0)      // Opacity is inside Motion, so nothing is left
        m.collapsedSections = []; m.expanded = [.opacity]
        try? await Task.sleep(for: .milliseconds(50))
        var graphs = 0
        func walk(_ n: NSView) { for s in n.subviews { if s is KeyframeGraphView { graphs += 1 }; walk(s) } }
        walk(v)
        #expect(graphs == 1)
    }

    @Test func laneHitTestFindsKeys() async {
        let (m, v) = setup()
        m.toggleStopwatch(.opacity)
        try? await Task.sleep(for: .milliseconds(50))
        v.layoutSubtreeIfNeeded()
        let lanes = v.firstSubview(of: EffectKeyframeLanesView.self)!
        let row = lanes.rows.first { $0.kind == .property(.opacity) }!
        let x = lanes.geometry.x(for: .zero)
        if case .key(.opacity, _, _) = lanes.hit(at: CGPoint(x: x, y: row.y + 10)) {} else { Issue.record("no key hit") }
        #expect(lanes.hit(at: CGPoint(x: x + 50, y: row.y + 10)) == .none)
    }

    @Test func collapsedSectionHitsSummaryKey() async {
        let (m, v) = setup()
        m.toggleStopwatch(.rotation)
        m.collapsedSections = [.motion]
        try? await Task.sleep(for: .milliseconds(50))
        v.layoutSubtreeIfNeeded()
        let lanes = v.firstSubview(of: EffectKeyframeLanesView.self)!
        let row = lanes.rows.first { $0.kind == .section(.motion) }!
        let x = lanes.geometry.x(for: .zero)
        #expect(lanes.hit(at: CGPoint(x: x, y: row.y + 10)) == .summary(.motion, .zero))
    }
}

extension NSView {
    func allSubviews<T: NSView>(of t: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.allSubviews(of: t) }
    }
    func firstSubview<T: NSView>(of t: T.Type) -> T? {
        for s in subviews { if let m = s as? T { return m }; if let m = s.firstSubview(of: t) { return m } }
        return nil
    }
}

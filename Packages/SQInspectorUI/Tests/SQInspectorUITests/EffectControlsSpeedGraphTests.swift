import AppKit
import Testing
import SQCore
@testable import SQInspectorUI

/// The opened keyframe row (variant A): geometry of the inline speed graph and the model edits behind its chips,
/// fields and handles.
@MainActor @Suite struct EffectControlsSpeedGraphTests {
    func segment(_ shape: EaseShape) -> EaseTrackSegment {
        EaseTrackSegment(from: UUID(), to: UUID(), start: Time(2, 1), end: Time(6, 1), shape: shape)
    }
    /// 10 s over 420 pt with a 10 pt inset: 40 pt per second.
    var geometry: SpeedGraphGeometry { SpeedGraphGeometry(lane: KeyframeLaneGeometry(width: 420, duration: Time(10, 1))) }

    // MARK: Geometry

    func scaled(_ shape: EaseShape, _ scale: Double) -> EaseTrackSegment { var s = segment(shape); s.scale = scale; return s }

    @Test func equalValueSegmentIsAFlatLineAtZero() {
        let flat = scaled(SpeedCurveChip.smooth.shape, 0), real = scaled(SpeedCurveChip.smooth.shape, 1)
        let g = SpeedGraphGeometry(lane: geometry.lane, peak: SpeedGraphGeometry.peak(of: [flat, real]))
        #expect(g.points(flat).allSatisfy { abs($0.y - g.baseline) < 1e-9 })
        #expect(g.points(real).map(\.y).min()! < g.baseline - 10)
    }

    @Test func curveHeightScalesWithTheValueChangeOnOneSharedScale() {
        let half = scaled(SpeedCurveChip.smooth.shape, 0.5), full = scaled(SpeedCurveChip.smooth.shape, 1)
        let g = SpeedGraphGeometry(lane: geometry.lane, peak: SpeedGraphGeometry.peak(of: [half, full]))
        let hHalf = g.baseline - g.points(half).map(\.y).min()!, hFull = g.baseline - g.points(full).map(\.y).min()!
        #expect(abs(hFull - 2 * hHalf) < 1e-6)
    }

    @Test func baselineAndSteadyLine() {
        let g = geometry
        #expect(g.baseline == 98)                       // 22 pt above the bottom edge of the 120 pt row
        #expect(g.y(speed: 0) == 98 && g.y(speed: 1) == 58)   // 40 pt per 1.0x
    }

    @Test func keysSitAtTheirSpeed() {
        let g = geometry
        let smooth = segment(SpeedCurveChip.smooth.shape), steady = segment(.linear)
        #expect(g.key(smooth, side: .out) == CGPoint(x: 90, y: g.baseline))     // eased key: speed 0 = baseline
        #expect(g.key(smooth, side: .in) == CGPoint(x: 250, y: g.baseline))
        #expect(abs(g.key(steady, side: .out).y - g.y(speed: 1)) < 0.01)        // steady key: on the 1.0x line
    }

    /// Regression guard (feedback 2026-10-04/05/06): a handle at 100 % influence reaches the middle of its
    /// segment, never the neighboring key. History: reach x full segment width (commit 75abe911) meant dragging all the
    /// way to the other key; one third (26b37a06) stopped 10-20 % short of Premiere. Every graph shares
    /// `HandleReach.fullInfluence`.
    @Test func fullInfluenceSitsAtTheMiddleOfTheSegment() {
        #expect(HandleReach.fullInfluence == 0.5)
        #expect(GraphMath.handleReach == HandleReach.fullInfluence)
        let g = geometry
        let s = segment(SpeedCurveChip.smooth.shape.settingReach(1, side: .both))
        #expect(abs(g.handleSpan(s) - g.width(s) / 2) < 1e-9)
        let k = g.key(s, side: .out), h = g.handleEnd(s, side: .out)
        #expect(abs((h.x - k.x) - g.width(s) / 2) < 1e-9)
        let kin = g.key(s, side: .in), hin = g.handleEnd(s, side: .in)
        #expect(abs((kin.x - hin.x) - g.width(s) / 2) < 1e-9)
        #expect(h.x <= hin.x + 1e-9)                          // two full handles meet in the middle, never cross
        #expect(h.x < kin.x - 20 && hin.x > k.x + 20)         // and never touch the neighboring key
    }

    /// Both handles pulled to the middle as far as they go (feedback 2026-10-06: "the curve is just a stroke"): a sharp
    /// peak with clean flanks that runs off the top of the plot, on a scale that keeps the Steady line readable.
    @Test func bothHandlesAtFullInfluenceDrawASharpPeakNotAStroke() {
        let s = segment(SpeedCurveChip.smooth.shape.settingReach(1, side: .both))
        let g = SpeedGraphGeometry(lane: geometry.lane, peak: SpeedGraphGeometry.peak(of: [s]))
        #expect(g.unitHeight >= (g.baseline - SpeedGraphGeometry.topInset) / CGFloat(SpeedGraphGeometry.peakCap) - 1e-9)
        #expect(g.baseline - g.y(speed: 1) >= 20)             // the Steady line is not squashed onto the baseline
        let pts = g.points(s), mid = g.x(s, share: 0.5)
        #expect(pts.map(\.y).min()! < 0)                      // the tip leaves the plot (clipped when drawn)
        #expect(pts.filter { abs($0.x - mid) < 3 }.allSatisfy { $0.y < g.y(speed: 1) })   // no dive to the baseline at the tip
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $0.x <= $1.x + 1e-9 })
        // Flanks: rising to the middle, falling after it.
        let left = pts.filter { $0.x < mid - 3 }, right = pts.filter { $0.x > mid + 3 }
        #expect(zip(left, left.dropFirst()).allSatisfy { $1.y <= $0.y + 1e-9 })
        #expect(zip(right, right.dropFirst()).allSatisfy { $1.y >= $0.y - 1e-9 })
        // Half way (50 % each) it is a plain hill of twice the steady speed that fits.
        let half = segment(SpeedCurveChip.smooth.shape.settingReach(0.5, side: .both))
        let gh = SpeedGraphGeometry(lane: geometry.lane, peak: SpeedGraphGeometry.peak(of: [half]))
        #expect(abs(gh.points(half).map(\.y).min()! - gh.y(speed: 2)) < 0.01 && gh.y(speed: 2) >= SpeedGraphGeometry.topInset - 0.01)
    }

    @Test func handleIsHorizontalAndInfluenceTimesHalfTheSegmentLong() {
        let g = geometry
        let s = segment(SpeedCurveChip.smooth.shape.settingReach(0.75, side: .out))
        let k = g.key(s, side: .out), h = g.handleEnd(s, side: .out)
        #expect(h.y == k.y)
        #expect(abs((h.x - k.x) - 0.75 * g.width(s) / 2) < 1e-9)
        let kin = g.key(s, side: .in), hin = g.handleEnd(s, side: .in)
        #expect(hin.y == kin.y && hin.x < kin.x)
    }

    @Test func influenceFromXClampsToZeroAndFull() {
        let g = geometry
        let s = segment(SpeedCurveChip.smooth.shape)
        let k = g.key(s, side: .out), span = g.handleSpan(s)
        #expect(g.reach(atX: k.x + span, s, side: .out) == 1)               // the far end of the reach: exactly 100 %
        #expect(abs(g.reach(atX: k.x + span * 0.5, s, side: .out) - 0.5) < 1e-12)
        #expect(g.reach(atX: k.x + 3 * span, s, side: .out) == 1)           // past the stop (even past the other key)
        #expect(g.reach(atX: k.x - 50, s, side: .out) == 0)
        let kin = g.key(s, side: .in)
        #expect(abs(g.reach(atX: kin.x - span * 0.25, s, side: .in) - 0.25) < 1e-12)
        #expect(g.reach(atX: kin.x - 10 * span, s, side: .in) == 1)
    }

    @Test func handleRoundTripsBetweenInfluenceAndView() {
        let g = geometry
        for r in [0.05, 0.2, 1.0 / 3, 0.5, 0.9, 1.0] {
            for side in [EaseSide.out, .in] {
                let s = segment(SpeedCurveChip.smooth.shape.settingReach(r, side: side))
                let e = g.handleTrueEnd(s, side: side)
                #expect(abs(g.reach(atX: e.x, s, side: side) - r) < 1e-9)
            }
        }
    }

    @Test func shortHandleIsDrawnAtLeastAMinimumFromItsKey() {
        let g = geometry
        let s = segment(SpeedCurveChip.smooth.shape.settingReach(0.02, side: .out))
        let k = g.key(s, side: .out)
        #expect(g.handleEnd(s, side: .out).x - k.x >= SpeedGraphGeometry.minHandleLength - 1e-9)
        #expect(g.handleTrueEnd(s, side: .out).x - k.x < 2)
    }

    // MARK: Hit testing and marquee

    /// Smooth segment 2 s...6 s (x 90...250), both handles at 100 %; with `selected` both keys are selected.
    func hitRows(selected: Bool = true, reach: Double = 1) -> ([[EaseTrackSegment]], [Set<UUID>]) {
        let s = segment(SpeedCurveChip.smooth.shape.settingReach(reach, side: .both))
        return ([[s]], [selected ? [s.from, s.to] : []])
    }

    @Test func hitPriorityHandleKeyCurveEmpty() {
        let (rows, sel) = hitRows()
        let g = SpeedGraphGeometry(lane: geometry.lane, peak: SpeedGraphGeometry.peak(of: rows[0]))
        let s = rows[0][0]
        let h = g.handleEnd(s, side: .out), k = g.key(s, side: .out)
        #expect(g.hitTest(h, rows: rows, selected: sel) == .handle(row: 0, segment: 0, side: .out))
        #expect(g.hitTest(k, rows: rows, selected: sel) == .key(row: 0, id: s.from))
        #expect(g.hitTest(g.key(s, side: .in), rows: rows, selected: sel) == .key(row: 0, id: s.to))
        let mid = g.points(s)[24]
        #expect(g.hitTest(mid, rows: rows, selected: sel) == .curve(row: 0, segment: 0))
        #expect(g.hitTest(CGPoint(x: mid.x, y: 4), rows: rows, selected: sel) == .empty)
        // Handles of unselected keys are not shown and not hit.
        let (_, none) = hitRows(selected: false)
        #expect(g.hitTest(h, rows: rows, selected: none) != .handle(row: 0, segment: 0, side: .out))
    }

    @Test func handleWinsOverAKeyRightUnderIt() {
        let g = geometry
        let s = segment(SpeedCurveChip.smooth.shape.settingReach(0.01, side: .out))
        let e = g.handleEnd(s, side: .out)
        #expect(g.hitTest(e, rows: [[s]], selected: [[s.from, s.to]]) == .handle(row: 0, segment: 0, side: .out))
    }

    @Test func marqueeSelectsKeysAndKeysOfHandlesInside() {
        let g = geometry
        let (rows, sel) = hitRows(reach: 0.6)       // at 100 % the two handle ends meet in the middle
        let s = rows[0][0]
        let k = g.key(s, side: .out), h = g.handleEnd(s, side: .out)
        #expect(g.keys(in: CGRect(x: k.x - 4, y: k.y - 4, width: 8, height: 8), rows: rows, selected: sel) == [0: [s.from]])
        // Around the right key's handle only: picks that key.
        let hin = g.handleEnd(s, side: .in)
        #expect(g.keys(in: CGRect(x: hin.x - 3, y: hin.y - 3, width: 6, height: 6), rows: rows, selected: sel) == [0: [s.to]])
        #expect(g.keys(in: CGRect(x: 0, y: 0, width: 420, height: 120), rows: rows, selected: sel) == [0: [s.from, s.to]])
        #expect(g.keys(in: CGRect(x: h.x + 5, y: 2, width: 4, height: 4), rows: rows, selected: sel).isEmpty)
    }

    @Test func hillOfTwoEasedKeysStartsAndEndsOnTheBaselineAndPeaksAboveSteady() {
        let g = geometry
        let pts = g.points(segment(SpeedCurveChip.smooth.shape))
        #expect(abs(pts.first!.y - g.baseline) < 0.5 && abs(pts.last!.y - g.baseline) < 0.5)
        #expect(pts.map(\.y).min()! < g.y(speed: 1))    // flipped: above the Steady line
    }

    @Test func tallHillShrinksTheUnitSoItFits() {
        let sharp = segment(EaseShape.linear.settingSpeed(4, side: .out))     // leaves the key at 4.0x: taller than the plot
        let g = SpeedGraphGeometry(lane: geometry.lane, peak: SpeedGraphGeometry.peak(of: [sharp]))
        #expect(g.unitHeight < SpeedGraphGeometry.unit)
        #expect(g.points(sharp).allSatisfy { $0.y >= 2 })
    }

    // MARK: Chips

    @Test func chipReadsTheShapeWhateverTheReach() {
        // A shape cannot say Hold Ahead: it reads as Hold, the model tells them apart by the key (`speedChip(for:)`).
        for c in SpeedCurveChip.allCases { #expect(SpeedCurveChip.chip(for: c.shape) == (c == .holdAhead ? .hold : c)) }
        #expect(SpeedCurveChip.chip(for: SpeedCurveChip.smooth.shape.settingReach(0.6, side: .out)) == .smooth)
        #expect(SpeedCurveChip.chip(for: SpeedCurveChip.smooth.shape.settingSpeed(0.5, side: .out)) == nil)
        #expect(SpeedCurveChip.allCases.map(\.title) == ["Steady", "Smooth", "Smooth In", "Smooth Out", "Hold", "Hold Ahead"])
    }

    // MARK: Model

    /// Opacity keyed at 0 s and 2 s (clip-local).
    func model() -> EffectControlsModel {
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(Clip(name: "c", media: UUID(), kind: .video,
                       source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1)))
        m.playhead = Time(5, 1)
        m.toggleStopwatch(.opacity)
        m.playhead = Time(7, 1)
        m.setValue(.opacity, to: 0.5)
        return m
    }

    @Test func openingSelectsTheRowsKeysAndClosingKeepsThem() {
        let m = model()
        m.setSelection(for: .opacity, ids: [])
        m.toggleOpen(.opacity)
        #expect(m.expanded.contains(.opacity))
        #expect(m.selectedKeyIDs(.opacity).count == 2)
        m.toggleOpen(.opacity)
        #expect(!m.expanded.contains(.opacity))
    }

    @Test func chipSetsTheSelectedSegment() {
        let m = model()
        m.toggleOpen(.opacity)
        m.applySpeedChip(.smooth, for: .opacity)
        #expect(m.speedChip(for: .opacity) == .smooth)
        let seg = m.speedSegments(.opacity)
        #expect(seg.count == 1 && abs(seg[0].shape.speedOut) < 0.01 && abs(seg[0].shape.speedIn) < 0.01)
        m.applySpeedChip(.hold, for: .opacity)
        #expect(m.speedChip(for: .opacity) == .hold)
    }

    // MARK: Hold Ahead: its own chip and menu entry, and a toggle that remembers

    private func kinds(_ m: EffectControlsModel) -> [Interpolation] {
        guard case .scalar(let t) = m.track(.opacity) else { return [] }
        return t.keys.map(\.interpolation)
    }

    @Test func holdAheadChipIsItsOwnAndConvertsBothWays() {
        let m = model()
        m.toggleOpen(.opacity)
        m.applySpeedChip(.holdAhead, for: .opacity)
        #expect(kinds(m).first == .holdAhead && m.speedChip(for: .opacity) == .holdAhead)
        let g = InlineSpeedGraphView(property: .opacity, model: m)
        var items = g.curveMenuItems()
        #expect(items.filter(\.isChecked).map(\.title) == ["Hold Ahead"])
        #expect(items.firstIndex { $0.title == "Hold Ahead" } == items.firstIndex { $0.title == "Hold" }.map { $0 + 1 })
        m.applySpeedChip(.hold, for: .opacity)
        #expect(kinds(m).first == .hold && m.speedChip(for: .opacity) == .hold)
        items = g.curveMenuItems()
        items.first { $0.title == "Hold Ahead" }?.action?()
        #expect(kinds(m).first == .holdAhead)
        m.applySpeedChip(.smooth, for: .opacity)
        #expect(m.speedChip(for: .opacity) == .smooth && kinds(m).first == .bezier)
    }

    @Test func keyMenuListsHoldAheadDirectlyUnderHoldAndAppliesIt() {
        let m = model()
        let first = m.track(.opacity)!.keyIDs[0]
        m.setSelection(for: .opacity, ids: [first])
        let lanes = EffectKeyframeLanesView(model: m)
        let items = lanes.makeKeyItems(onKey: true)
        let titles = items.map(\.title)
        #expect(Array(titles.prefix(6)) == ["Steady", "Smooth", "Smooth In", "Smooth Out", "Hold", "Hold Ahead"])
        items[5].action?()
        #expect(kinds(m) == [.holdAhead, .linear])
        items[4].action?()
        #expect(kinds(m) == [.hold, .linear])
        let temporal = items.first { $0.title == "Temporal Interpolation" }?.submenu ?? []
        let sub = temporal.map(\.title)
        #expect(sub.firstIndex(of: "Hold Ahead") == sub.firstIndex(of: "Hold").map { $0 + 1 })
        temporal.first { $0.title == "Hold Ahead" }?.action?()
        #expect(kinds(m) == [.holdAhead, .linear])
        m.applyGraphEase(.hold)
        #expect(kinds(m) == [.hold, .linear])
        m.applyGraphEase(.holdAhead)
        #expect(kinds(m) == [.holdAhead, .linear])
    }

    @Test func toggleHoldBringsBackTheKindTheKeyHad() {
        let m = model()
        let first = m.track(.opacity)!.keyIDs[0]
        m.setSelection(for: .opacity, ids: [first])
        m.applyInterpolation(.holdAhead)
        m.toggleHold()
        #expect(kinds(m) == [.linear, .linear])
        m.toggleHold()
        #expect(kinds(m) == [.holdAhead, .linear])          // not a plain Hold
        // A Hold comes back as a Hold.
        m.applyInterpolation(.hold)
        m.toggleHold(); m.toggleHold()
        #expect(kinds(m) == [.hold, .linear])
        // Another ease by name in between: nothing to bring back, the toggle makes a Hold.
        m.applyInterpolation(.holdAhead)
        m.toggleHold()
        m.applyInterpolation(.linear)
        m.toggleHold()
        #expect(kinds(m) == [.hold, .linear])
    }

    /// The kind Toggle Hold remembers belongs to the clip it saw: undo, a dragged handle or any other edit in between
    /// and the toggle makes a plain Hold.
    @Test func toggleHoldForgetsTheKindWhenTheClipChangedInBetween() throws {
        let m = model()
        let first = m.track(.opacity)!.keyIDs[0]
        m.setSelection(for: .opacity, ids: [first])
        let linear = try #require(m.clip)
        m.applyInterpolation(.holdAhead)
        let ahead = try #require(m.clip)
        m.toggleHold()
        m.setClip(ahead)                                   // undo
        m.setClip(linear)                                  // undo
        #expect(kinds(m) == [.linear, .linear])
        m.toggleHold()
        #expect(kinds(m) == [.hold, .linear])

        m.applyInterpolation(.holdAhead)
        m.toggleHold()
        m.setGraphHandle(EaseHandle(dx: 0.4, dy: 0), side: .outgoing)
        m.toggleHold()
        #expect(kinds(m) == [.hold, .linear])

        m.applyInterpolation(.holdAhead)
        m.toggleHold()
        m.setKeySpeed(0.5, side: .out, for: .opacity)
        m.toggleHold()
        #expect(kinds(m) == [.hold, .linear])
    }

    /// Opacity keyed at 0 s, 2 s and 4 s.
    func threeKeyModel() -> EffectControlsModel {
        let m = model()
        m.playhead = Time(9, 1)
        m.setValue(.opacity, to: 0.2)
        return m
    }

    @Test func curvePresetAppliesToTheSelectedKeysOnly() {
        let m = threeKeyModel()
        let keys = m.track(.opacity)!.keyIDs
        #expect(keys.count == 3)
        m.setSelection(for: .opacity, ids: [keys[1], keys[2]])
        m.applySpeedChip(.smooth, for: .opacity)
        var segs = m.speedSegments(.opacity)
        #expect(SpeedCurveChip.chip(for: segs[0].shape) == .steady)
        #expect(SpeedCurveChip.chip(for: segs[1].shape) == .smooth)
        m.setSelection(for: .opacity, ids: [keys[0], keys[1]])
        m.applySpeedChip(.hold, for: .opacity)
        segs = m.speedSegments(.opacity)
        #expect(SpeedCurveChip.chip(for: segs[0].shape) == .hold)
        #expect(SpeedCurveChip.chip(for: segs[1].shape) == .smooth)
    }

    @Test func rightClickMenuOffersTheCurvePresetsAndAppliesThem() {
        let m = threeKeyModel()
        let keys = m.track(.opacity)!.keyIDs
        m.toggleOpen(.opacity)
        m.setSelection(for: .opacity, ids: [keys[0], keys[1]])
        let g = InlineSpeedGraphView(property: .opacity, model: m)
        let items = g.curveMenuItems()
        #expect(items.map(\.title) == ["Steady", "Smooth", "Smooth In", "Smooth Out", "Hold", "Hold Ahead"])
        #expect(items[0].isChecked)                                   // the selected segment reads as Steady
        items[2].action?()
        let segs = m.speedSegments(.opacity)
        #expect(SpeedCurveChip.chip(for: segs[0].shape) == .smoothIn)
        #expect(SpeedCurveChip.chip(for: segs[1].shape) == .steady)
    }

    @Test func pressInEmptySpaceDragsAMarqueeThatSelectsKeys() {
        let m = threeKeyModel()
        m.toggleOpen(.opacity)
        let keys = m.track(.opacity)!.keyIDs
        let g = InlineSpeedGraphView(property: .opacity, model: m)
        g.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        g.refresh()
        let geo = g.geometry
        let seg = m.speedSegments(.opacity)
        let k1 = geo.key(seg[1], side: .out)
        // Press above the curves, drag down over the middle key only.
        g.press(at: CGPoint(x: k1.x - 6, y: 3), shift: false)
        #expect(m.selectedKeyIDs(.opacity).isEmpty)                      // an empty press clears
        g.dragGesture(to: CGPoint(x: k1.x + 6, y: k1.y + 6))
        #expect(g.marqueeRect != nil)
        #expect(m.selectedKeyIDs(.opacity) == [keys[1]])
        g.release()
        #expect(g.marqueeRect == nil)
        #expect(m.selectedKeyIDs(.opacity) == [keys[1]])
        // Shift-press on another key adds it.
        g.press(at: geo.key(seg[0], side: .out), shift: true); g.release()
        #expect(m.selectedKeyIDs(.opacity) == [keys[0], keys[1]])
    }

    /// Feedback 2026-10-06: a marquee started inside the curve area and dragged up over the row's diamonds did not select
    /// them (the graph kept the marquee to itself). It selects wherever the drag starts.
    @Test func marqueeStartedInTheCurveReachesTheKeysOfTheLanesAbove() {
        let m = threeKeyModel()
        m.toggleOpen(.opacity)
        let keys = m.track(.opacity)!.keyIDs
        let host = FlippedHost(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        let lanes = EffectKeyframeLanesView(model: m)
        lanes.frame = host.bounds
        lanes.rows = [EffectRow(kind: .property(.opacity), y: 0, height: 28), EffectRow(kind: .graph(.opacity), y: 28, height: 120)]
        let g = InlineSpeedGraphView(property: .opacity, model: m)
        g.frame = NSRect(x: 0, y: 28, width: 420, height: 120)
        host.addSubview(lanes); host.addSubview(g)
        g.outerMarquee = { [weak lanes] rect, view in lanes?.externalMarquee(rect, from: view) ?? [] }
        g.refresh()
        // Press in the empty top of the curve area, drag up into the lane of the row above.
        g.press(at: CGPoint(x: 2, y: 3), shift: false)
        g.dragGesture(to: CGPoint(x: 418, y: -14))
        #expect(m.selectedKeyIDs(.opacity) == Set(keys))
        #expect(lanes.marqueeForTests == NSRect(x: 2, y: 14, width: 416, height: 17))     // drawn on over the lanes
        // Only over the first key's diamond.
        let x0 = g.geometry.lane.x(for: m.track(.opacity)!.times[0].time)
        g.dragGesture(to: CGPoint(x: x0 + 4, y: -14))
        #expect(m.selectedKeyIDs(.opacity) == [keys[0]])
        // Back inside the curve area, above the curve: nothing is under the marquee any more.
        g.dragGesture(to: CGPoint(x: 418, y: 6))
        #expect(m.selectedKeyIDs(.opacity).isEmpty)
        g.dragGesture(to: CGPoint(x: 418, y: -14))
        g.release()
        #expect(lanes.marqueeForTests == nil && g.marqueeRect == nil)
        #expect(m.selectedKeyIDs(.opacity) == Set(keys))
    }

    @Test func draggingAHandleToTheEndOfItsReachGivesFullInfluence() {
        let m = model()
        m.toggleOpen(.opacity)
        m.applySpeedChip(.smooth, for: .opacity)
        let g = InlineSpeedGraphView(property: .opacity, model: m)
        g.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        g.refresh()
        let seg = m.speedSegments(.opacity)[0]
        let geo = g.geometry
        let end = geo.handleEnd(seg, side: .out), k = geo.key(seg, side: .out)
        let grab = end.x - geo.handleTrueEnd(seg, side: .out).x
        #expect(g.beginDrag(at: end))
        g.continueDrag(to: CGPoint(x: k.x + geo.handleSpan(seg) + grab, y: end.y))
        g.endDrag()
        #expect(m.speedValues(for: .opacity)!.reachOut == 1)
        // Further right stays at 100 %; the in-handle keeps its own influence (no cross clamp).
        g.refresh()
        let end2 = g.geometry.handleEnd(m.speedSegments(.opacity)[0], side: .out)
        #expect(g.beginDrag(at: end2))
        g.continueDrag(to: CGPoint(x: end2.x + 200, y: end2.y)); g.endDrag()
        let v = m.speedValues(for: .opacity)!
        #expect(v.reachOut == 1 && abs(v.reachIn - 1.0 / 3) < 1e-9)
    }

    @Test func handleDragsVerticallyOnlyPastTheDeadZoneAndNotWithShift() {
        let m = model()
        m.toggleOpen(.opacity)
        m.applySpeedChip(.smooth, for: .opacity)
        let g = InlineSpeedGraphView(property: .opacity, model: m)
        g.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        g.refresh()
        let end = g.geometry.handleEnd(m.speedSegments(.opacity)[0], side: .out)
        #expect(g.beginDrag(at: end))
        g.continueDrag(to: CGPoint(x: end.x, y: end.y - 4))
        #expect(abs(m.speedValues(for: .opacity)!.speedOut) < 0.01)          // inside the dead zone
        g.continueDrag(to: CGPoint(x: end.x, y: end.y - 20), shift: true)
        #expect(abs(m.speedValues(for: .opacity)!.speedOut) < 0.01)          // Shift: horizontal only
        g.continueDrag(to: CGPoint(x: end.x, y: end.y - 20))
        #expect(m.speedValues(for: .opacity)!.speedOut > 0.1)                // past it: the speed follows
        g.endDrag()
    }

    @Test func reachChangesOnlyTheHandleLength() {
        let m = model()
        m.toggleOpen(.opacity)
        m.applySpeedChip(.smooth, for: .opacity)
        m.setReach(0.6, side: .out, for: .opacity)
        let v = m.speedValues(for: .opacity)!
        #expect(abs(v.reachOut - 0.6) < 1e-6)
        #expect(abs(v.speedOut) < 0.01 && abs(v.speedIn) < 0.01)     // still two eased keys
        #expect(m.speedChip(for: .opacity) == .smooth)
    }

    @Test func keySpeedLeavesTheReach() {
        let m = model()
        m.toggleOpen(.opacity)
        m.applySpeedChip(.smooth, for: .opacity)
        let before = m.speedValues(for: .opacity)!
        m.setKeySpeed(0.5, side: .out, for: .opacity)
        let v = m.speedValues(for: .opacity)!
        #expect(abs(v.speedOut - 0.5) < 1e-6 && abs(v.reachOut - before.reachOut) < 1e-6)
    }

    @Test func graphDrawsTheOpenedRowAndTheRowsSelectedWithIt() {
        let m = model()
        m.playhead = Time(5, 1); m.toggleStopwatch(.rotation)
        m.playhead = Time(8, 1); m.setValue(.rotation, to: 40)
        #expect(m.speedGraphRows(for: .opacity) == [.opacity])
        m.selectGraphProperty(.opacity, extend: false)
        m.selectGraphProperty(.rotation, extend: true)
        #expect(Set(m.speedGraphRows(for: .opacity)) == [.opacity, .rotation])
        #expect(m.speedGraphRows(for: .opacity).first == .opacity)
        // Both rows selected and eased together: one chip click, one hill per row.
        m.setSelection(for: .opacity, ids: Set(m.track(.opacity)!.keyIDs))
        m.setSelection(for: .rotation, ids: Set(m.track(.rotation)!.keyIDs))
        m.applySpeedChip(.smooth, for: .opacity)
        #expect(SpeedCurveChip.chip(for: m.speedSegments(.opacity)[0].shape) == .smooth)
        #expect(SpeedCurveChip.chip(for: m.speedSegments(.rotation)[0].shape) == .smooth)
    }

    @Test func shiftedHandleDragChangesReachHorizontallyOnly() {
        let m = model()
        m.toggleOpen(.opacity)
        m.applySpeedChip(.smooth, for: .opacity)
        let g = InlineSpeedGraphView(property: .opacity, model: m)
        g.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        g.refresh()
        let seg = m.speedSegments(.opacity)[0]
        let geo = SpeedGraphGeometry(lane: m.laneGeometry(width: 420), height: 120, peak: SpeedGraphGeometry.peak(of: [seg]))
        let end = geo.handleEnd(seg, side: .out)
        let before = m.speedValues(for: .opacity)!
        // Straight up with Shift: nothing changes.
        #expect(g.beginDrag(at: end))
        g.continueDrag(to: CGPoint(x: end.x, y: end.y - 40), shift: true)
        g.endDrag()
        let up = m.speedValues(for: .opacity)!
        #expect(abs(up.reachOut - before.reachOut) < 0.01 && abs(up.speedOut - before.speedOut) < 1e-6)
        // Sideways: the reach follows, the key speed stays.
        g.refresh()
        #expect(g.beginDrag(at: end))
        g.continueDrag(to: CGPoint(x: end.x + 0.2 * geo.handleSpan(seg), y: end.y + 30), shift: true)
        g.endDrag()
        let side = m.speedValues(for: .opacity)!
        #expect(abs(side.reachOut - (before.reachOut + 0.2)) < 0.02)
        #expect(abs(side.speedOut - before.speedOut) < 1e-6)
    }

    @Test func sectionSummaryNamesTheLook() {
        let m = model()
        #expect(m.sectionSummary(.motion) == nil)
        m.collapsedSections = [.motion]
        #expect(m.sectionSummary(.motion)?.isEmpty == false)
    }
}

private final class FlippedHost: NSView {
    override var isFlipped: Bool { true }
}

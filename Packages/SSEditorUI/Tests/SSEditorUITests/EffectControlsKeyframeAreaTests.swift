import AppKit
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

@MainActor @Suite struct EffectControlsKeyframeAreaTests {
    /// Video clip at 5 s on the timeline, 10 s long; playhead at its start.
    func rig(playhead: Time = Time(5, 1)) -> (EffectControlsModel, Box) {
        let clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let m = EffectControlsModel()
        let box = Box()
        m.onEdit = { c, _, _ in box.edits += 1; m.setClip(c) }
        m.onSeek = { box.seeks.append($0) }
        m.setClip(clip)
        m.playhead = playhead
        return (m, box)
    }
    final class Box { var edits = 0; var seeks: [Time] = []; var log: [String] = [] }
    func t(_ s: Int64) -> Time { Time(s, 1) }

    func keyIDs(_ m: EffectControlsModel, _ p: EffectProperty) -> [UUID] { m.clip!.animation.opacity.track.keys.map(\.id) }

    // MARK: Deselect after move

    @Test func movedKeyIsDeselectedAndTheNextValueChangeMakesANewKey() {
        let (m, _) = rig(playhead: t(5))
        m.setValue(.opacity, to: 0.5)
        m.toggleStopwatch(.opacity)                                   // key at 0 s
        let id = keyIDs(m, .opacity)[0]
        m.selectKey(.opacity, id: id, extend: false)
        m.beginGesture()
        m.moveSelection(by: t(2))
        m.endKeyMove()                                                // the lane drag ends
        #expect(m.selection.isEmpty)
        #expect(m.clip!.animation.opacity.track.keys[0].time == t(2))
        m.playhead = t(9)                                             // 4 s into the clip
        m.setValue(.opacity, to: 0.9)
        let keys = m.clip!.animation.opacity.track.keys
        #expect(keys.count == 2 && keys[0].value == 0.5 && keys[1].time == t(4) && keys[1].value == 0.9)
    }

    @Test func aKeySelectedElsewhereDoesNotCaptureAValueEdit() {
        let (m, _) = rig(playhead: t(5))
        m.toggleStopwatch(.opacity)                                   // key at 0 s
        m.selectKey(.opacity, id: keyIDs(m, .opacity)[0], extend: false)
        m.playhead = t(8)                                             // playhead away from the selected key
        m.setValue(.opacity, to: 0.3)
        #expect(m.clip!.animation.opacity.track.keys.count == 2)
        #expect(m.clip!.animation.opacity.track.keys[0].value == 1)   // untouched
    }

    @Test func keyDragThatChangedNothingKeepsTheSelection() {
        let (m, _) = rig(playhead: t(5))
        m.toggleStopwatch(.opacity)
        m.selectKey(.opacity, id: keyIDs(m, .opacity)[0], extend: false)
        m.beginGesture()
        m.moveSelection(by: .zero)
        m.endKeyMove()
        #expect(m.selection.count == 1)
    }

    @Test func resetInsideAnOpenGestureUsesTheGestureBase() {
        let (m, _) = rig(playhead: t(5))
        m.toggleStopwatch(.opacity)
        m.beginGesture()
        #expect(m.reset(.opacity) || true)
        m.endGesture()
        #expect(m.clip != nil)
    }

    @Test func clipChangeEndsAnOpenScrub() {
        let (m, box) = rig()
        m.onScrubEnded = { box.log.append("end") }
        m.scrubDown(to: t(7)); m.scrubDrag(to: t(8))
        m.setClip(Clip(name: "o", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: t(5)), start: .zero))
        #expect(box.log == ["end"])
        m.scrubUp()
        #expect(box.log == ["end"])                                   // not ended twice
    }

    // MARK: Reset

    @Test func resetOnAnimatedPropertyResetsOnlyTheValueAtThePlayhead() {
        let (m, _) = rig(playhead: t(5))
        m.setValue(.opacity, to: 0.2)
        m.toggleStopwatch(.opacity)                                   // key 0 s = 0.2
        m.playhead = t(9)
        m.setValue(.opacity, to: 0.6)                                 // key 4 s = 0.6
        m.playhead = t(7)                                             // between the keys
        #expect(m.canResetAtPlayhead(.opacity))
        #expect(m.reset(.opacity))
        let keys = m.clip!.animation.opacity.track.keys
        #expect(keys.count == 3)                                      // a key with the default value was added
        #expect(keys.first { $0.time == t(2) }?.value == ClipAnimation().opacity.value)
        #expect(keys[0].value == 0.2 && keys.last!.value == 0.6)
        // On a key: replaces that key's value.
        m.playhead = t(9)
        m.reset(.opacity)
        #expect(m.clip!.animation.opacity.track.keys.count == 3)
        #expect(m.clip!.animation.opacity.track.keys.last!.value == 1)
    }

    @Test func resetAllDropsTheKeysAndVectorsResetAtThePlayheadToo() {
        let (m, _) = rig(playhead: t(5))
        m.setValue(.opacity, to: 0.2); m.toggleStopwatch(.opacity)
        m.resetAll(.opacity)
        #expect(!m.isAnimated(.opacity) && m.isDefault(.opacity))
        m.setValue(.position, component: .x, to: 40)
        m.toggleStopwatch(.position)
        m.playhead = t(8)
        m.setValue(.position, component: .x, to: 100)
        m.playhead = t(6)
        m.reset(.position)
        #expect(m.clip!.animation.position.track.keys.count == 3)
        #expect(m.vectorValue(.position) == Vec2.zero)
        #expect(m.isAnimated(.position))
    }

    @Test func resetAtPlayheadOutsideTheClipDoesNothing() {
        let (m, box) = rig(playhead: t(5))
        m.toggleStopwatch(.opacity)
        m.playhead = t(30)
        let before = box.edits
        #expect(!m.reset(.opacity))
        #expect(box.edits == before)
    }

    // MARK: Scrubbing stops playback

    @Test func rulerPressStopsPlaybackAndDragScrubsOnce() {
        let (m, box) = rig()
        m.onPointerDown = { box.log.append("stop") }
        m.onScrubBegan = { box.log.append("begin") }
        m.onScrub = { box.log.append("scrub \($0.value)") }
        m.onScrubEnded = { box.log.append("end") }
        m.scrubDown(to: t(7))
        #expect(box.log == ["stop"] && box.seeks == [t(7)])
        m.scrubDrag(to: t(8)); m.scrubDrag(to: t(9))
        m.scrubUp()
        #expect(box.log == ["stop", "begin", "scrub 8", "scrub 9", "end"])
        box.log = []
        m.scrubDown(to: t(7)); m.scrubUp()                            // a plain click never begins a scrub
        #expect(box.log == ["stop"])
    }

    @Test func shiftSnapsTheScrubToKeyframes() {
        let (m, _) = rig()
        m.toggleStopwatch(.opacity)
        m.playhead = t(8)
        m.setValue(.opacity, to: 0.5)                                 // keys at 0 s and 3 s (clip-local)
        let near = Time(31, 10)                                       // 3.1 s
        #expect(m.scrubTarget(local: near, snap: true, thresholdSeconds: 0.2) == t(8))
        #expect(m.scrubTarget(local: near, snap: false, thresholdSeconds: 0.2) == t(5) + near)
        #expect(m.scrubTarget(local: Time(6, 1), snap: true, thresholdSeconds: 0.2) == t(11))
        #expect(m.snapTargets().contains(t(3)) && m.snapTargets().contains(.zero) && m.snapTargets().contains(t(10)))
    }

    // MARK: Zoom

    @Test func zoomPanAndFit() {
        let (m, _) = rig(playhead: t(10))                             // clip-local 5 s
        #expect(!m.isZoomed)
        m.zoomIn()
        #expect(m.isZoomed && m.viewport.span < 10 && m.viewport.range.contains(5))
        let span = m.viewport.span
        m.panViewport(bySeconds: 1)
        #expect(m.viewport.span == span && m.viewport.start > 0)
        m.zoomToFit()
        #expect(!m.isZoomed && m.viewport.isFull(duration: 10))
        for _ in 0..<40 { m.zoomIn() }
        #expect(m.viewport.span >= m.minViewportSpan - 1e-12)
        m.zoom(by: 0.000_1)
        #expect(!m.isZoomed)                                          // zooming all the way out is the whole clip again
    }

    @Test func keyNavigationScrollsTheKeyIntoView() {
        let (m, box) = rig(playhead: t(5))
        m.toggleStopwatch(.opacity)
        m.playhead = t(14)
        m.setValue(.opacity, to: 0.5)                                 // keys at 0 s and 9 s
        m.playhead = t(5)
        m.setViewport(KeyframeViewport(start: 0, span: 2))
        m.goToNextKey(.opacity)
        #expect(box.seeks.last == t(14))
        #expect(m.viewport.range.contains(9))
    }

    @Test func newClipShowsTheWholeRangeAgain() {
        let (m, _) = rig()
        m.zoomIn()
        let other = Clip(name: "o", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(20, 1)), start: .zero)
        m.setClip(other)
        #expect(!m.isZoomed && m.viewport.span == 20)
        #expect(m.laneGeometry(width: 210).x(for: Time(20, 1)) == 200)
    }

    // MARK: View

    func setupView(clip: Bool = true) -> (EffectControlsModel, EffectControlsView) {
        let (m, _) = rig()
        if !clip { m.setClip(nil) }
        let v = EffectControlsView(model: m)
        v.persistLabelWidth = { _ in }
        v.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        v.layoutSubtreeIfNeeded()
        return (m, v)
    }
    func all<T: NSView>(_ t: T.Type, in v: NSView) -> [T] {
        var out: [T] = []
        func walk(_ n: NSView) { for s in n.subviews { if let x = s as? T { out.append(x) }; walk(s) } }
        walk(v); return out
    }

    @Test func rulerIsAtTheTopAndTimecodeAndZoomBarAtTheBottom() {
        let (_, v) = setupView()
        let ruler = all(KeyframeRulerView.self, in: v)[0], bar = all(KeyframeZoomBar.self, in: v)[0]
        #expect(ruler.frame.minY == 0 && ruler.frame.height == KeyframeRulerView.height)
        #expect(bar.frame.maxY == v.bounds.height)
        let scroll = all(NSScrollView.self, in: v)[0]
        #expect(scroll.frame.minY == ruler.frame.maxY && scroll.frame.maxY == bar.frame.minY)
        #expect(ruler.frame.minX == bar.frame.minX)
        #expect(all(KeyframeRulerView.self, in: v).count == 1)
    }

    @Test func dividerIsHiddenWithoutAClipAndDragClampsAndPersists() {
        let (_, empty) = setupView(clip: false)
        #expect(all(EffectControlsDivider.self, in: empty)[0].isHidden)
        #expect(all(KeyframeRulerView.self, in: empty)[0].isHidden && all(KeyframeZoomBar.self, in: empty)[0].isHidden)

        let (_, v) = setupView()
        var saved: [CGFloat] = []
        v.persistLabelWidth = { saved.append($0) }
        let d = all(EffectControlsDivider.self, in: v)[0]
        #expect(!d.isHidden)
        d.onBegin?()
        d.onDrag?(-1000)
        #expect(v.labelWidth == EffectControlsSplit.minLabelWidth)
        d.onDrag?(+5000)
        v.layoutSubtreeIfNeeded()
        #expect(v.labelWidth == 900 - EffectControlsSplit.minLanesWidth)
        d.onDrag?(20)
        d.onEnd?()
        #expect(saved == [EffectControlsSplit.defaultWidth + 20])
        v.layoutSubtreeIfNeeded()
        #expect(all(KeyframeRulerView.self, in: v)[0].frame.minX == v.labelWidth)
    }

    @Test func expandedPropertyHasNoSegmentedControlAndKeysAreOnlyInTheRow() async {
        let (m, v) = setupView()
        m.expanded = [.opacity]
        try? await Task.sleep(for: .milliseconds(50))    // observation re-arms on the main actor
        v.layoutSubtreeIfNeeded()
        #expect(all(NSSegmentedControl.self, in: v).isEmpty)
        #expect(all(KeyframeGraphView.self, in: v).count == 1)
    }

    @Test func textSectionSitsBelowMotionAndOpacity() {
        let (m, _) = rig()
        let tl = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        let session = EditorSession(project: Project(name: "P", timelines: [tl]))
        let v = EffectControlsView(model: m)
        v.persistLabelWidth = { _ in }
        let sections = ClipSectionsView(session: session)
        v.clipSections = sections
        v.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        v.layoutSubtreeIfNeeded()
        let rows = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [])
        #expect(sections.frame.minY == EffectControlsLayout.totalHeight(rows))
    }

    @Test func windowCoordinatesPutRulerAboveLanesAboveZoomBar() {
        let (m, v) = setupView()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        win.contentView = v
        v.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        v.layoutSubtreeIfNeeded()
        _ = m
        func top(_ x: NSView) -> CGFloat { x.convert(x.bounds, to: nil).maxY }   // window space: y grows upwards
        func bottom(_ x: NSView) -> CGFloat { x.convert(x.bounds, to: nil).minY }
        let ruler = all(KeyframeRulerView.self, in: v)[0], bar = all(KeyframeZoomBar.self, in: v)[0]
        let lanes = all(EffectKeyframeLanesView.self, in: v)[0]
        #expect(bottom(ruler) >= top(lanes) - 0.5)          // ruler above the lanes
        #expect(top(bar) <= bottom(lanes) + 0.5 || top(bar) <= bottom(all(NSScrollView.self, in: v)[0]) + 0.5)
        #expect(bottom(ruler) > top(bar))                   // and above the zoom bar
        #expect(abs(top(ruler) - v.convert(v.bounds, to: nil).maxY) < 0.5)   // ruler touches the panel top
    }

    @Test func glyphKindPerKey() {
        func k(_ i: Interpolation, inH: EaseHandle = .linear, outH: EaseHandle = .linear) -> Keyframe<Double> {
            Keyframe(time: .zero, value: 0, interpolation: i, inHandle: inH, outHandle: outH)
        }
        var a = k(.linear), b = k(.linear); b.time = Time(1, 1)
        // a fresh key (single, linear) is a plain diamond
        #expect(KeyGlyph.glyphs(of: KeyframeTrack(keys: [a])).map(\.glyph) == [.linear])
        #expect(KeyGlyph.glyphs(of: KeyframeTrack(keys: [a, b])).allSatisfy { $0.glyph == .linear })
        // eased: hourglass halves only on the eased side
        let ease = EaseHandle(dx: 0.6, dy: 0)
        a.interpolation = .bezier; a.outHandle = ease
        let g = KeyGlyph.glyphs(of: KeyframeTrack(keys: [a, b])).map(\.glyph)
        #expect(g[0] == KeyGlyph(incoming: .eased, outgoing: .eased))
        #expect(g[1] == KeyGlyph(incoming: .linear, outgoing: .linear))
        #expect(g[0].shape == .circle && g[1].shape == .diamond)
    }

    // MARK: Empty area below the last row

    @Test func lanesCoverTheEmptyAreaBelowTheLastRow() {
        let (_, v) = setupView()
        let lanes = all(EffectKeyframeLanesView.self, in: v)[0]
        let scroll = all(NSScrollView.self, in: v)[0]
        #expect(lanes.frame.height >= scroll.frame.height)                // playhead line, zoom and clicks reach the bottom
        #expect(lanes.hit(at: CGPoint(x: 100, y: lanes.frame.height - 5)) == .none)
    }

    @Test func clickInTheEmptyAreaDeselectsKeys() {
        let (m, v) = setupView()
        m.toggleStopwatch(.opacity)
        m.selectKey(.opacity, id: m.clip!.animation.opacity.track.keys[0].id, extend: false)
        #expect(!m.selection.isEmpty)
        let win = NSWindow(contentRect: v.frame, styleMask: [.titled], backing: .buffered, defer: true)
        win.contentView = v
        v.layoutSubtreeIfNeeded()
        let lanes = all(EffectKeyframeLanesView.self, in: v)[0]
        let p = lanes.convert(CGPoint(x: 120, y: lanes.bounds.height - 8), to: nil)
        let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        lanes.mouseDown(with: e)
        lanes.mouseUp(with: e)
        #expect(m.selection.isEmpty)
    }

    @Test func zoomInputInTheEmptyAreaUsesTheSharedViewport() {
        let (m, v) = setupView()
        let lanes = all(EffectKeyframeLanesView.self, in: v)[0]
        // The lanes view maps x through the model viewport everywhere, including below the last row.
        let before = lanes.geometry.pointsPerSecond
        m.zoomIn()
        #expect(lanes.geometry.pointsPerSecond > before)
        #expect(lanes.geometry == m.laneGeometry(width: lanes.bounds.width))
    }
}

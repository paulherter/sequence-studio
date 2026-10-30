import AppKit
import Foundation
import SQCore
import SQLibrary
import Testing
@testable import SQInspectorUI

@MainActor @Suite struct EasingCurvePopoverTests {
    // MARK: Model

    /// Position and Scale with two keys each, all four selected.
    func rig() -> (EffectControlsModel, Log) {
        let m = EffectControlsModel(), log = Log()
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        c.animation.position.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(0, 0)), Keyframe(time: Time(2, 1), value: Vec2(100, 0))])
        c.animation.scale.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(1, 1)), Keyframe(time: Time(2, 1), value: Vec2(2, 2))])
        m.onEdit = { n, name, coalescing in log.edits.append((name, coalescing)); m.setClip(n) }
        m.setClip(c)
        for k in c.animation.position.track.keys { m.selectKey(.position, id: k.id, extend: true) }
        for k in c.animation.scale.track.keys { m.selectKey(.scale, id: k.id, extend: true) }
        return (m, log)
    }

    final class Log { var edits: [(String, Bool)] = [] }

    @Test func oneDragGivesIdenticalHandlesOnAllSegmentsInOneUndoStep() {
        let (m, log) = rig()
        #expect(m.easeReading == .common(.linear))
        m.beginGesture()
        for y in [0.3, 0.6, 0.9] {
            m.applyEaseShape(EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.25, dy: y), in: .linear))
        }
        m.endGesture()
        let a = m.clip!.animation
        #expect(a.position.track.keys[0].outHandle == EaseHandle(dx: 0.25, dy: 0.9))
        #expect(a.position.track.keys[0].outHandle == a.scale.track.keys[0].outHandle)
        #expect(a.position.track.keys[1].inHandle == a.scale.track.keys[1].inHandle)
        #expect(log.edits.map(\.1) == [false, true, true])          // first edit opens the undo step, the rest coalesce
        if case .common(let s) = m.easeReading { #expect(abs(s.out.dy - 0.9) < 1e-9) } else { Issue.record("not common") }
    }

    @Test func mixedReadingWhenOnePropertyDiffers() {
        let (m, _) = rig()
        let scaleOnly = m.clip!.animation.scale.track.keys.map { SummaryMember(property: EffectProperty.scale.id, keyID: $0.id) }
        let all = m.selection
        m.select(scaleOnly, extend: false)
        m.applyEaseShape(EasingCurve.easeInOut.shape)
        m.select(Array(all), extend: false)
        guard case .mixed(let shapes) = m.easeReading else { Issue.record("expected mixed"); return }
        #expect(shapes.count == 2)
    }

    @Test func applyWithoutSelectionDoesNothing() {
        let (m, log) = rig()
        m.clearSelection()
        m.applyEaseShape(EasingCurve.easeInOut.shape)
        #expect(log.edits.isEmpty)
        #expect(m.easeReading == .empty)
    }

    @Test func reopeningPopoverKeepsOneObservationChain() {
        let (m, _) = rig()
        let c = EasingCurvePopoverController(model: m, library: EasingPresetLibrary(store: nil))
        _ = c.view
        for _ in 0 ..< 3 { c.viewWillAppear(); c.viewDidDisappear() }
        c.viewWillAppear()
        #expect(c.observationChains == 1)
        #expect(c.editor.reading == .common(.linear))
    }

    // MARK: Presets

    @Test func presetLibrarySavesAndReloadsEasing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-easing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PresetStore(applicationSupport: dir)
        let lib = EasingPresetLibrary(store: store)
        let shape = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.1, dy: 1.2), in: EaseHandle(dx: 0.3, dy: 0))
        try await lib.save(shape, name: "  Bounce ")
        #expect(lib.saved.map(\.name) == ["Bounce"])
        let again = EasingPresetLibrary(store: try PresetStore(applicationSupport: dir))
        await again.reload()
        #expect(again.saved.first?.shape == shape)
        #expect(await store.presets(kind: .easing).count == 1)
    }

    @Test func chipsAreBuiltInsThenSaved() {
        let lib = EasingPresetLibrary(store: nil)
        let extra = EasingCurve(shape: .linear, name: "Mine")
        let chips = EasingCurveChips.curves(library: lib, session: [extra])
        #expect(Array(chips.prefix(EasingCurve.builtIns.count)) == EasingCurve.builtIns)
        #expect(chips.last == extra)
    }

    /// One editor for every source (DECISIONS 2026-10-06): the ruler button's popover shows the speed curve of the
    /// selected keys and its handles change the Reach of all of them in one undo step.
    @Test func rulerPopoverIsTheSpeedEditorAndDragsReach() throws {
        let (m, log) = rig()
        m.applyEaseShape(EasingCurve.easeInOut.shape)
        log.edits.removeAll()
        let c = EasingCurvePopoverController(model: m, library: EasingPresetLibrary(store: nil))
        c.loadView(); c.refresh()
        let e: EaseSpeedEditorView = c.editor
        #expect(e.superview === c.view && c.view.subviews.filter { $0 is EaseSpeedEditorView }.count == 1)
        let seg = try #require(e.segment), geo = e.geometry
        let out = geo.handleEnd(seg, side: .out)
        #expect(e.press(at: out))
        e.dragGesture(to: CGPoint(x: geo.x(seg, share: 0.5), y: 3))
        e.dragGesture(to: CGPoint(x: geo.x(seg, share: 0.5) + 30, y: 3))
        e.release()
        let a = m.clip!.animation
        #expect(a.position.track.keys[0].outHandle.dx == 1 && a.scale.track.keys[0].outHandle.dx == 1)
        #expect(abs(a.position.track.keys[1].inHandle.dx - 1.0 / 3) < 1e-9)
        #expect(log.edits.map(\.1).first == false && log.edits.dropFirst().allSatisfy(\.1))   // one undo step
        // Keyframes take Hold: the chip is there.
        #expect(c.chipItemsForTests.contains { $0.name == "Hold" })
    }

    @Test func holdChipOnlyWhereHoldCanBeApplied() {
        let lib = EasingPresetLibrary(store: nil)
        let mine = EasingCurve(shape: .hold, name: "My Hold")
        #expect(EasingCurveChips.curves(library: lib, session: [mine]).contains(.hold))
        let without = EasingCurveChips.curves(library: lib, session: [mine], hold: false)
        #expect(!without.contains { $0.interpolation == .hold })
        #expect(without.count == EasingCurve.builtIns.count - 1)
        // A curve saved from a Hold Ahead key is a Hold: no chip where Hold is refused (transition, speed ramp).
        let ahead = EasingCurve(from: Keyframe(time: .zero, value: 1.0, interpolation: .holdAhead), name: "Reversed")
        #expect(ahead.interpolation == .hold)
        #expect(EasingCurveChips.curves(library: lib, session: [ahead], hold: false) == without)
    }

    // MARK: Thumbnails and springs

    @Test func thumbnailPointsComeFromPreviewSamples() {
        let rect = CGRect(x: 0, y: 0, width: 30, height: 20)
        let item = EasingChipItem.curve(.easeOut100)
        let pts = EasingThumbnail.points(samples: item.samples(count: 11), in: rect)
        #expect(pts.count == 11)
        #expect(pts.first == CGPoint(x: 0, y: 20) && pts.last == CGPoint(x: 30, y: 0))   // 0 at bottom, 1 on top
        #expect(pts[5].y < 10)                                                           // decelerating: past halfway at t = 0.5
        let spring = EasingChipItem.spring(EasingLibrary.springPresets[2])
        let sp = EasingThumbnail.points(samples: spring.samples(count: 40), in: rect)
        #expect(sp.contains { $0.y < 0 } == false && sp.last!.y == 0 || sp.contains { $0.y >= 0 })
        #expect(sp.map(\.y).min()! >= 0)                                                  // overshoot widens the range, stays inside
    }

    @Test func chipsListSpringsOnlyForKeyframeSources() {
        let (m, _) = rig()
        let c = EasingCurvePopoverController(model: m, library: EasingPresetLibrary(store: nil))
        _ = c.view
        c.refresh()
        #expect(c.chipItemsForTests.suffix(3).map(\.name) == EasingLibrary.springPresets.map(\.name))
    }

    @Test func applyingSpringBakesKeysAsOneUndoStep() {
        let (m, log) = rig()
        let before = m.clip!.animation.position.track.keys.count
        m.applySpring(EasingLibrary.springPresets[2].spring)
        let t = m.clip!.animation.position.track
        #expect(t.keys.count > before)
        #expect(t.keys.allSatisfy { $0.interpolation == .linear })
        #expect(t.keys.last?.value == Vec2(100, 0))
        #expect(log.edits.count == 1 && log.edits[0].0 == "Apply Spring")
    }

    @Test func springNeedsSelection() {
        let (m, log) = rig()
        m.clearSelection()
        m.applySpring(SpringEasing(bounce: 0.5))
        #expect(log.edits.isEmpty)
    }
}

import CoreGraphics
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Mask pen handles in the Program monitor (tangents, add / delete vertex, corner <-> smooth, move the mask) and
/// Track Forward / Backward from Effect Controls.
@MainActor @Suite struct MaskPenTrackTests {
    final class Log { var edits: [(Clip, String, Bool)] = [] }

    func rig(_ kind: MaskShapeKind = .rectangle) -> (EffectControlsModel, ClipMask.ID, Log) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(5, 1))
        let mask = ClipMask.make(kind, name: "Mask (1)")
        clip.masks = [mask]
        let m = EffectControlsModel(); let log = Log()
        m.onEdit = { c, n, co in log.edits.append((c, n, co)) }
        m.setClip(clip); m.playhead = Time(6, 1)
        m.frameDuration = Time(1, 2)
        return (m, mask.id, log)
    }

    /// Moves the region right by `dx` per frame (and turns it by `turn` radians per frame about its first vertex); loses
    /// it after `lostAfter` frames. Records the mode it was asked for.
    final class FakeTracker: MaskTracking, @unchecked Sendable {
        var dx = 0.1
        var turn = 0.0
        var lostAfter = Int.max
        var modes: [MaskTrackMode] = []
        init(dx: Double = 0.1, turn: Double = 0, lostAfter: Int = .max) { self.dx = dx; self.turn = turn; self.lostAfter = lostAfter }
        func track(region: [Vec2], mode: MaskTrackMode, sourceTimes: [Time],
                   progress: (@Sendable (Double) -> Void)?) async throws -> [MaskMotion?] {
            modes.append(mode)
            return sourceTimes.indices.map { i in
                i > lostAfter ? nil : MaskMotion(rotation: turn * Double(i), about: region[0])
                    .then(MaskMotion(translation: Vec2(dx * Double(i), 0)))
            }
        }
    }

    @Test func activeMaskIsTheSelectedOneOrTheOnlyOne() {
        let (m, id, _) = rig()
        #expect(m.maskOverlays.first?.active == true)
        let other = m.addMask(.ellipse)!
        #expect(m.maskOverlays.allSatisfy { !$0.active })
        m.selectedSection = .mask(other)
        #expect(m.maskOverlays.first { $0.id == other }?.active == true)
        #expect(m.maskOverlays.first { $0.id == id }?.active == false)
    }

    @Test func tangentDragIsOneUndoStepAndMirrors() {
        let (m, id, log) = rig(.ellipse)
        m.beginGesture()
        m.moveMaskTangent(id, index: 0, out: true, to: Vec2(0.2, 0), independent: false)
        m.moveMaskTangent(id, index: 0, out: true, to: Vec2(0.3, 0), independent: false)
        m.endGesture()
        let v = m.clip!.mask(id)!.path.value.vertices[0]
        #expect(v.outTangent == Vec2(0.3, 0) && v.inTangent == Vec2(-0.3, 0))
        #expect(log.edits.map(\.2) == [false, true])
    }

    @Test func moveMaskDragsFromTheGestureBase() {
        let (m, id, log) = rig()
        let start = m.clip!.mask(id)!.path.value
        m.beginGesture()
        m.moveMask(id, by: Vec2(0.1, 0))
        m.moveMask(id, by: Vec2(0.2, 0.1))
        m.endGesture()
        let p = m.clip!.mask(id)!.path.value
        #expect(abs(p.vertices[0].point.x - (start.vertices[0].point.x + 0.2)) < 1e-9)
        #expect(log.edits.count == 2 && log.edits.last?.1 == "Move Mask")
    }

    @Test func addRemoveAndConvertVertices() {
        let (m, id, log) = rig()
        m.insertMaskVertex(id, segment: 0, at: 0.5)
        #expect(m.clip!.mask(id)!.path.value.vertices.count == 5)
        m.toggleMaskVertexSmooth(id, index: 1)
        #expect(!m.clip!.mask(id)!.path.value.vertices[1].isCorner)
        m.removeMaskVertex(id, index: 1)
        #expect(m.clip!.mask(id)!.path.value.vertices.count == 4)
        #expect(log.edits.map(\.1) == ["Add Mask Vertex", "Convert Mask Vertex", "Delete Mask Vertex"])
    }

    @Test func penPlacesAVertexAndPullsItsHandlesInOneUndoStep() {
        let (m, id, log) = rig()
        m.beginGesture()
        m.placeMaskVertex(id, segment: 0, at: 0.5, handle: .zero, independent: false)
        m.placeMaskVertex(id, segment: 0, at: 0.5, handle: Vec2(0.1, 0.05), independent: false)
        m.endGesture()
        let v = m.clip!.mask(id)!.path.value.vertices
        #expect(v.count == 5 && v[1].outTangent == Vec2(0.1, 0.05) && v[1].inTangent == Vec2(-0.1, -0.05))
        #expect(log.edits.map(\.2) == [false, true])
    }

    @Test func trackForwardKeysEveryFrameInOneUndoStep() async throws {
        let (m, id, log) = rig()
        let n = try await m.trackMask(id, forward: true, tracker: FakeTracker())
        // Playhead at local 1 s, half-second frames, clip 2 s: frames 1 and 1.5.
        #expect(n == 2)
        let keys = m.clip!.mask(id)!.path.track.keys.sorted { $0.time < $1.time }
        #expect(keys.map(\.time) == [Time(1, 1), Time(3, 2)])
        #expect(abs(keys[1].value.vertices[0].point.x - keys[0].value.vertices[0].point.x - 0.1) < 1e-9)
        #expect(log.edits.count == 1 && log.edits[0].1 == "Track Mask" && !log.edits[0].2)
    }

    @Test func trackUsesTheChosenModeAndKeysTurnedShapes() async throws {
        let (m, id, _) = rig()
        #expect(m.maskTrackMode == .scale)
        m.maskTrackMode = .rotation
        let fake = FakeTracker(dx: 0, turn: .pi / 2)
        let n = try await m.trackMask(id, forward: true, tracker: fake)
        #expect(n == 2 && fake.modes == [.rotation])
        let keys = m.clip!.mask(id)!.path.track.keys.sorted { $0.time < $1.time }
        let a = keys[0].value.vertices, b = keys[1].value.vertices
        // A quarter turn about vertex 0: vertex 0 stays, vertex 1 (to its right) ends up below it.
        #expect((b[0].point - a[0].point).length < 1e-9)
        let d = a[1].point - a[0].point
        #expect((b[1].point - (a[0].point + Vec2(-d.y, d.x))).length < 1e-9)
    }

    @Test func trackBackwardStopsWhereTheObjectIsLost() async throws {
        let (m, id, _) = rig()
        let n = try await m.trackMask(id, forward: false, tracker: FakeTracker(lostAfter: 1))
        #expect(n == 2)
        #expect(m.clip!.mask(id)!.path.track.keys.map(\.time).sorted() == [Time(1, 2), Time(1, 1)])
    }

    /// Fails with a cancellation on its `cancelOnCall`-th call (1-based); earlier calls follow the object like FakeTracker.
    final class CancellingTracker: MaskTracking, @unchecked Sendable {
        var calls = 0
        let cancelOnCall: Int
        init(cancelOnCall: Int) { self.cancelOnCall = cancelOnCall }
        func track(region: [Vec2], mode: MaskTrackMode, sourceTimes: [Time],
                   progress: (@Sendable (Double) -> Void)?) async throws -> [MaskMotion?] {
            calls += 1
            if calls == cancelOnCall { throw CancellationError() }
            return sourceTimes.indices.map { MaskMotion(translation: Vec2(0.001 * Double($0), 0)) }
        }
    }

    @Test func stoppingATrackKeepsTheFramesDoneSoFar() async throws {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(200, 1)), start: .zero)
        let mask = ClipMask.make(.rectangle, name: "Mask (1)")
        clip.masks = [mask]
        let m = EffectControlsModel(); let log = Log()
        m.onEdit = { c, n, co in log.edits.append((c, n, co)) }
        m.setClip(clip); m.playhead = .zero
        m.frameDuration = Time(1, 2)
        let tracker = CancellingTracker(cancelOnCall: 2)
        do {
            _ = try await m.trackMask(mask.id, forward: true, tracker: tracker)
            Issue.record("expected a stop")
        } catch let stop as MaskTrackStopped {
            #expect(stop.frames == EffectControlsModel.trackChunk)
        }
        #expect(m.clip!.mask(mask.id)!.path.track.keys.count == EffectControlsModel.trackChunk)
        #expect(log.edits.count == 1 && log.edits[0].1 == "Track Mask")
    }

    /// A run that lost its slot (its mask was removed and came back by undo, another run started) writes no undo step.
    @Test func aTrackThatLostItsSlotWritesNothing() async throws {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(200, 1)), start: .zero)
        let mask = ClipMask.make(.rectangle, name: "Mask (1)")
        clip.masks = [mask]
        let m = EffectControlsModel(); let log = Log()
        m.onEdit = { c, n, co in log.edits.append((c, n, co)) }
        m.setClip(clip); m.playhead = .zero
        m.frameDuration = Time(1, 2)
        do {
            _ = try await m.trackMask(mask.id, forward: true, tracker: CancellingTracker(cancelOnCall: 2), mayWrite: { false })
            Issue.record("expected a stop")
        } catch let stop as MaskTrackStopped {
            #expect(stop.frames == 0)
        }
        #expect(m.clip!.mask(mask.id)!.path.track.keys.isEmpty && log.edits.isEmpty)
        // A run that ended by itself after its slot went to another run: the same.
        let n = try await m.trackMask(mask.id, forward: true, tracker: CancellingTracker(cancelOnCall: 99), mayWrite: { false })
        #expect(n == 0 && log.edits.isEmpty)
    }

    /// A long stretch (several chunks) whose object is lost inside the first chunk keeps the frames tracked up to there.
    @Test func aTrackLostInsideALongStretchKeepsTheTrackedPart() async throws {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(200, 1)), start: .zero)
        let mask = ClipMask.make(.rectangle, name: "Mask (1)")
        clip.masks = [mask]
        let m = EffectControlsModel(); let log = Log()
        m.onEdit = { c, n, co in log.edits.append((c, n, co)) }
        m.setClip(clip); m.playhead = .zero
        m.frameDuration = Time(1, 2)
        let n = try await m.trackMask(mask.id, forward: true, tracker: FakeTracker(dx: 0.001, lostAfter: 30))
        #expect(n == 31)
        #expect(m.clip!.mask(mask.id)!.path.track.keys.count == 31)
        #expect(log.edits.count == 1 && log.edits[0].1 == "Track Mask")
    }

    @Test func aFinishedTrackIsAppliedToItsClipEvenWhenAnotherClipIsShown() async throws {
        let (m, id, log) = rig()
        let tracked = m.clip!
        let other = Clip(name: "o", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(5, 1))
        final class Slow: MaskTracking, @unchecked Sendable {
            let onRun: @Sendable () -> Void
            init(_ f: @escaping @Sendable () -> Void) { onRun = f }
            func track(region: [Vec2], mode: MaskTrackMode, sourceTimes: [Time],
                       progress: (@Sendable (Double) -> Void)?) async throws -> [MaskMotion?] {
                onRun()
                return sourceTimes.indices.map { MaskMotion(translation: Vec2(0.1 * Double($0), 0)) }
            }
        }
        let n = try await m.trackMask(id, forward: true, tracker: Slow { Task { @MainActor in m.setClip(other) } },
                                      clipByID: { $0 == tracked.id ? tracked : nil })
        #expect(n == 2)
        #expect(log.edits.count == 1 && log.edits[0].0.id == tracked.id && log.edits[0].0.mask(id)!.path.track.keys.count == 2)
        #expect(m.clip?.id == other.id)
    }

    @Test func trackNeedsThePlayheadInTheClipAndAPathMask() async throws {
        let (m, id, log) = rig()
        m.playhead = Time(20, 1)
        #expect(try await m.trackMask(id, forward: true, tracker: FakeTracker()) == 0)
        #expect(log.edits.isEmpty)
    }

    @Test func hitTestsTangentsAndSegments() throws {
        let g = MaskOverlayGeometry(quad: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)])
        var e = MaskOverlay(id: UUID(), path: .ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.25, 0.25)))
        e.active = true
        let out = e.path.vertices[0].point + e.path.vertices[0].outTangent
        let hit = try #require(g.hitTangent(g.viewPoint(out), masks: [e]))
        #expect(hit.mask == 0 && hit.vertex == 0 && hit.out)
        e.active = false
        #expect(g.hitTangent(g.viewPoint(out), masks: [e]) == nil)
        var r = MaskOverlay(id: UUID(), path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))
        #expect(g.hitSegment(CGPoint(x: 50, y: 21), masks: [r]) == nil && g.hitInside(CGPoint(x: 50, y: 50), masks: [r]) == nil)
        r.active = true
        let seg = try #require(g.hitSegment(CGPoint(x: 50, y: 21), masks: [r]))
        #expect(seg.mask == 0 && seg.segment == 0 && abs(seg.t - 0.5) < 0.02)
        #expect(g.hitSegment(CGPoint(x: 50, y: 50), masks: [r]) == nil)
        #expect(g.hitInside(CGPoint(x: 50, y: 50), masks: [r]) == 0)
        #expect(g.hitInside(CGPoint(x: 5, y: 5), masks: [r]) == nil)
    }
}

import Foundation
import Testing
@testable import SQCore

// FB-G: Move, Zoom and Pop are element transitions. They sit on one clip edge (head = In, tail = Out), animate the clip
// itself on its transform stage for exactly the transition's span, and are at rest outside it. The old Motion effects of
// the same name are no longer offered but keep playing in old projects.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private let canvas = SequenceFormat(width: 640, height: 360, frameDuration: fd)

private func clip(_ name: String, start: Int64, frames: Int64 = 60) -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(frames)), start: f(start),
         mediaDuration: f(300))
}

/// A at 0..60 and B at 60..120, touching, on one video track.
private func timeline() throws -> (Timeline, Clip, Clip) {
    let a = clip("A", start: 0), b = clip("B", start: 60)
    var t = Track(kind: .video)
    try t.overwrite(a); try t.overwrite(b)
    return (Timeline(name: "t", format: canvas, tracks: [t]), a, b)
}

private func layer(_ t: Timeline, at frame: Int64) -> LayerRequest { t.videoLayers(at: f(frame))[0] }
private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

@Suite struct ElementTransitionKindTests {
    @Test func moveZoomPopAreOneSidedVideoTransitions() {
        for k in TransitionKind.elementKinds {
            #expect(k.isElement && k.trackKind == .video, "\(k)")
            #expect(!k.isMotion, "drawn on the clip's own transform, not by the transition node")
            #expect(k.usesMotionBlur && !k.usesEasing && !k.usesDirection, "\(k)")
            #expect(k.elementEffectKind != nil)
        }
        #expect(TransitionKind.elementKinds.map(\.name) == ["Move", "Zoom", "Pop"])
        #expect(!TransitionKind.crossDissolve.isElement && !TransitionKind.slide.isElement)
    }

    @Test func paramsComeFromTheMotionEffectWithoutModeOrDuration() {
        let keys = TransitionKind.move.elementParams.map(\.key)
        #expect(keys.contains(ClipEffect.moveDirectionKey) && keys.contains(ClipEffect.motionCurveKey))
        #expect(!keys.contains(ClipEffect.motionModeKey) && !keys.contains(ClipEffect.motionDurationKey)
                && !keys.contains(ClipEffect.motionOutDurationKey))
        #expect(!TransitionKind.pop.elementParams.map(\.key).contains(ClipEffect.popSettleKey), "a pop settles at 100 %")
        #expect(TransitionKind.crossDissolve.elementParams.isEmpty)
    }

    @Test func theOldMotionEffectsAreNoLongerOfferedButStillKnown() {
        for k in [ClipEffect.moveKind, ClipEffect.zoomKind, ClipEffect.popKind, ClipEffect.fadeKind] {
            #expect(!EffectCatalog.all.contains { $0.kind == k }, "\(k) only exists as a transition now")
            #expect(EffectCatalog.spec(for: k) != nil, "\(k) still opens and plays in old projects")
        }
        for k in [ClipEffect.shakeKind, ClipEffect.bounceKind, ClipEffect.pulseKind, ClipEffect.wiggleKind] {
            #expect(EffectCatalog.all.contains { $0.kind == k }, "\(k) is continuous, it stays an effect")
        }
    }
}

@Suite struct ElementTransitionEditTests {
    @Test func goesOnAClipEdgeNotOnACut() throws {
        var (t, a, b) = try timeline()
        let tid = t.tracks[0].id
        #expect(throws: EditError.notACut) {
            try t.addTransition(kind: .move, track: tid, outgoing: a.id, incoming: b.id, duration: f(15))
        }
        // The head of B even though A touches it: the edge of the clip, not the cut.
        let id = try t.addTransition(point: .head(b.id), kind: .move, track: tid, duration: f(15))
        let r = try #require(t.resolvedTransitions(on: tid).first { $0.id == id })
        #expect(r.span == TimeRange(start: f(60), duration: f(15)))
    }

    @Test func coexistsWithTheCutTransitionOnThatEdge() throws {
        var (t, a, b) = try timeline()
        let tid = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tid, outgoing: a.id, incoming: b.id, duration: f(10))
        try t.addTransition(point: .head(b.id), kind: .zoom, track: tid, duration: f(15))
        try t.addTransition(point: .tail(a.id), kind: .move, track: tid, duration: f(15))
        #expect(t.tracks[0].transitions.map(\.kind) == [.crossDissolve, .zoom, .move], "no second picture: nothing to replace")
        // And the other way round: a cut transition leaves the element ones alone, only replaces its own class.
        try t.addTransition(kind: .dipToBlack, track: tid, outgoing: a.id, incoming: b.id, duration: f(10))
        #expect(t.tracks[0].transitions.map(\.kind) == [.zoom, .move, .dipToBlack])
        try t.addTransition(point: .head(b.id), kind: .pop, track: tid, duration: f(15))
        #expect(t.tracks[0].transitions.map(\.kind) == [.move, .dipToBlack, .pop], "same class, same edge: replaced")
        // Both play: the dip mixes A and B, B pops in on top of it.
        let l = try #require(t.videoLayers(at: f(62)).first { $0.clip == b.id })
        #expect(l.inTransition)
        #expect(!close(l.transform.scale.x, 1))
    }

    @Test func elementAndCutTransitionsDoNotShareTheClipBudget() throws {
        var (t, _, b) = try timeline()
        let tid = t.tracks[0].id
        try t.addTransition(point: .head(b.id), kind: .zoom, track: tid, duration: f(45))
        let dissolve = try t.addTransition(point: .tail(b.id), kind: .crossDissolve, track: tid, duration: f(30))
        #expect(t.resolvedTransitions(on: tid).first { $0.id == dissolve }?.frames == 30, "the Zoom does not eat B's frames")
        let out = try t.addTransition(point: .tail(b.id), kind: .move, track: tid, duration: f(30))
        #expect(t.resolvedTransitions(on: tid).first { $0.id == out }?.frames == 15, "two elements share B's 60 frames")
    }

    @Test func bothEndsOfAShortClipFitHalfEach() throws {
        let short = clip("S", start: 0, frames: 20), tiny = clip("T", start: 100, frames: 1)
        var tr = Track(kind: .video)
        try tr.overwrite(short); try tr.overwrite(tiny)
        var t = Timeline(name: "t", format: canvas, tracks: [tr])
        let tid = t.tracks[0].id
        let ids = try t.addElementTransitions(kind: .move, track: tid, clip: short.id, edges: [.head, .tail], duration: f(15))
        #expect(ids.count == 2)
        #expect(t.resolvedTransitions(on: tid).filter { ids.contains($0.id) }.map(\.frames) == [10, 10])
        // One frame: the head gets it, the tail is skipped instead of failing the whole drop.
        let one = try t.addElementTransitions(kind: .move, track: tid, clip: tiny.id, edges: [.head, .tail], duration: f(15))
        #expect(one.count == 1)
        // A long clip keeps the full length on both ends.
        var (long, _, b) = try timeline()
        let both = try long.addElementTransitions(kind: .pop, track: long.tracks[0].id, clip: b.id, edges: [.head, .tail], duration: f(15))
        #expect(long.resolvedTransitions(on: long.tracks[0].id).filter { both.contains($0.id) }.map(\.frames) == [15, 15])
        #expect(Timeline.elementDuration(f(15), clipDuration: f(20), bothEnds: true, frameDuration: fd) == f(10))
        #expect(Timeline.elementDuration(f(15), clipDuration: f(20), bothEnds: false, frameDuration: fd) == f(15))
    }

    @Test func motionBlurIsCappedAtWhatRenders() throws {
        var (t, _, b) = try timeline()
        let id = try t.addTransition(point: .head(b.id), kind: .move, track: t.tracks[0].id, duration: f(15))
        try t.setTransition(id, motionBlur: 3)
        #expect(t.transition(id)?.transition.effectiveMotionBlur == 1, "one frame = a 360 degree shutter")
    }

    @Test func aCutTransitionCannotBecomeAnElement() throws {
        var (t, a, b) = try timeline()
        let tid = t.tracks[0].id
        let id = try t.addTransition(kind: .crossDissolve, track: tid, outgoing: a.id, incoming: b.id, duration: f(10))
        #expect(throws: EditError.notACut) { try t.setTransition(id, kind: .pop) }
        let head = try t.addTransition(point: .tail(b.id), kind: .crossDissolve, track: tid, duration: f(10))
        try t.setTransition(head, kind: .pop)
        #expect(t.transition(head)?.transition.kind == .pop)
    }

    @Test func paramsAreClampedAndMerged() throws {
        var (t, _, b) = try timeline()
        let id = try t.addTransition(point: .head(b.id), kind: .move, track: t.tracks[0].id, duration: f(15))
        try t.setTransition(id, params: [ClipEffect.moveDirectionKey: 90])
        try t.setTransition(id, params: [ClipEffect.moveDistanceKey: 50_000])
        let tr = try #require(t.transition(id)?.transition)
        #expect(tr.param(ClipEffect.moveDirectionKey) == 90)
        #expect(tr.param(ClipEffect.moveDistanceKey) == 1_000)
        #expect(tr.param(ClipEffect.moveRotationKey) == 0, "unset = the effect's default")
        #expect(throws: EditError.self) { try t.setTransition(id, params: ["nonsense": 1]) }
    }
}

@Suite struct ElementTransitionRenderTests {
    @Test func moveInComesFromTheLeftAndRestsAfterItsSpan() throws {
        var (t, _, b) = try timeline()
        let id = try t.addTransition(point: .head(b.id), kind: .move, track: t.tracks[0].id, duration: f(15))
        try t.setTransition(id, params: [ClipEffect.moveDirectionKey: 270, ClipEffect.moveDistanceKey: 100,
                                         ClipEffect.motionCurveKey: Double(MotionCurve.linear.rawValue)])
        #expect(close(layer(t, at: 60).transform.position.x, -640))           // first frame: a whole frame to the left
        #expect(close(layer(t, at: 60).transform.position.y, 0))
        let mid = layer(t, at: 60 + 7).transform.position.x
        #expect(mid < 0 && mid > -640)
        #expect(layer(t, at: 75).transform == b.transform(at: f(75)))          // span over: at rest
        #expect(layer(t, at: 30).transform == ClipTransform.identity, "A is untouched")
    }

    @Test func moveOutLeavesAtTheTail() throws {
        var (t, a, _) = try timeline()
        try t.addTransition(point: .tail(a.id), kind: .move, track: t.tracks[0].id, duration: f(10))
        #expect(layer(t, at: 49).transform == a.transform(at: f(49)))          // before the span
        #expect(layer(t, at: 59).transform.position.x < -500)                   // nearly gone on the last frame
    }

    @Test func zoomScalesFromTheEdgeValueToRestAndBack() throws {
        var (t, a, b) = try timeline()
        let tid = t.tracks[0].id
        let head = try t.addTransition(point: .head(b.id), kind: .zoom, track: tid, duration: f(15))
        try t.setTransition(head, params: [ClipEffect.zoomFromKey: 150])
        #expect(close(layer(t, at: 60).transform.scale.x, 1.5))
        #expect(close(layer(t, at: 80).transform.scale.x, 1))
        let tail = try t.addTransition(point: .tail(a.id), kind: .zoom, track: tid, duration: f(15))
        try t.setTransition(tail, params: [ClipEffect.zoomFromKey: 80])
        #expect(close(layer(t, at: 40).transform.scale.x, 1))
        let end = layer(t, at: 59).transform.scale.x
        #expect(end < 0.85 && end >= 0.8)
    }

    @Test func popSettlesAtHundredPercent() throws {
        var (t, _, b) = try timeline()
        try t.addTransition(point: .head(b.id), kind: .pop, track: t.tracks[0].id, duration: f(15))
        #expect(close(layer(t, at: 60).transform.scale.x, 0.9))
        #expect(close(layer(t, at: 90).transform.scale.x, 1))
    }

    @Test func inAndOutOnOneClipBothPlay() throws {
        var (t, _, b) = try timeline()
        let tid = t.tracks[0].id
        try t.addTransition(point: .head(b.id), kind: .move, track: tid, duration: f(10))
        try t.addTransition(point: .tail(b.id), kind: .move, track: tid, duration: f(10))
        #expect(t.tracks[0].transitions.count == 2)
        #expect(layer(t, at: 60).transform.position.x < -500)
        #expect(layer(t, at: 90).transform == b.transform(at: f(90)))
        #expect(layer(t, at: 119).transform.position.x < -500, "Direction is where it comes from and where it goes")
    }

    @Test func spanFollowsTheDuration() throws {
        var (t, _, b) = try timeline()
        let id = try t.addTransition(point: .head(b.id), kind: .move, track: t.tracks[0].id, duration: f(10))
        #expect(layer(t, at: 72).transform == b.transform(at: f(72)))
        try t.setTransition(id, duration: f(20))
        #expect(layer(t, at: 72).transform != b.transform(at: f(72)))
    }

    @Test func noMixingStateAndFullOpacity() throws {
        var (t, _, b) = try timeline()
        try t.addTransition(point: .head(b.id), kind: .pop, track: t.tracks[0].id, duration: f(15))
        let l = layer(t, at: 62)
        #expect(l.pair == nil && !l.inTransition)
        #expect(l.transform.opacity == 1)
        #expect(t.videoLayers(at: f(62)).count == 1)
    }

    @Test func motionBlurOpensTheShutterOnlyWhileItMoves() throws {
        var (t, _, b) = try timeline()
        let id = try t.addTransition(point: .head(b.id), kind: .move, track: t.tracks[0].id, duration: f(15))
        #expect(layer(t, at: 65).motionBlur == nil, "no blur by default")
        try t.setTransition(id, motionBlur: 0.5)
        let mb = try #require(layer(t, at: 65).motionBlur)
        #expect(mb.transforms.count == EffectTransformStage.sampleCount(shutterAngle: 180))
        #expect(layer(t, at: 100).motionBlur == nil)
    }

    @Test func fadeEndsWithTheSpanSoNothingJumps() throws {
        var (t, _, b) = try timeline()
        let id = try t.addTransition(point: .head(b.id), kind: .move, track: t.tracks[0].id, duration: f(5))
        try t.setTransition(id, params: [ClipEffect.moveFadeKey: 1, ClipEffect.moveFadeLengthKey: 0.5])
        #expect(layer(t, at: 60).transform.opacity < 0.05)
        #expect(layer(t, at: 64).transform.opacity >= 0.75, "the fade fits the 5-frame span")
        #expect(layer(t, at: 65).transform.opacity == 1)
        let (t2, a2, _) = try timeline()
        var tail = t2
        let out = try tail.addTransition(point: .tail(a2.id), kind: .move, track: tail.tracks[0].id, duration: f(5))
        try tail.setTransition(out, params: [ClipEffect.moveFadeKey: 1, ClipEffect.moveFadeLengthKey: 0.5])
        #expect(layer(tail, at: 54).transform.opacity == 1)
        #expect(layer(tail, at: 55).transform.opacity > 0.75, "starts with the span, not 0.5 s before the end")
    }

    @Test func longSpansPlayOverTheirWholeLength() throws {
        // 100 s clip, 90 s Move: the old effect clamped Duration to 60 s, so an Out started late and an In ended early.
        let long = Clip(name: "L", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(3000)), start: .zero,
                        mediaDuration: f(3000))
        var tr = Track(kind: .video)
        try tr.overwrite(long)
        var t = Timeline(name: "t", format: canvas, tracks: [tr])
        let tid = t.tracks[0].id
        let linear = [ClipEffect.motionCurveKey: Double(MotionCurve.linear.rawValue), ClipEffect.moveDirectionKey: 270]
        let out = try t.addTransition(point: .tail(long.id), kind: .move, track: tid, duration: f(2700))
        try t.setTransition(out, params: linear)
        #expect(close(layer(t, at: 300 + 1350).transform.position.x, -320, 1), "half way through the 90 s Out")
        try t.removeTransition(out)
        let inn = try t.addTransition(point: .head(long.id), kind: .move, track: tid, duration: f(2700))
        try t.setTransition(inn, params: linear)
        #expect(close(layer(t, at: 1350).transform.position.x, -320, 1), "half way through the 90 s In")
    }

    @Test func theStoredClipKeepsItsEffects() throws {
        var (t, _, b) = try timeline()
        try t.addTransition(point: .head(b.id), kind: .move, track: t.tracks[0].id, duration: f(15))
        #expect(t.tracks[0].clips[1].effects.isEmpty)
        #expect(t.tracks[0].clipWithElementTransitions(t.tracks[0].clips[1], at: f(62), frameDuration: fd).effects.count == 1)
        #expect(t.tracks[0].clipWithElementTransitions(t.tracks[0].clips[1], at: f(100), frameDuration: fd).effects.isEmpty)
    }
}

@Suite struct ElementTransitionFileTests {
    @Test func roundTripsAndIsWrittenAsV40() throws {
        var (t, _, b) = try timeline()
        let id = try t.addTransition(point: .head(b.id), kind: .zoom, track: t.tracks[0].id, duration: f(15))
        try t.setTransition(id, params: [ClipEffect.zoomFromKey: 140])
        let p = Project(name: "P", timelines: [t])
        #expect(p.containsElementTransitions)
        let data = try ProjectFile.encode(p)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == ProjectFile.elementTransitionVersion)
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        #expect(back == p)
        #expect(back.timelines[0].transition(id)?.transition.param(ClipEffect.zoomFromKey) == 140)
    }

    @Test func plainProjectsKeepTheLowerVersion() throws {
        let (t, _, _) = try timeline()
        #expect(!Project(name: "P", timelines: [t]).containsElementTransitions)
        #expect(ProjectFile.writtenVersion(for: Project(name: "P", timelines: [t])) < ProjectFile.elementTransitionVersion)
    }

    @Test func presetReplacesTheParamsOfTheSameKind() throws {
        var (t, _, b) = try timeline()
        let tid = t.tracks[0].id
        let id = try t.addTransition(point: .head(b.id), kind: .move, track: tid, duration: f(12))
        try t.setTransition(id, params: [ClipEffect.moveRotationKey: 45, ClipEffect.moveDistanceKey: 20])
        try t.applyTransitionPreset(TransitionPreset(kind: .move, duration: f(12), params: [ClipEffect.moveDirectionKey: 90]), to: id)
        var tr = try #require(t.transition(id)?.transition)
        #expect(tr.param(ClipEffect.moveDirectionKey) == 90)
        #expect(tr.param(ClipEffect.moveRotationKey) == 0 && tr.param(ClipEffect.moveDistanceKey) == 100, "the saved look, not a merge")
        try t.applyTransitionPreset(TransitionPreset(kind: .move, duration: f(12)), to: id)
        tr = try #require(t.transition(id)?.transition)
        #expect(tr.params == nil, "a preset without params is the default look")
    }

    @Test func presetKeepsTheParams() throws {
        var (t, a, b) = try timeline()
        let tid = t.tracks[0].id
        let id = try t.addTransition(point: .head(b.id), kind: .move, track: tid, duration: f(12))
        try t.setTransition(id, params: [ClipEffect.moveDirectionKey: 90, ClipEffect.moveRotationKey: 30])
        let preset = TransitionPreset.capture(from: try #require(t.transition(id)?.transition))
        let back = try TransitionPreset(payload: try preset.payload(), version: TransitionPreset.payloadVersion)
        let other = try t.addTransition(preset: back, point: .tail(a.id), track: tid)
        let tr = try #require(t.transition(other)?.transition)
        #expect(tr.kind == .move && tr.param(ClipEffect.moveRotationKey) == 30 && tr.param(ClipEffect.moveDirectionKey) == 90)
    }

    @Test func oldMoveEffectStillPlays() {
        var c = clip("C", start: 0)
        c.effects = MotionRecipes.moveFrom(.left)
        let t = Timeline(name: "t", format: canvas, tracks: [Track(kind: .video, clips: [c])])
        #expect(t.videoLayers(at: .zero)[0].transform.position.x < -600)
    }
}

import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

// Transition feel defaults (DECISIONS 2026-10-06): what the user adds starts with the factory look; a user default, a
// preset and everything already in the project keep theirs.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private func clip(_ start: Int64) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: .video, source: TimeRange(start: f(60), duration: f(90)), start: f(start), mediaDuration: f(600))
}

@MainActor private func makeSession() throws -> (EditorSession, Track.ID, [Clip]) {
    var v = Track(kind: .video, name: "V1")
    let cs = [clip(0), clip(90), clip(180)]
    for c in cs { try v.overwrite(c) }
    let t = Timeline(name: "Main", frameDuration: fd, tracks: [v, Track(kind: .video, name: "V2")])
    return (EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine()), v.id, cs)
}

@MainActor @Suite struct TransitionFeelUITests {
    @Test func aDroppedTransitionStartsWithTheFactoryLookAndLength() throws {
        let (ses, v, cs) = try makeSession()
        let push = try #require(ses.addTransition(kind: .push, track: v, point: .cut(outgoing: cs[0].id, incoming: cs[1].id), alignment: .center))
        var tr = try #require(ses.activeTimeline?.transition(push)?.transition)
        #expect(tr.easing == .easeOut100 && tr.duration == f(24))
        let zoom = try #require(ses.addTransition(kind: .zoomIn, track: v, point: .cut(outgoing: cs[1].id, incoming: cs[2].id), alignment: .center))
        tr = try #require(ses.activeTimeline?.transition(zoom)?.transition)
        #expect(tr.zoomAmount == 1.1 && tr.duration == f(21))
        // One undo step each.
        ses.undo()
        #expect(ses.activeTimeline?.transition(zoom) == nil && ses.activeTimeline?.transition(push) != nil)
    }

    @Test func everyPathGivesTheSameLengthPerKind() throws {
        // Drag (addTransition) and Shift+D / double-click / palette (applyDefaultTransitions) share one factory length.
        for kind in [TransitionKind.quickFade, .push, .slide, .whip, .crossDissolve] {
            let (a, v, cs) = try makeSession()
            let drag = try #require(a.addTransition(kind: kind, track: v, point: .cut(outgoing: cs[0].id, incoming: cs[1].id), alignment: .center))
            let dragLen = try #require(a.activeTimeline?.transition(drag)?.transition).duration
            let (b, _, cs2) = try makeSession()
            b.select(clips: [cs2[1].id])
            #expect(b.applyDefaultTransitions(scope: .video, edges: nil, kind: kind) > 0)
            let lens = Set(b.activeTimeline!.tracks[0].transitions.map(\.duration))
            #expect(lens == [dragLen], "\(kind)")
        }
    }

    @Test func theDefaultTransitionCommandGivesASoftDissolve() throws {
        let (ses, _, cs) = try makeSession()
        ses.select(clips: [cs[1].id])
        #expect(ses.applyDefaultTransitions(scope: .video, edges: nil) > 0)
        let all = ses.activeTimeline!.tracks[0].transitions
        #expect(!all.isEmpty && all.allSatisfy { $0.kind == .crossDissolve && $0.easing == .easeInOut })
    }

    @Test func elementTransitionsArriveSettlingAndLeaveAccelerating() throws {
        let (ses, v, cs) = try makeSession()
        let made = ses.addElementTransition(kind: .move, track: v, clip: cs[1].id, edges: [.head, .tail])
        #expect(made.count == 2)
        let head = try #require(ses.activeTimeline?.transition(made[0])?.transition), tail = try #require(ses.activeTimeline?.transition(made[1])?.transition)
        #expect(head.param(ClipEffect.motionCurveKey) == Double(MotionCurve.easeOut100.rawValue))
        #expect(tail.param(ClipEffect.motionCurveKey) == Double(MotionCurve.easeIn100.rawValue))
        #expect(head.duration == f(24))
    }

    @Test func aUserDefaultWinsOverTheFactoryLook() throws {
        let (ses, v, cs) = try makeSession()
        // A default saved from a transition as an older build made it (no own curve): Slide's "Smooth In".
        var d = EffectDefaults()
        d.setDefault(from: Transition(kind: .slide, duration: f(25), outgoing: nil, incoming: UUID()))
        ses.effectDefaults = d
        let id = try #require(ses.addTransition(kind: .slide, track: v, point: .cut(outgoing: cs[0].id, incoming: cs[1].id), alignment: .center))
        let tr = try #require(ses.activeTimeline?.transition(id)?.transition)
        #expect(tr.effectiveEasing == .easeIn && tr.duration == f(25))
        ses.setTransitionStyle(id, easing: .linear, direction: nil)
        #expect(ses.resetTransition(id))
        #expect(ses.activeTimeline?.transition(id)?.transition.effectiveEasing == .easeIn)
    }

    @Test func changingTheKindOrResettingGivesTheFactoryLook() throws {
        let (ses, v, cs) = try makeSession()
        let id = try #require(ses.addTransition(kind: .push, track: v, point: .cut(outgoing: cs[0].id, incoming: cs[1].id), alignment: .center))
        ses.setTransition(id, kind: .spin)
        #expect(ses.activeTimeline?.transition(id)?.transition.easing == .overshoot)
        ses.setTransition(id, kind: .zoomOut)
        #expect(ses.activeTimeline?.transition(id)?.transition.params == ["amount": 110])
        ses.setTransitionParams(id, ["amount": 140])
        #expect(ses.activeTimeline?.transition(id)?.transition.zoomAmount == 1.4)
        #expect(ses.resetTransition(id))
        #expect(ses.activeTimeline?.transition(id)?.transition.zoomAmount == 1.1)
    }

    @Test func zoomShowsItsAmountInTheTransitionControls() throws {
        let (ses, v, cs) = try makeSession()
        let id = try #require(ses.addTransition(kind: .zoomIn, track: v, point: .cut(outgoing: cs[0].id, incoming: cs[1].id), alignment: .center))
        let view = TransitionControlsView()
        var edits: [(String, Double)] = []
        view.onElementParam = { edits.append(($0, $1)) }
        let info = try #require(ses.transitionInfo(id))
        view.update(transition: info.transition, resolved: info.resolved, frameDuration: fd)
        let field = try #require(findView(in: view, id: "amount") as? ScrubField)
        #expect(field.value == 110 && field.range == 100...200 && field.unit == "%")
        field.onEnd?(125)
        #expect(edits.count == 1 && edits[0].0 == "amount" && edits[0].1 == 125)
        // Dragging reports every value live; the release adds nothing (one undo step through continuesGesture).
        var live: [(Double, Bool)] = []
        view.onElementParamLive = { _, v, c in live.append((v, c)) }
        edits.removeAll()
        field.onBegin?(); field.onChange?(120); field.onChange?(130); field.onEnd?(130)
        #expect(live.map(\.0) == [120, 130] && live.map(\.1) == [false, true] && edits.isEmpty)
        // The factory curve of a move has a name in the Curve pop-up.
        let push = try #require(ses.addTransition(kind: .push, track: v, point: .cut(outgoing: cs[1].id, incoming: cs[2].id), alignment: .center))
        let pi = try #require(ses.transitionInfo(push))
        view.update(transition: pi.transition, resolved: pi.resolved, frameDuration: fd)
        #expect(view.easingTitleForTests == EaseName.smoothIn100)
        #expect(findView(in: view, id: "amount") == nil || (findView(in: view, id: "amount")?.isHiddenOrHasHiddenAncestor ?? true))
    }

    @Test func aTransitionLayerGetsTheLookAndItsAmount() throws {
        let (ses, _, _) = try makeSession()
        let v2 = ses.activeTimeline!.tracks[1].id
        let id = try #require(ses.addTransitionLayer(kind: .zoomIn, track: v2, start: f(80), duration: f(21), cut: f(90)))
        var info = try #require(ses.transitionLayerInfo(id))
        #expect(info.transition.params == ["amount": 110] && info.resolved.zoomAmount == 1.1)
        #expect(ses.setTransitionLayerParam(id, "amount", 150))
        info = try #require(ses.transitionLayerInfo(id))
        #expect(info.transition.param("amount") == 150 && info.resolved.zoomAmount == 1.5)
        #expect(ses.setTransitionLayerKind(id, .push))
        info = try #require(ses.transitionLayerInfo(id))
        #expect(info.transition.params == nil && info.transition.easing == nil, "an edited Amount is not the factory look")
        let fresh = try #require(ses.addTransitionLayer(kind: .zoomOut, track: v2, start: f(120), duration: f(21), cut: f(130)))
        #expect(ses.setTransitionLayerKind(fresh, .push))
        #expect(ses.transitionLayerInfo(fresh)?.transition.easing == .easeOut100)
    }

    @Test func scrubbingAmountIsOneUndoStep() throws {
        let (ses, v, cs) = try makeSession()
        let id = try #require(ses.addTransition(kind: .zoomIn, track: v, point: .cut(outgoing: cs[0].id, incoming: cs[1].id), alignment: .center))
        let depth = ses.undoDepth
        ses.setTransitionParams(id, ["amount": 120])
        ses.setTransitionParams(id, ["amount": 130], continuesGesture: true)
        ses.setTransitionParams(id, ["amount": 140], continuesGesture: true)
        #expect(ses.undoDepth == depth + 1)
        ses.undo()
        #expect(ses.activeTimeline?.transition(id)?.transition.zoomAmount == 1.1)
        let v2 = ses.activeTimeline!.tracks[1].id
        let layer = try #require(ses.addTransitionLayer(kind: .zoomIn, track: v2, start: f(80), duration: f(21), cut: f(90)))
        let d2 = ses.undoDepth
        #expect(ses.setTransitionLayerParam(layer, "amount", 120))
        #expect(ses.setTransitionLayerParam(layer, "amount", 150, continuesGesture: true))
        #expect(ses.undoDepth == d2 + 1)
    }
}

@MainActor private func findView(in root: NSView, id: String) -> NSView? {
    if root.identifier?.rawValue == id { return root }
    for s in root.subviews { if let v = findView(in: s, id: id) { return v } }
    return nil
}

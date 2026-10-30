import Foundation
import Testing
import SQCore
import SQDrawKit
import SQUIKit
@testable import SQInspectorUI

// The draw-list transition controls (Windows Controls while a transition is selected) and the shared rules and session
// actions both platforms use.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

@MainActor @Suite struct TransitionControlsDrawTests {
    private func makeSession(_ kind: TransitionKind = .softWipe) throws -> (EditorSession, Transition.ID) {
        var v = Track(kind: .video, name: "V1")
        let a = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(120)), start: .zero, mediaDuration: f(240))
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: f(60), duration: f(120)), start: f(120), mediaDuration: f(240))
        try v.overwrite(a); try v.overwrite(b)
        var t = Timeline(name: "Main", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [v])
        let id = try t.addTransition(kind: kind, track: v.id, outgoing: a.id, incoming: b.id, duration: f(30))
        let ses = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        ses.selectTransition(id)
        return (ses, id)
    }

    private func panel(_ ses: EditorSession) -> TransitionControlsDraw {
        let p = TransitionControlsDraw(actions: TransitionControlsActions(session: ses))
        p.size = CGSize(width: 360, height: 500)
        p.show(p.actions.shown())
        var c = Canvas(width: 360, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
        return p
    }

    private func tr(_ ses: EditorSession, _ id: Transition.ID) throws -> Transition {
        try #require(ses.activeTimeline?.transition(id)?.transition)
    }

    @Test func rowsFollowTheKindAsOnTheMac() throws {
        let (ses, _) = try makeSession()
        let s = try #require(TransitionControlsActions(session: ses).shown())
        let rows = TransitionControlsLogic.rows(s)
        #expect(rows.first == .duration && rows[1] == .alignment)
        #expect(rows.contains(.direction) && rows.contains(.softness) && rows.contains(.border) && rows.contains(.borderColor))
        #expect(!rows.contains(.kind) && !rows.contains(.color) && !rows.contains(.stingerClip))
        var layer = s
        layer.isLayer = true
        let layerRows = TransitionControlsLogic.rows(layer)
        #expect(layerRows.first == .kind && !layerRows.contains(.border))
        #expect(TransitionControlsLogic.subtitle(s) == "Video Transition")
        #expect(TransitionControlsLogic.subtitle(layer) == "Transition Layer · everything below")
        #expect(TransitionControlsLogic.alignmentOptions(s) == [.center, .startAtCut, .endAtCut])
    }

    @Test func nothingShownWithoutASelectedTransition() throws {
        let (ses, _) = try makeSession()
        ses.selectTransition(nil)
        let p = panel(ses)
        #expect(p.shown == nil)
        #expect(p.control(at: CGPoint(x: 120, y: 80)) == nil)
    }

    @Test func softnessTrackDragIsOneUndoStep() throws {
        let (ses, id) = try makeSession()
        let before = try tr(ses, id).effectiveSoftness
        let p = panel(ses)
        let track = p.frame(.track(.softness))
        #expect(track.width > 0)
        p.mouseDown(at: CGPoint(x: track.minX + track.width * 0.2, y: track.midY), clickCount: 1)
        p.mouseDragged(to: CGPoint(x: track.minX + track.width * 0.6, y: track.midY))
        p.mouseDragged(to: CGPoint(x: track.maxX, y: track.midY))
        p.mouseUp(at: CGPoint(x: track.maxX, y: track.midY))
        #expect(abs(try tr(ses, id).effectiveSoftness - 0.5) < 1e-9)
        #expect(ses.undo())
        #expect(abs(try tr(ses, id).effectiveSoftness - before) < 1e-9)
    }

    @Test func typedDurationSetsWholeFrames() throws {
        let (ses, id) = try makeSession()
        let p = panel(ses)
        let field = p.frame(.row(.duration))
        let mid = CGPoint(x: field.midX, y: field.midY)
        p.mouseDown(at: mid, clickCount: 1)
        p.mouseUp(at: mid)
        #expect(p.focused == .duration)
        _ = p.key(.character("a"), modifiers: .command)
        for ch in "15" { _ = p.key(.character(ch), modifiers: []) }
        _ = p.key(.enter, modifiers: [])
        #expect(try tr(ses, id).duration == f(15))
    }

    @Test func directionPopupAndReverseBox() throws {
        let (ses, id) = try makeSession()
        let p = panel(ses)
        var menu: [SQMenuItem] = []
        p.onMenu = { items, _ in menu = items }
        let d = p.frame(.row(.direction))
        p.mouseDown(at: CGPoint(x: d.midX, y: d.midY), clickCount: 1)
        p.mouseUp(at: CGPoint(x: d.midX, y: d.midY))
        #expect(menu.map(\.title) == TransitionDirection.allCases.map { SQL10n.string($0.name) })
        let other = try #require(TransitionDirection.allCases.firstIndex { $0 != (try? tr(ses, id))?.effectiveDirection })
        menu[other].action?()
        #expect(try tr(ses, id).effectiveDirection == TransitionDirection.allCases[other])
        p.show(p.actions.shown())
        let r = p.frame(.reverse)
        p.mouseDown(at: CGPoint(x: r.minX + 4, y: r.midY), clickCount: 1)
        p.mouseUp(at: CGPoint(x: r.minX + 4, y: r.midY))
        #expect(try tr(ses, id).isReversed)
    }

    @Test func easingCustomOpensTheCurvePopover() throws {
        let (ses, id) = try makeSession()
        let p = panel(ses)
        var menu: [SQMenuItem] = []
        var opened: (any EaseCurveSource)?
        p.onMenu = { items, _ in menu = items }
        p.onEaseCurve = { source, _ in opened = source }
        let e = p.frame(.row(.easing))
        p.mouseDown(at: CGPoint(x: e.midX, y: e.midY), clickCount: 1)
        #expect(menu.count == TransitionControlsLogic.easings.count + 1)
        menu.last?.action?()
        #expect((opened as? TransitionEaseSource)?.target == .edge(id))
        // The shown preset's handles become a hand-drawn curve, so Custom never jumps (the Mac `easingPicked`).
        #expect(try tr(ses, id).effectiveEasing.name == "Custom")
    }

    @Test func rightClickOffersTheDefaultMenu() throws {
        let (ses, _) = try makeSession()
        let p = panel(ses)
        var menu: [SQMenuItem] = []
        p.onMenu = { items, _ in menu = items }
        p.mouseDown(at: CGPoint(x: 200, y: 20), clickCount: 1, modifiers: .secondary)
        #expect(menu.first?.title == SQL10n.string("Reset"))
        #expect(menu.contains { $0.title == SQL10n.string("Reset Default to Factory") && !$0.isEnabled })
    }

    @Test func colorWellSessionIsOneUndoStep() throws {
        let (ses, id) = try makeSession(.dipToColour)
        let p = panel(ses)
        var change: (@MainActor (EffectColor?) -> Void)?
        p.onPickColor = { _, _, c in change = c }
        let w = p.frame(.row(.color))
        p.mouseDown(at: CGPoint(x: w.midX, y: w.midY), clickCount: 1)
        change?(EffectColor(red: 1, green: 0, blue: 0, alpha: 1))
        change?(EffectColor(red: 0, green: 0, blue: 1, alpha: 1))
        change?(nil)
        #expect(try tr(ses, id).color == [0, 0, 255])
        #expect(ses.undo())
        #expect(try tr(ses, id).color != [0, 0, 255] && (try tr(ses, id).color) != [255, 0, 0])
    }
}

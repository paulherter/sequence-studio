import AppKit
import Foundation
import Testing
import SQCore
import SQLibrary
@testable import SQInspectorUI
@testable import SQTimelineUI

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}
@MainActor private func makeSession(_ clips: [Clip]) -> EditorSession {
    var t = Track(kind: .video)
    for c in clips { try! t.overwrite(c) }
    return EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: fd, tracks: [t])]),
                         engine: StubProgramEngine())
}
@MainActor private func clipNow(_ session: EditorSession, _ id: Clip.ID) -> Clip {
    session.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }!
}
private let rotate = Keystone(name: "Turn", duration: s(1),
                              rotation: KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: s(1), value: 90.0)]))

@MainActor @Suite struct KeystoneUITests {
    @Test func dropAppliesAtTheGhostSpanAsOneUndoStep() {
        let c = clip(10, 6)
        let session = makeSession([c])
        let span = rotate.placement(dropAt: s(3), clipDuration: c.duration)
        let applied = session.applyKeystone(rotate, to: c.id, span: span)
        #expect(applied == span)
        #expect(clipNow(session, c.id).animation.rotation.track.keys.map(\.time) == [span.start, span.end])
        session.undo()
        #expect(clipNow(session, c.id).animation.rotation.track.isEmpty)
    }

    @Test func effectControlsDropUsesThePlayhead() {
        let c = clip(10, 6)
        let session = makeSession([c])
        session.seek(to: s(14))
        let applied = session.applyKeystone(rotate, to: c.id, span: nil)
        // Centered on clip-local 4 s.
        #expect(applied?.start == Time(7, 2))
    }

    @Test func refusedOnAudioWithAMessage() {
        let a = clip(0, 4, kind: .audio)
        var t = Track(kind: .audio)
        try! t.overwrite(a)
        let session = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "M", frameDuration: fd, tracks: [t])]),
                                    engine: StubProgramEngine())
        #expect(session.applyKeystone(rotate, to: a.id, span: nil) == nil)
        #expect(session.lastError != nil)
    }

    @Test func restretchIsOneUndoStep() {
        let c = clip(0, 6)
        let session = makeSession([c])
        let span = session.applyKeystone(rotate, to: c.id, span: KeystoneSpan(start: s(1), duration: s(1), properties: [.rotation]))!
        let new = KeystoneSpan(start: s(1), duration: s(3), properties: span.properties)
        #expect(session.restretchKeystone(on: c.id, span, to: new))
        #expect(clipNow(session, c.id).animation.rotation.track.keys.map(\.time) == [s(1), s(4)])
        session.undo()
        #expect(clipNow(session, c.id).animation.rotation.track.keys.map(\.time) == [s(1), s(2)])
    }

    @Test func saveFromSelectedClipNeedsKeys() {
        var c = clip(0, 6)
        let session0 = makeSession([c])
        session0.select(clips: [c.id])
        #expect(session0.keystoneFromSelectedClip(name: "x") == nil)
        c.animation.scale.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(1, 1)), Keyframe(time: s(1), value: Vec2(2, 2))])
        let session = makeSession([c])
        session.select(clips: [c.id])
        let k = session.keystoneFromSelectedClip(name: "Zoom")
        #expect(k?.properties == [.scale] && k?.duration == s(1))
    }

    @Test func pasteboardCarriesTheKeystone() {
        let pb = NSPasteboard(name: NSPasteboard.Name("sq.test.keystone.\(UUID().uuidString)"))
        pb.clearContents()
        KeystoneDrag.write(rotate, to: pb)
        #expect(KeystoneDrag.read(from: pb) == rotate)
        pb.clearContents()
        pb.setString("nope", forType: .sequenceKeystone)
        #expect(KeystoneDrag.read(from: pb) == nil)
    }

    @Test func panelModelListsBuiltInsAndUserKeystones() throws {
        let model = KeystonesPanelModel()
        #expect(model.keystones.map(\.id) == Keystone.builtIns.filter { !HiddenCatalog.isHidden(keystone: $0.id) }.map(\.id))
        let mine = try KeystoneLibrary.presetItem(for: rotate)
        model.presets = [mine]
        #expect(model.keystones.last?.name == "Turn")
        #expect(model.canDelete(rotate.id) && !model.canDelete(Keystone.builtIns[0].id))
    }
}

@Suite struct KeystoneBarTests {
    private let span = KeystoneSpan(start: s(1), duration: s(2), properties: [.scale])
    private let frame = Time(1, 30)

    @Test func endEdgeStretchesInsideTheClip() {
        #expect(KeystoneBar.dragged(span, edge: .end, toLocal: s(4), clipDuration: s(6), minimum: frame).end == s(4))
        #expect(KeystoneBar.dragged(span, edge: .end, toLocal: s(9), clipDuration: s(6), minimum: frame).end == s(6))
        // Never shorter than a frame, never across the other edge.
        let short = KeystoneBar.dragged(span, edge: .end, toLocal: .zero, clipDuration: s(6), minimum: frame)
        #expect(short.start == s(1) && short.duration == frame)
    }

    @Test func startEdgeKeepsTheEnd() {
        let r = KeystoneBar.dragged(span, edge: .start, toLocal: Time(-1, 1), clipDuration: s(6), minimum: frame)
        #expect(r.start == .zero && r.end == s(3))
        let r2 = KeystoneBar.dragged(span, edge: .start, toLocal: s(5), clipDuration: s(6), minimum: frame)
        #expect(r2.end == s(3) && r2.duration == frame)
        #expect(r2.properties == span.properties)
    }

    @Test func edgeHitNeedsTheBarRow() {
        let bar = CGRect(x: 100, y: 50, width: 80, height: 10)
        #expect(KeystoneBar.edge(at: CGPoint(x: 102, y: 55), barRect: bar) == .start)
        #expect(KeystoneBar.edge(at: CGPoint(x: 178, y: 55), barRect: bar) == .end)
        #expect(KeystoneBar.edge(at: CGPoint(x: 140, y: 55), barRect: bar) == nil)
        #expect(KeystoneBar.edge(at: CGPoint(x: 102, y: 20), barRect: bar) == nil)
    }
}

@MainActor @Suite struct KeystoneEffectControlsDropTests {
    @Test func effectControlsAcceptsAKeystone() {
        let pb = NSPasteboard(name: NSPasteboard.Name("sq.test.keystone.ec.\(UUID().uuidString)"))
        pb.clearContents()
        let k = Keystone.builtIns[0]
        KeystoneDrag.write(k, to: pb)
        #expect(EffectControlsView.dropPayload(from: pb) == .keystone(k))
    }
}

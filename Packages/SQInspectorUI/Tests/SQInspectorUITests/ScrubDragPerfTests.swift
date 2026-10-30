import AppKit
import Foundation
import SQCore
import Testing
@testable import SQInspectorUI
@testable import SQUIKit

/// K6: a scrub drag in Controls (ScrubField -> model.setValue -> onEdit -> session edit -> session change -> model sync
/// -> panel refresh) measured headless over N drag steps on a mid-size project. The correctness tests (undo step, key
/// value, event coalescing) always run; `measureDrag` is opt-in:
/// `SQ_PERF=1 SQ_TEST_FILTER=ScrubDragPerfTests scripts/test.sh SQEditorUI`.
@MainActor @Suite(.serialized) struct ScrubDragPerfTests {
    static let steps = 120

    /// 6 video tracks x 60 clips plus 4 audio tracks x 60 clips, the dragged clip has the KeyDisplay effects.
    static func project() throws -> (Project, Clip.ID) {
        var tracks: [Track] = []
        var target: Clip.ID?
        for k in 0..<10 {
            var tr = Track(kind: k < 6 ? .video : .audio)
            for i in 0..<60 {
                var c = Clip(name: "c\(k)-\(i)", media: UUID(), kind: tr.kind,
                             source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(Int64(i * 2), 1))
                if k == 0, i == 3 {
                    let rich = KeyDisplayPerfTests.clip()
                    c.animation = rich.animation; c.effects = rich.effects
                    c.animation.rotation = AnimatedProperty(0)      // the dragged property is static
                    target = c.id
                }
                try tr.overwrite(c)
            }
            tracks.append(tr)
        }
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: tracks)
        return (Project(name: "P", timelines: [t]), target!)
    }

    struct Rig {
        let session: EditorSession
        let model: EffectControlsModel
        let view: EffectControlsView
        let field: ScrubField
    }

    /// Wired like the app (`EditorPanels.wireEffectControls` / `sync`): the field drives the model, the model the session,
    /// the session's change goes back to the model.
    static func rig() throws -> Rig {
        let (p, id) = try project()
        let session = EditorSession(project: p, engine: StubProgramEngine(),
                                    autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("sq-scrubperf-\(UUID().uuidString)")))
        let model = EffectControlsModel()
        model.onEdit = { [weak session] c, name, co in session?.replaceDisplayedClip(c, name: name, continuesGesture: co) }
        session.onChange = { [weak session, weak model] change in
            guard let session, let model else { return }
            model.sync(with: session, change: change)
        }
        session.select(clips: [id])
        session.seek(to: Time(7, 1))
        let view = EffectControlsView(model: model)
        view.persistLabelWidth = { _ in }
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        view.layoutSubtreeIfNeeded()
        let f = ScrubField()
        f.value = 0
        f.step = 1
        f.onBegin = { model.beginGesture() }
        f.onChange = { v in model.setValue(.rotation, to: v) }
        f.onEnd = { _ in model.endGesture() }
        return Rig(session: session, model: model, view: view, field: f)
    }

    static func ms(_ body: () -> Void) -> Double {
        let t = ContinuousClock().measure(body)
        return Double(t.components.seconds) * 1000 + Double(t.components.attoseconds) / 1e15
    }

    /// One drag of `steps` pixels with events `eventGap` seconds apart (fake clock: 1 s = every event is handed off, the
    /// pre-K6 behavior). Returns (ms of main-thread work per event, session notifications).
    static func drag(_ r: Rig, eventGap: TimeInterval) -> (perStep: Double, notifies: Int) {
        let clock = FakeFrameClock()
        clock.install(on: r.field.liveCoalescer)
        var notifies = 0
        let old = r.session.onChange
        r.session.onChange = { c in notifies += 1; old?(c) }
        defer { r.session.onChange = old }
        let total = ms {
            r.field.beginDragForTesting()
            var seen = 0
            for _ in 0..<steps {
                r.field.dragForTesting(pixels: 1)
                clock.advance(eventGap)
                // The panel refreshes after each model change (its async hop): count that work like the run loop would.
                if notifies != seen { seen = notifies; r.view.refresh() }
            }
            r.field.endDragForTesting()
        }
        return (total / Double(steps), notifies)
    }

    @Test func oneUndoStepAndFinalValue() throws {
        for gap in [1.0, 1.0 / 120, 1.0 / 1000] {
            let r = try Self.rig()
            #expect(!r.session.canUndo)
            _ = Self.drag(r, eventGap: gap)
            let clip = try #require(r.session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == r.model.clip!.id })
            #expect(clip.animation.rotation.value(atLocal: Time.zero) == Double(Self.steps))
            #expect(r.model.scalarValue(.rotation) == Double(Self.steps))
            #expect(r.session.undo())
            #expect(!r.session.canUndo)          // one drag = one undo step
            #expect(r.session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == clip.id }?
                .animation.rotation.value(atLocal: Time.zero) == 0)
        }
    }

    @Test func keyframedDragEndsOnTheSameKeyValue() throws {
        let r = try Self.rig()
        _ = r.model.toggleKeyAtPlayhead(.rotation)        // animate: the drag writes the key at the playhead
        let undoName = r.session.undoName
        _ = Self.drag(r, eventGap: 1.0 / 240)
        let clip = try #require(r.session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == r.model.clip!.id })
        #expect(clip.animation.rotation.track.keys.count == 1)
        #expect(clip.animation.rotation.track.keys.first?.value == Double(Self.steps))
        #expect(r.session.undo())
        #expect(r.session.undoName == undoName)          // the drag was exactly one step on top of the key
    }

    /// Fake clock, no timing: display-rate and fast-mouse events are coalesced into far fewer session edits.
    @Test func coalescesDisplayRateAndFastMouseEvents() throws {
        let r = try Self.rig()
        let at120 = Self.drag(r, eventGap: 1.0 / 120)     // trackpad / display-rate events
        let at1000 = Self.drag(r, eventGap: 1.0 / 1000)   // fast mouse
        #expect(at120.notifies <= Self.steps / 2 + 2)
        #expect(at1000.notifies <= Self.steps / 16 + 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_PERF"] == "1"))
    func measureDrag() throws {
        let r = try Self.rig()
        _ = Self.drag(r, eventGap: 1)                     // warm-up
        let before = Self.drag(r, eventGap: 1)            // every event handed off (pre-K6)
        let at120 = Self.drag(r, eventGap: 1.0 / 120)     // trackpad / display-rate events
        let at1000 = Self.drag(r, eventGap: 1.0 / 1000)   // fast mouse
        // Pieces: the model alone (no session), the session edit alone, the panel's per-change refresh.
        let m2 = EffectControlsModel(); m2.setClip(r.model.clip); m2.playhead = r.model.playhead
        let modelOnly = Self.ms {
            m2.beginGesture(); for i in 0..<Self.steps { m2.setValue(.rotation, to: Double(i)) }; m2.endGesture()
        } / Double(Self.steps)
        var c = try #require(r.model.clip)
        let sessionOnly = Self.ms {
            for i in 0..<Self.steps {
                c.animation.rotation.value = Double(i)
                r.session.replaceDisplayedClip(c, name: "Rotation", continuesGesture: i > 0)
            }
        } / Double(Self.steps)
        let refresh = Self.ms { for _ in 0..<20 { r.view.refresh() } } / 20
        let line = String(format: "K6 %d-step drag. per event: uncoalesced %.3f ms (%d session edits); 120 Hz %.3f ms (%d); 1000 Hz %.3f ms (%d). "
                          + "Pieces per edit: model %.3f ms, session %.3f ms, panel refresh %.3f ms\n",
                          Self.steps, before.perStep, before.notifies, at120.perStep, at120.notifies, at1000.perStep, at1000.notifies,
                          modelOnly, sessionOnly, refresh)
        if let out = ProcessInfo.processInfo.environment["SQ_K6_OUT"] { try? line.write(toFile: out, atomically: true, encoding: .utf8) }
        #expect(before.perStep < 50 * KeyDisplayPerfTests.allowance)
    }
}

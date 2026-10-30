import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private func clip(_ start: Int64) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(60)), start: f(start), mediaDuration: f(300))
}
private let blur = ClipEffect.gaussianBlurKind
private let k = ClipEffect.blurrinessKey

@MainActor private func makeSession() throws -> (EditorSession, Track.ID, [Clip]) {
    var v = Track(kind: .video, name: "V1")
    let cs = [clip(0), clip(60), clip(120)]
    for c in cs { try v.overwrite(c) }
    let t = Timeline(name: "Main", frameDuration: fd, tracks: [v])
    return (EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine()), v.id, cs)
}

@MainActor @Suite struct EffectDefaultsUITests {
    @Test func useAsDefaultInEffectControlsDrivesNewInstancesAndReset() throws {
        let (ses, _, cs) = try makeSession()
        #expect(ses.addEffect(kind: blur, to: [cs[0].id]))
        let m = EffectControlsModel()
        var stored: EffectDefaults?
        m.onEffectDefaultsChange = { stored = $0; ses.effectDefaults = $0 }
        m.onEdit = { c, name, _ in _ = ses.attempt(name) { try $0.replaceClip(c) } }
        m.setClip(ses.activeTimeline!.tracks[0].clips[0])
        let e = ses.activeTimeline!.tracks[0].clips[0].effects[0]
        let section = EffectSection.effect(e.id, kind: blur)
        let p = EffectProperty.fx(e.id, kind: blur, key: k)
        #expect(m.canUseAsDefault(section) && !m.hasUserDefault(section))
        #expect(m.setValue(p, to: 17))
        #expect(m.useAsDefault(section))
        #expect(m.hasUserDefault(section) && stored?.effect(blur)?.parameters[k]?.value == 17)
        #expect(m.isDefault(p))                                   // 17 is now the default

        // A palette / drag add on another clip goes through the session: starts at 17.
        #expect(ses.addEffect(kind: blur, to: [cs[1].id]))
        #expect(ses.activeTimeline!.tracks[0].clips[1].effects[0].parameters[k]?.value == 17)

        // Reset (section) goes back to the saved default.
        #expect(m.setValue(p, to: 50))
        m.resetSection(section)
        #expect(m.clip?.effects[0].parameters[k]?.value == 17)

        // Reset Default to Factory: marker gone, Reset goes to the built-in value.
        m.resetDefaultToFactory(section)
        #expect(!m.hasUserDefault(section) && stored?.isEmpty == true)
        m.resetSection(section)
        #expect(m.clip?.effects[0].parameters == ClipEffect.make(kind: blur)!.parameters)
    }

    @Test func dragAndPaletteTransitionsStartFromTheUserDefault() throws {
        let (ses, track, cs) = try makeSession()
        let first = try #require(ses.addTransition(kind: .push, track: track, point: .cut(outgoing: cs[0].id, incoming: cs[1].id),
                                                   alignment: .center))
        ses.setTransition(first, duration: f(14))
        ses.setTransitionStyle(first, easing: .fastStart, direction: .up)
        var stored: EffectDefaults?
        ses.onEffectDefaultsChange = { stored = $0 }
        #expect(ses.useTransitionAsDefault(first))
        #expect(ses.hasTransitionDefault(.push) && stored?.transition(.push)?.duration == f(14))

        // Drag onto the next cut.
        let second = try #require(ses.addTransition(kind: .push, track: track, point: .cut(outgoing: cs[1].id, incoming: cs[2].id),
                                                    alignment: .center))
        var tr = ses.activeTimeline!.transition(second)!.1
        #expect(tr.duration == f(14) && tr.effectiveEasing == .fastStart && tr.effectiveDirection == .up)

        // Change it, Reset: back to the user default.
        ses.setTransitionStyle(second, easing: .linear, direction: .down)
        #expect(ses.resetTransition(second))
        tr = ses.activeTimeline!.transition(second)!.1
        #expect(tr.effectiveEasing == .fastStart && tr.effectiveDirection == .up && tr.duration == f(14))

        // Factory again.
        ses.resetTransitionDefaultToFactory(.push)
        #expect(!ses.hasTransitionDefault(.push) && stored?.isEmpty == true)
        #expect(ses.resetTransition(second))
        tr = ses.activeTimeline!.transition(second)!.1
        // Factory: the kind's settling curve (DECISIONS 2026-10-06), nothing else of its own.
        #expect(tr.easing == .easeOut100 && tr.direction == nil)
        #expect(tr.duration == TransitionKind.push.presetDuration(frameDuration: fd)
                ?? TransitionDefaults.load().duration(for: .video, frameDuration: fd))
    }

    @Test func libraryPersistsAndAnnouncesChanges() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sq-fbw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("defaults.json")
        let lib = EffectDefaultsLibrary(fileURL: url)
        #expect(lib.defaults.isEmpty)
        var e = ClipEffect.make(kind: blur)!
        e.parameters[k] = AnimatedProperty(9)
        #expect(lib.update { $0.setDefault(from: e, keepKeyframes: true, at: .zero) })
        let again = EffectDefaultsLibrary(fileURL: url)
        #expect(again.defaults.effect(blur)?.parameters[k]?.value == 9)
    }
}

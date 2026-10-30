import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func vclip(_ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}
private func timeline(_ clips: [Clip], locked: Bool = false) throws -> Timeline {
    var t = Track(kind: .video)
    for c in clips { try t.overwrite(c) }
    t.isLocked = locked
    return Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t])
}
private func stage(_ tl: Timeline, _ i: Int) -> ClipEffect? {
    let c = tl.tracks[0].clips[i]
    return c.effects.first { PunchIn.isPunchIn($0, of: c.id) }
}
/// Effective punch-in zoom factor of clip `i` at local time `t` (1 when it has no stage).
private func scale(_ tl: Timeline, _ i: Int, at t: Time = .zero) -> Double {
    guard let e = stage(tl, i), let p = e.parameters[ClipEffect.stageScaleKey] else { return 1 }
    return p.value(atLocal: t) / 100
}
private func opts(_ scales: [Double], _ ease: PunchInCutsOptions.Ease, _ pattern: PunchInCutsOptions.Pattern, ramp: Int = 6) -> PunchInCutsOptions {
    PunchInCutsOptions(scales: scales, ease: ease, pattern: pattern, rampFrames: ramp)
}

@Suite struct PunchInCutsTests {
    @Test func alternateHoldAlternatesBaseAndScale() throws {
        let cs = (0..<4).map { vclip(Int64($0) * 5, 5) }
        var tl = try timeline(cs)
        let n = try tl.punchInCuts(cs.map(\.id), opts([115], .hold, .alternate))
        #expect(n == 2)   // the 100% shots stay untouched
        #expect(scale(tl, 0) == 1 && scale(tl, 2) == 1)
        #expect(abs(scale(tl, 1) - 1.15) < 1e-9 && abs(scale(tl, 3) - 1.15) < 1e-9)
        #expect(stage(tl, 1)?.parameters[ClipEffect.stageScaleKey]?.isAnimated == false)
    }

    @Test func cyclicWalksTheSelectedScalesAscending() throws {
        let cs = (0..<5).map { vclip(Int64($0) * 5, 5) }
        var tl = try timeline(cs)
        try tl.punchInCuts(cs.map(\.id), opts([126.5, 100, 110], .hold, .cyclic))
        let want = [1.0, 1.10, 1.265, 1.0, 1.10]
        for i in 0..<5 { #expect(abs(scale(tl, i) - want[i]) < 1e-9) }
    }

    @Test func writesTheSameMarkerAsShiftP() throws {
        let cs = [vclip(0, 5), vclip(5, 5)]
        var tl = try timeline(cs)
        try tl.punchInCuts(cs.map(\.id), opts([115], .hold, .alternate))
        let c = tl.tracks[0].clips[1]
        #expect(tl.isPunchedIn(c) && c.effects.count == 1)
        #expect(c.effects[0].parameters[PunchIn.markerKey] != nil)
        #expect(!c.animation.scale.isAnimated && c.animation.scale.value.x == 1)   // Motion untouched
        // Shift+P on that clip toggles the very same marker off.
        try tl.togglePunchIn([c.id])
        #expect(!tl.isPunchedIn(tl.tracks[0].clips[1]) && tl.tracks[0].clips[1].effects.isEmpty)
    }

    @Test func leavesExistingMotionScaleAlone() throws {
        var c = vclip(5, 5); c.animation.scale = AnimatedProperty(Vec2(2, 2))
        var tl = try timeline([vclip(0, 5), c])
        try tl.punchInCuts(tl.tracks[0].clips.map(\.id), opts([110], .hold, .alternate))
        #expect(abs(scale(tl, 1) - 1.1) < 1e-9)
        #expect(tl.tracks[0].clips[1].animation.scale.value.x == 2)
    }

    @Test func easedRampStartsAtPreviousLevelAndLandsOnTarget() throws {
        let cs = [vclip(0, 5), vclip(5, 5)]
        var tl = try timeline(cs)
        try tl.punchInCuts(cs.map(\.id), opts([115], .easeInOut, .alternate))
        #expect(stage(tl, 1)?.parameters[ClipEffect.stageScaleKey]?.track.keys.count == 2)
        #expect(scale(tl, 1, at: .zero) == 1)
        #expect(abs(scale(tl, 1, at: Time(6, 30)) - 1.15) < 1e-9)
        #expect(abs(scale(tl, 1, at: s(4)) - 1.15) < 1e-9)
        let mid = scale(tl, 1, at: Time(3, 30))
        #expect(mid > 1 && mid < 1.15)
        #expect(stage(tl, 0) == nil)
    }

    @Test func shotsBackAt100PercentLoseTheirStage() throws {
        let cs = (0..<4).map { vclip(Int64($0) * 5, 5) }
        var tl = try timeline(cs)
        try tl.punchInCuts(cs.map(\.id), opts([115], .hold, .alternate))   // B and D punched
        #expect(stage(tl, 1) != nil)
        // Run again on B-D only: B is now the first (100%) shot and must lose its stage.
        try tl.punchInCuts(cs.dropFirst().map(\.id), opts([115], .hold, .alternate))
        #expect(stage(tl, 1) == nil && scale(tl, 1) == 1)
        #expect(stage(tl, 2) != nil)
    }

    @Test func oldMotionScaleAtTheSameLevelIsNotStacked() throws {
        var c = vclip(5, 5); c.animation.scale = AnimatedProperty(Vec2(1.15, 1.15))
        var tl = try timeline([vclip(0, 5), c])
        try tl.punchInCuts(tl.tracks[0].clips.map(\.id), opts([115], .hold, .alternate))
        #expect(stage(tl, 1) == nil && tl.tracks[0].clips[1].animation.scale.value.x == 1.15)
    }

    @Test func runningTwiceNeverStacksAStage() throws {
        let cs = [vclip(0, 5), vclip(5, 5)]
        var tl = try timeline(cs)
        try tl.punchInCuts(cs.map(\.id), opts([115], .hold, .alternate))
        try tl.punchInCuts(cs.map(\.id), opts([126.5], .hold, .alternate))
        #expect(tl.tracks[0].clips[1].effects.count == 1)
        #expect(abs(scale(tl, 1) - 1.265) < 1e-9)
    }

    @Test func errorsLeaveTheTimelineUntouched() throws {
        let cs = [vclip(0, 5), vclip(5, 5)]
        var locked = try timeline(cs, locked: true)
        let before = locked
        #expect(throws: EditError.self) { try locked.punchInCuts(cs.map(\.id), opts([115], .hold, .alternate)) }
        #expect(locked == before)
        var tl = try timeline(cs)
        #expect(throws: EditError.self) { try tl.punchInCuts([UUID()], opts([115], .hold, .alternate)) }
    }

    @Test func noLevelAboveBaseChangesNothing() throws {
        let cs = [vclip(0, 5), vclip(5, 5)]
        var tl = try timeline(cs); let before = tl
        let n = try tl.punchInCuts(cs.map(\.id), opts([100], .hold, .alternate))
        #expect(n == 0 && tl == before)
    }
}

@Suite struct VocabularyPassTests {
    @Test func renamedEffectsKeepTheirKinds() {
        #expect(EffectCatalog.spec(for: ClipEffect.tintKind)?.title == "Duotone")
        #expect(EffectCatalog.spec(for: ClipEffect.strobeKind)?.title == "Strobe Light")
        #expect(EffectCatalog.spec(for: ClipEffect.audioParametricEQKind)?.title == "EQ")
        #expect(EffectCatalog.spec(for: ClipEffect.colorKind)?.title == "Color")
        #expect(EffectCatalog.spec(for: ClipEffect.ultraKeyKind)?.title == "Color Key")
    }
}

import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private let fd = Time(1, 25)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ name: String, _ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(dur)), start: s(start),
         mediaDuration: s(60))
}
private func track(_ clips: [Clip]) -> Track {
    var t = Track(kind: .video)
    for c in clips { try! t.overwrite(c) }
    return t
}
@MainActor private func session(_ tracks: [Track]) -> EditorSession {
    EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: fd, tracks: tracks)]),
                  engine: StubProgramEngine())
}

/// A luma ramp with mild, varied color (display values).
private func picture(scale: SIMD3<Float> = .one) -> [SIMD3<Float>] {
    var seed: UInt32 = 777
    func r() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) }
    return (0..<2400).map { i in
        let y = 0.04 + 0.9 * Float(i) / 2400
        let c = SIMD3<Float>(y + 0.06 * (r() - 0.5), y + 0.06 * (r() - 0.5), y + 0.06 * (r() - 0.5)) * scale
        return SIMD3(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1))
    }
}

@MainActor @Suite struct ColorMatchToClipSessionTests {
    @Test func theSelectedClipIsMatchedToThePreviousClip() throws {
        let a = clip("A", 0, 4), b = clip("B", 4, 4)
        let ses = session([track([a, b])])
        ses.select(clips: [b.id], captions: [])
        guard case .ready(let pair) = ses.colorMatchToClipPlan() else { Issue.record("not ready"); return }
        #expect(pair.target == b.id && pair.reference == a.id)
    }

    @Test func withoutSelectionTheClipUnderThePlayheadOnTheTopTrackIsTheTarget() throws {
        let low = clip("Low", 0, 10), high = clip("High", 2, 4)
        let ses = session([track([low]), track([high])])
        ses.seek(to: s(3))
        guard case .ready(let pair) = ses.colorMatchToClipPlan() else { Issue.record("not ready"); return }
        #expect(pair.target == high.id && pair.reference == low.id)
    }

    @Test func aLonelyClipHasNoReference() {
        let a = clip("A", 0, 4)
        let ses = session([track([a])])
        ses.select(clips: [a.id], captions: [])
        #expect(ses.colorMatchToClipPlan() == .blocked(EditorSession.colorMatchNoReference))
        let none = session([track([])])
        #expect(none.colorMatchToClipPlan() == .blocked(EditorSession.colorMatchNoTarget))
    }

    @Test func applyingIsOneUndoStepOnTheFirstColourEffect() throws {
        let a = clip("A", 0, 4), b = clip("B", 4, 4)
        let ses = session([track([a, b])])
        ses.select(clips: [b.id], captions: [])
        guard case .ready(let pair) = ses.colorMatchToClipPlan() else { Issue.record("not ready"); return }
        let out = ses.applyColorMatchToClip(pair, reference: picture(), target: picture(scale: SIMD3(0.7, 0.62, 0.5)))
        #expect(out == .applied)
        #expect(ses.undoName == "Match Color to Clip")
        let matched = try #require(ses.activeTimeline?.tracks[0].clips.first { $0.id == b.id })
        let e = matched.color.primary
        #expect(e.basic.exposure > 0.2)
        #expect(!e.wheels.isNeutral)
        #expect(matched.colorGradeEffects.first?.colorData.match?.clip == a.id)
        #expect(matched.colorGradeEffects.first?.colorData.match?.label.hasPrefix("A ") == true)
        #expect(ses.undo())
        #expect(ses.activeTimeline?.tracks[0].clips.first { $0.id == b.id }?.colorGradeEffects.isEmpty == true)
    }

    @Test func aMatchingClipIsLeftAlone() {
        let a = clip("A", 0, 4), b = clip("B", 4, 4)
        let ses = session([track([a, b])])
        ses.select(clips: [b.id], captions: [])
        guard case .ready(let pair) = ses.colorMatchToClipPlan() else { Issue.record("not ready"); return }
        #expect(ses.applyColorMatchToClip(pair, reference: picture(), target: picture()) == .alreadyMatches)
        #expect(ses.applyColorMatchToClip(pair, reference: [], target: picture()) == .unreadable)
        #expect(!ses.canUndo)
    }

    @Test func theSoloViewShowsOnlyTheMeasuredClip() throws {
        let low = clip("Low", 0, 10), high = clip("High", 2, 4)
        let ses = session([track([low]), track([high])])
        let solo = try #require(ses.colorMatchSoloTimeline(low.id))
        #expect(solo.tracks[1].isVisible == false)
        #expect(solo.tracks[0].clips.first?.id == low.id)
    }
}

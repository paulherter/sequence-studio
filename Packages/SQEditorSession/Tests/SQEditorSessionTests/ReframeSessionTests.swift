import Foundation
import Testing
import SQAnalysis
import SQCore
@testable import SQEditorSession

private let fd = Time(1, 30)

/// Face that walks from 30 % to 70 % of the width over the clip; or nothing at all; or an error.
private struct FakeDetector: SubjectDetecting {
    enum Mode: Sendable { case walk(duration: Double), none, fail, stall }
    let mode: Mode
    struct Broken: Error {}
    func subjects(atSourceTime t: Time) async throws -> [SubjectBox] {
        switch mode {
        case .none: return []
        case .fail: throw Broken()
        case .stall: throw BlockingLane.Stalled()
        case .walk(let d):
            let f = min(max(Double(t.value) / Double(t.timescale) / d, 0), 1)
            let x = 0.3 + 0.4 * f
            return [SubjectBox(kind: .face, rect: NormalizedRect(x: x - 0.05, y: 0.45, width: 0.1, height: 0.1), confidence: 0.9)]
        }
    }
}

/// Runs `hook` before every detection (an edit made by the user while the analysis runs).
private struct EditingDetector: SubjectDetecting {
    let inner: FakeDetector
    let hook: @Sendable () async -> Void
    func subjects(atSourceTime t: Time) async throws -> [SubjectBox] {
        await hook()
        return try await inner.subjects(atSourceTime: t)
    }
}

@MainActor private struct Fixture {
    let session: EditorSession
    let clips: [Clip]
    let media: [MediaRef]

    /// Portrait 1080x1920 sequence with landscape 1920x1080 clips of `seconds` each, back to back on V1.
    init(count: Int = 1, seconds: Int64 = 4, extra: [Clip] = []) {
        var media: [MediaRef] = [], clips: [Clip] = []
        var track = Track(kind: .video)
        for i in 0..<count {
            let info = MediaInfo(duration: Time(seconds, 1), video: VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8,
                                                                                    chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false))
            let m = MediaRef(name: "m\(i)", path: "/nonexistent/m\(i).mov", fingerprint: MediaFingerprint(size: 1), duration: Time(seconds, 1), info: info)
            let c = Clip(name: "c\(i)", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: Time(seconds, 1)),
                         start: Time(seconds * Int64(i), 1))
            try! track.overwrite(c)
            media.append(m); clips.append(c)
        }
        for c in extra { try! track.overwrite(c) }
        let t = Timeline(name: "Vertical", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd), tracks: [track])
        session = EditorSession(project: Project(name: "P", media: media, timelines: [t]), engine: StubProgramEngine())
        self.clips = clips; self.media = media
    }

    func clip(_ id: Clip.ID) -> Clip { session.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }
}

/// The clip's Auto Reframe stage (W7.1).
private func stage(_ c: Clip) -> ClipEffect? { c.effect(ofKind: ClipEffect.reframeKind) }
private func reframed(_ c: Clip) -> Bool { stage(c)?.parameters[ClipEffect.stagePositionXKey]?.isAnimated == true }

@MainActor @Suite struct ReframeSessionTests {
    @Test func aClipThatAlreadyFillsTheFrameIsLeftAlone() async throws {
        let f = Fixture()
        _ = f.session.setSequenceFormat(SequenceFormat(width: 1920, height: 1080, frameDuration: fd))
        f.session.select(clips: [f.clips[0].id])
        let before = f.session.history.current
        let out = try await f.session.autoReframe { _ in FakeDetector(mode: .walk(duration: 4)) }
        #expect(out.reframed == 0 && out.alreadyFramed == 1 && out.noSubject == 0)
        #expect(f.session.history.current == before)
        #expect(stage(f.clip(f.clips[0].id)) == nil)
    }

    @Test func dynamicZoomWritesOneEasedStageInOneUndoStepAndReplacesItOnTheSecondRun() throws {
        let f = Fixture(count: 2)
        f.session.select(clips: Set(f.clips.map(\.id)))
        #expect(f.session.applyDynamicZoom(zoomIn: true))
        for c in f.clips {
            let e = try #require(f.clip(c.id).effect(ofKind: ClipEffect.dynamicZoomKind))
            let sc = try #require(e.parameters[ClipEffect.stageScaleKey])
            #expect(sc.value(atLocal: .zero) == 100 && abs(sc.value(atLocal: c.duration) - 125) < 1e-9)
        }
        #expect(f.session.applyDynamicZoom(zoomIn: false))
        let e = try #require(f.clip(f.clips[0].id).effect(ofKind: ClipEffect.dynamicZoomKind))
        #expect(f.clip(f.clips[0].id).effects.count == 1)
        #expect(abs((e.parameters[ClipEffect.stageScaleKey]?.value(atLocal: .zero) ?? 0) - 125) < 1e-9)
        f.session.undo(); f.session.undo()
        #expect(f.clips.allSatisfy { f.clip($0.id).effect(ofKind: ClipEffect.dynamicZoomKind) == nil })
    }

    @Test func zoomWindowsAreEditedLiveInOneUndoStepAndReadBack() throws {
        let f = Fixture()
        let c = f.clips[0]
        f.session.select(clips: [c.id])
        let defaults = try #require(f.session.dynamicZoomWindows(for: f.clip(c.id)))
        #expect(defaults.start == .full && abs(defaults.end.zoom - 1.25) < 1e-9)
        let a = ZoomRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), b = ZoomRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        #expect(f.session.setDynamicZoomWindows(clip: c.id, start: a, end: b, ease: .easeOut, continuesGesture: false))
        #expect(f.session.setDynamicZoomWindows(clip: c.id, start: a, end: b.moved(by: Vec2(0.1, 0)), ease: .easeOut, continuesGesture: true))
        let w = try #require(f.session.dynamicZoomWindows(for: f.clip(c.id)))
        #expect(abs(w.start.x - 0.1) < 1e-9 && abs(w.end.x - 0.4) < 1e-9 && w.ease == .easeOut)
        #expect(f.clip(c.id).effects.count == 1)
        f.session.undo()
        #expect(f.clip(c.id).effect(ofKind: ClipEffect.dynamicZoomKind) == nil)
    }

    @Test func dynamicZoomWithoutAClipIsRefused() {
        let f = Fixture()
        f.session.select(clips: [])
        f.session.seek(to: Time(100, 1))
        #expect(!f.session.applyDynamicZoom(zoomIn: true))
    }

    @Test func movingSubjectWritesPositionKeysAndCoverScaleInOneUndoStep() async throws {
        let f = Fixture()
        f.session.select(clips: [f.clips[0].id])
        let before = f.clip(f.clips[0].id)
        let out = try await f.session.autoReframe { _ in FakeDetector(mode: .walk(duration: 4)) }
        #expect(out == ReframeOutcome(reframed: 1, noSubject: 0, failed: 0))
        let c = f.clip(f.clips[0].id)
        #expect(c.animation == before.animation)                           // Motion is left alone
        let e = try #require(stage(c))
        let keys = try #require(e.parameters[ClipEffect.stagePositionXKey]).track.keys
        #expect(keys.first!.time == .zero && keys.first!.value > keys.last!.value)
        let scale = try #require(e.parameters[ClipEffect.stageScaleKey])
        #expect(abs(scale.value - 100 * 1920.0 / 1080.0) < 1e-9 && !scale.isAnimated)
        #expect(abs(c.renderTransform(at: c.start, frame: Vec2(1920, 1080)).scale.x - 1920.0 / 1080.0) < 1e-9)
        #expect(f.session.undoName == "Auto Reframe")
        #expect(f.session.undo())
        #expect(f.clip(f.clips[0].id) == before)
    }

    @Test func noSubjectLeavesTheClipAlone() async throws {
        let f = Fixture()
        f.session.select(clips: [f.clips[0].id])
        let out = try await f.session.autoReframe { _ in FakeDetector(mode: .none) }
        #expect(out == ReframeOutcome(reframed: 0, noSubject: 1, failed: 0))
        #expect(!f.session.canUndo)
    }

    @Test func aFailingClipDoesNotStopTheOthers() async throws {
        let f = Fixture(count: 2)
        f.session.select(clips: Set(f.clips.map(\.id)))
        let broken = f.media[0].id
        let out = try await f.session.autoReframe { ref in FakeDetector(mode: ref.id == broken ? .fail : .walk(duration: 4)) }
        #expect(out == ReframeOutcome(reframed: 1, noSubject: 0, failed: 1))
        #expect(stage(f.clip(f.clips[0].id)) == nil)
        #expect(reframed(f.clip(f.clips[1].id)))
        // Both clips are one step.
        #expect(f.session.undo())
        #expect(!f.session.canUndo)
    }

    @Test func aClipWhoseReadHungIsCountedAsStalledNotAsUnreadable() async throws {
        let f = Fixture(count: 2)
        f.session.select(clips: Set(f.clips.map(\.id)))
        let hung = f.media[0].id
        let out = try await f.session.autoReframe { ref in FakeDetector(mode: ref.id == hung ? .stall : .walk(duration: 4)) }
        #expect(out == ReframeOutcome(reframed: 1, noSubject: 0, failed: 0, stalled: 1))
    }

    @Test func severalClipsAreOneUndoStep() async throws {
        let f = Fixture(count: 2)
        f.session.select(clips: Set(f.clips.map(\.id)))
        let out = try await f.session.autoReframe { _ in FakeDetector(mode: .walk(duration: 4)) }
        #expect(out.reframed == 2)
        #expect(f.session.undo())
        #expect(!f.session.canUndo)
        #expect(f.clips.allSatisfy { stage(f.clip($0.id)) == nil })
    }

    @Test func onlyMediaVideoClipsWithAKnownSizeAreTargets() {
        let text = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(10, 1))
        var gen = text; gen.generator = GeneratorRef(kind: GeneratorRef.text, payload: Data())
        let unknown = Clip(name: "u", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(20, 1))
        let f = Fixture(extra: [gen, unknown])
        f.session.select(clips: Set([f.clips[0].id, gen.id, unknown.id]))
        #expect(f.session.reframeTargets.map(\.id) == [f.clips[0].id])
    }

    @Test func withoutSelectionTheClipUnderThePlayheadIsUsed() {
        let f = Fixture(count: 2)
        f.session.seek(to: Time(5, 1))
        #expect(f.session.reframeTargets.map(\.id) == [f.clips[1].id])
    }

    @Test func applyKeepsOtherMotionValuesAndTheKeysStayEditable() throws {
        let f = Fixture()
        var c = f.clip(f.clips[0].id)
        c.animation.rotation = AnimatedProperty(12)
        f.session.replaceClip(c, name: "Rotate", continuesGesture: false)
        let keys = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(10, 0)), Keyframe(time: Time(1, 1), value: Vec2(-10, 0))])
        let plan = ReframePlan(scale: 2, position: AnimatedProperty(Vec2(10, 0), track: keys), samples: 2, detectedSamples: 2)
        #expect(f.session.applyReframe([c.id: plan]))
        let n = f.clip(c.id)
        #expect(n.animation == c.animation)
        let e = try #require(stage(n))
        #expect(e.parameters[ClipEffect.stageScaleKey]?.value == 200)
        let xs = try #require(e.parameters[ClipEffect.stagePositionXKey]).track
        #expect(xs.keys.count == 2)
        // Rendered: rotation kept, the planned framing reached at the keys.
        for k in keys.keys {
            let r = n.renderTransform(at: n.start + k.time, frame: Vec2(1920, 1080))
            #expect(abs(r.rotation - 12) < 1e-9 && abs(r.scale.x - 2) < 1e-9)
            #expect((r.map(.zero) - k.value).length < 1e-9)
        }
        // An ordinary key edit afterwards is its own undo step.
        var m = n
        let i = m.effects.firstIndex { $0.kind == ClipEffect.reframeKind }!
        m.effects[i].parameters[ClipEffect.stagePositionXKey]!.track.set(xs.keys[1].id, value: -20)
        f.session.replaceClip(m, name: "Position", continuesGesture: false)
        #expect(stage(f.clip(c.id))!.parameters[ClipEffect.stagePositionXKey]!.track.keys[1].value == -20)
        #expect(f.session.undo())
        #expect(f.session.undoName == "Auto Reframe")
    }

    @Test func clipEditedDuringTheRunIsSkippedAsFailed() async throws {
        let f = Fixture(count: 2)
        f.session.select(clips: Set(f.clips.map(\.id)))
        let session = f.session, edited = f.clips[0].id
        // While analyzing, the user moves the anchor of the first clip (the framing would no longer fit).
        let hook = EditingDetector(inner: FakeDetector(mode: .walk(duration: 4))) {
            await MainActor.run {
                guard var c = session.activeTimeline?.tracks.flatMap(\.clips).first(where: { $0.id == edited }) else { return }
                c.animation.anchor = AnimatedProperty(Vec2(50, 0))
                session.replaceClip(c, name: "Anchor", continuesGesture: false)
            }
        }
        let out = try await f.session.autoReframe { _ in hook }
        #expect(out == ReframeOutcome(reframed: 1, noSubject: 0, failed: 1))
        #expect(stage(f.clip(edited)) == nil && f.clip(edited).animation.anchor.value == Vec2(50, 0))
        #expect(reframed(f.clip(f.clips[1].id)))
    }

    @Test func formatChangedDuringTheRunSkipsEverything() {
        let f = Fixture()
        let c = f.clip(f.clips[0].id)
        let plan = ReframePlan(scale: 2, position: AnimatedProperty(Vec2(10, 0)), samples: 1, detectedSamples: 1)
        let r = f.session.applyReframe([c.id: plan], in: nil, expecting: [c.id: c],
                                       format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), variant: nil)
        #expect(r.applied == 0 && r.stale == 1 && !f.session.canUndo)
    }

    @Test func reframeWorksWithMotionSwitchedOff() throws {
        let f = Fixture()
        var c = f.clip(f.clips[0].id)
        c.motionEnabled = false
        c.animation.scale = AnimatedProperty(Vec2(0.3, 0.3))                // ignored while Motion is off
        f.session.replaceClip(c, name: "Motion off", continuesGesture: false)
        let plan = ReframePlan(scale: 2, position: AnimatedProperty(Vec2(10, 0)), samples: 1, detectedSamples: 1)
        #expect(f.session.applyReframe([c.id: plan]))
        let n = f.clip(c.id)
        let r = n.renderTransform(at: n.start, frame: Vec2(1920, 1080))
        #expect(!n.motionEnabled && (r.map(.zero) - Vec2(10, 0)).length < 1e-9 && abs(r.scale.x - 2) < 1e-9)
    }

    @Test func userScaleKeysSurviveAndMultiplyOntoTheReframe() throws {
        let f = Fixture()
        var c = f.clip(f.clips[0].id)
        c.animation.scale = AnimatedProperty(Vec2(1, 1), track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(1, 1)), Keyframe(time: Time(2, 1), value: Vec2(1.2, 1.2))]))
        f.session.replaceClip(c, name: "Punch in", continuesGesture: false)
        let plan = ReframePlan(scale: 1.5, position: AnimatedProperty(Vec2(10, 0)), samples: 1, detectedSamples: 1)
        #expect(f.session.applyReframe([c.id: plan]))
        let n = f.clip(c.id)
        #expect(n.animation == c.animation)
        #expect(abs(n.renderTransform(at: n.start, frame: Vec2(1920, 1080)).scale.x - 1.5) < 1e-9)
        #expect(abs(n.renderTransform(at: n.start + Time(2, 1), frame: Vec2(1920, 1080)).scale.x - 1.8) < 1e-9)
    }

    @Test func aSecondRunReplacesTheStage() throws {
        let f = Fixture()
        let c = f.clip(f.clips[0].id)
        #expect(f.session.applyReframe([c.id: ReframePlan(scale: 2, position: AnimatedProperty(Vec2(10, 0)), samples: 1, detectedSamples: 1)]))
        let id = try #require(stage(f.clip(c.id))).id
        #expect(f.session.applyReframe([c.id: ReframePlan(scale: 3, position: AnimatedProperty(Vec2(0, 0)), samples: 1, detectedSamples: 1)]))
        let n = f.clip(c.id)
        #expect(n.effects.filter { $0.kind == ClipEffect.reframeKind }.count == 1)
        #expect(stage(n)?.id == id && stage(n)?.parameters[ClipEffect.stageScaleKey]?.value == 300)
    }

    @Test func emptyPlanIsNotAnEdit() {
        let f = Fixture()
        #expect(!f.session.applyReframe([:]))
        #expect(!f.session.canUndo)
    }

    // MARK: W5.1 variants

    @Test func inAVariantTheKeysGoIntoItsOverrideAndTheBaseStays() async throws {
        let f = Fixture()                                     // 1080x1920 sequence
        let v = try #require(f.session.addVariant(name: "1:1", width: 1080, height: 1080))
        f.session.select(clips: [f.clips[0].id])
        let before = f.clip(f.clips[0].id)
        let g = try #require(f.session.reframeGeometry(for: before))
        #expect(g.frameWidth == 1080 && g.frameHeight == 1080)             // the variant's frame
        let out = try await f.session.autoReframe { _ in FakeDetector(mode: .walk(duration: 4)) }
        #expect(out.reframed == 1)
        let c = f.clip(f.clips[0].id)
        #expect(c.animation == before.animation)
        // The base gets an identity stage; the variant's framing sits in its effect-parameter overrides.
        let e = try #require(stage(c))
        #expect(c.renderTransform(at: c.start, frame: Vec2(1920, 1080)) == c.transform(at: c.start))
        let o = try #require(c.variantOverrides[v])
        #expect(o.position == nil && o.scale == nil)
        let ps = try #require(o.effectParameters[e.id])
        #expect(ps[ClipEffect.stagePositionXKey]?.isAnimated == true)
        #expect(ps[ClipEffect.stageScaleKey] != nil)                       // a cover scale is stored
        let shown = f.session.activeTimeline!.resolvedClip(c, variant: v)
        #expect(abs(shown.renderTransform(at: shown.start, frame: Vec2(1920, 1080)).scale.x - g.scale) < 1e-9)
        #expect(f.session.undoName == "Auto Reframe")
    }

    @Test func variantRemovedDuringTheRunSkipsEverything() throws {
        let f = Fixture()
        let v = try #require(f.session.addVariant(name: "1:1", width: 1080, height: 1080))
        let c = f.clip(f.clips[0].id)
        f.session.removeVariant(v)
        let plan = ReframePlan(scale: 2, position: AnimatedProperty(Vec2(10, 0)), samples: 1, detectedSamples: 1)
        let r = f.session.applyReframe([c.id: plan], in: nil, expecting: [c.id: c],
                                       format: SequenceFormat(width: 1080, height: 1080, frameDuration: fd), variant: v)
        #expect(r.applied == 0 && r.stale == 1)
    }
}

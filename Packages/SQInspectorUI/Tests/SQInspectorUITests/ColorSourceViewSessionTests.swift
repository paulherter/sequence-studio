import Foundation
import Testing
import SQCore
@testable import SQEditorSession
@testable import SQInspectorUI

/// Color page, Clips mode: the Program monitor plays the picked clip's whole source file on its own time axis.
@MainActor @Suite struct ColorSourceViewSessionTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private let fd = Time(1, 25)

    /// V1: other 0-2 s, graded 2-6 s showing source 10-14 s of a 30 s file.
    private func setup() throws -> (EditorSession, StubProgramEngine, Clip.ID) {
        var v1 = Track(kind: .video)
        try v1.overwrite(Clip(name: "other", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero,
                              mediaDuration: s(5)))
        let graded = Clip(name: "graded", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: s(2),
                          mediaDuration: s(30))
        try v1.overwrite(graded)
        let engine = StubProgramEngine()
        let session = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: fd, tracks: [v1])]),
                                    engine: engine)
        return (session, engine, graded.id)
    }

    /// Sequence-time jumps (markers, any-track edit points, selected clip edge) move the sequence playhead while the
    /// monitor shows the file; they must not be read as file time.
    @Test func sequenceJumpsStayInSequenceTime() throws {
        let (session, _, id) = try setup()
        session.seek(to: s(3))
        _ = session.attempt("M") { _ = $0.addMarker(at: self.s(5)) }
        session.colorSoloClip = id
        session.goToNextMarker()
        #expect(session.playhead == s(5))
        session.goToEditPointOnAnyTrack(forward: false)
        #expect(session.playhead == s(2))
        session.select(clips: [id])
        session.goToSelectedClipEdge(end: true)
        #expect(session.playhead == s(6))
    }

    /// Cut Out while the monitor shows the file: the playhead lands on the join in sequence time (not read as file time).
    @Test func cutOutLandsInSequenceTime() throws {
        let (session, _, id) = try setup()
        session.seek(to: s(3))
        session.colorSoloClip = id
        session.seekSequence(to: s(3)); session.cutOut()
        session.seekSequence(to: s(5)); session.cutOut()
        #expect(session.playhead == s(3))
    }

    @Test func soloShowsTheWholeFileOnItsOwnAxis() throws {
        let (session, engine, id) = try setup()
        session.seek(to: s(3))
        session.colorSoloClip = id
        let view = try #require(session.colorSourceView)
        #expect(engine.timeline?.duration == s(30))
        #expect(session.monitorDuration == s(30))
        #expect(view.position == s(11) && session.monitorTime == s(11))       // the same frame, now in file time
        #expect(engine.position == s(11))
        #expect(session.sourceViewClipRange == TimeRange(start: s(10), duration: s(4)))

        // Monitor seeks are file time; the sequence playhead follows inside the clip, held at its ends.
        session.seek(to: s(12))
        #expect(engine.position == s(12) && session.playhead == s(4))
        session.seek(to: s(25))
        #expect(session.monitorTime == s(25))
        #expect(session.playhead == s(6) - fd)
        session.goToEnd()
        #expect(session.monitorTime == s(30) - fd)
        session.goToIn()
        #expect(session.monitorTime == s(10))
    }

    @Test func playbackRunsThroughTheFileAndStopsAtItsEnd() throws {
        let (session, engine, id) = try setup()
        session.colorSoloClip = id
        session.seek(to: s(28))
        session.playPause()
        engine.simulatePlayback(advance: s(1))
        #expect(session.monitorTime == s(29) && session.isPlaying)
        engine.simulatePlayback(advance: s(1))
        #expect(!session.isPlaying)
        session.playPause()                                                     // at the end: restarts at the file start
        #expect(session.monitorTime == .zero)
    }

    @Test func gradeEditKeepsTheFileFrameAndLeavingRestoresTheSequence() throws {
        let (session, engine, id) = try setup()
        session.seek(to: s(3))
        session.colorSoloClip = id
        session.seek(to: s(20))
        session.select(clips: [id])
        session.renameSelectedClip(to: "edited")                                // any edit of the clip re-pushes the view
        #expect(session.colorSourceView?.timeline.tracks.first?.clips.first?.name == "edited")
        #expect(session.monitorTime == s(20))
        session.colorSoloClip = nil
        #expect(session.colorSourceView == nil)
        #expect(engine.timeline?.duration == s(6))
        #expect(engine.position == session.playhead)
        #expect(session.monitorTime == session.playhead)
    }

    @Test func pickingKeepsTheSequencePlayheadInSequenceTime() throws {
        let (session, _, id) = try setup()
        session.colorSoloClip = id
        session.seekSequence(to: s(1))
        #expect(session.playhead == s(1))
        #expect(session.monitorTime == s(10))                                  // the monitor stays on its file frame
    }

    // MARK: Raw source + grade only (DECISIONS "Color solo = raw source + grade")

    /// V1: graded 0-2 s showing source 10-14 s at 200 % with scale / position keys, a blur and a keyed grade; a second
    /// clip of the same file at 4-6 s (source 20-22 s); V2: a title over both. The file is 3840x2160 at 50 fps.
    private func rawSetup(independent: Bool = false, probed: Bool = true) throws -> (EditorSession, StubProgramEngine, Clip.ID, Clip.ID) {
        let media = UUID()
        var graded = Clip(name: "graded", media: media, kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: .zero,
                          mediaDuration: s(30), speed: ClipSpeed(num: 2, den: 1))
        var blur = try #require(ClipEffect.make(kind: ClipEffect.gaussianBlurKind))
        blur.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(25)
        var e = ColorEffect(id: 1, inputLUT: .automatic)
        e.basic.saturation = 140
        var grade = ClipEffect.colorGrade(e)
        var exposure = AnimatedProperty(0.0)
        exposure.track.insert(Keyframe(time: .zero, value: 0, interpolation: .linear))
        exposure.track.insert(Keyframe(time: s(1), value: 2, interpolation: .linear))
        grade.parameters[ClipEffect.colorExposureKey] = exposure
        graded.effects = [blur, grade]
        graded.animation.scale.track.insert(Keyframe(time: .zero, value: Vec2(1, 1), interpolation: .linear))
        graded.animation.scale.track.insert(Keyframe(time: s(1), value: Vec2(2, 2), interpolation: .linear))
        graded.animation.position.track.insert(Keyframe(time: .zero, value: Vec2(0, 0), interpolation: .linear))
        graded.animation.position.track.insert(Keyframe(time: s(1), value: Vec2(400, 0), interpolation: .linear))
        graded.blendMode = .screen
        var other = Clip(name: "other use", media: media, kind: .video, source: TimeRange(start: s(20), duration: s(2)), start: s(4),
                         mediaDuration: s(30))
        other.effects = [grade]
        other.gradeIndependent = independent
        graded.gradeIndependent = independent
        var v1 = Track(kind: .video), v2 = Track(kind: .video)
        try v1.overwrite(graded); try v1.overwrite(other)
        try v2.overwrite(Clip(name: "title", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(6)), start: .zero))
        var p = Project(name: "P", timelines: [Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd),
                                                        tracks: [v1, v2])])
        p.media = [MediaRef(id: media, name: "M", path: "/nonexistent/M.mov", fingerprint: MediaFingerprint(size: 1), duration: s(30),
                            info: MediaInfo(duration: s(30), video: VideoTrackInfo(width: 3840, height: 2160, codec: "hvc1", bitDepth: 10,
                                                                                   chroma: "4:2:0", nominalFrameDuration: Time(1, 50),
                                                                                   isVariableFrameRate: false)))]
        if !probed { p.media[0].info = nil }
        let engine = StubProgramEngine()
        return (EditorSession(project: p, engine: engine), engine, graded.id, other.id)
    }

    private func clip(_ session: EditorSession, _ id: Clip.ID) throws -> Clip {
        try #require(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id })
    }

    @Test func soloPlanIsOneRawLayerWithOnlyTheGrade() throws {
        let (session, engine, id, _) = try rawSetup()
        session.seek(to: s(1))
        session.colorSoloClip = id
        let tl = try #require(engine.timeline)
        #expect(tl.format.width == 3840 && tl.format.height == 2160 && tl.frameDuration == Time(1, 50))
        #expect(session.monitorFrameDuration == Time(1, 50))
        #expect(session.monitorTime == s(12))                                   // 1 s at 200 % = source 12 s
        let original = try clip(session, id)
        for file in [s(10), Time(21, 2), s(11), s(12), s(25)] {
            let layers = tl.videoLayers(at: file)
            #expect(layers.count == 1)                                          // no title, no other clip
            let l = try #require(layers.first)
            #expect(l.clip == id && l.sourceTime == file)                       // speed 1, own axis, whole file
            #expect(l.transform == .identity && l.blendMode == .normal && l.effects == .none)
            let local = min(max(.zero, Time.scaled(file - s(10), by: 1, over: 2)), s(2) - fd)
            #expect(l.color == original.color(atLocal: local))                  // the grade the timeline shows on that frame
        }
        let solo = try #require(tl.tracks.first { $0.kind == .video }?.clips.first)
        #expect(solo.effects.map(\.kind) == [ClipEffect.colorKind] && solo.speed == .normal)
        // Steps go by the file's own frames.
        session.stepFrames(1)
        #expect(session.monitorTime == s(12) + Time(1, 50))
        // Leaving the solo returns to the program view.
        session.colorSoloClip = nil
        #expect(session.colorSourceView == nil)
        #expect(engine.timeline == session.pushedTimeline)
        #expect(engine.timeline?.tracks.filter { $0.kind == .video }.flatMap(\.clips).count == 3)
        #expect(session.monitorFrameDuration == fd)
    }

    @Test func linkedGradeEditOfAnotherUseShowsInTheSolo() throws {
        let (session, engine, id, other) = try rawSetup()
        session.colorSoloClip = id
        let edited = session.editClipColor(other, continuesGesture: false) { c in
            var col = c.color; col.effects[0].basic.saturation = 60; c.color = col; return true
        }
        #expect(edited)
        let solo = try #require(engine.timeline?.tracks.first { $0.kind == .video }?.clips.first)
        #expect(solo.id == id && solo.color.primary.basic.saturation == 60)
    }

    @Test func unlinkedSoloKeepsItsOwnGrade() throws {
        let (session, engine, id, other) = try rawSetup(independent: true)
        session.colorSoloClip = id
        _ = session.editClipColor(other, continuesGesture: false) { c in
            var col = c.color; col.effects[0].basic.saturation = 60; c.color = col; return true
        }
        let solo = try #require(engine.timeline?.tracks.first { $0.kind == .video }?.clips.first)
        #expect(solo.color.primary.basic.saturation == 140)
        #expect(try clip(session, other).color.primary.basic.saturation == 60)
    }

    /// Probe info arriving after the solo opened (relink / background probe) switches it to the file's size and rate.
    @Test func probeInfoArrivingLaterRefreshesTheSolo() async throws {
        let (session, engine, id, _) = try rawSetup(probed: false)
        session.colorSoloClip = id
        #expect(engine.timeline?.format.width == 1080 && engine.timeline?.frameDuration == fd)
        let info = MediaInfo(duration: s(30), video: VideoTrackInfo(width: 3840, height: 2160, codec: "hvc1", bitDepth: 10,
                                                                    chroma: "4:2:0", nominalFrameDuration: Time(1, 50),
                                                                    isVariableFrameRate: false))
        session.mediaInfoProbe = { (_: URL) in info }
        let media = try #require(session.project.media.first?.id)
        session.relinkMedia([media: "/found/m.mov"])
        for _ in 0..<SQTiming.polls(100) where engine.timeline?.format.width != 3840 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.timeline?.format.width == 3840)
        #expect(engine.timeline?.frameDuration == Time(1, 50))
        #expect(session.monitorFrameDuration == Time(1, 50))
    }

    /// Vectorscope shows nothing on the Color page: the Scopes panel measures what the monitor renders, so every
    /// switch of the Color solo (also one without a file view) must make it re-measure, and so must the file view's moves.
    @Test func colourSoloSwitchesAndFileMovesMakeTheScopesRemeasure() throws {
        let (session, _, id) = try setup()
        var seen: [EditorSession.Change] = []
        session.onChange = { seen.append($0) }
        session.colorSoloClip = id
        #expect(seen.contains { ScopesPanelView.refreshes(for: $0) }, "solo on")
        seen.removeAll()
        session.seek(to: s(12))
        #expect(seen.contains { ScopesPanelView.refreshes(for: $0) }, "the file view moved")
        seen.removeAll()
        session.colorSoloClip = nil
        #expect(seen.contains { ScopesPanelView.refreshes(for: $0) }, "solo off")
        seen.removeAll()
        session.colorSoloClip = UUID()                                           // no such clip: no file view, still a new picture
        #expect(seen.contains { ScopesPanelView.refreshes(for: $0) }, "solo of a clip without a file view")
        #expect(!ScopesPanelView.refreshes(for: [.selection, .transport]))
    }
}

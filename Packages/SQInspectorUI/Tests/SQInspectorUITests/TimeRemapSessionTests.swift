import CoreGraphics
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQInspectorUI

private let fd = Time(1, 24)
private func f(_ n: Int64) -> Time { fd * n }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
private func mk(_ start: Int64, from: Int64 = 0, _ frames: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "clip", media: UUID(), kind: kind, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         link: link, mediaDuration: f(4000))
}
@MainActor
private func session(_ clips: [[Clip]], kinds: [TrackKind]) throws -> EditorSession {
    var p = EditorSession.makeUntitled()
    var tracks: [Track] = []
    for (i, cs) in clips.enumerated() {
        var t = Track(kind: kinds[i])
        for c in cs { try t.overwrite(c) }
        tracks.append(t)
    }
    p.timelines[0].tracks = tracks
    p.timelines[0].format = SequenceFormat(width: 1920, height: 1080, frameDuration: fd)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-remap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir))
}

@MainActor
@Suite struct TimeRemapSessionTests {
    private func twoSpeeds(_ clip: Clip) -> SpeedKeys {
        let k = SpeedKeys.of(clip)
        let (n, b) = k.addingKey(at: f(24), frameDuration: fd)!
        return n.settingSpeed(ofSegment: b, to: pct(300), frameDuration: fd)
    }

    @Test func aBandDragIsOneUndoStep() throws {
        let c = mk(0, 96)
        let s = try session([[c]], kinds: [.video])
        s.select(clips: [c.id])
        let keys = twoSpeeds(c)
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: SpeedKeys.of(c), phase: .began))
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: keys, phase: .changed))
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: keys.settingSpeed(ofSegment: 1, to: pct(400), frameDuration: fd), phase: .changed))
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: keys, phase: .ended))
        let r = try #require(s.activeTimeline?.tracks[0].clips.first)
        #expect(r.speedKeys != nil && r.duration == f(24) + f(18))              // 72 frames of source at 400 % = 18
        #expect(s.undoName == "Speed Ramp")
        #expect(s.undo())
        #expect(s.activeTimeline?.tracks[0].clips.first == c)                   // one step back to the untouched clip
    }

    @Test func deleteAndRemoveReturnToConstant() throws {
        let c = mk(0, 96)
        let s = try session([[c]], kinds: [.video])
        s.select(clips: [c.id])
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: twoSpeeds(c), phase: .began))
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: twoSpeeds(c), phase: .changed))
        #expect(s.canRemoveTimeRemapping && s.canToggleTimeRemapping)
        #expect(s.deleteSpeedKey(clip: c.id, hit: SpeedBandKeyHit(hit: .key(1))))     // merges to the average speed
        #expect(s.activeTimeline?.tracks[0].clips[0].speedKeys == nil || s.activeTimeline?.tracks[0].clips[0].speedKeys?.segments.count == 1)
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: twoSpeeds(c), phase: .began))
        s.applySpeedEdit(SpeedEdit(clip: c.id, keys: twoSpeeds(c), phase: .changed))
        #expect(s.removeTimeRemapping())
        let r = try #require(s.activeTimeline?.tracks[0].clips.first)
        #expect(r.speedKeys == nil && r.speed == .normal && r.duration == r.source.duration)
        #expect(!s.canRemoveTimeRemapping)
    }

    @Test func audioClipsAndStillsDoNotShowTheBand() throws {
        let a = mk(0, 48, kind: .audio)
        let s = try session([[a]], kinds: [.audio])
        s.select(clips: [a.id])
        #expect(!s.canToggleTimeRemapping)
    }

    @Test func dialogKeepsAverageSpeedAndStoresInterpolation() throws {
        var c = mk(0, 96)
        let k = twoSpeeds(c)
        c.setSpeedKeys(k)
        var m = SpeedDialogModel(clips: [c], frameDuration: fd)
        #expect(!m.hasChanges && m.percent == c.averageSpeed.percent)
        m.timeInterpolation = .frameBlend
        #expect(m.hasChanges && m.change.timeInterpolation == .frameBlend)
        // applying "no change" plus the interpolation keeps the remapped clip's shape and length
        let s = try session([[c]], kinds: [.video])
        s.select(clips: [c.id])
        #expect(s.applySpeed(m.change))
        let r = try #require(s.activeTimeline?.tracks[0].clips.first)
        #expect(r.timeInterpolation == .frameBlend && r.speedKeys == c.speedKeys && r.duration == c.duration)
        #expect(SpeedLabel.nameSuffix(for: r) == " [Speed Ramp]")
    }
}

/// Effect Controls Speed row: diamond and previous / next navigation over the speed keys.
@MainActor
@Suite struct SpeedKeyRowTests {
    private func rig() throws -> (EffectControlsModel, EditorSession, Clip.ID) {
        let c = mk(0, 96)
        let s = try session([[c]], kinds: [.video])
        s.select(clips: [c.id])
        let m = EffectControlsModel()
        m.frameDuration = fd
        m.speedSession = s
        m.setClip(c)
        return (m, s, c.id)
    }
    private func refresh(_ m: EffectControlsModel, _ s: EditorSession, _ id: Clip.ID) {
        m.setClip(s.activeTimeline?.tracks[0].clips.first { $0.id == id })
    }

    @Test func diamondAddsAndRemovesAKeyAtThePlayhead() throws {
        let (m, s, id) = try rig()
        #expect(m.speedKeyControlState() == .off && !m.speedIsAnimated)
        m.playhead = f(24)
        #expect(m.toggleSpeedKeyAtPlayhead())
        refresh(m, s, id)
        #expect(m.speedKeyTimes == [f(24)] && m.speedIsAnimated)
        let st = m.speedKeyControlState()
        #expect(st.keyIsOn && st.showsNavigation && !st.canGoPrevious && !st.canGoNext)
        #expect(m.clip!.duration == f(96))                       // a new key holds the speed: nothing plays differently
        #expect(m.clip!.speedKeys?.segments.allSatisfy { $0.from == .normal } == true)
        #expect(m.toggleSpeedKeyAtPlayhead())                   // on the key: removes it
        refresh(m, s, id)
        #expect(m.speedKeyTimes.isEmpty)
        s.undo(); refresh(m, s, id)
        #expect(m.speedKeyTimes == [f(24)])                      // one undo step each
    }

    @Test func switchOffAsksThenRemovesTheRampInOneUndoStep() throws {
        let (m, s, id) = try rig()
        m.playhead = f(24); #expect(m.toggleSpeedKeyAtPlayhead()); refresh(m, s, id)
        #expect(m.toggleSpeedAnimation() == .needsConfirmation)       // cancel = nothing else called
        refresh(m, s, id)
        #expect(m.speedIsAnimated)
        #expect(m.toggleSpeedAnimation(confirmRemoval: true) == .removed)
        refresh(m, s, id)
        #expect(!m.speedIsAnimated && m.clip?.speedKeys == nil)
        s.undo(); refresh(m, s, id)
        #expect(m.speedKeyTimes == [f(24)])                           // one undo step
        s.undo(); refresh(m, s, id)
        #expect(!m.speedIsAnimated)
    }

    /// The Speed field on an animated clip edits the speed at the playhead; the stretch between keys ramps, with ease.
    @Test func fieldSetsTheSpeedAtThePlayheadAndEasesBetweenKeys() throws {
        let (m, s, id) = try rig()
        m.playhead = f(24); #expect(m.toggleSpeedKeyAtPlayhead()); refresh(m, s, id)
        m.playhead = f(48)
        #expect(abs(m.speedPercent - 100) < 0.01)
        m.setSpeedPercent(120); refresh(m, s, id)             // adds a key at 48 holding 100, then sets 120
        #expect(m.speedKeyTimes == [f(24), f(48)])
        #expect(abs(m.speedPercent - 120) < 0.01)
        m.playhead = f(36)
        #expect(m.speedPercent > 100 && m.speedPercent < 120)  // ramp between the keys
        #expect(m.speedHasTransition)
        let src = try #require(m.speedCurveSource())
        src.applyEaseShape(EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.5, dy: 0), in: EaseHandle(dx: 0.5, dy: 0)))
        refresh(m, s, id)
        #expect(m.clip?.speedKeys?.ease(ofSegment: 1).effective.interpolation == .bezier)
        #expect(m.clip!.duration == f(96))                     // the key frames did not move
        s.undo(); s.undo(); refresh(m, s, id)
        #expect(m.speedKeyTimes == [f(24)])
    }

    /// A typed value with the playhead outside the clip edits the nearest frame; it never rescales the track.
    @Test func fieldWithThePlayheadOutsideTheClipKeepsTheKeys() throws {
        let (m, s, id) = try rig()
        m.playhead = f(24); #expect(m.toggleSpeedKeyAtPlayhead()); refresh(m, s, id)
        m.playhead = f(500)
        m.setSpeedPercent(150); refresh(m, s, id)
        #expect(m.speedKeyTimes.first == f(24) && m.clip?.speedKeys != nil)
        #expect(m.clip!.duration == f(96))
    }

    @Test func switchOnAddsTheFirstKey() throws {
        let (m, s, id) = try rig()
        m.playhead = f(24)
        #expect(m.toggleSpeedAnimation() == .added)
        refresh(m, s, id)
        #expect(m.speedKeyTimes == [f(24)])
    }

    @Test func navigationJumpsBetweenSpeedKeys() throws {
        let (m, s, id) = try rig()
        for t in [24, 40] { m.playhead = f(Int64(t)); #expect(m.toggleSpeedKeyAtPlayhead()); refresh(m, s, id) }
        m.playhead = f(30)
        #expect(m.previousSpeedKeyTime() == f(24) && m.nextSpeedKeyTime() == f(40))
        var seeks: [Time] = []
        m.onSeek = { seeks.append($0) }
        m.goToNextSpeedKey(); m.goToPreviousSpeedKey()
        #expect(seeks == [f(40), f(24)])
        m.playhead = f(40)
        #expect(m.speedKeyControlState().keyIsOn && m.nextSpeedKeyTime() == nil && m.previousSpeedKeyTime() == f(24))
    }

    private func gesture(_ k: SpeedKeys, hit: SpeedBand.Hit, addKey: Bool, at x: CGFloat = 240) -> SpeedBand.Gesture {
        // 10 pt per frame: x 240 = frame 24.
        SpeedBand.Gesture(keys: k, clipStart: .zero, hit: hit, start: CGPoint(x: x, y: 50), lane: CGRect(x: 0, y: 0, width: 960, height: 100),
                          frameDuration: fd, addKey: addKey, option: false, shift: false, timeAt: { Time(Int64($0 / 10), 24) })
    }
    private func drag(_ s: EditorSession, _ id: Clip.ID, _ g: SpeedBand.Gesture, through keys: [SpeedKeys]) {
        s.applySpeedEdit(SpeedEdit(clip: id, keys: g.original, phase: .began, keepingKeys: g.keepsKeys))
        for k in keys { s.applySpeedEdit(SpeedEdit(clip: id, keys: k, phase: .changed, keepingKeys: g.keepsKeys)) }
        s.applySpeedEdit(SpeedEdit(clip: id, keys: keys.last ?? g.original, phase: .ended, keepingKeys: g.keepsKeys))
    }

    @Test func cmdClickOnTheBandAddsANoChangeKeyLikeTheDiamond() throws {
        let c = mk(0, 96)
        let s = try session([[c]], kinds: [.video])
        s.select(clips: [c.id])
        let g = gesture(SpeedKeys.of(c), hit: .segment(0), addKey: true)
        #expect(g.keepsKeys)
        drag(s, c.id, g, through: [g.update(to: g.start)])
        let r = try #require(s.activeTimeline?.tracks[0].clips.first)
        #expect(r.speedKeys?.boundaries == [.zero, f(24), f(96)] && r.duration == f(96))
        #expect(r.speedKeys?.segments.allSatisfy { $0.from == .normal } == true)
    }

    @Test func aDragBackToTheStartSpeedKeepsNoChangeKeys() throws {
        let c = mk(0, 96)
        let s = try session([[c]], kinds: [.video])
        s.select(clips: [c.id])
        #expect(s.addSpeedKey(clip: c.id, atLocal: f(24)))
        let keyed = try #require(s.activeTimeline?.tracks[0].clips.first?.speedKeys)
        let g = gesture(keyed, hit: .segment(1), addKey: false)
        #expect(g.keepsKeys)
        // Faster, then back to 100 %: the result only depends on the track at mouse-down.
        drag(s, c.id, g, through: [keyed.settingSpeed(ofSegment: 1, to: pct(200), frameDuration: fd), keyed])
        #expect(s.activeTimeline?.tracks[0].clips.first?.speedKeys == keyed)
    }

    @Test func aDragOnAKeyedTrackBackToOneSpeedStillCollapses() throws {
        let c = mk(0, 96)
        let s = try session([[c]], kinds: [.video])
        s.select(clips: [c.id])
        let (n, b) = SpeedKeys.of(c).addingKey(at: f(24), frameDuration: fd)!
        let two = n.settingSpeed(ofSegment: b, to: pct(300), frameDuration: fd)
        drag(s, c.id, gesture(SpeedKeys.of(c), hit: .segment(0), addKey: false), through: [two])
        let g = gesture(try #require(s.activeTimeline?.tracks[0].clips.first?.speedKeys), hit: .segment(1), addKey: false)
        #expect(!g.keepsKeys)
        drag(s, c.id, g, through: [two.settingSpeed(ofSegment: 1, to: ClipSpeed.normal, frameDuration: fd)])
        #expect(s.activeTimeline?.tracks[0].clips.first?.speedKeys == nil)
    }

    @Test func frameModeIsStoredAndResetWithSpeed() throws {
        let (m, s, id) = try rig()
        #expect(m.timeInterpolation == .frameSampling)
        for mode in [TimeInterpolation.frameBlend, .opticalFlow] {
            m.setTimeInterpolation(mode); refresh(m, s, id)
            #expect(m.timeInterpolation == mode)
        }
        m.resetSpeed(); refresh(m, s, id)
        #expect(m.timeInterpolation == .frameSampling)
    }

    @Test func audioClipsGetNoSpeedKeys() throws {
        let a = mk(0, 48, kind: .audio)
        let s = try session([[a]], kinds: [.audio])
        let m = EffectControlsModel()
        m.speedSession = s; m.setClip(a)
        #expect(!m.speedKeysAvailable && !m.toggleSpeedKeyAtPlayhead())
    }
}

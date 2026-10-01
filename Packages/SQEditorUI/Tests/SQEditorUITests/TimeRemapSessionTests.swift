import CoreGraphics
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQEditorUI

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
        #expect(s.undoName == "Time Remapping")
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
        #expect(SpeedLabel.nameSuffix(for: r) == " [Remapped]")
    }
}

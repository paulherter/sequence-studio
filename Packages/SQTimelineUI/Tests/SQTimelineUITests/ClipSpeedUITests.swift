#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 24)
private func f(_ n: Int64) -> Time { fd * n }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
private func mk(_ start: Int64, from: Int64 = 0, _ frames: Int64, kind: TrackKind = .video, link: UUID? = nil,
                speed: ClipSpeed = .normal, reversed: Bool = false) -> Clip {
    Clip(name: "clip", media: UUID(), kind: kind, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         link: link, mediaDuration: f(2000), speed: speed, reversed: reversed)
}

@Suite struct SpeedLabelTests {
    @Test func badgeText() {
        #expect(SpeedLabel.text(speed: pct(200), reversed: false) == "200%")
        #expect(SpeedLabel.text(speed: .normal, reversed: true) == "-100%")
        #expect(SpeedLabel.text(speed: pct(33.33), reversed: false) == "33.33%")
        #expect(SpeedLabel.text(speed: pct(12.5), reversed: true) == "-12.5%")
        #expect(SpeedLabel.nameSuffix(for: mk(0, 10)) == "")
        #expect(SpeedLabel.nameSuffix(for: mk(0, 10, speed: pct(250))) == " [250%]")
        #expect(SpeedLabel.nameSuffix(for: mk(0, 10, reversed: true)) == " [-100%]")
    }
}

@Suite struct SpeedDialogModelTests {
    @Test func startsAtTheClipsValues() {
        let m = SpeedDialogModel(clips: [mk(0, 48, speed: pct(200), reversed: true)], frameDuration: fd)
        #expect(m.percent == 200 && m.duration == f(24) && m.reversed && m.keepsPitch && !m.hasChanges)
    }

    @Test func linkedSpeedComputesDuration() {
        var m = SpeedDialogModel(clips: [mk(0, 48)], frameDuration: fd)
        m.setPercent(200)
        #expect(m.duration == f(24) && m.hasChanges)
        #expect(m.change == SpeedChange(speed: pct(200), reversed: false, keepsPitch: true, ripple: false, holdingDuration: false))
    }

    @Test func durationComputesSpeed() {
        var m = SpeedDialogModel(clips: [mk(0, 48)], frameDuration: fd)
        m.setDuration(f(96))
        #expect(m.percent == 50)
        #expect(m.change.duration == f(96) && m.change.speed == nil)
    }

    @Test func unlinkedSpeedKeepsTheDuration() {
        var m = SpeedDialogModel(clips: [mk(0, 48)], frameDuration: fd)
        m.isLinked = false
        m.setPercent(200)
        #expect(m.duration == f(48))
        #expect(m.change.holdingDuration && m.change.speed == pct(200))
    }

    @Test func negativeSpeedMeansReverseAndPercentIsClamped() {
        var m = SpeedDialogModel(clips: [mk(0, 48)], frameDuration: fd)
        m.setPercent(-50)
        #expect(m.reversed && m.percent == 50)
        m.setPercent(1_000_000)
        #expect(m.percent == 10_000)
        m.setPercent(0.01)
        #expect(m.percent == 1)
    }

    @Test func severalClipsDisableTheDurationField() {
        var m = SpeedDialogModel(clips: [mk(0, 48), mk(100, 24)], frameDuration: fd)
        #expect(!m.canEditDuration)
        m.setDuration(f(10))
        #expect(!m.hasChanges)
        m.isLinked = false
        m.setPercent(200)
        #expect(!m.change.holdingDuration)
    }

    @Test func reverseOnlyIsAChange() {
        var m = SpeedDialogModel(clips: [mk(0, 48)], frameDuration: fd)
        m.reversed = true
        #expect(m.hasChanges && m.change.reversed == true && m.change.speed == .normal)
    }
}

@Suite struct RateStretchGestureTests {
    private func interaction(_ tl: Timeline, tool: TimelineTool) -> TimelineInteraction {
        var i = TimelineInteraction(timeline: tl, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: tool, snapping: false, linkedSelection: true)
        return i
    }
    private func X(_ frame: Double) -> CGFloat { TimelineGeometry.contentOriginX + CGFloat(frame) * 4 }

    @Test func keyRSelectsTheRateStretchTool() {
        #expect(TimelineTool(key: "r") == .rateStretch)
        #expect(CommandMap.premiereDefault.entries.contains { $0.command == .tool(.rateStretch) })
        #expect(CommandMap.premiereDefault.entries.contains { $0.command == .speedDuration })
    }

    @Test func draggingTheTailChangesSpeedAndCommitsOneStep() throws {
        let c = mk(0, 48)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        tl.tracks[0] = Track(kind: .video, clips: [c])
        var i = interaction(tl, tool: .rateStretch)
        let y: CGFloat = 40
        i.mouseDown(CGPoint(x: X(47), y: y), modifiers: [])
        i.mouseDragged(CGPoint(x: X(30), y: y), modifiers: [])
        i.mouseDragged(CGPoint(x: X(23), y: y), modifiers: [])           // tail from frame 48 to 24
        let up = i.mouseUp(CGPoint(x: X(23), y: y), modifiers: [])
        let commit = try #require(up)
        #expect(commit.undoName == "Stretch" && commit.edits.count == 1)
        let r = try #require(commit.timeline.tracks[0].clips.first)
        #expect(r.duration == f(24) && r.speed == pct(200) && r.source.duration == f(48))
    }

    @Test func rateStretchEditReplaysOnTheSessionTimeline() throws {
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [mk(0, 48)])])
        let id = tl.tracks[0].clips[0].id
        try TimelineEdit.rateStretch(id, edge: .tail, by: f(-24)).apply(to: &tl)
        #expect(tl.tracks[0].clips[0].speed == pct(200))
        try TimelineEdit.speed([id], SpeedChange(speed: pct(50))).apply(to: &tl)
        #expect(tl.tracks[0].clips[0].duration == f(96))
    }

    @Test func cursorRegionsForRateStretch() {
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [mk(0, 48)])])
        let regions = TimelineCursorMap.regions(timeline: tl, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4),
                                                tool: .rateStretch, content: CGRect(x: 150, y: 20, width: 800, height: 300))
        #expect(regions.map(\.kind) == [.rateIn, .rateOut])
    }
}

@Suite struct ReversedWaveformTests {
    @Test func reversedColumnsAreTheMirrorImage() {
        // Ramp of peaks: level rises with time.
        let levels: [Float] = (0..<256).flatMap { i -> [Float] in [-Float(i) / 256, Float(i) / 256] }
        let data = WaveformData(sampleRate: 48_000, channelCount: 1, totalFrames: 256 * 256, baseBucketSize: 256, levels: [levels])
        let src = TimeRange(start: .zero, duration: Time(256 * 256, 48_000))
        var input = WaveformPath.Input(data: data, source: src, clipWidth: 64, visibleColumns: 0..<64)
        let forward = WaveformPath.columns(input)[0]
        input.reversed = true
        let back = WaveformPath.columns(input)[0]
        #expect(back.map(\.hi) == forward.map(\.hi).reversed())
        input.visibleColumns = 10..<20
        let part = WaveformPath.columns(input)[0]
        #expect(part.map(\.hi) == Array(back[10..<20].map(\.hi)))
    }
}

@MainActor @Suite struct SessionSpeedTests {
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir))
    }

    @Test func applyIsOneUndoStepForALinkedPair() throws {
        let l = UUID()
        let s = try session([[mk(0, 48, link: l)], [mk(0, 48, kind: .audio, link: l)]], kinds: [.video, .audio])
        let v = try #require(s.activeTimeline?.tracks[0].clips.first)
        let a = try #require(s.activeTimeline?.tracks[1].clips.first)
        s.select(clips: [v.id, a.id])          // a plain click selects the pair (Option would pick one alone)
        #expect(s.canSetSpeed && s.speedDialogModel() != nil)
        let depth = s.undoName
        #expect(s.applySpeed(SpeedChange(speed: pct(200), reversed: true)))
        for t in s.activeTimeline!.tracks {
            #expect(t.clips[0].duration == f(24) && t.clips[0].reversed)
        }
        #expect(s.undoName == "Speed")
        #expect(s.undo())
        for t in s.activeTimeline!.tracks { #expect(t.clips[0].speed == .normal && t.clips[0].duration == f(48)) }
        _ = depth
    }

    @Test func stillsAndEmptySelectionsAreRefused() throws {
        var still = mk(0, 48)
        still.isStill = true
        let s = try session([[still]], kinds: [.video])
        s.select(clips: [still.id])
        #expect(!s.canSetSpeed && s.speedDialogModel() == nil && !s.applySpeed(SpeedChange(speed: pct(200))))
    }

    @Test func contextMenuEnablesSpeedForMediaClips() {
        let c = mk(0, 10)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        let items = TimelineContextMenu.items(timeline: tl, selection: [c.id], clipboardHasClips: false)
        #expect(items.first { $0.action == .speed }?.isEnabled == true)
        let none = TimelineContextMenu.items(timeline: tl, selection: [], clipboardHasClips: false)
        #expect(none.first { $0.action == .speed }?.isEnabled == false)
    }
}

import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession(duration: Time = s(10), fps: Time = Time(1, 30)) -> (EditorSession, StubProgramEngine, MediaRef) {
    let engine = StubProgramEngine()
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: fps, isVariableFrameRate: false)
    let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
    let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                     duration: duration, info: MediaInfo(duration: duration, video: v, audio: a))
    let session = EditorSession(engine: engine, autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
        .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
    session.perform("Import") { $0.add(m) }
    return (session, engine, m)
}

@MainActor @Suite struct ReviewRound2Tests {
    // Review finding 2: placeMedia kept raw (off-grid) source durations.
    @Test func placeMediaStaysOnFrameGrid() {
        let (session, _, m) = makeSession(duration: Time(1001, 100))
        #expect(session.placeMedia([m.id, m.id], at: .zero))
        let fd = session.activeTimeline!.frameDuration
        for c in session.activeTimeline!.tracks.flatMap(\.clips) {
            #expect(c.start == c.start.snapped(to: fd))
            #expect(c.source.duration == c.source.duration.snapped(to: fd))
        }
    }

    // Finding 9: opening or creating a project left playback, In/Out range and clipboard of the old one alive.
    @Test func newProjectStopsPlaybackAndDropsOldState() {
        let (session, engine, m) = makeSession()
        session.placeMedia([m.id], at: .zero)
        session.selectAllClips()
        #expect(session.copySelection())
        session.playPause()
        session.bounds.range = TimeRange(start: .zero, duration: s(1))
        #expect(session.isPlaying)
        session.newProject()
        #expect(!session.isPlaying && engine.rate.isPaused)
        #expect(session.bounds.range == nil)
        #expect(session.clipboard == nil)
    }

    // Finding 31: a refused replace (every caption track locked) returned 0 instead of nil.
    @Test func replaceCaptionTextRefusedIsNil() {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        session.replaceCaptions([CaptionItem(lines: ["cat"], range: TimeRange(start: s(0), end: s(1)), styleRef: "default")])
        session.perform("lock") { p in
            let id = p.timelines[0].id
            _ = try? p.edit(id) { for i in $0.captionTracks.indices { $0.captionTracks[i].isLocked = true } }
        }
        #expect(session.replaceCaptionText(find: "cat", with: "fox", caseSensitive: false) == nil)
    }

    // Findings 14, 15: huge hour or frame fields overflowed the timecode maths and trapped.
    @Test func hugeTimecodeIsRejected() {
        let tc = Timecode(frameDuration: Time(1, 30), dropFrame: false)
        #expect(tc.parse("9999999999999:00:00:00") == nil)
        #expect(tc.parse("1:00:00:00") != nil)
        let fd = Time(1, 30)
        #expect(MarkersPanelModel.parseTimecode("9999999999999:00:00:00", frameDuration: fd) == nil)
        #expect(MarkersPanelModel.parseTimecode("9999999999999999", frameDuration: fd) == nil)
        #expect(MarkersPanelModel.parseTimecode("01:00:00:00", frameDuration: fd) != nil)
    }

    // Finding 16: Create Captions "Minimum duration" of 1e30 / inf trapped on the Int64 conversion.
    @Test func captionMinimumDurationIsClamped() {
        #expect(CaptionsPanelModel.minDuration(seconds: 1e30) == Time(3600, 1))
        #expect(CaptionsPanelModel.minDuration(seconds: .infinity) == Time(3600, 1))
        #expect(CaptionsPanelModel.minDuration(seconds: .nan) == .zero)
        #expect(CaptionsPanelModel.minDuration(seconds: -4) == .zero)
        #expect(CaptionsPanelModel.minDuration(seconds: 1.5) == Time(3, 2))
    }

    // Finding 17: NaN pixels trapped in the 8-bit conversion.
    @Test func nanPixelsConvertToZero() {
        #expect(FrameSampler.display8(SIMD3<Float>(.nan, 0, 1)).x == 0)
        #expect(FrameSampler.byte(.nan) == 0)
        #expect(FrameSampler.byte(2) == 255)
    }

    // Finding 18: a probe with a zero frame duration trapped in the duration columns and hover scrub.
    @Test func zeroFrameDurationDoesNotTrap() {
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(0, 1), isVariableFrameRate: false)
        let m = MediaRef(name: "A", path: "/x.mov", fingerprint: MediaFingerprint(size: 1),
                         duration: s(10), info: MediaInfo(duration: s(10), video: v, audio: nil))
        #expect(ProjectPanelModel.durationString(m) == "00:00:10")
        #expect(ProjectPanelModel.timecode(s(10), frameDuration: Time(0, 1)) == "00:00:10")
        #expect(HoverScrub.poster(duration: s(10), frameDuration: Time(0, 1)) <= Time(2, 1))
    }

    // Finding 24: OK with the unchanged speed or duration still applied a no-op SpeedChange.
    @Test func unchangedSpeedDialogHasNoChanges() {
        let fd = Time(1, 24)
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 48), start: .zero,
                        link: nil, mediaDuration: fd * 2000)
        var m = SpeedDialogModel(clips: [clip], frameDuration: fd)
        m.setPercent(100)
        #expect(!m.hasChanges)
        m.setDuration(fd * 48)
        #expect(!m.hasChanges)
        m.setPercent(200)
        #expect(m.hasChanges)
        m.setPercent(100)
        #expect(!m.hasChanges)
    }
}

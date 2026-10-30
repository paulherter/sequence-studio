import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor
struct ReplaceModesSessionTests {
    private func media(_ dur: Int64) -> MediaRef {
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 24), isVariableFrameRate: false)
        return MediaRef(name: "New", path: "/nonexistent/new.mov", fingerprint: MediaFingerprint(size: 1),
                        duration: s(dur), info: MediaInfo(duration: s(dur), video: v, audio: nil))
    }

    /// Main track: A[0-4] B[4-8] (source 10..14).
    private func rig(_ dur: Int64, fastCut: Bool = true) -> (EditorSession, Clip, MediaRef) {
        func c(_ start: Int64) -> Clip {
            Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(10), duration: s(4)), start: s(start), mediaDuration: s(100))
        }
        var t = Timeline(name: "t", frameDuration: Time(1, 24), tracks: [Track(kind: .video, clips: [c(0), c(4)]), Track(kind: .audio)])
        if fastCut { t.setEditMode(.magnetic) }
        let m = media(dur)
        var p = Project(name: "P", timelines: [t])
        p.add(m)
        let ses = EditorSession(project: p)
        return (ses, t.tracks[0].clips[0], m)
    }

    @Test func fromStartKeepsTheClipLengthAndIsOneUndoStep() throws {
        let (ses, clip, m) = rig(30)
        let before = try #require(ses.activeTimeline)
        #expect(ses.replaceOnMainTrack(clip.id, withMedia: m.id, mode: .fromStart))
        let now = try #require(ses.activeTimeline?.tracks[0].clips.first)
        #expect(now.id == clip.id && now.media == m.id && now.timeline.duration == s(4) && now.source.start == .zero)
        #expect(ses.lastError == nil)
        ses.undo()
        #expect(ses.activeTimeline == before)
    }

    @Test func shortMediaWarnsInTheStatusLine() throws {
        let (ses, clip, m) = rig(2)
        #expect(ses.replaceOnMainTrack(clip.id, withMedia: m.id, mode: .fromStart))
        #expect(ses.lastError?.contains("shorter") == true)
        #expect(ses.activeTimeline?.tracks[0].clips.first?.timeline.duration == s(2))
    }

    @Test func fromEndUsesTheEndOfTheMedia() throws {
        let (ses, clip, m) = rig(30)
        #expect(ses.replaceOnMainTrack(clip.id, withMedia: m.id, mode: .fromEnd))
        let now = try #require(ses.activeTimeline?.tracks[0].clips.first)
        #expect(now.source.end == s(30) && now.timeline.duration == s(4))
    }

    @Test func withRetimeFitsTheWholeMediaIntoTheClip() throws {
        let (ses, clip, m) = rig(8)
        #expect(ses.replaceOnMainTrack(clip.id, withMedia: m.id, mode: .withRetime))
        let now = try #require(ses.activeTimeline?.tracks[0].clips.first)
        #expect(now.timeline.duration == s(4) && now.source.duration == s(8))
    }

    @Test func atPlayheadLinesTheSourceFrameUpWithThePlayhead() throws {
        let (ses, clip, m) = rig(30)
        ses.seekSequence(to: s(2))
        #expect(ses.replaceOnMainTrack(clip.id, withMedia: m.id, mode: .atPlayhead, sourceAnchor: s(12)))
        let now = try #require(ses.activeTimeline?.tracks[0].clips.first)
        #expect(now.source.start == s(10) && now.timeline.duration == s(4))
    }

    @Test func refusesOutsideFastCutAndExplainsWhy() throws {
        let (ses, clip, m) = rig(30, fastCut: false)
        #expect(!ses.replaceOnMainTrack(clip.id, withMedia: m.id, mode: .fromStart))
        #expect(ses.lastError != nil)
    }
}

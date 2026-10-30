import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func media(_ name: String, _ dur: Int64) -> MediaRef {
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
    let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
    return MediaRef(name: name, path: "/nonexistent/\(name).mov", fingerprint: MediaFingerprint(size: 1),
                    duration: s(dur), info: MediaInfo(duration: s(dur), video: v, audio: a))
}

@MainActor @Suite struct ReplaceMediaSessionTests {
    private func rig() -> (EditorSession, MediaRef, MediaRef) {
        let a = media("A", 10), b = media("B", 20)
        let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
        session.perform("Import") { $0.add(a); $0.add(b) }
        return (session, a, b)
    }

    @Test func replacesMediaUsesInMarkAndUndoesInOneStep() throws {
        let (session, a, b) = rig()
        #expect(session.sourceEdit(media: a.id, mode: .overwrite))
        let clip = try #require(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first)
        session.setSourceMarks(SourceMarks(markIn: s(3), markOut: nil), for: b.id)
        let before = session.activeTimeline!
        #expect(session.replaceMedia(of: clip.id, with: b.id))
        let now = try #require(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first)
        #expect(now.media == b.id && now.start == clip.start && now.duration == clip.duration && now.source.start == s(3))
        #expect(session.activeTimeline?.tracks.first { $0.kind == .audio }?.clips.first?.media == b.id)
        session.undo()
        #expect(session.activeTimeline! == before)
    }

    @Test func matchFrameUsesTheSourceTimeAtThePlayhead() throws {
        let (session, a, b) = rig()
        #expect(session.sourceEdit(media: a.id, mode: .overwrite))
        let clip = try #require(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first)
        session.seek(to: s(4))
        #expect(session.replaceMedia(of: clip.id, with: b.id, matchSourceTime: s(12)))
        #expect(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first?.source.start == s(8))
    }

    @Test func tooShortMediaIsRefusedAndReported() throws {
        let (session, a, _) = rig()
        let short = media("S", 4)
        session.perform("Import") { $0.add(short) }
        #expect(session.sourceEdit(media: a.id, mode: .overwrite))
        let clip = try #require(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first)
        #expect(!session.replaceMedia(of: clip.id, with: short.id))
    }

    @Test func unknownMediaSetsAnError() throws {
        let (session, a, _) = rig()
        #expect(session.sourceEdit(media: a.id, mode: .overwrite))
        let clip = try #require(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first)
        #expect(!session.replaceMedia(of: clip.id, with: UUID()))
        #expect(session.lastError != nil)
    }

    @Test func severalItemsUseTheFirstAndSayso() throws {
        let (session, a, b) = rig()
        #expect(session.sourceEdit(media: a.id, mode: .overwrite))
        let clip = try #require(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first)
        #expect(session.replaceMedia(of: clip.id, withFirstOf: [b.id, a.id]))
        #expect(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first?.media == b.id)
        #expect(session.lastError == "Replaced with the first of 2 items.")
    }

    @Test func singleItemSaysNothingExtra() throws {
        let (session, a, b) = rig()
        #expect(session.sourceEdit(media: a.id, mode: .overwrite))
        let clip = try #require(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first)
        #expect(session.replaceMedia(of: clip.id, withFirstOf: [b.id]))
        #expect(session.lastError == nil)
        #expect(!session.replaceMedia(of: clip.id, withFirstOf: []))
    }
}

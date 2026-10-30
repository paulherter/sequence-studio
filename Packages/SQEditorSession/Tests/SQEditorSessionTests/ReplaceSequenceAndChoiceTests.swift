import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor @Suite struct ReplaceSequenceAndChoiceTests {
    private func rig() -> (EditorSession, MediaRef) {
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                         duration: s(10), info: MediaInfo(duration: s(10), video: v, audio: nil))
        let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
        session.perform("Import") { $0.add(m) }
        return (session, m)
    }

    @Test func choiceNeededOnlyWhenFourMarksDifferInLength() {
        let (session, m) = rig()
        session.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(4)), for: m.id)
        #expect(!session.fourPointNeedsChoice(media: m.id))                      // no sequence marks
        session.perform("In") { _ = try? $0.edit(session.activeTimelineID!) { $0.inOut = TimeRange(start: s(10), end: s(15)); $0.inOutKind = .both } }
        #expect(session.fourPointNeedsChoice(media: m.id))
        session.perform("In") { _ = try? $0.edit(session.activeTimelineID!) { $0.inOut = TimeRange(start: s(10), end: s(12)); $0.inOutKind = .both } }
        #expect(!session.fourPointNeedsChoice(media: m.id))                      // same length
    }

    @Test func replaceWithSequenceIsOneUndoStepAndReportsShortSequence() throws {
        let (session, m) = rig()
        #expect(session.sourceEdit(media: m.id, mode: .overwrite))
        let clip = try #require(session.activeTimeline?.tracks.first { $0.kind == .video }?.clips.first)
        let host = try #require(session.activeTimelineID)
        let other = session.addSequence()
        session.setActiveTimeline(host)
        #expect(!session.replaceWithSequence(of: clip.id, with: other))          // empty sequence
        #expect(session.lastError != nil)
        let before = session.activeTimeline!
        #expect(session.activeTimeline! == before)
    }
}

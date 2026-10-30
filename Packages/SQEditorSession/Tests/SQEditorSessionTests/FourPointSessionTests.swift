import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor @Suite struct FourPointSessionTests {
    private func setup(_ fit: FourPointFit) -> [Clip] {
        let engine = StubProgramEngine()
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                         duration: s(10), info: MediaInfo(duration: s(10), video: v, audio: nil))
        let session = EditorSession(engine: engine, autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
        session.perform("Import") { $0.add(m) }
        session.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(4)), for: m.id)
        session.perform("In") { _ = try? $0.edit(session.activeTimelineID!) { $0.inOut = TimeRange(start: s(10), end: s(15)); $0.inOutKind = .both } }
        #expect(session.sourceEdit(media: m.id, streams: .videoOnly, mode: .overwrite, fourPointFit: fit))
        return session.activeTimeline!.tracks.flatMap(\.clips)
    }

    @Test func defaultUsesSequenceRangeAndSourceIn() {
        let c = setup(.trimSourceEnd)
        #expect(c.count == 1 && c[0].start == s(10) && c[0].source == TimeRange(start: s(2), end: s(7)))
    }

    @Test func ignoreSourceInUsesSourceOut() {
        let c = setup(.ignoreSourceIn)
        #expect(c[0].start == s(10) && c[0].source == TimeRange(start: s(0), end: s(4)))
    }

    @Test func ignoreSequenceOutUsesSourceLengthAtSequenceIn() {
        let c = setup(.ignoreSequenceOut)
        #expect(c[0].start == s(10) && c[0].source == TimeRange(start: s(2), end: s(4)))
    }

    @Test func ignoreSequenceInEndsAtSequenceOut() {
        let c = setup(.ignoreSequenceIn)
        #expect(c[0].start == s(13) && c[0].source == TimeRange(start: s(2), end: s(4)))
    }
}

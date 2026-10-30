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

@MainActor @Suite struct ReelFillSessionTests {
    private func rig() -> (EditorSession, [MediaRef]) {
        let ms = [media("A", 10), media("B", 20), media("C", 30)]
        let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
        session.perform("Import") { p in ms.forEach { p.add($0) } }
        #expect(session.sourceEdit(media: ms[0].id, mode: .overwrite))
        return (session, ms)
    }

    private func videoClips(_ t: Timeline?) -> [Clip] {
        (t?.tracks.first { $0.kind == .video }?.clips ?? []).sorted { $0.start < $1.start }
    }

    @Test func fillIntoCopyKeepsTheTemplateAndUndoesInOneStep() throws {
        let (session, ms) = rig()
        let templateID = try #require(session.activeTimelineID)
        let template = try #require(session.activeTimeline)
        let slots = session.reelSlotCount
        #expect(slots >= 1)
        let report = try #require(session.fillReel(with: [ms[1].id, ms[2].id]))
        #expect(!report.filled.isEmpty)
        #expect(session.activeTimelineID != templateID)
        #expect(session.project.timelines.first { $0.id == templateID } == template)
        let filled = videoClips(session.activeTimeline)
        #expect(filled.first?.media == ms[1].id)
        #expect(Set(filled.map(\.id)).isDisjoint(with: Set(videoClips(template).map(\.id))))
        session.undo()
        #expect(session.project.timelines.count == 1)
    }

    @Test func stillWithoutLengthFillsTheSlotWithItsLength() throws {
        let (session, ms) = rig()
        let slotLength = try #require(videoClips(session.activeTimeline).first).duration
        let v = VideoTrackInfo(width: 1000, height: 1000, codec: "png", bitDepth: 8, chroma: "4:4:4",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let still = MediaRef(name: "S", path: "/nonexistent/S.png", fingerprint: MediaFingerprint(size: 2),
                             duration: nil, info: MediaInfo(duration: .zero, video: v, audio: nil, isStill: true))
        session.perform("Import") { $0.add(still) }
        let report = try #require(session.fillReel(with: [still.id, ms[1].id]))
        #expect(!report.filled.isEmpty)
        let first = try #require(videoClips(session.activeTimeline).first)
        #expect(first.isStill && first.media == still.id && first.duration == slotLength)
    }

    @Test func emptySequenceIsRefused() {
        let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
        #expect(session.fillReel(with: []) == nil)
    }
}

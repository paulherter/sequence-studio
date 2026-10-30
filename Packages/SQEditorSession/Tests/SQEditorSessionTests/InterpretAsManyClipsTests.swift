import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// Interpret As on several clips at once: one undo step, Automatic (nil) clears it, unchanged clips make no step.
@MainActor @Suite struct InterpretAsManyClipsTests {
    private func make() throws -> (EditorSession, [Clip]) {
        var t = Track(kind: .video)
        var clips: [Clip] = []
        for i in 0..<3 {
            let c = Clip(name: "v\(i)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(Int64(i) * 2, 1))
            try t.overwrite(c); clips.append(c)
        }
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [t])]),
                              engine: StubProgramEngine())
        return (s, clips)
    }

    private func source(_ s: EditorSession, _ id: Clip.ID) -> ColorSpaceID? {
        s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id }?.footageColor.source
    }

    @Test func setsEveryClipInOneUndoStep() throws {
        let (s, clips) = try make()
        #expect(s.setInterpretation(.hlgBT2020, for: clips.map(\.id)) == 3)
        #expect(clips.allSatisfy { source(s, $0.id) == .hlgBT2020 })
        _ = s.undo()
        #expect(clips.allSatisfy { source(s, $0.id) == nil })
    }

    @Test func automaticClearsAndUnchangedIsNoStep() throws {
        let (s, clips) = try make()
        #expect(s.setInterpretation(nil, for: clips.map(\.id)) == 0)
        #expect(!s.canUndo)
        _ = s.setInterpretation(.pqBT2020, for: [clips[0].id])
        #expect(s.setInterpretation(nil, for: clips.map(\.id)) == 1)
        #expect(source(s, clips[0].id) == nil)
    }
}

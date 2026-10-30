import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// H6 3/4 review fixes, session side: Paste Settings > Transform clears the pending v10 Scale marker, and Relink probes
/// the new file (off the main thread) and runs the owed Scale step.
@MainActor @Suite struct PendingScaleSessionTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private let fd = Time(1, 30)

    private func info(w: Int, h: Int) -> MediaInfo {
        MediaInfo(duration: s(10), video: VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 10, chroma: "4:2:0",
                                                         nominalFrameDuration: fd, isVariableFrameRate: false))
    }

    /// 1920x1080 sequence, one clip at Scale 200 % on media without probe info, marked pending (as a v9 file decodes).
    private func pendingProject(extra: (inout Project) -> Void = { _ in }) throws -> (Project, MediaRef.ID) {
        let m = MediaRef(name: "m.mov", path: "/offline/m.mov", fingerprint: MediaFingerprint(size: 1), duration: s(10))
        var c = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        c.animation.scale = AnimatedProperty(Vec2(2, 2))
        var p = Project(name: "P", timelines: [Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd),
                                                        tracks: [Track(kind: .video, clips: [c])])])
        p.add(m)
        extra(&p)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectFile.write(p, to: dir)
        let file = dir.appendingPathComponent("project.json")
        var obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var proj = try #require(obj["project"] as? [String: Any])
        var tls = try #require(proj["timelines"] as? [[String: Any]])
        var tracks = try #require(tls[0]["tracks"] as? [[String: Any]])
        var clips = try #require(tracks[0]["clips"] as? [[String: Any]])
        clips[0]["pendingSourcePixelScale"] = true
        tracks[0]["clips"] = clips; tls[0]["tracks"] = tracks; proj["timelines"] = tls; obj["project"] = proj
        try JSONSerialization.data(withJSONObject: obj).write(to: file)
        let back = try ProjectFile.read(from: dir)
        #expect(back.timelines[0].tracks[0].clips[0].pendingSourcePixelScale)
        return (back, m.id)
    }

    @Test func pasteMotionGroupClearsThePendingMarker() throws {
        let (p, _) = try pendingProject()
        let target = p.timelines[0].tracks[0].clips[0]
        var src = Clip(name: "s", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        src.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
        #expect(!target.pastingAttributes(from: src, groups: [.motion]).pendingSourcePixelScale)
        #expect(target.pastingAttributes(from: src, groups: [.opacity]).pendingSourcePixelScale)   // Scale untouched
    }

    /// A pending source pasted onto a clip whose media has probe info: the target is converted with its own fit and is
    /// not pending (a later relink must not convert it again).
    @Test func pastingAPendingSourceOntoKnownMediaConvertsTheTarget() throws {
        let known = MediaRef(name: "k.mov", path: "/k.mov", fingerprint: MediaFingerprint(size: 2), duration: s(10),
                             info: info(w: 7680, h: 4320))   // fit 0.25 in 1920x1080
        let target = Clip(name: "t", media: known.id, kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: s(5))
        let (p, _) = try pendingProject { p in
            p.add(known)
            p.timelines[0].tracks[0] = Track(kind: .video, clips: p.timelines[0].tracks[0].clips + [target])
        }
        let session = EditorSession(project: p, engine: StubProgramEngine(),
                                    autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let source = session.project.timelines[0].tracks[0].clips[0]
        session.select(clips: [source.id]); #expect(session.copySelection())
        session.select(clips: [target.id])
        #expect(session.pasteAttributes(groups: [.motion]))
        let out = try #require(session.project.timelines[0].tracks[0].clips.first { $0.id == target.id })
        #expect(!out.pendingSourcePixelScale)
        #expect(out.animation.scale.value == Vec2(0.5, 0.5))   // 200 % of its own fit (0.25)
        #expect(session.project.timelines[0].tracks[0].clips[0].pendingSourcePixelScale)   // the source is untouched
    }

    @Test func relinkProbesTheNewFileAndRunsThePendingStep() async throws {
        let (p, id) = try pendingProject()
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let probed = info(w: 3840, h: 2160)
        session.mediaInfoProbe = { (_: URL) in probed }
        session.relinkMedia([id: "/found/m.mov"])
        for _ in 0..<SQTiming.polls(100) where session.project.timelines[0].tracks[0].clips[0].pendingSourcePixelScale {
            try await Task.sleep(for: .milliseconds(20))
        }
        let c = session.project.timelines[0].tracks[0].clips[0]
        #expect(!c.pendingSourcePixelScale)
        #expect(c.animation.scale.value == Vec2(1, 1))   // fit 0.5
        #expect(session.project.media(id)?.info?.video?.width == 3840)
        // Undo goes back to the offline file: still pending, nothing converted.
        _ = session.undo()
        let before = session.project.timelines[0].tracks[0].clips[0]
        #expect(session.project.media(id)?.path == "/offline/m.mov")
        #expect(before.pendingSourcePixelScale)
        #expect(before.animation.scale.value == Vec2(2, 2))
        // Redo brings the converted state back.
        _ = session.redo()
        #expect(session.project.timelines[0].tracks[0].clips[0].animation.scale.value == Vec2(1, 1))
    }
}

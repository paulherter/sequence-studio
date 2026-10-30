import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI
@testable import SQMonitorUI

/// Edit page main-thread suspects: the Color panels live on the Color page only; playhead ticks must not reach them
/// while that page is hidden, and becoming active catches up.
@MainActor @Suite struct ColorPanelHiddenSyncTests {
    func rig() throws -> (EditorSession, ColorInspectorPanelView, Clip) {
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(600, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])
        var p = Project(name: "P", timelines: [t])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(600, 1)))]
        let session = EditorSession(project: p, engine: StubProgramEngine())
        session.select(clips: [clip.id])
        return (session, ColorInspectorPanelView(session: session), clip)
    }

    @Test func playheadTicksAreSkippedWhileInactive() throws {
        let (session, panel, _) = try rig()
        panel.sync([.project, .selection])
        let n = 3000
        func run(_ label: String) -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            for i in 0..<n {
                session.seek(to: Time(Int64(i % 500), 30))
                panel.sync([.playhead])
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(n)
            if let dir = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] {
                try? "colorView.sync playhead tick \(label): \(ms) ms\n".appendLine(to: dir)
            }
            return ms
        }
        _ = run("active")
        panel.isActive = false
        _ = run("inactive")
        #expect(panel.skippedSyncs == n)
    }

    @Test func becomingActiveCatchesUp() throws {
        let (session, panel, _) = try rig()
        panel.sync([.project, .selection])
        panel.isActive = false
        session.seek(to: Time(1, 1))
        panel.sync([.playhead])
        #expect(panel.pendingWhileInactive.contains(.playhead))
        panel.isActive = true
        #expect(panel.pendingWhileInactive.isEmpty)
    }

    @Test func structuralChangesStillSyncWhileInactive() throws {
        let (_, panel, clip) = try rig()
        panel.isActive = false
        panel.sync([.project, .selection])
        #expect(panel.colorModels[clip.id] != nil)
    }
}

private extension String {
    func appendLine(to path: String) throws {
        let h = FileHandle(forWritingAtPath: path) ?? { FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path)! }()
        h.seekToEndOfFile(); h.write(Data(utf8)); try h.close()
    }
}

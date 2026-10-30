import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// Edit page main-thread suspects: what each `EditorPanels.sync` receiver costs per playhead tick during playback.
/// `SQ_PERF_OUT=<file>` appends one line per receiver.
@MainActor @Suite struct PlayheadFanOutTickTests {
    func rig() -> (EditorSession, Clip) {
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(600, 1)), start: .zero)
        var v = Track(kind: .video)
        try? v.overwrite(clip)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])
        var p = Project(name: "P", timelines: [t])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(600, 1)))]
        let session = EditorSession(project: p, engine: StubProgramEngine())
        session.select(clips: [clip.id])
        return (session, clip)
    }

    private func measure(_ session: EditorSession, _ label: String, _ body: () -> Void) {
        let n = 3000
        for i in 0..<200 { session.seek(to: Time(Int64(i % 500), 30)); body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<n { session.seek(to: Time(Int64(i % 500), 30)); body() }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(n)
        guard let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] else { return }
        let line = "fan-out \(label) playhead tick: \(ms) ms\n"
        let h = FileHandle(forWritingAtPath: path) ?? { FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path)! }()
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    }

    @Test func receiversPerTick() {
        let (session, _) = rig()
        let change: EditorSession.Change = [.playhead]
        let model = EffectControlsModel()
        model.sync(with: session, change: [.project, .selection])
        measure(session, "effectModel") { model.sync(with: session, change: change) }
        let sections = ClipSectionsView(session: session)
        sections.sync([.project, .selection])
        measure(session, "clipSections") { sections.sync(change) }
        let text = TextPanelView(session: session)
        text.sync([.project, .selection])
        measure(session, "textView") { text.sync(change) }
        let scopes = ScopesPanelView(session: session)
        measure(session, "scopesView") { scopes.sync(change) }
    }
}

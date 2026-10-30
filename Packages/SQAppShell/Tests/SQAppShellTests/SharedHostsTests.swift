import Foundation
import SQAppShell
import SQAudioFX
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQEditorSession
import SQMedia
import SQTranscribe
import SQUIKit
import Testing

/// A Program engine stand-in with a picture: what each platform backend (Windows `WinProgramEngine`, Mac
/// `MacPictureEngine`) hands the shared hosts.
@MainActor
final class PictureEngineStub: ProgramEngine, AppPictureSource {
    var position: Time = .zero
    var rate: PlaybackRate = .zero
    var quality: DecodeScale = .full
    #if os(macOS)
    var viewerZoom: ViewerZoom = .fit
    #endif
    var onPositionChange: (@MainActor (Time) -> Void)?
    func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {}
    func attach(_ layer: PreviewSurface?) {}
    func play(_ rate: PlaybackRate) { self.rate = rate }
    func pause() { rate = .zero }
    func seek(to t: Time) { position = t }
    func step(_ frames: Int) {}
    func beginScrub() {}
    func scrub(to t: Time) { position = t }
    func endScrub() {}

    var picture: AppPicture?
    var pictureGeneration = 0
    var hasPicture: Bool { picture != nil }
    var scopeReads = 0
    func scopePicture() -> AppPicture? { scopeReads += 1; return picture }
    var skippedFrames = 0
    var gains: [MonitorGain.Setting] = []
    func setMonitorGain(_ setting: MonitorGain.Setting) { gains.append(setting) }
    var channelStates: [ChannelMonitor] = []
    func setChannelMonitor(_ state: ChannelMonitor) { channelStates.append(state) }
    var meterReading: (sequence: Int, peaks: [Float])? = (3, [0.5, 0.25])
}

@MainActor
struct SharedHostsTests {
    private func session(_ engine: any ProgramEngine) -> EditorSession {
        EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: engine)
    }

    @Test func shownScopesReadTheEnginePicture() {
        let engine = PictureEngineStub()
        let host = MeterScopesHost(session: session(engine), engine: engine, picture: engine, menus: MenuController())
        let meter = DrawRect(x: 640, y: 0, w: 104, h: 360), card = DrawRect(x: 0, y: 0, w: 320, h: 360)
        engine.picture = AppPicture(bytes: [UInt8](repeating: 128, count: 16 * 8 * 4), width: 16, height: 8,
                                    fullRange: true, rgba: true)
        host.layout(meter: meter, scopes: card, scale: 1)
        #expect(engine.scopeReads == 0)          // Scopes hidden: no readback
        host.showsScopes = true
        host.layout(meter: meter, scopes: card, scale: 1)
        #expect(engine.scopeReads == 1)
        host.layout(meter: meter, scopes: .zero, scale: 1)
        #expect(engine.scopeReads == 1)          // no card: no readback
    }

    @Test func noPictureLeavesTheScopesEmpty() {
        let engine = PictureEngineStub()
        let host = MeterScopesHost(session: session(engine), engine: engine, picture: engine, menus: MenuController())
        host.showsScopes = true
        host.layout(meter: .zero, scopes: DrawRect(x: 0, y: 0, w: 320, h: 200), scale: 1)
        #expect(engine.scopeReads == 0)
        #expect(host.images.isEmpty)
    }

    @Test func monitoringGoesToTheEngineSeam() {
        let engine = PictureEngineStub()
        let host = MeterScopesHost(session: session(engine), engine: engine, picture: engine, menus: MenuController())
        host.meter.onChannelMonitorChange?(ChannelMonitor())
        #expect(engine.channelStates.count == 1)
    }

    @Test func captionsTakeFocusOnlyOnTheirCard() {
        let engine = PictureEngineStub()
        let s = session(engine)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let host = CaptionsHost(session: s, menus: shell.menuBar.controller, shell: shell)
        host.layout(nil)
        #expect(!host.handle(.mouseDown(x: 10, y: 10, modifiers: []), scale: 2))
        host.layout(CGRect(x: 100, y: 50, width: 300, height: 400))
        #expect(host.panel.size == CGSize(width: 300, height: 400))
        #expect(!host.handle(.mouseDown(x: 20, y: 20, modifiers: []), scale: 2))
        #expect(!host.hasFocus)
        #expect(host.handle(.mouseDown(x: 400, y: 300, modifiers: []), scale: 2))
        #expect(host.hasFocus)
        _ = host.handle(.mouseUp(x: 400, y: 300), scale: 2)
    }

    @Test func autoCaptionsOpensTheTranscribeTabAndSaysTheOutcome() async {
        let engine = PictureEngineStub()
        let s = session(engine)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        var lines: [String] = []
        shell.onStatus = { lines.append($0) }
        let host = CaptionsHost(session: s, menus: shell.menuBar.controller, shell: shell)
        // No speech engine on the panel yet: it says so and starts nothing.
        #expect(host.autoCaptions() == nil)
        #expect(lines.last == "Open a sequence first.")
        host.useTranscription { UnavailableTranscriptionService() }
        host.panel.select(.captions)
        guard let task = host.autoCaptions() else { Issue.record("expected a running task"); return }
        #expect(host.panel.tab == .transcript)
        #expect(lines.contains("Transcribing the sequence…"))
        #expect(await task.value == 0)
        #expect(lines.count >= 2)
    }

    @Test func theAutoCaptionsCommandRunsThroughTheCaptionsHost() {
        let engine = PictureEngineStub()
        let s = session(engine)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        var lines: [String] = []
        shell.onStatus = { lines.append($0) }
        let host = CaptionsHost(session: s, menus: shell.menuBar.controller, shell: shell)
        #expect(shell.execute(.autoCaptions))
        #expect(lines.last == "Open a sequence first.")
        _ = host
    }

    @Test func whooshNeedsASelectedCutAndTheMenuCommandIsWired() {
        let engine = PictureEngineStub()
        let s = session(engine)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        var lines: [String] = []
        shell.onStatus = { lines.append($0) }
        let host = LibraryHost(session: s, menus: shell.menuBar.controller, shell: shell, defaults: UserDefaults(suiteName: "sq.test.whoosh")!)
        #expect(shell.runWhooshAtCuts != nil)
        host.whoosh(URL(fileURLWithPath: "/tmp/none.wav"))
        #expect(lines.last == "Select a cut first: click an edge, or select clips next to each other.")
    }
}

import Foundation
import SQAppShell
import SQAudioFX
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI
import SQUIKit
import Testing

/// A monitor engine stand-in for the shared monitor card: what WinProgramEngine / MacPictureTap hand it.
@MainActor
final class MonitorEngineStub: AppMonitorEngine {
    let stub = PictureEngineStub()
    var player: any ProgramEngine { stub }
    var ticks = 0
    func tick() { ticks += 1 }
    var media: [MediaRef] = []
    func setMedia(_ media: [MediaRef]) { self.media = media }
    var exports: [String] = []
    func exportFrame(suggestedName: String, files: (any PanelFileChooser)?,
                     status: @escaping @MainActor @Sendable (String) -> Void) { exports.append(suggestedName) }
    var hasPicture: Bool { stub.hasPicture }
    var pictureGeneration: Int { stub.pictureGeneration }
    var skippedFrames: Int { 0 }
    func scopePicture() -> AppPicture? { stub.scopePicture() }
    func setMonitorGain(_ setting: MonitorGain.Setting) {}
    func setChannelMonitor(_ state: ChannelMonitor) {}
}

@MainActor
final class MonitorBackendStub: AppMonitorBackend {
    var made: [MonitorEngineStub] = []
    func makeSourceEngine() -> any AppMonitorEngine { let e = MonitorEngineStub(); made.append(e); return e }
    func makeStillEngine() -> any AppMonitorEngine { let e = MonitorEngineStub(); made.append(e); return e }
    var timelineMedia: (any TimelineMediaSource)? { nil }
}

/// A segmenter stand-in (the Mac `MacMagicMasks`).
@MainActor
final class MagicStub: AppMagicMasks {
    var clicks: [(p: Vec2, subtract: Bool, newMask: Bool)] = []
    func click(_ p: Vec2, target: Clip.ID?, subtract: Bool, newMask: Bool) { clicks.append((p, subtract, newMask)) }
    func refresh(target: Clip.ID?, magicOn: Bool, isPlaying: Bool) {}
}

@MainActor
struct MonitorCardTests {
    @Test func finderFilesOverTheSourceTabHighlightItAndReleaseHandsThemOver() {
        let (host, _, _, _) = card()
        let panel = host.source.panel
        panel.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        var got: [URL] = []
        panel.model.onDropFiles = { got = $0 }
        let url = URL(fileURLWithPath: "/tmp/a.mov")
        let x = Float(panel.frame.midX), y = Float(panel.frame.midY)
        // The Program tab leaves Finder files to the timeline.
        host.source.isShown = false
        #expect(!host.filesDragged([url], phase: .ended, x: x, y: y) && got.isEmpty && !panel.dropHighlight)
        host.source.isShown = true
        #expect(!host.filesDragged([url], phase: .moved, x: x, y: y))
        #expect(panel.dropHighlight && panel.dropZone == nil)
        #expect(!host.filesDragged([url], phase: .moved, x: -50, y: -50) && !panel.dropHighlight)
        #expect(host.filesDragged([url], phase: .ended, x: x, y: y))
        #expect(got == [url] && !panel.dropHighlight)
        #expect(!host.filesDragged([], phase: .canceled, x: x, y: y))
    }

    private func card() -> (MonitorCardHost, MonitorEngineStub, MonitorBackendStub, EditorSession) {
        let program = MonitorEngineStub()
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: program.stub)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let backend = MonitorBackendStub()
        let host = MonitorCardHost(session: s, shell: shell, program: program, backend: backend,
                                   effects: EffectControlsModel(), projectList: ProjectListView(host: shell),
                                   timelineHost: TimelineHost(), qualityDefaults: nil)
        return (host, program, backend, s)
    }

    @Test func theSourceGetsItsOwnEngineFromTheBackend() {
        let (host, program, backend, _) = card()
        #expect(backend.made.count >= 1)
        #expect(host.source.engine !== program)
        #expect(host.shownEngine === program)            // Program tab first
        host.source.isShown = true
        #expect(host.shownEngine === host.source.engine)
    }

    @Test func exportFrameGoesToTheProgramEngineSeam() {
        let (host, program, _, s) = card()
        host.applyMonitor(.exportFrame)
        #expect(program.exports == [(s.activeTimeline?.name ?? "Frame") + ".png"])
    }

    @Test func markInGoesToTheSession() {
        let (host, _, _, s) = card()
        host.applyMonitor(.markIn)
        #expect(s.activeTimeline?.explicitMarks.markIn == .zero)
    }

    @Test func pointerRulesKeepTheirOrder() {
        #expect(AppPointer.shape(.init()) == .arrow)
        #expect(AppPointer.shape(.init(divider: .horizontal)) == .resizeLeftRight)
        #expect(AppPointer.shape(.init(divider: .vertical)) == .resizeUpDown)
        #expect(AppPointer.shape(.init(keystoneEdge: true)) == .resizeLeftRight)
        #expect(AppPointer.shape(.init(textEditing: true)) == .iBeam)
        #expect(AppPointer.shape(.init(typeToolOverPicture: true)) == .iBeam)
        #expect(AppPointer.shape(.init(handOverTimeline: true)) == .openHand)
        // The eyedropper wins over everything, a divider over text.
        #expect(AppPointer.shape(.init(divider: .vertical, sampling: true, textEditing: true)) == .crosshair)
        #expect(AppPointer.shape(.init(divider: .horizontal, textEditing: true)) == .resizeLeftRight)
    }

    @Test func projectDragOverTheProgramMonitorShowsTheHalfAndOtherPhasesClearIt() {
        let (host, _, _, _) = card()
        let panel = host.monitor.panel
        panel.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        let ref = BinItemRef.media(MediaRef.ID())
        let x = Float(panel.frame.minX + 10), y = Float(panel.frame.midY)
        #expect(!host.projectDragged([ref], phase: .moved, x: x, y: y))
        #expect(panel.dropHighlight)
        #expect(panel.dropZone == .insert)                  // left half = Insert
        #expect(!host.projectDragged([ref], phase: .canceled, x: x, y: y))
        #expect(!panel.dropHighlight)
        #expect(panel.dropZone == nil)
        // Outside the card nothing is taken.
        #expect(!host.projectDragged([ref], phase: .ended, x: -50, y: -50))
    }

    @Test func projectItemsBecomeTimelineDropSources() {
        let m = MediaRef.ID(), t = Timeline.ID()
        #expect(TimelineDropRoute.source([.media(m), .sequence(t)]) == .media([m]))   // media first
        #expect(TimelineDropRoute.source([.sequence(t)]) == .sequences([t]))
        #expect(TimelineDropRoute.source([.bin(Bin.ID())]) == nil)
        #expect(TimelineDropRoute.source([]) == nil)
    }

    @Test func slipTwoUpWithoutAGestureShowsNothing() {
        let (_, _, _, s) = card()
        let slip = SlipTwoUpHost(session: s, backend: MonitorBackendStub())
        #expect(slip.tick() == nil)
        #expect(slip.image == nil)
    }

    @Test func sourceZoomGrowsThePictureQuadWhileTheEngineRendersAtFit() {
        let (host, _, _, _) = card()
        let source = host.source
        let engine = source.engine as? MonitorEngineStub
        source.layout(DrawRect(x: 0, y: 0, w: 800, h: 600), scale: 1)
        let fit = source.panel.canvasRect
        source.core.model.setZoom(.percent(400))
        source.layout(DrawRect(x: 0, y: 0, w: 800, h: 600), scale: 1)
        #expect(source.panel.canvasRect.width > fit.width * 2)
        #expect(source.panel.canvasRect.width > source.panel.slot.width)
        #if os(macOS)
        #expect(engine?.stub.viewerZoom == .fit)        // the quad zooms, the platform viewer scales with it
        #else
        _ = engine
        #endif
    }

    @Test func aSourceDragDrawsItsTileAtThePointerUntilItEnds() {
        let (host, _, _, _) = card()
        var empty = Canvas(width: 800, height: 600, atlas: nil, scale: 2)
        host.drawDragTile(&empty, scale: 2, theme: DrawTheme())
        #expect(empty.list.quads.isEmpty)
        host.source.panel.onSourceDrag?(.videoOnly, .moved, 400, 600)
        #expect(host.dragTile?.streams == .videoOnly)
        var c = Canvas(width: 800, height: 600, atlas: nil, scale: 2)
        host.drawDragTile(&c, scale: 2, theme: DrawTheme())
        #expect(!c.list.quads.isEmpty)
        let r = SourceDragGhost.layout(pointer: CGPoint(x: 200, y: 300), tipWidth: 40)
        #expect(abs(r.tile.midX - 204) < 0.5 && r.tile.minY == 300 - 53 + 4)   // the Mac drag frame: tile on the pointer
        #expect(r.tip.minY == r.tile.maxY + 6)
        host.source.panel.onSourceDrag?(.videoOnly, .ended, 400, 600)
        #expect(host.dragTile == nil)
    }

    @Test func offlineMediaUnderThePlayheadShowsTheOfflineCard() throws {
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        var p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])])
        p.media = [MediaRef(id: media, name: "a.mp4", path: "/nonexistent", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(2, 1)))]
        let program = MonitorEngineStub()
        let s = EditorSession(project: p, fileURL: nil, engine: program.stub)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let host = MonitorCardHost(session: s, shell: shell, program: program, backend: MonitorBackendStub(),
                                   effects: EffectControlsModel(), projectList: ProjectListView(host: shell),
                                   timelineHost: TimelineHost())
        host.refreshOfflineAndSize()
        #expect(host.monitor.model.offlineFileName == nil)          // no Project model: nothing known offline
        let model = ProjectPanelModel(project: p, status: { _ in .missing }, onEdit: { _, _ in })
        shell.projectModel = model
        host.refreshOfflineAndSize()
        #expect(host.monitor.model.offlineFileName == "a.mp4")
        #expect(host.monitor.model.pictureSize?.width == s.activeTimeline?.format.displayWidth)
        s.seek(to: Time(3, 1))
        host.refreshOfflineAndSize()
        #expect(host.monitor.model.offlineFileName == nil)          // past the clip: black, no card
    }

    @Test func theProgramStartsAtTheSavedQualityAndAHandPickIsSaved() throws {
        let d = try #require(UserDefaults(suiteName: "sq.test.quality.\(UUID())"))
        AppSettings.load(from: d).choosingFixedQuality(.half).save(to: d)
        let program = MonitorEngineStub()
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: program.stub)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let host = MonitorCardHost(session: s, shell: shell, program: program, backend: MonitorBackendStub(),
                                   effects: EffectControlsModel(), projectList: ProjectListView(host: shell),
                                   timelineHost: TimelineHost(), qualityDefaults: d)
        #expect(host.monitor.model.quality == .half)
        #expect(StatusBarContent.playback(host.monitor.model.quality) == "Playback: 1/2 · GPU")
        host.monitor.model.setQuality(.quarter)                     // a hand pick in the popup
        #expect(AppSettings.load(from: d).defaultQuality == .quarter && !AppSettings.load(from: d).previewQualityAuto)
        host.monitor.model.setQuality(.auto)
        #expect(AppSettings.load(from: d).previewQualityAuto)
        var fixed = AppSettings.load(from: d).choosingFixedQuality(.half)   // Preferences apply the new default
        fixed.autosaveInterval = 60
        shell.onSettingsChanged?(fixed)
        #expect(host.monitor.model.quality == .half)
    }

    @Test func programHeaderNamesTheShownSequence() {
        let (host, _, _, s) = card()
        let name = s.activeTimeline?.name ?? ""
        #expect(!name.isEmpty)
        #expect(host.monitor.model.sequenceName == name)
        #expect(host.monitor.model.sequenceCurrent == s.activeTimelineID)
    }

    @Test func magicClicksGoToThePlatformSegmenterWithTheirModifiers() {
        let program = MonitorEngineStub()
        let s = EditorSession(project: EditorSession.makeUntitled(), fileURL: nil, engine: program.stub)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let effects = EffectControlsModel()
        let host = MonitorCardHost(session: s, shell: shell, program: program, backend: MonitorBackendStub(), effects: effects,
                                   projectList: ProjectListView(host: shell), timelineHost: TimelineHost())
        var lines: [String] = []
        host.monitor.onStatus = { lines.append($0) }
        host.monitor.maskToolNow = { .magic }
        let click = host.monitor.panel.overlay.onMaskToolClick
        click?(Vec2(0.5, 0.5), [])
        #expect(lines.count == 1)                       // no segmenter: the status line says so
        let magic = MagicStub()
        host.monitor.magic = magic
        click?(Vec2(0.25, 0.75), [.option, .shift])
        #expect(magic.clicks.count == 1)
        #expect(magic.clicks.first?.p == Vec2(0.25, 0.75))
        #expect(magic.clicks.first?.subtract == true && magic.clicks.first?.newMask == true)
        #expect(lines.count == 1)
    }
    /// The Color page shows the graded picture without the transform box (the Mac `colorPageActive`).
    @Test func theColorPageHidesTheTransformBox() throws {
        let clip = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        let p = Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v])])
        let program = MonitorEngineStub()
        let s = EditorSession(project: p, fileURL: nil, engine: program.stub)
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let effects = EffectControlsModel()
        let host = MonitorCardHost(session: s, shell: shell, program: program, backend: MonitorBackendStub(), effects: effects,
                                   projectList: ProjectListView(host: shell), timelineHost: TimelineHost(), qualityDefaults: nil)
        s.select(clips: [clip.id])
        effects.setClip(s.activeTimeline?.tracks[0].clips.first)
        func frame() {
            var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
            host.draw(&c, card: DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1, isPlaying: false, theme: DrawTheme())
            host.draw(&c, card: DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1, isPlaying: false, theme: DrawTheme())
        }
        frame()
        #expect(host.monitor.panel.overlay.isShown)
        shell.dock.setPage(.color)
        frame()
        #expect(!host.monitor.panel.overlay.isShown)
    }
}

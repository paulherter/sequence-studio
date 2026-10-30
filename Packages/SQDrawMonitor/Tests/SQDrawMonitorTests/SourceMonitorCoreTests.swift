import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
import SQUIKit
@testable import SQDrawMonitor

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func video(tag: PixelAspect = .square) -> VideoTrackInfo {
    VideoTrackInfo(width: 1440, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 25),
                   isVariableFrameRate: false, pixelAspect: tag)
}

@MainActor private func makeSource() -> (SourceMonitorCore, EditorSession, StubProgramEngine, MediaRef, MediaRef) {
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
    let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
    let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                     duration: s(10), info: MediaInfo(duration: s(10), video: v, audio: a))
    let audioOnly = MediaRef(name: "B", path: "/nonexistent/B.wav", fingerprint: MediaFingerprint(size: 2),
                             duration: s(4), info: MediaInfo(duration: s(4), video: nil, audio: a))
    let session = EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
        .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
    session.perform("Import") { $0.add(m); $0.add(audioOnly) }
    let engine = StubProgramEngine()
    return (SourceMonitorCore(session: session, engine: engine), session, engine, m, audioOnly)
}

@MainActor @Suite struct SourceMonitorCoreTests {
    @Test func openBuildsTheClipTimelineAndFillsTheModel() {
        let (src, _, engine, m, b) = makeSource()
        #expect(src.open(m.id, at: s(3)))
        #expect(src.mediaID == m.id)
        #expect(engine.timeline?.frameDuration == Time(1, 30))
        #expect(src.model.duration == s(10))
        #expect(src.model.currentTime == s(3))
        #expect(src.model.viewerMode == .picture)
        #expect(src.pictureShape == [1920, 1080])
        #expect(src.open(b.id))
        #expect(src.model.viewerMode == .waveform)
        #expect(src.model.sourceItems.map(\.id) == [b.id, m.id])     // most recent first
        src.closeCurrent()
        #expect(src.mediaID == m.id)
        src.closeAll()
        #expect(src.mediaID == nil && src.model.sourceItems.isEmpty)
    }

    @Test func marksGoToTheProjectWithOutExclusive() {
        let (src, session, _, m, _) = makeSource()
        src.open(m.id)
        src.seek(to: s(2)); src.markIn()
        src.seek(to: s(5)); src.markOut()
        let marks = session.project.sourceMarks(for: m.id)
        #expect(marks.markIn == s(2))
        #expect(marks.markOut == s(5) + Time(1, 30))
        #expect(src.model.markIn == s(2))
        src.goToOut()
        #expect(src.currentTime == s(5))
        src.clearMarks()
        #expect(session.project.sourceMarks(for: m.id).isEmpty)
    }

    @Test func insertAndOverwritePlaceTheMarkedRange() {
        let (src, session, _, m, _) = makeSource()
        src.open(m.id)
        session.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(5)), for: m.id)
        src.perform(.overwrite)
        let clips = session.activeTimeline!.tracks.flatMap(\.clips)
        #expect(clips.count == 2)
        #expect(clips.allSatisfy { $0.source == TimeRange(start: s(2), end: s(5)) })
        src.perform(.insert)
        #expect(session.activeTimeline!.tracks.flatMap(\.clips).count == 4)
    }

    @Test func replaceNeedsOneSelectedClip() {
        let (src, session, _, m, _) = makeSource()
        var status: [String] = []
        src.onStatus = { status.append($0) }
        src.perform(.replace)
        #expect(status.last?.contains("Open a clip") == true)
        src.open(m.id)
        src.perform(.replace)
        #expect(status.last?.contains("Select one clip") == true)
        src.perform(.overwrite)
        let clip = session.activeTimeline!.tracks.first { $0.kind == .video }!.clips[0]
        var c = m
        c.id = UUID(); c.name = "C"; c.fingerprint = MediaFingerprint(size: 3)
        session.perform("Import") { $0.add(c) }
        src.open(c.id)
        session.seek(to: .zero)
        session.setSelection(clips: [clip.id], captions: [])   // the video clip alone (a click selects its linked audio too)
        src.perform(.replace)
        #expect(session.undoName?.contains("Replace") == true)
    }

    @Test func fourPointEditAsksAndCancelPlacesNothing() {
        let (src, session, _, m, _) = makeSource()
        src.open(m.id)
        session.setSourceMarks(SourceMarks(markIn: s(1), markOut: s(2)), for: m.id)
        session.setInPoint(at: s(0))
        session.setOutPoint(at: s(4))
        var asked = 0
        src.chooseFourPointFit = { done in asked += 1; done(nil) }
        src.perform(.overwrite)
        #expect(asked == 1)
        #expect(session.activeTimeline!.tracks.allSatisfy { $0.clips.isEmpty })
        src.chooseFourPointFit = { done in done(.changeSpeed) }
        src.perform(.overwrite)
        #expect(!session.activeTimeline!.tracks.allSatisfy { $0.clips.isEmpty })
    }

    @Test func playInToOutStopsAtOutAndLoopWrapsWithoutEngineLoop() {
        let (src, session, engine, m, _) = makeSource()
        src.open(m.id)
        session.setSourceMarks(SourceMarks(markIn: s(2), markOut: s(3)), for: m.id)
        src.playInToOut()
        #expect(src.isPlaying && src.bounds.range == TimeRange(start: s(2), end: s(3)))
        engine.simulatePlayback(advance: s(2))
        #expect(!src.isPlaying)
        #expect(src.currentTime == s(3) - Time(1, 30))
        src.perform(.loop)
        src.playInToOut()
        engine.simulatePlayback(advance: s(2))
        #expect(src.isPlaying && src.currentTime == s(2))           // wrapped back to In by the core
    }

    @Test func sourceCommandsRouteWhileFocused() {
        let (src, _, _, m, _) = makeSource()
        src.open(m.id)
        #expect(src.handle(.stepForward))
        #expect(src.currentTime == Time(1, 30))
        #expect(src.handle(.goToEnd))
        #expect(src.currentTime == s(10) - Time(1, 30))
        #expect(!src.handle(.undo))
    }

    @Test func audioOnlyClipShowsTheWaveformAndAPressScrubs() {
        let (src, _, _, _, b) = makeSource()
        var asked: [UUID] = []
        src.waveformProvider = { asked.append($0); return nil }
        src.open(b.id)
        #expect(asked == [b.id])
        let panel = MonitorPanel(model: src.model)
        panel.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        panel.draw(&c)
        #expect(panel.showsWaveform)
        #expect(!panel.headerControls.contains { $0.0 == .zoom })   // no picture tools for sound
        let r = panel.slot
        #expect(panel.handle(.mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: [])))
        #expect(src.currentTime > s(1) && src.currentTime < s(3))   // the middle of a 4 s file
        _ = panel.handle(.mouseDragged(x: Float(r.maxX), y: Float(r.midY)))
        _ = panel.handle(.mouseUp(x: Float(r.maxX), y: Float(r.midY)))
        #expect(src.currentTime == src.duration - src.frameDuration)
        #expect(!panel.isDragging)
    }

    @Test func menuListsTheEditRows() {
        let (src, _, _, m, _) = makeSource()
        src.open(m.id)
        let titles = src.contextMenuItems().map(\.title)
        for t in ["Mark In", "Insert", "Overwrite", "Fit to Fill", "Replace Clip from Source", "Export Frame…"] {
            #expect(titles.contains(t))
        }
    }
}

@Suite struct SourceTimelineBuilderTests {
    private func ref(_ v: VideoTrackInfo?) -> MediaRef {
        MediaRef(name: "a.mov", path: "/a.mov", fingerprint: MediaFingerprint(size: 1), duration: nil,
                 info: MediaInfo(duration: Time(10, 1), video: v))
    }

    @Test func shapeFollowsThePixelAspect() {
        var r = ref(video())
        #expect(SourceTimelineBuilder.shape(of: r) == [1440, 1080])
        r.info?.video?.pixelAspectOverride = PixelAspect(4, 3)
        #expect(SourceTimelineBuilder.shape(of: r) == [1920, 1080])
        #expect(SourceTimelineBuilder.build(r)?.format.width == 1920)
    }

    @Test func rebuildOnlyWhenTheShapeMoved() {
        var r = ref(video())
        let loaded = SourceTimelineBuilder.shape(of: r)
        #expect(!SourceTimelineBuilder.needsReshape(r, loaded: loaded))
        r.info?.video?.pixelAspectOverride = PixelAspect(2, 1)
        #expect(SourceTimelineBuilder.needsReshape(r, loaded: loaded))
        #expect(!SourceTimelineBuilder.needsReshape(r, loaded: SourceTimelineBuilder.shape(of: r)))
        #expect(!SourceTimelineBuilder.needsReshape(ref(nil), loaded: []))       // audio only: no picture, no shape
    }

    @Test func unprobedMediaBuildsNothingAndHasNoShape() {
        let r = MediaRef(name: "a.mov", path: "/a.mov", fingerprint: MediaFingerprint(size: 1))
        #expect(SourceTimelineBuilder.build(r) == nil)
        #expect(SourceTimelineBuilder.shape(of: r) == [])
        #expect(!SourceTimelineBuilder.needsReshape(r, loaded: []))
    }

    @Test func lateInfoChangesFrameRateAndLength() {
        let unprobed = MediaRef(name: "a.mov", path: "/a.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1))
        let before = SourceTimelineBuilder.build(unprobed)
        #expect(before?.format.frameDuration == Time(1, 30))
        var probed = unprobed
        probed.info = MediaInfo(duration: Time(4, 1), video: video())
        let after = SourceTimelineBuilder.build(probed)
        #expect(after?.format.frameDuration == Time(1, 25))
        #expect(after?.total == Time(4, 1))
        #expect(SourceTimelineBuilder.needsReshape(probed, loaded: SourceTimelineBuilder.shape(of: unprobed)))
    }

    @Test func positionAndRangeAreClampedToTheNewEnd() {
        let fd = Time(1, 25), total = Time(4, 1)
        #expect(SourceTimelineBuilder.clampedPosition(Time(9, 1), total: total, frameDuration: fd) == Time(4, 1) - fd)
        #expect(SourceTimelineBuilder.clampedPosition(Time(2, 1), total: total, frameDuration: fd) == Time(2, 1))
        let cut = SourceTimelineBuilder.clampedRange(TimeRange(start: Time(2, 1), end: Time(9, 1)), total: total)
        #expect(cut == TimeRange(start: Time(2, 1), end: total))
        #expect(SourceTimelineBuilder.clampedRange(TimeRange(start: Time(5, 1), end: Time(9, 1)), total: total) == nil)
        #expect(SourceTimelineBuilder.clampedRange(nil, total: total) == nil)
    }
}

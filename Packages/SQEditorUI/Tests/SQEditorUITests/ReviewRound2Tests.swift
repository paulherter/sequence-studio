import Foundation
import Testing
import SQCore
import SQMedia
import AppKit
@testable import SQEditorSession
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQMonitorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession(duration: Time = s(10), fps: Time = Time(1, 30)) -> (EditorSession, StubProgramEngine, MediaRef) {
    let engine = StubProgramEngine()
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: fps, isVariableFrameRate: false)
    let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")
    let m = MediaRef(name: "A", path: "/nonexistent/A.mov", fingerprint: MediaFingerprint(size: 1),
                     duration: duration, info: MediaInfo(duration: duration, video: v, audio: a))
    let session = EditorSession(engine: engine, autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
        .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
    session.perform("Import") { $0.add(m) }
    return (session, engine, m)
}

@MainActor @Suite struct ReviewRound2Tests {
    // Review finding 2: placeMedia kept raw (off-grid) source durations.
    @Test func placeMediaStaysOnFrameGrid() {
        let (session, _, m) = makeSession(duration: Time(1001, 100))
        #expect(session.placeMedia([m.id, m.id], at: .zero))
        let fd = session.activeTimeline!.frameDuration
        for c in session.activeTimeline!.tracks.flatMap(\.clips) {
            #expect(c.start == c.start.snapped(to: fd))
            #expect(c.source.duration == c.source.duration.snapped(to: fd))
        }
    }

    // Finding 9: opening or creating a project left playback, In/Out range and clipboard of the old one alive.
    @Test func newProjectStopsPlaybackAndDropsOldState() {
        let (session, engine, m) = makeSession()
        session.placeMedia([m.id], at: .zero)
        session.selectAllClips()
        #expect(session.copySelection())
        session.playPause()
        session.bounds.range = TimeRange(start: .zero, duration: s(1))
        #expect(session.isPlaying)
        session.newProject()
        #expect(!session.isPlaying && engine.rate.isPaused)
        #expect(session.bounds.range == nil)
        #expect(session.clipboard == nil)
    }

    // Finding 31: a refused replace (every caption track locked) returned 0 instead of nil.
    @Test func replaceCaptionTextRefusedIsNil() {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        session.replaceCaptions([CaptionItem(lines: ["cat"], range: TimeRange(start: s(0), end: s(1)), styleRef: "default")])
        session.perform("lock") { p in
            let id = p.timelines[0].id
            _ = try? p.edit(id) { for i in $0.captionTracks.indices { $0.captionTracks[i].isLocked = true } }
        }
        #expect(session.replaceCaptionText(find: "cat", with: "fox", caseSensitive: false) == nil)
    }

    // Findings 14, 15: huge hour or frame fields overflowed the timecode maths and trapped.
    @Test func hugeTimecodeIsRejected() {
        let tc = Timecode(frameDuration: Time(1, 30), dropFrame: false)
        #expect(tc.parse("9999999999999:00:00:00") == nil)
        #expect(tc.parse("1:00:00:00") != nil)
        let fd = Time(1, 30)
        #expect(MarkersPanelModel.parseTimecode("9999999999999:00:00:00", frameDuration: fd) == nil)
        #expect(MarkersPanelModel.parseTimecode("9999999999999999", frameDuration: fd) == nil)
        #expect(MarkersPanelModel.parseTimecode("01:00:00:00", frameDuration: fd) != nil)
    }

    // Finding 16: Create Captions "Minimum duration" of 1e30 / inf trapped on the Int64 conversion.
    @Test func captionMinimumDurationIsClamped() {
        #expect(CaptionsPanelModel.minDuration(seconds: 1e30) == Time(3600, 1))
        #expect(CaptionsPanelModel.minDuration(seconds: .infinity) == Time(3600, 1))
        #expect(CaptionsPanelModel.minDuration(seconds: .nan) == .zero)
        #expect(CaptionsPanelModel.minDuration(seconds: -4) == .zero)
        #expect(CaptionsPanelModel.minDuration(seconds: 1.5) == Time(3, 2))
    }

    // Finding 17: NaN pixels trapped in the 8-bit conversion.
    @Test func nanPixelsConvertToZero() {
        #expect(FrameSampler.display8(SIMD3<Float>(.nan, 0, 1)).x == 0)
        #expect(FrameSampler.byte(.nan) == 0)
        #expect(FrameSampler.byte(2) == 255)
    }

    // Finding 18: a probe with a zero frame duration trapped in the duration columns and hover scrub.
    @Test func zeroFrameDurationDoesNotTrap() {
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(0, 1), isVariableFrameRate: false)
        let m = MediaRef(name: "A", path: "/x.mov", fingerprint: MediaFingerprint(size: 1),
                         duration: s(10), info: MediaInfo(duration: s(10), video: v, audio: nil))
        #expect(ProjectPanelModel.durationString(m) == "00:00:10")
        #expect(ProjectPanelModel.timecode(s(10), frameDuration: Time(0, 1)) == "00:00:10")
        #expect(HoverScrub.poster(duration: s(10), frameDuration: Time(0, 1)) <= Time(2, 1))
    }

    // Finding 24: OK with the unchanged speed or duration still applied a no-op SpeedChange.
    @Test func unchangedSpeedDialogHasNoChanges() {
        let fd = Time(1, 24)
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 48), start: .zero,
                        link: nil, mediaDuration: fd * 2000)
        var m = SpeedDialogModel(clips: [clip], frameDuration: fd)
        m.setPercent(100)
        #expect(!m.hasChanges)
        m.setDuration(fd * 48)
        #expect(!m.hasChanges)
        m.setPercent(200)
        #expect(m.hasChanges)
        m.setPercent(100)
        #expect(!m.hasChanges)
    }

    // Finding 25: zoom to fit on a one-frame sequence went past the zoom cap.
    @Test func zoomToFitRespectsTheLimits() {
        let fd = Time(1, 24)
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd), start: .zero)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c], name: "V1")])
        let v = TimelineView(timeline: tl, frame: NSRect(x: 0, y: 0, width: 1600, height: 180))
        v.zoomToFit()
        #expect(v.geometry.pointsPerSecond <= v.zoomLimits.upperBound + 1e-9)
    }

    // Finding 8: unchecking Uniform Scale with Width == Height changed no tracked property, so the Scale row stayed single.
    @Test func uncheckingUniformScaleRebuildsTheScaleRow() async throws {
        let m = EffectControlsModel()
        m.setClip(Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1)))
        m.playhead = Time(5, 1)
        let v = EffectControlsView(model: m)
        v.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        v.layoutSubtreeIfNeeded()
        func count(_ n: NSView) -> Int { n.subviews.reduce(0) { $0 + ($1 is ScrubField ? 1 : 0) + count($1) } }
        let before = count(v)
        m.setUniformScale(false)
        try await Task.sleep(for: .milliseconds(100))
        v.layoutSubtreeIfNeeded()
        #expect(count(v) == before + 1)
    }

    // Finding 20: marker timecodes were non-drop while the monitor shows drop-frame at 29.97 / 59.94.
    @Test func markerTimecodeIsDropFrameAtNTSC() {
        let fd = Time(1001, 30000)
        #expect(MarkersPanelModel.timecode(fd * 107_892, frameDuration: fd) == "01:00:00;00")
        #expect(MarkersPanelModel.parseTimecode("01:00:00;00", frameDuration: fd) == fd * 107_892)
        #expect(MarkersPanelModel.timecode(fd * 30, frameDuration: fd) == Timecode(frameDuration: fd, dropFrame: true).format(fd * 30))
        let fd25 = Time(1, 25)
        #expect(MarkersPanelModel.timecode(fd25 * 90_000, frameDuration: fd25) == "01:00:00:00")
        #expect(MarkersPanelModel.parseTimecode("120", frameDuration: fd25) == fd25 * 120)      // a plain number is a frame count
    }

    // Finding 19: leaving a marker field unchanged still produced an edit (and moved off-grid markers onto the frame grid).
    @Test func unchangedMarkerFieldsCommitNothing() {
        let model = MarkersPanelModel()
        let m = Marker(time: Time(1001, 1000) + Time(1, 100), name: "Intro")          // between two frames
        model.update(markers: [m], frameDuration: Time(1, 30))
        var edits: [MarkersPanelModel.Edit] = []
        model.onEdit = { edits.append($0) }
        let row = model.rows[0]
        #expect(model.commit(row: 0, column: .name, text: "Intro"))
        #expect(model.commit(row: 0, column: .inPoint, text: row.inTimecode))
        #expect(model.commit(row: 0, column: .duration, text: row.durationTimecode))
        #expect(model.commit(row: 0, column: .comment, text: row.comment))
        #expect(edits.isEmpty)
        #expect(model.commit(row: 0, column: .name, text: "Outro"))
        #expect(edits == [.rename(m.id, "Outro")])
    }

    // Finding 33: every decoded still stayed in memory for the life of the project.
    @Test func stillCacheStaysWithinItsByteBudget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let info = MediaInfo(duration: Time(5, 1), video: VideoTrackInfo(width: 64, height: 64, codec: "image", bitDepth: 8, chroma: "4:4:4",
                             nominalFrameDuration: Time(1, 30), isVariableFrameRate: false), isStill: true)
        var refs: [MediaRef] = []
        for i in 0..<3 {
            let url = dir.appendingPathComponent("s\(i).png")
            try png.write(to: url)
            refs.append(MediaRef(name: "s\(i)", path: url.path, fingerprint: MediaFingerprint(size: 1), duration: info.duration, info: info))
        }
        let r = ProjectMediaResolver(stillCacheBytes: 1)
        r.update(refs)
        for ref in refs { _ = try r.stillFrame(for: ref.id) }
        #expect(r.cachedStillCount == 1)
    }

    // Finding 36 (and 12): enlarging the thumbnails asks for a sharper poster instead of stretching the small one.
    @Test func largerThumbnailSizeRequestsASharperPoster() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("posters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = dir.appendingPathComponent("p.png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        let info = MediaInfo(duration: Time(5, 1), video: VideoTrackInfo(width: 800, height: 800, codec: "image", bitDepth: 8, chroma: "4:4:4",
                             nominalFrameDuration: Time(1, 30), isVariableFrameRate: false), isStill: true)
        let ref = MediaRef(name: "p", path: url.path, fingerprint: MediaFingerprint(size: 1), duration: info.duration, info: info)
        let thumbs = ProjectThumbnails()
        thumbs.requestPoster(ref, height: 50) {}
        for _ in 0..<SQTiming.polls(200) where thumbs.cachedPoster(ref.id) == nil { try await Task.sleep(for: .milliseconds(10)) }
        let small = try #require(thumbs.cachedPoster(ref.id)).size.height
        thumbs.requestPoster(ref, height: 300) {}
        for _ in 0..<SQTiming.polls(200) where (thumbs.cachedPoster(ref.id)?.size.height ?? 0) <= small { try await Task.sleep(for: .milliseconds(10)) }
        #expect((thumbs.cachedPoster(ref.id)?.size.height ?? 0) > small)
    }

    // Finding 42: the transcript model kept the old file path after a relink (same clip id).
    @Test func transcriptFollowsARelinkedFile() throws {
        let (session, _, m) = makeSession()
        session.placeMedia([m.id], at: .zero)
        let clip = try #require(session.activeTimeline?.tracks.flatMap(\.clips).first)
        session.select(clips: [clip.id])
        let view = TextPanelView(session: session)
        let audio = try #require(session.activeTimeline?.tracks.first { $0.kind == .audio }?.clips.first)
        #expect(view.captionsModel?.sequenceSource?.urls[audio.media]?.path == "/nonexistent/A.mov")
        session.relinkMedia([m.id: "/elsewhere/B.mov"])
        view.sync([.project])
        #expect(view.captionsModel?.sequenceSource?.urls[audio.media]?.path == "/elsewhere/B.mov")
    }

    // Finding 27: audio inspector views of deleted tracks stayed in the view (and their presets came back with reused ids).
    @Test func clipSectionsPrunesDeletedAudioTracks() throws {
        let (session, _, m) = makeSession()
        session.placeMedia([m.id], at: .zero)
        let audio = try #require(session.activeTimeline?.tracks.first { $0.kind == .audio }?.clips.first)
        let view = ClipSectionsView(session: session)
        let base = view.subviews.count
        session.select(clips: [audio.id])
        view.sync([.selection])
        #expect(view.subviews.count == base + 1)
        session.perform("Remove tracks") { p in
            _ = try? p.edit(p.timelines[0].id) { $0.tracks.removeAll { $0.kind == .audio } }
        }
        view.sync([.project])
        #expect(view.subviews.count == base)
    }
}

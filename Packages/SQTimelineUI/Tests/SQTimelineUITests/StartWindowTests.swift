#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 30)

@MainActor @Suite struct StartWindowTests {
    private func media(video: Bool = true, audio: Bool = true) -> MediaRef {
        let v = video ? VideoTrackInfo(width: 1080, height: 1920, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false) : nil
        let a = audio ? AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "aac") : nil
        return MediaRef(name: "M", path: "/nonexistent/M.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(4, 1),
                        info: MediaInfo(duration: Time(4, 1), video: v, audio: a))
    }

    private func session(_ m: MediaRef) -> EditorSession {
        var p = ProjectTemplate.vertical.makeProject(name: "P")
        p.add(m)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-sw-\(UUID().uuidString)")
        return EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: dir))
    }

    @Test func newVerticalProjectIsOneStepAndOpensReady() {
        // Start window: ONE click on the 9:16 card (template -> project -> session).
        let s = EditorSession(project: ProjectTemplate.vertical.makeProject(name: "Reel"),
                              engine: StubProgramEngine(),
                              autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory.appendingPathComponent("sq-sw-\(UUID().uuidString)")))
        let t = s.activeTimeline
        #expect(t?.format.width == 1080 && t?.format.height == 1920)
        #expect(t?.tracks.count == 8)
        #expect(s.canUndo == false)
    }

    @Test func ghostVideoDropCreatesTrackInOneUndoStep() throws {
        let m = media()
        let s = session(m)
        let before = s.project
        #expect(s.placeMedia([m.id], at: .zero, newTrack: .video))
        let tl = try #require(s.activeTimeline)
        #expect(tl.tracks.filter { $0.kind == .video }.count == 5)   // 4 default video tracks + the new one
        let top = try #require(tl.tracks.last { $0.kind == .video })
        #expect(top.clips.count == 1)
        #expect(tl.tracks.filter { $0.kind == .audio }.count == 5)      // linked audio mirrored onto a new A5
        #expect(s.undo())
        #expect(s.project == before)
        #expect(s.canUndo == false)
    }

    @Test func ghostAudioDropCreatesAudioTrackOnly() throws {
        let m = media()
        let s = session(m)
        #expect(s.placeMedia([m.id], at: .zero, newTrack: .audio))
        let tl = try #require(s.activeTimeline)
        #expect(tl.tracks.filter { $0.kind == .video }.count == 4)
        #expect(tl.tracks.filter { $0.kind == .video }.allSatisfy { $0.clips.isEmpty })
        let a = try #require(tl.tracks.last { $0.kind == .audio })
        #expect(tl.tracks.filter { $0.kind == .audio }.count == 5 && a.clips.count == 1)
    }

    // MARK: Ghost geometry and preview

    private func timeline() -> Timeline {
        Timeline(name: "t", frameDuration: fd, tracks: Timeline.defaultTracks())
    }

    @Test func ghostRowsSitUnderTheLastRow() {
        let t = timeline()
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 10)
        let last = g.rows(for: t).last!
        let gr = g.ghostRows(for: t)
        #expect(gr.map(\.kind) == [.video, .audio])
        #expect(gr[0].y == last.maxY && gr[1].y == gr[0].maxY)
        let x = TimelineGeometry.contentOriginX + 20
        #expect(g.ghostKind(at: CGPoint(x: x, y: gr[0].y + 2), in: t) == .video)
        #expect(g.ghostKind(at: CGPoint(x: x, y: gr[1].y + 2), in: t) == .audio)
        #expect(g.ghostKind(at: CGPoint(x: x, y: last.y + 2), in: t) == nil)
        #expect(g.ghostKind(at: CGPoint(x: -5, y: gr[0].y + 2), in: t) == nil)       // left of the view
    }

    @Test func reservedGhostSpaceShrinksStretchedRows() {
        let t = timeline()
        var g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 10)
        g.viewportHeight = 600
        let plain = g.rows(for: t).last!.maxY
        g.reservesGhostSpace = true
        let reserved = g.rows(for: t).last!.maxY
        #expect(abs((plain - reserved) - 2 * TimelineGeometry.ghostRowHeight) < 0.5)
        #expect(g.ghostRows(for: t).last!.maxY <= 600 + 0.5)
    }

    @Test func previewOverGhostRowCommitsNewTrackKind() {
        let t = timeline()
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 10)
        let gr = g.ghostRows(for: t)
        var p = DropPreview()
        p.begin(items: [DropItem(name: "m", duration: fd * 24, hasVideo: true, hasAudio: true)])
        p.update(point: CGPoint(x: TimelineGeometry.contentOriginX + 30, y: gr[0].y + 3), insert: false, timeline: t, geometry: g,
                 snapping: false, playhead: .zero)
        #expect(p.commitGhostKind == .video)
        #expect(p.ghosts.count == 1 && p.ghosts[0].onGhostRow)
        p.update(point: CGPoint(x: TimelineGeometry.contentOriginX + 30, y: gr[1].y + 3), insert: false, timeline: t, geometry: g,
                 snapping: false, playhead: .zero)
        #expect(p.commitGhostKind == .audio)
        // A video-only item cannot be dropped on the audio ghost.
        p.begin(items: [DropItem(name: "v", duration: fd * 24, hasVideo: true, hasAudio: false)])
        p.update(point: CGPoint(x: TimelineGeometry.contentOriginX + 30, y: gr[1].y + 3), insert: false, timeline: t, geometry: g,
                 snapping: false, playhead: .zero)
        #expect(p.commitGhostKind == nil)
    }

    @Test func noGhostForPayloadsThatCannotCreateTracks() {
        let t = timeline()
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 10)
        let gr = g.ghostRows(for: t)
        var p = DropPreview()
        p.begin(items: [DropItem(name: "f", duration: fd * 24, hasVideo: true, hasAudio: true)], canCreateTracks: false)
        p.update(point: CGPoint(x: TimelineGeometry.contentOriginX + 30, y: gr[0].y + 3), insert: false, timeline: t, geometry: g,
                 snapping: false, playhead: .zero)
        #expect(p.ghostKind == nil && p.commitGhostKind == nil && !p.ghosts.contains { $0.onGhostRow })
    }

    @Test func ghostPreviewHonoursTheDragStreams() {
        let t = timeline()
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 10)
        let gr = g.ghostRows(for: t)
        var p = DropPreview()
        p.begin(items: [DropItem(name: "m", duration: fd * 24, hasVideo: true, hasAudio: true)], streams: .audioOnly)
        p.update(point: CGPoint(x: TimelineGeometry.contentOriginX + 30, y: gr[0].y + 3), insert: false, timeline: t, geometry: g,
                 snapping: false, playhead: .zero)
        #expect(p.commitGhostKind == nil)                      // no empty V track from an audio-only drag
        p.update(point: CGPoint(x: TimelineGeometry.contentOriginX + 30, y: gr[1].y + 3), insert: false, timeline: t, geometry: g,
                 snapping: false, playhead: .zero)
        #expect(p.commitGhostKind == .audio)
    }

    @Test func sessionRefusesGhostDropsThatWouldLeaveAnEmptyTrack() {
        let m = media()
        let s = session(m)
        let silent = media(audio: false)
        s.perform("add") { $0.add(silent) }
        let before = s.project
        #expect(!s.placeMedia([m.id], at: .zero, streams: .audioOnly, newTrack: .video))
        #expect(!s.placeMedia([m.id], at: .zero, streams: .videoOnly, newTrack: .audio))
        #expect(!s.placeMedia([silent.id], at: .zero, newTrack: .audio))
        #expect(s.project == before)
    }

    @Test func idleLayoutIsUnchangedByGhostSupport() {
        let t = timeline()
        var g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 10)
        g.viewportHeight = 600
        let idleRows = g.rows(for: t), idleHeight = g.contentHeight(for: t)
        #expect(!g.reservesGhostSpace)
        #expect(idleHeight == idleRows.reduce(TimelineGeometry.rulerHeight) { $0 + $1.height })
        g.reservesGhostSpace = true
        #expect(g.rows(for: t) != idleRows)                     // rows give way to the ghost rows only while reserved
        g.reservesGhostSpace = false
        #expect(g.rows(for: t) == idleRows && g.contentHeight(for: t) == idleHeight)
        #expect(!TimelineView(timeline: t).geometry.reservesGhostSpace)
    }

    // MARK: Recents

    @Test func recentsAreNewestFirstUniqueAndCapped() {
        var r = RecentProjects()
        for i in 0..<20 { r.note(URL(fileURLWithPath: "/p/\(i).sqproj"), now: Date(timeIntervalSince1970: Double(i))) }
        #expect(r.entries.count == RecentProjects.limit)
        #expect(r.entries.first?.name == "19")
        r.note(URL(fileURLWithPath: "/p/10.sqproj"))
        #expect(r.entries.first?.name == "10")
        #expect(r.entries.filter { $0.name == "10" }.count == 1)
    }

    @Test func recentsReportMissingPathsAndRelocate() {
        var r = RecentProjects()
        r.note(URL(fileURLWithPath: "/p/a.sqproj"), now: Date(timeIntervalSince1970: 1))
        r.note(URL(fileURLWithPath: "/p/b.sqproj"), now: Date(timeIntervalSince1970: 2))
        #expect(Set(r.missing { $0.hasSuffix("a.sqproj") }) == ["/p/b.sqproj"])
        // Locate...: the entry keeps its place and date, takes the new path and name.
        r.relocate(path: "/p/b.sqproj", to: URL(fileURLWithPath: "/q/b2.sqproj"))
        #expect(r.entries.map(\.path) == ["/q/b2.sqproj", "/p/a.sqproj"])
        #expect(r.entries[0].name == "b2" && r.entries[0].opened == Date(timeIntervalSince1970: 2))
        // Relocating onto a path that is already listed does not duplicate it.
        r.relocate(path: "/q/b2.sqproj", to: URL(fileURLWithPath: "/p/a.sqproj"))
        #expect(r.entries.map(\.path) == ["/p/a.sqproj"])
    }

    @Test func recentsPruneMissingFilesAndRoundTrip() throws {
        var r = RecentProjects()
        r.note(URL(fileURLWithPath: "/p/a.sqproj")); r.note(URL(fileURLWithPath: "/p/b.sqproj"))
        let kept = r.pruned { $0.hasSuffix("a.sqproj") }
        #expect(kept.entries.map(\.name) == ["a"])
        let back = try JSONDecoder().decode(RecentProjects.self, from: JSONEncoder().encode(r))
        #expect(back == r)
    }

    @Test func continueTargetIsNewestPresentEntry() {
        var r = RecentProjects()
        r.note(URL(fileURLWithPath: "/a/a.sqproj"), now: Date(timeIntervalSince1970: 1))
        r.note(URL(fileURLWithPath: "/b/b.sqproj"), now: Date(timeIntervalSince1970: 2))
        #expect(r.mostRecent(missing: [])?.name == "b")
        #expect(r.mostRecent(missing: ["/b/b.sqproj"])?.name == "a")
        #expect(r.mostRecent(missing: ["/b/b.sqproj", "/a/a.sqproj"]) == nil)
        #expect(RecentProjects().mostRecent(missing: []) == nil)
    }

    @Test func launchReopenSkipsStartWindowOnlyWhenOnAndFilePresent() {
        var r = RecentProjects()
        r.note(URL(fileURLWithPath: "/a/a.sqproj"), now: Date(timeIntervalSince1970: 1))
        r.note(URL(fileURLWithPath: "/b/b.sqproj"), now: Date(timeIntervalSince1970: 2))
        #expect(r.launchReopenTarget(enabled: false, exists: { _ in true }) == nil)
        #expect(r.launchReopenTarget(enabled: true, exists: { _ in true })?.name == "b")
        #expect(r.launchReopenTarget(enabled: true, exists: { $0 != "/b/b.sqproj" })?.name == "a")
        #expect(r.launchReopenTarget(enabled: true, exists: { _ in false }) == nil)
    }

    @Test func decodedListIsDeduplicatedAndCapped() throws {
        var entries = (0..<20).map { RecentProjects.Entry(path: "/p/\($0).sqproj", name: "\($0)", opened: Date(timeIntervalSince1970: Double($0))) }
        entries.insert(entries[2], at: 1)
        struct Raw: Codable { var entries: [RecentProjects.Entry] }
        let data = try JSONEncoder().encode(Raw(entries: entries))
        let r = try JSONDecoder().decode(RecentProjects.self, from: data)
        #expect(r.entries.count == RecentProjects.limit)
        #expect(Set(r.entries.map(\.path)).count == r.entries.count)
    }
}

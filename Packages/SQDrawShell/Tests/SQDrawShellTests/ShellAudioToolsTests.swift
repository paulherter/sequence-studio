import Foundation
import Testing
import SQCore
import SQUIKit
import SQMedia
import SQLibrary
import SQEditorSession
@testable import SQDrawShell

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Mono, 1000 frames/s, one bucket per second: `loud[i]` true = full level, false = near silence.
private func wave(_ loud: [Bool]) -> WaveformData {
    let peaks: [Float] = loud.flatMap { (l: Bool) -> [Float] in l ? [-0.5, 0.5] : [-0.001, 0.001] }
    return WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: loud.count * 1000, baseBucketSize: 1000, levels: [peaks])
}

@MainActor
@Suite(.serialized) struct ShellAudioToolsTests {
    /// Video v linked to audio a, music m, dialogue d; ten seconds each.
    func host(fileURL: URL? = nil) -> (ShellHost, v: Clip, a: Clip, m: Clip, d: Clip, status: Box) {
        let link = UUID()
        let v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        var m = Clip(name: "m", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        var d = Clip(name: "d", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        m.audioTag = .music; d.audioTag = .dialogue
        var vt = Track(kind: .video), t1 = Track(kind: .audio), t2 = Track(kind: .audio), t3 = Track(kind: .audio)
        try! vt.overwrite(v); try! t1.overwrite(a); try! t2.overwrite(m); try! t3.overwrite(d)
        let tl = Timeline(name: "T", frameDuration: Time(1, 25), tracks: [vt, t1, t2, t3])
        let h = ShellHost(session: EditorSession(project: Project(name: "P", timelines: [tl]), fileURL: fileURL), map: .premiereDefault)
        h.spawn = { f in Task { @MainActor in await f() } }
        let box = Box()
        h.onStatus = { box.lines.append($0) }
        return (h, v, a, m, d, box)
    }
    final class Box { var lines: [String] = [] }

    func clip(_ h: ShellHost, _ id: Clip.ID) -> Clip { h.session.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }

    func answer(_ h: ShellHost, _ flow: @escaping @MainActor () async -> Void, with r: ShellDialog.Response) async {
        let t = Task { @MainActor in await flow() }
        for _ in 0..<400 where h.dialog == nil { await Task.yield() }
        h.dialog?.press(r)
        await t.value
    }

    @Test func clipPeakFallsBackToTheWaveform() {
        let (h, _, a, _, _, _) = host()
        #expect(h.peak(of: a) == nil)
        h.waveform = { _ in wave([true, false]) }
        #expect(h.peak(of: a) == 0.5)
        h.clipPeak = { _ in 0.25 }
        #expect(h.peak(of: a) == 0.25)
    }

    @Test func autoDuckBakesKeysThatOpenInTheDialoguePause() async {
        let (h, _, _, m, d, box) = host()
        // Dialogue speaks for 3 s, pauses 4 s, speaks again: the music comes back up in the pause.
        h.waveform = { $0 == d.media ? wave([true, true, true, false, false, false, false, true, true, true]) : nil }
        await h.autoDuck()
        let keys = clip(h, m.id).animation.volume.track.keys
        #expect(!clip(h, m.id).duckKeyIDs.isEmpty)
        #expect(keys.contains { $0.time > s(3) && $0.time < s(7) })
        #expect(box.lines.last == "Duck baked into volume keys.")
    }

    @Test func autoDuckWithoutMusicSaysWhatToTag() async {
        let (h, _, _, m, _, box) = host()
        h.session.select(clips: [m.id], captions: [])
        _ = h.session.toggleAudioTag(.music)
        await h.autoDuck()
        #expect(box.lines.last == "Tag a clip as Music first (Clip > Audio Options).")
    }

    @Test func removeSilencesCutsThePauseOnLinkedTracksInOneStep() async {
        let (h, _, a, _, _, _) = host()
        let defaults = UserDefaults(suiteName: "sq.test.silences.\(UUID())")!
        SilenceSettings(thresholdDB: -35, minimumMs: 500, paddingMs: 0).remember(defaults)
        h.waveform = { $0 == a.media ? wave([true, true, true, false, false, false, true, true, true, true]) : nil }
        h.session.select(clips: [a.id], captions: [])
        let depth = h.session.undoDepth
        await answer(h, { await h.removeSilences(defaults: defaults) }, with: .first)
        #expect(h.session.undoDepth == depth + 1)
        let tl = h.session.activeTimeline!
        #expect(tl.tracks[0].end == s(7) && tl.tracks[1].end == s(7))      // picture cut with the sound
        #expect(SilenceSettings.remembered(defaults) == SilenceSettings(thresholdDB: -35, minimumMs: 500, paddingMs: 0))
    }

    @Test func removeSilencesShowsThePreviewWhileTheDialogIsUpAndClearsIt() async {
        let (h, _, a, _, _, _) = host()
        let defaults = UserDefaults(suiteName: "sq.test.silences.\(UUID())")!
        SilenceSettings(thresholdDB: -35, minimumMs: 500, paddingMs: 0).remember(defaults)
        h.waveform = { $0 == a.media ? wave([true, true, true, false, false, false, true, true, true, true]) : nil }
        h.session.select(clips: [a.id], captions: [])
        var shown: [[TimeRange]] = []
        h.silencePreview = { shown.append($0) }
        await answer(h, { await h.removeSilences(defaults: defaults) }, with: .second)
        #expect(shown.first == [TimeRange(start: s(3), duration: s(3))])
        #expect(shown.last == [])                                          // canceled: the red bands go
        #expect(h.session.activeTimeline!.tracks[1].end == s(10))
    }

    @Test func removeSilencesWaitsForTheWaveform() async {
        let (h, _, a, _, _, box) = host()
        h.session.select(clips: [a.id], captions: [])
        await h.removeSilences()
        #expect(h.dialog == nil)
        #expect(box.lines.last == "The audio is not analyzed yet. Try again in a moment.")
    }

    @Test func silenceFormSnapsLikeTheMacFields() {
        let f = ShellForm(ShellSilenceForm.rows(SilenceSettings(thresholdDB: -80, minimumMs: 333, paddingMs: 74)))
        #expect(f.number("level") == -60)                                 // clamped to the slider range
        #expect(ShellSilenceForm.settings(f) == SilenceSettings(thresholdDB: -60, minimumMs: 350, paddingMs: 70))
    }

    @Test func syncFitPrefersTimecodeThenSoundThenCaptureDate() throws {
        let tc = ShellSyncFacts.fit(reference: ShellSyncFacts(startTimecode: s(10)), other: ShellSyncFacts(startTimecode: s(12)))
        #expect(tc?.method == .timecode)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let date = ShellSyncFacts.fit(reference: ShellSyncFacts(captureDate: day), other: ShellSyncFacts(captureDate: day.addingTimeInterval(5)))
        #expect(date?.method == .captureDate)
        #expect(ShellSyncFacts.fit(reference: ShellSyncFacts(), other: ShellSyncFacts()) == nil)
        // The same sound 2 s later: the envelope fit wins over the dates.
        var env = [Float](repeating: 0, count: 3000)
        for i in env.indices where (i / 37) % 3 == 0 || (i * 7919) % 101 < 9 { env[i] = 1 }
        let later = [Float](repeating: 0, count: 200) + env
        let sound = ShellSyncFacts.fit(reference: ShellSyncFacts(envelope: env, captureDate: day),
                                       other: ShellSyncFacts(envelope: later, captureDate: day))
        #expect(sound?.method == .sound)
    }

    @Test func syncReadsABroadcastWaveTimecodeWhenTheHostHasNoReader() async throws {
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + le32(UInt32(body.count)) + body }
        var bext = [UInt8](repeating: 0, count: 602)
        let ref: UInt32 = 48_000 * 3600 * 10                                  // 10:00:00:00
        bext.replaceSubrange(338..<342, with: le32(ref))
        let fmt = le32(0x0001_0001) + le32(48_000) + le32(96_000) + [2, 0, 16, 0]
        let payload = Array("WAVE".utf8) + chunk("fmt ", fmt) + chunk("bext", bext) + chunk("data", [0, 0, 0, 0])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-bwf-\(UUID().uuidString).wav")
        try Data(Array("RIFF".utf8) + le32(UInt32(payload.count)) + payload).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (h, _, _, _, _, _) = host()
        #expect(h.startTimecode == nil)
        let facts = await h.syncFacts(MediaRef(name: "a.wav", path: url.path, fingerprint: MediaFingerprint(size: 0)), waveform: nil)
        #expect(facts.startTimecode == Time(Int64(ref), 48_000))
        h.startTimecode = { _ in Time(5, 1) }                                 // the host's reader goes first
        #expect(await h.syncFacts(MediaRef(name: "a.wav", path: url.path, fingerprint: MediaFingerprint(size: 0)), waveform: nil).startTimecode == Time(5, 1))
    }

    @Test func syncWithoutTwoClipsExplains() async {
        let (h, _, a, _, _, _) = host()
        h.session.select(clips: [a.id], captions: [])
        await answer(h, { await h.syncAudio() }, with: .first)
        #expect(h.dialog == nil)
    }

    // MARK: Create Angles Clip sync (the Mac `AnglesOrigins`)

    private func angleHost() -> (ShellHost, [AngleCandidate]) {
        let refs = ["A", "B"].map { MediaRef(name: $0, path: "/nowhere/\($0).mov", fingerprint: MediaFingerprint(size: 0)) }
        let h = ShellHost(session: EditorSession(project: Project(name: "P", media: refs, timelines: [Timeline(name: "T", frameDuration: Time(1, 25))])),
                          map: .premiereDefault)
        return (h, refs.map { AngleCandidate(name: $0.name, media: $0.id, hasAudio: true) })
    }

    @Test func anglesByTimelineOrInPointsNeedNoFiles() async {
        let (h, angles) = angleHost()
        let tl = await h.anglesOrigins(sync: .timelinePositions, angles: angles)
        #expect(tl.origins == nil && tl.note == nil)
        let inPoints = await h.anglesOrigins(sync: .inPoints, angles: angles)
        #expect(inPoints.origins == [:] && inPoints.note == nil)
    }

    @Test func anglesByTimecodeUseTheStartTimecodes() async {
        let (h, angles) = angleHost()
        h.startTimecode = { Time($0.name == "A" ? 100 : 130, 1) }
        let found = await h.anglesOrigins(sync: .timecode, angles: angles)
        #expect(found.origins?[angles[0].media!] == Time(100, 1) && found.origins?[angles[1].media!] == Time(130, 1))
        #expect(found.note == nil)
        h.startTimecode = { $0.name == "A" ? Time(100, 1) : nil }
        let one = await h.anglesOrigins(sync: .timecode, angles: angles)
        #expect(one.origins == [:] && one.note == "No timecode found: lined up by In point.")
    }

    @Test func anglesByAudioPlaceTheSecondWhereItsSoundMatches() async {
        let (h, angles) = angleHost()
        var state: UInt64 = 7
        let scene: [Bool] = (0..<60).map { _ in state = state &* 6364136223846793005 &+ 1442695040888963407; return (state >> 33) % 2 == 0 }
        // B starts 7 s into A's scene.
        h.waveform = { $0 == angles[0].media ? wave(scene) : wave(Array(scene[7...])) }
        let found = await h.anglesOrigins(sync: .audio, angles: angles)
        #expect(found.origins?[angles[0].media!] == .zero)
        #expect(found.origins?[angles[1].media!] == Time(7, 1))
        h.waveform = { _ in nil }
        let none = await h.anglesOrigins(sync: .audio, angles: angles)
        #expect(none.origins == [:] && none.note == "The sound could not be read: lined up by In point.")
    }

    // MARK: View toggles

    @Test func viewTogglesRunAndShowTheirCheckMarks() {
        let (h, _, _, _, _, box) = host()
        let defaults = UserDefaults(suiteName: "sq.test.view.\(UUID())")!
        let before = h.session.selectionFollowsPlayhead
        #expect(h.performViewCommand(.toggleSelectionFollowsPlayhead, defaults: defaults))
        #expect(h.session.selectionFollowsPlayhead == !before)
        #expect(AppSettings.load(from: defaults).selectionFollowsPlayhead == !before)
        #expect(h.menuState().checkedCommands.contains(.toggleSelectionFollowsPlayhead) == !before)
        // The test engine has no audio scrubbing: refused, no check mark.
        #expect(h.performViewCommand(.toggleAudioScrubbing, defaults: defaults))
        #expect(box.lines.last == ShellPlatformText.notAvailable && !h.menuState().checkedCommands.contains(.toggleAudioScrubbing))
        #expect(h.performViewCommand(.uiScaleLarger, defaults: defaults))
        #expect(InterfaceScale.load(from: defaults) == 1.1)
        #expect(h.performViewCommand(.uiScaleReset, defaults: defaults))
        #expect(InterfaceScale.load(from: defaults) == 1.0)
        #expect(!h.performViewCommand(.projectIconView, defaults: defaults))   // no Project list: the host's
    }

    @Test func projectViewCommandsDriveTheList() {
        let (h, _, _, _, _, _) = host()
        let defaults = UserDefaults(suiteName: "sq.test.list.\(UUID())")!
        let list = ProjectListView(host: h, defaults: defaults)
        #expect(h.performViewCommand(.projectIconView))
        #expect(list.viewMode == .icons && h.menuState().checkedCommands.contains(.projectIconView))
        let size = list.thumbSize
        #expect(h.performViewCommand(.projectThumbnailLarger))
        #expect(list.thumbSize == size + 16)
        #expect(h.performViewCommand(.projectListView))
        #expect(list.viewMode == .list)
        h.menuChecks.append { [.toggleSafeAreas] }
        #expect(h.menuState().checkedCommands.contains(.toggleSafeAreas))
    }

    // MARK: Card import

    @Test func cardSummaryAndChoicesFollowWhatTheCardHolds() {
        let now = Date()
        let items = [CardCandidate(url: URL(fileURLWithPath: "/c/A.mp4"), kind: .video, size: 1_000_000, modified: now),
                     CardCandidate(url: URL(fileURLWithPath: "/c/B.mp4"), kind: .video, size: 1_000_000, modified: now),
                     CardCandidate(url: URL(fileURLWithPath: "/c/C.jpg"), kind: .photo, size: 1000, modified: now)]
        #expect(ShellCardImport.summary(items).hasPrefix("2 videos ("))
        #expect(ShellCardImport.summary(items).contains(", 1 photo ("))
    }

    @Test func cardAtLaunchWaitsForAProject() async throws {
        let (h, _, _, _, _, _) = host(fileURL: nil)
        h.presentStartAtLaunch()
        #expect(h.isStartShown)
        h.openCardImport(volume: URL(fileURLWithPath: "/Volumes/NOPE"), atLaunch: true)
        #expect(h.cardImportVolumes.isEmpty)                              // start window up: nothing offered
        h.openCardImport(volume: URL(fileURLWithPath: "/Volumes/NOPE"))   // a card mounted later is still offered
        #expect(h.cardImportVolumes.count == 1)
    }

    @Test func cardImportCopiesIntoTheProjectMediaFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sq-card-\(UUID().uuidString)")
        let card = root.appendingPathComponent("CARD/DCIM", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: card.appendingPathComponent("C0001.MP4"))
        try Data([1, 2]).write(to: card.appendingPathComponent("IMG_1.JPG"))
        let projectFile = root.appendingPathComponent("Work/P.sqproj")
        try FileManager.default.createDirectory(at: projectFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (h, _, _, _, _, _) = host(fileURL: projectFile)
        let model = ProjectPanelModel(project: h.session.project, probe: ShellImportTests.fakeProbe,
                                      onEdit: { [weak s = h.session] p, name in s?.perform(name) { $0 = p } })
        h.projectModel = model
        let t = Task { @MainActor in await h.cardImport(volume: root.appendingPathComponent("CARD")) }
        for _ in 0..<400 where h.dialog == nil { await Task.yield() }
        let board = try #require(ShellCardImport.current)
        h.dialog?.press(.first)                                           // nothing ticked: stays open
        #expect(h.dialog != nil)
        #expect(h.dialog?.model.buttons.map(\.title) == ["Copy & Import", "Import without Copying", "Select All"])   // no Cancel
        #expect(h.dialog?.escapeResponse == ShellCardImport.cancel)
        #expect(h.dialog?.closeButton == true)
        board.selectAll()                                                 // the videos
        board.setKind(.photo)
        board.click(board.visibleIDs[0], toggle: true)
        #expect(board.selected.count == 1)
        board.setKind(.video)
        #expect(board.selected.isEmpty)                                   // ticks belong to the shown kind (the Mac prune)
        board.setKind(.photo)
        board.selectAll()
        h.dialog?.press(.first)
        await t.value
        let media = projectFile.deletingLastPathComponent().appendingPathComponent("Media")
        let copied = try FileManager.default.contentsOfDirectory(atPath: media.path).sorted()
        #expect(copied == ["IMG_1.JPG"])
        #expect(Set(h.session.project.media.map(\.name)) == ["IMG_1.JPG"])
        #expect(h.session.project.media.allSatisfy { $0.path.hasPrefix(media.path) })
        try? FileManager.default.removeItem(at: root)
    }
}

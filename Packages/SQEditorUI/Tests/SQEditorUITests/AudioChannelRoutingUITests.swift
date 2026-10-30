import Foundation
import Synchronization
import Testing
import SQCore
import SQMedia
@testable import SQEditorSession
@testable import SQEditorUI
@testable import SQInspectorUI

// F7.10: the channels chosen for a media item reach the engines (their audio is opened again), the resolver (the
// source it hands out plays the chosen channels), the waveforms (rebuilt for the map) and the Project item's menu.

private func ref(_ name: String, channels: Int = 4, path: String? = nil) -> MediaRef {
    MediaRef(name: name, path: path ?? "/nowhere/\(name)", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1),
             info: MediaInfo(duration: Time(2, 1), video: nil,
                             audio: AudioTrackInfo(sampleRate: 48_000, channels: channels, codec: "lpcm")))
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-channels-ui-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func sides(_ s: any AudioSource, count: Int = 32) throws -> (l: [Float], r: [Float]) {
    var l = [Float](repeating: -9, count: count), r = l
    #expect(try s.read(from: 0, count: count, into: &l, channel: 0) == count)
    #expect(try s.read(from: 0, count: count, into: &r, channel: 1) == count)
    return (l, r)
}

@MainActor @Suite struct AudioChannelRoutingUITests {
    @Test func changingTheChannelsReopensTheMediaInTheEngine() {
        var p = EditorSession.makeUntitled()
        let a = ref("A.wav"), b = ref("B.wav")
        p.add(a); p.add(b)
        let engine = StubProgramEngine()
        let session = EditorSession(project: p, engine: engine, autosaveStore: AutosaveStore(base: tempDir()))
        #expect(engine.changedMedia.isEmpty)

        session.perform("Set Audio Channels") { $0.setAudioChannelMap(.mono(2), for: a.id) }
        #expect(engine.changedMedia == [[a.id]])
        #expect(session.media.info(of: a.id)?.audio?.channelMap == .mono(2))
        _ = session.undo()
        #expect(engine.changedMedia == [[a.id], [a.id]])
        #expect(session.media.info(of: a.id)?.audio?.channelMap == nil)
        session.perform("Rename") { $0.media[0].name = "C.wav" }
        #expect(engine.changedMedia.count == 2)
    }

    /// Review F7.10: a relink to a file with fewer channels clears the map the file cannot play (the label and the
    /// file version say what is heard); Undo of the relink has the old file and its map again.
    @Test func relinkClearsAMapTheNewFileCannotPlay() async throws {
        var p = EditorSession.makeUntitled()
        var a = ref("A.wav", channels: 4)
        a.info?.audio?.channelMap = .mono(3)
        p.add(a)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        let probed = MediaInfo(duration: Time(2, 1), video: nil, audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm"))
        session.mediaInfoProbe = { (_: URL) in probed }
        session.relinkMedia([a.id: "/found/A.wav"])
        for _ in 0..<SQTiming.polls(100) where session.project.audioChannelMap(of: a.id) != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.project.audioChannelMap(of: a.id) == nil)
        #expect(session.project.media(a.id)?.info?.audio?.channels == 2)
        #expect(!session.project.containsV70Content)
        _ = session.undo()
        #expect(session.project.media(a.id)?.path == "/nowhere/A.wav")
        #expect(session.project.audioChannelMap(of: a.id) == .mono(3))
    }

    @Test func panelModelSetsTheChannelsAsOneEdit() {
        var p = Project(name: "P")
        let a = ref("A.wav"), b = ref("B.wav")
        p.add(a); p.add(b)
        var names: [String] = []
        let m = ProjectPanelModel(project: p, probe: { _ in throw CocoaError(.fileReadUnknown) }, onEdit: { _, n in names.append(n) })
        #expect(m.setAudioChannels(.stereo(2, 3), for: [.media(a.id), .media(b.id)]))
        #expect(m.project.audioChannelMap(of: a.id) == .stereo(2, 3) && m.project.audioChannelMap(of: b.id) == .stereo(2, 3))
        #expect(names == ["Set Audio Channels"])
        #expect(!m.setAudioChannels(.stereo(2, 3), for: [.media(a.id)]))
        #expect(m.setAudioChannels(nil, for: [.media(a.id)]))
        #expect(m.project.audioChannelMap(of: a.id) == nil && names.count == 2)
    }

    @Test func resolverHandsOutTheChosenChannels() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.wav")
        try Data([0]).write(to: url)
        let opens = Mutex(0)
        let resolver = ProjectMediaResolver(audio: { _, _ in
            opens.withLock { $0 += 1 }
            return MemoryAudioSource(left: [Float](repeating: 0.25, count: 100), right: [Float](repeating: -0.5, count: 100))
        })
        var m = ref("a.wav", channels: 2, path: url.path)
        resolver.update([m], sampleRate: 48_000)
        var s = try sides(try resolver.audio(for: m.id))
        #expect(s.l[0] == 0.25 && s.r[0] == -0.5)
        _ = try resolver.audio(for: m.id)
        #expect(opens.withLock { $0 } == 1)

        m.info?.audio?.channelMap = .mono(1)
        resolver.update([m])
        let right = try resolver.audio(for: m.id)
        s = try sides(right)
        #expect(right.isMono && s.l.allSatisfy { $0 == -0.5 } && s.r.allSatisfy { $0 == -0.5 })
        #expect(opens.withLock { $0 } == 2)

        // An update that leaves the channels alone keeps the opened source.
        resolver.update([m])
        _ = try resolver.audio(for: m.id)
        #expect(opens.withLock { $0 } == 2)

        m.info?.audio?.channelMap = nil
        resolver.update([m])
        s = try sides(try resolver.audio(for: m.id))
        #expect(s.l[0] == 0.25 && s.r[0] == -0.5)
    }

    @Test func waveformIsRebuiltForOtherChannels() async throws {
        var m = ref("m.wav")
        var p = Project(name: "p")
        p.add(m)
        let clip = Clip(name: "m", media: m.id, kind: .audio, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .audio, clips: [clip])])
        let builds = Mutex(0)
        let w = TimelineWaveforms { _ in
            let n = builds.withLock { $0 += 1; return $0 }
            return WaveformData(sampleRate: 48_000, channelCount: 1, totalFrames: 100 * n, baseBucketSize: 256, levels: [[-0.5, 0.5]])
        }
        w.ensure(timeline: tl, project: p)
        for _ in 0..<SQTiming.polls(100) where w.data[m.id] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(w.data[m.id]?.totalFrames == 100)
        w.ensure(timeline: tl, project: p)                  // same channels: nothing rebuilt
        #expect(w.data[m.id]?.totalFrames == 100 && w.pendingCount == 0)

        m.info?.audio?.channelMap = .mono(3)
        p.add(m)
        w.ensure(timeline: tl, project: p)
        #expect(w.data[m.id] == nil && w.pendingCount == 1)  // the old channels are not drawn any more
        for _ in 0..<SQTiming.polls(100) where w.data[m.id] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(w.data[m.id]?.totalFrames == 200 && builds.withLock { $0 } == 2)
    }

    @Test func menuOffersLayoutMonoStereoAndDualMono() {
        var picked: [AudioChannelMap?] = []
        let rows = AudioChannelsMenu.items(channels: 4, current: .mono(0)) { picked.append($0) }
        #expect(rows.map(\.title) == ["File Layout", "", "Mono", "Stereo", "Dual Mono"])
        #expect(!rows[0].isChecked && rows[2].isChecked && !rows[3].isChecked)
        let mono = try! #require(rows[2].submenu), stereo = try! #require(rows[3].submenu), dual = try! #require(rows[4].submenu)
        #expect(mono.map(\.title) == ["Channel 1", "Channel 2", "Channel 3", "Channel 4"])
        #expect(mono.map(\.isChecked) == [true, false, false, false])
        #expect(stereo.map(\.title) == ["1 + 2", "1 + 3", "1 + 4", "2 + 3", "2 + 4", "3 + 4"])
        mono[2].action?(); stereo[5].action?(); dual[0].action?(); rows[0].action?()
        #expect(picked == [.mono(2), .stereo(2, 3), .dualMono(0, 1), nil])

        #expect(AudioChannelsMenu.items(channels: 1, current: nil) { _ in }.isEmpty)
        let many = AudioChannelsMenu.items(channels: 8, current: nil) { _ in }
        #expect(many[0].isChecked && many[3].submenu?.map(\.title) == ["1 + 2", "3 + 4", "5 + 6", "7 + 8"])
    }

    /// Review: a relink without a chosen map re-reads the sound info when the file is another one.
    @Test func relinkRefreshesTheSoundInfoOfAChangedFile() async throws {
        var p = EditorSession.makeUntitled()
        var a = ref("A.wav", channels: 2)
        a.fingerprint = MediaFingerprint(size: 1)
        p.add(a)
        let file = tempDir().appendingPathComponent("A.wav")
        try Data(count: 64).write(to: file)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        let probed = MediaInfo(duration: Time(2, 1), video: nil,
                               audio: AudioTrackInfo(sampleRate: 48_000, channels: 3, codec: "lpcm", firstTrackChannels: 1))
        session.mediaInfoProbe = { (_: URL) in probed }
        session.relinkMedia([a.id: file.path])
        for _ in 0..<SQTiming.polls(100) where session.project.media(a.id)?.info?.audio?.channels != 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.project.media(a.id)?.info?.audio?.channels == 3)
        #expect(session.project.media(a.id)?.info?.audio?.firstTrackChannels == 1)
    }

    /// Old projects: media with info but no stored sound is probed again on open, so its channels can be shown.
    @Test func openingProbesMediaWithoutStoredSoundInfo() async throws {
        var p = EditorSession.makeUntitled()
        let file = tempDir().appendingPathComponent("Old.mov")
        try Data(count: 64).write(to: file)
        var old = ref("Old.mov", channels: 2, path: file.path)
        old.info?.audio = nil
        p.add(old)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        let probed = MediaInfo(duration: Time(2, 1), video: nil,
                               audio: AudioTrackInfo(sampleRate: 48_000, channels: 4, codec: "lpcm"))
        session.mediaInfoProbe = { (_: URL) in probed }
        session.refreshMissingSoundInfo()
        for _ in 0..<SQTiming.polls(100) where session.project.media(old.id)?.info?.audio == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.project.media(old.id)?.info?.audio?.channels == 4)
    }

    /// The background reprobe of an old project writes the marker silently: no changed flag, no undo step.
    @Test func soundProbeOfAnOldProjectLeavesItUnchanged() async throws {
        var p = EditorSession.makeUntitled()
        let file = tempDir().appendingPathComponent("Old.mov")
        try Data(count: 64).write(to: file)
        var old = ref("Old.mov", channels: 2, path: file.path)
        old.info?.audio = nil
        p.add(old)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        let depth = session.history.undoDepth
        #expect(!session.isDirty)
        session.mediaInfoProbe = { (_: URL) in MediaInfo(duration: Time(2, 1), audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")) }
        session.refreshMissingSoundInfo()
        for _ in 0..<SQTiming.polls(100) where session.project.media(old.id)?.info?.soundProbed != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.project.media(old.id)?.info?.soundProbed == true)
        #expect(session.project.media(old.id)?.info?.audio?.channels == 2)
        #expect(!session.isDirty)
        #expect(session.history.undoDepth == depth)
    }

    /// A silent file is probed once; sound without a track count is probed again; counted sound is left alone.
    @Test func silentMediaIsNotProbedAgainAndUncountedSoundIs() async throws {
        var p = EditorSession.makeUntitled()
        let dir = tempDir()
        var silent = ref("Silent.mov", channels: 2, path: dir.appendingPathComponent("S.mov").path)
        silent.info?.audio = nil
        var uncounted = ref("Uncounted.mov", channels: 2, path: dir.appendingPathComponent("U.mov").path)
        uncounted.info?.audio?.firstTrackChannels = nil
        for m in [silent, uncounted] { try Data(count: 64).write(to: URL(fileURLWithPath: m.path)) }
        p.add(silent); p.add(uncounted)
        let session = EditorSession(project: p, engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: tempDir()))
        final class Calls: @unchecked Sendable { let l = NSLock(); var paths: [String] = []
            func add(_ s: String) { l.lock(); paths.append(s); l.unlock() }
            var n: Int { l.lock(); defer { l.unlock() }; return paths.count } }
        let calls = Calls()
        session.mediaInfoProbe = { (u: URL) in
            calls.add(u.lastPathComponent)
            return u.lastPathComponent == "S.mov" ? MediaInfo(duration: Time(2, 1))
                : MediaInfo(duration: Time(2, 1), audio: AudioTrackInfo(sampleRate: 48_000, channels: 3, codec: "lpcm", firstTrackChannels: 2))
        }
        session.refreshMissingSoundInfo()
        for _ in 0..<SQTiming.polls(100) where session.project.media(uncounted.id)?.info?.soundProbed != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(calls.n == 2)
        #expect(session.project.media(silent.id)?.info?.soundProbed == true)
        #expect(session.project.media(uncounted.id)?.info?.audio?.channels == 3)
        session.refreshMissingSoundInfo()
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls.n == 2)
    }

    @Test func twoMonoTracksShowStereoChecked() {
        let audio = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm", firstTrackChannels: 1)
        let stored = AudioChannelMap.stereo(0, 1)!.stored(audio: audio, path: "/a.mov")
        #expect(stored == .stereo(0, 1))
        let rows = AudioChannelsMenu.items(channels: 2, current: stored) { _ in }
        #expect(!rows[0].isChecked && rows[3].isChecked)
    }

    @Test func projectItemMenuHasTheRowOnlyForMultiChannelSound() {
        var c = ProjectPanelMenus.Context(media: [UUID()], targetCount: 1, allMediaOnline: true, hasNonBinTarget: true)
        #expect(!ProjectPanelMenus.items(c, shortcut: { _ in "" }) { _ in }.contains { $0.title == "Audio Channels" })
        c.audioChannels = 4
        var got: [ProjectPanelMenus.Action] = []
        let rows = ProjectPanelMenus.items(c, shortcut: { _ in "" }) { got.append($0) }
        let row = rows.first { $0.title == "Audio Channels" }
        row?.submenu?[2].submenu?[0].action?()
        #expect(got == [.setAudioChannels(.mono(0))])
        #expect(rows.last?.title == "Delete")
    }
}

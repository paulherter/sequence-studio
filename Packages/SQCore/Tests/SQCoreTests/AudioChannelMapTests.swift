import Foundation
import Testing
@testable import SQCore

// F7.10: audio channel routing per media item. The map says which file channels feed the clip's left and right side;
// nil is the file's own layout (what every project before v70 plays).

private func projectWith(channels: Int, map: AudioChannelMap? = nil) -> (Project, MediaRef.ID) {
    let ref = MediaRef(name: "a.mxf", path: "/a.mxf", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                       info: MediaInfo(duration: Time(10, 1),
                                       audio: AudioTrackInfo(sampleRate: 48_000, channels: channels, codec: "PCM", channelMap: map)))
    let clip = Clip(name: "a", media: ref.id, kind: .audio, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero,
                    mediaDuration: Time(10, 1))
    let tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)),
                      tracks: [Track(kind: .audio, clips: [clip])])
    return (Project(name: "P", media: [ref], timelines: [tl]), ref.id)
}

@Suite struct AudioChannelMapTests {
    @Test func mapsAreNormalizedAndValidated() {
        #expect(AudioChannelMap(left: [], right: []) == nil)
        #expect(AudioChannelMap(left: [-1], right: [0]) == nil)
        #expect(AudioChannelMap(left: Array(0..<17), right: [0]) == nil)
        let m = AudioChannelMap(left: [3, 1, 3], right: [2])
        #expect(m?.left == [1, 3] && m?.right == [2])
        #expect(AudioChannelMap.stereo(1, 1) == nil && AudioChannelMap.dualMono(2, 2) == nil)
    }

    @Test func presetsLayoutsAndLevels() throws {
        let mono = try #require(AudioChannelMap.mono(2))
        #expect(mono.layout == .mono && mono.isCentered && mono.gain == 1 && mono.label == "Mono: 3")
        let stereo = try #require(AudioChannelMap.stereo(0, 1))
        #expect(stereo.layout == .stereo && !stereo.isCentered && stereo.gain == 1 && stereo.label == "Stereo: 1 + 2")
        let dual = try #require(AudioChannelMap.dualMono(2, 3))
        #expect(dual.layout == .dualMono && dual.isCentered && dual.label == "Dual Mono: 3 + 4")
        #expect(abs(dual.gain - 0.70710678) < 1e-6)                        // -3 dB each
        let wide = try #require(AudioChannelMap(left: [0, 2], right: [1, 3]))
        #expect(wide.layout == .custom && wide.gain == 1 && wide.highestChannel == 3)
        // One side only is a valid map (a channel on the left, nothing on the right).
        #expect(AudioChannelMap(left: [0], right: [])?.layout == .custom)
    }

    @Test func fittingDropsChannelsTheFileLacks() {
        #expect(AudioChannelMap.dualMono(0, 3)?.fitting(channels: 2) == .mono(0))
        #expect(AudioChannelMap.stereo(2, 3)?.fitting(channels: 2) == nil)
        #expect(AudioChannelMap.stereo(0, 1)?.fitting(channels: 4) == .stereo(0, 1))
        // A side that was in use never ends up empty: the whole map is gone instead.
        #expect(AudioChannelMap.stereo(1, 2)?.fitting(channels: 2) == nil)
        #expect(AudioChannelMap.stereo(3, 0)?.fitting(channels: 2) == nil)
        #expect(AudioChannelMap(left: [1, 2], right: [3])?.fitting(channels: 3) == nil)
        // A side that was empty by choice stays empty.
        #expect(AudioChannelMap(left: [0, 3], right: [])?.fitting(channels: 2) == AudioChannelMap(left: [0], right: []))
    }

    private func plainProject(channels: Int, path: String = "/a.mov", codec: String = "aac ") -> (Project, MediaRef.ID) {
        let ref = MediaRef(name: "a", path: path, fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                           info: MediaInfo(duration: Time(10, 1),
                                           audio: AudioTrackInfo(sampleRate: 48_000, channels: channels, codec: codec)))
        return (Project(name: "P", media: [ref]), ref.id)
    }

    @Test func aChoiceThatNamesTheFileLayoutIsNoChoice() throws {
        // An ordinary stereo file: Stereo 1 + 2 is what it plays anyway. Nothing stored, no newer file version.
        var (p, id) = plainProject(channels: 2)
        let same = p.setAudioChannelMap(.stereo(0, 1), for: id)
        #expect(!same)
        #expect(p.audioChannelMap(of: id) == nil)
        #expect(!p.containsV70Content)
        #expect(ProjectFile.writtenVersion(for: p) < 70)
        // Choosing it while another map is set goes back to File Layout.
        p.setAudioChannelMap(.stereo(1, 0), for: id)
        #expect(p.audioChannelMap(of: id) == .stereo(1, 0))
        let back = p.setAudioChannelMap(.stereo(0, 1), for: id)
        #expect(back)
        #expect(p.audioChannelMap(of: id) == nil)
        // A real change on the same file is stored.
        p.setAudioChannelMap(.dualMono(0, 1), for: id)
        #expect(p.audioChannelMap(of: id) == .dualMono(0, 1))

        var (m, mid) = plainProject(channels: 1)
        let mono = m.setAudioChannelMap(.mono(0), for: mid)
        #expect(!mono)
        #expect(m.audioChannelMap(of: mid) == nil)
    }

    @Test func twoMonoTracksKeepStereoAsARealMap() throws {
        // Two mono audio tracks: 2 channels in all, but the file plays its first track (mono). Stereo 1 + 2 differs.
        var ref = MediaRef(name: "a", path: "/a.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                           info: MediaInfo(duration: Time(10, 1), audio: AudioTrackInfo(
                               sampleRate: 48_000, channels: 2, codec: "lpcm", firstTrackChannels: 1)))
        var p = Project(name: "P", media: [ref])
        #expect(AudioChannelMap.fileLayout(audio: ref.info!.audio!, path: ref.path) == AudioChannelMap.mono(0))
        let changed = p.setAudioChannelMap(.stereo(0, 1), for: ref.id)
        #expect(changed)
        #expect(p.audioChannelMap(of: ref.id) == .stereo(0, 1))
        ref = p.media[0]
        #expect(ref.info?.audio?.firstTrackChannels == 1)

        // One stereo track: the equal map is still dropped.
        var (s, sid) = plainProject(channels: 2)
        let dropped = s.setAudioChannelMap(.stereo(0, 1), for: sid)
        #expect(!dropped)
        #expect(s.audioChannelMap(of: sid) == nil)
    }

    @Test func firstTrackChannelsIsAdditiveInJSON() throws {
        let old = Data(#"{"sampleRate":48000,"channels":2,"codec":"aac "}"#.utf8)
        let a = try JSONDecoder().decode(AudioTrackInfo.self, from: old)
        #expect(a.firstTrackChannels == nil && a.channels == 2)
        let plain = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        #expect(!plain.contains("firstTrackChannels"))
        let multi = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm", firstTrackChannels: 1)
        let back = try JSONDecoder().decode(AudioTrackInfo.self, from: try JSONEncoder().encode(multi))
        #expect(back.firstTrackChannels == 1)
    }

    @Test func theFileLayoutIsDecidedFromTheItemNotTheChannelCount() throws {
        // An MXF with two mono tracks plays them in the center: Stereo 1 + 2 is a real change there.
        var (p, id) = projectWith(channels: 2)
        let split = p.setAudioChannelMap(.stereo(0, 1), for: id)
        #expect(split)
        #expect(p.audioChannelMap(of: id) == .stereo(0, 1))
        #expect(p.containsV70Content)
        // Its own layout is Dual Mono 1 + 2, also with more tracks.
        p.setAudioChannelMap(.dualMono(0, 1), for: id)
        #expect(p.audioChannelMap(of: id) == nil)
        var (q, qid) = projectWith(channels: 4)
        q.setAudioChannelMap(.dualMono(0, 1), for: qid)
        #expect(q.audioChannelMap(of: qid) == nil)
        q.setAudioChannelMap(.stereo(0, 1), for: qid)
        #expect(q.audioChannelMap(of: qid) == .stereo(0, 1))
        // Six channels are the reader's own mix: no map names it.
        var (s, sid) = plainProject(channels: 6)
        s.setAudioChannelMap(.stereo(0, 1), for: sid)
        #expect(s.audioChannelMap(of: sid) == .stereo(0, 1))
        // Layout not known (PCM outside an MXF or WebM, an .mxf probed by another reader): the map is kept.
        var (u, uid) = plainProject(channels: 2, path: "/a.dat", codec: "PCM")
        u.setAudioChannelMap(.stereo(0, 1), for: uid)
        #expect(u.audioChannelMap(of: uid) == .stereo(0, 1))
        var (x, xid) = plainProject(channels: 2, path: "/a.MXF", codec: "lpcm")
        x.setAudioChannelMap(.stereo(0, 1), for: xid)
        #expect(x.audioChannelMap(of: xid) == .stereo(0, 1))
        x.setAudioChannelMap(.dualMono(0, 1), for: xid)
        #expect(x.audioChannelMap(of: xid) == .dualMono(0, 1))
        var (w, wid) = plainProject(channels: 2, path: "/a.webm", codec: "PCM")
        w.setAudioChannelMap(.stereo(0, 1), for: wid)
        #expect(w.audioChannelMap(of: wid) == nil)
    }

    @Test func replaceMediaClearsAMapThatWouldLeaveASideDead() {
        var (p, id) = projectWith(channels: 4, map: .stereo(1, 2))
        let stereo = MediaRef(name: "b.mov", path: "/b.mov", fingerprint: MediaFingerprint(size: 2), duration: Time(10, 1),
                              info: MediaInfo(duration: Time(10, 1), audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "aac ")))
        p.replaceMedia(id, with: stereo)
        #expect(p.audioChannelMap(of: id) == nil)
        #expect(!p.containsV70Content)
        // A map that names the new file's layout is cleared as well.
        var (q, qid) = projectWith(channels: 4, map: .stereo(0, 1))
        q.replaceMedia(qid, with: stereo)
        #expect(q.audioChannelMap(of: qid) == nil)
    }

    @Test func relinkFitsTheMapToTheProbedFile() {
        func info(_ channels: Int?) -> MediaInfo {
            MediaInfo(duration: Time(10, 1), audio: channels.map { AudioTrackInfo(sampleRate: 44_100, channels: $0, codec: "PCM") })
        }
        var (p, id) = projectWith(channels: 4, map: .mono(3))
        p.relink([id: "/other/a.mxf"], probed: [id: info(2)])
        #expect(p.audioChannelMap(of: id) == nil)
        #expect(p.media(id)?.info?.audio?.channels == 2)          // the menu offers the new file's channels
        #expect(!p.containsV70Content)

        var (q, qid) = projectWith(channels: 4, map: .mono(3))
        q.relink([qid: "/other/a.mxf"], probed: [qid: info(8)])
        #expect(q.audioChannelMap(of: qid) == .mono(3))
        #expect(q.media(qid)?.info?.audio?.channels == 8)

        var (n, nid) = projectWith(channels: 4, map: .mono(3))
        n.relink([nid: "/other/a.mxf"])                            // not probed yet: nothing is known, the map stays
        #expect(n.audioChannelMap(of: nid) == .mono(3))
        let fitted = n.fitAudioChannelMaps(to: [nid: info(nil)])   // the new file has no sound
        #expect(fitted)
        #expect(n.audioChannelMap(of: nid) == nil)
        let again = n.fitAudioChannelMaps(to: [nid: info(2)])      // no map: the sound info follows the new file
        #expect(again)
        #expect(n.media(nid)?.info?.audio?.channels == 2)
        let same = n.fitAudioChannelMaps(to: [nid: info(2)])
        #expect(!same)
    }

    @Test func settingTheMapChangesTheItemAndNothingElse() throws {
        var (p, id) = projectWith(channels: 4)
        let before = p.timelines
        #expect(p.audioChannelMap(of: id) == nil)
        let set = p.setAudioChannelMap(.mono(0), for: id)
        #expect(set)
        #expect(p.audioChannelMap(of: id) == .mono(0))
        #expect(p.timelines == before)
        let again = p.setAudioChannelMap(.mono(0), for: id)                 // same again: no change, no undo step
        #expect(!again)
        let cleared = p.setAudioChannelMap(nil, for: id)
        #expect(cleared)
        #expect(p.audioChannelMap(of: id) == nil)
        let clearedAgain = p.setAudioChannelMap(nil, for: id)
        #expect(!clearedAgain)
    }

    @Test func channelsTheFileLacksAreDroppedOrRefused() {
        var (p, id) = projectWith(channels: 2)
        let none = p.setAudioChannelMap(.stereo(2, 3), for: id)             // none of them exists
        #expect(!none)
        #expect(p.audioChannelMap(of: id) == nil)
        let part = p.setAudioChannelMap(.dualMono(1, 5), for: id)
        #expect(part)
        #expect(p.audioChannelMap(of: id) == .mono(1))
        let unknown = p.setAudioChannelMap(.mono(0), for: UUID())
        #expect(!unknown)
    }

    @Test func aWebMOffersTwoChannelsAtMost() {
        let six = AudioTrackInfo(sampleRate: 48_000, channels: 6, codec: "PCM")
        #expect(six.mappableChannels(path: "/a.webm") == 2)
        #expect(six.mappableChannels(path: "/a.MKV") == 2)
        #expect(six.mappableChannels(path: "/a.mov") == 6)
        #expect(AudioChannelMap.fileLayout(audio: six, path: "/a.webm") == .stereo(0, 1))
        #expect(AudioChannelMap.fileLayout(audio: six, path: "/a.mov") == nil)
        // A map above the reader's two channels is fitted down or refused, never stored as is.
        #expect(AudioChannelMap.mono(4)!.stored(audio: six, path: "/a.webm") == nil)
        #expect(AudioChannelMap.dualMono(1, 4)!.stored(audio: six, path: "/a.webm") == .mono(1))
        #expect(AudioChannelMap.mono(4)!.stored(audio: six, path: "/a.mov") == .mono(4))
        var (p, id) = projectWith(channels: 6)
        p.media[0].path = "/a.webm"
        let refused = p.setAudioChannelMap(.mono(4), for: id)
        let fitted = p.setAudioChannelMap(.mono(1), for: id)
        #expect(!refused)
        #expect(fitted)
        #expect(p.audioChannelMap(of: id) == .mono(1))
    }

    @Test func mediaWithoutAudioIsRefused() {
        var p = Project(name: "P")
        let ref = MediaRef(name: "v.mov", path: "/v.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(1, 1),
                           info: MediaInfo(duration: Time(1, 1)))
        p.media.append(ref)
        let set = p.setAudioChannelMap(.mono(0), for: ref.id)
        #expect(!set)
    }

    @Test func replaceMediaKeepsTheMapAsFarAsTheNewFileHasTheChannels() {
        var (p, id) = projectWith(channels: 4, map: .dualMono(1, 3))
        func replacement(_ channels: Int?) -> MediaRef {
            MediaRef(name: "b.mxf", path: "/b.mxf", fingerprint: MediaFingerprint(size: 2), duration: Time(10, 1),
                     info: MediaInfo(duration: Time(10, 1),
                                     audio: channels.map { AudioTrackInfo(sampleRate: 48_000, channels: $0, codec: "PCM") }))
        }
        p.replaceMedia(id, with: replacement(8))
        #expect(p.audioChannelMap(of: id) == .dualMono(1, 3))
        p.replaceMedia(id, with: replacement(2))
        #expect(p.audioChannelMap(of: id) == .mono(1))
        p.replaceMedia(id, with: replacement(1))
        #expect(p.audioChannelMap(of: id) == nil)
        p.replaceMedia(id, with: replacement(nil))
        #expect(p.media(id)?.info?.audio == nil)
    }
}

@Suite struct ProjectFileV70Tests {
    private func json(_ d: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: d) as! [String: Any] }

    // An older build would play a disguised voice undisguised: both pitch kinds need v70, other audio effects do not.
    private func project(effect kind: String, enabled: Bool) -> Project {
        var clip = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero,
                        mediaDuration: Time(10, 1))
        clip.effects = [ClipEffect(kind: kind, enabled: enabled)]
        let tl = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)),
                          tracks: [Track(kind: .audio, clips: [clip])])
        return Project(name: "P", timelines: [tl])
    }

    @Test func pitchShiftAndDisguiseVoiceWriteV70() throws {
        for kind in ["audio.pitchShift", "audio.disguiseVoice"] {
            let p = project(effect: kind, enabled: false)
            #expect(p.containsV70Content, "\(kind)")
            #expect(ProjectFile.writtenVersion(for: p) == 70)
            let data = try ProjectFile.encode(p)
            #expect(try json(data)["formatVersion"] as? Int == 70)
            #expect(try ProjectFile.decode(data, migrations: nil) == p)
        }
        let q = project(effect: "audio.gain", enabled: true)
        #expect(!q.containsV70Content && ProjectFile.writtenVersion(for: q) < 70)
    }

    @Test func versionConstant() {
        #expect(ProjectFile.v70Version == 70)
        #expect(ProjectFile.currentVersion >= 70)
    }

    @Test func fileLayoutWritesNoKeyAndNoNewVersion() throws {
        let (p, id) = projectWith(channels: 4)
        #expect(!p.containsV70Content)
        #expect(ProjectFile.writtenVersion(for: p) < 70)
        let data = try ProjectFile.encode(p)
        #expect(!String(decoding: data, as: UTF8.self).contains("channelMap"))
        // Setting and clearing leaves nothing behind.
        var q = p
        q.setAudioChannelMap(.mono(1), for: id)
        q.setAudioChannelMap(nil, for: id)
        #expect(try ProjectFile.encode(q) == data)
    }

    @Test func aChosenMapWritesV70AndRoundTrips() throws {
        var (p, id) = projectWith(channels: 4)
        p.setAudioChannelMap(.dualMono(2, 3), for: id)
        #expect(p.containsV70Content)
        #expect(ProjectFile.writtenVersion(for: p) == 70)
        let data = try ProjectFile.encode(p)
        #expect(try json(data)["formatVersion"] as? Int == 70)
        let back = try ProjectFile.decode(data, migrations: nil)
        #expect(back == p)
        #expect(back.audioChannelMap(of: id) == .dualMono(2, 3))
        #expect(try ProjectFile.encode(back) == data)
        #expect(try ProjectFile.decode(data, migrations: ProjectFile.migrations) == p)
    }

    private func stripped(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return d.filter { $0.key != "channelMap" }.mapValues(stripped) }
        if let a = v as? [Any] { return a.map(stripped) }
        return v
    }

    /// A file from before v70 has no channel map key: every item plays its file's layout.
    @Test func olderFileOpensWithTheFileLayout() throws {
        let (mapped, id) = projectWith(channels: 4, map: .mono(0))
        var obj = try #require(stripped(try json(try ProjectFile.encode(mapped))) as? [String: Any])
        obj["formatVersion"] = 69
        obj["appFormat"] = 69
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        var plain = mapped
        plain.media[0].info?.audio?.channelMap = nil
        #expect(back == plain)
        #expect(back.audioChannelMap(of: id) == nil)
        #expect(ProjectFile.writtenVersion(for: back) < 70)
    }

    @Test func malformedOrForeignMapOpensWithTheFileLayout() throws {
        let a = AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "PCM", channelMap: .stereo(0, 1))
        var obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(a)) as! [String: Any]
        for bad: Any in [["left": [], "right": []] as [String: Any], ["left": [-2], "right": [0]], "stereo", ["left": [4], "right": [5]]] {
            obj["channelMap"] = bad
            let back = try JSONDecoder().decode(AudioTrackInfo.self, from: try JSONSerialization.data(withJSONObject: obj))
            #expect(back.channelMap == nil && back.channels == 2)
        }
    }

    @Test func olderReaderRefusesANewerFile() throws {
        var (p, id) = projectWith(channels: 4)
        p.setAudioChannelMap(.mono(0), for: id)
        var obj = try json(try ProjectFile.encode(p))
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations)
        }
    }
}

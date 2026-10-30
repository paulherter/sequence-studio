import Foundation
import Testing
@testable import SQCore

// F7.3: pixel aspect ratio per media item (anamorphic desqueeze). The picture's display size is the stored width times
// the pixel aspect; fit, sequence-from-clip and the engines all read it from `VideoTrackInfo`.

private func video(_ w: Int, _ h: Int, rotation: Int = 0, tag: PixelAspect = .square, override: PixelAspect? = nil) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 25),
                   isVariableFrameRate: false, rotation: rotation, pixelAspect: tag, pixelAspectOverride: override)
}

private func projectWith(_ v: VideoTrackInfo, sequence: SequenceFormat = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)))
    -> (Project, MediaRef.ID, Clip.ID) {
    let ref = MediaRef(name: "a.mov", path: "/a.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                       info: MediaInfo(duration: Time(10, 1), video: v))
    let clip = Clip(name: "a", media: ref.id, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero,
                    mediaDuration: Time(10, 1))
    let tl = Timeline(name: "S", format: sequence, tracks: [Track(kind: .video, clips: [clip])])
    return (Project(name: "P", media: [ref], timelines: [tl]), ref.id, clip.id)
}

@Suite struct PixelAspectTests {
    @Test func ratioIsReducedAndValidated() {
        #expect(PixelAspect(8, 6) == PixelAspect(4, 3))
        #expect(PixelAspect(1000, 1000) == .square)
        #expect(PixelAspect(0, 1) == nil)
        #expect(PixelAspect(1, 0) == nil)
        #expect(PixelAspect(-4, 3) == nil)
        #expect(PixelAspect(9, 1) == nil)        // beyond 4:1 is a broken tag, not a lens
        #expect(PixelAspect(1, 9) == nil)
        #expect(PixelAspect(4, 1) != nil)
        #expect(PixelAspect.square.isSquare)
        #expect(PixelAspect(2, 1)?.isSquare == false)
    }

    @Test func presetsAreExact() {
        #expect(PixelAspect.presets.map(\.value) == [1, 1.25, 4.0 / 3.0, 1.5, 1.6, 1.8, 2])
        #expect(PixelAspect.presets.first == .square)
        #expect(PixelAspect.presets.allSatisfy { $0.num > 0 && $0.den > 0 })
    }

    @Test func displayWidthIsEvenForNonSquarePixels() {
        #expect(PixelAspect.square.displayWidth(ofStored: 1920) == 1920)
        #expect(PixelAspect(2, 1)!.displayWidth(ofStored: 1920) == 3840)
        #expect(PixelAspect(4, 3)!.displayWidth(ofStored: 1440) == 1920)
        #expect(PixelAspect(4, 3)!.displayWidth(ofStored: 1920) == 2560)
        #expect(PixelAspect(10, 11)!.displayWidth(ofStored: 720) == 654)      // 654.5: nearest even
        #expect(PixelAspect(40, 33)!.displayWidth(ofStored: 720) == 872)      // 872.7
        #expect(PixelAspect.square.displayWidth(ofStored: 721) == 721)        // square pixels are never touched
        for a in PixelAspect.presets.dropFirst() { for w in [1, 3, 719, 720, 1439, 1920, 4095] { #expect(a.displayWidth(ofStored: w) % 2 == 0) } }
        #expect(PixelAspect(9, 5)!.displayWidth(ofStored: 3) == 6)            // 5.4
        #expect(PixelAspect(1, 4)!.displayWidth(ofStored: 1) == 2)            // never 0
        #expect(PixelAspect(2, 1)!.displayWidth(ofStored: 0) == 0)
    }

    @Test func displaySizeUsesTagOverrideAndRotation() {
        #expect(video(1920, 1080).displayWidth == 1920)
        let tagged = video(1440, 1080, tag: PixelAspect(4, 3)!)
        #expect(tagged.displayWidth == 1920 && tagged.displayHeight == 1080)
        #expect(tagged.desqueezedWidth == 1920)
        let overridden = video(1440, 1080, tag: PixelAspect(4, 3)!, override: .square)
        #expect(overridden.displayPixelAspect == .square)
        #expect(overridden.displayWidth == 1440)
        // The stored width is desqueezed before the quarter turn.
        let turned = video(1920, 1080, rotation: 90, override: PixelAspect(2, 1)!)
        #expect(turned.displayWidth == 1080 && turned.displayHeight == 3840)
        // What the engines draw a rotated source at (before the turn): desqueezed stored width x stored height.
        #expect(turned.desqueezedWidth == 3840 && turned.height == 1080)
    }

    @Test func fitUsesTheDisplaySize() {
        let (p, _, clip) = projectWith(video(1920, 1080, override: PixelAspect(2, 1)!))
        let c = p.timelines[0].tracks[0].clips.first { $0.id == clip }!
        #expect(p.pictureSize(of: c)! == (3840, 1080))
        #expect(p.frameFitScale(of: c, in: p.timelines[0]) == 0.5)
        #expect(p.frameFillScale(of: c, in: p.timelines[0]) == 1)
    }

    @Test func sequenceFromClipHasTheDisplaySize() {
        let (p, id, _) = projectWith(video(1920, 1080, override: PixelAspect(4, 3)!))
        let t = p.sequence(fromMedia: id)!
        #expect(t.format.width == 2560 && t.format.height == 1080)
    }

    /// One rule for the odd case: the sequence made from a clip is as wide as the layer the engines draw, and even.
    @Test func sequenceFromClipIsEvenAndMatchesTheLayerWidth() {
        let v = video(720, 480, tag: PixelAspect(10, 11)!)
        let (p, id, _) = projectWith(v)
        let t = p.sequence(fromMedia: id)!
        #expect(t.format.width == 654 && t.format.height == 480)
        #expect(t.format.width == v.desqueezedWidth)
        let turned = video(720, 480, rotation: 90, tag: PixelAspect(40, 33)!)
        #expect(turned.displayWidth == 480 && turned.displayHeight == 872)
    }

    @Test func setPixelAspectChangesTheItemAndLeavesClipsAlone() {
        var (p, id, _) = projectWith(video(1920, 1080))
        let before = p.timelines
        do { let r = p.setPixelAspect(PixelAspect(2, 1)!, for: id); #expect(r) }
        #expect(p.media(id)?.info?.video?.pixelAspectOverride == PixelAspect(2, 1))
        #expect(p.media(id)?.info?.video?.displayWidth == 3840)
        #expect(p.pixelAspect(of: id) == PixelAspect(2, 1))
        #expect(p.timelines == before)                                   // Scale stays, as in Interpret Footage
        do { let r = p.setPixelAspect(PixelAspect(2, 1)!, for: id); #expect(!r) }          // unchanged
        do { let r = p.setPixelAspect(nil, for: id); #expect(r) }                          // back to what the file says
        #expect(p.media(id)?.info?.video?.pixelAspectOverride == nil)
        #expect(p.media(id)?.info?.video?.displayWidth == 1920)
        do { let r = p.setPixelAspect(.square, for: UUID()); #expect(!r) }
    }

    @Test func settingTheFilesOwnRatioStoresNoOverride() {
        var (p, id, _) = projectWith(video(1440, 1080, tag: PixelAspect(4, 3)!))
        do { let r = p.setPixelAspect(PixelAspect(4, 3)!, for: id); #expect(!r) }
        do { let r = p.setPixelAspect(.square, for: id); #expect(r) }
        #expect(p.media(id)?.info?.video?.displayWidth == 1440)
        do { let r = p.setPixelAspect(PixelAspect(4, 3)!, for: id); #expect(r) }
        #expect(p.media(id)?.info?.video?.pixelAspectOverride == nil)
    }

    @Test func mediaWithoutPictureIsRefused() {
        var p = Project(name: "P", media: [MediaRef(name: "a.wav", path: "/a.wav", fingerprint: MediaFingerprint(size: 1),
                                                    info: MediaInfo(duration: Time(1, 1), audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm")))])
        do { let r = p.setPixelAspect(PixelAspect(2, 1)!, for: p.media[0].id); #expect(!r) }
        #expect(p.pixelAspect(of: p.media[0].id) == nil)
    }

    @Test func subclipsFollowTheirFile() throws {
        var (p, id, _) = projectWith(video(1920, 1080))
        var sub = p.media[0]
        sub.id = UUID(); sub.name = "sub"
        sub.subclip = Subclip(parent: id, range: TimeRange(start: .zero, duration: Time(1, 1)))
        p.add(sub)
        do { let r = p.setPixelAspect(PixelAspect(3, 2)!, for: sub.id); #expect(r) }
        #expect(p.media(id)?.info?.video?.displayWidth == 2880)
        #expect(p.media(sub.id)?.info?.video?.displayWidth == 2880)
    }

    @Test func replaceMediaKeepsTheChosenRatio() {
        var (p, id, _) = projectWith(video(1920, 1080))
        p.setPixelAspect(PixelAspect(2, 1)!, for: id)
        let other = MediaRef(name: "b.mov", path: "/b.mov", fingerprint: MediaFingerprint(size: 2), duration: Time(10, 1),
                             info: MediaInfo(duration: Time(10, 1), video: video(3840, 2160)))
        do { let r = p.replaceMedia(id, with: other); #expect(r) }
        #expect(p.media(id)?.info?.video?.width == 3840)
        #expect(p.media(id)?.info?.video?.pixelAspectOverride == PixelAspect(2, 1))
    }

    /// Relink points the item at another path and leaves its info (and the chosen ratio in it) alone; a later probe
    /// result only fills media without info, so it cannot drop the choice. Unprobed media gets the file's own tag.
    @Test func relinkKeepsTheChosenRatioThroughTheReprobe() {
        var (p, id, _) = projectWith(video(1920, 1080))
        p.setPixelAspect(PixelAspect(2, 1)!, for: id)
        p.relink([id: "/moved/a.mov"])
        #expect(p.media(id)?.path == "/moved/a.mov")
        #expect(p.pixelAspect(of: id) == PixelAspect(2, 1))
        p.adoptProbedInfo([id: MediaInfo(duration: Time(10, 1), video: video(1920, 1080, tag: PixelAspect(4, 3)!))])
        #expect(p.pixelAspect(of: id) == PixelAspect(2, 1))
        // Unprobed: no info yet, so the reprobe brings the file's tag and there is no choice to re-apply.
        var q = Project(name: "Q", media: [MediaRef(name: "b.mov", path: "/b.mov", fingerprint: MediaFingerprint(size: 1))])
        let qid = q.media[0].id
        q.relink([qid: "/new/b.mov"])
        #expect(q.pixelAspect(of: qid) == nil)
        q.adoptProbedInfo([qid: MediaInfo(duration: Time(10, 1), video: video(1440, 1080, tag: PixelAspect(4, 3)!))])
        #expect(q.pixelAspect(of: qid) == PixelAspect(4, 3))
    }

    @Test func replaceMediaWithoutProbeInfoKeepsTheChosenRatio() {
        var (p, id, _) = projectWith(video(1920, 1080))
        p.setPixelAspect(PixelAspect(2, 1)!, for: id)
        let other = MediaRef(name: "b.mov", path: "/b.mov", fingerprint: MediaFingerprint(size: 2), duration: Time(10, 1), info: nil)
        do { let r = p.replaceMedia(id, with: other); #expect(r) }
        #expect(p.media(id)?.path == "/b.mov")
        #expect(p.media(id)?.info?.video?.pixelAspectOverride == PixelAspect(2, 1))
        // Without a choice, the old probe info does not outlive the old file.
        var (q, qid, _) = projectWith(video(1920, 1080))
        q.replaceMedia(qid, with: other)
        #expect(q.media(qid)?.info == nil)
    }

    @Test func engineInfoAdoptsTheProjectsInterpretation() {
        let decoded = video(1920, 1080, tag: PixelAspect(4, 3)!)
        #expect(decoded.adoptingPixelAspect(of: nil).desqueezedWidth == 1920)                       // unknown to the project: square
        #expect(decoded.adoptingPixelAspect(of: video(1920, 1080)).desqueezedWidth == 1920)         // an old project: square
        #expect(decoded.adoptingPixelAspect(of: video(1920, 1080, override: PixelAspect(2, 1)!)).desqueezedWidth == 3840)
    }
}

@Suite struct ProjectFileV69Tests {
    private func json(_ d: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: d) as! [String: Any] }

    @Test func versionConstant() {
        #expect(ProjectFile.v69Version == 69)
        #expect(ProjectFile.currentVersion >= 69)
    }

    @Test func squareMediaWritesNoKeyAndNoNewVersion() throws {
        let (p, _, _) = projectWith(video(1920, 1080))
        #expect(!p.containsV69Content)
        #expect(ProjectFile.writtenVersion(for: p) < 69)
        let text = String(decoding: try ProjectFile.encode(p), as: UTF8.self)
        #expect(!text.contains("pixelAspect"))
        // Setting and clearing leaves nothing behind.
        var q = p
        q.setPixelAspect(PixelAspect(2, 1)!, for: q.media[0].id)
        q.setPixelAspect(nil, for: q.media[0].id)
        #expect(try ProjectFile.encode(q) == ProjectFile.encode(p))
    }

    @Test func overrideWritesV69AndRoundTrips() throws {
        var (p, id, _) = projectWith(video(1920, 1080))
        p.setPixelAspect(PixelAspect(4, 3)!, for: id)
        #expect(p.containsV69Content)
        #expect(ProjectFile.writtenVersion(for: p) == 69)
        let data = try ProjectFile.encode(p)
        #expect(try json(data)["formatVersion"] as? Int == 69)
        let back = try ProjectFile.decode(data, migrations: nil)
        #expect(back == p)
        #expect(back.media(id)?.info?.video?.displayWidth == 2560)
        #expect(try ProjectFile.encode(back) == data)
        #expect(try ProjectFile.decode(data, migrations: ProjectFile.migrations) == p)
    }

    @Test func fileTagWritesV69AndRoundTrips() throws {
        let (p, id, _) = projectWith(video(1440, 1080, tag: PixelAspect(4, 3)!))
        #expect(ProjectFile.writtenVersion(for: p) == 69)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p)
        #expect(back.media(id)?.info?.video?.pixelAspect == PixelAspect(4, 3))
    }

    private func stripped(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            return d.filter { $0.key != "pixelAspect" && $0.key != "pixelAspectOverride" }.mapValues(stripped)
        }
        if let a = v as? [Any] { return a.map(stripped) }
        return v
    }

    /// A file from before v69 has no pixel aspect keys: every item opens square, also when its file is tagged, and the
    /// engines (which adopt the item's reading) keep drawing it at its stored size.
    @Test func olderFileOpensSquare() throws {
        let (tagged, id, _) = projectWith(video(1440, 1080, tag: PixelAspect(4, 3)!, override: PixelAspect(2, 1)!))
        let written = try json(try ProjectFile.encode(tagged))
        #expect(written["formatVersion"] as? Int == 69)
        var obj = try #require(stripped(written) as? [String: Any])
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self).contains("pixelAspect"))
        var p = tagged
        p.media[0].info?.video?.pixelAspect = .square
        p.media[0].info?.video?.pixelAspectOverride = nil
        obj["formatVersion"] = 67
        obj["appFormat"] = 67
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back == p)
        #expect(back.media(id)?.info?.video?.displayPixelAspect == .square)
        #expect(back.media(id)?.info?.video?.displayWidth == 1440)
        // The decoder reads the file's 4:3 tag; the engine draws what the old project says.
        let decoded = video(1440, 1080, tag: PixelAspect(4, 3)!)
        #expect(decoded.adoptingPixelAspect(of: back.media(id)?.info?.video).desqueezedWidth == 1440)
        #expect(ProjectFile.writtenVersion(for: back) < 69)
    }

    @Test func malformedRatioOpensSquare() throws {
        let v = video(1920, 1080, override: PixelAspect(2, 1)!)
        var obj = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(v)) as! [String: Any]
        obj["pixelAspectOverride"] = ["num": 0, "den": 3]
        obj["pixelAspect"] = "wide"
        let back = try JSONDecoder().decode(VideoTrackInfo.self, from: try JSONSerialization.data(withJSONObject: obj))
        #expect(back.pixelAspect == .square && back.pixelAspectOverride == nil)
    }

    @Test func olderReaderRefusesANewerFile() throws {
        var (p, id, _) = projectWith(video(1920, 1080))
        p.setPixelAspect(PixelAspect(2, 1)!, for: id)
        var obj = try json(try ProjectFile.encode(p))
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations)
        }
    }
}

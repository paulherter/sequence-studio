import Foundation
import Testing
@testable import SQCore

/// W9.3: camera input color spaces (camera + Log + SDR/HDR), project default, ProjectFile v34.
@Suite struct InputColorSpaceTests {
    // MARK: Camera profiles

    @Test func cameraProfilesResolveToTheirCurve() {
        func id(_ c: CameraMake, log: Bool = false, _ r: DynamicRange = .sdr) -> ColorSpaceID? {
            InputColorProfile(camera: c, log: log, range: r).colorSpace
        }
        #expect(id(.sony, log: true) == .sLog3SGamut3Cine)
        #expect(id(.iPhone, log: true) == .appleLog)
        #expect(id(.dji, log: true) == .dLogDGamut)
        #expect(id(.panasonic, log: true) == .vLogVGamut)
        #expect(id(.canon, log: true) == .canonLog3CinemaGamut)
        #expect(id(.goPro, log: true) == nil)            // GP-Log: no published curve yet
        #expect(id(.other, log: true) == nil)
        for c in CameraMake.allCases {
            #expect(id(c) == .rec709)
            #expect(id(c, .hlg) == .hlgBT2020)
            #expect(id(c, .pq) == .pqBT2020)
        }
        #expect(InputColorProfile.logAvailable(for: .goPro) == false)
        #expect(InputColorProfile.logAvailable(for: .panasonic))
    }

    @Test func canonOffersEveryCurveAndColorSpace() {
        let canon: [ColorSpaceID] = [.canonLogCinemaGamut, .canonLogBT2020, .canonLogBT709, .canonLog2CinemaGamut,
                                     .canonLog2BT2020, .canonLog2BT709, .canonLog3CinemaGamut, .canonLog3BT2020,
                                     .canonLog3BT709]
        let offered = InputColorProfile.logSpaces(for: .canon)
        #expect(Set(offered) == Set(canon) && offered.count == canon.count)
        #expect(offered.first == InputColorProfile.logSpace(for: .canon))
        for s in canon {
            #expect(s.isLog && !s.isHDR)
            #expect(s.displayName.hasPrefix("Canon Log"))
            #expect(InputColorProfile(camera: .canon, log: true, logVariant: s).colorSpace == s)
            #expect(InputColorProfile(describing: s).camera == .canon)
        }
        #expect(Set(canon.map(\.displayName)).count == canon.count)
        // A variant of another camera is ignored; Log off ignores the variant.
        #expect(InputColorProfile(camera: .sony, log: true, logVariant: .canonLog2BT2020).colorSpace == .sLog3SGamut3Cine)
        #expect(InputColorProfile(camera: .canon, log: false, logVariant: .canonLog2BT2020).colorSpace == .rec709)
        // The other cameras list exactly their one curve.
        #expect(InputColorProfile.logSpaces(for: .sony) == [.sLog3SGamut3Cine])
        #expect(InputColorProfile.logSpaces(for: .goPro).isEmpty)
        // A profile stored without the variant key still decodes.
        let old = try? JSONDecoder().decode(InputColorProfile.self,
                                            from: Data(#"{"camera":"sony","log":true,"range":"sdr"}"#.utf8))
        #expect(old?.colorSpace == .sLog3SGamut3Cine)
    }

    @Test func canonSpacesSurviveAClipColorRoundTrip() throws {
        for s in InputColorProfile.logSpaces(for: .canon) {
            let c = ClipFootageColor(source: s)
            let back = try JSONDecoder().decode(ClipFootageColor.self, from: JSONEncoder().encode(c))
            #expect(back.source == s)
        }
    }

    @Test func logWinsOverTheDynamicRange() {
        #expect(InputColorProfile(camera: .iPhone, log: true, range: .hlg).colorSpace == .appleLog)
    }

    @Test func everySpaceDescribesItselfAsAProfileThatResolvesBack() {
        for s in ColorSpaceID.allCases {
            let p = InputColorProfile(describing: s)
            #expect(p.colorSpace == s, "\(s)")
            #expect(!s.displayName.isEmpty)
        }
    }

    @Test func logAndHDRFlags() {
        #expect(ColorSpaceID.rec709.isLog == false && ColorSpaceID.rec709.isHDR == false)
        #expect(ColorSpaceID.hlgBT2020.isHDR && !ColorSpaceID.hlgBT2020.isLog)
        #expect(ColorSpaceID.pqBT2020.isHDR && !ColorSpaceID.pqBT2020.isLog)
        for s: ColorSpaceID in [.sLog3SGamut3Cine, .vLogVGamut, .appleLog, .dLogDGamut] { #expect(s.isLog && !s.isHDR) }
    }

    @Test func rawValuesAreStable() {
        // Stored in .sqproj files: never rename.
        #expect(ColorSpaceID.allCases.map(\.rawValue) ==
                ["rec709", "sLog3SGamut3Cine", "hlgBT2020", "pqBT2020", "vLogVGamut", "appleLog", "dLogDGamut",
                 "canonLogCinemaGamut", "canonLogBT2020", "canonLogBT709", "canonLog2CinemaGamut", "canonLog2BT2020",
                 "canonLog2BT709", "canonLog3CinemaGamut", "canonLog3BT2020", "canonLog3BT709",
                 "logC3WideGamut3", "logC4WideGamut4", "log3G10RedWideGamut", "bmdFilmGen5WideGamut", "nLogBT2020",
                 "fLog2FGamutC", "acesCCTAP1"])
        #expect(CameraMake.canon.rawValue == "canon")
    }

    // MARK: Resolution order

    @Test func clipOverrideThenDetectionThenProjectDefault() {
        typealias C = ColorSpaceID
        // Clip override wins over everything (an explicit Rec.709 too).
        #expect(C.effective(clip: .rec709, detected: .sLog3SGamut3Cine, tagged: false, projectDefault: .vLogVGamut) == .rec709)
        #expect(C.effective(clip: .appleLog, detected: nil, tagged: false, projectDefault: nil) == .appleLog)
        // A real detection (Sony XML S-Log3, HLG/PQ tags) wins over the project default.
        #expect(C.effective(clip: nil, detected: .sLog3SGamut3Cine, tagged: false, projectDefault: .vLogVGamut) == .sLog3SGamut3Cine)
        #expect(C.effective(clip: nil, detected: .hlgBT2020, tagged: true, projectDefault: .dLogDGamut) == .hlgBT2020)
        // Tagged Rec.709 (iPhone SDR, screen recordings, ProRes overlays) is a real detection too.
        #expect(C.effective(clip: nil, detected: .rec709, tagged: true, projectDefault: .vLogVGamut) == .rec709)
        // Untagged video that detected as Rec.709 (Panasonic/DJI log): the project default applies.
        #expect(C.effective(clip: nil, detected: .rec709, tagged: false, projectDefault: .vLogVGamut) == .vLogVGamut)
        #expect(C.effective(clip: nil, detected: nil, tagged: false, projectDefault: .dLogDGamut) == .dLogDGamut)
        #expect(C.effective(clip: nil, detected: nil, tagged: false, projectDefault: nil) == .rec709)
        #expect(C.effective(clip: nil, detected: .rec709, tagged: false, projectDefault: nil) == .rec709)
    }

    private static func video(primaries: String? = nil, transfer: String? = nil) -> VideoTrackInfo {
        VideoTrackInfo(width: 10, height: 10, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                       nominalFrameDuration: Time(1, 25), isVariableFrameRate: false,
                       colorPrimaries: primaries, transfer: transfer)
    }

    @Test func mediaInfoTakesTheProjectDefaultOnlyForUntaggedVideoWithoutADetection() {
        let untagged = MediaInfo(duration: Time(1, 1), video: Self.video(), detectedColorSpace: .rec709)
        #expect(!untagged.hasColorTags)
        #expect(untagged.applyingProjectInput(.vLogVGamut).colorSpace == .vLogVGamut)
        #expect(untagged.applyingProjectInput(nil) == untagged)
        let sony = MediaInfo(duration: Time(1, 1), video: Self.video(), detectedColorSpace: .sLog3SGamut3Cine)
        #expect(sony.applyingProjectInput(.vLogVGamut).colorSpace == .sLog3SGamut3Cine)
        let still = MediaInfo(duration: Time(5, 1), video: Self.video(), detectedColorSpace: .rec709, isStill: true)
        #expect(still.applyingProjectInput(.appleLog).colorSpace == .rec709)
        let audio = MediaInfo(duration: Time(1, 1))
        #expect(audio.applyingProjectInput(.appleLog).detectedColorSpace == nil)
    }

    @Test func taggedRec709VideoIgnoresTheProjectDefault() {
        // iPhone SDR / screen recording: primaries + transfer tagged 709.
        let phone = MediaInfo(duration: Time(1, 1), video: Self.video(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2"),
                              detectedColorSpace: .rec709)
        #expect(phone.hasColorTags)
        #expect(phone.applyingProjectInput(.appleLog) == phone)
        // Only one of the two tags present still counts as tagged.
        let transferOnly = MediaInfo(duration: Time(1, 1), video: Self.video(transfer: "ITU_R_709_2"), detectedColorSpace: .rec709)
        #expect(transferOnly.applyingProjectInput(.vLogVGamut).colorSpace == .rec709)
        let primariesOnly = MediaInfo(duration: Time(1, 1), video: Self.video(primaries: "ITU_R_709_2"), detectedColorSpace: .rec709)
        #expect(primariesOnly.applyingProjectInput(.vLogVGamut).colorSpace == .rec709)
    }

    @Test func projectMediaForRenderingAppliesTheDefault() {
        let info = MediaInfo(duration: Time(1, 1), video: Self.video(), detectedColorSpace: .rec709)
        var p = Project(name: "P", media: [MediaRef(name: "a", path: "/a.mov", fingerprint: MediaFingerprint(size: 1), info: info)])
        #expect(p.mediaForRendering == p.media)
        p.inputColorSpace = .dLogDGamut
        #expect(p.mediaForRendering[0].info?.colorSpace == .dLogDGamut)
        #expect(p.media[0].info?.colorSpace == .rec709)   // the stored detection is untouched
    }

    // MARK: Codable

    @Test func newSpacesRoundTripInClipFootageAndMedia() throws {
        for s in ColorSpaceID.allCases {
            let f = ClipFootageColor(source: s)
            #expect(try JSONDecoder().decode(ClipFootageColor.self, from: JSONEncoder().encode(f)) == f)
            let c = ClipColor(source: s)
            #expect(try JSONDecoder().decode(ClipColor.self, from: JSONEncoder().encode(c)) == c)
            let m = MediaInfo(duration: Time(1, 1), detectedColorSpace: s)
            #expect(try JSONDecoder().decode(MediaInfo.self, from: JSONEncoder().encode(m)) == m)
        }
    }

    // MARK: ProjectFile v34

    @Test func projectDefaultRoundTripsThroughTheProjectFile() throws {
        var p = Project(name: "P")
        p.inputColorSpace = .appleLog
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.inputColorSpace == .appleLog)
        #expect(back == p)
    }

    @Test func aProjectWithoutADefaultWritesNoKey() throws {
        let data = try JSONEncoder().encode(Project(name: "P"))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["inputColorSpace"] == nil)
    }

    @Test func anUnknownDefaultIsDroppedAndTheProjectOpens() throws {
        let data = try JSONEncoder().encode(Project(name: "P"))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["inputColorSpace"] = "fancyLog9"
        let back = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.inputColorSpace == nil)
    }

    /// A v33 project with one media item per case: untagged-detection video, S-Log3 video, a still, audio only.
    private static func v33File() throws -> ProjectFile.JSONObject {
        let v = video()
        let media = [
            MediaRef(name: "a", path: "/a.mov", fingerprint: MediaFingerprint(size: 1),
                     info: MediaInfo(duration: Time(1, 1), video: v, detectedColorSpace: .rec709, embeddedLUTName: "x")),
            MediaRef(name: "b", path: "/b.mov", fingerprint: MediaFingerprint(size: 2),
                     info: MediaInfo(duration: Time(1, 1), video: v, detectedColorSpace: .sLog3SGamut3Cine)),
            MediaRef(name: "c", path: "/c.png", fingerprint: MediaFingerprint(size: 3),
                     info: MediaInfo(duration: Time(5, 1), video: v, detectedColorSpace: .rec709, isStill: true)),
            MediaRef(name: "d", path: "/d.wav", fingerprint: MediaFingerprint(size: 4),
                     info: MediaInfo(duration: Time(1, 1), audio: AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm"),
                                     detectedColorSpace: .rec709)),
        ]
        let data = try ProjectFile.encode(Project(name: "P", media: media))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? ProjectFile.JSONObject)
        obj["formatVersion"] = 33
        return obj
    }

    @Test func v33ToV34ResetsRec709DetectionOfVideoSoItIsDetectedAgain() throws {
        #expect(ProjectFile.currentVersion >= 34)
        let step = try #require(ProjectFile.realMigrations[33])
        let out = try step(Self.v33File())
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: out), migrations: ProjectFile.migrations)
        func space(_ name: String) -> ColorSpaceID? { back.media.first { $0.name == name }?.info?.detectedColorSpace }
        // Pre-v34 builds stored rec709 for PQ files and could not tell tagged from untagged: detect again.
        #expect(space("a") == nil)
        let a = back.media.first { $0.name == "a" }
        #expect(a?.info?.needsColorDetection == true)
        #expect(space("b") == .sLog3SGamut3Cine)   // a real detection stays
        #expect(space("c") == .rec709)             // stills are never re-detected
        #expect(space("d") == .rec709)             // audio only
    }

    @Test func v33ToV34LeavesAProjectWithoutMediaUnchanged() throws {
        let obj: ProjectFile.JSONObject = ["formatVersion": 33, "project": ["name": "P"] as ProjectFile.JSONObject]
        let step = try #require(ProjectFile.realMigrations[33])
        let out = try step(obj)
        #expect(jsonEqual(out, obj))
    }

    @Test func aV33FileWithMediaOpensAtV34AndSavesAsV34() throws {
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: Self.v33File()), migrations: ProjectFile.migrations)
        #expect(back.media.first { $0.name == "a" }?.info?.detectedColorSpace == nil)
        let saved = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(back)) as? [String: Any])
        #expect((saved["formatVersion"] as? Int ?? 0) >= 34)   // v34, or later once a newer step exists (v35 writes 34 without pending clips)
    }

    @Test func aV33FileOpensWithoutADefault() throws {
        let data = try ProjectFile.encode(Project(name: "P"))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = 33
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.inputColorSpace == nil)
    }

    @Test func aNewerProjectFileIsRefused() throws {
        let data = try ProjectFile.encode(Project(name: "P"))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        let expected = ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)
        #expect(throws: expected) { _ = try ProjectFile.decode(newer, migrations: ProjectFile.migrations) }
    }
}

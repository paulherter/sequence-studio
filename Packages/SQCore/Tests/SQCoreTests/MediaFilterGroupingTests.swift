import Foundation
import Testing
@testable import SQCore

@Suite struct MediaFilterGroupingTests {
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    func media(_ name: String, camera: String? = nil, created: Date? = nil, fps: Int64 = 25, label: LabelColor? = nil,
               path: String? = nil) -> MediaRef {
        var info = MediaInfo(duration: Time(10, 1), video: VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8,
            chroma: "4:2:0", nominalFrameDuration: Time(1, fps), isVariableFrameRate: false))
        info.cameraModel = camera; info.created = created
        return MediaRef(name: name, path: path ?? "/x/\(name).mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                        info: info, label: label)
    }

    @Test func parsesTokensAndKeepsFreeText() {
        let q = MediaFilterQuery.parse("window cam:FX3 unused fps:24 label:rose day:today kind:video")
        #expect(q.text == "window")
        #expect(q.tokens.map(\.text) == ["cam:FX3", "unused", "fps:24", "label:rose", "day:today", "kind:video"])
        #expect(MediaFilterQuery.parse("cam:\"Sony FX3\"").tokens == [MediaFilterToken(.camera, "Sony FX3")])
        #expect(MediaFilterToken.parse(MediaFilterToken(.camera, "Sony FX3").text) == MediaFilterToken(.camera, "Sony FX3"))
    }

    @Test func invalidTokensStayText() {
        let q = MediaFilterQuery.parse("cam: fps:abc label:nope day:soon kind:x foo:bar")
        #expect(q.tokens.isEmpty)
        #expect(q.text == "cam: fps:abc label:nope day:soon kind:x foo:bar")
    }

    @Test func extractWaitsForTheSpace() {
        let typing = MediaFilterToken.extract(from: "cam:FX3")
        #expect(typing.tokens.isEmpty && typing.rest == "cam:FX3")
        let done = MediaFilterToken.extract(from: "win cam:FX3 ")
        #expect(done.tokens == [MediaFilterToken(.camera, "FX3")])
        #expect(done.rest == "win ")
        #expect(MediaFilterToken.extract(from: "cam:FX3", final: true).tokens.count == 1)
    }

    @Test func filtersByEachToken() {
        let a = media("A", camera: "ILME-FX3", created: Self.date(2026, 10, 19), fps: 24, label: .rose)
        let b = media("B", camera: "iPhone 15 Pro", created: Self.date(2026, 10, 20), fps: 30)
        let now = Self.date(2026, 10, 20, 15), cal = Self.cal
        func ok(_ s: String, _ m: MediaRef, used: Bool = false) -> Bool {
            MediaFilterQuery.parse(s).matches(m, isUsed: used, now: now, calendar: cal)
        }
        #expect(ok("cam:fx3", a) && !ok("cam:fx3", b))
        #expect(ok("fps:24", a) && !ok("fps:24", b) && ok("fps:30", b))
        #expect(ok("day:yesterday", a) && !ok("day:yesterday", b) && ok("day:today", b))
        #expect(ok("day:2026-10-19", a) && !ok("day:2026-10-19", b))
        #expect(ok("label:rose", a) && ok("label:pink", a) && !ok("label:rose", b))
        #expect(ok("unused", a) && !ok("unused", a, used: true) && ok("used", a, used: true))
        #expect(ok("cam:fx3 fps:24 A", a) && !ok("cam:fx3 fps:30", a))
        #expect(ok("cam:fx3 cam:iphone", a) && ok("cam:fx3 cam:iphone", b))      // same kind = alternatives
        #expect(!ok("zzz", a))
    }

    @Test func fractionalFrameRate() {
        var m = media("N")
        m.info?.video?.nominalFrameDuration = Time(1001, 24000)
        #expect(MediaFilterToken(.fps, "23.976").matches(m, isUsed: false))
        #expect(MediaFilterToken(.fps, "24").matches(m, isUsed: false))
        #expect(MediaFilterQuery.values(for: .fps, in: [m]) == ["23.976"])
    }

    @Test func smartFolderUsesTokens() throws {
        let a = media("A", camera: "FX3"), b = media("B", camera: "GoPro")
        let bin = SmartBin(name: "s", tokens: [MediaFilterToken(.camera, "fx3")])
        #expect(bin.matches(a, isUsed: false, isOffline: false) && !bin.matches(b, isUsed: false, isOffline: false))
        let data = try JSONEncoder().encode(bin)
        #expect(try JSONDecoder().decode(SmartBin.self, from: data) == bin)
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","name":"o","text":"","usage":"any","kind":"any","offlineOnly":false}"#
        #expect(try JSONDecoder().decode(SmartBin.self, from: Data(old.utf8)).tokens == nil)
    }

    @Test func groupsByDayInShootingOrderAcrossCameras() {
        let a = media("late", camera: "FX3", created: Self.date(2026, 10, 19, 14))
        let b = media("early", camera: "iPhone", created: Self.date(2026, 10, 19, 9))
        let c = media("sun", camera: "FX3", created: Self.date(2026, 10, 20))
        var d = media("none"); d.fingerprint.modified = nil
        let g = MediaGrouping.day.groups(of: [c, a, d, b], calendar: Self.cal)
        #expect(g.map(\.id) == ["2026-10-19", "2026-10-20", "~"])
        #expect(g[0].items == [b.id, a.id])
        #expect(g[0].duration == Time(20, 1))
        #expect(g[2].title == "No Date")
    }

    @Test func groupsByCameraAndKind() {
        let a = media("a", camera: "FX3"), b = media("b", camera: "fx3 "), c = media("c", camera: "Alpha"), d = media("d")
        let g = MediaGrouping.camera.groups(of: [a, b, c, d])
        #expect(g.map(\.title) == ["Alpha", "FX3", "Unknown Camera"])
        #expect(g[1].items.count == 2)
        var photo = media("p", path: "/x/p.png"); photo.info?.video = nil; photo.info?.isStill = true
        #expect(MediaGrouping.kind.groups(of: [photo, a]).map(\.title) == ["Video", "Photo"])
        #expect(MediaGrouping.folders.groups(of: [a]).isEmpty)
    }

    @Test func mediaInfoRoundTripAndOldFiles() throws {
        var info = try #require(media("x", camera: "FX3", created: Self.date(2026, 10, 19)).info)
        info.shootProbed = true
        let back = try JSONDecoder().decode(MediaInfo.self, from: JSONEncoder().encode(info))
        #expect(back.cameraModel == "FX3" && back.created == info.created && back.shootProbed == true)
        let plain = try #require(media("y").info)
        #expect(try JSONDecoder().decode(MediaInfo.self, from: JSONEncoder().encode(plain)).shootProbed == nil)
    }
}

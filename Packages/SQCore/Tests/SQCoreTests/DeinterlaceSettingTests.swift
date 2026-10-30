import Foundation
import Testing
@testable import SQCore

@Suite struct DeinterlaceSettingTests {
    private func video(_ order: FieldOrder?, off: Bool = false) -> VideoTrackInfo {
        VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                       nominalFrameDuration: Time(1, 25), isVariableFrameRate: false, fieldOrder: order, deinterlaceOff: off)
    }

    private func project(_ v: VideoTrackInfo) -> (Project, MediaRef.ID) {
        let ref = MediaRef(name: "a.mxf", path: "/a.mxf", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                           info: MediaInfo(duration: Time(10, 1), video: v))
        return (Project(name: "P", media: [ref]), ref.id)
    }

    @Test func interlacedMediaIsDeinterlacedByDefault() {
        #expect(video(.topFirst).deinterlaceFieldOrder == .topFirst)
        #expect(video(.bottomFirst).deinterlaceFieldOrder == .bottomFirst)
        #expect(video(nil).deinterlaceFieldOrder == nil)
        #expect(video(.topFirst, off: true).deinterlaceFieldOrder == nil)
        #expect(video(.topFirst, off: true).fieldOrder == .topFirst)
    }

    @Test func theKeyIsWrittenOnlyWhenSwitchedOff() throws {
        let on = String(decoding: try JSONEncoder().encode(video(.topFirst)), as: UTF8.self)
        #expect(!on.contains("deinterlaceOff"))
        let data = try JSONEncoder().encode(video(.topFirst, off: true))
        #expect(String(decoding: data, as: UTF8.self).contains("\"deinterlaceOff\":true"))
        let back = try JSONDecoder().decode(VideoTrackInfo.self, from: data)
        #expect(back.deinterlaceOff)
        #expect(back == video(.topFirst, off: true))
    }

    @Test func aMalformedValueReadsAsOn() throws {
        let text = String(decoding: try JSONEncoder().encode(video(.topFirst, off: true)), as: UTF8.self)
            .replacingOccurrences(of: "\"deinterlaceOff\":true", with: "\"deinterlaceOff\":\"later\"")
        let back = try JSONDecoder().decode(VideoTrackInfo.self, from: Data(text.utf8))
        #expect(!back.deinterlaceOff)
        #expect(back.fieldOrder == .topFirst)
    }

    @Test func projectFileKeepsItsVersionAndRoundTrips() throws {
        var (p, id) = project(video(.topFirst))
        let before = ProjectFile.writtenVersion(for: p)
        do { let r = p.setDeinterlace(false, for: id); #expect(r) }
        #expect(ProjectFile.writtenVersion(for: p) == before)
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: nil)
        #expect(back.deinterlace(of: id) == false)
        #expect(back.media(id)?.info?.video?.fieldOrder == .topFirst)
    }

    @Test func setDeinterlaceTogglesInterlacedMediaOnly() {
        var (p, id) = project(video(.bottomFirst))
        #expect(p.deinterlace(of: id) == true)
        do { let r = p.setDeinterlace(true, for: id); #expect(!r) }      // already on
        do { let r = p.setDeinterlace(false, for: id); #expect(r) }
        #expect(p.deinterlace(of: id) == false)
        #expect(p.media(id)?.info?.video?.deinterlaceFieldOrder == nil)
        do { let r = p.setDeinterlace(true, for: id); #expect(r) }
        #expect(p.media(id)?.info?.video?.deinterlaceFieldOrder == .bottomFirst)

        var (q, qid) = project(video(nil))
        #expect(q.deinterlace(of: qid) == nil)
        do { let r = q.setDeinterlace(false, for: qid); #expect(!r) }
        #expect(q.media(qid)?.info?.video?.deinterlaceOff == false)
        do { let r = q.setDeinterlace(false, for: UUID()); #expect(!r) }
    }

    @Test func subclipsFollowTheirFile() {
        var (p, id) = project(video(.topFirst))
        var sub = p.media[0]
        sub.id = UUID(); sub.name = "sub"
        sub.subclip = Subclip(parent: id, range: TimeRange(start: .zero, duration: Time(1, 1)))
        p.add(sub)
        do { let r = p.setDeinterlace(false, for: sub.id); #expect(r) }
        #expect(p.deinterlace(of: id) == false)
        #expect(p.deinterlace(of: sub.id) == false)
    }

    @Test func replaceMediaKeepsTheSwitch() {
        var (p, id) = project(video(.topFirst))
        p.setDeinterlace(false, for: id)
        let other = MediaRef(name: "b.mxf", path: "/b.mxf", fingerprint: MediaFingerprint(size: 2), duration: Time(10, 1),
                             info: MediaInfo(duration: Time(10, 1), video: video(.bottomFirst)))
        do { let r = p.replaceMedia(id, with: other); #expect(r) }
        #expect(p.media(id)?.info?.video?.fieldOrder == .bottomFirst)
        #expect(p.deinterlace(of: id) == false)
    }
}

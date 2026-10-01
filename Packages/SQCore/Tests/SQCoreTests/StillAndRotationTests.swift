import Foundation
import Testing
@testable import SQCore

@Suite struct StillAndRotationTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    @Test func displaySizeSwapsForQuarterTurns() {
        func v(_ r: Int) -> VideoTrackInfo {
            VideoTrackInfo(width: 1920, height: 1080, codec: "hvc1", bitDepth: 10, chroma: "4:2:0",
                           nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, rotation: r)
        }
        #expect(v(0).displayWidth == 1920 && v(0).displayHeight == 1080)
        #expect(v(90).displayWidth == 1080 && v(90).displayHeight == 1920)
        #expect(v(180).displayWidth == 1920)
        #expect(v(270).displayWidth == 1080)
        #expect(v(-90).rotation == 270 && v(450).rotation == 90)
    }

    @Test func oldMediaInfoDecodesWithoutRotationAndStill() throws {
        let info = MediaInfo(duration: s(5), video: VideoTrackInfo(width: 10, height: 20, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                                                  nominalFrameDuration: Time(1, 30), isVariableFrameRate: false,
                                                                  rotation: 90), isStill: true)
        let data = try JSONEncoder().encode(info)
        #expect(try JSONDecoder().decode(MediaInfo.self, from: data) == info)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "isStill")
        var video = try #require(obj["video"] as? [String: Any])
        video.removeValue(forKey: "rotation")
        obj["video"] = video
        let old = try JSONDecoder().decode(MediaInfo.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(!old.isStill && old.video?.rotation == 0)
    }

    @Test func stillClipTrimsFreelyInBothDirections() throws {
        var t = Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [Track(kind: .video)])
        let media = UUID()
        try t.threePointEdit(source: TimeRange(start: .zero, duration: s(5)), media: media, name: "still",
                             mediaDuration: nil, isStill: true, targets: [t.tracks[0].id], at: s(10), mode: .overwrite)
        let id = t.tracks[0].clips[0].id
        #expect(t.tracks[0].clips[0].isStill)
        #expect(try t.trim(id, edge: .tail, by: s(100)) == s(100))
        #expect(try t.trim(id, edge: .head, by: s(-4)) == s(-4))
        #expect(t.tracks[0].clips[0].timeline.duration == s(109))
        let c = t.tracks[0].clips[0]
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back.isStill && back == c)
    }

    @Test func plainMediaClipKeepsHeadLimit() throws {
        var t = Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [Track(kind: .video)])
        try t.threePointEdit(source: TimeRange(start: .zero, duration: s(5)), media: UUID(), mediaDuration: s(5),
                             targets: [t.tracks[0].id], at: s(10), mode: .overwrite)
        let id = t.tracks[0].clips[0].id
        #expect(try t.trim(id, edge: .head, by: s(-4)) == .zero)
    }
}

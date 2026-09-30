import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ kind: TrackKind, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(4)), start: .zero, link: link)
}
private func track(_ kind: TrackKind, _ c: Clip) throws -> Track {
    var t = Track(kind: kind)
    try t.overwrite(c)
    return t
}

@Suite struct SequenceSettingsTests {
    @Test func presetsCoverPremiereSizesAndRates() {
        let sizes = SequenceFormatPresets.sizes.map { [$0.width, $0.height] }
        #expect(sizes.contains([1080, 1920]) && sizes.contains([1920, 1080]) && sizes.contains([3840, 2160]))
        #expect(sizes.contains([2160, 3840]) && sizes.contains([1080, 1350]) && sizes.contains([1080, 1080]))
        #expect(SequenceFormatPresets.frameRates.map(\.label) == ["23.976", "24", "25", "29.97", "30", "50", "59.94", "60"])
        #expect(SequenceFormatPresets.frameRates.first { $0.label == "29.97" }?.frameDuration == Time(1001, 30000))
        #expect(SequenceFormatPresets.frameRates.first { $0.label == "24" }?.frameDuration == Time(1, 24))
        #expect(SequenceFormatPresets.size(width: 1080, height: 1920)?.name.contains("9:16") == true)
        #expect(SequenceFormatPresets.size(width: 777, height: 555) == nil)
    }

    @Test func setFormatKeepsClipsAndIsValidated() throws {
        let tl = Timeline(name: "t", frameDuration: Time(1001, 30000), tracks: [try track(.video, clip(.video))])
        var p = Project(name: "p", timelines: [tl])
        let before = p.timelines[0].tracks
        try p.setFormat(SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30), audioSampleRate: 44_100),
                        of: tl.id)
        #expect(p.timelines[0].format.width == 1080 && p.timelines[0].format.height == 1920)
        #expect(p.timelines[0].tracks == before)
        #expect(throws: EditError.invalidFormat) {
            try p.setFormat(SequenceFormat(width: 0, height: 1080, frameDuration: Time(1, 30)), of: tl.id)
        }
        #expect(throws: EditError.timelineNotFound) {
            try p.setFormat(SequenceFormat(frameDuration: Time(1, 30)), of: UUID())
        }
    }

    @Test func primaryClipOfLinkedPairIsTheVideoClip() throws {
        let l = UUID()
        let v = clip(.video, link: l), a = clip(.audio, link: l), other = clip(.video)
        let tl = Timeline(name: "t", frameDuration: Time(1, 30),
                          tracks: [try track(.video, v), try track(.audio, a), try track(.video, other)])
        #expect(tl.primaryClip(of: [v.id, a.id])?.id == v.id)
        #expect(tl.primaryClip(of: [a.id])?.id == a.id)
        #expect(tl.primaryClip(of: [v.id, other.id]) == nil)
        #expect(tl.primaryClip(of: []) == nil)
    }
}

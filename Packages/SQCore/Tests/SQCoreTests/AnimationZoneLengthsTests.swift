import Foundation
import Testing
@testable import SQCore

@Suite struct AnimationZoneLengthsTests {
    private func project() throws -> (Project, Clip.ID) {
        var t = Track(kind: .video)
        let c = Clip(name: "G", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        try t.overwrite(c)
        var p = Project(name: "P")
        p.timelines = [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [t])]
        return (p, c.id)
    }

    @Test func setsBothLengthsAndRaisesTheFloor() throws {
        var (p, id) = try project()
        try p.setAnimationZoneLengths(intro: Time(2, 1), outro: Time(3, 1), clip: id)
        let c = try #require(p.allClips().first { $0.id == id })
        #expect(c.zones?.introEnd == Time(2, 1) && c.zones?.outroLength == Time(3, 1))
        #expect(c.minimumDuration(frame: Time(1, 30)) == Time(5, 1))
    }

    @Test func zonesNeverExceedTheClip() throws {
        var (p, id) = try project()
        try p.setAnimationZoneLengths(intro: Time(8, 1), outro: Time(9, 1), clip: id)
        let c = try #require(p.allClips().first { $0.id == id })
        #expect(c.zones?.introEnd == Time(8, 1) && c.zones?.outroLength == Time(2, 1))
        try p.setAnimationZoneLengths(intro: Time(-1, 1), outro: Time(1, 1), clip: id)
        #expect(p.allClips().first { $0.id == id }?.zones?.introEnd == .zero)
    }
}

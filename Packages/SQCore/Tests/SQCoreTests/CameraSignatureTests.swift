import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }
private func clip(_ media: UUID, start: Int64) -> Clip {
    Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: f(30)), start: f(start), mediaDuration: f(300))
}
private func info(width: Int, space: ColorSpaceID?) -> MediaInfo {
    MediaInfo(duration: f(300),
              video: VideoTrackInfo(width: width, height: 1080, codec: "hvc1", bitDepth: 10, chroma: "420",
                                    nominalFrameDuration: fd, isVariableFrameRate: false),
              detectedColorSpace: space)
}

@Suite struct CameraSignatureTests {
    @Test func gradesOnlyClipsOfTheSameCamera() throws {
        let camA = UUID(), camA2 = UUID(), camB = UUID()
        let infos = [camA: info(width: 1920, space: .rec709), camA2: info(width: 1920, space: .rec709),
                     camB: info(width: 3840, space: .rec709)]
        var track = Track(kind: .video)
        let src = clip(camA, start: 0), same = clip(camA2, start: 30), other = clip(camB, start: 60)
        for c in [src, same, other] { try track.overwrite(c) }
        var tl = Timeline(name: "T", frameDuration: fd, tracks: [track])
        var graded = tl.tracks[0].clips[0]
        var color = graded.color
        color.effects[0].basic.exposure = 1.5
        graded.color = color
        tl.tracks[0].replace(graded)
        let n = try tl.gradeAllFromCamera(of: src.id) { CameraSignature(infos[$0]) }
        #expect(n == 1)
        let clips = tl.tracks[0].clips
        #expect(clips[1].color.effects[0].basic.exposure == 1.5)
        #expect(clips[2].colorGradeEffects.isEmpty)
        #expect(clips[1].colorGradeEffects[0].id != clips[0].colorGradeEffects[0].id)
    }

    @Test func gradeFromPreviousClipCopiesGrade() throws {
        var track = Track(kind: .video)
        let a = clip(UUID(), start: 0), b = clip(UUID(), start: 30), c = clip(UUID(), start: 60)
        for x in [a, b, c] { try track.overwrite(x) }
        var tl = Timeline(name: "T", frameDuration: fd, tracks: [track])
        var g = tl.tracks[0].clips[0]
        var color = g.color
        color.effects[0].basic.exposure = 2
        g.color = color
        tl.tracks[0].replace(g)
        try tl.gradeFromPreviousClip(c.id, back: 2)
        #expect(tl.tracks[0].clips[2].color.effects[0].basic.exposure == 2)
        #expect(tl.tracks[0].clips[1].colorGradeEffects.isEmpty)
        #expect(throws: (any Error).self) { try tl.gradeFromPreviousClip(a.id) }
    }

    @Test func throwsWhenNothingMatches() throws {
        let m = UUID()
        var track = Track(kind: .video)
        let src = clip(m, start: 0)
        try track.overwrite(src)
        var tl = Timeline(name: "T", frameDuration: fd, tracks: [track])
        #expect(throws: (any Error).self) { try tl.gradeAllFromCamera(of: src.id) { _ in CameraSignature(info(width: 1920, space: nil)) } }
    }
}

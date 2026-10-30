import Foundation
import SQCore

/// One sequence: V1 = [a 0-4s][b 4-8s], A1 = [a' 0-4s] linked to a. 25 fps, media 20 s long.
struct Fixture {
    var project: Project
    var seq: Timeline.ID
    var v1: Track.ID
    var a1: Track.ID
    var a: Clip.ID
    var b: Clip.ID
    var aAudio: Clip.ID

    init() {
        let fd = Time(1, 25)
        let media = MediaRef(name: "m.mov", path: "/x/m.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(20, 1))
        let link = UUID()
        func clip(_ name: String, _ kind: TrackKind, at s: Int64, src: Int64, link: UUID? = nil) -> Clip {
            Clip(name: name, media: media.id, kind: kind, source: TimeRange(start: Time(src, 1), duration: Time(4, 1)),
                 start: Time(s, 1), link: link, mediaDuration: Time(20, 1))
        }
        let ca = clip("a", .video, at: 0, src: 2, link: link)
        let cb = clip("b", .video, at: 4, src: 10)
        let caa = clip("a", .audio, at: 0, src: 2, link: link)
        let v = Track(kind: .video, clips: [ca, cb], name: "V1", isTargeted: true)
        let au = Track(kind: .audio, clips: [caa], name: "A1", isTargeted: true)
        let t = Timeline(name: "Seq", frameDuration: fd, tracks: [v, au])
        var p = Project(name: "P", timelines: [t])
        p.add(media)
        project = p; seq = t.id; v1 = v.id; a1 = au.id; a = ca.id; b = cb.id; aAudio = caa.id
    }
}

extension Time {
    static func s(_ n: Int64) -> Time { Time(n, 1) }
}

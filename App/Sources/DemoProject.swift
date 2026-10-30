import Foundation
import SQCore
import SQEditorUI

/// Sample project for screenshots (`SQ_DEMO=1`): offline media refs and a busy 29.97 fps timeline. Not shipped UI.
@MainActor
enum DemoProject {
    static let fd = Time(1001, 30000)
    static func frames(_ n: Int64) -> Time { fd * n }
    static let playhead = frames(260)

    private static func ref(_ name: String, seconds: Int64, audio: Bool = true) -> MediaRef {
        let v = VideoTrackInfo(width: 3840, height: 2160, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                               nominalFrameDuration: fd, isVariableFrameRate: false)
        let a = audio ? AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "lpcm") : nil
        let d = Time(seconds, 1)
        return MediaRef(name: name, path: "/Volumes/Demo/\(name)", fingerprint: MediaFingerprint(size: 1),
                        duration: d, info: MediaInfo(duration: d, video: v, audio: a))
    }

    static func make() -> Project {
        let names = ["A001_C004_0912AB.mov", "A001_C007_0912CD.mov", "A002_C001_0913EF.mov", "A002_C012_0913GH.mov",
                     "B001_C003_0914IJ.mov", "B001_C009_0914KL.mov", "Interview_Main.mov", "Drone_Coast.mov"]
        let refs = names.map { ref($0, seconds: 40) }
        var project = Project(name: "Demo Edit")
        for r in refs { project.add(r) }

        var v1 = Track(kind: .video), v2 = Track(kind: .video)
        var a1 = Track(kind: .audio), a2 = Track(kind: .audio)
        v1.name = "V1"; v2.name = "V2"; a1.name = "A1"; a2.name = "A2"
        v1.isTargeted = true; a1.isTargeted = true
        let lengths: [Int64] = [150, 210, 120, 260, 180, 240, 140, 200]
        var at: Int64 = 0
        for (i, len) in lengths.enumerated() {
            let r = refs[i % refs.count]
            let link = UUID()
            let src = TimeRange(start: frames(30), duration: frames(len))
            try? v1.overwrite(Clip(name: r.name, media: r.id, kind: .video, source: src, start: frames(at), link: link,
                                   mediaDuration: r.duration))
            try? a1.overwrite(Clip(name: r.name, media: r.id, kind: .audio, source: src, start: frames(at), link: link,
                                   mediaDuration: r.duration))
            at += len + (i == 3 ? 24 : 0)
        }
        let over = refs[7]
        try? v2.overwrite(Clip(name: "Drone_Coast.mov", media: over.id, kind: .video,
                               source: TimeRange(start: .zero, duration: frames(180)), start: frames(200),
                               mediaDuration: over.duration))
        try? v2.overwrite(Clip(name: "Drone_Coast.mov", media: over.id, kind: .video,
                               source: TimeRange(start: frames(300), duration: frames(120)), start: frames(700),
                               mediaDuration: over.duration))
        let music = refs[6]
        try? a2.overwrite(Clip(name: "Interview_Main.mov", media: music.id, kind: .audio,
                               source: TimeRange(start: .zero, duration: frames(1300)), start: .zero,
                               mediaDuration: Time(60, 1)))

        var t = Timeline(name: "Main Sequence", format: SequenceFormat(width: 3840, height: 2160, frameDuration: fd),
                         tracks: [v1, v2, Track(kind: .video), Track(kind: .video), a1, a2, Track(kind: .audio), Track(kind: .audio)])
        t.addMarker(at: frames(150), name: "Cut to B-roll")
        t.addMarker(at: frames(480), name: "Music swell")
        t.inOut = TimeRange(start: frames(90), end: frames(540))
        project.timelines = [t]
        project.activeTimeline = t.id
        project.normalizeBins()
        return project
    }

    static func selection(in session: EditorSession) -> Set<Clip.ID> {
        guard let t = session.activeTimeline else { return [] }
        let hit = t.tracks.flatMap(\.clips).filter { $0.timeline.contains(frames(300)) && $0.kind == .video }
        let link = hit.first?.link
        return Set(t.tracks.flatMap(\.clips).filter { $0.link == link && link != nil }.map(\.id))
    }
}

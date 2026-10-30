import Foundation
import SQCore

/// The test project the Windows app and its Mac reference both build from one media file (video plus stereo audio):
/// V1 holds two shots of the file, A1 their linked sound, so select, move, razor and delete have something to work on.
public enum SampleProject {
    /// `frames`: the file's length in frames at `frameDuration` (at least 2 seconds' worth).
    /// `title`: a text clip on V2 over the whole of Shot A (`SampleTitle.ref()`), for the title comparison.
    /// `layers`: that many more video tracks above, each a scaled, turned, semi-transparent copy of the file over the
    /// whole sequence (same source times as V1), for playback load.
    public static func make(mediaPath: String, fileSize: Int64, width: Int, height: Int, frameDuration fd: Time,
                            frames: Int64, title: GeneratorRef? = nil, layers: Int = 0) -> Project {
        let media = MediaRef(id: UUID(uuidString: "5A5A0000-0000-4000-8000-000000000001")!, name: "sample.mp4",
                             path: mediaPath, fingerprint: MediaFingerprint(size: fileSize), duration: fd * frames)
        let firstLen = frames * 2 / 5, secondIn = frames / 2
        let ida = UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000A1")!
        let idb = UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000B1")!
        let linkA = UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000A0")!
        let linkB = UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000B0")!
        func pair(_ id: UUID, _ link: UUID, name: String, src: Int64, len: Int64, at: Int64) -> (Clip, Clip) {
            let range = TimeRange(start: fd * src, duration: fd * len)
            let v = Clip(id: id, name: name, media: media.id, kind: .video, source: range, start: fd * at, link: link,
                         mediaDuration: media.duration)
            var aID = id.uuid
            aID.15 ^= 0xFF
            let a = Clip(id: UUID(uuid: aID), name: name, media: media.id, kind: .audio, source: range, start: fd * at,
                         link: link, mediaDuration: media.duration)
            return (v, a)
        }
        let (va, aa) = pair(ida, linkA, name: "Shot A", src: 0, len: firstLen, at: 0)
        let (vb, ab) = pair(idb, linkB, name: "Shot B", src: secondIn, len: frames - secondIn, at: firstLen)
        let v1 = Track(id: UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000F1")!, kind: .video, clips: [va, vb], name: "V1")
        let titleClip = title.map {
            Clip(id: UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000C1")!, name: "Title",
                 media: UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000C0")!, kind: .video,
                 source: TimeRange(start: .zero, duration: fd * firstLen), start: .zero, generator: $0)
        }
        let v2 = Track(id: UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000F2")!, kind: .video,
                       clips: titleClip.map { [$0] } ?? [], name: "V2")
        let a1 = Track(id: UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000F3")!, kind: .audio, clips: [aa, ab], name: "A1")
        let extra = (0..<max(0, layers)).map { k -> Track in
            var c = Clip(name: "Layer \(k + 1)", media: media.id, kind: .video,
                         source: TimeRange(start: .zero, duration: fd * frames), start: .zero, mediaDuration: media.duration)
            c.animation.scale = AnimatedProperty(Vec2(0.45, 0.45))
            c.animation.position = AnimatedProperty(Vec2(Double(k % 3 - 1) * Double(width) * 0.3,
                                                         Double(k / 3 % 3 - 1) * Double(height) * 0.3))
            c.animation.rotation = AnimatedProperty(Double(k * 5))
            c.animation.opacity = AnimatedProperty(0.85)
            return Track(kind: .video, clips: [c], name: "V\(k + 3)")
        }
        let timeline = Timeline(id: UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000E1")!, name: "Sequence 1",
                                format: SequenceFormat(width: width, height: height, frameDuration: fd), tracks: [v1, v2] + extra + [a1])
        return Project(id: UUID(uuidString: "5A5A0000-0000-4000-8000-0000000000D1")!, name: "Windows Sample",
                       media: [media], timelines: [timeline])
    }
}

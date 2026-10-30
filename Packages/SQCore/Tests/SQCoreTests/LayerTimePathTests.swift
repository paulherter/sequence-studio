import Foundation
import Testing
@testable import SQCore

/// `LayerTimePath` gives a layer's source time at a nearby timeline time without evaluating the timeline: wherever it
/// answers, the full evaluation gives the same time.
@Suite struct LayerTimePathTests {
    static let fd = Time(1, 30)

    static func file(_ n: String, at frame: Int64, frames: Int64, speed: ClipSpeed = .normal, reversed: Bool = false,
                     fd: Time = fd) -> Clip {
        let length = fd * frames
        let source = TimeRange(start: Time(1, 1), duration: Time(length.value * Int64(speed.num), length.timescale * Int64(speed.den)))
        return Clip(name: n, media: UUID(), kind: .video, source: source, start: fd * frame, speed: speed, reversed: reversed)
    }

    static func nested(_ inner: Timeline, at frame: Int64, frames: Int64, from: Int64 = 0, fd: Time = fd) -> Clip {
        Clip(name: inner.name, media: inner.id, kind: .video, source: TimeRange(start: inner.frameDuration * from, duration: fd * frames),
             start: fd * frame, sequence: inner.id)
    }

    /// Three levels: `top` holds a nested `middle` (25 fps), which holds a nested `inner`; plain, fast, slow and
    /// reversed file clips, gaps, a second track and a transition layer above them.
    static func project() throws -> (project: Project, top: Timeline.ID) {
        var held = file("held", at: 60, frames: 20)
        held.holdFrame = Time(3, 2)
        let inner = Timeline(name: "inner", frameDuration: fd, tracks: [
            Track(kind: .video, clips: [file("i1", at: 0, frames: 20), file("i2", at: 20, frames: 20, reversed: true),
                                        file("i3", at: 40, frames: 20, speed: ClipSpeed(num: 2, den: 1)), held,
                                        file("i5", at: 80, frames: 40, speed: ClipSpeed(num: 1, den: 2))]),
            Track(kind: .video, clips: [file("j1", at: 5, frames: 25), file("j2", at: 50, frames: 31, reversed: true)]),
        ])
        let m = Time(1, 25)
        let middle = Timeline(name: "middle", frameDuration: m, tracks: [
            Track(kind: .video, clips: [nested(inner, at: 0, frames: 40, from: 7, fd: m), file("m1", at: 40, frames: 13, fd: m),
                                        nested(inner, at: 60, frames: 30, from: 30, fd: m)]),
        ])
        let v3 = Track(kind: .video)
        let top = Timeline(name: "top", frameDuration: fd, tracks: [
            Track(kind: .video, clips: [nested(middle, at: 0, frames: 70), nested(inner, at: 70, frames: 50, from: 3),
                                        file("t1", at: 125, frames: 30, reversed: true)]),
            Track(kind: .video, clips: [file("u1", at: 10, frames: 33, speed: ClipSpeed(num: 3, den: 1)), file("u2", at: 43, frames: 40),
                                        file("u3", at: 100, frames: 45)]),
            v3,
        ])
        var p = Project(name: "P", timelines: [top, middle, inner])
        _ = try p.addTransitionLayer(kind: .dipToBlack, in: top.id, at: fd * 28, track: v3.id, duration: fd * 12)
        _ = try p.addTransitionLayer(kind: .spin, in: top.id, at: fd * 90, track: v3.id, duration: fd * 10)
        return (p, top.id)
    }

    static func chain(_ r: LayerRequest) -> [UUID] { r.groups.map(\.clip) + [r.clip] }

    @Test func thePathGivesTheEvaluatedSourceTimeOrNothing() throws {
        let (p, id) = try Self.project()
        let top = try #require(p.timeline(id))
        let sequences: SequenceResolver = { p.timeline($0) }
        var asked = 0, answered = 0, layers = 0, paths = 0
        for f in 0..<160 {
            let t = Self.fd * Int64(f)
            for r in top.videoLayers(at: t, sequences: sequences) where r.generator == nil {
                layers += 1
                guard let path = LayerTimePath(r, at: t, in: top, sequences: sequences) else { continue }
                paths += 1
                #expect(path.sourceTime(at: t) == r.sourceTime)
                for k in -4...4 where k != 0 && f + k >= 0 {
                    let at = Self.fd * Int64(f + k)
                    asked += 1
                    guard let derived = path.sourceTime(at: at) else { continue }
                    answered += 1
                    let same = top.videoLayers(at: at, sequences: sequences).filter { Self.chain($0) == Self.chain(r) }
                    #expect(!same.isEmpty, "frame \(f) + \(k): the path answers for a layer the evaluation does not show")
                    #expect(same.allSatisfy { $0.sourceTime == derived }, "frame \(f) + \(k): \(derived) is not the evaluated time")
                }
            }
        }
        // Not vacuous: most layers have a path, and most nearby times are answered without an evaluation.
        #expect(paths * 10 >= layers * 7, "\(paths) of \(layers) layers have a path")
        #expect(answered * 10 >= asked * 7, "\(answered) of \(asked) times answered")
    }

    @Test func aTimeOutsideTheClipOrUnderATransitionLayerIsLeftToTheEvaluation() throws {
        let (p, id) = try Self.project()
        let top = try #require(p.timeline(id))
        let sequences: SequenceResolver = { p.timeline($0) }
        func path(_ name: String, at f: Int64) -> LayerTimePath? {
            let t = Self.fd * f
            return top.videoLayers(at: t, sequences: sequences)
                .first { r in top.tracks.contains { $0.clips.contains { $0.id == r.clip && $0.name == name } } }
                .flatMap { LayerTimePath($0, at: t, in: top, sequences: sequences) }
        }
        // u3 runs from frame 100 to 145.
        let u3 = try #require(path("u3", at: 141))
        #expect(u3.sourceTime(at: Self.fd * 144) == Time(1, 1) + Self.fd * 44)
        #expect(u3.sourceTime(at: Self.fd * 145) == nil && u3.sourceTime(at: Self.fd * 99) == nil)
        // u2 (43..<83) is under the first transition layer until frame 40 and clear of the second (from 90).
        #expect(path("u1", at: 30) == nil)
        let u1 = try #require(path("u1", at: 24))
        #expect(u1.sourceTime(at: Self.fd * 27) != nil && u1.sourceTime(at: Self.fd * 28) == nil)
    }
}

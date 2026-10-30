import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
/// How far the helper key of the two-key form sat behind its leader.
private let step = Time(1, 1_000_000)

// v77: Hold Ahead is a shape of the key. Files up to v76 wrote it as two keys (a Hold key and a helper Hold key one
// microsecond later on the next key's value); decoding folds them into one key and the picture stays the same.

@Suite struct ProjectFileV77Tests {
    /// The two-key form as a v76 build wrote it: a plain key, the leader, its helper, the next key, a last key.
    private static func legacy<V: KeyframeValue>(_ a: V, _ b: V, _ c: V) -> KeyframeTrack<V> {
        KeyframeTrack(keys: [
            Keyframe(time: s(1), value: c),
            Keyframe(time: s(2), value: a, interpolation: .hold),
            Keyframe(time: s(2) + step, value: b, interpolation: .hold),
            Keyframe(time: s(6), value: b),
            Keyframe(time: s(8), value: c),
        ])
    }

    private static func expectFolded<V: KeyframeValue>(_ t: KeyframeTrack<V>, from old: KeyframeTrack<V>, _ name: String) {
        #expect(t.keys.count == 4, "\(name): the helper is gone")
        #expect(t.keys.map(\.interpolation) == [.linear, .holdAhead, .linear, .linear], "\(name)")
        #expect(t.keys.map(\.id) == [0, 1, 3, 4].map { old.keys[$0].id }, "\(name): the other keys keep their ids")
        #expect(t.keys.map(\.time) == [s(1), s(2), s(6), s(8)], "\(name)")
        for i in 0...300 {
            let at = Time(Int64(i), 30)
            #expect(t.value(at: at) == old.value(at: at), "\(name), frame \(i)")
        }
    }

    private static let bandX = ClipEffect.graphicEQBandKeys[0], bandY = ClipEffect.graphicEQBandKeys[1]

    /// A project with the two-key form in every kind of track: scalar, Vec2, the two members of a pair row, a mask path,
    /// an audio level.
    private static func v76Project() throws -> Project {
        var v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        v.animation.opacity.track = legacy(0.8, 0.2, 0.5)
        v.animation.position.track = legacy(Vec2(0, 0), Vec2(100, 40), Vec2(-20, 300))
        var mask = ClipMask(path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))
        mask.path.track = legacy(MaskPath.rectangle(Vec2(0.1, 0.1), Vec2(0.4, 0.4)), .rectangle(Vec2(0.5, 0.5), Vec2(0.9, 0.9)),
                                 .rectangle(Vec2(0, 0), Vec2(1, 1)))
        mask.feather.track = legacy(1, 8, 3)
        v.masks = [mask]
        var a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
        a.animation.volume.track = legacy(1.0, 0.25, 0.5)
        let fx = a.addEffect(kind: ClipEffect.audioGraphicEQKind)
        let i = try #require(a.effects.firstIndex { $0.id == fx })
        a.effects[i].parameters[bandX]?.track = legacy(3, -6, 0)
        a.effects[i].parameters[bandY]?.track = legacy(-2, 5, 1)
        var vt = Track(kind: .video), at = Track(kind: .audio)
        try vt.overwrite(v)
        try at.overwrite(a)
        return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                                                       tracks: [vt, at])])
    }

    private static func version(of data: Data) throws -> Int {
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(obj["formatVersion"] as? Int)
    }

    @Test func currentVersionIs77() { #expect(ProjectFile.currentVersion >= 77 && ProjectFile.v77Version == 77) }

    @Test func aV76FileFoldsEveryLeaderAndHelperIntoOneHoldAheadKey() throws {
        let old = try Self.v76Project()
        var data = try ProjectFile.encode(old)
        // No Hold Ahead key in it: this is what a v76 build wrote.
        #expect(try Self.version(of: data) == 76)
        #expect(!String(decoding: data, as: UTF8.self).contains("holdAhead"))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = 76
        data = try JSONSerialization.data(withJSONObject: obj)

        for migrations in [ProjectFile.migrations, nil] {
            let p = try ProjectFile.decode(data, migrations: migrations)
            let clips = p.allClips(), was = old.allClips()
            let v = try #require(clips.first { $0.kind == .video }), a = try #require(clips.first { $0.kind == .audio })
            let ov = try #require(was.first { $0.kind == .video }), oa = try #require(was.first { $0.kind == .audio })
            Self.expectFolded(v.animation.opacity.track, from: ov.animation.opacity.track, "scalar")
            Self.expectFolded(v.animation.position.track, from: ov.animation.position.track, "Vec2")
            Self.expectFolded(v.masks[0].path.track, from: ov.masks[0].path.track, "mask path")
            Self.expectFolded(v.masks[0].feather.track, from: ov.masks[0].feather.track, "mask feather")
            Self.expectFolded(a.animation.volume.track, from: oa.animation.volume.track, "audio level")
            let x = try #require(a.effects[0].parameters[Self.bandX]), y = try #require(a.effects[0].parameters[Self.bandY])
            Self.expectFolded(x.track, from: try #require(oa.effects[0].parameters[Self.bandX]).track, "pair member X")
            Self.expectFolded(y.track, from: try #require(oa.effects[0].parameters[Self.bandY]).track, "pair member Y")
            // The two members read as one pair row again, with one Hold Ahead key.
            #expect(KeyframesPair.zipped(x, y)?.track.keys.map(\.interpolation) == [.linear, .holdAhead, .linear, .linear])
            // What the clip shows is what it showed, on every frame.
            for i in 0...300 {
                let t = Time(Int64(i), 30)
                #expect(v.animation.opacity.value(atLocal: t) == ov.animation.opacity.value(atLocal: t) && a.volume(at: t) == oa.volume(at: t), "frame \(i)")
                #expect(v.animation.position.value(atLocal: t) == ov.animation.position.value(atLocal: t), "frame \(i)")
                #expect(v.maskShapes(atLocal: t) == ov.maskShapes(atLocal: t), "frame \(i)")
            }
        }
    }

    @Test func aHoldAheadKeyWritesV77AndRoundTrips() throws {
        let p = try ProjectFile.decode(ProjectFile.encode(Self.v76Project()), migrations: nil)
        let data = try ProjectFile.encode(p)
        #expect(try Self.version(of: data) == 77)
        #expect(String(decoding: data, as: UTF8.self).contains("holdAhead"))
        let back = try ProjectFile.decode(data, migrations: nil)
        #expect(back == p)
        #expect(try ProjectFile.encode(back) == data)
        // An older build refuses the file instead of reading the key as something else.
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        #expect(throws: ProjectFileError.self) { try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: nil) }
    }

    @Test func aProjectWithoutAHoldAheadKeepsItsVersion() throws {
        let clip = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        var held = clip
        held.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: s(0), value: 1, interpolation: .hold), Keyframe(time: s(1), value: 0)])
        var ahead = held
        ahead.animation.opacity.track.update(ahead.animation.opacity.track.keys[0].id) { $0.interpolation = .holdAhead }
        func written(_ c: Clip) throws -> Int {
            let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [c])])
            return try Self.version(of: ProjectFile.encode(Project(name: "P", timelines: [tl])))
        }
        #expect(try written(clip) < 76 && written(held) == written(clip))
        #expect(try written(ahead) == 77)
        // One encode does not mark the next.
        #expect(try written(held) == written(clip))
    }

    // MARK: The fold

    private func folded<V: KeyframeValue>(_ t: KeyframeTrack<V>) throws -> KeyframeTrack<V> {
        try JSONDecoder().decode(KeyframeTrack<V>.self, from: JSONEncoder().encode(t))
    }

    @Test func onlyAnUntouchedHelperIsFolded() throws {
        let base = Self.legacy(0.8, 0.2, 0.5)
        let h = base.keys[2].id
        #expect(try folded(base).keys.count == 4)
        // Anything the user could have done to the second key makes it a key of theirs: it stays.
        let edits: [(String, (inout Keyframe<Double>) -> Void)] = [
            ("another value", { $0.value = 0.3 }),
            ("an ease", { $0.outHandle = EaseHandle(dx: 0.5, dy: 0) }),
            ("an in ease", { $0.inHandle = EaseHandle(dx: 0.5, dy: 0) }),
            ("a tangent", { $0.outTangent = Vec2(1, 0) }),
            ("another shape", { $0.interpolation = .linear }),
        ]
        for (name, edit) in edits {
            var t = base
            t.update(h, edit)
            #expect(try folded(t) == t, "\(name)")
        }
        // Further away than one step, a leader that is no Hold, or nothing after it.
        var far = base
        far.move(h, to: s(2) + Time(1, 30))
        #expect(try folded(far) == far)
        var linear = base
        linear.update(base.keys[1].id) { $0.interpolation = .linear }
        #expect(try folded(linear) == linear)
        let tail = KeyframeTrack(keys: Array(base.keys.prefix(3)))
        #expect(try folded(tail) == tail)
        // Folding twice changes nothing, and a plain Hold is left alone.
        let once = try folded(base)
        #expect(try folded(once) == once)
        let plain = KeyframeTrack(keys: [Keyframe(time: s(0), value: 1.0, interpolation: .hold), Keyframe(time: s(1), value: 0.0)])
        #expect(try folded(plain) == plain)
    }

    @Test func leadersInARowAreAllFolded() throws {
        let raw = KeyframeTrack(keys: [
            Keyframe(time: s(1), value: 1.0, interpolation: .hold), Keyframe(time: s(1) + step, value: 2.0, interpolation: .hold),
            Keyframe(time: s(2), value: 2.0, interpolation: .hold), Keyframe(time: s(2) + step, value: 3.0, interpolation: .hold),
            Keyframe(time: s(3), value: 3.0, interpolation: .hold), Keyframe(time: s(4), value: 9.0),
        ])
        let t = try folded(raw)
        #expect(t.keys.map(\.time) == [s(1), s(2), s(3), s(4)])
        #expect(t.keys.map(\.interpolation) == [.holdAhead, .holdAhead, .hold, .linear])
        #expect(t.keys.map(\.value) == [1, 2, 3, 9])
    }

    @Test func presetsAndClipboardsFoldAsWell() throws {
        let preset = EffectPreset(anchor: .stretch, referenceDuration: s(10), opacity: AnimatedProperty(1.0, track: Self.legacy(0.8, 0.2, 0.5)))
        let back = try JSONDecoder().decode(EffectPreset.self, from: JSONEncoder().encode(preset))
        #expect(back.opacity?.track.keys.map(\.interpolation) == [.linear, .holdAhead, .linear, .linear])
    }

    // MARK: Old evaluation against new, at many rational times

    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func unit() -> Double { Double(next() % 10_001) / 10_000 }
    }

    /// A random track in the two-key form (what an old file holds; evaluated as it is, this is the old evaluation: the
    /// helper is a Hold key like any other) and the leaders that have a helper.
    private func randomLegacy<V: KeyframeValue>(_ r: inout Random, value: (inout Random) -> V) -> (track: KeyframeTrack<V>, leaders: [Time]) {
        let scales: [(Int64, Int64)] = [(1, 30), (1, 24), (1001, 30000), (1, 60), (1, 25)]
        let (num, den) = scales[r.int(scales.count)]
        var keys: [Keyframe<V>] = [], frame: Int64 = Int64(r.int(20))
        let count = 2 + r.int(7)
        var shapes: [Interpolation] = []
        for _ in 0..<count {
            let shape: Interpolation = [.linear, .hold, .hold, .bezier][r.int(4)]
            var k = Keyframe(time: Time(frame * num, den), value: value(&r), interpolation: shape)
            if shape == .bezier || r.int(3) == 0 {
                k.outHandle = EaseHandle(dx: r.unit(), dy: r.unit() * 1.4 - 0.2)
                k.inHandle = EaseHandle(dx: r.unit(), dy: r.unit() * 1.4 - 0.2)
            }
            if r.int(4) == 0 { k.outTangent = Vec2(r.unit() * 200 - 100, r.unit() * 200 - 100); k.inTangent = Vec2(r.unit() * 200 - 100, 0) }
            keys.append(k); shapes.append(shape)
            frame += 1 + Int64(r.int(90))
        }
        var all: [Keyframe<V>] = [], leaders: [Time] = []
        for (i, k) in keys.enumerated() {
            all.append(k)
            guard shapes[i] == .hold, i + 1 < keys.count, r.int(3) != 0 else { continue }
            all.append(Keyframe(time: k.time + step, value: keys[i + 1].value, interpolation: .hold))
            leaders.append(k.time)
        }
        return (KeyframeTrack(keys: all), leaders)
    }

    private func expectSameEvaluation<V: KeyframeValue>(seed: UInt64, tracks: Int, value: (inout Random) -> V) throws {
        var r = Random(state: seed)
        var helpers = 0
        for n in 0..<tracks {
            let (old, leaders) = randomLegacy(&r, value: value)
            let new = try folded(old)
            helpers += leaders.count
            #expect(new.keys.count == old.keys.count - leaders.count, "track \(n): every helper folded")
            #expect(new.keys.filter { $0.interpolation == .holdAhead }.map(\.time) == leaders, "track \(n)")
            let end = old.keys[old.keys.count - 1].time + s(1)
            var times: [Time] = []
            for (num, den) in [(Int64(1), Int64(30)), (1, 24), (1, 60), (1001, 30000), (1001, 60000), (1, 25), (1, 50)] {
                var i: Int64 = 0
                while Time(i * num, den) <= end { times.append(Time(i * num, den)); i += 1 }
            }
            for k in old.keys { times += [k.time, k.time - step, k.time + step, k.time + Time(1, 90_000), k.time - Time(1, 48_000)] }
            for den in [Int64(90_000), 48_000, 44_100, 1_000_000, 12_800, 7] {
                for _ in 0..<60 { times.append(Time(Int64(r.int(Int(KeyframeMath.seconds(end) * Double(den)) + 1)), den)) }
            }
            // The one place the forms differ: strictly inside the microsecond between a leader and its old helper
            // (the old form still showed the leader there). No frame or sample time of a real timeline falls into it.
            let checked = times.filter { t in !leaders.contains { $0 < t && t < $0 + step } }
            let off = checked.filter { old.value(at: $0) != new.value(at: $0) }
            #expect(off.isEmpty, "track \(n): \(off.count) of \(checked.count) times differ, first \(String(describing: off.first))")
            // Inside it the new form already shows the next key.
            for l in leaders {
                let inside = l + Time(1, 2_000_000)
                #expect(new.value(at: inside) == old.value(at: l + step), "track \(n)")
            }
        }
        #expect(helpers > tracks / 2, "the generator makes helpers")
    }

    @Test func oldFilesEvaluateTheSameAtEveryTime() throws {
        try expectSameEvaluation(seed: 77, tracks: 120) { Double($0.int(400)) / 4 - 50 }
        try expectSameEvaluation(seed: 1977, tracks: 80) { Vec2(Double($0.int(400)) - 200, Double($0.int(300)) - 150) }
        try expectSameEvaluation(seed: 7_700, tracks: 40) { r in
            let a = Vec2(r.unit() * 0.4, r.unit() * 0.4)
            return MaskPath.rectangle(a, Vec2(a.x + 0.1 + r.unit() * 0.4, a.y + 0.1 + r.unit() * 0.4))
        }
    }
}

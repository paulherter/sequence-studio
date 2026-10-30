import Testing
import Foundation
import SQCore
import SQMedia
import SQAudioFX
import SQPlayback
@testable import SQExport

/// Consolidation step 4: offline render of both paths. Live ducking on a Music track and the same duck baked into keys (track
/// excluded, live setting still on) sound the same; keys on a track live ducking still ducks would duck twice (not allowed).
@Suite struct BakeLiveDuckParityTests {
    private static let n = 10 * 48_000
    private static let setting = ProjectLiveDucking(isOn: true, amountDB: 12)
    private static let live = LiveDucking(amountDB: 12, fade: Time(3, 10))

    private static func fixture() -> (Timeline, dialogue: UUID, music: UUID) {
        let d = UUID(), m = UUID()
        let len = TimeRange(start: .zero, duration: Time(10, 1))
        var dt = Track(kind: .audio, clips: [Clip(name: "d", media: d, kind: .audio, source: TimeRange(start: .zero, duration: Time(3, 1)),
                                                   start: Time(3, 1))])
        dt.audioRole = .dialogue
        var mt = Track(kind: .audio, clips: [Clip(name: "m", media: m, kind: .audio, source: len, start: .zero)])
        mt.audioRole = .music
        return (Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [dt, mt]), d, m)
    }

    private static let music = MemoryAudioSource(mono: (0..<n).map { Float(0.4 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) })
    private static let quiet = MemoryAudioSource(mono: [Float](repeating: 0, count: n))

    private static func render(_ t: Timeline, d: UUID, m: UUID) async throws -> [Float] {
        let src = TimelineAudioSource(timeline: t, range: TimeRange(start: .zero, duration: Time(10, 1)), liveDucking: setting,
                                      resolver: StaticMediaResolver(audio: [d: quiet, m: music]))
        var l: [Float] = []
        while let chunk = try await src.nextChunk(maxFrames: 3_000) {
            for i in stride(from: 0, to: chunk.samples.count, by: 2) { l.append(chunk.samples[i]) }
        }
        return l
    }

    private static func peak(_ x: [Float], _ fromS: Double, _ toS: Double) -> Float {
        x[Int(fromS * 48_000)..<Int(toS * 48_000)].reduce(0) { max($0, abs($1)) }
    }

    @Test func bakedKeysSoundLikeLiveDucking() async throws {
        let (t, d, m) = Self.fixture()
        let liveOut = try await Self.render(t, d: d, m: m)
        var baked = t
        #expect(Self.live.bake(into: &baked) > 0)
        #expect(LiveDucking.duckedClipIDs(in: baked).isEmpty)                    // live no longer acts on the baked track
        let bakedOut = try await Self.render(baked, d: d, m: m)
        #expect(liveOut.count == Self.n && bakedOut.count == Self.n)
        #expect(Self.peak(liveOut, 4, 5) < Self.peak(liveOut, 0, 1) * 0.3)         // it really ducks under the dialogue
        #expect(zip(liveOut, bakedOut).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) } < 2e-3)
    }

    /// Offline render (left channel) with a custom media map; `setting` nil = live ducking off (the project setting off, so
    /// Preferences cannot turn it on).
    private static func render(_ t: Timeline, sequences: [Timeline.ID: Timeline] = [:], audio: [UUID: MemoryAudioSource],
                               setting: ProjectLiveDucking? = Self.setting) async throws -> [Float] {
        let src = TimelineAudioSource(timeline: t, sequences: sequences, range: TimeRange(start: .zero, duration: Time(10, 1)),
                                      liveDucking: setting ?? ProjectLiveDucking(isOn: false),
                                      resolver: StaticMediaResolver(audio: audio))
        var l: [Float] = []
        while let chunk = try await src.nextChunk(maxFrames: 3_000) {
            for i in stride(from: 0, to: chunk.samples.count, by: 2) { l.append(chunk.samples[i]) }
        }
        return l
    }

    private static func maxDiff(_ a: [Float], _ b: [Float], _ fromS: Double = 0, _ toS: Double = 10) -> Float {
        let r = Int(fromS * 48_000)..<Int(toS * 48_000)
        return zip(a[r], b[r]).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
    }

    private static let duckDepth = Float(pow(10, -12.0 / 20))

    /// Audit C18: clip tags on tracks without a role duck like the track roles (one role = tag ?? track role), live and baked
    /// alike; an untagged clip on a track without a role is left alone.
    @Test func clipTagsDuckLikeTrackRoles() async throws {
        let (roles, d, m) = Self.fixture()
        var tags = roles
        for tr in roles.tracks {
            for var c in tr.clips { c.audioTag = tr.audioRole; try tags.replaceClip(c) }
        }
        for i in tags.tracks.indices { tags.tracks[i].audioRole = nil }
        let loose = UUID()
        tags.tracks.append(Track(kind: .audio, clips: [Clip(name: "x", media: loose, kind: .audio,
                                                            source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)]))
        // Not sample-equal to the role render: a track role also runs its voiced track preset (Voice Chain, track-level), a
        // tag does not. The duck depth is the same: 12 dB under the dialogue.
        let tagsOut = try await Self.render(tags, audio: [d: Self.quiet, m: Self.music, loose: Self.quiet])
        #expect(abs(Self.peak(tagsOut, 4, 5) / Self.peak(tagsOut, 0, 1) - Self.duckDepth) < 0.01)
        // The untagged clip alone (music source on it, the tagged bed silent): not ducked at all.
        let looseOn = try await Self.render(tags, audio: [d: Self.quiet, m: Self.quiet, loose: Self.music])
        let looseOff = try await Self.render(tags, audio: [d: Self.quiet, m: Self.quiet, loose: Self.music], setting: nil)
        #expect(Self.maxDiff(looseOn, looseOff) == 0)
        var baked = tags
        #expect(Self.live.bake(into: &baked) > 0)
        #expect(LiveDucking.duckedClipIDs(in: baked).isEmpty)                    // keyed: live leaves it (its track has no role)
        #expect(baked.tracks.allSatisfy { !$0.isExcludedFromLiveDucking })       // no Music-role track to exclude
        let bakedOut = try await Self.render(baked, audio: [d: Self.quiet, m: Self.music, loose: Self.quiet])
        #expect(Self.maxDiff(tagsOut, bakedOut) < 2e-3)
    }

    /// Review finding 1: an old project (before C18) with a Music-tagged clip on a track without role Music, keyed by Auto
    /// Duck, was never live-ducked. It must render exactly as before: identical with live ducking on and off.
    @Test func oldProjectTaggedClipWithAutoDuckKeysIsNotDuckedTwice() async throws {
        let (roles, d, m) = Self.fixture()
        var old = roles
        old.tracks[1].audioRole = nil
        var bed = old.tracks[1].clips[0]
        bed.audioTag = .music
        bed.applyDucking(dialogue: LiveDucking.dialogueRanges(in: old), amountDB: 12, fade: Time(3, 10))
        try old.replaceClip(bed)
        #expect(LiveDucking.duckedClipIDs(in: old).isEmpty && LiveDucking.clipsDuckingTwice(in: old).isEmpty)
        let on = try await Self.render(old, audio: [d: Self.quiet, m: Self.music])
        let off = try await Self.render(old, audio: [d: Self.quiet, m: Self.music], setting: nil)
        #expect(Self.maxDiff(on, off) == 0)
        #expect(Self.peak(on, 4, 5) > Self.peak(on, 0, 1) * 0.2)                   // keys alone: 12 dB, not 24
    }

    /// One Music track, two clips: untagged (inherits Music, ducked) and SFX-tagged (not ducked), through the mixer.
    @Test func mixedRolesOnOneTrackDuckPerClip() async throws {
        let d = UUID(), a = UUID(), b = UUID()
        var dt = Track(kind: .audio, clips: [Clip(name: "d", media: d, kind: .audio, source: TimeRange(start: .zero, duration: Time(6, 1)),
                                                   start: Time(2, 1))])
        dt.audioRole = .dialogue
        var sfx = Clip(name: "s", media: b, kind: .audio, source: TimeRange(start: .zero, duration: Time(5, 1)), start: Time(5, 1))
        sfx.audioTag = .sfx
        var mt = Track(kind: .audio, clips: [Clip(name: "m", media: a, kind: .audio, source: TimeRange(start: .zero, duration: Time(5, 1)),
                                                   start: .zero), sfx])
        mt.audioRole = .music
        let t = Timeline(name: "t", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [dt, mt])
        let audio = [d: Self.quiet, a: Self.music, b: Self.music]
        let on = try await Self.render(t, audio: audio), off = try await Self.render(t, audio: audio, setting: nil)
        #expect(Self.peak(on, 3, 4.5) < Self.peak(off, 3, 4.5) * 0.7)              // untagged on the Music track: ducked (the voiced Music preset compresses part of the 12 dB back)
        #expect(Self.maxDiff(on, off, 6, 7.5) < 1e-6)                              // SFX-tagged on the Music track: untouched
    }

    /// A nested sequence clip tagged Music on a track without a role is ducked whole (the top-level clip's role decides).
    @Test func nestedClipTaggedMusicIsDucked() async throws {
        let d = UUID(), m = UUID()
        let fmt = SequenceFormat(frameDuration: Time(1, 30))
        let inner = Timeline(name: "inner", format: fmt, tracks: [
            Track(kind: .audio, clips: [Clip(name: "m", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)])])
        var nest = Clip(name: "n", media: inner.id, kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)),
                        start: .zero, sequence: inner.id)
        nest.audioTag = .music
        var dt = Track(kind: .audio, clips: [Clip(name: "d", media: d, kind: .audio, source: TimeRange(start: .zero, duration: Time(3, 1)),
                                                   start: Time(3, 1))])
        dt.audioRole = .dialogue
        let t = Timeline(name: "t", format: fmt, tracks: [dt, Track(kind: .audio, clips: [nest])])
        let seqs = [inner.id: inner]
        let on = try await Self.render(t, sequences: seqs, audio: [d: Self.quiet, m: Self.music])
        let off = try await Self.render(t, sequences: seqs, audio: [d: Self.quiet, m: Self.music], setting: nil)
        #expect(abs(Self.peak(on, 4, 5) / Self.peak(off, 4, 5) - Self.duckDepth) < 0.01)
        #expect(Self.maxDiff(on, off, 0, 2) < 1e-6)
    }

    @Test func keysOnATrackLiveDucksStillDuckTwice() async throws {
        let (t, d, m) = Self.fixture()
        let liveOut = try await Self.render(t, d: d, m: m)
        var both = t
        var c = both.tracks[1].clips[0]
        c.applyDucking(dialogue: LiveDucking.dialogueRanges(in: t), amountDB: 12, fade: Time(3, 10))
        try both.replaceClip(c)
        #expect(LiveDucking.clipsDuckingTwice(in: both) == [c.id])                 // what the UI warns about
        let bothOut = try await Self.render(both, d: d, m: m)
        #expect(Self.peak(bothOut, 4, 5) < Self.peak(liveOut, 4, 5) * 0.4)         // about 24 dB instead of 12
    }
}

import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

/// The feeder's per-timeline duck index (built in `setTimeline`) mixes bit for bit what the per-block walk mixed, and a
/// timeline change (edit, undo, mute, solo, role) reaches it. Nothing is played out loud: blocks are only pulled from the ring.
@Suite struct AudioFeederDuckIndexTests {
    static let rate: Int64 = 48_000
    static let fmt = SequenceFormat(frameDuration: Time(1, 30))
    static let musicMedia = UUID(), voiceMedia = UUID()

    struct Pauses: DialogueSilenceProvider {
        func silences(of clip: Clip, trackVolumeDB: Double) -> [TimeRange]? {
            [TimeRange(start: clip.start + Time(1, 5), duration: Time(1, 10))]
        }
    }

    static func clip(_ media: UUID, start: Time, length: Time, tag: AudioTag? = nil) -> Clip {
        var c = Clip(name: "c", media: media, kind: .audio, source: TimeRange(start: .zero, duration: length), start: start)
        c.audioTag = tag
        return c
    }

    /// Music track 0..2 s, a second music track, two dialogue tracks with short clips and gaps, an untagged track with a
    /// dialogue-tagged clip.
    static func timeline(secondDialogueAt d2Start: Int64 = 1500) -> Timeline {
        let ms = { (v: Int64) in Time(v, 1000) }
        var music = Track(kind: .audio, clips: [clip(musicMedia, start: .zero, length: Time(2, 1))]); music.audioRole = .music
        var music2 = Track(kind: .audio, clips: [clip(musicMedia, start: ms(300), length: ms(1500))]); music2.audioRole = .music
        var d1 = Track(kind: .audio, clips: [clip(voiceMedia, start: ms(200), length: ms(350)),
                                             clip(voiceMedia, start: ms(900), length: ms(500))]); d1.audioRole = .dialogue
        var d2 = Track(kind: .audio, clips: [clip(voiceMedia, start: ms(d2Start), length: ms(250))]); d2.audioRole = .dialogue
        let loose = Track(kind: .audio, clips: [clip(musicMedia, start: ms(50), length: ms(400), tag: .music),
                                                clip(voiceMedia, start: ms(1700), length: ms(200), tag: .dialogue)])
        return Timeline(name: "t", format: fmt, tracks: [music, music2, d1, d2, loose])
    }

    static func feeder(_ t: Timeline, duck: LiveDucking, pauses: Bool, index: Bool) -> AudioFeeder {
        let n = 3 * Int(rate)
        let music = MemoryAudioSource(mono: (0..<n).map { Float(sin(Double($0) * 0.031)) * 0.4 })
        let voice = MemoryAudioSource(mono: (0..<n).map { Float(sin(Double($0) * 0.0071)) * 0.2 })
        let f = AudioFeeder(timeline: t, ring: RingBuffer(capacity: 1 << 14), blockFrames: 1024) { $0 == musicMedia ? music : voice }
        f.liveDucking = duck
        if pauses { f.dialogueSilences = Pauses() }
        f.usesDuckIndex = index
        return f
    }

    /// Pulls `frames` frames from `startFrame` (forward or reverse) out of the ring.
    static func render(_ f: AudioFeeder, from startFrame: Int64 = 0, frames: Int = 2 * 48_000 + 512, reverse: Bool = false) -> [Float] {
        f.seek(to: startFrame, reverse: reverse)
        var out: [Float] = []
        out.reserveCapacity(frames * 2)
        var l = [Float](repeating: 0, count: 4096), r = l
        while out.count < frames * 2 {
            let pushed = f.fill(maxBlocks: 4)
            let got = l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in
                f.ring.pop(left: a.baseAddress!, right: b.baseAddress!, count: 4096) } }
            if got == 0 && pushed == 0 { break }
            for i in 0..<got { out.append(l[i]); out.append(r[i]) }
        }
        return out
    }

    @Test func indexedMixIsBitIdenticalToTheWalk() {
        let t = Self.timeline()
        for timing in [DuckTiming.classic, .speech, .resolve] {
            for pauses in [false, true] {
                let d = LiveDucking(amountDB: 12, timing: timing)
                let a = Self.render(Self.feeder(t, duck: d, pauses: pauses, index: true))
                let b = Self.render(Self.feeder(t, duck: d, pauses: pauses, index: false))
                #expect(a.count > 100_000)
                #expect(a == b, "timing \(timing), pauses \(pauses)")
                let plain = Self.render(Self.feeder(t, duck: LiveDucking(amountDB: 0), pauses: pauses, index: true))
                #expect(a != plain)                              // the duck acted
            }
        }
        let d = LiveDucking(amountDB: 12, timing: .speech)
        #expect(Self.render(Self.feeder(t, duck: d, pauses: true, index: true), from: 96_000, reverse: true)
                == Self.render(Self.feeder(t, duck: d, pauses: true, index: false), from: 96_000, reverse: true))
    }

    /// A music nest with effects (its own nest pass inside the outer block, each with its own duck buffer) under live ducking:
    /// the indexed mix equals the walk and the duck acts on the nest.
    @Test func effectedNestUnderDuckingMatchesTheWalk() {
        var innerMusic = Self.clip(Self.musicMedia, start: .zero, length: Time(2, 1))
        innerMusic.audioTag = nil
        let inner = Timeline(name: "inner", format: Self.fmt, tracks: [Track(kind: .audio, clips: [innerMusic])])
        var nest = Clip(name: "n", media: inner.id, kind: .audio, source: TimeRange(start: .zero, duration: Time(2, 1)),
                        start: .zero, sequence: inner.id)
        if let id = nest.addEffect(kind: ClipEffect.audioLimiterKind) { nest.setParameter(id, ClipEffect.limiterCeilingKey, to: -1) }
        #expect(!nest.effects.isEmpty)
        var music = Track(kind: .audio, clips: [nest]); music.audioRole = .music
        var dlg = Track(kind: .audio, clips: [Self.clip(Self.voiceMedia, start: Time(1, 5), length: Time(1, 2))]); dlg.audioRole = .dialogue
        let t = Timeline(name: "t", format: Self.fmt, tracks: [music, dlg])
        func run(_ duck: LiveDucking, index: Bool) -> [Float] {
            let f = Self.feeder(t, duck: duck, pauses: true, index: index)
            f.setTimeline(t, sequences: [inner.id: inner])
            return Self.render(f)
        }
        for timing in [DuckTiming.classic, .speech] {
            let d = LiveDucking(amountDB: 12, timing: timing)
            let a = run(d, index: true)
            #expect(a.count > 100_000)
            #expect(a == run(d, index: false), "timing \(timing)")
            #expect(a != run(LiveDucking(amountDB: 0), index: true))
        }
    }

    /// Edit, mute, solo, role and tag changes and undo all go through `setTimeline`: the mix then equals a fresh feeder of
    /// the new timeline (walk path), and the change is heard.
    @Test func setTimelineRebuildsTheIndex() {
        let base = Self.timeline()
        let d = LiveDucking(amountDB: 12, timing: .speech)
        let live = Self.feeder(base, duck: d, pauses: true, index: true)
        let before = Self.render(live)
        var changes: [(String, Timeline)] = []
        var muted = base; muted.tracks[2].isMuted = true; changes.append(("mute dialogue", muted))
        var solo = base; solo.tracks[0].isSolo = true; changes.append(("solo music", solo))
        var role = base; role.tracks[2].audioRole = .music; changes.append(("track role", role))
        var excluded = base; excluded.tracks[1].isExcludedFromLiveDucking = true; changes.append(("opt out", excluded))
        var moved = Self.timeline(secondDialogueAt: 100)              // same tracks, one dialogue clip elsewhere
        for i in moved.tracks.indices { moved.tracks[i].id = base.tracks[i].id }
        changes.append(("move dialogue clip", moved))
        var tagged = base
        var m = tagged.tracks[4].clips.first { $0.audioTag == .music }!; m.audioTag = .sfx; try? tagged.replaceClip(m)
        #expect(tagged.tracks[4].clips.first { $0.id == m.id }?.audioTag == .sfx)
        #expect(LiveDuckingIndex(base).ducks(clip: m.id) && !LiveDuckingIndex(tagged).ducks(clip: m.id))
        changes.append(("clip tag", tagged))
        for (name, t) in changes {
            live.setTimeline(t)
            let now = Self.render(live)
            #expect(now == Self.render(Self.feeder(t, duck: d, pauses: true, index: false)), "\(name)")
            #expect(now != before, "\(name) must be heard")
        }
        live.setTimeline(base)                                     // undo: the earlier snapshot again
        #expect(Self.render(live) == before)
    }
}

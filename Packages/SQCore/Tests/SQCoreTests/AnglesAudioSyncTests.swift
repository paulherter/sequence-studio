import Foundation
import Testing
@testable import SQCore

/// Deterministic "speech-like" envelope: bursts of varying length and level (no audio is played or decoded).
private func envelope(_ count: Int, seed: UInt64) -> [Float] {
    var state = seed
    func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    var out: [Float] = []
    while out.count < count {
        let level = Float(next() % 1000) / 1000
        let length = Int(next() % 40) + 5
        for k in 0..<length { out.append(level * (0.6 + 0.4 * Float((k * 7) % 5) / 5)) }
    }
    return Array(out.prefix(count))
}

@Suite struct AnglesAudioSyncTests {
    @Test func findsALaterStart() throws {
        let scene = envelope(3000, seed: 1)
        // The second camera started 437 steps later and recorded quieter, with its own noise floor.
        let other = scene[437..<2600].enumerated().map { $0.element * 0.4 + 0.05 + Float($0.offset % 3) * 0.01 }
        let m = try #require(AnglesAudioSync.match(reference: scene, other: other))
        #expect(m.lag == 437)
        #expect(m.confidence > 0.9)
    }

    @Test func findsAnEarlierStart() throws {
        let scene = envelope(3000, seed: 2)
        let reference = Array(scene[600...])
        let m = try #require(AnglesAudioSync.match(reference: reference, other: Array(scene[..<2000])))
        #expect(m.lag == -600)
    }

    @Test func coarseSearchIsRefinedToTheExactStep() throws {
        let scene = envelope(20_000, seed: 3)
        let other = Array(scene[3333..<18_000])
        // Forced thinning (factor 8) must still land on the exact lag.
        let m = try #require(AnglesAudioSync.match(reference: scene, other: other, coarseLimit: 2500))
        #expect(m.lag == 3333)
        #expect(m.confidence > 0.99)
    }

    @Test func unrelatedSoundIsWeak() {
        let m = AnglesAudioSync.match(reference: envelope(3000, seed: 4), other: envelope(3000, seed: 99))
        #expect((m?.confidence ?? 0) < AnglesAudioSync.weakConfidence)
    }

    @Test func silenceAndShortInputGiveNothing() {
        #expect(AnglesAudioSync.match(reference: [Float](repeating: 0, count: 500), other: envelope(500, seed: 5)) == nil)
        #expect(AnglesAudioSync.match(reference: envelope(8, seed: 6), other: envelope(500, seed: 6)) == nil)
    }

    @Test func originsOnlyForAnglesThatReallyMatch() {
        let scene = envelope(3000, seed: 1)
        let later = Array(scene[437..<2600])
        let found = AnglesAudioSync.origins(envelopes: [(id: "ref", envelope: scene), (id: "later", envelope: later),
                                                        (id: "other", envelope: envelope(3000, seed: 8)),
                                                        (id: "silent", envelope: [Float](repeating: 0, count: 3000))], rate: 100)
        // A weak or missing match gets no origin: such an angle is lined up by its In point.
        #expect(found.origins == ["ref": .zero, "later": Time(437, 100)])
        #expect(found.unmatched == 2)
        // One readable sound alone places nothing.
        let alone = AnglesAudioSync.origins(envelopes: [(id: "ref", envelope: scene)], rate: 100)
        #expect(alone.origins.isEmpty && alone.unmatched == 0)
    }

    @Test func reportSaysWhichAnglesCouldNotBeSynced() {
        let scene = envelope(3000, seed: 1)
        let r = AnglesAudioSync.report(envelopes: [(id: "ref", envelope: scene), (id: "later", envelope: Array(scene[437..<2600])),
                                                   (id: "other", envelope: envelope(3000, seed: 8)),
                                                   (id: "silent", envelope: [Float](repeating: 0, count: 3000))], rate: 100)
        #expect(r.outcomes["ref"] == .reference)
        guard case .synced(let c)? = r.outcomes["later"] else { Issue.record("later not synced"); return }
        #expect(c > 0.9)
        guard case .notSynced(let weak)? = r.outcomes["other"] else { Issue.record("other synced"); return }
        #expect((weak ?? 0) < AnglesAudioSync.weakConfidence)
        #expect(r.outcomes["silent"] == .notSynced(confidence: nil))
        #expect(r.origins == ["ref": .zero, "later": Time(437, 100)])
        #expect(r.failed == ["other", "silent"])
    }

    @Test func noteNamesFailuresWithConfidence() {
        let note = AnglesAudioSync.note(failed: [(name: "B.mov", confidence: 0.12), (name: "C.mov", confidence: nil)],
                                        synced: [0.93, 0.71], silent: 1, unreadable: 0)
        #expect(note == "Could not sync by sound: B.mov (confidence 12 %), C.mov (no match). 1 without sound. Those are lined up by In point. Synced 2 by sound, weakest 71 %.")
        #expect(AnglesAudioSync.note(failed: [], synced: [0.9], silent: 0, unreadable: 0) == "Synced 1 by sound, weakest 90 %.")
        #expect(AnglesAudioSync.note(failed: [], synced: [], silent: 0, unreadable: 0) == nil)
        #expect(AnglesAudioSync.note(failed: [], synced: [], silent: 0, unreadable: 2)
                == "Could not sync by sound: 2 files whose sound could not be read. Those are lined up by In point.")
    }

    @Test func lagAsTime() {
        #expect(AnglesAudioSync.time(lag: 437, rate: 100) == Time(437, 100))
        #expect(AnglesAudioSync.time(lag: -50, rate: 100) == Time(-1, 2))
    }
}

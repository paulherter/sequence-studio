import Foundation
import Testing
import SQCore
@testable import SQAnalysis

@Suite struct BeatDetectorTests {
    private let rate = 44100

    /// Decaying click train; every 4th click from `accentPhase` is louder and lower.
    private func clicks(bpm: Double, seconds: Double, offset: Double, accentPhase: Int = 0) -> (samples: [Float], times: [Double]) {
        var s = [Float](repeating: 0, count: Int(seconds * Double(rate)))
        var times: [Double] = []
        let period = 60 / bpm
        var k = 0
        while true {
            let t = offset + Double(k) * period
            let start = Int(t * Double(rate))
            if start + 2000 >= s.count { break }
            let accent = k % 4 == accentPhase
            let freq = 1800.0, amp: Float = accent ? 0.9 : 0.4
            for i in 0..<1500 {
                let env = Float(exp(-Double(i) / 250))
                s[start + i] += amp * env * Float(sin(2 * .pi * freq * Double(i) / Double(rate)))
            }
            times.append(t); k += 1
        }
        return (s, times)
    }

    private func seconds(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

    @Test func findsTempoBeatsAndDownbeats() throws {
        let (samples, truth) = clicks(bpm: 120, seconds: 20, offset: 0.3)
        let grid = try #require(BeatDetector.analyze(samples: samples, sampleRate: rate))
        #expect(abs(grid.bpm - 120) < 1.5)
        let got = grid.beats.map(seconds)
        let hit = truth.filter { t in got.contains { abs($0 - t) < 0.03 } }.count
        #expect(Double(hit) / Double(truth.count) > 0.9)
        let downs = grid.downbeats.map(seconds)
        let accented = truth.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        let good = downs.filter { d in accented.contains { abs($0 - d) < 0.04 } }.count
        #expect(downs.count >= 4)
        #expect(Double(good) / Double(downs.count) > 0.9)
    }

    @Test func downbeatPhaseFollowsTheAccent() throws {
        let (samples, truth) = clicks(bpm: 100, seconds: 24, offset: 0.1, accentPhase: 2)
        let grid = try #require(BeatDetector.analyze(samples: samples, sampleRate: rate))
        #expect(abs(grid.bpm - 100) < 1.5)
        let accented = truth.enumerated().filter { $0.offset % 4 == 2 }.map(\.element)
        let downs = grid.downbeats.map(seconds)
        let good = downs.filter { d in accented.contains { abs($0 - d) < 0.04 } }.count
        #expect(downs.count >= 4)
        #expect(Double(good) / Double(downs.count) > 0.9)
    }

    @Test func beatsAscendAndTempoIsClose() throws {
        let (samples, _) = clicks(bpm: 128, seconds: 15, offset: 0)
        let grid = try #require(BeatDetector.analyze(samples: samples, sampleRate: rate))
        #expect(zip(grid.beats, grid.beats.dropFirst()).allSatisfy { $0 < $1 })
        #expect(abs(grid.bpm - 128) < 2)
    }

    @Test func silenceAndTooShortGiveNoGrid() {
        #expect(BeatDetector.analyze(samples: [Float](repeating: 0, count: rate * 10), sampleRate: rate) == nil)
        #expect(BeatDetector.analyze(samples: [Float](repeating: 0.1, count: rate), sampleRate: rate) == nil)
    }
}

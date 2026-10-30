import Testing
import Foundation
@testable import SQAudioFX

/// Channel identification file: every speaker carries its own frequency, so a wrong order or a lost channel shows in
/// which tones come out on which side.
@Suite struct SurroundFoldDownTests {
    static let rate = 48_000.0, frames = 4800
    // Speaker frequencies (whole periods in 0.1 s).
    static let hz: [String: Double] = ["L": 500, "R": 300, "C": 400, "LFE": 60, "Ls": 700, "Rs": 800]

    static func tone(_ f: Double) -> [Float] {
        (0..<frames).map { Float(sin(2 * Double.pi * f * Double($0) / rate)) }
    }
    static func amplitude(_ x: [Float], _ f: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() {
            let p = 2 * Double.pi * f * Double(i) / rate
            re += Double(v) * cos(p); im += Double(v) * sin(p)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(x.count)
    }
    static func names(_ order: SurroundFoldDown.ChannelOrder) -> [String] {
        switch order {
        case .smpte: return ["L", "R", "C", "LFE", "Ls", "Rs"]
        case .aac: return ["C", "L", "R", "Ls", "Rs", "LFE"]
        case .film: return ["L", "C", "R", "Ls", "Rs", "LFE"]
        }
    }
    /// Interleaved 6-channel file whose channel order is `file`, folded as if it were `read`.
    static func fold(file: SurroundFoldDown.ChannelOrder, read: SurroundFoldDown.ChannelOrder) -> (l: [Float], r: [Float]) {
        let tones = names(file).map { tone(hz[$0]!) }
        var inter = [Float](repeating: 0, count: frames * 6)
        for i in 0..<frames { for c in 0..<6 { inter[i * 6 + c] = tones[c][i] } }
        let out = SurroundFoldDown.fold(interleaved: inter, order: read)!
        return ((0..<frames).map { out[$0 * 2] }, (0..<frames).map { out[$0 * 2 + 1] })
    }

    @Test(arguments: SurroundFoldDown.ChannelOrder.allCases)
    func everyChannelLandsOnTheRightSide(order: SurroundFoldDown.ChannelOrder) {
        let (l, r) = Self.fold(file: order, read: order)
        let k = Double(SurroundFoldDown.centerGain)
        #expect(abs(Self.amplitude(l, 500) - 1) < 0.01)
        #expect(abs(Self.amplitude(l, 400) - k) < 0.01)
        #expect(abs(Self.amplitude(l, 700) - k) < 0.01)
        #expect(Self.amplitude(l, 300) < 0.01 && Self.amplitude(l, 800) < 0.01)
        #expect(abs(Self.amplitude(r, 300) - 1) < 0.01)
        #expect(abs(Self.amplitude(r, 400) - k) < 0.01)
        #expect(abs(Self.amplitude(r, 800) - k) < 0.01)
        #expect(Self.amplitude(r, 500) < 0.01 && Self.amplitude(r, 700) < 0.01)
        #expect(Self.amplitude(l, 60) < 0.01 && Self.amplitude(r, 60) < 0.01)     // LFE dropped
    }

    @Test func readingAacOrderAsSmpteMovesSpeakers() {
        // Premise of #733: the orders are not interchangeable, so the order has to be declared.
        let (l, _) = Self.fold(file: .aac, read: .smpte)
        #expect(Self.amplitude(l, 500) < 0.01)
    }

    @Test func planarMatchesInterleaved() {
        let tones = Self.names(.aac).map { Self.tone(Self.hz[$0]!) }
        var l = [Float](repeating: 0, count: Self.frames), r = l
        let ok = tones[0].withUnsafeBufferPointer { a in tones[1].withUnsafeBufferPointer { b in
            tones[2].withUnsafeBufferPointer { c in tones[3].withUnsafeBufferPointer { d in
            tones[4].withUnsafeBufferPointer { e in tones[5].withUnsafeBufferPointer { f in
                SurroundFoldDown.fold(channels: [a.baseAddress!, b.baseAddress!, c.baseAddress!, d.baseAddress!,
                                                 e.baseAddress!, f.baseAddress!],
                                      order: .aac, frames: Self.frames, left: &l, right: &r)
            } } } } } }
        #expect(ok)
        let ref = Self.fold(file: .aac, read: .aac)
        #expect(l == ref.l && r == ref.r)
    }

    @Test func normalizingKeepsFullScaleInsideAndLfeIsSilent() {
        let ones = [Float](repeating: 1, count: 6 * 4)
        let hot = SurroundFoldDown.fold(interleaved: ones)!
        #expect(abs(hot[0] - (1 + 2 * SurroundFoldDown.centerGain)) < 1e-5)
        let safe = SurroundFoldDown.fold(interleaved: ones, normalized: true)!
        #expect(abs(safe[0] - 1) < 1e-5 && abs(safe[1] - 1) < 1e-5)
        #expect(SurroundFoldDown.fold(interleaved: [0, 0, 0]) == nil)
        var lfeOnly = [Float](repeating: 0, count: 6); lfeOnly[3] = 1
        #expect(SurroundFoldDown.fold(interleaved: lfeOnly) == [0, 0])
    }

    @Test func refusesWrongChannelCount() {
        var l: [Float] = [0], r: [Float] = [0]
        let x: [Float] = [1]
        let ok = x.withUnsafeBufferPointer { p in
            SurroundFoldDown.fold(channels: [p.baseAddress!, p.baseAddress!], frames: 1, left: &l, right: &r)
        }
        #expect(!ok)
    }
}

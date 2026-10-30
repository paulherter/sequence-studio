import Foundation
import Testing
import SQCore
@testable import SQAudioFX

private func run(_ kind: String, _ stage: AudioFXStage, _ x: [[Float]], enabled: Bool = true) throws -> [[Float]] {
    let s = AudioFXSlot(id: UUID(), kind: kind)
    let chain = try ClipAudioFXChain(layout: [s], channelCount: x.count, maxFrames: 480)
    var out: [[[Float]]] = []
    for part in Sig.chunked(x, sizes: [480]) {
        var b = part
        chain.process(&b, steps: [AudioFXStep(id: s.id, enabled: enabled, stage: stage)])
        out.append(b)
    }
    return Sig.concat(out, channels: x.count)
}
/// Gain in dB of the steady part (after 0.5 s) relative to the input.
private func gainDB(_ y: [Float], _ x: [Float]) -> Double { Sig.db(Sig.rms(y[24000...]) / Sig.rms(x[24000...])) }

@Suite struct RepairStagesTests {
    @Test func deHumRemovesHumAndHarmonicsAndLeavesSpeechBand() throws {
        let hum = ClipEffect.audioDeHumKind
        let stage = AudioFXStage.deHum(frequencyHz: 50, q: 10, gainDB: -30, harmonics: 4, slope: 0.5, listen: false)
        for f in [50.0, 100, 150, 200] {
            let x = Sig.sine(freq: f, amplitudeDB: -20, seconds: 1)
            let g = gainDB(try run(hum, stage, x)[0], x[0])
            #expect(g < -25, "hum \(f) Hz only \(g) dB down")
        }
        for f in [500.0, 1000, 4000] {
            let x = Sig.sine(freq: f, amplitudeDB: -20, seconds: 1)
            let g = gainDB(try run(hum, stage, x)[0], x[0])
            #expect(abs(g) < 0.7, "\(f) Hz: \(g) dB")
        }
    }
    @Test func deHumSlopeZeroTouchesOnlyTheRoot() throws {
        let stage = AudioFXStage.deHum(frequencyHz: 50, q: 10, gainDB: -30, harmonics: 4, slope: 0, listen: false)
        let x100 = Sig.sine(freq: 200, amplitudeDB: -20, seconds: 1)     // slope 0: the last of 4 harmonics gets no cut
        let g100 = gainDB(try run(ClipEffect.audioDeHumKind, stage, x100)[0], x100[0])
        #expect(abs(g100) < 1.5, "\(g100)")
        let x50 = Sig.sine(freq: 50, amplitudeDB: -20, seconds: 1)
        #expect(gainDB(try run(ClipEffect.audioDeHumKind, stage, x50)[0], x50[0]) < -25)
    }
    @Test func deHumListenKeepsOnlyTheHum() throws {
        let stage = AudioFXStage.deHum(frequencyHz: 60, q: 10, gainDB: -40, harmonics: 2, slope: 0.5, listen: true)
        let hum = Sig.sine(freq: 60, amplitudeDB: -20, seconds: 1), voice = Sig.sine(freq: 1000, amplitudeDB: -20, seconds: 1)
        #expect(abs(gainDB(try run(ClipEffect.audioDeHumKind, stage, hum)[0], hum[0])) < 0.5)
        let gv = gainDB(try run(ClipEffect.audioDeHumKind, stage, voice)[0], voice[0])
        #expect(gv < -12, "\(gv)")      // what is left of a 1 kHz tone is the notches' phase shift only
    }
    @Test func lowCutSlopes() throws {
        func g(_ f: Double, order: Int) throws -> Double {
            let x = Sig.sine(freq: f, amplitudeDB: -20, seconds: 1)
            return gainDB(try run(ClipEffect.audioLowCutKind, .lowCut(frequencyHz: 100, order: order), x)[0], x[0])
        }
        #expect(abs(try g(100, order: 2) + 3) < 0.7)           // Butterworth: -3 dB at the corner
        #expect(abs(try g(2000, order: 2)) < 0.1)
        let o1 = try g(25, order: 1), o2 = try g(25, order: 2), o3 = try g(25, order: 3)
        #expect(o1 < -10 && o2 < o1 - 8 && o3 < o2 - 15, "\(o1) \(o2) \(o3)")   // 2 octaves down: ~-12, -24, -48 dB
    }
    @Test func levelerEvensLoudAndSoftWithinRange() throws {
        let soft = Sig.mono(300, amplitudeDB: -36, seconds: 3), loud = Sig.mono(300, amplitudeDB: -12, seconds: 3)
        let x = [soft + loud, soft + loud]
        let v = AudioLevelerValues(preset: 3, reduceLoud: true, liftSoft: true, background: false, outputGainDB: 0)
        let y = try run(ClipEffect.audioDialogueLevelerKind, .dialogueLeveler(v), x)[0]
        let softG = Sig.db(Sig.rms(y[120000..<144000]) / Sig.rms(x[0][120000..<144000]))   // end of soft part
        let loudG = Sig.db(Sig.rms(y[264000..<288000]) / Sig.rms(x[0][264000..<288000]))   // end of loud part
        let p = v.params
        #expect(softG > 3 && softG <= p.maxUpDB + 0.3, "soft \(softG)")
        #expect(loudG < -3 && loudG >= -p.maxDownDB - 0.3, "loud \(loudG)")
        #expect(24 + loudG - softG < 24 - 6)                    // the 24 dB spread shrinks by more than 6 dB
    }
    @Test func levelerDoesNotLiftBelowSpeechFloorAndOutputGainAdds() throws {
        let hiss = Sig.mono(300, amplitudeDB: -70, seconds: 2)
        let v = AudioLevelerValues(preset: 1, reduceLoud: true, liftSoft: true, background: false, outputGainDB: 0)
        #expect(abs(gainDB(try run(ClipEffect.audioDialogueLevelerKind, .dialogueLeveler(v), [hiss, hiss])[0], hiss)) < 0.1)
        var v6 = v; v6.outputGainDB = 6
        #expect(abs(gainDB(try run(ClipEffect.audioDialogueLevelerKind, .dialogueLeveler(v6), [hiss, hiss])[0], hiss) - 6) < 0.1)
        var bg = v; bg.background = true
        #expect(gainDB(try run(ClipEffect.audioDialogueLevelerKind, .dialogueLeveler(bg), [hiss, hiss])[0], hiss) < -4)
    }
    @Test func disabledRepairStagesPassThrough() throws {
        let x = Sig.sine(freq: 50, amplitudeDB: -20, seconds: 0.1)
        #expect(try run(ClipEffect.audioDeHumKind, .deHum(frequencyHz: 50, q: 10, gainDB: -30, harmonics: 4, slope: 0.5, listen: false), x, enabled: false) == x)
        #expect(try run(ClipEffect.audioLowCutKind, .lowCut(frequencyHz: 200, order: 3), x, enabled: false) == x)
    }
}

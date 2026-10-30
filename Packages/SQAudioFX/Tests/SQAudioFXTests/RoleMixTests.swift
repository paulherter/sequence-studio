import Foundation
import Testing
import SQCore
@testable import SQAudioFX

@Suite struct RoleVoicingTests {
    @Test func everyRoleHasItsOwnBuiltInPreset() {
        let ids = AudioTag.allCases.map { TrackAudioPreset.forRole($0).id }
        #expect(ids == ["builtin.role.dialogue", "builtin.role.music", "builtin.role.sfx"])
        for r in AudioTag.allCases {
            let p = TrackAudioPreset.forRole(r)
            #expect(p.isBuiltIn)
            #expect(p.name == r.title)
            #expect(!p.compressor.bypass)
            #expect(p.compressor.bands.count == 4 && p.compressor.crossoversHz.count == 3)
            #expect(p.compressor.crossoversHz == p.compressor.crossoversHz.sorted())
        }
    }

    @Test func dialogueCutsRumbleAddsPresenceCompressesFirmlyAndDenoises() {
        let v = RoleVoicing.forRole(.dialogue)
        #expect(v.eqDB == [-6, 0, 3, 1])
        #expect(v.levelDB == 0)
        #expect(v.noiseReduction == 0.6)
        #expect(v.bands.map(\.ratio) == [2, 3, 3, 2])
        #expect(v.makeupGainDB == 0)        // matched dialogue (-14 LUFS) is not pushed above its target
    }

    @Test func musicIsScoopedWithGentleGlue() {
        let v = RoleVoicing.forRole(.music)
        #expect(v.eqDB == [0, -2, -3, 0])        // scooped where speech lives
        #expect(v.levelDB == 0)             // Match Loudness already puts music 6 dB under dialogue
        #expect(v.makeupGainDB == 0)
        #expect(v.noiseReduction == 0)
        #expect(v.bands.allSatisfy { $0.ratio <= 1.6 })
    }

    @Test func sfxKeepsTransientsAndLevel() {
        let v = RoleVoicing.forRole(.sfx)
        #expect(v.eqDB == [0, 0, 0, 0])
        #expect(v.levelDB == 0)
        #expect(v.makeupGainDB == 0)
        #expect(v.noiseReduction == 0)
        #expect(v.bands.allSatisfy { $0.attackMs >= 10 })   // slow attack lets hits through
    }

    @Test func presetFoldsEQIntoBandGainsAndLevelIntoMakeup() {
        for r in AudioTag.allCases {
            let v = RoleVoicing.forRole(r), p = TrackAudioPreset.forRole(r)
            #expect(p.compressor.bands.map(\.gainDB) == v.eqDB)
            #expect(p.compressor.bands.map(\.ratio) == v.bands.map(\.ratio))
            #expect(p.compressor.makeupGainDB == v.makeupGainDB + v.levelDB)
            #expect(p.noiseReduction == v.noiseReduction)
        }
    }

    @Test func libraryFindsRolePresetsWithoutListingThemTwice() {
        let lib = PresetLibrary()
        #expect(lib.preset(id: "builtin.role.music") == .forRole(.music))
        #expect(lib.all.count == TrackAudioPreset.builtIns.count)
    }
}

@Suite struct MasterLimiterTests {
    @Test func requiredGainBringsThePeakToTheCeiling() {
        #expect(MasterLimiter.requiredGain(peak: 2, ceiling: 0.5) == 0.25)
        #expect(MasterLimiter.requiredGain(peak: 0.5, ceiling: 0.5) == 1)
        #expect(MasterLimiter.requiredGain(peak: 0.3, ceiling: 0.5) == 1)
        #expect(MasterLimiter.requiredGain(peak: 0, ceiling: 0.5) == 1)
    }

    @Test func ceilingIsTheTargetTruePeakInLinear() {
        let l = MasterLimiter(sampleRate: 48_000, ceilingDB: -1)
        #expect(abs(l.ceiling - 0.891_250_9) < 1e-6)
        #expect(l.ceiling <= GainMath.linear(fromDB: -1))        // rounded down, never up
    }

    @Test func signalBelowTheCeilingPassesBitExact() {
        var lim = MasterLimiter(sampleRate: 48_000, ceilingDB: -1)
        var l = (0..<4800).map { Float(0.8 * sin(Double($0) * 0.05)) }, r = l.map { -$0 }
        let l0 = l, r0 = r
        process(&lim, &l, &r)
        #expect(l == l0 && r == r0)
        #expect(lim.gainReductionDB == 0)
    }

    @Test func outputNeverExceedsTheCeilingOnEitherChannel() {
        var lim = MasterLimiter(sampleRate: 48_000, ceilingDB: -1)
        var l = (0..<9600).map { Float(1.6 * sin(Double($0) * 0.03)) }, r = (0..<9600).map { Float(0.4 * sin(Double($0) * 0.07)) }
        process(&lim, &l, &r)
        let ceil = Float(lim.ceiling)            // strict: no epsilon
        #expect(l.allSatisfy { abs($0) <= ceil } && r.allSatisfy { abs($0) <= ceil })
        #expect(lim.gainReductionDB < 0)
    }

    @Test func gainIsStereoLinkedSoTheImageStays() {
        var lim = MasterLimiter(sampleRate: 48_000, ceilingDB: -6.0206)
        var l = [Float](repeating: 1, count: 64), r = [Float](repeating: 0.25, count: 64)
        process(&lim, &l, &r)
        #expect(abs(l[10] - 0.5) < 1e-4 && abs(r[10] - 0.125) < 1e-4)
    }

    @Test func gainHoldsThenReleasesWithTheReleaseTimeConstant() {
        var lim = MasterLimiter(sampleRate: 48_000, ceilingDB: -6.0206, releaseMs: 100, holdMs: 5)
        var l: [Float] = [1], r: [Float] = [1]
        process(&lim, &l, &r)                       // one spike: gain 0.5
        #expect(abs(lim.gain - 0.5) < 1e-4)
        var ql = [Float](repeating: 0.01, count: 240), qr = ql      // 5 ms hold
        process(&lim, &ql, &qr)
        #expect(abs(lim.gain - 0.5) < 1e-4)
        ql = [Float](repeating: 0.01, count: 4800); qr = ql         // one release time constant
        process(&lim, &ql, &qr)
        let expected = 1 - 0.5 * exp(-1.0)
        #expect(abs(lim.gain - expected) < 2e-3)
        ql = [Float](repeating: 0.01, count: 48_000); qr = ql
        process(&lim, &ql, &qr)
        #expect(lim.gain > 0.9999)
    }

    @Test func resetForgetsTheGainReduction() {
        var lim = MasterLimiter(sampleRate: 48_000, ceilingDB: -1)
        var l: [Float] = [4], r: [Float] = [4]
        process(&lim, &l, &r)
        lim.reset()
        #expect(lim.gain == 1)
    }

    private func process(_ lim: inout MasterLimiter, _ l: inout [Float], _ r: inout [Float]) {
        let n = l.count
        l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in
            lim.process(left: a.baseAddress!, right: b.baseAddress!, count: n) } }
    }
}

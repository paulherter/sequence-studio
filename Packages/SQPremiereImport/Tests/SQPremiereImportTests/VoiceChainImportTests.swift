import Testing
import Foundation
import SQCore
@testable import SQPremiereImport

// Premiere Multiband Compressor / Parametric EQ -> audio.multiband / audio.parametricEQ. Values copied from a real project.
@Suite struct VoiceChainImportTests {
    let S = PRFixture.second

    /// A 46-param audio component with `values` at their positions (everything else 0).
    func component(_ f: PRFixture, match: String, name: String, count: Int, _ values: [Int: String]) -> String {
        let ps = (0..<count).map { i in f.param(nil, values[i] ?? "0.", kind: "AudioComponentParam", name: "P\(i)") }
        return f.audioComponent(displayName: name, matchName: match, ps)
    }

    func importClip(_ comp: (PRFixture) -> String) throws -> (Clip, PRImportResult) {
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let a = f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [comp(f)], audio: true)
        f.sequence("Main", video: [], audio: [f.track([a], audio: true)])
        let r = PRMapper.map(try PRReader.read(data: f.data), name: "T")
        return (r.project.timelines[0].tracks.filter { $0.kind == .audio }.flatMap(\.clips)[0], r)
    }
    func value(_ e: ClipEffect, _ k: String) -> Double { e.parameters[k]?.value ?? -999 }

    @Test func multibandMapsTheDocumentedFormulas() throws {
        // Rode NTG Indoor values: out 0.5, thresholds .75/.8167/.7167/.75, ratios .069/.034/.034/.069, attack .002, release .02,
        // gains .6111/.4444/.3889/.4444, crossovers .005856/.056406/.344845.
        let (c, r) = try importClip { f in
            component(f, match: "3981e750-c8ae-40a2-889f-41a01c7efa03", name: "Multiband", count: 41, [
                1: "0.5", 2: "0.75", 3: "0.816666662693", 4: "0.716666638851", 5: "0.75",
                6: "0.068965516984", 7: "0.034482758492", 8: "0.034482758492", 9: "0.068965516984",
                10: "0.002", 11: "0.002", 12: "0.002", 13: "0.002", 14: "0.02", 15: "0.02", 16: "0.02", 17: "0.02",
                18: "0.611111104488", 19: "0.444444447756", 20: "0.388888895512", 21: "0.444444447756",
                34: "0.005855855998", 35: "0.056406404823", 36: "0.344844847918"])
        }
        let e = try #require(c.effects.first { $0.kind == ClipEffect.audioMultibandKind })
        #expect(abs(value(e, ClipEffect.mbOutputGainKey)) < 1e-6)
        #expect(abs(value(e, ClipEffect.mbThresholdKey(1)) - (-15)) < 1e-6 && abs(value(e, ClipEffect.mbThresholdKey(2)) - (-11)) < 1e-6)
        #expect(abs(value(e, ClipEffect.mbRatioKey(1)) - 3) < 1e-6 && abs(value(e, ClipEffect.mbRatioKey(2)) - 2) < 1e-6)
        // The maintainer's Premiere panel for these values: attack 1 ms, release 100 ms, crossovers 137 / 1147 / 6910 Hz (Audition ranges:
        // attack 0...500 ms, release 0...5000 ms, crossovers 20...20000 Hz).
        #expect(abs(value(e, ClipEffect.mbAttackKey(3)) - 1) < 1e-6 && abs(value(e, ClipEffect.mbReleaseKey(3)) - 100) < 1e-6)
        #expect(abs(value(e, ClipEffect.mbGainKey(1)) - 4) < 1e-6 && abs(value(e, ClipEffect.mbGainKey(3)) - (-4)) < 1e-6)
        #expect(abs(value(e, ClipEffect.mbCrossoverKey(1)) - 137) < 0.5)
        #expect(abs(value(e, ClipEffect.mbCrossoverKey(2)) - 1147) < 0.5)
        #expect(abs(value(e, ClipEffect.mbCrossoverKey(3)) - 6910) < 0.5)
        #expect(value(e, ClipEffect.mbLimiterOnKey) == 0)             // a component without the LMAX params has no limiter
        #expect(e.enabled)
        #expect(r.report.status(of: "Multiband") == .approximated)
    }

    @Test func multibandLimiterMapsFromTheLMAXParams() throws {
        // Positions follow Premiere's parameter table: 48 LMAX threshold, 49 margin, 50 ratio, 51 attack, 52 release, 53 bypass.
        // Broadcast: threshold -9 dB, margin -0.1 dB, attack 4 ms, release 500 ms.
        func imported(bypass: String) throws -> ClipEffect {
            let (c, _) = try importClip { f in
                component(f, match: "3981e750-c8ae-40a2-889f-41a01c7efa03", name: "Multiband", count: 60, [
                    1: "0.5", 48: "0.85", 49: "0.497222222", 51: "0.008", 52: "0.1", 53: bypass])
            }
            return try #require(c.effects.first { $0.kind == ClipEffect.audioMultibandKind })
        }
        let e = try imported(bypass: "0.")
        #expect(value(e, ClipEffect.mbLimiterOnKey) == 1)
        #expect(abs(value(e, ClipEffect.mbLimiterThresholdKey) - (-9)) < 1e-6)
        #expect(abs(value(e, ClipEffect.mbLimiterMarginKey) - (-0.1)) < 1e-4)
        #expect(abs(value(e, ClipEffect.mbLimiterReleaseKey) - 500) < 1e-6)
        #expect(value(try imported(bypass: "1"), ClipEffect.mbLimiterOnKey) == 0)
        #expect(abs(value(e, ClipEffect.mbLimiterAttackKey) - 4) < 1e-6)          // 51 attack, v x 500 ms (assumed, band attack scale)
    }

    /// The maintainer's full "Broadcast" multiband (raw values as Premiere stores them) maps to physically plausible values, every one
    /// listed: the panel values the maintainer read off Premiere, no hidden gain anywhere.
    @Test func broadcastPresetMapsToPlausibleValues() throws {
        let (c, _) = try importClip { f in
            component(f, match: "3981e750-c8ae-40a2-889f-41a01c7efa03", name: "Multiband", count: 60, [
                1: "0.5", 2: "0.75", 3: "0.816666662693", 4: "0.716666638851", 5: "0.75",
                6: "0.068965516984", 7: "0.034482758492", 8: "0.034482758492", 9: "0.068965516984",
                10: "0.002", 11: "0.002", 12: "0.002", 13: "0.002", 14: "0.02", 15: "0.02", 16: "0.02", 17: "0.02",
                18: "0.611111104488", 19: "0.444444447756", 20: "0.388888895512", 21: "0.444444447756",
                34: "0.005855855998", 35: "0.056406404823", 36: "0.344844847918",
                48: "0.85", 49: "0.497222222", 51: "0.008", 52: "0.1", 53: "0."])
        }
        let e = try #require(c.effects.first { $0.kind == ClipEffect.audioMultibandKind })
        guard case .multiband(let v) = e.audioStage(atLocal: .zero) else { Issue.record("mb"); return }
        func near(_ a: Double, _ b: Double, _ tol: Double = 0.01) -> Bool { abs(a - b) <= tol }
        #expect(near(v.outputGainDB, 0))
        #expect(near(v.crossoverHz[0], 137, 0.5) && near(v.crossoverHz[1], 1147, 0.5) && near(v.crossoverHz[2], 6910, 0.5))
        let thr: [Double] = [-15, -11, -17, -15], gain: [Double] = [4, -2, -4, -2], ratio: [Double] = [3, 2, 2, 3]
        for b in 0..<4 {
            #expect(near(v.thresholdDB[b], thr[b]) && near(v.gainDB[b], gain[b]) && near(v.ratio[b], ratio[b]), "band \(b + 1)")
            #expect(near(v.attackMs[b], 1) && near(v.releaseMs[b], 100), "band \(b + 1)")
        }
        #expect(v.limiterOn)
        #expect(near(v.limiterThresholdDB, -9) && near(v.limiterMarginDB, -0.1) && near(v.limiterAttackMs, 4) && near(v.limiterReleaseMs, 500))
        #expect(near(v.limiterGainDB, 8.9))                       // the drive into the look-ahead brickwall
        #expect(v.bandSolo == 0 && v.bandBypass == 0)
        // Physically plausible: no single gain stage above +12 dB, ratios >= 1, crossovers ascending inside 20 Hz...20 kHz.
        #expect(v.outputGainDB + (0..<4).map { v.gainDB[$0] }.max()! + v.limiterGainDB <= 18)
        #expect((0..<4).allSatisfy { v.ratio[$0] >= 1 && v.thresholdDB[$0] <= 0 })
        #expect(v.crossoverHz[0] < v.crossoverHz[1] && v.crossoverHz[1] < v.crossoverHz[2])
    }

    @Test func limiterDriveIsCappedConservatively() throws {
        // An unknown preset with LMAX threshold -45 dB (0.25) and margin -0.1: at most 12 dB drive, not 44.9.
        let (c, _) = try importClip { f in
            component(f, match: "3981e750-c8ae-40a2-889f-41a01c7efa03", name: "Multiband", count: 60, [1: "0.5", 48: "0.25", 49: "0.497222222"])
        }
        let e = try #require(c.effects.first { $0.kind == ClipEffect.audioMultibandKind })
        guard case .multiband(let v) = e.audioStage(atLocal: .zero) else { Issue.record("mb"); return }
        #expect(abs(v.limiterGainDB - 12) < 1e-9)
    }

    @Test func limiterDriveCapHoldsForKeyframedMargins() throws {
        // Margin keyed from -18 dB (0) to 0 dB (0.5), threshold -45 dB: the drive stays <= 12 dB at every key and in between.
        let (c, _) = try importClip { f in
            let ps = (0..<60).map { i -> String in
                if i == 49 {
                    return f.param(nil, "0.", keys: "0,0.,0,0,0,0,0,0;\(PRFixture.second / 2),0.5,0,0,0,0,0,0", kind: "AudioComponentParam", name: "P49")
                }
                return f.param(nil, [1: "0.5", 48: "0.25"][i] ?? "0.", kind: "AudioComponentParam", name: "P\(i)")
            }
            return f.audioComponent(displayName: "Multiband", matchName: "3981e750-c8ae-40a2-889f-41a01c7efa03", ps)
        }
        let e = try #require(c.effects.first { $0.kind == ClipEffect.audioMultibandKind })
        for k in 0...20 {
            let t = Time(Int64(k), 40)
            guard case .multiband(let v) = e.audioStage(atLocal: t) else { Issue.record("mb"); return }
            #expect(v.limiterGainDB <= 12 + 1e-9, "t \(k)/40 s: drive \(v.limiterGainDB)")
        }
    }

    @Test func audioGainFeedsTheEffectsInsteadOfFollowingTheLimiter() throws {
        // Premiere: Audio Gain is the input level (before effects), Volume the output level. +6 dB of Audio Gain on a clip with a
        // limiter must go into the chain, not lift the limited output.
        let f = PRFixture()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let mb = component(f, match: "3981e750-c8ae-40a2-889f-41a01c7efa03", name: "Multiband", count: 60, [1: "0.5", 48: "0.85", 49: "0.497222222"])
        let a = f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [mb], audio: true, gain: 2)
        let b = f.item(start: S, end: 2 * S, inPoint: 0, outPoint: S, source: .media(m), audio: true, gain: 2)
        f.sequence("Main", video: [], audio: [f.track([a, b], audio: true)])
        let clips = PRMapper.map(try PRReader.read(data: f.data), name: "T").project.timelines[0].tracks.filter { $0.kind == .audio }.flatMap(\.clips)
        let withFX = try #require(clips.first { !$0.effects.isEmpty }), plain = try #require(clips.first { $0.effects.isEmpty })
        // Clip.audioGainDB is SQ's Audio Gain, applied in front of the chain (AudioFeeder); no hidden effect, volume untouched.
        #expect(withFX.effects.map(\.kind) == [ClipEffect.audioMultibandKind])
        #expect(abs(withFX.audioGainDB - 20 * log10(2.0)) < 1e-9)
        #expect(abs(withFX.animation.volume.value - 1) < 1e-9)
        #expect(abs(plain.audioGainDB - 20 * log10(2.0)) < 1e-9 && abs(plain.animation.volume.value - 1) < 1e-9)
    }

    @Test func multibandBandSoloBypassAndLinkMapFromTheirParams() throws {
        // Premiere's table: 24 link band controls, 25-28 bypass 1-4, 29-32 solo 1-4, 37-40 crossover band bypass 1-4.
        let (c, r) = try importClip { f in
            component(f, match: "3981e750-c8ae-40a2-889f-41a01c7efa03", name: "Multiband", count: 41, [
                1: "0.5", 2: "0.5", 6: "0.5", 18: "0.75", 24: "1", 26: "1", 31: "1", 40: "1"])
        }
        let e = try #require(c.effects.first { $0.kind == ClipEffect.audioMultibandKind })
        #expect(value(e, ClipEffect.mbLinkKey) == 1)
        #expect(value(e, ClipEffect.mbBypassKey(1)) == 0 && value(e, ClipEffect.mbBypassKey(2)) == 1)
        #expect(value(e, ClipEffect.mbBypassKey(4)) == 1)                            // crossover band bypass counts too
        #expect(value(e, ClipEffect.mbSoloKey(3)) == 1 && value(e, ClipEffect.mbSoloKey(1)) == 0)
        // The band's own values stay (bypass is a real switch now, not ratio 1 + gain 0).
        #expect(abs(value(e, ClipEffect.mbRatioKey(1)) - 15.5) < 1e-6 && abs(value(e, ClipEffect.mbGainKey(1)) - 9) < 1e-6)
        guard case .multiband(let v) = c.audioFXSteps(atLocal: .zero)[0].stage else { Issue.record("mb"); return }
        #expect(v.bandBypass == 0b1010 && v.bandSolo == 0b0100)
        #expect(r.report.status(of: "Multiband") == .approximated)
    }

    @Test func parametricEQMapsGainFrequencyAndEnableFlags() throws {
        // Band 4: freq .105947 gain .424342 (about -3.6 dB), band 1 switched off with "0.", HP on at .002493 (60 Hz at 48 kHz).
        let (c, _) = try importClip { f in
            component(f, match: "8edcd326-33de-4a4d-985b-f1bf48ed1427", name: "EQ", count: 46, [
                1: "0.000834", 2: "0.5", 3: "0.749791", 4: "0.520833",
                5: "0.001251", 6: "0.000199989998", 7: "0.544407", 8: "0.",
                17: "0.105947375298", 18: "0.0002", 19: "0.42434206605", 20: "1",
                30: "1", 31: "1", 32: "0.25", 38: "1", 39: "0.002493", 41: "0.", 42: "0.749791"])
        }
        let e = try #require(c.effects.first { $0.kind == ClipEffect.audioParametricEQKind })
        let k = ClipEffect.peqKey
        // Frequency = 20 Hz + value x (sample rate / 2 - 20 Hz): Premiere's default band 1 (.001251) is 50 Hz, shelves 40 / 18000 Hz.
        #expect(abs(value(e, k("b4", "Gain")) - (-3.63)) < 0.01 && abs(value(e, k("b4", "Freq")) - 2560.6) < 0.5 && abs(value(e, k("b4", "Q")) - 1) < 0.01)
        #expect(abs(value(e, k("b1", "Freq")) - 50) < 0.1 && abs(value(e, k("ls", "Freq")) - 40) < 0.1)
        #expect(value(e, k("b1", "On")) == 0 && value(e, k("b4", "On")) == 1)
        #expect(abs(value(e, k("hs", "Gain")) - 1) < 0.001 && abs(value(e, k("hs", "Freq")) - 18_000) < 1)
        #expect(value(e, k("hp", "On")) == 1 && abs(value(e, k("hp", "Freq")) - 79.8) < 0.1)
        #expect(value(e, k("lp", "On")) == 0)
    }

    /// Golden values from a real voice preset (stereo instance): Premiere shows band 4 at 3000 Hz / Q 0.75 / +1 dB, band 5 at
    /// 7000 Hz / Q 0.875 / -1 dB, bands 1-3 off, HP on at about 80 Hz, LP off at 18 kHz. Its bandwidth readouts (params 33-37,
    /// value x 20 kHz = frequency / Q) confirm the Q scale.
    @Test func parametricEQMatchesPremieresReadoutsForARealPreset() throws {
        let (c, _) = try importClip { f in
            component(f, match: "8edcd326-33de-4a4d-985b-f1bf48ed1427", name: "EQ", count: 46, [
                1: "0.000834028", 2: "0.5", 3: "0.0828507", 4: "0.520833",
                5: "0.00430451", 6: "0.0002", 7: "0.544408", 8: "0.",
                9: "0.0145694", 10: "0.0002", 11: "0.536184", 12: "0.",
                13: "0.0325271", 14: "0.0002", 15: "0.5", 16: "0.",
                17: "0.12427022", 18: "0.00015", 19: "0.5208333", 20: "1",
                21: "0.29107589", 22: "0.000175", 23: "0.4791667", 24: "1",
                25: "0.6667", 26: "0.", 30: "0.", 31: "0.", 32: "0.25", 38: "1", 39: "0.0024934697", 41: "0.", 42: "0.7498"])
        }
        let e = try #require(c.effects.first { $0.kind == ClipEffect.audioParametricEQKind })
        let k = ClipEffect.peqKey
        #expect(abs(value(e, k("b4", "Freq")) - 3_000) < 0.5 && abs(value(e, k("b4", "Q")) - 0.75) < 0.001 && abs(value(e, k("b4", "Gain")) - 1) < 0.001)
        #expect(abs(value(e, k("b5", "Freq")) - 7_000) < 0.5 && abs(value(e, k("b5", "Q")) - 0.875) < 0.001 && abs(value(e, k("b5", "Gain")) + 1) < 0.001)
        #expect(abs(value(e, k("b3", "Freq")) - 800) < 0.5 && abs(value(e, k("b1", "Freq")) - 123.2) < 0.2)
        #expect(value(e, k("b1", "On")) == 0 && value(e, k("b2", "On")) == 0 && value(e, k("b3", "On")) == 0)
        #expect(value(e, k("b4", "On")) == 1 && value(e, k("b5", "On")) == 1)
        #expect(value(e, k("ls", "On")) == 0 && value(e, k("hs", "On")) == 0)
        #expect(value(e, k("hp", "On")) == 1 && abs(value(e, k("hp", "Freq")) - 79.8) < 0.1)
        #expect(value(e, k("lp", "On")) == 0 && abs(value(e, k("lp", "Freq")) - 18_000) < 1)
    }

    @Test func importedEffectsSurviveTheProjectFileAsV46() throws {
        let (c, r) = try importClip { f in component(f, match: "3981e750-c8ae-40a2-889f-41a01c7efa03", name: "Multiband", count: 41, [1: "0.5"]) }
        #expect(c.audioFXLayout.map(\.kind) == [ClipEffect.audioMultibandKind])
        #expect(r.project.containsVoiceChainEffects)     // so the file is written as v46 (SQCore tests)
    }
}

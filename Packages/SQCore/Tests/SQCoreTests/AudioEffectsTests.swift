import Foundation
import Testing
@testable import SQCore

// AUDIO-FX: audio effects are `ClipEffect`s with `audio.` kinds on audio clips. List order = processing order; Volume stays
// the fixed clip property and is applied after them.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

private func add(_ c: inout Clip, _ kind: String) throws -> ClipEffect.ID {
    let id = c.addEffect(kind: kind)
    return try #require(id)
}

@Suite struct AudioEffectsTests {
    private func audioClip(start: Time = .zero) -> Clip {
        Clip(name: "A", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: f(60)), start: start,
             mediaDuration: f(60))
    }
    private func videoClip() -> Clip {
        Clip(name: "V", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero,
             mediaDuration: f(60))
    }

    // MARK: Catalog

    @Test func catalogHasTheV1AudioEffects() {
        let kinds = EffectCatalog.offeredAudio(hiding: true).map(\.kind)
        #expect(kinds == [ClipEffect.audioNoiseReductionKind, ClipEffect.audioCompressorKind,   // Gain and the 3-band EQ are hidden (HiddenCatalog)
                          ClipEffect.audioDeEsserKind, ClipEffect.audioDeReverbKind, ClipEffect.audioLimiterKind,
                          ClipEffect.audioNoiseGateKind, ClipEffect.audioDelayKind, ClipEffect.audioReverbKind,
                          ClipEffect.audioDeHumKind, ClipEffect.audioLowCutKind, ClipEffect.audioDialogueLevelerKind,
                          ClipEffect.audioMultibandKind, ClipEffect.audioParametricEQKind, ClipEffect.audioEnhanceSpeechKind,
                          ClipEffect.audioHighCutKind, ClipEffect.audioStereoWidthKind, ClipEffect.audioChorusKind,
                          ClipEffect.audioNotchKind, ClipEffect.audioGraphicEQKind, ClipEffect.audioPitchShiftKind, ClipEffect.audioDisguiseVoiceKind])
        for k in kinds {
            #expect(ClipEffect.isAudioKind(k))
            #expect(EffectCatalog.spec(for: k) != nil)
            #expect(!EffectCatalog.all.contains { $0.kind == k })     // the video list stays video only
        }
        #expect(!ClipEffect.isAudioKind(ClipEffect.gaussianBlurKind))
    }

    @Test func gateDelayReverbStageDefaults() throws {
        var a = audioClip()
        let g = try add(&a, ClipEffect.audioNoiseGateKind)
        let d = try add(&a, ClipEffect.audioDelayKind)
        let r = try add(&a, ClipEffect.audioReverbKind)
        let steps = a.audioFXSteps(atLocal: .zero)
        #expect(steps.map(\.id) == [g, d, r])
        #expect(steps[0].stage == .noiseGate(thresholdDB: -40, attackMs: 1, releaseMs: 100, rangeDB: 60))
        #expect(steps[1].stage == .delay(timeMs: 350, feedback: 0.35, mix: 0.3))
        #expect(steps[2].stage == .reverb(roomSize: 0.5, damping: 0.5, mix: 0.25))
        a.setParameter(d, ClipEffect.delayTimeKey, to: 5000)   // clamped to the catalog range
        #expect(a.audioFXSteps(atLocal: .zero)[1].stage == .delay(timeMs: 2000, feedback: 0.35, mix: 0.3))
    }

    @Test func highCutStereoWidthChorusDefaultsAndRanges() throws {
        var a = audioClip()
        let h = try add(&a, ClipEffect.audioHighCutKind)
        let w = try add(&a, ClipEffect.audioStereoWidthKind)
        let c = try add(&a, ClipEffect.audioChorusKind)
        #expect(a.audioFXSteps(atLocal: .zero).map(\.stage) == [.highCut(frequencyHz: 12_000, order: 2), .stereoWidth(width: 1),
                                                              .chorus(rateHz: 0.8, depthMs: 3, mix: 0.4)])
        a.setParameter(h, ClipEffect.highCutFreqKey, to: 100)        // clamped to 1...20 kHz
        a.setParameter(w, ClipEffect.stereoWidthKey, to: 900)        // clamped to 0...200 %
        a.setParameter(c, ClipEffect.chorusDepthKey, to: 99)         // clamped to 0...10 ms
        #expect(a.audioFXSteps(atLocal: .zero).map(\.stage) == [.highCut(frequencyHz: 1_000, order: 2), .stereoWidth(width: 2),
                                                              .chorus(rateHz: 0.8, depthMs: 10, mix: 0.4)])
    }

    @Test func deEsserNewControlsDefaultToTheOldBehaviourAndClamp() throws {
        var a = audioClip()
        let e = try add(&a, ClipEffect.audioDeEsserKind)
        #expect(a.audioFXSteps(atLocal: .zero)[0].stage == .deEsser(reductionDB: 10, sensitivity: 0.5, frequencyHz: 7_000, range: 1, speed: 1, listen: false))
        a.setParameter(e, ClipEffect.deEssFrequencyKey, to: 20_000)       // clamped to 2...10 kHz
        a.setParameter(e, ClipEffect.deEssRangeKey, to: 2)
        a.setParameter(e, ClipEffect.deEssListenKey, to: 1)
        #expect(a.audioFXSteps(atLocal: .zero)[0].stage == .deEsser(reductionDB: 10, sensitivity: 0.5, frequencyHz: 10_000, range: 2, speed: 1, listen: true))
        // An effect stored before the new keys existed (only the old two) reads the new defaults.
        var old = audioClip()
        let o = try add(&old, ClipEffect.audioDeEsserKind)
        let idx = try #require(old.effects.firstIndex { $0.id == o })
        old.effects[idx].parameters = old.effects[idx].parameters.filter { [ClipEffect.deEssReductionKey, ClipEffect.deEssSensitivityKey].contains($0.key) }
        #expect(old.audioFXSteps(atLocal: .zero)[0].stage == .deEsser(reductionDB: 10, sensitivity: 0.5))
    }

    @Test func deReverbDefaultsAndRanges() throws {
        var a = audioClip()
        let r = try add(&a, ClipEffect.audioDeReverbKind)
        #expect(a.audioFXSteps(atLocal: .zero)[0].stage == .deReverb(amount: 0.5, decaySeconds: 0.6, tone: 0))
        a.setParameter(r, ClipEffect.deReverbDecayKey, to: 90_000)
        a.setParameter(r, ClipEffect.deReverbAmountKey, to: 250)
        #expect(a.audioFXSteps(atLocal: .zero)[0].stage == .deReverb(amount: 1, decaySeconds: 2.5, tone: 0))
    }

    @Test func repairEffectDefaultsAndRanges() throws {
        var a = audioClip()
        let h = try add(&a, ClipEffect.audioDeHumKind)
        _ = try add(&a, ClipEffect.audioLowCutKind)
        let d = try add(&a, ClipEffect.audioDialogueLevelerKind)
        let steps = a.audioFXSteps(atLocal: .zero)
        #expect(steps[0].stage == .deHum(frequencyHz: 50, q: 10, gainDB: -30, harmonics: 4, slope: 0.5, listen: false))
        #expect(steps[1].stage == .lowCut(frequencyHz: 80, order: 2))
        #expect(steps[2].stage == .dialogueLeveler(AudioLevelerValues(preset: 0, reduceLoud: true, liftSoft: true, background: false, outputGainDB: 0)))
        a.setParameter(h, ClipEffect.deHumMainsKey, to: 2)            // 60 Hz quick choice overrides Frequency
        a.setParameter(h, ClipEffect.deHumHarmonicsKey, to: 20)       // clamped to 8
        a.setParameter(h, ClipEffect.deHumGainKey, to: -200)          // clamped to -80
        a.setParameter(d, ClipEffect.levelerOutputGainKey, to: 10)    // clamped to +6
        let s2 = a.audioFXSteps(atLocal: .zero)
        #expect(s2[0].stage == .deHum(frequencyHz: 60, q: 10, gainDB: -80, harmonics: 8, slope: 0.5, listen: false))
        if case .dialogueLeveler(let v) = s2[2].stage { #expect(v.outputGainDB == 6) } else { Issue.record("no leveler") }
    }

    // MARK: Adding

    @Test func audioEffectsGoOnAudioClipsOnly() {
        var a = audioClip()
        let a1 = a.addEffect(kind: ClipEffect.audioEQKind), a2 = a.addEffect(kind: ClipEffect.gaussianBlurKind)
        #expect(a1 != nil && a2 == nil)
        var v = videoClip()
        let v1 = v.addEffect(kind: ClipEffect.audioEQKind), v2 = v.addEffect(kind: ClipEffect.gaussianBlurKind)
        #expect(v1 == nil && v2 != nil)
        #expect(a.hasAudioEffects && !v.hasAudioEffects)
    }

    @Test func addingTwiceGivesTwoInstancesInOrder() throws {
        var a = audioClip()
        let g1 = try add(&a, ClipEffect.audioGainKind)
        let c = try add(&a, ClipEffect.audioCompressorKind)
        let g2 = try add(&a, ClipEffect.audioGainKind)
        #expect(a.effects.map(\.id) == [g1, c, g2])
        let moved = a.moveEffect(g2, to: 0)
        #expect(moved)
        #expect(a.effects.map(\.id) == [g2, g1, c])
        let removed = a.removeEffect(g1)
        #expect(removed)
        #expect(a.effects.map(\.id) == [g2, c])
    }

    @Test func pastedAudioEffectsOnlyLandOnAudioClips() throws {
        var a = audioClip()
        let id = try add(&a, ClipEffect.audioDeEsserKind)
        let e = try #require(a.effects.first { $0.id == id })
        #expect(audioClip().canAcceptPastedEffect(e))
        #expect(!videoClip().canAcceptPastedEffect(e))
        var v = videoClip()
        let blurID = try add(&v, ClipEffect.gaussianBlurKind)
        #expect(!audioClip().canAcceptPastedEffect(try #require(v.effects.first { $0.id == blurID })))
    }

    // MARK: Evaluation

    @Test func stepsFollowTheListOrderWithValuesAtTheTime() throws {
        var a = audioClip()
        let g = try add(&a, ClipEffect.audioGainKind)
        let l = try add(&a, ClipEffect.audioLimiterKind)
        a.setParameter(g, ClipEffect.audioGainKey, to: 6)
        a.setParameter(l, ClipEffect.limiterCeilingKey, to: -3)
        let steps = a.audioFXSteps(atLocal: .zero)
        #expect(steps.map(\.id) == [g, l])
        #expect(steps[0].stage == .gain(dB: 6))
        #expect(steps[1].stage == .limiter(inputDB: 0, ceilingDB: -3))
        #expect(a.audioFXLayout == [.init(id: g, kind: ClipEffect.audioGainKind), .init(id: l, kind: ClipEffect.audioLimiterKind)])
    }

    @Test func layoutMatchFollowsOrderAndIDs() throws {
        var a = audioClip()
        let g = try add(&a, ClipEffect.audioGainKind)
        _ = try add(&a, ClipEffect.audioEQKind)
        let layout = a.audioFXLayout
        #expect(a.audioFXLayoutMatches(layout))
        a.setParameter(g, ClipEffect.audioGainKey, to: 3)
        #expect(a.audioFXLayoutMatches(layout))            // values do not change the layout
        _ = a.moveEffect(g, to: 1)
        #expect(!a.audioFXLayoutMatches(layout))
        _ = a.removeEffect(g)
        #expect(!a.audioFXLayoutMatches(layout))
        var steps: [AudioFXStep] = []
        a.audioFXSteps(atLocal: .zero, into: &steps)
        #expect(steps == a.audioFXSteps(atLocal: .zero))
    }

    @Test func disabledEffectsStayInTheLayoutButAreOff() throws {
        var a = audioClip()
        let n = try add(&a, ClipEffect.audioNoiseReductionKind)
        a.effects[0].enabled = false
        let s = a.audioFXSteps(atLocal: .zero)
        #expect(s.count == 1 && s[0].id == n && !s[0].enabled)
        #expect(a.audioFXLayout.count == 1)        // the denoiser keeps its latency while switched off
    }

    @Test func keyframedParametersEvaluateAtClipLocalTime() throws {
        var a = audioClip(start: f(30))
        let g = try add(&a, ClipEffect.audioGainKind)
        var p = AnimatedProperty(0.0)
        p.track.insert(Keyframe(time: .zero, value: -12))
        p.track.insert(Keyframe(time: f(30), value: 0))
        a.effects[0].parameters[ClipEffect.audioGainKey] = p
        #expect(a.audioFXSteps(atLocal: .zero).first?.stage == .gain(dB: -12))
        #expect(a.audioFXSteps(atLocal: f(15)).first?.stage == .gain(dB: -6))
        #expect(a.audioFXSteps(atLocal: f(30)).first?.stage == .gain(dB: 0))
        _ = g
    }

    @Test func valuesAreClampedToTheCatalogRange() throws {
        var a = audioClip()
        let c = try add(&a, ClipEffect.audioCompressorKind)
        a.setParameter(c, ClipEffect.compRatioKey, to: 0.2)
        guard case .compressor(_, let ratio, _, _, _)? = a.audioFXSteps(atLocal: .zero).first?.stage else { Issue.record("no compressor"); return }
        #expect(ratio == 1)
    }

    @Test func defaultsAreNeutralEnough() throws {
        var a = audioClip()
        for k in EffectCatalog.everyAudioSpec.map(\.kind) { _ = a.addEffect(kind: k) }
        let s = a.audioFXSteps(atLocal: .zero).map(\.stage)
        #expect(s.contains(.gain(dB: 0)))
        #expect(s.contains(.eq(AudioEQValues(lowGainDB: 0, lowHz: 100, midGainDB: 0, midHz: 1000, midQ: 1, highGainDB: 0, highHz: 8000))))
        #expect(s.contains(.noiseReduction(amount: 0.5)))
    }

    // MARK: Paste Attributes

    @Test func pasteAttributesCarriesAudioEffects() throws {
        var src = audioClip()
        let eq = try add(&src, ClipEffect.audioEQKind)
        src.setParameter(eq, ClipEffect.eqMidGainKey, to: 5)
        _ = try add(&src, ClipEffect.audioGainKind)
        var dst = audioClip()
        _ = try add(&dst, ClipEffect.audioGainKind)
        let out = dst.pastingAttributes(from: src)
        // Gain: same count replaces; EQ: added behind with a fresh id.
        #expect(out.effects.map(\.kind) == [ClipEffect.audioGainKind, ClipEffect.audioEQKind])
        #expect(out.effects[1].id != eq)
        #expect(out.audioFXSteps(atLocal: .zero)[1].stage == .eq(AudioEQValues(lowGainDB: 0, lowHz: 100, midGainDB: 5, midHz: 1000, midQ: 1, highGainDB: 0, highHz: 8000)))
        // Pasting twice does not stack copies.
        #expect(out.pastingAttributes(from: src).effects.count == 2)
    }

    @Test func videoClipsHaveNoAudioSteps() throws {
        var v = videoClip()
        _ = v.addEffect(kind: ClipEffect.gaussianBlurKind)
        #expect(v.audioFXSteps(atLocal: .zero).isEmpty)
    }

    // MARK: ProjectFile v39

    private func project(_ clip: Clip) throws -> Project {
        var t = Track(kind: .audio)
        try t.overwrite(clip)
        return Project(name: "P", timelines: [Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd), tracks: [t])])
    }
    private func writtenVersion(_ p: Project) throws -> Int {
        let obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        return try #require(obj["formatVersion"] as? Int)
    }

    @Test func versionConstants() {
        #expect(ProjectFile.currentVersion >= 39)
        #expect(ProjectFile.audioEffectsVersion == 39)
    }

    @Test func aProjectWithAudioEffectsIsWrittenAsV39AndRoundTrips() throws {
        var a = audioClip()
        let g = try add(&a, ClipEffect.audioEQKind)
        a.setParameter(g, ClipEffect.eqMidGainKey, to: 4.5)
        _ = a.addEffect(kind: ClipEffect.audioNoiseReductionKind)
        a.effects[1].enabled = false
        let p = try project(a)
        #expect(p.containsAudioEffects)
        #expect(try writtenVersion(p) == ProjectFile.audioEffectsVersion)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p)
        #expect(back.timelines[0].tracks[0].clips[0].effects.map(\.kind) == [ClipEffect.audioEQKind, ClipEffect.audioNoiseReductionKind])
    }

    @Test func plainAudioProjectsKeepTheLowestVersion() throws {
        let p = try project(audioClip())
        #expect(!p.containsAudioEffects)
        #expect(try writtenVersion(p) == 36)
    }

    @Test func v38FilesStillOpen() throws {
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(try project(audioClip()))) as? [String: Any])
        obj["formatVersion"] = 38
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips.count == 1)
        #expect(!back.containsAudioEffects)
    }

    // MARK: Voice chain (v46): Multiband Compressor + 5-band Parametric EQ

    @Test func voiceChainEffectsRoundTripAsV46() throws {
        var a = audioClip()
        let m = try add(&a, ClipEffect.audioMultibandKind)
        let e = try add(&a, ClipEffect.audioParametricEQKind)
        a.setParameter(m, ClipEffect.mbThresholdKey(2), to: -33)
        a.setParameter(m, ClipEffect.mbRatioKey(2), to: 5.5)
        a.setParameter(e, ClipEffect.peqKey("b4", "Gain"), to: -3.6)
        a.setParameter(e, ClipEffect.peqKey("hp", "On"), to: 1)
        let p = try project(a)
        #expect(p.containsVoiceChainEffects)
        #expect(ProjectFile.currentVersion >= 46 && ProjectFile.voiceChainVersion == 46)
        #expect(try writtenVersion(p) == 46)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p)
        guard case .multiband(let mv) = back.timelines[0].tracks[0].clips[0].audioFXSteps(atLocal: .zero)[0].stage else { Issue.record("mb"); return }
        #expect(mv.thresholdDB[1] == -33 && mv.ratio[1] == 5.5)
    }

    @Test func multibandLimiterIsOffByDefaultAndReadsItsValues() throws {
        var a = audioClip()
        let m = try add(&a, ClipEffect.audioMultibandKind)
        guard case .multiband(let off) = a.audioFXSteps(atLocal: .zero)[0].stage else { Issue.record("mb"); return }
        #expect(!off.limiterOn)                                  // old and new SQ multibands sound as before
        a.setParameter(m, ClipEffect.mbLimiterOnKey, to: 1)
        a.setParameter(m, ClipEffect.mbLimiterThresholdKey, to: -9)
        a.setParameter(m, ClipEffect.mbLimiterMarginKey, to: -0.1)
        a.setParameter(m, ClipEffect.mbLimiterReleaseKey, to: 500)
        guard case .multiband(let on) = a.audioFXSteps(atLocal: .zero)[0].stage else { Issue.record("mb"); return }
        #expect(on.limiterOn && on.limiterThresholdDB == -9 && on.limiterMarginDB == -0.1 && on.limiterReleaseMs == 500)
        #expect(abs(on.limiterGainDB - 8.9) < 1e-9)             // threshold up to the margin (Premiere's Limiter)
    }

    @Test func multibandSoloBypassAndLimiterAttackDefaultOffAndReadTheirValues() throws {
        var a = audioClip()
        let m = try add(&a, ClipEffect.audioMultibandKind)
        guard case .multiband(let off) = a.audioFXSteps(atLocal: .zero)[0].stage else { Issue.record("mb"); return }
        #expect(off.bandSolo == 0 && off.bandBypass == 0 && off.limiterAttackMs == 0)
        a.setParameter(m, ClipEffect.mbSoloKey(2), to: 1)
        a.setParameter(m, ClipEffect.mbBypassKey(1), to: 1)
        a.setParameter(m, ClipEffect.mbBypassKey(4), to: 1)
        a.setParameter(m, ClipEffect.mbLimiterAttackKey, to: 4)
        guard case .multiband(let on) = a.audioFXSteps(atLocal: .zero)[0].stage else { Issue.record("mb"); return }
        #expect(on.bandSolo == 0b0010 && on.bandBypass == 0b1001 && on.limiterAttackMs == 4)
    }

    @Test func multibandWithoutTheNewKeysReadsAsBeforeAndStaysV46() throws {
        // A v46 multiband written before solo / bypass / limiter attack existed: the absent keys read as off / 0.
        var a = audioClip()
        let m = try add(&a, ClipEffect.audioMultibandKind)
        let newKeys = (1...4).flatMap { [ClipEffect.mbSoloKey($0), ClipEffect.mbBypassKey($0)] } + [ClipEffect.mbLimiterAttackKey, ClipEffect.mbLinkKey]
        if let i = a.effects.firstIndex(where: { $0.id == m }) { for k in newKeys { a.effects[i].parameters[k] = nil } }
        guard case .multiband(let v) = a.audioFXSteps(atLocal: .zero)[0].stage else { Issue.record("mb"); return }
        #expect(v.bandSolo == 0 && v.bandBypass == 0 && v.limiterAttackMs == 0)
        #expect(try writtenVersion(try project(a)) == 46)
        a.setParameter(m, ClipEffect.mbSoloKey(3), to: 1)
        #expect(try writtenVersion(try project(a)) == 46)        // keys inside an existing v46 kind: no format bump
    }

    @Test func multibandSetupOnlyKeysAreSoloBypassAndLink() {
        #expect(ClipEffect.mbSetupOnlyKeys.count == 9)
        #expect(ClipEffect.mbSetupOnlyKeys.contains(ClipEffect.mbLinkKey))
        #expect(!ClipEffect.mbSetupOnlyKeys.contains(ClipEffect.mbLimiterAttackKey))
        let spec = EffectCatalog.spec(for: ClipEffect.audioMultibandKind)!
        for k in ClipEffect.mbSetupOnlyKeys { #expect(spec.params.contains { $0.key == k && $0.defaultValue == 0 }) }
    }

    @Test func olderAudioProjectsKeepTheirVersionAndV45StillOpens() throws {
        var a = audioClip()
        _ = try add(&a, ClipEffect.audioEQKind)
        #expect(try writtenVersion(try project(a)) == ProjectFile.audioEffectsVersion)
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(try project(a))) as? [String: Any])
        obj["formatVersion"] = 45
        let back = try ProjectFile.decode(JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(!back.containsVoiceChainEffects && back.containsAudioEffects)
    }

    @Test func voiceChainValuesAreClampedAndDefaultsTransparentForTheEQ() throws {
        var a = audioClip()
        let e = try add(&a, ClipEffect.audioParametricEQKind)
        a.setParameter(e, ClipEffect.peqKey("b1", "Gain"), to: 99)
        a.setParameter(e, ClipEffect.peqKey("b1", "Freq"), to: 5)
        guard case .parametricEQ(let v) = a.audioFXSteps(atLocal: .zero)[0].stage else { Issue.record("eq"); return }
        #expect(v.b1.gainDB == 24 && v.b1.hz == 20)
        #expect(v.b2.gainDB == 0 && v.b2.on && !v.hp.on && !v.lp.on && v.lowShelf.on)
        #expect(a.audioFXLayout.map(\.kind) == [ClipEffect.audioParametricEQKind])
    }
}

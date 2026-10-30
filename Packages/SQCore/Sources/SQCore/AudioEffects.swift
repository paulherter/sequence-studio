import Foundation

// AUDIO-FX (v39): clip audio effects. They are `ClipEffect`s with `audio.` kinds in `Clip.effects` of AUDIO clips, so
// enable switch, keyframes, reorder, duplicate, remove and paste work like for video effects. List order = processing
// order. Volume stays the fixed clip property (`ClipAnimation.volume`) and is applied after the effects (Premiere order).

extension ClipEffect {
    /// Every audio effect kind starts with this (stored strings: never rename).
    public static let audioKindPrefix = "audio."
    public static let audioNoiseReductionKind = "audio.noiseReduction", noiseAmountReductionKey = "amount"
    public static let audioEQKind = "audio.eq"
    public static let eqLowGainKey = "lowGain", eqLowFreqKey = "lowFreq"
    public static let eqMidGainKey = "midGain", eqMidFreqKey = "midFreq", eqMidQKey = "midQ"
    public static let eqHighGainKey = "highGain", eqHighFreqKey = "highFreq"
    public static let audioCompressorKind = "audio.compressor"
    public static let compThresholdKey = "threshold", compRatioKey = "ratio", compAttackKey = "attack"
    public static let compReleaseKey = "release", compMakeupKey = "makeup"
    public static let audioDeEsserKind = "audio.deEsser", deEssReductionKey = "reduction", deEssSensitivityKey = "sensitivity"
    public static let deEssFrequencyKey = "frequency", deEssRangeKey = "range", deEssSpeedKey = "speed", deEssListenKey = "listen"
    public static let audioDeReverbKind = "audio.deReverb", deReverbAmountKey = "amount", deReverbDecayKey = "decay", deReverbToneKey = "tone"
    public static let audioGainKind = "audio.gain", audioGainKey = "gain"
    public static let audioLimiterKind = "audio.limiter", limiterInputKey = "inputGain", limiterCeilingKey = "ceiling"

    public static let audioNoiseGateKind = "audio.noiseGate"
    public static let gateThresholdKey = "threshold", gateAttackKey = "attack", gateReleaseKey = "release", gateRangeKey = "range"
    /// Gate Hold (v76): ms the gate stays open after the level fell below the threshold. Missing key = 0 (the earlier behavior).
    public static let gateHoldKey = "hold"
    public static let audioDelayKind = "audio.delay"
    public static let delayTimeKey = "time", delayFeedbackKey = "feedback", delayMixKey = "mix"
    public static let audioReverbKind = "audio.reverb"
    public static let reverbRoomSizeKey = "roomSize", reverbDampingKey = "damping", reverbMixKey = "mix"

    // Audio repair (De-Hum, Low Cut, Dialogue Leveler). Stored strings: never rename.
    public static let audioDeHumKind = "audio.deHum"
    public static let deHumMainsKey = "mains", deHumFreqKey = "frequency", deHumSlopeKey = "slope", deHumQKey = "q"
    public static let deHumGainKey = "gain", deHumHarmonicsKey = "harmonics", deHumListenKey = "listen"
    public static let audioLowCutKind = "audio.lowCut", lowCutFreqKey = "frequency", lowCutSlopeKey = "slope"
    public static let audioDialogueLevelerKind = "audio.dialogueLeveler"
    public static let levelerPresetKey = "preset", levelerReduceLoudKey = "reduceLoud", levelerLiftSoftKey = "liftSoft"
    public static let levelerBackgroundKey = "background", levelerOutputGainKey = "outputGain"

    // Creator tools: High Cut, Stereo Width, Chorus. Stored strings: never rename.
    public static let audioHighCutKind = "audio.highCut", highCutFreqKey = "frequency", highCutSlopeKey = "slope"
    public static let audioStereoWidthKind = "audio.stereoWidth", stereoWidthKey = "width"
    public static let audioChorusKind = "audio.chorus", chorusRateKey = "rate", chorusDepthKey = "depth", chorusMixKey = "mix"
    /// Notch (v73): a narrow cut at one frequency. Stored strings: never rename.
    public static let audioNotchKind = "audio.notch", notchFreqKey = "frequency", notchQKey = "q", notchDepthKey = "depth"
    /// Graphic EQ (v76): ten octave bands (31.5 Hz ... 16 kHz) and an output gain. Stored strings: never rename.
    public static let audioGraphicEQKind = "audio.graphicEQ", graphicEQOutputKey = "output"
    public static let graphicEQBandKeys = ["band31", "band63", "band125", "band250", "band500", "band1k", "band2k", "band4k", "band8k", "band16k"]

    public static func isAudioKind(_ kind: String) -> Bool { kind.hasPrefix(audioKindPrefix) }
    /// An audio effect (runs on the sound of an audio clip, never on the picture).
    public var isAudio: Bool { Self.isAudioKind(kind) }
}

extension EffectCatalog {
    /// The "Audio Effects" folder as offered (`HiddenCatalog` ones left out); `everyAudioSpec` has them all.
    public static let audio: [EffectSpec] = offeredAudio(hiding: HiddenCatalog.isActive)
    /// The same list for an explicit switch (tests; `audio` uses the app-level default).
    public static func offeredAudio(hiding: Bool) -> [EffectSpec] { everyAudioSpec.filter { !HiddenCatalog.isHidden(effectKind: $0.kind, active: hiding) } }

    /// The Effects panel's "Audio Effects" folder, in panel order. Not part of `all` (the video list).
    static let everyAudioSpec: [EffectSpec] = [
        // RNNoise wet/dry: 0 = off, 100 = fully denoised. Adds 10 ms of latency the mixer compensates.
        EffectSpec(kind: ClipEffect.audioNoiseReductionKind, title: "Noise Reduction", params: [
            EffectParamSpec(key: ClipEffect.noiseAmountReductionKey, title: "Amount", unit: "%", defaultValue: 50,
                            range: 0...100, step: 1, decimals: 0),
        ]),
        // Three-band parametric EQ: low shelf, mid peak, high shelf (RBJ).
        EffectSpec(kind: ClipEffect.audioEQKind, title: "EQ (3 band)", params: [
            EffectParamSpec(key: ClipEffect.eqLowGainKey, title: "Low Gain", unit: "dB", defaultValue: 0, range: -24...24, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.eqLowFreqKey, title: "Low Frequency", unit: "Hz", defaultValue: 100, range: 20...1_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.eqMidGainKey, title: "Mid Gain", unit: "dB", defaultValue: 0, range: -24...24, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.eqMidFreqKey, title: "Mid Frequency", unit: "Hz", defaultValue: 1_000, range: 100...10_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.eqMidQKey, title: "Mid Q", unit: "", defaultValue: 1, range: 0.1...10, step: 0.01, decimals: 2),
            EffectParamSpec(key: ClipEffect.eqHighGainKey, title: "High Gain", unit: "dB", defaultValue: 0, range: -24...24, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.eqHighFreqKey, title: "High Frequency", unit: "Hz", defaultValue: 8_000, range: 1_000...20_000, step: 1, decimals: 0),
        ]),
        // Single-band peak compressor (the detector of the 4-band compressor).
        EffectSpec(kind: ClipEffect.audioCompressorKind, title: "Compressor", params: [
            EffectParamSpec(key: ClipEffect.compThresholdKey, title: "Threshold", unit: "dB", defaultValue: -20, range: -60...0, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.compRatioKey, title: "Ratio", unit: ":1", defaultValue: 4, range: 1...20, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.compAttackKey, title: "Attack", unit: "ms", defaultValue: 10, range: 0.1...200, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.compReleaseKey, title: "Release", unit: "ms", defaultValue: 100, range: 10...2_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.compMakeupKey, title: "Makeup Gain", unit: "dB", defaultValue: 0, range: 0...24, step: 0.1, decimals: 1),
        ]),
        // Split-band de-esser: Reduction = the most the highs above the split are pulled down; Sensitivity = how early it reacts.
        // Frequency / Range / Speed / Listen follow the Resolve De-Esser's controls (target frequency, Narrow / Wide / All HF,
        // Slow / Medium / Fast, Listen to Ess; docs/research/AUDIO-EFFECTS.md). Defaults (7 kHz, Wide, Medium) are the values
        // the effect always had, so older projects sound the same. The 2-10 kHz span and the split ratios per Range and the
        // speed times are our own (unsourced).
        EffectSpec(kind: ClipEffect.audioDeEsserKind, title: "De-Esser", params: [
            EffectParamSpec(key: ClipEffect.deEssReductionKey, title: "Reduction", unit: "dB", defaultValue: 10, range: 0...24, step: 0.5, decimals: 1),
            EffectParamSpec(key: ClipEffect.deEssSensitivityKey, title: "Sensitivity", unit: "%", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.deEssFrequencyKey, title: "Frequency", unit: "Hz", defaultValue: 7_000, range: 2_000...10_000, step: 50, decimals: 0),
            .choice(ClipEffect.deEssRangeKey, "Range", AudioDeEsserValues.rangeTitles, default: 1),
            .choice(ClipEffect.deEssSpeedKey, "Reaction", AudioDeEsserValues.speedTitles, default: 1),
            .checkbox(ClipEffect.deEssListenKey, "Listen to Ess"),
        ]),
        // Late-reverb suppression (spectral): Amount = how much of the tail goes, Decay = the room's reverb time the estimate
        // assumes, Tone = which end of the spectrum is reduced more. Adds a fixed delay (`AudioDeReverbValues.latencySamples`).
        // Premiere's Reduce Reverb documents only Amount (0-100 %); Decay and Tone are ours, defaults unsourced.
        EffectSpec(kind: ClipEffect.audioDeReverbKind, title: "De-Reverb", params: [
            EffectParamSpec(key: ClipEffect.deReverbAmountKey, title: "Amount", unit: "%", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.deReverbDecayKey, title: "Decay", unit: "ms", defaultValue: 600, range: 150...2_500, step: 10, decimals: 0),
            EffectParamSpec(key: ClipEffect.deReverbToneKey, title: "Tone", unit: "", defaultValue: 0, range: -100...100, step: 1, decimals: 0),
        ]),
        EffectSpec(kind: ClipEffect.audioGainKind, title: "Gain", params: [
            EffectParamSpec(key: ClipEffect.audioGainKey, title: "Gain", unit: "dB", defaultValue: 0, range: -60...24, step: 0.1, decimals: 1),
        ]),
        // Input gain into a zero-latency peak limiter (the master limiter's code).
        EffectSpec(kind: ClipEffect.audioLimiterKind, title: "Limiter", params: [
            EffectParamSpec(key: ClipEffect.limiterInputKey, title: "Input Boost", unit: "dB", defaultValue: 0, range: 0...24, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.limiterCeilingKey, title: "Maximum Amplitude", unit: "dB", defaultValue: -1, range: -24...0, step: 0.1, decimals: 1),
        ]),
        // Downward gate: closes below Threshold, Range = how far it pulls the sound down while closed.
        EffectSpec(kind: ClipEffect.audioNoiseGateKind, title: "Noise Gate", params: [
            EffectParamSpec(key: ClipEffect.gateThresholdKey, title: "Threshold", unit: "dB", defaultValue: -40, range: -80...0, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.gateAttackKey, title: "Attack", unit: "ms", defaultValue: 1, range: 0.1...100, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.gateHoldKey, title: "Hold", unit: "ms", defaultValue: 0, range: 0...1_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.gateReleaseKey, title: "Release", unit: "ms", defaultValue: 100, range: 5...2_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.gateRangeKey, title: "Range", unit: "dB", defaultValue: 60, range: 0...80, step: 0.5, decimals: 1),
        ]),
        // Feedback delay (2 s line).
        EffectSpec(kind: ClipEffect.audioDelayKind, title: "Delay", params: [
            EffectParamSpec(key: ClipEffect.delayTimeKey, title: "Delay", unit: "ms", defaultValue: 350, range: 1...2_000, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.delayFeedbackKey, title: "Feedback", unit: "%", defaultValue: 35, range: 0...95, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.delayMixKey, title: "Mix", unit: "%", defaultValue: 30, range: 0...100, step: 1, decimals: 0),
        ]),
        // Freeverb-style room.
        EffectSpec(kind: ClipEffect.audioReverbKind, title: "Reverb", params: [
            EffectParamSpec(key: ClipEffect.reverbRoomSizeKey, title: "Room Size", unit: "%", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.reverbDampingKey, title: "Damping", unit: "%", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.reverbMixKey, title: "Mix", unit: "%", defaultValue: 25, range: 0...100, step: 1, decimals: 0),
        ]),
        // Hum notch bank: the root and its harmonics (mains 50 / 60 Hz or Custom = Frequency). Defaults chosen by us (the
        // reference sheets store ranges only): 50 Hz (EU mains), Q 10, -30 dB, 4 harmonics, slope 50 = equal depth.
        EffectSpec(kind: ClipEffect.audioDeHumKind, title: "De-Hum", params: [
            .choice(ClipEffect.deHumMainsKey, "Mains", ["Custom", "50 Hz", "60 Hz"], default: 1),
            EffectParamSpec(key: ClipEffect.deHumFreqKey, title: "Frequency", unit: "Hz", defaultValue: 50, range: 20...20_000, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.deHumSlopeKey, title: "Slope", unit: "", defaultValue: 50, range: 0...100, step: 1, decimals: 0),
            EffectParamSpec(key: ClipEffect.deHumQKey, title: "Q", unit: "", defaultValue: 1_000, range: 30...3_000, step: 10, decimals: 1,
                            displayScale: 0.01),
            EffectParamSpec(key: ClipEffect.deHumGainKey, title: "Gain", unit: "dB", defaultValue: -30, range: -80...5, step: 0.5, decimals: 1),
            EffectParamSpec(key: ClipEffect.deHumHarmonicsKey, title: "Harmonics", unit: "", defaultValue: 4, range: 1...8, step: 1, decimals: 0),
            .checkbox(ClipEffect.deHumListenKey, "Listen to Hum"),
        ]),
        // Rumble: a high-pass (Butterworth) with 12, 24 or 48 dB per octave.
        EffectSpec(kind: ClipEffect.audioLowCutKind, title: "Low Cut", params: [
            EffectParamSpec(key: ClipEffect.lowCutFreqKey, title: "Frequency", unit: "Hz", defaultValue: 80, range: 20...400, step: 1, decimals: 0),
            .choice(ClipEffect.lowCutSlopeKey, "Slope", ["12 dB/oct", "24 dB/oct", "48 dB/oct"], default: 1),
        ]),
        // Slow level ride: loud speech down, soft speech up, no lift below the speech floor (so no pumping on pauses).
        EffectSpec(kind: ClipEffect.audioDialogueLevelerKind, title: "Dialogue Leveler", params: [
            .choice(ClipEffect.levelerPresetKey, "Preset", AudioLevelerValues.presetTitles, default: 0),
            .checkbox(ClipEffect.levelerReduceLoudKey, "Reduce Loud Dialogue", on: true),
            .checkbox(ClipEffect.levelerLiftSoftKey, "Lift Soft Dialogue", on: true),
            .checkbox(ClipEffect.levelerBackgroundKey, "Background Reduction"),
            EffectParamSpec(key: ClipEffect.levelerOutputGainKey, title: "Output Gain", unit: "dB", defaultValue: 0, range: 0...6, step: 0.1, decimals: 1),
        ]),
    ] + voiceChainAudio + [enhanceSpeechSpec] + creatorAudio + pitchSpecs

    /// High Cut (low-pass, the Low Cut's counterpart for hiss and harsh highs), Stereo Width (mid/side) and Chorus.
    static let creatorAudio: [EffectSpec] = [
        EffectSpec(kind: ClipEffect.audioHighCutKind, title: "High Cut", params: [
            EffectParamSpec(key: ClipEffect.highCutFreqKey, title: "Frequency", unit: "Hz", defaultValue: 12_000, range: 1_000...20_000, step: 10, decimals: 0),
            .choice(ClipEffect.highCutSlopeKey, "Slope", ["12 dB/oct", "24 dB/oct", "48 dB/oct"], default: 1),
        ]),
        // Mid/side width: 0 = mono, 100 = as recorded, 200 = side doubled. Mono clips stay as they are.
        EffectSpec(kind: ClipEffect.audioStereoWidthKind, title: "Stereo Width", params: [
            EffectParamSpec(key: ClipEffect.stereoWidthKey, title: "Width", unit: "%", defaultValue: 150, range: 0...200, step: 1, decimals: 0),
        ]),
        // A short delay (about 15 ms) swept by a sine LFO, mixed with the dry sound; right channel runs a quarter cycle later.
        EffectSpec(kind: ClipEffect.audioChorusKind, title: "Chorus", params: [
            EffectParamSpec(key: ClipEffect.chorusRateKey, title: "Rate", unit: "Hz", defaultValue: 0.8, range: 0.1...10, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.chorusDepthKey, title: "Depth", unit: "ms", defaultValue: 3, range: 0...10, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.chorusMixKey, title: "Mix", unit: "%", defaultValue: 40, range: 0...100, step: 1, decimals: 0),
        ]),
        // A narrow cut for one tone (hum, whistle, ring). Width is the filter's Q: higher = narrower. Depth 0 = off.
        EffectSpec(kind: ClipEffect.audioNotchKind, title: "Notch", params: [
            EffectParamSpec(key: ClipEffect.notchFreqKey, title: "Frequency", unit: "Hz", defaultValue: 50, range: 20...20_000, step: 0.1, decimals: 1),
            EffectParamSpec(key: ClipEffect.notchQKey, title: "Q", unit: "", defaultValue: 1_000, range: 50...5_000, step: 10, decimals: 1,
                            displayScale: 0.01),
            EffectParamSpec(key: ClipEffect.notchDepthKey, title: "Depth", unit: "dB", defaultValue: 30, range: 0...60, step: 0.5, decimals: 1),
        ]),
        // Ten fixed octave bands, each -12...+12 dB (0 = untouched), and an output gain.
        EffectSpec(kind: ClipEffect.audioGraphicEQKind, title: "Graphic EQ",
                   params: zip(ClipEffect.graphicEQBandKeys, AudioGraphicEQValues.bandTitles).map { key, title in
            EffectParamSpec(key: key, title: title, unit: "dB", defaultValue: 0, range: -12...12, step: 0.1, decimals: 1)
        } + [EffectParamSpec(key: ClipEffect.graphicEQOutputKey, title: "Output gain", unit: "dB", defaultValue: 0, range: -24...24, step: 0.1, decimals: 1)]),
    ]
}

/// Graphic EQ values at one instant: gain per octave band (`bandHz`, always ten) and the output gain.
public struct AudioGraphicEQValues: Sendable, Hashable {
    public static let bandHz: [Double] = [31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    public static let bandTitles = ["31.5 Hz", "63 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"]
    /// Constant Q of every band (about one octave wide).
    public static let q = 1.41
    /// The ten gains in fixed storage (no heap), so building the value per block does not allocate.
    private var lo = SIMD8<Double>(repeating: 0), hi = SIMD2<Double>(repeating: 0)
    public var outputDB: Double
    public init(outputDB: Double = 0) { self.outputDB = outputDB }
    /// Convenience for tests and presets (allocates the array you pass); missing bands are 0, extra ones are ignored.
    public init(gainsDB: [Double], outputDB: Double = 0) {
        self.outputDB = outputDB
        for i in 0..<min(gainsDB.count, 10) { self[i] = gainsDB[i] }
    }
    /// Gain of band `i` (0...9) in dB; reads of an index outside the range give 0, writes are ignored.
    public subscript(i: Int) -> Double {
        get { i >= 0 && i < 8 ? lo[i] : i == 8 || i == 9 ? hi[i - 8] : 0 }
        set { if i >= 0 && i < 8 { lo[i] = newValue } else if i == 8 || i == 9 { hi[i - 8] = newValue } }
    }
    public static let flat = AudioGraphicEQValues()
}

/// Values of the three-band EQ at one instant.
public struct AudioEQValues: Sendable, Hashable {
    public var lowGainDB: Double, lowHz: Double
    public var midGainDB: Double, midHz: Double, midQ: Double
    public var highGainDB: Double, highHz: Double
    public init(lowGainDB: Double, lowHz: Double, midGainDB: Double, midHz: Double, midQ: Double, highGainDB: Double, highHz: Double) {
        self.lowGainDB = lowGainDB; self.lowHz = lowHz; self.midGainDB = midGainDB; self.midHz = midHz; self.midQ = midQ
        self.highGainDB = highGainDB; self.highHz = highHz
    }
}

/// Dialogue Leveler values: preset index (see `presetTitles`), toggles, output gain 0...6 dB.
public struct AudioLevelerValues: Sendable, Hashable {
    public static let presetTitles = ["Allow wider dynamics", "More lift for low levels", "Lift soft whispery sources", "Optimize moderate levels"]
    public var preset: Int, reduceLoud: Bool, liftSoft: Bool, background: Bool, outputGainDB: Double
    public init(preset: Int, reduceLoud: Bool, liftSoft: Bool, background: Bool, outputGainDB: Double) {
        self.preset = preset; self.reduceLoud = reduceLoud; self.liftSoft = liftSoft; self.background = background
        self.outputGainDB = outputGainDB
    }
    /// Per preset (chosen by us, the reference only names the presets): target level dBFS, most down / up in dB, how much of
    /// the gap to the target is closed (0...1), speech floor dBFS (below it the gain is held, never lifted).
    public var params: (targetDB: Double, maxDownDB: Double, maxUpDB: Double, strength: Double, floorDB: Double) {
        switch preset {
        case 1: (-20, 6, 12, 0.8, -50)
        case 2: (-22, 4, 15, 0.8, -58)
        case 3: (-20, 9, 9, 0.9, -50)
        default: (-20, 6, 6, 0.5, -50)
        }
    }
}

/// One audio effect evaluated at an instant: what the DSP chain runs.
public enum AudioFXStage: Sendable, Hashable {
    /// Denoiser wet/dry 0...1.
    case noiseReduction(amount: Double)
    case eq(AudioEQValues)
    case compressor(thresholdDB: Double, ratio: Double, attackMs: Double, releaseMs: Double, makeupDB: Double)
    /// Most reduction of the highs in dB; sensitivity 0...1 (1 = reacts earliest).
    /// `frequencyHz` is the sibilance center, `range` 0 Narrow / 1 Wide / 2 All HF, `speed` 0 Fast / 1 Medium / 2 Slow, `listen` = only the
    /// reduced band. The defaults are the effect's behavior before these were added.
    case deEsser(reductionDB: Double, sensitivity: Double, frequencyHz: Double = 7_000, range: Int = 1, speed: Int = 1, listen: Bool = false)
    /// Late-reverb suppression: amount 0...1, decay = assumed reverb time in seconds, tone -1...1 (positive = more reduction in the highs).
    case deReverb(amount: Double, decaySeconds: Double, tone: Double)
    case gain(dB: Double)
    case limiter(inputDB: Double, ceilingDB: Double)
    /// Gate: closes below the threshold (dB), pulls the sound down by `rangeDB` while closed.
    case noiseGate(thresholdDB: Double, attackMs: Double, releaseMs: Double, rangeDB: Double, holdMs: Double = 0)
    /// Delay line: time in ms, feedback and mix 0...1.
    case delay(timeMs: Double, feedback: Double, mix: Double)
    /// Reverb: room size, damping and mix 0...1.
    case reverb(roomSize: Double, damping: Double, mix: Double)
    case multiband(AudioMultibandValues)
    case parametricEQ(AudioParametricEQValues)
    /// Notch bank at `frequencyHz` and its harmonics: Q, depth, count, slope 0...1 (0.5 = equal depth), listen = the hum only.
    case deHum(frequencyHz: Double, q: Double, gainDB: Double, harmonics: Int, slope: Double, listen: Bool)
    /// High-pass: corner Hz, order 1...3 (12, 24, 48 dB/oct).
    case lowCut(frequencyHz: Double, order: Int)
    case dialogueLeveler(AudioLevelerValues)
    /// Low-pass: corner Hz, order 1...3 (12, 24, 48 dB/oct).
    case highCut(frequencyHz: Double, order: Int)
    /// Mid/side width, 0 (mono) ... 2 (side doubled); 1 = unchanged.
    case stereoWidth(width: Double)
    /// Modulated short delay: LFO rate Hz, sweep depth ms, mix 0...1.
    case chorus(rateHz: Double, depthMs: Double, mix: Double)
    /// Narrow cut: center Hz, Q, depth in dB (0 = bypass).
    case notch(frequencyHz: Double, q: Double, depthDB: Double)
    /// Ten octave bands in dB plus the output gain.
    case graphicEQ(AudioGraphicEQValues)
    /// One-click speech clean-up (`AudioEnhanceSpeechValues.recipe` drives the repair stages).
    case enhanceSpeech(AudioEnhanceSpeechValues)
    /// Semitones (cents included); `preserveFormants` keeps the spectral envelope where it was.
    case pitchShift(semitones: Double, preserveFormants: Bool)
    /// `voice` = index into `AudioDisguiseValues.voiceTitles`, `at` = clip-local position (drives the modulation).
    case disguiseVoice(voice: Int, at: Time)
}

/// One audio effect of a clip at an instant. A disabled one stays in the chain (its state and latency are kept) but passes
/// the sound through.
public struct AudioFXStep: Sendable, Hashable {
    public var id: ClipEffect.ID
    public var enabled: Bool
    public var stage: AudioFXStage
    public init(id: ClipEffect.ID, enabled: Bool, stage: AudioFXStage) { self.id = id; self.enabled = enabled; self.stage = stage }
}

/// Which effects a clip's chain holds, in order: a change rebuilds the DSP chain, parameter changes do not.
public struct AudioFXSlot: Sendable, Hashable {
    public var id: ClipEffect.ID
    public var kind: String
    public init(id: ClipEffect.ID, kind: String) { self.id = id; self.kind = kind }
}

extension ClipEffect {
    /// This audio effect at clip-local `t`, values clamped to the catalog ranges; nil for any other kind.
    public func audioStage(atLocal t: Time) -> AudioFXStage? {
        func v(_ k: String) -> Double { scalar(k, atLocal: t) }
        switch kind {
        case Self.audioNoiseReductionKind: return .noiseReduction(amount: v(Self.noiseAmountReductionKey) / 100)
        case Self.audioEQKind:
            return .eq(AudioEQValues(lowGainDB: v(Self.eqLowGainKey), lowHz: v(Self.eqLowFreqKey),
                                     midGainDB: v(Self.eqMidGainKey), midHz: v(Self.eqMidFreqKey), midQ: v(Self.eqMidQKey),
                                     highGainDB: v(Self.eqHighGainKey), highHz: v(Self.eqHighFreqKey)))
        case Self.audioCompressorKind:
            return .compressor(thresholdDB: v(Self.compThresholdKey), ratio: v(Self.compRatioKey), attackMs: v(Self.compAttackKey),
                               releaseMs: v(Self.compReleaseKey), makeupDB: v(Self.compMakeupKey))
        case Self.audioDeEsserKind:
            return .deEsser(reductionDB: v(Self.deEssReductionKey), sensitivity: v(Self.deEssSensitivityKey) / 100,
                            frequencyHz: v(Self.deEssFrequencyKey), range: Int(v(Self.deEssRangeKey).rounded()),
                            speed: Int(v(Self.deEssSpeedKey).rounded()), listen: v(Self.deEssListenKey) >= 0.5)
        case Self.audioDeReverbKind:
            return .deReverb(amount: v(Self.deReverbAmountKey) / 100, decaySeconds: v(Self.deReverbDecayKey) / 1000, tone: v(Self.deReverbToneKey) / 100)
        case Self.audioGainKind: return .gain(dB: v(Self.audioGainKey))
        case Self.audioLimiterKind: return .limiter(inputDB: v(Self.limiterInputKey), ceilingDB: v(Self.limiterCeilingKey))
        case Self.audioNoiseGateKind:
            return .noiseGate(thresholdDB: v(Self.gateThresholdKey), attackMs: v(Self.gateAttackKey), releaseMs: v(Self.gateReleaseKey),
                              rangeDB: v(Self.gateRangeKey), holdMs: v(Self.gateHoldKey))
        case Self.audioDelayKind:
            return .delay(timeMs: v(Self.delayTimeKey), feedback: v(Self.delayFeedbackKey) / 100, mix: v(Self.delayMixKey) / 100)
        case Self.audioReverbKind:
            return .reverb(roomSize: v(Self.reverbRoomSizeKey) / 100, damping: v(Self.reverbDampingKey) / 100, mix: v(Self.reverbMixKey) / 100)
        case Self.audioDeHumKind:
            let mains = Int(v(Self.deHumMainsKey).rounded())
            return .deHum(frequencyHz: mains == 1 ? 50 : mains == 2 ? 60 : v(Self.deHumFreqKey), q: v(Self.deHumQKey) / 100,
                          gainDB: v(Self.deHumGainKey), harmonics: Int(v(Self.deHumHarmonicsKey).rounded()),
                          slope: v(Self.deHumSlopeKey) / 100, listen: v(Self.deHumListenKey) >= 0.5)
        case Self.audioLowCutKind: return .lowCut(frequencyHz: v(Self.lowCutFreqKey), order: Int(v(Self.lowCutSlopeKey).rounded()) + 1)
        case Self.audioDialogueLevelerKind:
            return .dialogueLeveler(AudioLevelerValues(preset: Int(v(Self.levelerPresetKey).rounded()), reduceLoud: v(Self.levelerReduceLoudKey) >= 0.5,
                                                       liftSoft: v(Self.levelerLiftSoftKey) >= 0.5, background: v(Self.levelerBackgroundKey) >= 0.5,
                                                       outputGainDB: v(Self.levelerOutputGainKey)))
        case Self.audioHighCutKind: return .highCut(frequencyHz: v(Self.highCutFreqKey), order: Int(v(Self.highCutSlopeKey).rounded()) + 1)
        case Self.audioStereoWidthKind: return .stereoWidth(width: v(Self.stereoWidthKey) / 100)
        case Self.audioChorusKind: return .chorus(rateHz: v(Self.chorusRateKey), depthMs: v(Self.chorusDepthKey), mix: v(Self.chorusMixKey) / 100)
        case Self.audioNotchKind: return .notch(frequencyHz: v(Self.notchFreqKey), q: v(Self.notchQKey) / 100, depthDB: v(Self.notchDepthKey))
        case Self.audioGraphicEQKind:
            var g = AudioGraphicEQValues(outputDB: v(Self.graphicEQOutputKey))
            for i in 0..<10 { g[i] = v(Self.graphicEQBandKeys[i]) }
            return .graphicEQ(g)
        case Self.audioMultibandKind: return .multiband(multibandValues(atLocal: t))
        case Self.audioParametricEQKind: return .parametricEQ(parametricEQValues(atLocal: t))
        case Self.audioEnhanceSpeechKind:
            return .enhanceSpeech(AudioEnhanceSpeechValues(amount: v(Self.enhanceAmountKey) / 100, preset: Int(v(Self.enhancePresetKey).rounded())))
        default: return pitchStage(atLocal: t)
        }
    }
}

extension Clip {
    /// An audio clip with at least one audio effect (switched off ones count).
    public var hasAudioEffects: Bool { kind == .audio && effects.contains { $0.isAudio } }

    /// The audio effects of this clip in processing order (empty for video clips).
    public var audioFXLayout: [AudioFXSlot] {
        guard kind == .audio else { return [] }
        return effects.filter { $0.isAudio && EffectCatalog.spec(for: $0.kind) != nil }.map { AudioFXSlot(id: $0.id, kind: $0.kind) }
    }

    /// Every audio effect at clip-local `t`, in processing order (same order and ids as `audioFXLayout`).
    public func audioFXSteps(atLocal t: Time) -> [AudioFXStep] {
        var out: [AudioFXStep] = []
        audioFXSteps(atLocal: t, into: &out)
        return out
    }

    /// `audioFXSteps(atLocal:)` into a reused array (no allocation once it has the capacity): the mixer calls it per block.
    public func audioFXSteps(atLocal t: Time, into out: inout [AudioFXStep]) {
        out.removeAll(keepingCapacity: true)
        guard kind == .audio else { return }
        for e in effects { if let s = e.audioStage(atLocal: t) { out.append(AudioFXStep(id: e.id, enabled: e.enabled, stage: s)) } }
    }

    /// Same effects in the same order as `layout` (a DSP chain built for it still fits). Does not allocate.
    public func audioFXLayoutMatches(_ layout: [AudioFXSlot]) -> Bool {
        guard kind == .audio else { return layout.isEmpty }
        var i = 0
        for e in effects where e.isAudio && EffectCatalog.spec(for: e.kind) != nil {
            guard i < layout.count, layout[i].id == e.id, layout[i].kind == e.kind else { return false }
            i += 1
        }
        return i == layout.count
    }
}

extension Project {
    /// Any timeline holds an audio clip with audio effects: the file must be v39.
    public var containsAudioEffects: Bool {
        timelines.contains { $0.tracks.contains { $0.clips.contains(where: \.hasAudioEffects) } }
    }
}

/// De-Esser option titles (stored as the choice index, never reorder).
public enum AudioDeEsserValues {
    public static let rangeTitles = ["Narrow", "Wide", "All HF"]
    public static let speedTitles = ["Fast", "Medium", "Slow"]
}

/// De-Reverb constants shared by the DSP and the latency the playback and export paths compensate.
public enum AudioDeReverbValues {
    /// One analysis window at 48 kHz (the stage delays the sound by exactly this).
    public static let latencySamples = 1_024
}

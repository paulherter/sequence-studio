#if canImport(SQAudioFX)
import Testing
import Foundation
import SQCore
import SQAudioFX
@testable import SQPremiereImport

// Premiere effect presets (.prfpset) -> SQ effect presets. Fixture: a synthetic preset file with the structure of a real
// Premiere export (invented preset names and parameter values). Each test applies the imported preset
// to a clip and compares the result with the values Premiere stored.
@Suite struct PresetImportTests {
    static let ticksPerFrame: Int64 = 8_475_667_200     // 29.97 fps

    static func fixture() throws -> [PRPreset] {
        guard let url = Bundle.module.url(forResource: "presets.prfpset", withExtension: "gz", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try PRPresetReader.read(url: url)
    }

    static let cached = Result { PRPresetMapper.map(try fixture()) }
    static func imported() throws -> PRPresetImport { try cached.get() }

    static func preset(_ name: String) throws -> PRMappedPreset {
        try #require(try imported().presets.first { $0.name == name }, "\(name) not imported")
    }

    /// A video clip of `seconds` with the preset applied.
    static func applied(_ name: String, seconds: Int64 = 10, kind: TrackKind = .video) throws -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Time(seconds, 1)), start: .zero)
        c.applyPreset(try preset(name).preset)
        return c
    }

    static func t(_ ticks: Int64) -> Time { PRTicks.time(ticks) }
    static func frames(_ n: Int64) -> Time { t(n * ticksPerFrame) }

    func keys(_ p: AnimatedProperty<Double>?) -> [(Time, Double)] { (p?.track.keys ?? []).map { ($0.time, $0.value) } }

    func effect(_ c: Clip, _ kind: String) throws -> ClipEffect { try #require(c.effects.first { $0.kind == kind }) }

    /// Writes the import summary of the real preset file at `SQ_PRFPSET` to `SQ_PRFPSET_DIAG` when both are set.
    @Test func diagnostics() throws {
        let env = ProcessInfo.processInfo.environment
        guard let src = env["SQ_PRFPSET"], let dst = env["SQ_PRFPSET_DIAG"] else { return }
        let r = PRPresetMapper.map(try PRPresetReader.read(url: URL(fileURLWithPath: src)))
        var lines = r.presets.map { "IMPORT \($0.name) [\($0.path)] \($0.preset.anchor) " + $0.notes.joined(separator: "; ") }
        lines += r.skipped.map { "SKIP \($0.path): \($0.reason)" }
        lines.append(r.report.summary)
        try lines.joined(separator: "\n").write(toFile: dst, atomically: true, encoding: .utf8)
    }

    // MARK: Reader

    @Test func readerFindsTheTreeAndSkipsNothingSilently() throws {
        let ps = try Self.fixture()
        let paths = ps.map(\.path)
        #expect(paths.contains("Presets / Voice Clean (v1)"))
        #expect(paths.contains("Demo Presets / Start & End / Outro IN"))
        let ntg = try #require(ps.first { $0.name == "Voice Clean (v1)" })
        // One instance per channel type (mono, stereo, 5.1) of each of the three effects.
        #expect(ntg.filters.count == 9 && Set(ntg.filters.compactMap(\.channelType)) == [0, 1, 2])
        let end = try #require(ps.first { $0.name == "Outro IN" })
        #expect(end.filters.map(\.type) == [2, 2] && end.filters.map(\.component.matchName) == ["AE.ADBE Geometry2", "AE.ADBE Gaussian Blur 2"])
    }

    @Test func importListsEveryPresetOnceWithItsAnchor() throws {
        let r = try Self.imported()
        let names = r.presets.map(\.name)
        #expect(Set(names) == ["Voice Clean (v1)", "Backdrop Blur", "Backdrop Blur - Fade In", "Mono", "Caption Pop", "Soft Fade In",
                               "Soft Fade Out", "Soft Shadow", "Outro IN", "Outro OUT", "Intro IN", "Intro OUT"])
        #expect(names.count == Set(names).count, "the two identical Shadow presets import once")
        func anchor(_ n: String) -> EffectPreset.Anchor? { r.presets.first { $0.name == n }?.preset.anchor }
        #expect(anchor("Soft Fade In") == .start && anchor("Soft Fade Out") == .end && anchor("Outro IN") == .end)
        #expect(anchor("Outro OUT") == .end && anchor("Intro OUT") == .start && anchor("Caption Pop") == .start)
        // Saved as "Scale" in Premiere: stretches with the clip.
        #expect(anchor("Intro IN") == .stretch && anchor("Backdrop Blur") == .stretch)
    }

    @Test func ignoredFoldersAndUnmappableEffectsAreSkippedWithAReason() throws {
        let blur = try #require(try Self.fixture().first { $0.name == "Backdrop Blur" })
        var zoom = blur; zoom.name = "BOT"; zoom.folders = ["Presets"]; zoom.aliasFolders = [["Demo", "Skipped Folder", "Zoom In & Out"]]
        var lens = blur; lens.name = "Lens"
        lens.filters[0].component = PRComponent(matchName: "PR.ADBE Lens Distortion", displayName: "Lens Distortion", params: [], isAudio: false)
        let r = PRPresetMapper.map([zoom, lens, blur], ignoring: ["Skipped Folder"])
        #expect(r.presets.map(\.name) == ["Backdrop Blur"])
        #expect(r.skipped.map(\.reason) == ["ignored folder", "no SQ equivalent: PR.ADBE Lens Distortion (Lens Distortion)"])
    }

    // MARK: Basic

    @Test func backdropBlurIsAStaticBlurWithRepeatedEdges() throws {
        let c = try Self.applied("Backdrop Blur")
        let e = try effect(c, ClipEffect.gaussianBlurKind)
        #expect(e.parameters[ClipEffect.blurrinessKey]?.value == 150 && e.parameters[ClipEffect.blurrinessKey]?.isAnimated == false)
        #expect(e.parameters[ClipEffect.repeatEdgePixelsKey]?.value == 1)
        #expect(c.animation == ClipAnimation(), "no Motion change")
    }

    @Test func backdropBlurFadeInRampsFrom0To150AtTheStart() throws {
        for seconds: Int64 in [3, 30] {
            let c = try Self.applied("Backdrop Blur - Fade In", seconds: seconds)
            let k = keys(try effect(c, ClipEffect.gaussianBlurKind).parameters[ClipEffect.blurrinessKey])
            #expect(k.map(\.0) == [Self.frames(1), Self.frames(17)] && k.map(\.1) == [0, 150])
        }
    }

    @Test func blackAndWhiteSetsSaturationToZero() throws {
        let c = try Self.applied("Mono")
        let e = try effect(c, ClipEffect.colorKind)
        let grade = e.colorEffect(atLocal: nil, id: 1)
        #expect(grade.basic.saturation == 0 && grade.basic.exposure == 0 && grade.basic.contrast == 0)
        #expect(!c.effects.contains { $0.kind == ClipEffect.sharpenKind }, "Lumetri sharpen 0 adds nothing")
    }

    @Test func fadeInAnchorsToTheClipStart() throws {
        for seconds: Int64 in [2, 20] {
            let c = try Self.applied("Soft Fade In", seconds: seconds)
            let k = keys(c.animation.opacity)
            #expect(k.map(\.0) == [.zero, Self.frames(7)] && k.map(\.1) == [0, 1])
        }
    }

    @Test func fadeOutAnchorsToTheClipEnd() throws {
        for seconds: Int64 in [2, 20] {
            let c = try Self.applied("Soft Fade Out", seconds: seconds)
            let end = Time(seconds, 1)
            let k = keys(c.animation.opacity)
            #expect(k.map(\.0) == [end - Self.frames(7), end] && k.map(\.1) == [1, 0])
        }
    }

    @Test func shadowMatchesTheStoredDropShadow() throws {
        let e = try effect(try Self.applied("Soft Shadow"), ClipEffect.dropShadowKind)
        #expect(e.parameters[ClipEffect.shadowOpacityKey]?.value == 100)          // 255 of 255
        #expect(e.parameters[ClipEffect.shadowDirectionKey]?.value == 135 && e.parameters[ClipEffect.shadowDistanceKey]?.value == 0)
        #expect(e.parameters[ClipEffect.shadowSoftnessKey]?.value == 120 && (e.parameters[ClipEffect.shadowOnlyKey]?.value ?? 0) == 0)
        let col = try #require(e.colors[ClipEffect.shadowColorKey]?.value)
        #expect(col.red == 0 && col.green == 0 && col.blue == 0)
    }

    @Test func captionAnimationPopsTheScaleAroundTheCaptionLine() throws {
        let c = try Self.applied("Caption Pop")
        let e = try effect(c, ClipEffect.transformKind)
        let k = keys(e.parameters[ClipEffect.stageScaleKey])
        #expect(k.map(\.0) == [.zero, Self.frames(3), Self.frames(4)] && k.map(\.1) == [85, 108, 100])
        // Anchor and position 0.5 : 0.70677 of a 1080x1920 frame: pivot on the caption line, no shift.
        #expect(abs((e.parameters[ClipEffect.stageAnchorYKey]?.value ?? 0) - 0.20677083730697632 * 1920) < 1e-6)
        #expect(e.parameters[ClipEffect.stageAnchorXKey]?.value == 0)
        #expect(e.parameters[ClipEffect.stagePositionXKey]?.value == 0 && e.parameters[ClipEffect.stagePositionYKey]?.value == 0)
        #expect(try Self.preset("Caption Pop").notes.contains { $0.contains("Transform anchor in a preset") })
    }

    // MARK: Start & End

    /// Clip-end-relative time of a key stored at `ticks` in a preset saved from `inPoint`...`outPoint`, on a clip ending at `end`.
    static func fromEnd(_ ticks: Int64, in inPoint: Int64, out outPoint: Int64, end: Time) -> Time {
        end + t(ticks - inPoint) - t(outPoint - inPoint)
    }

    @Test func videoEndInAnchorsToTheClipEnd() throws {
        let inPoint: Int64 = 39_547_463_155_200, out: Int64 = 40_496_737_881_600
        for seconds: Int64 in [5, 60] {
            let c = try Self.applied("Outro IN", seconds: seconds)
            let end = Time(seconds, 1)
            func at(_ ticks: Int64) -> Time { Self.fromEnd(ticks, in: inPoint, out: out, end: end) }
            let scale = keys(try effect(c, ClipEffect.transformKind).parameters[ClipEffect.stageScaleKey])
            #expect(scale.map(\.0) == [at(40_340_760_304_621), at(40_505_213_548_800)] && scale.map(\.1) == [100, 112])
            // About 0.61 s before the end, up to one frame past it (as saved).
            #expect(abs((end - scale[0].0).seconds - 0.614) < 0.001 && abs((scale[1].0 - end - Self.frames(1)).seconds) < 1e-5)
            let blur = keys(try effect(c, ClipEffect.gaussianBlurKind).parameters[ClipEffect.blurrinessKey])
            #expect(blur.map(\.0) == [at(40_462_835_212_800), at(40_505_213_548_800)] && blur.map(\.1) == [0, 30])
            #expect(abs((end - blur[0].0 - Self.frames(4)).seconds) < 1e-5)
        }
        // Bezier out of the first scale key (Premiere's ease), kept.
        let c = try Self.applied("Outro IN")
        #expect(try effect(c, ClipEffect.transformKind).parameters[ClipEffect.stageScaleKey]?.track.keys.first?.interpolation == .bezier)
    }

    @Test func videoEndOutAnchorsToTheClipEnd() throws {
        let inPoint: Int64 = 39_547_463_155_200, out: Int64 = 40_861_191_571_200
        for seconds: Int64 in [5, 60] {
            let c = try Self.applied("Outro OUT", seconds: seconds)
            let end = Time(seconds, 1)
            let scale = keys(try effect(c, ClipEffect.transformKind).parameters[ClipEffect.stageScaleKey])
            #expect(scale.map(\.0) == [Self.fromEnd(40_696_738_327_021, in: inPoint, out: out, end: end), end] && scale.map(\.1) == [112, 100])
            let blur = keys(try effect(c, ClipEffect.gaussianBlurKind).parameters[ClipEffect.blurrinessKey])
            #expect(blur.map(\.0) == [Self.fromEnd(40_818_813_235_200, in: inPoint, out: out, end: end), end] && blur.map(\.1) == [0, 30])
            #expect(abs((end - blur[0].0 - Self.frames(5)).seconds) < 1e-5)
        }
    }

    @Test func videoStartInStretchesLikePremieresScalePreset() throws {
        let inPoint: Int64 = 39_547_463_155_200, ref = Self.t(40_496_737_881_600 - inPoint)
        let p = try Self.preset("Intro IN").preset
        #expect(p.referenceDuration == ref)
        // On a clip as long as the saved one the keys land where Premiere stored them.
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: ref), start: .zero)
        c.applyPreset(p)
        let scale = keys(try effect(c, ClipEffect.transformKind).parameters[ClipEffect.stageScaleKey])
        #expect(scale.map(\.0) == [.zero, Self.t(39_915_838_422_160 - inPoint)] && scale.map(\.1) == [100, 112])
        let blur = keys(try effect(c, ClipEffect.gaussianBlurKind).parameters[ClipEffect.blurrinessKey])
        #expect(blur.map(\.0) == [.zero, Self.t(39_642_390_627_840 - inPoint)] && blur.map(\.1) == [30, 0])
        // Twice as long: twice as slow (Premiere's Scale type).
        var d = Clip(name: "d", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: ref + ref), start: .zero)
        d.applyPreset(p)
        let blur2 = keys(try effect(d, ClipEffect.gaussianBlurKind).parameters[ClipEffect.blurrinessKey])
        #expect(blur2.map(\.0) == [.zero, Self.t(39_642_390_627_840 - inPoint) + Self.t(39_642_390_627_840 - inPoint)])
    }

    @Test func videoStartOutAnchorsToTheClipStart() throws {
        let inPoint: Int64 = 39_547_463_155_200
        for seconds: Int64 in [5, 60] {
            let c = try Self.applied("Intro OUT", seconds: seconds)
            let scale = keys(try effect(c, ClipEffect.transformKind).parameters[ClipEffect.stageScaleKey])
            #expect(scale.map(\.0) == [.zero, Self.t(39_711_916_399_379 - inPoint)] && scale.map(\.1) == [112, 100])
            let blur = keys(try effect(c, ClipEffect.gaussianBlurKind).parameters[ClipEffect.blurrinessKey])
            #expect(blur.map(\.0) == [.zero, Self.frames(5)] && blur.map(\.1) == [30, 0])
        }
    }

    // MARK: Audio

    @Test func ntgIndoorUsesTheStereoInstanceAndAppliesToAudioClips() throws {
        let m = try Self.preset("Voice Clean (v1)")
        #expect(m.preset.isAudioOnly && m.preset.trackKind == .audio)
        #expect(m.preset.effects.map(\.kind) == [ClipEffect.audioParametricEQKind, ClipEffect.audioMultibandKind, ClipEffect.audioNoiseReductionKind])
        let c = try Self.applied("Voice Clean (v1)", kind: .audio)
        let eq = try effect(c, ClipEffect.audioParametricEQKind)
        let k = ClipEffect.peqKey
        func v(_ key: String) -> Double { eq.parameters[key]?.value ?? -999 }
        #expect(abs(v(k("b4", "Freq")) - 3_000) < 0.5 && abs(v(k("b4", "Q")) - 0.75) < 0.001 && abs(v(k("b4", "Gain")) - 1) < 0.001)
        #expect(abs(v(k("b5", "Freq")) - 7_000) < 0.5 && abs(v(k("b5", "Q")) - 0.875) < 0.001 && abs(v(k("b5", "Gain")) + 1) < 0.001)
        #expect(v(k("b1", "On")) == 0 && v(k("b4", "On")) == 1 && v(k("hp", "On")) == 1 && abs(v(k("hp", "Freq")) - 79.8) < 0.1)
        let nr = try effect(c, ClipEffect.audioNoiseReductionKind)
        #expect(abs((nr.parameters[ClipEffect.noiseAmountReductionKey]?.value ?? 0) - 5) < 1e-6)
        let mb = try effect(c, ClipEffect.audioMultibandKind)
        #expect(abs((mb.parameters[ClipEffect.mbThresholdKey(1)]?.value ?? 0) - (0.7 * 60 - 60)) < 0.01)
        #expect(abs((mb.parameters[ClipEffect.mbCrossoverKey(1)]?.value ?? 0) - (20 + 0.005856 * 19_980)) < 1)
        #expect(mb.parameters[ClipEffect.mbLimiterOnKey]?.value == 1)
    }

    /// Synthetic speech through the imported chain (the clip chain playback and export run): never over the limiter
    /// margin, no flat tops, a sane level change.
    @Test func ntgIndoorOnSpeechStaysUnderTheCeiling() throws {
        let c = try Self.applied("Voice Clean (v1)", kind: .audio)
        let mb = try effect(c, ClipEffect.audioMultibandKind)
        let margin = mb.parameters[ClipEffect.mbLimiterMarginKey]?.value ?? -0.1
        for lufs in [-24.0, -16] {
            let x = Speech.make(seconds: 6, targetLUFS: lufs)
            let block = 512
            let chain = try ClipAudioFXChain(layout: c.audioFXLayout, channelCount: 2, maxFrames: block)
            var y: [[Float]] = [[], []]
            var i = 0
            while i < x[0].count {
                let n = min(block, x[0].count - i)
                var b = x.map { Array($0[i..<i + n]) }
                chain.process(&b, steps: c.audioFXSteps(atLocal: Time(Int64(i), 48_000)))
                y[0] += b[0]; y[1] += b[1]
                i += n
            }
            let peak = Double(y.flatMap { $0 }.map { abs($0) }.max() ?? 0)
            let peakDB = 20 * log10(max(peak, 1e-12))
            #expect(y.allSatisfy { $0.allSatisfy(\.isFinite) })
            #expect(peakDB <= margin + 1e-3, "peak \(peakDB) dBFS over the limiter margin \(margin)")
            #expect(Speech.flatRuns(y, ceilingDB: margin) == 0, "hard clipping")
            let gain = Speech.lufs(y) - Speech.lufs(x)
            #expect(gain > -12 && gain < 12, "level change \(gain) dB")
        }
    }
}

extension Time {
    /// Test readout only (the model never uses Double time).
    var seconds: Double { Double(value) / Double(timescale) }
}

/// Speech-like stereo test signal (pulse train through formants, syllables, sibilants, pauses), as in SQAudioFX's
/// broadcast safety tests.
enum Speech {
    static func lufs(_ x: [[Float]]) -> Double {
        var m = LoudnessMeter(sampleRate: 48_000, channelCount: x.count)
        m.process(x)
        return m.integrated
    }

    static func make(seconds: Double, targetLUFS: Double) -> [[Float]] {
        let fs = 48_000.0, n = Int(seconds * fs)
        var seed: UInt64 = 11
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) * 2 - 1 }
        var y = [Float](repeating: 0, count: n)
        var r = [(0.0, 0.0), (0.0, 0.0), (0.0, 0.0)]
        let vowels: [[Double]] = [[730, 1090, 2440], [270, 2290, 3010], [530, 1840, 2480], [570, 840, 2410], [300, 870, 2240]]
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / fs
            let syl = Int(t * 4), inSyl = t * 4 - Double(syl)
            let env = syl % 9 == 8 ? 0 : pow(sin(.pi * inSyl), 0.6) * (0.6 + 0.4 * sin(Double(syl) * 1.7))
            phase += (120 + 25 * sin(2 * .pi * 0.5 * t) + 10 * sin(Double(syl))) / fs
            var src = 0.0
            if phase >= 1 { phase -= 1; src = 1 }
            let v = vowels[syl % vowels.count]
            var s = 0.0
            for k in 0..<3 {
                let bw = 80.0 + 40 * Double(k), w = 2 * .pi * v[k] / fs, rr = exp(-.pi * bw / fs)
                let o = src * (1 - rr) * 6 + 2 * rr * cos(w) * r[k].0 - rr * rr * r[k].1
                r[k].1 = r[k].0; r[k].0 = o
                s += o / Double(k + 1)
            }
            let z = noise()
            y[i] = Float(syl % 5 == 2 && inSyl > 0.6 ? z * 0.25 : (env == 0 ? z * 0.0005 : s * env))
        }
        let stereo = [y, y]
        let g = Float(pow(10, (targetLUFS - lufs(stereo)) / 20))
        return stereo.map { $0.map { $0 * g } }
    }

    /// Runs of >= 3 consecutive samples within 0.001 dB of `ceilingDB` (flat tops).
    static func flatRuns(_ y: [[Float]], ceilingDB: Double) -> Int {
        let c = Float(pow(10, (ceilingDB - 0.001) / 20))
        var runs = 0
        for ch in y {
            var run = 0
            for s in ch { if abs(s) >= c { run += 1 } else { if run >= 3 { runs += 1 }; run = 0 } }
            if run >= 3 { runs += 1 }
        }
        return runs
    }
}
#endif

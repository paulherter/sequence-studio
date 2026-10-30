#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
#endif
import Foundation
import SQAudioFX

/// What the audio pre-flight found in the mix of a sequence.
public struct AudioAnalysis: Sendable, Equatable {
    public var integratedLUFS: Double
    public var truePeakDB: Double
    /// Samples at or above full scale (0 dBFS): they are cut flat when the file is written.
    public var clippedSamples: Int
    /// Stretches of at least one second below -60 dBFS, in every channel.
    public var gapCount: Int
    public var longestGapSeconds: Double
    /// Stereo whose two channels are identical all the way through (a mono recording on both sides).
    public var isDualMono: Bool
    public var durationSeconds: Double
    /// EBU R128 loudness range in LU; nil for mixes under 3 s or without sound.
    public var loudnessRangeLU: Double? = nil
    public var isSilent: Bool { !integratedLUFS.isFinite }
}

/// One line of the audio check: a pass, a warning or a failure against the delivery target.
public struct AudioFinding: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case silent, clipping, loudness, loudnessRange, truePeak, gaps, dualMono, unsynced }
    public enum Severity: String, Sendable { case pass, warning, fail }
    public var kind: Kind
    public var severity: Severity
    public var message: String
    public var id: String { kind.rawValue }
}

/// Audio pre-flight of an export: analyses the mix once (BS.1770 loudness, true peak, clipping, gaps, dual mono) and
/// judges it against the delivery target. Unsynced clips come from the timeline (`Timeline.syncOffsets`), passed in.
public enum AudioPreflight {
    /// A gap is silence of at least this long.
    public static let gapSeconds = 1.0
    /// -60 dBFS.
    static let silenceLevel: Float = 0.001
    /// Loudness within this many LU of the target passes.
    public static let loudnessToleranceLU = 1.0

    /// Reads the whole source (from its start) and rewinds it afterwards.
    public static func analyze(_ source: some RewindableAudioSource) async throws -> AudioAnalysis {
        try await source.rewind()
        let ch = max(1, source.channels), rate = max(1, source.sampleRate)
        var meter = LoudnessMeter(sampleRate: rate, channelCount: ch)
        var clipped = 0, frames = 0, run = 0, gaps = 0, longest = 0
        var identical = ch == 2, anySignal = false
        let gapFrames = Int(gapSeconds * Double(rate))
        while let chunk = try await source.nextChunk(maxFrames: 4096) {
            try Task.checkCancellation()
            let n = chunk.frameCount, c = chunk.channels
            var planar = [[Float]](repeating: [Float](repeating: 0, count: n), count: ch)
            for i in 0..<n {
                var loud: Float = 0
                for k in 0..<min(c, ch) {
                    let x = chunk.samples[i * c + k]
                    planar[k][i] = x
                    let a = abs(x)
                    if a >= 0.9999 { clipped += 1 }
                    loud = max(loud, a)
                }
                if loud >= silenceLevel {
                    anySignal = true
                    if run >= gapFrames { gaps += 1 }
                    longest = max(longest, run); run = 0
                } else { run += 1 }
                if identical, c >= 2, abs(chunk.samples[i * c] - chunk.samples[i * c + 1]) > 1e-6 { identical = false }
            }
            frames += n
            meter.process(planar)
        }
        if run >= gapFrames { gaps += 1 }
        longest = max(longest, run)
        try await source.rewind()
        return AudioAnalysis(integratedLUFS: meter.integrated, truePeakDB: meter.truePeakDB.max() ?? -.infinity,
                             clippedSamples: clipped, gapCount: gaps, longestGapSeconds: Double(longest) / Double(rate),
                             isDualMono: identical && anySignal, durationSeconds: Double(frames) / Double(rate),
                             loudnessRangeLU: meter.loudnessRange)
    }

    /// What the export will really do to this mix: the same plan `NormalizedAudioSource.make` settles on (gain, peak
    /// limiter behind it when the ceiling stops the plain gain, levels measured through the chain). Runs up to
    /// `LoudnessNormalizer.maxSearchPasses` extra passes, and none when the plain gain reaches the target or the
    /// mix is silent. `analysis` supplies the measurement, so the mix is not measured again.
    public static func predict(_ source: some RewindableAudioSource, analysis a: AudioAnalysis,
                               target: LoudnessNormalization) async throws -> LoudnessReport {
        let m = LoudnessMeasurement(integratedLUFS: a.integratedLUFS, truePeakDB: a.truePeakDB)
        let plan = try await LoudnessNormalizer.plan(for: source, measured: m, settings: target)
        var r = LoudnessReport(measurement: m, settings: target)
        r.gainDB = plan.gainDB
        r.limiterUsed = plan.limiterCeilingDB != nil
        r.resultLUFS = plan.result.integratedLUFS; r.resultTruePeakDB = plan.result.truePeakDB
        return r
    }

    /// Pass, warning or fail per check. `predicted` (from `predict`) makes the Normalize lines name the loudness the
    /// export reaches with the peak limiter, instead of the pessimistic ceiling-limited gain. With `normalizing` the export moves loudness to the target itself, so the
    /// loudness and peak lines say what the gain will do; clipping and gaps are never fixed by a gain.
    public static func evaluate(_ a: AudioAnalysis, target: LoudnessNormalization, normalizing: Bool,
                                unsyncedClips: Int = 0, predicted: LoudnessReport? = nil,
                                toleranceLU: Double = AudioPreflight.loudnessToleranceLU) -> [AudioFinding] {
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        func sec(_ v: Double) -> String { String(format: "%.1f s", v) }
        var out: [AudioFinding] = []
        func add(_ k: AudioFinding.Kind, _ s: AudioFinding.Severity, _ m: String) { out.append(AudioFinding(kind: k, severity: s, message: m)) }
        if a.isSilent {
            add(.silent, .fail, "The mix is silent: nothing above the gate. Check the audio tracks and their volume.")
        } else {
            if normalizing {
                let m = LoudnessMeasurement(integratedLUFS: a.integratedLUFS, truePeakDB: a.truePeakDB)
                let gain = LoudnessNormalizer.gainDB(for: m, settings: target)
                let outL = predicted?.outputLUFS ?? a.integratedLUFS + gain
                let outP = predicted?.outputTruePeakDB ?? a.truePeakDB + gain
                let limited = predicted?.limiterUsed == true
                add(.loudness, .pass, "\(f(a.integratedLUFS)) LUFS; export moves it to \(f(outL)) LUFS (target \(f(target.targetLUFS)))"
                    + (limited ? " with the peak limiter" : ""))
                add(.truePeak, .pass, "\(f(a.truePeakDB)) dBTP; \(f(outP)) dBTP after \(limited ? "gain and peak limiter" : "gain") (ceiling \(f(target.truePeakCeilingDB)))")
            } else {
                let off = a.integratedLUFS - target.targetLUFS
                let ok = abs(off) <= toleranceLU
                add(.loudness, ok ? .pass : .fail,
                    "\(f(a.integratedLUFS)) LUFS, target \(f(target.targetLUFS)) (\(off >= 0 ? "+" : "")\(f(off)) LU)"
                    + (ok ? "" : "; turn on Normalize to fix"))
                let tpOK = a.truePeakDB <= target.truePeakCeilingDB
                add(.truePeak, tpOK ? .pass : .fail,
                    "\(f(a.truePeakDB)) dBTP, ceiling \(f(target.truePeakCeilingDB))" + (tpOK ? "" : "; turn on Normalize to fix"))
            }
            if let lra = a.loudnessRangeLU { add(.loudnessRange, .pass, "Loudness range \(f(lra)) LU") }
            add(.clipping, a.clippedSamples == 0 ? .pass : .fail,
                a.clippedSamples == 0 ? "No clipped samples"
                    : "\(a.clippedSamples) clipped sample\(a.clippedSamples == 1 ? "" : "s"): lower the clip or track volume")
            add(.gaps, a.gapCount == 0 ? .pass : .warning,
                a.gapCount == 0 ? "No silence over 1 s"
                    : "\(a.gapCount) gap\(a.gapCount == 1 ? "" : "s") of silence over 1 s (longest \(sec(a.longestGapSeconds)))")
            if a.isDualMono {
                add(.dualMono, .warning, "Both channels are identical (dual mono); the file is stereo but carries one voice")
            }
        }
        add(.unsynced, unsyncedClips == 0 ? .pass : .warning,
            unsyncedClips == 0 ? "Audio and picture are in sync"
                : "\(unsyncedClips) audio clip\(unsyncedClips == 1 ? " is" : "s are") out of sync with the picture")
        return out
    }
}

#if canImport(AVFoundation)
/// Measures the audio of a written file (decoded again), so the export can confirm its own loudness and peak.
public enum OutputAudioVerifier {
    /// nil when the file has no audio track.
    public static func measure(url: URL) async throws -> LoudnessMeasurement? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let channels = min(2, max(1, try await Self.channelCount(of: track)))
        let rate = 48_000
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
        ])
        reader.add(out)
        guard reader.startReading() else { throw ExportError.writerFailed(reader.error?.localizedDescription ?? "read audio") }
        var meter = LoudnessMeter(sampleRate: rate, channelCount: channels)
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &ptr) == kCMBlockBufferNoErr, let base = ptr else { continue }
            let n = length / (4 * channels)
            guard n > 0 else { continue }
            let floats = UnsafeRawPointer(base).bindMemory(to: Float.self, capacity: n * channels)
            var planar = [[Float]](repeating: [Float](repeating: 0, count: n), count: channels)
            var c = 0
            while c < channels {                // index loops: Range iterators are ~100x slower in Debug
                planar[c].withUnsafeMutableBufferPointer { dst in
                    var i = 0
                    while i < n { dst[i] = floats[i * channels + c]; i += 1 }
                }
                c += 1
            }
            meter.process(planar)
        }
        if reader.status == .failed { throw ExportError.writerFailed(reader.error?.localizedDescription ?? "read audio") }
        return LoudnessMeasurement(integratedLUFS: meter.integrated, truePeakDB: meter.truePeakDB.max() ?? -.infinity)
    }

    private static func channelCount(of track: AVAssetTrack) async throws -> Int {
        guard let d = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee else { return 2 }
        return Int(asbd.mChannelsPerFrame)
    }
}
#endif

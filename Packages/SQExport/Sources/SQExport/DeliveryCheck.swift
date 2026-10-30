import Foundation
import SQCore

/// Pure delivery checks of an export: what the Export sheet shows as chips, plus the encoder hint. Soft findings only,
/// they never block (hard upload limits: `DeliveryLimits`; plain notes: `DeliveryAdvice`).
public enum DeliveryCheck {
    public enum Severity: Sendable, Equatable { case info, warning }

    public struct Issue: Sendable, Equatable, Identifiable {
        /// Stable key: vfr, interlaced, fps, audioRate, length.
        public var id: String
        public var severity: Severity
        /// Short text for a chip (one line).
        public var text: String
    }

    /// What the used source media looks like (probed at import).
    public struct SourceTraits: Sendable, Equatable, Hashable {
        public var hasVariableFrameRate: Bool
        public var hasInterlaced: Bool
        /// Captions whose box reaches into the delivery platform's UI zone (counted by the app from the caption layout).
        public var captionsInZone: Int
        public init(hasVariableFrameRate: Bool = false, hasInterlaced: Bool = false, captionsInZone: Int = 0) {
            self.hasVariableFrameRate = hasVariableFrameRate; self.hasInterlaced = hasInterlaced; self.captionsInZone = captionsInZone
        }
    }

    public struct EncoderHint: Sendable, Equatable {
        public var isHardware: Bool
        /// Why this encoder runs (and, for software, which setting forced it).
        public var reason: String
    }

    public static func issues(settings s: ExportSettings, preset: ExportPreset, duration: Time, source: SourceTraits,
                              platform: DeliveryPlatform? = nil) -> [Issue] {
        guard s.audioOnly == nil, s.frameOutput == nil else { return [] }
        var out: [Issue] = []
        if source.hasVariableFrameRate {
            out.append(Issue(id: "vfr", severity: .warning, text: "Variable frame rate source"))
        }
        if source.hasInterlaced {
            out.append(Issue(id: "interlaced", severity: .warning, text: "Interlaced source"))
        }
        if source.captionsInZone > 0, let zp = platform?.safeZonePlatform {
            let n = source.captionsInZone
            out.append(Issue(id: "zone", severity: .warning, text: "\(n) \(n == 1 ? "caption sits" : "captions sit") in the \(zp.title) UI zone"))
        }
        let fd = s.video.frameDuration
        if fd.value > 0 {
            let fps = Double(fd.timescale) / Double(fd.value)
            let listed = DeliveryAdvice.youtubeRates.contains { abs($0 - fps) < 0.05 || abs($0 * 1000 / 1001 - fps) < 0.05 }
            if !listed { out.append(Issue(id: "fps", severity: .warning, text: "\(DeliveryAdvice.formatRate(fps)) fps is not a YouTube rate")) }
        }
        let a = s.effectiveAudio
        if a.enabled, a.sampleRate != 48_000 {
            out.append(Issue(id: "audioRate", severity: .warning, text: "Audio \(DeliveryAdvice.formatRate(Double(a.sampleRate) / 1000)) kHz, not 48"))
        }
        let secs = Double(duration.value) / Double(duration.timescale)
        if let lim = DeliveryAdvice.softDurationLimit(of: preset), duration > lim {
            out.append(Issue(id: "length", severity: .warning, text: "Over \(seconds(lim)) s: \(preset.platform?.displayName ?? "platform") may cut it"))
        } else if preset.kind == .xPost, let hard = preset.limits?.maxDuration, duration <= hard,
                  secs > 0.9 * Double(hard.value) / Double(hard.timescale) {
            out.append(Issue(id: "length", severity: .warning, text: "Close to X's \(seconds(hard)) s limit"))
        }
        return out
    }

    /// Which encoder will run for video and why. nil for audio-only and frame-output exports.
    public static func encoder(_ s: ExportSettings) -> EncoderHint? {
        guard s.audioOnly == nil, s.frameOutput == nil else { return nil }
        if s.video.codec.isProRes {
            return EncoderHint(isHardware: true, reason: "ProRes runs on the Mac's ProRes engine.")
        }
        if !s.video.hardwareEncoding {
            return EncoderHint(isHardware: false, reason: "Software encoder: hardware encoding is off in the video settings.")
        }
        // shortcut: 4096 px is the common hardware H.264/HEVC size limit; the exact limit depends on the Mac, ask VideoToolbox when it matters.
        if max(s.video.width, s.video.height) > 4096 {
            return EncoderHint(isHardware: false, reason: "Software encoder: \(s.video.width)x\(s.video.height) is above the 4096 px hardware limit.")
        }
        return EncoderHint(isHardware: true, reason: "Hardware encoder; it falls back to software when the Mac has none for this size.")
    }

    private static func seconds(_ t: Time) -> Int { Int((Double(t.value) / Double(t.timescale)).rounded()) }
}

import Foundation
import SQCore

/// Soft findings about an export that never block it (the hard upload limits live in `DeliveryLimits`).
/// Plain English lines for the Export sheet; the sheet shows them under the warning line.
public enum DeliveryAdvice {
    /// Frame rates YouTube lists as supported (fps).
    static let youtubeRates: [Double] = [24, 25, 30, 48, 50, 60]

    /// Soft length limit of a platform preset (Shorts 3 min, Reels 90 s); nil = none.
    public static func softDurationLimit(of preset: ExportPreset) -> Time? {
        guard preset.kind == .social, let p = preset.platform else { return nil }
        let id: String
        switch p { case .shorts: id = "shorts"; case .reels: id = "reels"; case .tiktok: id = "tiktok" }
        return PlatformSpec.bundled.entry(id)?.softDurationSeconds.map { Time(Int64($0), 1) }
    }

    /// The length warning for `duration` under `preset`, nil when it fits or the preset has no soft limit.
    public static func lengthWarning(preset: ExportPreset, duration: Time, presetName: String) -> String? {
        guard let lim = softDurationLimit(of: preset), duration > lim else { return nil }
        let seconds = Int((Double(lim.value) / Double(lim.timescale)).rounded())
        let actual = Int((Double(duration.value) / Double(duration.timescale)).rounded())
        return "\(presetName) usually accepts at most \(seconds) seconds; this export is \(actual) seconds."
    }

    /// Notes about delivery settings: odd frame rate for YouTube, audio not at 48 kHz.
    public static func settingsNotes(_ s: ExportSettings, preset: ExportPreset) -> [String] {
        var out: [String] = []
        guard s.audioOnly == nil, s.frameOutput == nil else { return out }
        let fd = s.video.frameDuration
        if fd.value > 0, [.youtube1080, .youtube1440, .youtube4K].contains(preset.kind) {
            let fps = Double(fd.timescale) / Double(fd.value)
            if !youtubeRates.contains(where: { abs($0 - fps) < 0.05 || abs($0 * 1000 / 1001 - fps) < 0.05 }) {
                out.append("YouTube lists 24, 25, 30, 48, 50 and 60 fps; \(formatRate(fps)) fps may be re-encoded or look uneven.")
            }
        }
        let a = s.effectiveAudio
        if a.enabled, a.sampleRate != 48_000 {
            out.append("Audio is \(formatRate(Double(a.sampleRate) / 1000)) kHz; video delivery expects 48 kHz.")
        }
        return out
    }

    /// An odd stored sequence size is written one pixel smaller (codecs need even sizes); say so.
    public static func oddSizeNote(width: Int, height: Int) -> String? {
        guard width > 0, height > 0, width % 2 != 0 || height % 2 != 0 else { return nil }
        return "The sequence is \(width)x\(height); the file is written at \(width & ~1)x\(height & ~1) because video needs even sizes."
    }

    /// Which encoder runs and why software is used.
    public static func encoderNote(_ s: ExportSettings) -> String? {
        guard s.audioOnly == nil, s.frameOutput == nil else { return nil }
        if s.video.codec.isProRes { return "ProRes uses the Mac's own ProRes encoder." }
        if !s.video.hardwareEncoding { return "Software encoder: hardware encoding is off. Slower, sometimes smaller files." }
        return "Hardware encoder; it falls back to software when the Mac has none for this size."
    }

    static func formatRate(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.3g", v)
    }
}

import SQCore

/// Quality steps for the H.264 / HEVC target bitrate, as bits per pixel per frame (docs/research/export/F3b-quality-per-bit.md:
/// Standard is the Match Source default, nothing wasted; Smaller file and High quality are the measured ends).
public enum QualityStep: String, Sendable, CaseIterable {
    case smaller, standard, high

    public var title: String {
        switch self { case .smaller: "Smaller file"; case .standard: "Standard"; case .high: "High quality" }
    }

    /// Bits per pixel per frame; HEVC needs about 30 % less than H.264 for the same picture. nil for ProRes.
    public func bitsPerPixel(for codec: VideoCodec) -> Double? {
        switch codec {
        case .h264: switch self { case .smaller: 0.09; case .standard: 0.18; case .high: 0.35 }
        case .hevc: switch self { case .smaller: 0.055; case .standard: 0.12; case .high: 0.235 }
        default: nil
        }
    }
}

extension VideoSettings {
    private var pixelsPerSecond: Double {
        Double(width * height) * Double(frameDuration.timescale) / Double(max(frameDuration.value, 1))
    }

    /// The step the current target bitrate sits on (within 8 %), nil for a custom value or ProRes.
    public var qualityStep: QualityStep? {
        let px = pixelsPerSecond
        guard px > 0 else { return nil }
        let bpp = Double(bitrate.averageBitsPerSecond) / px
        return QualityStep.allCases.first { step in
            step.bitsPerPixel(for: codec).map { abs(bpp - $0) <= 0.08 * $0 } ?? false
        }
    }

    /// Sets the target bitrate for the step at the current size and rate. A stored maximum keeps its ratio to the target.
    public mutating func applyQuality(_ step: QualityStep) {
        guard let bpp = step.bitsPerPixel(for: codec) else { return }
        let avg = Int(min(max(pixelsPerSecond * bpp, 500_000), 400_000_000))
        if let oldMax = bitrate.maxBitsPerSecond {
            let ratio = Double(oldMax) / Double(max(bitrate.averageBitsPerSecond, 1))
            bitrate = .averageAndMax(average: avg, max: max(avg, Int(Double(avg) * ratio)))
        } else {
            bitrate = .average(avg)
        }
    }
}

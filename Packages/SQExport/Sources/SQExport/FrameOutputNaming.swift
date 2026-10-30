import SQCore

/// Numbered file names of an image sequence.
public enum ImageSequenceNaming {
    /// Digits of the frame number: at least 4, more when the last number needs them.
    public static func digits(startNumber: Int, count: Int) -> Int {
        max(4, String(max(0, startNumber + max(count, 1) - 1)).count)
    }

    /// "Shot_0007.png": the name is made file-system safe, the number is zero padded.
    public static func fileName(stem: String, number: Int, digits: Int, ext: String) -> String {
        let n = String(max(0, number))
        let padded = String(repeating: "0", count: max(0, digits - n.count)) + n
        return "\(ExportQueue.sanitize(stem))_\(padded).\(ext)"
    }

    /// Every file name of a sequence of `count` frames numbered from `startNumber`.
    public static func fileNames(stem: String, startNumber: Int = 0, count: Int, ext: String) -> [String] {
        let d = digits(startNumber: startNumber, count: count)
        return (0..<max(0, count)).map { fileName(stem: stem, number: startNumber + $0, digits: d, ext: ext) }
    }
}

/// GIF stores each frame delay in whole centiseconds. A constant round(100 / fps) would play 24 fps four percent fast;
/// frame i instead spans round(i * 100 / fps) to round((i + 1) * 100 / fps), so delays alternate (4, 4, 5 at 24 fps)
/// and their sum is the duration (to half a centisecond).
public enum GIFTiming {
    public static func delaysCentiseconds(frameDuration: Time, frameCount: Int) -> [Int] {
        guard frameDuration.value > 0, frameDuration.timescale > 0, frameCount > 0 else { return [] }
        let v = Int128(frameDuration.value), t = Int128(frameDuration.timescale)
        // round(i * 100 * v / t), half up, in integers.
        func boundary(_ i: Int) -> Int { Int((2 * Int128(i) * 100 * v + t) / (2 * t)) }
        return (0..<frameCount).map { boundary($0 + 1) - boundary($0) }
    }
}


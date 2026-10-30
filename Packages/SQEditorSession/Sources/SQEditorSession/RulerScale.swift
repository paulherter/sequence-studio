#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Timecode labels for the ruler and viewer. Pure: frame index in, string out.
/// 29.97 (30000/1001) and 59.94 (60000/1001) can be shown as drop frame ("HH:MM:SS;FF") or non-drop ("HH:MM:SS:FF").
/// All other rates (23.976, 24, 25, 30, 50, 60, ...) are labeled at their nominal rate; there is no drop-frame form for them.
public struct TimecodeFormat: Sendable, Equatable {
    /// Frames per timecode second (30 for 29.97, 24 for 23.976, 25 for 25).
    public let nominalFPS: Int
    public let dropFrame: Bool
    /// Sequence Settings "Starts at" as a frame count; added to every label (positions only).
    public var startFrame: Int64 = 0
    /// Sequence Settings "Display: Frames": labels are plain frame numbers.
    public var framesOnly = false

    /// - Parameter preferDropFrame: applies only to 29.97 / 59.94; otherwise ignored.
    public init(frameDuration: Time, preferDropFrame: Bool = true) {
        let fps = Double(frameDuration.timescale) / Double(frameDuration.value)
        nominalFPS = max(1, Int(fps.rounded()))
        let ntsc = frameDuration.value == 1001          // 24000/1001, 30000/1001, 60000/1001
        dropFrame = preferDropFrame && ntsc && (nominalFPS == 30 || nominalFPS == 60)
    }

    public init(nominalFPS: Int, dropFrame: Bool) {
        precondition(nominalFPS > 0 && (!dropFrame || nominalFPS == 30 || nominalFPS == 60))
        self.nominalFPS = nominalFPS; self.dropFrame = dropFrame
    }

    /// Frames dropped per minute (except every tenth): 2 at 30, 4 at 60.
    private var dropPerMinute: Int64 { Int64(nominalFPS / 15) }

    /// "HH:MM:SS:FF" (";" before FF for drop frame). Negative frames get a leading "-".
    public func string(forFrame position: Int64) -> String {
        let frame = position + startFrame
        if framesOnly { return String(frame) }
        let negative = frame < 0
        var n = negative ? -frame : frame
        let fps = Int64(nominalFPS)
        if dropFrame {
            let d = dropPerMinute
            let per10 = fps * 600 - d * 9
            let perMin = fps * 60 - d
            let tens = n / per10, rem = n % per10
            n += 9 * d * tens
            if rem > d { n += d * ((rem - d) / perMin) }
        }
        let ff = n % fps
        let total = n / fps
        let ss = total % 60, mm = (total / 60) % 60, hh = total / 3600
        let sep = dropFrame ? ";" : ":"
        return (negative ? "-" : "")
            + String(format: "%02lld:%02lld:%02lld", hh, mm, ss) + sep + String(format: "%02lld", ff)
    }

    public func string(for time: Time, frameDuration: Time) -> String {
        string(forFrame: time.frameIndex(frameDuration: frameDuration))
    }
}

/// Tick spacing of the ruler at a zoom level, in whole frames.
public struct RulerScale: Sendable, Equatable {
    /// Labeled ticks every `majorFrames`.
    public var majorFrames: Int64
    /// Unlabeled ticks every `minorFrames`; divides `majorFrames` (equal when there are no minor ticks).
    public var minorFrames: Int64

    /// Frame counts tried for the major interval, smallest first: a few sub-second steps, then whole seconds / minutes / hours.
    static func majorCandidates(nominalFPS n: Int64) -> [Int64] {
        let sub: [Int64] = [1, 2, 5, 10].filter { $0 < n }
        let seconds: [Int64] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 18_000, 36_000]
        return sub + seconds.map { $0 * n }
    }

    /// Picks the smallest major interval whose labels are at least `minLabelSpacing` apart, and minor ticks
    /// (the largest subdivision out of 10, 5, 4, 2) at least `minTickSpacing` apart.
    public static func scale(pointsPerFrame: Double, nominalFPS: Int,
                             minLabelSpacing: CGFloat = 96, minTickSpacing: CGFloat = 6) -> RulerScale {
        precondition(pointsPerFrame > 0 && nominalFPS > 0)
        let n = Int64(nominalFPS)
        let candidates = majorCandidates(nominalFPS: n)
        var major = candidates.last!
        for c in candidates where Double(c) * pointsPerFrame >= Double(minLabelSpacing) { major = c; break }
        // Beyond the table (extreme zoom-out): keep doubling so labels never collide.
        while Double(major) * pointsPerFrame < Double(minLabelSpacing), major < Int64.max / 4 { major *= 2 }
        var minor = major
        for d: Int64 in [10, 5, 4, 2] where major % d == 0 && Double(major / d) * pointsPerFrame >= Double(minTickSpacing) {
            minor = major / d
            break
        }
        return RulerScale(majorFrames: major, minorFrames: minor)
    }
}

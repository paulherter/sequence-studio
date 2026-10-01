/// Frame rate choice for a clip / sequence (pure, rational).
public enum FrameRate {
    /// 23.976, 24, 25, 29.97, 30, 50, 59.94, 60.
    public static let standardFrameDurations: [Time] = [
        Time(1001, 24000), Time(1, 24), Time(1, 25), Time(1001, 30000),
        Time(1, 30), Time(1, 50), Time(1001, 60000), Time(1, 60),
    ]

    /// Frame duration from the average rate (`frameCount` over `duration`): the nearest standard rate when within 1 %,
    /// else `duration / frameCount`. Never the duration of a single sample (VFR clips vary per sample).
    public static func sequenceFrameDuration(frameCount: Int, duration: Time) -> Time {
        guard frameCount > 0, duration > .zero else { return Time(1, 30) }
        let n = Int64(frameCount)
        // fps = n * timescale / value
        let fps = Double(n) * Double(duration.timescale) / Double(duration.value)
        var best: (Time, Double)?
        for fd in standardFrameDurations {
            let std = Double(fd.timescale) / Double(fd.value)
            let rel = abs(fps - std) / std
            if rel <= 0.01, rel < (best?.1 ?? .infinity) { best = (fd, rel) }
        }
        if let best { return best.0 }
        let (v, overflow) = duration.timescale.multipliedReportingOverflow(by: n)
        return overflow ? Time(1, Int64(fps.rounded())) : Time(duration.value, v)
    }
}

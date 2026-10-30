import SQCore

/// The detail a layer needs while playing or scrubbing (Windows engine: the decoded picture is reduced on the CPU before
/// upload, `WinProgramEngine`): a layer drawn at half its native size or less on its sequence's canvas is decoded at
/// half, a quarter or less at a quarter, so the picture still holds about every pixel the composite samples. A 4K phone
/// or camera clip at 50 % in a 1080 x 1920 sequence uploads 1/4 of the bytes. Paused frames keep the full picture.
/// Tilted layers keep full detail (their near edge is drawn larger than the scale says).
public enum PlaybackLayerDetail {
    /// Scale margin: a layer up to 10 % above half (quarter) size still uses the half (quarter) picture.
    static let margin = 1.1

    /// 1, 2 or 4: the divisor of the layer's picture size.
    public static func divisor(for l: LayerRequest) -> Int {
        guard !l.transform.isTilted else { return 1 }
        var s = drawnScale(l.transform)
        for g in l.groups {
            guard !g.transform.isTilted else { return 1 }
            s *= drawnScale(g.transform)
        }
        if s <= 0.25 * margin { return 4 }
        if s <= 0.5 * margin { return 2 }
        return 1
    }

    private static func drawnScale(_ t: ClipTransform) -> Double { max(abs(t.scale.x), abs(t.scale.y)) }
}

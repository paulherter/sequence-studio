import Foundation

/// What a popup's spectrum curve shows, from successive `AudioSpectrumTap` snapshots (pure, testable). A new sequence
/// runs the FFT (`spectrum`) and the curve rises at once; between readings it falls at `fallDBPerSecond`. Nothing new
/// for `staleSeconds` (stopped, or the playhead left the clip), or the effect is not watched: no curve.
public struct SpectrumDisplay: Sendable, Equatable {
    public static let points = 160
    public static let staleSeconds = 0.3
    public static let fallDBPerSecond: Float = 40
    /// The plot's vertical scale (dBFS of a sine).
    public static let topDB: Float = 0, bottomDB: Float = -90

    /// One level per `SpectrumAnalyzer.frequencies(points: points)`, empty = nothing to draw.
    public private(set) var levelsDB: [Float] = []
    private var lastSequence: UInt64 = 0
    private var lastNewAt = -Double.infinity
    private var lastTime = -Double.infinity

    public init() {}

    /// `sequence`: the tap's sequence for this effect (nil = not watched, 0 = nothing published yet).
    public mutating func update(sequence: UInt64?, at time: Double, spectrum: () -> [Float]) {
        let dt = Float(max(0, time - lastTime))
        lastTime = time
        guard let sequence, sequence != 0 else { levelsDB = []; return }
        if sequence != lastSequence {
            lastSequence = sequence; lastNewAt = time
            let new = spectrum()
            if levelsDB.count != new.count { levelsDB = new; return }
            for i in new.indices { levelsDB[i] = max(new[i], levelsDB[i] - Self.fallDBPerSecond * dt) }
            return
        }
        if time - lastNewAt > Self.staleSeconds { levelsDB = []; return }
        for i in levelsDB.indices { levelsDB[i] -= Self.fallDBPerSecond * dt }
    }

    /// 0 (bottom) ... 1 (top) of the plot for a level.
    public static func fraction(dB: Float) -> Float {
        min(1, max(0, (dB - bottomDB) / (topDB - bottomDB)))
    }
}

import Foundation

/// The one gate state machine behind both gates: the clip Noise Gate (`NoiseGateStage`, Float, keyframed) and the track
/// gate (`NoiseGate` in CreatorFX.swift, Double, fixed settings). It owns the level detector, the open/hold/close logic
/// and the gain glide; the callers only differ in how they get their per-sample numbers and in the three choices below,
/// which keep each gate sounding exactly as it did before they shared this core.
///
/// - `Detector`: the track gate keeps a peak with a pure exponential fall; the clip gate falls as a one-pole smoother
///   of the peak (so it also dips towards the input instead of only decaying).
/// - `Smoothing`: the same glide written two ways; the float rounding differs, so each gate keeps its own order.
/// - Hysteresis: `closeLevel` below `openLevel` (track gate, 3 dB) or equal to it (clip gate, none).
/// Hold: after the level fell below `closeLevel` the gate stays open for `holdSamples` samples, then closes.
struct GateCore<F: BinaryFloatingPoint> {
    enum Detector { case peakDecay, smoothedFall }
    enum Smoothing { case blend, lerp }

    let detector: Detector
    let smoothing: Smoothing
    var env: F = 0
    var gain: F = 1
    var hold = 0
    var isOpen = true

    init(detector: Detector, smoothing: Smoothing) { self.detector = detector; self.smoothing = smoothing }

    mutating func reset() { env = 0; gain = 1; hold = 0; isOpen = true }

    /// Gate off: unity gain, nothing held.
    mutating func bypass() { gain = 1; isOpen = true; hold = 0 }

    /// One sample: `peak` is the loudest channel's magnitude. Returns the gain to multiply every channel with.
    @inline(__always)
    mutating func step(peak: F, openLevel: F, closeLevel: F, floorGain: F, decay: F, attack: F, release: F, holdSamples: Int) -> F {
        switch detector {
        case .peakDecay: env = max(peak, env * decay)
        case .smoothedFall: env = peak > env ? peak : env * decay + peak * (1 - decay)
        }
        if isOpen {
            if env < closeLevel {
                if hold > 0 { hold -= 1 } else { isOpen = false }
            } else { hold = holdSamples }
        } else if env >= openLevel {
            isOpen = true; hold = holdSamples
        }
        let target: F = isOpen ? 1 : floorGain
        let k = target > gain ? attack : release
        switch smoothing {
        case .blend: gain = k * gain + (1 - k) * target
        case .lerp: gain = target + (gain - target) * k
        }
        return gain
    }
}

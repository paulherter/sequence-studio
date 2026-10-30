import Foundation

// Stabilize as an effect (DECISIONS 2026-10-06). The `stabilize` effect (Stabilizer.swift) is offered in the Effects panel
// under Video > Transform and dragged onto a clip like any other effect. Its Method picks the engine:
//   Standard: the picture analysis (SQAnalysis, Vision) measures the shake, `Stabilizer` plans the correction and writes it
//             as the effect's stage keys (Position / Rotation / Scale), so playback and export render the same keys.
//   Gyroflow: the camera's own gyro data, undistorted and stabilized by gyroflow_core in its own render pass (docs/GYROFLOW.md).
//             Its settings live on the effect; the Standard stage keys are ignored while it is chosen.
// A Gyroflow Stabilizer is version gated (v52): an older build would re-plan it as Standard.

/// Which engine a Stabilizer uses. Stored as the index of the Method choice (never reorder).
public enum StabilizerMethod: Int, Sendable, Hashable, CaseIterable {
    case standard = 0
    case gyroflow = 1

    public var title: String { self == .standard ? "Standard" : "Gyroflow" }

    /// The parameter rows Effect Controls shows for this method, in order (Method first).
    public var visibleKeys: [String] {
        switch self {
        case .standard:
            [ClipEffect.stabilizeMethodKey, ClipEffect.stabilizeModeKey, ClipEffect.stabilizeStrengthKey, ClipEffect.stabilizeSmoothnessKey, ClipEffect.stabilizeMaxCropKey,
             ClipEffect.stabilizeEdgeFillKey,
             ClipEffect.rollingShutterKey, ClipEffect.rollingShutterStrengthKey]
        case .gyroflow:
            [ClipEffect.stabilizeMethodKey, ClipEffect.gyroSmoothnessKey, ClipEffect.gyroZoomLimitKey,
             ClipEffect.gyroFieldOfViewKey, ClipEffect.gyroLensCorrectionKey, ClipEffect.gyroRollingShutterKey,
             ClipEffect.gyroHorizonLockKey, ClipEffect.gyroSyncOffsetKey]
        }
    }
}

/// The Gyroflow settings stored on a Stabilizer (names and ranges of the Gyroflow plugins, `common/src/lib.rs`).
public struct GyroflowOptions: Sendable, Hashable {
    /// Smoothness, % (1...100; Gyroflow's 0.001...1 range, its default is 50).
    public var smoothness: Double = 50
    /// Most the adaptive zoom may scale up, % (100...300).
    public var zoomLimit: Double = 130
    /// Rolling-shutter correction (readout time from the lens profile).
    public var rollingShutter = true
    /// Horizon lock amount, % (0...100).
    public var horizonLock: Double = 0
    /// Field of view of the stabilized frame, % (10...300; 100 = as framed; Gyroflow's FOV x 100). Above 100 shows more of
    /// the picture (and its edges), below zooms in further.
    public var fieldOfView: Double = 100
    /// How much of the lens profile's distortion is undone, % (0...100; 0 keeps the lens look, 100 = straight lines).
    public var lensCorrection: Double = 100
    /// Gyro data shifted against the picture, ms (-5000...5000; Gyroflow's sync offset sign: the gyro is looked up
    /// at `frame time - offset`, so positive = an EARLIER gyro sample is used, GyroflowBenchTests.syncOffsetSign). Added to the offsets the file brings.
    public var syncOffsetMS: Double = 0
    public init() {}

    /// Field of View, Lens Correction or Sync Offset differ from their defaults (a v58 build would ignore them: v59 gate).
    public var changesLensOrSync: Bool {
        let d = GyroflowOptions()
        return fieldOfView != d.fieldOfView || lensCorrection != d.lensCorrection || syncOffsetMS != d.syncOffsetMS
    }

    public init(effect e: ClipEffect) {
        self.init()
        func v(_ k: String) -> Double? { e.parameters[k]?.value.isFinite == true ? e.parameters[k]?.value : nil }
        if let s = v(ClipEffect.gyroSmoothnessKey) { smoothness = min(max(s, 1), 100) }
        if let z = v(ClipEffect.gyroZoomLimitKey) { zoomLimit = min(max(z, 100), 300) }
        if let r = v(ClipEffect.gyroRollingShutterKey) { rollingShutter = r >= 0.5 }
        if let h = v(ClipEffect.gyroHorizonLockKey) { horizonLock = min(max(h, 0), 100) }
        if let f = v(ClipEffect.gyroFieldOfViewKey) { fieldOfView = min(max(f, 10), 300) }
        if let l = v(ClipEffect.gyroLensCorrectionKey) { lensCorrection = min(max(l, 0), 100) }
        if let o = v(ClipEffect.gyroSyncOffsetKey) { syncOffsetMS = min(max(o, -5000), 5000) }
    }

    /// A source frame time as the gyro engine takes it: microseconds from the start of the file, rounded to nearest.
    public static func timestampMicroseconds(_ t: Time) -> Int64 {
        let n = Int128(t.value) * 1_000_000, d = Int128(t.timescale)
        let q = n >= 0 ? (2 * n + d) / (2 * d) : -((-2 * n + d) / (2 * d))
        return Int64(clamping: q)
    }
}

extension ClipEffect {
    // Stored parameter keys (never rename). Gyroflow keys must not collide with the stage keys.
    public static let stabilizeMethodKey = "stabilizeMethod"
    public static let gyroSmoothnessKey = "gyroSmoothness", gyroZoomLimitKey = "gyroZoomLimit"
    public static let gyroRollingShutterKey = "gyroRollingShutter", gyroHorizonLockKey = "gyroHorizonLock"
    // v59
    public static let gyroFieldOfViewKey = "gyroFieldOfView", gyroLensCorrectionKey = "gyroLensCorrection"
    public static let gyroSyncOffsetKey = "gyroSyncOffset"

    /// The Stabilizer's engine (Standard when missing or out of range: Stabilizers written before v52 are Standard).
    public var stabilizeMethod: StabilizerMethod {
        guard let v = parameters[Self.stabilizeMethodKey]?.value, v.isFinite else { return .standard }
        return StabilizerMethod(rawValue: Int(v.rounded())) ?? .standard
    }

    /// A Stabilizer that already holds its correction: Standard with an analyzed range or stage keys. A fresh one (just
    /// dropped from the Effects panel) changes nothing until Analyze runs. Gyroflow keeps no result on the effect.
    public var stabilizeIsAnalysed: Bool {
        guard kind == Self.stabilizeKind, stabilizeMethod == .standard else { return false }
        return stabilizeAnalysedRange != nil || parameters[Self.stagePositionXKey] != nil || parameters[Self.stageScaleKey] != nil
    }
}

extension Clip {
    /// Clips whose picture moves (media video, not a still, hold or nested sequence): what Stabilize can analyze.
    public var canStabilize: Bool {
        kind == .video && !isGenerator && sequence == nil && !isStill && holdFrame == nil
    }

    /// Options of the clip's enabled Gyroflow Stabilizer (nil: none, Standard, or switched off).
    public var gyroflowOptions: GyroflowOptions? {
        guard canStabilize, let e = effects.first(where: { $0.kind == ClipEffect.stabilizeKind }),
              e.enabled, e.stabilizeMethod == .gyroflow else { return nil }
        return GyroflowOptions(effect: e)
    }

    /// The clip's Stabilizer, if any.
    public var stabilizerID: ClipEffect.ID? { effects.first { $0.kind == ClipEffect.stabilizeKind }?.id }

    /// Adds a fresh (unanalyzed) Stabilizer before the first other transform stage, so Transform / Auto Reframe act on the
    /// steadied picture. One per clip: nil (no change) when the clip has one or cannot be stabilized.
    mutating func addStabilizer(_ e: ClipEffect) -> ClipEffect.ID? {
        guard canStabilize, stabilizerID == nil else { return nil }
        effects.insert(e, at: Stabilizer.insertionIndex(in: effects))
        return e.id
    }
}

extension Project {
    /// Any clip carries a Gyroflow Stabilizer: the file must be v52.
    public var containsGyroflowStabilizers: Bool {
        allClips().contains { c in c.effects.contains { $0.kind == ClipEffect.stabilizeKind && $0.stabilizeMethod == .gyroflow } }
    }
}

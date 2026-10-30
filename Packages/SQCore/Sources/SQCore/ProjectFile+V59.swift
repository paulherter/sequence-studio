import Foundation

// v59: a Gyroflow Stabilizer's Field of View, Lens Correction and Sync Offset (`GyroflowOptions`, StabilizeEffect.swift).
// A v58 build would keep the keys but ignore them and render a different picture; at v59 it refuses the file with
// `ProjectFileError.newerVersion` instead. Values at their defaults do not gate.

extension Project {
    /// Any Gyroflow Stabilizer (on or off) sets Field of View, Lens Correction or Sync Offset away from the
    /// default: the file must be v59.
    public var containsV59Content: Bool {
        allClips().contains { c in
            c.effects.contains { $0.kind == ClipEffect.stabilizeKind && $0.stabilizeMethod == .gyroflow
                && GyroflowOptions(effect: $0).changesLensOrSync }
        }
    }
}

import Foundation

// v93: per-clip footage color handling on `ClipFootageColor`: `logMode` (camera LUT / built-in transform / off), `targetSpace`
// (Rec.709, Rec.2020, Rec.2020 PQ, Rec.2020 HLG) and the `hdrConform` switch (default on). Each key is written only when it differs
// from its default, so a file without them keeps the lowest version that holds its content (byte-identical). A v92 build would
// drop the settings on the next save; at v93 it refuses the file. Identity step: all keys are optional on decode.

/// How a log source reaches the display signal (the first Color effect's conversion).
public enum LogMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// The effect's Input LUT decides (embedded or chosen camera LUT, else the built-in transform). The default.
    case cameraLUT
    /// The built-in transform of the source color space; the Input LUT is ignored.
    case builtIn
    /// No log conversion: a log source is taken as display-referred Rec.709.
    case off
}

/// The space the clip's conversion delivers.
public enum TargetSpace: String, Sendable, Hashable, Codable, CaseIterable {
    case rec709, rec2020, rec2020PQ, rec2020HLG
    public var isHDR: Bool { self == .rec2020PQ || self == .rec2020HLG }
}

extension ClipColor {
    /// The source space the render uses: the override, else the media's, else Rec.709; log sources count as Rec.709 when
    /// `logMode` is off.
    public func effectiveSource(mediaSpace: ColorSpaceID?) -> ColorSpaceID {
        let id = source ?? mediaSpace ?? .rec709
        return logMode == .off && id.isLog ? .rec709 : id
    }

    /// False when `logMode` bypasses the first effect's Input LUT.
    public var usesInputLUT: Bool { logMode == .cameraLUT }

    init(footage f: ClipFootageColor, effects: [ColorEffect]) {
        self.init(source: f.source, useEmbeddedLUT: f.useEmbeddedLUT, effects: effects)
        logMode = f.logMode; targetSpace = f.targetSpace; hdrConform = f.hdrConform
    }
}

extension Project {
    /// Any clip has a non-default log mode, target space or HDR conform switch: the file must be v93.
    public var containsV93Content: Bool { allClips().contains { $0.footageColor.hasV93Content } }
}

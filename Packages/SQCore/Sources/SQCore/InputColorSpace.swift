import Foundation

// W9.3 camera input color spaces. The stored value is always a `ColorSpaceID` (per clip `ClipFootageColor.source`,
// per project `Project.inputColorSpace`); `InputColorProfile` is the camera / Log / SDR-HDR view of it for the UI.

extension ColorSpaceID {
    /// Camera log encoding (needs the conversion to look normal).
    public var isLog: Bool {
        switch self {
        case .sLog3SGamut3Cine, .vLogVGamut, .appleLog, .dLogDGamut: true
        case .canonLogCinemaGamut, .canonLogBT2020, .canonLogBT709, .canonLog2CinemaGamut, .canonLog2BT2020,
             .canonLog2BT709, .canonLog3CinemaGamut, .canonLog3BT2020, .canonLog3BT709: true
        case .logC3WideGamut3, .logC4WideGamut4, .log3G10RedWideGamut, .bmdFilmGen5WideGamut, .nLogBT2020,
             .fLog2FGamutC, .acesCCTAP1: true
        case .rec709, .hlgBT2020, .pqBT2020: false
        }
    }

    /// HDR delivery encoding (HLG or PQ).
    public var isHDR: Bool { self == .hlgBT2020 || self == .pqBT2020 }

    public var displayName: String {
        switch self {
        case .rec709: "Rec. 709"
        case .sLog3SGamut3Cine: "S-Log3 / S-Gamut3.Cine"
        case .hlgBT2020: "HLG / Rec. 2020"
        case .pqBT2020: "PQ (HDR10) / Rec. 2020"
        case .vLogVGamut: "V-Log / V-Gamut"
        case .appleLog: "Apple Log / Rec. 2020"
        case .dLogDGamut: "D-Log / D-Gamut"
        case .canonLogCinemaGamut: "Canon Log / Cinema Gamut"
        case .canonLogBT2020: "Canon Log / Rec. 2020"
        case .canonLogBT709: "Canon Log / Rec. 709"
        case .canonLog2CinemaGamut: "Canon Log 2 / Cinema Gamut"
        case .canonLog2BT2020: "Canon Log 2 / Rec. 2020"
        case .canonLog2BT709: "Canon Log 2 / Rec. 709"
        case .canonLog3CinemaGamut: "Canon Log 3 / Cinema Gamut"
        case .canonLog3BT2020: "Canon Log 3 / Rec. 2020"
        case .canonLog3BT709: "Canon Log 3 / Rec. 709"
        case .logC3WideGamut3: "LogC3 / ARRI Wide Gamut 3"
        case .logC4WideGamut4: "LogC4 / ARRI Wide Gamut 4"
        case .log3G10RedWideGamut: "Log3G10 / REDWideGamutRGB"
        case .bmdFilmGen5WideGamut: "Blackmagic Film Gen 5 / Wide Gamut"
        case .nLogBT2020: "N-Log / Rec. 2020"
        case .fLog2FGamutC: "F-Log2 / F-Gamut C"
        case .acesCCTAP1: "ACEScct / AP1"
        }
    }

    /// The source color space a clip is rendered with: the clip's own override, else a real detection of the media
    /// (Sony XML S-Log3, HLG/PQ/Apple Log tags, or a file tagged Rec.709), else the project default, else Rec.709.
    /// Only untagged video that detected as Rec.709 takes the project default (Panasonic/DJI log files carry no
    /// color tags); tagged Rec.709 (iPhone SDR, screen recordings, ProRes overlays) keeps Rec.709.
    /// `tagged`: the file has a color primaries or transfer tag (`MediaInfo.hasColorTags`).
    public static func effective(clip: ColorSpaceID?, detected: ColorSpaceID?, tagged: Bool,
                                 projectDefault: ColorSpaceID?) -> ColorSpaceID {
        if let clip { return clip }
        if let detected, detected != .rec709 || tagged { return detected }
        return projectDefault ?? detected ?? .rec709
    }
}

/// Camera brands the input picker offers.
public enum CameraMake: String, Sendable, Hashable, Codable, CaseIterable {
    case sony, iPhone, goPro, dji, panasonic, canon, other
    case arri, red, blackmagic, nikon, fujifilm, aces

    public var displayName: String {
        switch self {
        case .sony: "Sony"
        case .iPhone: "iPhone"
        case .goPro: "GoPro"
        case .dji: "DJI"
        case .panasonic: "Panasonic"
        case .canon: "Canon"
        case .other: "Other"
        case .arri: "ARRI"
        case .red: "RED"
        case .blackmagic: "Blackmagic"
        case .nikon: "Nikon"
        case .fujifilm: "Fujifilm"
        case .aces: "ACES"
        }
    }
}

/// SDR or one of the two HDR encodings.
public enum DynamicRange: String, Sendable, Hashable, Codable, CaseIterable {
    case sdr, hlg, pq
}

/// Camera + Log on/off + SDR/HDR, resolved to a color space. Log wins over the dynamic range.
public struct InputColorProfile: Sendable, Hashable, Codable {
    public var camera: CameraMake
    public var log: Bool
    public var range: DynamicRange
    /// Which of the camera's log curves / color spaces, for a camera with several (Canon); nil = its default
    /// (`logSpace(for:)`). Ignored when it is not one of `logSpaces(for: camera)`.
    public var logVariant: ColorSpaceID?

    public init(camera: CameraMake, log: Bool = false, range: DynamicRange = .sdr, logVariant: ColorSpaceID? = nil) {
        self.camera = camera; self.log = log; self.range = range; self.logVariant = logVariant
    }

    /// The camera's log curve (its default one when it has several); nil when there is none we can convert (GoPro
    /// GP-Log has no published curve). Canon: Canon Log 3 / Cinema Gamut, the pairing Canon recommends for grading.
    public static func logSpace(for camera: CameraMake) -> ColorSpaceID? {
        switch camera {
        case .sony: .sLog3SGamut3Cine
        case .iPhone: .appleLog
        case .dji: .dLogDGamut
        case .panasonic: .vLogVGamut
        case .canon: .canonLog3CinemaGamut
        case .arri: .logC3WideGamut3
        case .red: .log3G10RedWideGamut
        case .blackmagic: .bmdFilmGen5WideGamut
        case .nikon: .nLogBT2020
        case .fujifilm: .fLog2FGamutC
        case .aces: .acesCCTAP1
        case .goPro, .other: nil
        }
    }

    /// Every log space of the camera, the default first.
    public static func logSpaces(for camera: CameraMake) -> [ColorSpaceID] {
        switch camera {
        case .canon:
            [.canonLog3CinemaGamut, .canonLog3BT2020, .canonLog3BT709, .canonLog2CinemaGamut, .canonLog2BT2020,
             .canonLog2BT709, .canonLogCinemaGamut, .canonLogBT2020, .canonLogBT709]
        case .arri: [.logC3WideGamut3, .logC4WideGamut4]
        case .sony, .iPhone, .dji, .panasonic, .goPro, .other, .red, .blackmagic, .nikon, .fujifilm, .aces:
            logSpace(for: camera).map { [$0] } ?? []
        }
    }

    public static func logAvailable(for camera: CameraMake) -> Bool { logSpace(for: camera) != nil }

    /// nil = Log asked for on a camera without a supported log curve.
    public var colorSpace: ColorSpaceID? {
        if log {
            if let logVariant, Self.logSpaces(for: camera).contains(logVariant) { return logVariant }
            return Self.logSpace(for: camera)
        }
        switch range {
        case .sdr: return .rec709
        case .hlg: return .hlgBT2020
        case .pq: return .pqBT2020
        }
    }

    /// A profile that resolves back to `space` (log spaces name their camera; the others say "other").
    public init(describing space: ColorSpaceID) {
        switch space {
        case .rec709: self.init(camera: .other)
        case .hlgBT2020: self.init(camera: .other, range: .hlg)
        case .pqBT2020: self.init(camera: .other, range: .pq)
        case .sLog3SGamut3Cine: self.init(camera: .sony, log: true)
        case .appleLog: self.init(camera: .iPhone, log: true)
        case .dLogDGamut: self.init(camera: .dji, log: true)
        case .vLogVGamut: self.init(camera: .panasonic, log: true)
        case .canonLogCinemaGamut, .canonLogBT2020, .canonLogBT709, .canonLog2CinemaGamut, .canonLog2BT2020,
             .canonLog2BT709, .canonLog3CinemaGamut, .canonLog3BT2020, .canonLog3BT709:
            self.init(camera: .canon, log: true, logVariant: space)
        case .logC3WideGamut3, .logC4WideGamut4: self.init(camera: .arri, log: true, logVariant: space)
        case .log3G10RedWideGamut: self.init(camera: .red, log: true)
        case .bmdFilmGen5WideGamut: self.init(camera: .blackmagic, log: true)
        case .nLogBT2020: self.init(camera: .nikon, log: true)
        case .fLog2FGamutC: self.init(camera: .fujifilm, log: true)
        case .acesCCTAP1: self.init(camera: .aces, log: true)
        }
    }
}

extension MediaInfo {
    /// The video track carries a color primaries or transfer tag (probed at import into `VideoTrackInfo`).
    public var hasColorTags: Bool { video?.colorPrimaries != nil || video?.transfer != nil }

    /// The info the renderer sees under a project default: untagged video (not stills) whose detection found nothing
    /// beyond Rec.709 takes the default as its color space. A real detection, tagged Rec.709 included, is kept.
    public func applyingProjectInput(_ projectDefault: ColorSpaceID?) -> MediaInfo {
        guard let projectDefault, video != nil, !isStill else { return self }
        var out = self
        out.detectedColorSpace = ColorSpaceID.effective(clip: nil, detected: detectedColorSpace, tagged: hasColorTags,
                                                        projectDefault: projectDefault)
        return out
    }
}

extension Project {
    /// `media` with the project input default applied to each item's info (for the render/playback resolvers; the
    /// stored detection stays untouched).
    public var mediaForRendering: [MediaRef] {
        guard inputColorSpace != nil else { return media }
        return media.map { m in
            var m = m
            m.info = m.info?.applyingProjectInput(inputColorSpace)
            return m
        }
    }
}

/// What the inspector's camera / Log / SDR-HLG-PQ picker shows and edits. `camera == nil` is Automatic (no override).
public struct InputPickerState: Sendable, Hashable {
    public private(set) var camera: CameraMake?
    public private(set) var log: Bool
    public private(set) var range: DynamicRange
    /// The chosen log space of a camera with several (Canon); nil = the camera's default.
    public private(set) var logVariant: ColorSpaceID?

    public init(override space: ColorSpaceID?) {
        guard let space else { camera = nil; log = false; range = .sdr; return }
        let p = InputColorProfile(describing: space)
        camera = p.camera; log = p.log; range = p.range; logVariant = p.logVariant
    }

    public var logAvailable: Bool { camera.map(InputColorProfile.logAvailable) ?? false }

    /// The override to store; nil = Automatic.
    public var space: ColorSpaceID? {
        guard let camera else { return nil }
        return InputColorProfile(camera: camera, log: log, range: range, logVariant: logVariant).colorSpace
    }

    /// Picking a camera selects its Log curve when there is one, else SDR.
    public mutating func setCamera(_ c: CameraMake?) {
        camera = c
        log = c.map(InputColorProfile.logAvailable) ?? false
        range = .sdr
        logVariant = nil
    }

    /// Picks one of the camera's log spaces (turns Log on); ignored when the camera does not have it.
    public mutating func setLogVariant(_ space: ColorSpaceID) {
        guard let camera, InputColorProfile.logSpaces(for: camera).contains(space) else { return }
        logVariant = space
        log = true
    }

    public mutating func setLog(_ on: Bool) {
        guard camera != nil else { return }
        log = on && logAvailable
    }

    public mutating func setRange(_ r: DynamicRange) {
        guard camera != nil else { return }
        range = r
    }
}

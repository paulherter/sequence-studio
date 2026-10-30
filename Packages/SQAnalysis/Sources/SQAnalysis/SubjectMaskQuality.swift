import Foundation

/// How a subject mask's edge is made while it is tracked. An app setting of this Mac (`defaultsKey`), not part of the
/// project: mattes tracked before a change keep the edge they were made with until the mask is tracked again.
public enum SubjectMaskQuality: String, Sendable, CaseIterable, Equatable {
    /// The frames are read at up to twice the tracking size (long edge at most `longEdge`) and the matte is made at
    /// that size from the color picture (`SubjectMatteRefiner`): soft alpha along hair and fine edges.
    case quality
    /// The matte at the tracking size with the quick edge step (`SubjectMatteEdges`).
    case speed

    public static let defaultsKey = "sq.subjectMask.quality"
    /// Long edge of the largest matte Quality makes.
    public static let longEdge = 1920

    /// Quality on Apple silicon, Speed on Intel Macs.
    public static var standard: SubjectMaskQuality {
        #if arch(arm64)
        .quality
        #else
        .speed
        #endif
    }

    public var title: String {
        switch self {
        case .quality: "Quality"
        case .speed: "Speed"
        }
    }

    /// The stored choice; a missing or unknown value is the default.
    public static func stored(in defaults: UserDefaults = .standard) -> SubjectMaskQuality {
        defaults.string(forKey: defaultsKey).flatMap(SubjectMaskQuality.init(rawValue:)) ?? standard
    }

    public func store(in defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }

    /// Long edge the frames of a track are read at: `analysis` is the size the tracking itself works at on this Mac
    /// (`WorkLimits.subjectMaskDimension`), so a small Mac gets a smaller Quality matte too.
    public func frameDimension(analysis: Int) -> Int {
        self == .quality ? max(analysis, min(Self.longEdge, analysis * 2)) : analysis
    }
}

import SQMedia

/// Playback quality. The fixed cases map 1:1 to SQMedia `DecodeScale` (1/8 and 1/16 were removed: the decoder has no
/// finer step than quarter, so they were indistinguishable from it). `auto` is a monitor-only choice
/// (`AutoQualityGovernor`): the monitor model resolves it to one of the fixed qualities before it reaches the engine.
public enum MonitorQuality: String, Sendable, Hashable, CaseIterable {
    case full, half, quarter, auto

    /// The fixed qualities (Settings lists these; Auto is its own entry there).
    public static var allCases: [MonitorQuality] { [.full, .half, .quarter] }
    /// Monitor popup rows: the fixed qualities, then Auto.
    public static var menuCases: [MonitorQuality] { allCases + [.auto] }

    public var divisor: Int {
        switch self { case .full, .auto: 1; case .half: 2; case .quarter: 4 }
    }
    public var title: String {
        switch self { case .full: "Full"; case .half: "1/2"; case .quarter: "1/4"; case .auto: "Auto" }
    }
    public var decodeScale: DecodeScale {
        switch self {
        case .full, .auto: .full
        case .half: .half
        case .quarter: .quarter
        }
    }
    public init(_ scale: DecodeScale) { switch scale { case .full: self = .full; case .half: self = .half; case .quarter: self = .quarter } }
}

extension MonitorQuality {
    /// Corner-badge form: "½", "¼"; nil for full quality (the badge then shows only the zoom).
    public var badgeSymbol: String? {
        switch self { case .full: nil; case .half: "½"; case .quarter: "¼"; case .auto: "Auto" }
    }
}

extension MonitorQuality {
    /// A stored raw value; the retired "eighth" and "sixteenth" (old builds) read as quarter, what they decoded at.
    public static func stored(_ raw: String) -> MonitorQuality? {
        raw == "eighth" || raw == "sixteenth" ? .quarter : MonitorQuality(rawValue: raw)
    }
}

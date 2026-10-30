import Foundation

/// Guesses which source color space a LUT file expects from its file name (camera LUTs are named after the log
/// curve), so the Color inspector can warn when the clip is in another space. Pure name matching: a LUT whose name says
/// nothing has no expectation and never warns.
public enum LUTSpaceHint {
    private static let table: [(tokens: [String], space: ColorSpaceID)] = [
        (["slog3", "s-log3", "slog-3"], .sLog3SGamut3Cine),
        (["vlog", "v-log"], .vLogVGamut),
        (["applelog", "apple log"], .appleLog),
        (["dlog", "d-log"], .dLogDGamut),
        (["clog3", "canonlog3", "c-log3", "canon log 3"], .canonLog3CinemaGamut),
        (["clog2", "canonlog2", "c-log2", "canon log 2"], .canonLog2CinemaGamut),
        (["clog", "canonlog", "c-log", "canon log"], .canonLogCinemaGamut),
        (["logc4", "log-c4"], .logC4WideGamut4),
        (["logc3", "logc", "log-c"], .logC3WideGamut3),
        (["log3g10"], .log3G10RedWideGamut),
        (["flog2", "f-log2"], .fLog2FGamutC),
        (["nlog", "n-log"], .nLogBT2020),
        (["acescct"], .acesCCTAP1),
        (["hlg"], .hlgBT2020),
        (["rec709", "rec.709", "rec 709", "bt709", "bt.709"], .rec709),
    ]

    /// The space the LUT's name implies, nil when unknown.
    public static func expectedSpace(forFileName name: String) -> ColorSpaceID? {
        let n = (name as NSString).deletingPathExtension.lowercased()
        return table.first { row in row.tokens.contains { n.contains($0) } }?.space
    }

    /// Same transfer curve, any gamut variant (Canon's three gamut variants of one log are one family).
    private static func family(_ s: ColorSpaceID) -> Int {
        switch s {
        case .canonLogCinemaGamut, .canonLogBT2020, .canonLogBT709: 1
        case .canonLog2CinemaGamut, .canonLog2BT2020, .canonLog2BT709: 2
        case .canonLog3CinemaGamut, .canonLog3BT2020, .canonLog3BT709: 3
        default: 100 + (ColorSpaceID.allCases.firstIndex(of: s) ?? 0)
        }
    }

    /// The warning for a LUT picked on a clip in `source`; nil when it fits or the LUT's name gives no hint.
    public static func mismatch(lutFileName: String, source: ColorSpaceID) -> (expected: ColorSpaceID, message: String)? {
        guard let want = expectedSpace(forFileName: lutFileName), family(want) != family(source) else { return nil }
        return (want, "This LUT looks made for \(want.hintName) footage; the clip is \(source.hintName).")
    }
}

extension ColorSpaceID {
    /// Short name for warnings.
    var hintName: String {
        switch self {
        case .rec709: "Rec.709"
        case .sLog3SGamut3Cine: "S-Log3"
        case .hlgBT2020: "HLG"
        case .pqBT2020: "PQ"
        case .vLogVGamut: "V-Log"
        case .appleLog: "Apple Log"
        case .dLogDGamut: "D-Log"
        case .canonLogCinemaGamut, .canonLogBT2020, .canonLogBT709: "Canon Log"
        case .canonLog2CinemaGamut, .canonLog2BT2020, .canonLog2BT709: "Canon Log 2"
        case .canonLog3CinemaGamut, .canonLog3BT2020, .canonLog3BT709: "Canon Log 3"
        case .logC3WideGamut3: "LogC3"
        case .logC4WideGamut4: "LogC4"
        case .log3G10RedWideGamut: "Log3G10"
        case .bmdFilmGen5WideGamut: "Blackmagic Film"
        case .nLogBT2020: "N-Log"
        case .fLog2FGamutC: "F-Log2"
        case .acesCCTAP1: "ACEScct"
        }
    }
}

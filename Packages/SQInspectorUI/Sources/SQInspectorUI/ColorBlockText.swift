import Foundation
import SQUIKit

/// Translates the English block reasons of the SQCore color solvers (SQCore cannot import SQUIKit). Reasons that carry a
/// color space or section name are matched by their fixed prefix and suffix and keep that name.
enum ColorBlockText {
    private static let patterns: [(prefix: String, suffix: String, key: String)] = [
        ("Match works on Rec. 709 footage. This clip is interpreted as ", "; grade it by hand.",
         "Match works on Rec. 709 footage. This clip is interpreted as %@; grade it by hand."),
        ("Auto Tone works on Rec. 709 footage. This clip is interpreted as ", "; grade it by hand.",
         "Auto Tone works on Rec. 709 footage. This clip is interpreted as %@; grade it by hand."),
    ]

    static func localized(_ reason: String) -> String {
        for p in patterns where reason.hasPrefix(p.prefix) && reason.hasSuffix(p.suffix) {
            let name = String(reason.dropFirst(p.prefix.count).dropLast(p.suffix.count))
            return SQL10n.format(p.key, name)
        }
        let tonePrefix = "Auto Tone would measure ", toneMid = " too. Reset or switch off ", toneEnd = " first."
        if reason.hasPrefix(tonePrefix), reason.hasSuffix(toneEnd),
           let r = reason.range(of: toneMid) {
            let name = String(reason[reason.index(reason.startIndex, offsetBy: tonePrefix.count)..<r.lowerBound])
            return SQL10n.format("Auto Tone would measure %@ too. Reset or switch off %@ first.", SQL10n.string(name), SQL10n.string(name))
        }
        return SQL10n.string(reason)
    }
}

import Foundation
import SQCore

extension StyleKit {
    /// "the maintainer's Kit" (W8.6): the caption look of his Premiere projects (docs/research/E2-paul-videos.md 2.4): Inter Bold, white,
    /// soft dark shadow (the "classic" base style), the caption pop, caption y 0.707 (C1-own-style). Only values the research documents are set; unknown ones
    /// stay nil (caption size, emphasis pill color, motion defaults, "Folgen" overlay slot, audio chain, punch-in preset,
    /// see the roadmap "W8.6 SeedKit follow-ups").
    public static var pauls: StyleKit {
        StyleKit(fonts: [brandFontToken: "Inter-Bold"],
                 colors: [textColorToken: .white],
                 caption: CaptionStyleSpec(baseStyle: "classic", font: .token(brandFontToken), textColor: .token(textColorToken)),
                 captionPosition: CaptionPosition(vertical: .middle, offsetY: 0.707 - 0.5))
    }
}

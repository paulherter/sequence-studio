import Foundation
import SQCore

/// Look of the caption text box; resolved by the renderer (SQText), not by the segmenter.
public enum CaptionEmphasis: String, Sendable, Hashable, Codable {
    case none
    /// Rounded filled box behind the text.
    case pill
}

/// Segmentation limits plus opaque style/animation references (resolved elsewhere).
/// The options of Premiere's Create Captions dialog: characters per line, single or double line, minimum duration, gap.
public struct CaptionPreset: Sendable, Hashable, Codable {
    public var maxCharsPerLine: Int
    public var maxLines: Int
    public var maxDuration: Time
    /// Minimum time a caption stays on screen: shorter ones are extended into the silence after them
    /// (`CaptionSegmenter.applyTiming`). It is also a soft limit for sentence-end splits.
    public var minDuration: Time
    /// A silence between two words at least this long starts a new caption.
    public var pauseBreak: Time
    public var styleRef: String
    public var animationRef: String
    /// Smallest time between the end of a caption and the start of the next one (Premiere: gap in frames).
    public var gap: Time
    /// Hard cap on words per caption (short-video style: 1). nil = limited only by line/duration rules.
    /// When set to 1, a word longer than `maxCharsPerLine` stays whole (words are never split) and too-short
    /// captions borrow time from or merge with a neighbor so `minDuration` always holds.
    public var maxWordsPerCaption: Int?
    public var emphasis: CaptionEmphasis

    /// Premiere's name for the gap between captions.
    public var minGap: Time {
        get { gap }
        set { gap = max(.zero, newValue) }
    }

    public init(maxCharsPerLine: Int, maxLines: Int, maxDuration: Time, minDuration: Time,
                pauseBreak: Time, styleRef: String, animationRef: String, gap: Time = .zero,
                maxWordsPerCaption: Int? = nil, emphasis: CaptionEmphasis = .none) {
        self.maxCharsPerLine = maxCharsPerLine
        self.maxLines = maxLines
        self.maxDuration = maxDuration
        self.minDuration = minDuration
        self.pauseBreak = pauseBreak
        self.styleRef = styleRef
        self.animationRef = animationRef
        self.gap = gap
        self.maxWordsPerCaption = maxWordsPerCaption
        self.emphasis = emphasis
    }

    private enum CodingKeys: String, CodingKey {
        case maxCharsPerLine, maxLines, maxDuration, minDuration, pauseBreak, styleRef, animationRef, gap, maxWordsPerCaption, emphasis
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(maxCharsPerLine: try c.decode(Int.self, forKey: .maxCharsPerLine),
                  maxLines: try c.decode(Int.self, forKey: .maxLines),
                  maxDuration: try c.decode(Time.self, forKey: .maxDuration),
                  minDuration: try c.decode(Time.self, forKey: .minDuration),
                  pauseBreak: try c.decode(Time.self, forKey: .pauseBreak),
                  styleRef: try c.decode(String.self, forKey: .styleRef),
                  animationRef: try c.decode(String.self, forKey: .animationRef),
                  gap: try c.decodeIfPresent(Time.self, forKey: .gap) ?? .zero,
                  maxWordsPerCaption: try c.decodeIfPresent(Int.self, forKey: .maxWordsPerCaption),
                  emphasis: try c.decodeIfPresent(CaptionEmphasis.self, forKey: .emphasis) ?? .none)
    }

    public static let standard = CaptionPreset(
        maxCharsPerLine: 42, maxLines: 2, maxDuration: Time(6, 1), minDuration: Time(1, 1),
        pauseBreak: Time(4, 5), styleRef: "default", animationRef: "caption-pop")

    /// Short-video look: one word per caption, at least 0.2 s, at most 11 characters (a longer word stays whole),
    /// pill emphasis.
    public static let shortVideo = CaptionPreset(
        maxCharsPerLine: 11, maxLines: 1, maxDuration: Time(3, 1), minDuration: Time(1, 5),
        pauseBreak: Time(1, 2), styleRef: "pill", animationRef: "caption-pop",
        maxWordsPerCaption: 1, emphasis: .pill)

    /// The dialog's fields, clamped to sane values: 8...100 characters, one or two lines.
    public func with(maxCharsPerLine: Int? = nil, lines: Int? = nil, minDuration: Time? = nil,
                     gapFrames: Int? = nil, frameDuration: Time = Time(1, 30)) -> CaptionPreset {
        var p = self
        if let m = maxCharsPerLine { p.maxCharsPerLine = min(max(m, 8), 100) }
        if let l = lines { p.maxLines = l <= 1 ? 1 : 2 }
        if let d = minDuration { p.minDuration = max(.zero, d) }
        if let g = gapFrames { p.gap = frameDuration * Int64(max(0, g)) }
        return p
    }
}

import Foundation
import SQCore

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

    public init(maxCharsPerLine: Int, maxLines: Int, maxDuration: Time, minDuration: Time,
                pauseBreak: Time, styleRef: String, animationRef: String, gap: Time = .zero) {
        self.maxCharsPerLine = maxCharsPerLine
        self.maxLines = maxLines
        self.maxDuration = maxDuration
        self.minDuration = minDuration
        self.pauseBreak = pauseBreak
        self.styleRef = styleRef
        self.animationRef = animationRef
        self.gap = gap
    }

    private enum CodingKeys: String, CodingKey {
        case maxCharsPerLine, maxLines, maxDuration, minDuration, pauseBreak, styleRef, animationRef, gap
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
                  gap: try c.decodeIfPresent(Time.self, forKey: .gap) ?? .zero)
    }

    public static let standard = CaptionPreset(
        maxCharsPerLine: 42, maxLines: 2, maxDuration: Time(6, 1), minDuration: Time(1, 1),
        pauseBreak: Time(4, 5), styleRef: "default", animationRef: "none")

    /// One short line in a big heavy style, for vertical video.
    public static let shortVideo = CaptionPreset(
        maxCharsPerLine: 18, maxLines: 1, maxDuration: Time(3, 1), minDuration: Time(1, 2),
        pauseBreak: Time(1, 2), styleRef: "tiktok", animationRef: "none")

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

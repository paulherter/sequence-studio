import SSCore

/// Segmentation limits plus opaque style/animation references (resolved elsewhere).
public struct CaptionPreset: Sendable, Hashable, Codable {
    public var maxCharsPerLine: Int
    public var maxLines: Int
    public var maxDuration: Time
    /// Soft minimum: a sentence end does not split a caption shorter than this.
    public var minDuration: Time
    /// A silence between two words at least this long starts a new caption.
    public var pauseBreak: Time
    public var styleRef: String
    public var animationRef: String

    public init(maxCharsPerLine: Int, maxLines: Int, maxDuration: Time, minDuration: Time,
                pauseBreak: Time, styleRef: String, animationRef: String) {
        self.maxCharsPerLine = maxCharsPerLine
        self.maxLines = maxLines
        self.maxDuration = maxDuration
        self.minDuration = minDuration
        self.pauseBreak = pauseBreak
        self.styleRef = styleRef
        self.animationRef = animationRef
    }

    public static let standard = CaptionPreset(
        maxCharsPerLine: 42, maxLines: 2, maxDuration: Time(6, 1), minDuration: Time(1, 1),
        pauseBreak: Time(4, 5), styleRef: "default", animationRef: "none")
}

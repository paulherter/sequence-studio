import AppKit

// Timeline skin (design B: ruler, clips, In/Out band, markers).

extension Theme {
    /// Timeline paint values that were alpha literals in the drawing code (sq.css `.clip`, `.thh`, `.iov`, `.phd`).
    /// Values are the design's; the names let the drawing read tokens only.
    public enum TimelineSkin {
        /// `.clip` inset 0.5 px edge: white 22 % over every clip fill.
        public static let clipEdge = Theme.white(0.22)
        /// `.thh` right rule of the thumbnail column.
        public static let thumbRule = Theme.black(0.35)
        /// Waveform ink on a clip.
        public static let waveform = Theme.white(0.55)
        /// Clip name on a light label fill (black; `LabelColor.onFill` picks it for >= 4.5:1).
        public static let nameOnLight = Theme.black(1)
        /// `fx` pill behind the badge text.
        public static let fxPill = Theme.black(0.5)
        /// `.iov`: neutral wash over the lanes between In and Out, and its 1 pt edges.
        public static let inOutBand = Theme.white(0.13)
        public static let inOutBandEdge = Theme.white(0.38)
        /// Ruler strip of cached frames (accent at 60 %).
        public static let cacheStrip = Colors.accent.withAlphaComponent(0.6)
        /// Opened Graphic item bar (accent at 45 %).
        public static let itemBar = Colors.accent.withAlphaComponent(0.45)
        /// Silence preview band and its edge (red tints).
        public static let silenceFill = Colors.red.withAlphaComponent(0.28)
        public static let silenceEdge = Colors.red.withAlphaComponent(0.9)
        /// Ducking curve over an audio clip.
        public static let duckCurve = Colors.warning.withAlphaComponent(0.9)
        /// Unresolved transition outline (red at 55 %).
        public static let transitionIssue = Colors.red.withAlphaComponent(0.55)
    }
}

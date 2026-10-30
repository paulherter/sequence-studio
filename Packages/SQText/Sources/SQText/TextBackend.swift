import Foundation

/// Seam between the portable layout (`TextLayout`) and the platform's text engine (the Windows port plan "Seam 2 status").
/// macOS: Core Text (`TextBackend+CoreText.swift`, unchanged behavior). Elsewhere: `TextBackend+Portable.swift`.

/// Vertical metrics of a font in points (y up, all positive).
struct TextFontMetrics: Sendable, Equatable {
    var ascent: Double, descent: Double, leading: Double
}

/// What the line breaker needs from a typeset paragraph: widths of UTF-16 ranges.
struct TextLineMetrics: Sendable, Equatable {
    /// Typographic width of the line, trailing whitespace included.
    var width: Double
    var trailingWhitespace: Double
    var ascent: Double, descent: Double, leading: Double
}

protocol LineTypesetting {
    /// Metrics of the line made of `length` UTF-16 units from `location`.
    func line(location: Int, length: Int) -> TextLineMetrics
}

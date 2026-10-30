import Foundation

/// Validation of the New Project sheet's inputs (kept out of the AppKit sheet so it is testable).
public enum NewProjectInput {
    public static let defaultName = "Untitled Project"

    /// The format the choices describe: the template's, with the typed size, the chosen rate and sample rate.
    /// A size outside 1...maxDimension (either side) keeps the template's size; an unknown rate index keeps its rate.
    public static func resolve(base: SequenceFormat, width: Int, height: Int, rateIndex: Int, sampleRate: Int?) -> SequenceFormat {
        var f = base
        let max = SequenceFormatPresets.maxDimension
        if (1...max).contains(width), (1...max).contains(height) { f.width = width; f.height = height }
        let rates = SequenceFormatPresets.frameRates
        if rates.indices.contains(rateIndex) { f.frameDuration = rates[rateIndex].frameDuration }
        if let sampleRate, sampleRate > 0 { f.audioSampleRate = sampleRate }
        return f
    }

    /// The typed name, trimmed; empty or whitespace-only falls back to the default.
    public static func name(typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? defaultName : t
    }
}

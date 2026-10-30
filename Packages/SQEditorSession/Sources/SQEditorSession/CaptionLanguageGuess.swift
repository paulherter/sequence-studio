import Foundation
import NaturalLanguage

/// Auto language for transcription: after a run in the chosen language, the text itself tells whether another supported
/// language was spoken. One retry in that language; a wrong guess never loops (the host retries once per run).
public enum CaptionLanguageGuess {
    /// Fewer letters than this say too little about the language.
    static let minimumLetters = 24
    /// Recognizer confidence needed before a re-run is worth its time.
    static let minimumConfidence = 0.85

    /// The supported locale to transcribe again in, or nil when `text` is too short, too unsure, already in the language of
    /// `used`, or in a language `supported` has no locale for. Of several regions the system language's region wins.
    public static func retryLanguage(text: String, used: String, supported: [String],
                                     preferred: [String] = Locale.preferredLanguages) -> String? {
        guard text.filter(\.isLetter).count >= minimumLetters else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= minimumConfidence else { return nil }
        let code = lang.rawValue
        func base(_ id: String) -> String { String(id.prefix { $0 != "-" && $0 != "_" }).lowercased() }
        guard base(used) != code else { return nil }
        let matches = supported.filter { base($0) == code }
        guard !matches.isEmpty else { return nil }
        for id in preferred { if let m = matches.first(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) { return m } }
        return matches.first
    }
}

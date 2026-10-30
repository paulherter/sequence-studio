import Foundation

/// The languages of the multilingual Whisper models and how a BCP-47 locale maps to them.
public enum WhisperLanguages {
    static let codes: Set<String> = Set(("en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt "
        + "la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo "
        + "ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su").split(separator: " ").map(String.init))

    /// The Whisper language code of `locale` ("de-DE" -> "de"), nil when the model does not know the language.
    public static func code(for locale: Locale) -> String? {
        guard var id = locale.language.languageCode?.identifier.lowercased() else { return nil }
        if id == "nb" { id = "no" }
        return codes.contains(id) ? id : nil
    }

    /// Identifiers for the language pop-up: the six defaults of the panel keep their regions (so the list holds no
    /// duplicates of the stored choice), everything else is the bare code.
    public static let supported: [String] = {
        let regional: [String: [String]] = ["de": ["de-DE"], "en": ["en-US", "en-GB"], "fr": ["fr-FR"], "es": ["es-ES"], "it": ["it-IT"]]
        return codes.sorted().flatMap { regional[$0] ?? [$0] }
    }()
}

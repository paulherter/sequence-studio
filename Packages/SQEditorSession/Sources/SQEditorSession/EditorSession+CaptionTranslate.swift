import Foundation
import SQUIKit
import NaturalLanguage
import SQCore
import Translation

/// On-device caption translation (Apple Translation framework, headless session for installed language pairs: no system sheet,
/// no network) and the one-click timing pass. The translation is a new caption track with the same timings and look.
public enum CaptionTranslator {
    public struct Failure: Error, Sendable, LocalizedError {
        public var errorDescription: String?
    }

    /// Languages the system can translate into, as BCP-47 codes with English names, sorted by name.
    public static func supportedTargets() async -> [(code: String, name: String)] {
        let langs = await LanguageAvailability().supportedLanguages
        var seen = Set<String>(), out: [(String, String)] = []
        for l in langs {
            let code = l.minimalIdentifier
            guard seen.insert(code).inserted else { continue }
            out.append((code, Locale(identifier: "en").localizedString(forIdentifier: code) ?? code))
        }
        return out.sorted { $0.1 < $1.1 }
    }

    /// The dominant language of `texts` (nil when it cannot be told).
    public static func detectLanguage(of texts: [String]) -> Locale.Language? {
        let r = NLLanguageRecognizer()
        r.processString(texts.joined(separator: ". "))
        return r.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    /// Translates `texts` (same order). Throws a readable `Failure` when the pair is not installed.
    public static func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        let status = await LanguageAvailability().status(from: source, to: target)
        let pair = "\(source.minimalIdentifier) to \(target.minimalIdentifier)"
        switch status {
        case .installed: break
        case .supported:
            throw Failure(errorDescription: SQL10n.format("The %@ language pack is not installed. Add it in System Settings > General > Language & Region > Translation Languages.", pair))
        default:
            throw Failure(errorDescription: SQL10n.format("Translation %@ is not supported on this Mac.", pair))
        }
        let session = TranslationSession(installedSource: source, target: target)
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        let responses = try await session.translations(from: requests)
        var out = texts
        for r in responses { if let i = r.clientIdentifier.flatMap(Int.init), out.indices.contains(i) { out[i] = r.targetText } }
        return out
    }
}

extension EditorSession {
    /// Translates the current caption track into `target` (BCP-47 code) as a new caption track "<name> (<code>)" with the same
    /// timings and look; the source language is detected from the text. One undo step. Returns the new track, or nil with `lastError` set.
    @discardableResult
    public func translateCaptions(to target: String) async -> CaptionTrack.ID? {
        guard let track = currentCaptionTrack, !track.items.isEmpty else { setError("There are no captions to translate."); return nil }
        let texts = track.items.map { $0.lines.joined(separator: " ") }
        guard let source = CaptionTranslator.detectLanguage(of: texts) else { setError("Could not tell the language of the captions."); return nil }
        let to = Locale.Language(identifier: target)
        guard source.minimalIdentifier != to.minimalIdentifier else { setError("The captions are already in that language."); return nil }
        let translated: [String]
        do { translated = try await CaptionTranslator.translate(texts, from: source, to: to) } catch {
            setError(SQL10n.errorText(error)); return nil
        }
        guard let items = CaptionTranslation.translatedItems(from: track.items, texts: translated) else { return nil }
        var made: CaptionTrack.ID?
        let name = CaptionTranslation.trackName(source: track.name, language: to.minimalIdentifier)
        let ok = attempt("Translate Captions") { t in
            let id = t.addCaptionTrack()
            guard let i = t.captionTracks.firstIndex(where: { $0.id == id }) else { return }
            t.captionTracks[i].name = name
            t.captionTracks[i].styleRef = track.styleRef; t.captionTracks[i].animationRef = track.animationRef
            t.captionTracks[i].karaoke = track.karaoke
            _ = try t.replaceCaptions(items, track: id)
            made = id
        }
        if ok, let made { captionTrackFocus = made; notify(.selection) }
        return ok ? made : nil
    }
}

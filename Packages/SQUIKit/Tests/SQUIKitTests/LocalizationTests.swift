import Foundation
import SQCore
import Testing
@testable import SQUIKit

@Suite("Localization")
struct LocalizationTests {
    @Test func overrideWinsOverSystem() {
        #expect(SQL10n.resolveLanguage(override: "de", preferred: ["en-US"]) == "de")
        #expect(SQL10n.resolveLanguage(override: "en", preferred: ["de-DE"]) == "en")
    }

    @Test func systemLanguageIsFollowedWhenSupported() {
        #expect(SQL10n.resolveLanguage(override: nil, preferred: ["de-DE", "en-US"]) == "de")
        #expect(SQL10n.resolveLanguage(override: "system", preferred: ["de-AT"]) == "de")
        // First supported language in the preference list wins; unsupported ones are skipped.
        #expect(SQL10n.resolveLanguage(override: nil, preferred: ["fr-FR", "de-DE"]) == "de")
    }

    @Test func unsupportedFallsBackToEnglish() {
        #expect(SQL10n.resolveLanguage(override: nil, preferred: ["fr-FR"]) == "en")
        #expect(SQL10n.resolveLanguage(override: "xx", preferred: ["fr"]) == "en")
        #expect(SQL10n.resolveLanguage(override: nil, preferred: []) == "en")
    }

    @Test func environmentNeverForcesALanguageInsideTheApp() {
        // A shell or launcher that exports SQ_LANGUAGE=de must not turn the shipped app German over the user's choice.
        #expect(SQL10n.effectiveOverride(env: "de", stored: "en", isAppBundle: true) == "en")
        #expect(SQL10n.effectiveOverride(env: "de", stored: nil, isAppBundle: true) == nil)
        // Outside an app bundle (tests, scripts) the variable wins; empty means unset.
        #expect(SQL10n.effectiveOverride(env: "en", stored: "de", isAppBundle: false) == "en")
        #expect(SQL10n.effectiveOverride(env: "", stored: "de", isAppBundle: false) == "de")
    }

    @Test func englishChoiceBeatsAGermanSystem() {
        let o = SQL10n.effectiveOverride(env: nil, stored: "en", isAppBundle: true)
        #expect(SQL10n.resolveLanguage(override: o, preferred: ["de-DE", "en-US"]) == "en")
        // "System" (stored as no value) follows macOS.
        let s = SQL10n.effectiveOverride(env: nil, stored: nil, isAppBundle: true)
        #expect(SQL10n.resolveLanguage(override: s, preferred: ["de-DE", "en-US"]) == "de")
    }

    @Test func lookupTranslatesAndFallsBack() {
        #expect(SQL10n.string("File", language: "de") == "Datei")
        #expect(SQL10n.string("File", language: "en") == "File")
        #expect(SQL10n.string("No such key anywhere", language: "de") == "No such key anywhere")
    }

    @Test func formatLookupSubstitutes() {
        #expect(SQL10n.format("Show %@", "Timeline", language: "en") == "Show Timeline")
    }

    @Test func germanCatalogCoversTheFirstSlice() {
        let missing = SQL10n.missingKeys(in: "de", required: SQL10n.requiredKeys)
        #expect(missing.isEmpty, "Missing German strings: \(missing)")
    }

    @Test func germanCatalogHasNoEmptyValuesOrStrayKeys() {
        let table = SQL10n.table(for: "de")
        #expect(!table.isEmpty)
        for (key, value) in table {
            #expect(!value.isEmpty, "empty German value for \(key)")
            // Format specifiers must match the English source.
            #expect(key.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count, "specifier mismatch: \(key)")
        }
    }

    @Test func requiredKeysCoverMenusAndPanels() {
        let keys = Set(SQL10n.requiredKeys)
        for spec in EditorMenus.all { #expect(keys.contains(spec.title)) }
        for p in PanelID.allCases { #expect(keys.contains(EditorCommand.panelTitle(p))) }
        for c in EditorMenus.all.flatMap(\.commands) { #expect(keys.contains(c.title), "menu command not required: \(c.title)") }
        for k in SQL10n.settingsKeys { #expect(keys.contains(k)) }
    }

    @Test func filledInEngineMessagesTranslateByPattern() {
        #expect(SQL10n.localized("“Beach.mov” was not found.", language: "de") == "„Beach.mov“ wurde nicht gefunden.")
        #expect(SQL10n.localized("This item has no sound.", language: "de") == "Dieses Medium hat keinen Ton.")
        // Nested: the captured reason is translated too.
        #expect(SQL10n.localized("The file could not be written: The file has no audio track.", language: "de")
                == "Die Datei konnte nicht geschrieben werden: Die Datei hat keine Audiospur.")
        #expect(SQL10n.localized("Unknown engine text", language: "de") == "Unknown engine text")
        #expect(SQL10n.localized("This item has no sound.", language: "en") == "This item has no sound.")
    }

    @Test func interpolatedAlertsAndStatusLinesTranslate() {
        #expect(SQL10n.format("Delete “%@”?", "Mix", language: "de") == "„Mix“ löschen?")
        #expect(SQL10n.format("%@ needs %@.", "Blur", "einen Videoclip", language: "de") == "Blur braucht einen Videoclip.")
        #expect(SQL10n.plural(2, one: "Reconnected %@ media file.", other: "Reconnected %@ media files.", language: "de")
                == "2 Mediendateien neu verbunden.")
        #expect(SQL10n.format("Remove In and Out: %@", "I / O", language: "de") == "Ein und Aus entfernen: I / O")
    }

    @Test func pluralPicksFormAndTranslates() {
        #expect(SQL10n.plural(1, one: "%@ Step", other: "%@ Steps", language: "en") == "1 Step")
        #expect(SQL10n.plural(3, one: "%@ Step", other: "%@ Steps", language: "en") == "3 Steps")
        #expect(SQL10n.plural(3, one: "%@ Step", other: "%@ Steps", language: "de") == "3 Schritte")
    }

    @Test func importAndVoiceErrorsTranslateThroughErrorText() {
        // Real SQCore errors (their English description is the key).
        #expect(SQL10n.errorText(LottieImportError.invalid, language: "de").hasPrefix("Das ist keine Lottie-Animation"))
        #expect(SQL10n.errorText(DisguiseVoiceError.linkedAudioLocked, language: "de").hasPrefix("Ein verknüpfter Audioclip"))
        // Descriptions of the SQPremiereImport / SQAnalysis errors (those packages cannot be imported here).
        #expect(SQL10n.localized("The file could not be read: no sequence", language: "de") == "Die Datei konnte nicht gelesen werden: keine Sequenz")
        #expect(SQL10n.localized("Not a supported interchange file: not an FCPXML file", language: "de")
                == "Keine unterstützte Austauschdatei: keine FCPXML-Datei")
        #expect(SQL10n.localized("Not a supported interchange file: .abc", language: "de") == "Keine unterstützte Austauschdatei: .abc")
        #expect(SQL10n.localized("Not a supported interchange file: unknown format", language: "de")
                == "Keine unterstützte Austauschdatei: unbekanntes Format")
        #expect(SQL10n.localized("The file could not be read: no OpenTimelineIO timeline", language: "de")
                == "Die Datei konnte nicht gelesen werden: keine OpenTimelineIO-Timeline")
        #expect(SQL10n.localized("the file gave no frame at 1.250 s", language: "de") == "die Datei lieferte bei 1.250 s kein Bild")
    }

    @Test func undoNamesTranslateExactAndPatterned() {
        #expect(SQL10n.undoName("Close Gap", language: "de") == "Lücke schließen")
        #expect(SQL10n.undoName("Reset Opacity to Automatic", language: "de") == "Deckkraft auf Automatisch zurücksetzen")
        #expect(SQL10n.format("Undo %@", SQL10n.undoName("Close Gap", language: "de"), language: "de") == "Lücke schließen widerrufen")
        #expect(SQL10n.undoName("Animate Opacity", language: "en") == "Animate Opacity")
        #expect(SQL10n.undoName("Add Mask", language: "de") == "Maske hinzufügen")
        #expect(SQL10n.undoName("Animate Opacity", language: "de") == "Deckkraft animieren")
        // The longer pattern wins over "Add %@".
        #expect(SQL10n.undoName("Add Opacity Keyframe", language: "de") == "Deckkraft-Keyframe hinzufügen")
        #expect(SQL10n.undoName("Something Unknown", language: "de") == "Something Unknown")
    }
}

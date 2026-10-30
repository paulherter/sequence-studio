import Foundation

/// Open-source fonts that ship with the app (all SIL OFL 1.1, each with its own `OFL.txt` next to the files in
/// `Resources/Fonts/Families/<folder>`). Registered for the running process only; nothing is installed on the Mac.
/// Only the weights creators use are bundled: variable fonts carry their whole weight range, static families only the
/// listed faces. Inter (the default font) is bundled separately, see `InterFont`.
public enum BundledFonts {
    public enum Category: String, Sendable, CaseIterable {
        case impact, sans, rounded, serif, script, display
    }

    public struct Family: Sendable, Equatable {
        /// Family name as Core Text reports it (what `TextStyle.fontName` holds).
        public let name: String
        /// Folder under `Resources/Fonts/Families`.
        public let folder: String
        /// Font files (without extension) in that folder.
        public let files: [String]
        public let category: Category
    }

    /// ~25 families typical for titles and captions. License of every entry is OFL 1.1 (checked per `OFL.txt`).
    public static let families: [Family] = [
        .init(name: "Bebas Neue", folder: "bebasneue", files: ["BebasNeue-Regular"], category: .impact),
        .init(name: "Anton", folder: "anton", files: ["Anton-Regular"], category: .impact),
        .init(name: "Oswald", folder: "oswald", files: ["Oswald[wght]"], category: .impact),
        .init(name: "Archivo Black", folder: "archivoblack", files: ["ArchivoBlack-Regular"], category: .impact),
        .init(name: "League Spartan", folder: "leaguespartan", files: ["LeagueSpartan[wght]"], category: .impact),
        .init(name: "Passion One", folder: "passionone", files: ["PassionOne-Regular"], category: .impact),
        .init(name: "Russo One", folder: "russoone", files: ["RussoOne-Regular"], category: .impact),
        .init(name: "Montserrat", folder: "montserrat", files: ["Montserrat[wght]"], category: .sans),
        .init(name: "Poppins", folder: "poppins", files: ["Poppins-Medium", "Poppins-Bold", "Poppins-ExtraBold"], category: .sans),
        .init(name: "Rubik", folder: "rubik", files: ["Rubik[wght]"], category: .sans),
        .init(name: "Space Grotesk", folder: "spacegrotesk", files: ["SpaceGrotesk[wght]"], category: .sans),
        .init(name: "Outfit", folder: "outfit", files: ["Outfit[wght]"], category: .sans),
        .init(name: "Fredoka", folder: "fredoka", files: ["Fredoka[wdth,wght]"], category: .rounded),
        .init(name: "Lilita One", folder: "lilitaone", files: ["LilitaOne-Regular"], category: .rounded),
        .init(name: "Righteous", folder: "righteous", files: ["Righteous-Regular"], category: .rounded),
        .init(name: "Playfair Display", folder: "playfairdisplay", files: ["PlayfairDisplay[wght]"], category: .serif),
        .init(name: "DM Serif Display", folder: "dmserifdisplay", files: ["DMSerifDisplay-Regular"], category: .serif),
        .init(name: "Pacifico", folder: "pacifico", files: ["Pacifico-Regular"], category: .script),
        .init(name: "Lobster", folder: "lobster", files: ["Lobster-Regular"], category: .script),
        .init(name: "Caveat", folder: "caveat", files: ["Caveat[wght]"], category: .script),
        .init(name: "Knewave", folder: "knewave", files: ["Knewave-Regular"], category: .script),
        .init(name: "Bangers", folder: "bangers", files: ["Bangers-Regular"], category: .display),
        .init(name: "Bungee", folder: "bungee", files: ["Bungee-Regular"], category: .display),
        .init(name: "Bowlby One", folder: "bowlbyone", files: ["BowlbyOne-Regular"], category: .display),
        .init(name: "Sigmar One", folder: "sigmarone", files: ["SigmarOne-Regular"], category: .display),
    ]

    /// Names for pickers: the default font first, then the bundled families A to Z.
    public static var pickerNames: [String] {
        [InterFont.familyName] + families.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func isBundled(_ name: String) -> Bool {
        name == InterFont.familyName || families.contains { $0.name == name }
    }

    public static func fontURLs(of family: Family) -> [URL] {
        family.files.compactMap {
            Bundle.module.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts/Families/\(family.folder)")
        }
    }

    public static func licenseURL(of family: Family) -> URL? {
        Bundle.module.url(forResource: "OFL", withExtension: "txt", subdirectory: "Fonts/Families/\(family.folder)")
    }

    private static let registered: Bool = {
        var ok = true
        for fam in families {
            let urls = fontURLs(of: fam)
            if urls.count != fam.files.count { ok = false }
            // Fonts that are installed on the Mac already report an error here; the family stays usable.
            for u in urls { registerFontFile(u) }
        }
        return ok
    }()

    /// Registers every bundled family once for this process (the font resolver calls it too). True if all files were found.
    @discardableResult
    public static func register() -> Bool { registered }
}

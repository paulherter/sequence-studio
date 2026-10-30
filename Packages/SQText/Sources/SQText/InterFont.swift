import Foundation

/// Inter (rsms/inter, SIL OFL 1.1) is the default text font of new titles and captions. The two variable fonts
/// (upright and italic, optical-size and weight axes) ship in this package's `Resources/Fonts` together with `OFL.txt`
/// and are registered for the running process only: nothing is installed on the Mac.
public enum InterFont {
    public static let familyName = "Inter"

    /// URLs of the bundled font files (upright first, then italic).
    public static var fontURLs: [URL] {
        ["Inter-VariableFont_opsz,wght", "Inter-Italic-VariableFont_opsz,wght"].compactMap {
            Bundle.module.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: $0, withExtension: "ttf")
        }
    }

    /// The license text that ships next to the fonts.
    public static var licenseURL: URL? {
        Bundle.module.url(forResource: "OFL", withExtension: "txt", subdirectory: "Fonts")
            ?? Bundle.module.url(forResource: "OFL", withExtension: "txt")
    }

    private static let registered: Bool = {
        BundledFonts.register()
        let urls = fontURLs
        guard !urls.isEmpty else { return false }
        var ok = false
        // Registering a file that is already installed on the Mac reports an error but the family stays usable.
        for u in urls where registerFontFile(u) { ok = true }
        return ok || isInstalled(family: familyName)
    }()

    /// Registers the bundled fonts once for this process (call at app start; the font resolver also calls it, so
    /// rendering never depends on the call order). Returns whether the Inter family is usable.
    @discardableResult
    public static func register() -> Bool { registered }
}

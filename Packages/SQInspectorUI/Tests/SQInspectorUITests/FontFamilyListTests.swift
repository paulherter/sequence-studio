import AppKit
import SQText
import Testing
@testable import SQInspectorUI

/// The launch-time font list is read off the main thread through CoreText; it must be the list AppKit would give.
@MainActor @Suite struct FontFamilyListTests {
    /// AppKit's list, up to date. CoreText sees fonts registered for this process (BundledFonts, by any earlier test)
    /// at once; NSFontManager only after the main run loop delivered the font-set change. The app's run loop does that
    /// by itself, a test has to turn it (measured: 210 families before, 232 after one turn).
    private func appKitFamilies() -> [String] {
        BundledFonts.register()
        let want = FontFamilyList.fetch()
        let deadline = Date().addingTimeInterval(5)
        while NSFontManager.shared.availableFontFamilies != want, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return NSFontManager.shared.availableFontFamilies
    }

    @Test func backgroundListMatchesAppKitsList() {
        let appKit = appKitFamilies()
        #expect(FontFamilyList.fetch() == appKit)
    }

    @Test func warmedListIsServedWithoutAppKit() {
        let appKit = appKitFamilies()
        FontFamilyList.warm()
        #expect(FontFamilyList.current == appKit)
    }
}

import Foundation
import Testing
@testable import SQEditorUI

@Suite struct AppSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "sq-settings-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func emptyDefaultsGiveStandard() {
        #expect(AppSettings.load(from: defaults()) == .standard)
    }

    @Test func roundTrip() {
        let d = defaults()
        let s = AppSettings(autosaveInterval: 120, offerRecovery: false, defaultQuality: .half,
                            audioOutputUID: "uid-1", cacheFolder: URL(fileURLWithPath: "/tmp/cache", isDirectory: true), cacheCapGB: 100)
        s.save(to: d)
        #expect(AppSettings.load(from: d) == s)
    }

    @Test func invalidValuesFallBack() {
        let d = defaults()
        d.set(-5.0, forKey: AppSettings.Key.autosave)
        d.set("ultra", forKey: AppSettings.Key.quality)
        d.set("relative/path", forKey: AppSettings.Key.cache)
        d.set(0, forKey: AppSettings.Key.cap)
        d.set("", forKey: AppSettings.Key.audio)
        #expect(AppSettings.load(from: d) == .standard)
    }

    @Test func clearingOptionalsRemovesKeys() {
        let d = defaults()
        var s = AppSettings.standard
        s.audioOutputUID = "x"; s.cacheFolder = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        s.save(to: d)
        s.audioOutputUID = nil; s.cacheFolder = nil
        s.save(to: d)
        let back = AppSettings.load(from: d)
        #expect(back.audioOutputUID == nil && back.cacheFolder == nil)
        #expect(back.effectiveCacheFolder == AppSettings.defaultCacheFolder)
    }

    @Test func keyboardListingFromCommandMap() {
        let rows = KeyboardListing.rows(.premiereDefault)
        #expect(!rows.isEmpty)
        #expect(rows.contains { $0.command == "Undo" && $0.shortcut == "⌘Z" })
        #expect(rows.contains { $0.shortcut == "Space" })
        #expect(KeyboardListing.text(for: KeyBinding(.char("z"), [.command, .shift])) == "⇧⌘Z")
    }
}

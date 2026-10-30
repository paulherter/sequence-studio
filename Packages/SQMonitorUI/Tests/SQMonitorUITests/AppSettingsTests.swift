import Foundation
import Testing
import SQCore
@testable import SQEditorSession
@testable import SQMonitorUI

@Suite struct AppSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "sq-settings-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func playbackMemorySettingsDefaultToAuto() {
        let s = AppSettings.load(from: defaults())
        #expect(s.previewQualityAuto && s.frameCacheGB == 0 && s.backgroundWork)
        #expect(s.startQuality(auto: .half) == .half)
    }

    @Test func cacheFolderAndCapPersistAndDecideTheProxyDirectory() {
        var s = AppSettings.load(from: defaults())
        #expect(s.cacheCapGB == 50 && s.cacheCapBytes == 50_000_000_000)
        #expect(s.proxyCacheDirectory.path.hasSuffix("Library/Caches/SequenceStudio/Proxies"), "default stays where proxies already are")
        let d = defaults()
        s.cacheFolder = URL(fileURLWithPath: "/Volumes/Fast/SQCache", isDirectory: true)
        s.cacheCapGB = 20
        s.save(to: d)
        let back = AppSettings.load(from: d)
        #expect(back.cacheCapBytes == 20_000_000_000)
        #expect(back.proxyCacheDirectory.path == "/Volumes/Fast/SQCache/Proxies")
    }

    @Test func playbackMemorySettingsPersist() {
        let d = defaults()
        var s = AppSettings.standard
        s.previewQualityAuto = false; s.defaultQuality = .quarter; s.frameCacheGB = 2; s.backgroundWork = false
        s.save(to: d)
        let back = AppSettings.load(from: d)
        #expect(!back.previewQualityAuto && back.frameCacheGB == 2 && !back.backgroundWork)
        #expect(back.startQuality(auto: .full) == .quarter)
        #expect(d.integer(forKey: "sq.playback.frameCacheGB") == 2)
        d.set(-3, forKey: "sq.playback.frameCacheGB")
        #expect(AppSettings.load(from: d).frameCacheGB == 0)
    }

    @Test func exportEncoderSpeedPersistsAndDefaultsToQuality() {
        let d = defaults()
        #expect(AppSettings.load(from: d).exportEncoderSpeed == .quality)
        var s = AppSettings.standard
        s.exportEncoderSpeed = .fast
        s.save(to: d)
        #expect(d.string(forKey: "sq.export.encoderSpeed") == "fast")
        #expect(AppSettings.load(from: d).exportEncoderSpeed == .fast)
        d.set("turbo", forKey: "sq.export.encoderSpeed")
        #expect(AppSettings.load(from: d).exportEncoderSpeed == .quality)
    }

    /// Auto saves no fixed quality: saving any other setting never turns Auto off.
    @Test func autoSavesNoFixedQuality() {
        let d = defaults()
        var s = AppSettings.load(from: d)
        s.audioScrubbing = true
        s.save(to: d)
        #expect(d.object(forKey: "settings.defaultQuality") == nil)
        #expect(AppSettings.load(from: d).previewQualityAuto)
    }

    /// Older builds wrote "full" (the default) on every save: that is not a choice, Auto applies.
    @Test func legacyFullWithoutAutoKeyBecomesAuto() {
        let d = defaults()
        d.set("full", forKey: "settings.defaultQuality")
        #expect(AppSettings.load(from: d).previewQualityAuto)
    }

    /// A pick in the monitor is a fixed quality, remembered across projects (`choosingFixedQuality`).
    @Test func monitorPickBecomesFixedQuality() {
        let d = defaults()
        let s = AppSettings.load(from: d).choosingFixedQuality(.quarter)
        s.save(to: d)
        let back = AppSettings.load(from: d)
        #expect(!back.previewQualityAuto && back.startQuality(auto: .half) == .quarter)
    }

    /// A quality remembered before Auto existed stays fixed (no surprise change after the update).
    @Test func rememberedQualityWithoutAutoKeyStaysFixed() {
        let d = defaults()
        d.set("half", forKey: "settings.defaultQuality")
        let s = AppSettings.load(from: d)
        #expect(!s.previewQualityAuto && s.startQuality(auto: .full) == .half)
    }

    @Test func emptyDefaultsGiveStandard() {
        #expect(AppSettings.load(from: defaults()) == .standard)
    }

    @Test func scrubbingDefaultsOffAndLanguageDefaultsGerman() {
        let s = AppSettings.load(from: defaults())
        #expect(s.audioScrubbing == false)
        #expect(s.captionLanguage == "de-DE")
    }

    @Test func scrubbingAndLanguagePersist() {
        let d = defaults()
        var s = AppSettings.standard
        s.audioScrubbing = false; s.captionLanguage = "en-US"
        s.save(to: d)
        let back = AppSettings.load(from: d)
        #expect(!back.audioScrubbing && back.captionLanguage == "en-US")
        #expect(d.string(forKey: "sq.captions.language") == "en-US")
        d.set("../x y", forKey: "sq.captions.language")
        #expect(AppSettings.load(from: d).captionLanguage == "de-DE")
    }

    @Test func projectLanguageOverride() {
        let d = defaults()
        let id = UUID()
        #expect(AppSettings.captionLanguage(forProject: id, from: d) == "de-DE")
        AppSettings.setCaptionLanguage("fr-FR", forProject: id, to: d)
        #expect(AppSettings.captionLanguage(forProject: id, from: d) == "fr-FR")
        #expect(AppSettings.captionLanguage(forProject: UUID(), from: d) == "de-DE")
        AppSettings.setCaptionLanguage(nil, forProject: id, to: d)
        #expect(AppSettings.captionLanguage(forProject: id, from: d) == "de-DE")
    }

    @Test func roundTrip() {
        let d = defaults()
        var s = AppSettings(autosaveInterval: 120, offerRecovery: false, defaultQuality: .half,
                            audioOutputUID: "uid-1", cacheFolder: URL(fileURLWithPath: "/tmp/cache", isDirectory: true), cacheCapGB: 100)
        s.previewQualityAuto = false
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

@MainActor @Suite struct MonitorQualityPreferenceTests {
    @Test func choiceIsRememberedAppWide() {
        let d = UserDefaults(suiteName: "sq.test.quality.\(UUID().uuidString)")!
        var s = AppSettings.load(from: d)
        #expect(s.defaultQuality == .full)
        let model = MonitorPanelModel(frameDuration: Time(1, 24))
        var seen: [MonitorQuality] = []
        model.onQualityChange = { seen.append($0) }
        model.setQuality(.quarter)
        s = s.choosingFixedQuality(model.quality)
        s.save(to: d)
        #expect(seen == [.quarter])
        model.setQuality(.full)
        model.setQuality(AppSettings.load(from: d).defaultQuality)
        #expect(model.quality == .quarter)
    }

    /// Delete follows the sequence mode; the old "Delete closes gap" value is neither read nor written any more.
    @Test func oldDeleteSettingIsIgnoredAndDropped() {
        let d = UserDefaults(suiteName: "delete-\(UUID())")!
        d.set(true, forKey: "sq.delete.ripple")
        AppSettings.load(from: d).save(to: d)
        #expect(d.object(forKey: "sq.delete.ripple") == nil)
    }
}

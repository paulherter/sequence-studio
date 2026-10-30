import AppKit
import Foundation
import SQEditorSession
import SQEditorUI
import SQUIKit
import Testing

@Suite("Settings pages")
struct SettingsPagesTests {
    /// The 26 options of the old four-tab window (windows proposal section 4: "every existing option is kept").
    private static let oldOptions: Set<String> = [
        "Autosave", "New Text Length", "Transcription", "Preview Quality", "Frame Cache", "Background Work", "Preroll", "Postroll",
        "Audio Scrubbing", "Dropped Frames", "New Sequences Start in", "De-Click", "Live Ducking", "Duck Timing",
        "Outside Files", "Library", "Library Folders", "Project Folder", "Card Import", "Cache", "Recovery", "Video Transition",
        "Audio Transition", "Edit API", "Effect Defaults",
        "Meter Response", "Fade Shape",   // added with the meter ballistics and default fade curve
        "Updates",    // added with the update check
        "Growing Files",    // added with the growing-file refresh
        "Render Cache",     // added with the preview render cache
    ]

    @Test func sixPagesInOrder() {
        #expect(SettingsPage.allCases.map(\.title) == ["General", "Playback", "Editing", "Audio", "Media", "Advanced"])
        #expect(SettingsPage.allCases.map(\.slug) == ["general", "playback", "editing", "audio", "media", "advanced"])
        #expect(SettingsPage.sidebarWidth == 200)
    }

    @Test func noOptionDropped() {
        let titles = SettingsOption.allCases.map(\.title)
        #expect(Set(titles) == Self.oldOptions)
        #expect(titles.count == Self.oldOptions.count)          // each exactly once
    }

    @Test func everyPageHasOptions() {
        for p in SettingsPage.allCases { #expect(!p.options.isEmpty, "\(p.title) is empty") }
        let all = SettingsPage.allCases.flatMap(\.options)
        #expect(all.count == SettingsOption.allCases.count)
    }

    @Test func effectDefaultsAreOnEditing() {
        #expect(SettingsOption.effectDefaults.page == .editing)
        #expect(SettingsOption.editAPI.page == .advanced)
        #expect(SettingsOption.libraryFolders.page == .media)
        #expect(SettingsOption.cache.page == .media)
    }

    @Test func defaultsKeysUseOurPrefixes() {
        var seen = Set<String>()
        for o in SettingsOption.allCases {
            guard let k = o.defaultsKey else { continue }
            #expect(k.hasPrefix("sq.") || k.hasPrefix("settings."), "\(k)")
            #expect(seen.insert(k).inserted, "duplicate key \(k)")
        }
    }

    @Test func appSettingsRoundTripWritesItsKeys() throws {
        let suite = "sq.test.settings.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var s = AppSettings.load(from: d)
        s.prerollSeconds = AppSettings.rollChoices[0]
        s.postrollSeconds = AppSettings.rollChoices[1]
        s.audioScrubbing = false
        s.dropIndicator = false
        s.backgroundWork = false
        s.refreshGrowingFiles = false
        s.save(to: d)
        let back = AppSettings.load(from: d)
        #expect(back.prerollSeconds == AppSettings.rollChoices[0])
        #expect(back.postrollSeconds == AppSettings.rollChoices[1])
        #expect(back.audioScrubbing == false)
        #expect(back.dropIndicator == false)
        #expect(back.refreshGrowingFiles == false)
        #expect(back.backgroundWork == false)
        let appSettingsOptions: [SettingsOption] = [.autosave, .recovery, .newTextLength, .transcription, .previewQuality, .frameCache,
                                                    .backgroundWork, .preroll, .postroll, .audioScrubbing, .droppedFrames,
                                                    .newSequenceMode, .growingFiles]
        for o in appSettingsOptions {
            let key = try #require(o.defaultsKey)
            #expect(d.object(forKey: key) != nil, "\(o.title) did not write \(key)")
        }
    }

    /// A control changing a setting saves it and the next launch (and every window reading the settings) sees the same
    /// value: every field moved off its default survives save + load, and a reset to defaults is saved too.
    @Test func everyChangedSettingSurvivesSaveAndLoad() throws {
        let suite = "sq.test.settings.all.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var s = AppSettings.load(from: d)
        let original = s
        s.autosaveInterval = 120
        s.offerRecovery.toggle()
        s.checkForUpdates.toggle()
        s.onboardingSeen = true
        s.previewQualityAuto = false
        s.defaultQuality = .quarter
        s.prerollSeconds = 7
        s.postrollSeconds = 9
        s.hoverScrub.toggle()
        s.dropIndicator.toggle()
        s.audioScrubbing.toggle()
        s.newSequenceEditMode = .magnetic
        s.selectionFollowsPlayhead.toggle()
        s.frameCacheGB = 12
        s.backgroundWork.toggle()
        s.audioOutputUID = "TestDevice"
        s.cacheFolder = URL(fileURLWithPath: "/tmp/sq-cache-test", isDirectory: true)
        s.cacheCapGB = 33
        s.refreshGrowingFiles.toggle()
        s.defaultTextSeconds = 8
        s.captionLanguage = "de-DE"
        s.save(to: d)
        let back = AppSettings.load(from: d)
        #expect(back.autosaveInterval == 120 && back.prerollSeconds == 7 && back.postrollSeconds == 9)
        #expect(back.defaultQuality == .quarter && back.previewQualityAuto == false)
        #expect(back.newSequenceEditMode == .magnetic && back.frameCacheGB == 12 && back.cacheCapGB == 33)
        #expect(back.audioOutputUID == "TestDevice" && back.cacheFolder?.path == "/tmp/sq-cache-test")
        #expect(back.defaultTextSeconds == 8 && back.captionLanguage == "de-DE")
        #expect(back == s)
        #expect(back != original)
        original.save(to: d)
        #expect(AppSettings.load(from: d) == original)
    }

    @Test func audioPageHasMeterAndFadeShapeOnTheirOwnKeys() {
        #expect(SettingsOption.meterBallistics.page == .audio && SettingsOption.defaultFadeCurve.page == .audio)
        #expect(SettingsOption.meterBallistics.defaultsKey == "sq.audio.meterBallistics")
        #expect(SettingsOption.defaultFadeCurve.defaultsKey == "sq.audio.defaultFadeCurve")
    }

    @Test func editAPIStateText() {
        #expect(EditAPIRunState.notRunning.text == "Not running")
        #expect(EditAPIRunState.listening(port: 8731).text == "Listening on 127.0.0.1, port 8731")
        #expect(EditAPIRunState.portInUse(port: 8731).text.hasPrefix("Port in use"))
        #expect(EditAPIRunState.notRunning.tone == .idle)
        #expect(EditAPIRunState.listening(port: 1).tone == .ok)
        #expect(EditAPIRunState.portInUse(port: 1).tone == .warning)
        #expect(EditAPIRunState.listening(port: 8731).copyablePort == 8731)
        #expect(EditAPIRunState.listeningNoFile(port: 9).copyablePort == 9)
        #expect(EditAPIRunState.notRunning.copyablePort == nil)
        #expect(EditAPIRunState.portInUse(port: 8731).copyablePort == nil)
    }

    @MainActor
    @Test func formRowGeometry() {
        let field = NSView()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 100).isActive = true
        field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let row = SQFormRow.row("Label", field, help: String(repeating: "Long help text. ", count: 40))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor), row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        let converted = field.convert(field.bounds, to: host)
        #expect(abs(converted.minX - SQFormRow.controlX()) < 0.5)
        #expect(SQFormRow.controlX() == 148)
        #expect(row.frame.height >= SQFormRow.lineHeight)
        let help = SQFormRow.helpLabel("x")
        #expect(help.preferredMaxLayoutWidth == 440)
    }
}

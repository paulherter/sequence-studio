import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// Interface Size, Transcription, De-Click, Live Ducking, Meter Response and Fade Shape in the portable Preferences: each
/// row writes the store the engine and session read.
@MainActor
@Suite(.serialized) struct ShellPreferenceStoresTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "sq.test.prefstores.\(UUID().uuidString)")! }

    @Test func generalRowsWriteInterfaceSizeAndTranscription() throws {
        let d = defaults()
        var s = AppSettings.load(from: d)
        var x = ShellPreferences.Extras.load(from: d)
        #expect(x.uiScale == 1.0)
        let f = ShellPreferences.form(.general, s, x)
        #expect(f.index("uiScale") == InterfaceScale.steps.firstIndex(of: 1.0))
        f.set("uiScale", .index(try #require(InterfaceScale.steps.firstIndex(of: 1.25))))
        let langs = ShellPreferences.transcriptionLanguages(s.captionLanguage)
        let other = try #require(langs.firstIndex { $0 != s.captionLanguage })
        f.set("transcription", .index(other))
        ShellPreferences.apply(f, to: &s)
        ShellPreferences.apply(f, to: &x)
        x.save(to: d)
        #expect(s.captionLanguage == langs[other])
        #expect(InterfaceScale.load(from: d) == 1.25)
        #expect(ShellPreferences.Extras.load(from: d).uiScale == 1.25)
    }

    /// Mac parity: the pages are `SettingsWindow`'s `SQFormRow` rows: captions, check row labels, help lines, popup widths
    /// and the 132 pt label column.
    @Test func pagesCarryTheMacCaptionsLabelsHelpsAndWidths() {
        let d = defaults()
        let s = AppSettings.load(from: d), x = ShellPreferences.Extras.load(from: d)
        func captions(_ f: ShellForm) -> [String] { f.rows.compactMap { if case .caption(let t) = $0 { t } else { nil } } }
        let general = ShellPreferences.form(.general, s, x)
        #expect(captions(general) == ["New items"])
        #expect(general.checkLabels["recovery"] == "Recovery" && general.checkLabels["autoLanguage"] == "Auto Language")
        #expect(general.helps["uiLanguage"]?.hasSuffix("Applies the next time Sequence Studio starts.") == true)
        #expect(general.controlWidths["autosave"] == 180)
        #expect(general.labelColumn() == 132)   // Theme.Modal.labelColumnL (SQUIKit Theme is Mac-only)
        let playback = ShellPreferences.form(.playback, s, x)
        #expect(captions(playback) == ["Play around", "Feedback"])
        #expect(playback.controlWidths["preroll"] == 120 && playback.controlWidths["renderCacheCap"] == 120)
        #expect(playback.checkLabels["dropIndicator"] == "Dropped Frames")
        #expect(captions(ShellPreferences.form(.audio, s, x)).first == "Ducking")
        #expect(captions(ShellPreferences.form(.media, s, x)) == ["Library", "Cache", "Folders"])
    }

    @Test func generalRowsWriteTheAppearanceKeys() {
        let d = defaults()
        let s = AppSettings.load(from: d)
        var x = ShellPreferences.Extras.load(from: d)
        #expect(x.appearance == .standard)
        let f = ShellPreferences.form(.general, s, x)
        #expect(f.index("appearance") == 0 && f.number("appearanceBackground") == 0 && f.number("appearanceContrast") == 50)
        f.set("appearance", .index(1))
        f.set("appearanceBackground", .number(-2.4))
        f.set("appearanceContrast", .number(140))
        ShellPreferences.apply(f, to: &x)
        x.save(to: d)
        #expect(AppearanceSettings(defaults: d) == AppearanceSettings(mode: .light, background: -2, contrast: 100))
    }

    @Test func audioRowsWriteDeClickDuckingMeterAndFadeShape() throws {
        let d = defaults()
        let s = AppSettings.load(from: d)
        var x = ShellPreferences.Extras.load(from: d)
        #expect(x.deClick && x.duckAmount == nil && x.meterStyle == .standard && x.fadeCurve == .linear)
        let f = ShellPreferences.form(.audio, s, x)
        f.set("deClick", .bool(false))
        f.set("liveDuck", .bool(true))
        f.set("duckAmount", .number(18))
        f.set("meterStyle", .index(try #require(MeterStyle.allCases.firstIndex(of: .fast))))
        f.set("fadeCurve", .index(try #require(FadeCurve.allCases.firstIndex(of: .sCurve))))
        ShellPreferences.apply(f, to: &x)
        x.save(to: d)
        #expect(!AudioPreferences.deClick(d))
        #expect(LiveDucking.current(d)?.amountDB == 18)
        #expect(MeterStyle.current(d) == .fast)
        #expect(DefaultFadeCurve.current(d) == .sCurve)

        let off = ShellPreferences.form(.audio, s, x)
        #expect(off.bool("liveDuck") == true)
        off.set("liveDuck", .bool(false))
        ShellPreferences.apply(off, to: &x)
        x.save(to: d)
        #expect(LiveDucking.current(d) == nil)
    }

    /// The Mac Live Ducking row: the amount is a 92 pt field after the check title ("12.0", no unit), any 0.5 dB step.
    @Test func theDuckAmountIsAFieldAfterTheLiveDuckingCheck() {
        let d = defaults()
        LiveDucking.setAmount(10, defaults: d)
        var x = ShellPreferences.Extras.load(from: d)
        let f = ShellPreferences.form(.audio, AppSettings.load(from: d), x)
        #expect(!f.rows.contains { ShellForm.id(of: $0) == "duckAmount" })
        #expect(f.checkFields["liveDuck"]?.width == 92 && f.checkFields["liveDuck"]?.field.decimals == 1)
        #expect(f.number("duckAmount") == 10)
        f.set("duckAmount", .number(13.3))
        ShellPreferences.apply(f, to: &x)
        #expect(x.duckAmount == 13.5)
        f.set("liveDuck", .bool(false))
        ShellPreferences.apply(f, to: &x)
        #expect(x.duckAmount == nil)
        #expect(f.scrubOff("duckAmount"))
    }

    /// Duck Timing and the role values sit in `SQFormRow.unitGrid`s under their rows: ms fields for the timing, label-tinted
    /// role fields without a unit under "J / L Offset" and "Crossfade Length".
    @Test func timingAndRoleValuesAreGridsUnderTheirRows() {
        let d = defaults()
        let f = ShellPreferences.form(.audio, AppSettings.load(from: d), ShellPreferences.Extras.load(from: d))
        #expect(f.grids["duckTiming"]?.map(\.title) == ["Lookahead", "Attack", "Hold", "Recovery", "Minimum pause"])
        #expect(f.grids["duckTiming"]?.allSatisfy { $0.unit == "ms" && $0.field.step == 5 } == true)
        #expect(f.grids["offset"]?.count == AudioTag.allCases.count && f.grids["length"]?.count == AudioTag.allCases.count)
        #expect(f.grids["offset"]?.allSatisfy { $0.unit.isEmpty && f.labelTinted.contains($0.field.id) } == true)
        #expect(f.rows.contains(.label(id: "offset", label: "J / L Offset")))
        #expect(!f.rows.contains { if case .caption("J / L Offset") = $0 { true } else { false } })
        f.layout(origin: .zero, width: 697)
        let row = f.rows.firstIndex(of: .label(id: "offset", label: "J / L Offset"))!
        let first = f.scrubFrames["offset.\(AudioTag.allCases[0].rawValue)"]!
        #expect(first.minY == f.rowFrames[row].minY + 28 + 4)
    }

    /// Advanced appears only with a host Edit API: the switch, its status line and Copy address.
    @Test func theAdvancedPageShowsTheEditAPISwitchAndStatus() {
        let d = defaults()
        var c = ShellPreferences.Context()
        c.defaults = d
        #expect(ShellPreferences.sidebar(c).items.count == ShellPreferences.Page.allCases.count - 1)
        c.editAPI = (true, ShellEditAPI.State(text: "Listening on 127.0.0.1, port 7341", tone: .ok, copyablePort: 7341))
        #expect(ShellPreferences.sidebar(c).items.last?.title == "Advanced")
        let f = ShellPreferences.form(.advanced, AppSettings.load(from: d), ShellPreferences.Extras.load(from: d), c)
        #expect(f.bool("api") == true && f.checkLabels["api"] == "Edit API")
        #expect(f.statuses["api"]?.button == "Copy address" && f.statuses["api"]?.tone == .ok)
        #expect(ShellPreferences.apiStatus(.init(text: "Not running", tone: .idle)).button == nil)
    }

    @MainActor final class APIBox { var on = false; var copied: String? }

    /// The Advanced switch starts the host's server (`apiChanged`), the line follows, Copy address copies host:port.
    @Test func theAdvancedSwitchAndCopyGoToTheHost() async throws {
        let h = ShellHost(session: ShellRecoveryTests.session(), map: .premiereDefault)
        let box = APIBox()
        h.editAPI = ShellEditAPI(isEnabled: { box.on }, setEnabled: { box.on = $0 }, state: {
            box.on ? .init(text: "Listening on 127.0.0.1, port 7341", tone: .ok, copyablePort: 7341) : .init(text: "Not running", tone: .idle)
        })
        h.copyText = { box.copied = $0 }
        let t = Task { await h.showPreferences(defaults: defaults()) }
        var dlg: ShellDialog?
        for _ in 0..<200 where dlg == nil { dlg = h.dialog; await Task.yield() }
        let dialog = try #require(dlg)
        dialog.form?.onChange?("page", .index(ShellPreferences.Page.advanced.rawValue))
        let f = try #require(dialog.form)
        #expect(f.statuses["api"]?.button == nil)
        f.set("api", .bool(true)); f.onChange?("api", .bool(true))
        #expect(box.on)
        #expect(f.statuses["api"]?.button == "Copy address")
        f.onChange?("api.status", .index(0))
        #expect(box.copied == "127.0.0.1:7341")
        dialog.press(.first)
        await t.value
        #expect(h.editAPI?.stateChanged == nil)
    }

    @Test func duckPresetSetsAmountAndTimingAndTheFieldsFallBackToCustom() throws {
        let d = defaults()
        var x = ShellPreferences.Extras.load(from: d)
        #expect(x.duckTiming == .classic)
        let f = ShellPreferences.form(.audio, AppSettings.load(from: d), x)
        #expect(f.index("duckPreset") == 0 && f.index("duckTiming") == 0)
        f.set("duckPreset", .index(try #require(DuckPreset.all.firstIndex(of: .hard)) + 1))
        ShellPreferences.apply(f, to: &x)
        ShellPreferences.sync(f, x)
        x.save(to: d)
        #expect(LiveDucking.current(d)?.amountDB == DuckPreset.hard.amountDB)
        #expect(DuckTiming.stored(d) == DuckPreset.hard.timing.clamped)
        #expect(f.bool("liveDuck") == true)
        #expect(f.number("timing.attack") == DuckPreset.hard.timing.attackMs)

        f.set("duckTiming", .index(2))
        ShellPreferences.apply(f, to: &x)
        ShellPreferences.sync(f, x)
        #expect(x.duckTiming == DuckTimingChoices.presets[2].timing.clamped)
        #expect(f.index("duckPreset") == 0)

        f.set("timing.hold", .text("777"))
        ShellPreferences.apply(f, to: &x)
        ShellPreferences.sync(f, x)
        x.save(to: d)
        #expect(DuckTiming.stored(d).holdMs == 777)
        #expect(f.index("duckTiming") == DuckTimingChoices.presets.count)
    }

    @Test func mediaRowsWriteTheMediaDefaultsAndCardImport() throws {
        let d = defaults()
        var x = ShellPreferences.Extras.load(from: d)
        var c = ShellPreferences.Context()
        c.defaults = d
        let hidden = ShellPreferences.form(.media, AppSettings.load(from: d), x, c)
        #expect(hidden.bool("cardImport") == nil)
        c.cardImport = true
        let f = ShellPreferences.form(.media, AppSettings.load(from: d), x, c)
        f.set("outside", .index(try #require(OutsideMediaMode.allCases.firstIndex(of: .copy))))
        f.set("watchFolder", .bool(false))
        f.set("libraryCopy", .bool(false))
        f.set("cardImport", .bool(false))
        ShellPreferences.apply(f, to: &x)
        x.save(to: d)
        #expect(MediaSettings.load(from: d) == MediaPolicyDefaults(outside: .copy, copyLibraryItems: false, watchFolder: false))
        #expect(!CardImportSettings.isEnabled(d))
    }

    @Test func mediaPageListsLibraryFoldersAndDeleteCache() {
        let d = defaults()
        var c = ShellPreferences.Context()
        c.defaults = d
        let x = ShellPreferences.Extras.load(from: d)
        let bare = ShellPreferences.form(.media, AppSettings.load(from: d), x, c)
        #expect(bare.rows.allSatisfy { if case .buttons(let id, _, _, _, _) = $0 { return id != "libFolderAdd" && id != "cacheClear" } else { return true } })
        c.libraryFolders = [ShellLibraryFolder(id: UUID(), name: "Music", path: "~/Music", offline: false)]
        c.cacheUsed = "Empty"
        let f = ShellPreferences.form(.media, AppSettings.load(from: d), x, c)
        let ids = f.rows.compactMap { r -> String? in if case .buttons(let id, _, _, _, _) = r { return id } else { return nil } }
        #expect(ids.contains("libFolderAdd") && ids.contains("cacheClear"))
        // The Mac boxed list: one list box, a folder icon and the path on each line, a Remove button per line.
        let box = f.rows.first { if case .listBox(let id, _, _, _, _) = $0 { return id == "libFolder" } else { return false } }
        guard case .listBox(_, let label, let lines, let button, _)? = box else { Issue.record("no Library Folders list box"); return }
        #expect(label == "Library Folders" && lines == ["Music"] && button == "Remove")
        #expect(f.listLines["libFolder"] == [ShellForm.ListLine(icon: .folder, detail: "~/Music", warning: nil)])
        #expect(ShellPreferences.buttonAction("libFolder", button: 0, effectDefaults: nil) == .removeLibraryFolder(0))
        #expect(ShellPreferences.buttonAction("libFolderAdd", button: 0, effectDefaults: nil) == .addLibraryFolder)
        #expect(ShellPreferences.buttonAction("cacheClear", button: 0, effectDefaults: nil) == .clearCache)
    }

    @Test func frameCacheAndAudioOutputRowsWriteAppSettings() throws {
        let d = defaults()
        var s = AppSettings.load(from: d)
        var c = ShellPreferences.Context()
        c.frameCacheValues = [0, 1, 2]
        c.frameCacheTitles = ["Auto (1.0 GB)", "1 GB", "2 GB"]
        #expect(ShellPreferences.form(.playback, s, .init(), c).index("audioOutput") == nil)
        c.audioOutputs = [.init(uid: "a", name: "Speakers"), .init(uid: "b", name: "Headphones")]
        let f = ShellPreferences.form(.playback, s, .init(), c)
        #expect(f.index("frameCache") == 0 && f.index("audioOutput") == 0)
        f.set("frameCache", .index(2))
        f.set("audioOutput", .index(2))
        ShellPreferences.apply(f, to: &s, c)
        #expect(s.frameCacheGB == 2 && s.audioOutputUID == "b")

        s.audioOutputUID = "gone"
        let missing = ShellPreferences.form(.playback, s, .init(), c)
        #expect(missing.index("audioOutput") == 3)
        missing.set("audioOutput", .index(0))
        ShellPreferences.apply(missing, to: &s, c)
        #expect(s.audioOutputUID == nil)
    }

    @Test func effectDefaultsAreListedByGroupWithRestoreFactory() throws {
        var lib = EffectDefaults()
        let kind = try #require(EffectCatalog.all.map(\.kind).first { EffectDefaults.canHaveDefault(kind: $0) })
        let fx = try #require(ClipEffect.make(kind: kind))
        let added = lib.setDefault(from: fx, keepKeyframes: true, at: .zero)
        #expect(added)
        var c = ShellPreferences.Context()
        c.effectDefaults = lib
        let f = ShellPreferences.form(.editing, AppSettings.load(from: defaults()), .init(), c)
        let boxes = f.rows.compactMap { r -> (String, Int, String)? in
            if case .listBox(let id, _, let lines, let b, _) = r { (id, lines.count, b) } else { nil } }
        #expect(boxes.map { $0.0 } == ["default.0", "default.1", "default.2"])
        #expect(boxes.map { $0.1 } == [1, 0, 0])
        #expect(boxes[0].2 == "Restore Factory")
        // The transition lengths are right-aligned scrub fields in label tint (the Mac `numberRow`).
        #expect(f.number("videoTransition") == Double(ShellPreferences.Extras().transitions.videoFrames) && f.number("audioTransition") == ShellPreferences.Extras().transitions.audioSeconds)
        #expect(f.labelTinted.contains("videoTransition"))
        let act = ShellPreferences.buttonAction("default.0", button: 0, effectDefaults: lib)
        #expect(act == .restoreFactory(.effect(fx.kind)))
        if case .restoreFactory(let e)? = act { lib.remove(e) }
        #expect(lib.isEmpty)
        #expect(ShellPreferences.buttonAction("cacheFolder", button: 1, effectDefaults: nil) == .useDefault(.cache))
    }

    @Test func folderButtonsSaveTheFoldersAndCopyTheProxies() throws {
        let d = defaults()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sq.prefs.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var s = AppSettings.load(from: d)
        let note = ShellPreferences.setFolder(.scratch, tmp.appendingPathComponent("Scratch"), settings: &s, defaults: d)
        #expect(note.isEmpty)
        #expect(StorageLocations.load(from: d).scratchFolder?.lastPathComponent == "Scratch")
        _ = ShellPreferences.setFolder(.scratch, nil, settings: &s, defaults: d)
        #expect(StorageLocations.load(from: d).scratchFolder == nil)

        final class Copied: @unchecked Sendable { var pair: (URL, URL)? }
        let copied = Copied()
        let cacheNote = ShellPreferences.setFolder(.cache, tmp.appendingPathComponent("Cache"), settings: &s, defaults: d,
                                                   migrate: { copied.pair = ($0, $1) })
        #expect(s.cacheFolder?.lastPathComponent == "Cache")
        #expect(AppSettings.load(from: d).cacheFolder?.lastPathComponent == "Cache")
        #expect(copied.pair?.1.path.hasPrefix(tmp.appendingPathComponent("Cache").path) == true)
        #expect(cacheNote.hasPrefix("Applies at the next launch"))
        _ = ShellPreferences.setFolder(.cache, nil, settings: &s, defaults: d, migrate: { _, _ in })
        #expect(AppSettings.load(from: d).cacheFolder == nil)
    }
}

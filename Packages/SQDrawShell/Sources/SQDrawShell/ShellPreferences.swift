import Foundation
import SQCore
import SQEditorSession
import SQUIKit
import SQDrawKit

/// Preferences, translated from the Mac `SettingsWindow`: the same pages, row titles, choices and `AppSettings` fields,
/// as `ShellForm` rows in a shell dialog with the page list in a sidebar column, as the Mac window.
/// The stores outside `AppSettings` (UI language and size, `TransitionDefaults`, `AudioRoleDefaults`, De-Click, Live
/// Ducking with its preset and timing, Meter Response, Fade Shape, media defaults, card import) ride along in `Extras`;
/// the host applies what it reads in `onSettingsChanged`. What the host knows (output devices, the effect defaults
/// library, whether it has a card import window) comes in `Context`; a row whose reader the host lacks is left out.
/// The Library Folders list is a `ShellForm` list box with folder icons (`ListLine`). The Advanced page (Edit API) shows when the host sets `ShellHost.editAPI`.
@MainActor
public enum ShellPreferences {
    public enum Page: Int, CaseIterable, Sendable {
        case general, playback, editing, audio, media
        /// Edit API: only when the host runs one (`ShellHost.editAPI`; the Mac app and the Windows app do).
        case advanced
        public var title: String {
            switch self {
            case .general: "General"; case .playback: "Playback"; case .editing: "Editing"; case .audio: "Audio"; case .media: "Media"
            case .advanced: "Advanced"
            }
        }
        /// The Mac `SettingsPage.icon`.
        public var icon: SQIcon {
            switch self {
            case .general: .slidersHorizontal; case .playback: .play; case .editing: .pencil; case .audio: .waveform; case .media: .folder
            case .advanced: .code
            }
        }
    }

    /// The page list of the Preferences form (the Mac sidebar); Advanced only when the host has an Edit API.
    public static func sidebar(_ c: Context) -> ShellForm.Sidebar {
        ShellForm.Sidebar(id: "page", items: Page.allCases.filter { $0 != .advanced || c.editAPI != nil }.map { ($0.title, $0.icon) })
    }

    /// The stores outside `AppSettings` the pages edit, as the Mac window reads them.
    public struct Extras: Equatable, Sendable {
        /// `SQL10n.defaultsKey` value; "system" = the key removed.
        public var uiLanguage = "system"
        public var transitions = TransitionDefaults.standard
        public var roles = AudioRoleDefaults.standard
        /// Interface Size factor (one of `InterfaceScale.steps`).
        public var uiScale = 1.0
        public var deClick = true
        /// Live Ducking amount in dB; nil = off.
        public var duckAmount: Double?
        public var meterStyle = MeterStyle.standard
        public var fadeCurve = FadeCurve.linear
        public var duckTiming = DuckTiming.classic
        /// Outside Files, Project Folder and Library (`MediaSettings`).
        public var media = MediaPolicyDefaults()
        public var cardImport = true
        /// Dark / Light, Background and Contrast (the Mac start screen's Appearance popover, `sq.appearance.*`).
        public var appearance = AppearanceSettings.standard
        public init() {}

        public static func load(from d: UserDefaults = .standard) -> Extras {
            var x = Extras()
            x.uiLanguage = d.string(forKey: SQL10n.defaultsKey) ?? "system"
            x.transitions = TransitionDefaults.load(from: d)
            x.roles = AudioRoleDefaults.load(from: d)
            x.uiScale = InterfaceScale.load(from: d)
            x.deClick = AudioPreferences.deClick(d)
            x.duckAmount = LiveDucking.current(d)?.amountDB
            x.meterStyle = MeterStyle.current(d)
            x.fadeCurve = DefaultFadeCurve.current(d)
            x.duckTiming = DuckTiming.stored(d)
            x.media = MediaSettings.load(from: d)
            x.cardImport = CardImportSettings.isEnabled(d)
            x.appearance = AppearanceSettings(defaults: d)
            return x
        }

        public func save(to d: UserDefaults = .standard) {
            if uiLanguage == "system" { d.removeObject(forKey: SQL10n.defaultsKey) } else { d.set(uiLanguage, forKey: SQL10n.defaultsKey) }
            transitions.save(to: d)
            roles.save(to: d)
            if InterfaceScale.load(from: d) != uiScale {
                InterfaceScale.store(uiScale, in: d)
                NotificationCenter.default.post(name: InterfaceScale.didChange, object: nil)
            }
            AudioPreferences.setDeClick(deClick, defaults: d)
            if LiveDucking.current(d)?.amountDB != duckAmount { LiveDucking.setAmount(duckAmount, defaults: d) }
            d.set(meterStyle.rawValue, forKey: MeterStyle.defaultsKey)
            DefaultFadeCurve.set(fadeCurve, defaults: d)
            if DuckTiming.stored(d) != duckTiming.clamped { DuckTiming.store(duckTiming, defaults: d) }
            if MediaSettings.load(from: d) != media { MediaSettings.store(media, in: d) }
            if CardImportSettings.isEnabled(d) != cardImport { CardImportSettings.setEnabled(cardImport, defaults: d) }
            if AppearanceSettings(defaults: d) != appearance { appearance.save(to: d) }
        }
    }

    /// What the rows show that is not a stored value: the machine's frame cache sizes, the output devices, the effect
    /// defaults, the storage folders and the last folder note.
    public struct Context {
        public var frameCacheValues = FrameCacheChoices.values()
        public var frameCacheTitles = FrameCacheChoices.titles()
        /// nil: the host cannot pick a device (row left out).
        public var audioOutputs: [AudioOutputChoices.Device]?
        /// nil: the host has no effect defaults library (rows left out).
        public var effectDefaults: EffectDefaults?
        /// The host opens an import window when a card mounts (else the Card Import row is left out).
        public var cardImport = false
        public var defaults: UserDefaults = .standard
        /// The note under the folder rows (a folder problem or "Applies at the next launch…").
        public var folderNote = ""
        /// The Library's watched folders; nil: the host has no Library (the Library Folders rows are left out).
        public var libraryFolders: [ShellLibraryFolder]?
        /// The cache size line next to Delete Cache ("Calculating…", "Empty", "1.2 GB"); nil: no Delete Cache row.
        public var cacheUsed: String?
        /// The Edit API switch and its status (`ShellHost.editAPI`); nil: no Advanced page.
        public var editAPI: (on: Bool, state: ShellEditAPI.State)?
        public init() {}
    }

    /// The five Duck Timing fields: id suffix, title, upper bound in ms (the Mac `DuckTimingForm`).
    static let timingFields: [(id: String, title: String, max: Double, key: WritableKeyPath<DuckTiming, Double>)] = [
        ("lookahead", "Lookahead", 500, \.lookaheadMs), ("attack", "Attack", 2000, \.attackMs), ("hold", "Hold", 2000, \.holdMs),
        ("recovery", "Recovery", 5000, \.recoveryMs), ("minPause", "Minimum pause", 2000, \.minPauseMs),
    ]
    /// Duck Preset entries: Custom, then `DuckPreset.all`.
    static let duckPresetTitles = ["Custom"] + DuckPreset.all.map(\.title)
    static func duckPresetIndex(_ x: Extras) -> Int {
        guard let amount = x.duckAmount else { return 0 }
        return DuckPreset.matching(amountDB: amount, timing: x.duckTiming).flatMap { DuckPreset.all.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
    }
    static let outsideModes = OutsideMediaMode.allCases
    static func outsideTitle(_ m: OutsideMediaMode) -> String { m == .ask ? "Ask" : m.title }

    /// "System" and every supported UI language in its own name (found whatever the current language is).
    static let uiLanguages: [String] = ["system"] + SQL10n.supported
    static func uiLanguageTitle(_ code: String) -> String {
        guard code != "system" else { return "System" }
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
    static let crossfadeKinds = TransitionKind.kinds(for: .audio)
    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
    /// The transcription languages offered, plus the stored one when it is not among them (the Mac `selectLanguage`).
    static func transcriptionLanguages(_ current: String) -> [String] {
        AppSettings.supportedCaptionLanguages + (AppSettings.supportedCaptionLanguages.contains(current) ? [] : [current])
    }
    static func languageTitle(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }
    /// The Mac `liveDuckAmount`: 0.5...40 dB in 0.5 steps, one decimal, 12 by default, no unit shown.
    static func duckAmountField(_ db: Double?) -> ShellForm.NumberField {
        ShellForm.NumberField(id: "duckAmount", value: db ?? 12, range: 0.5...40, step: 0.5, decimals: 1, defaultValue: 12)
    }
    /// The Edit API status line (`SettingsWindow.applyAPIState`): Copy address only while there is a port.
    static func apiStatus(_ s: ShellEditAPI.State) -> ShellForm.Status {
        ShellForm.Status(text: s.text, tone: s.tone, button: s.copyablePort == nil ? nil : "Copy address", buttonIcon: .copy)
    }

    static func seconds(_ n: Int) -> String { n == 1 ? "1 second" : "\(n) seconds" }
    static let qualities: [MonitorQuality] = [.auto, .full, .half, .quarter]

    /// The rows of one page filled from `s`; the form's sidebar (`sidebar`, id "page") picks the page. Rows, captions,
    /// help lines, check labels and control widths are the Mac `SettingsWindow` pages (`SQFormRow`).
    public static func form(_ page: Page, _ s: AppSettings, _ x: Extras = .load(), _ c: Context = Context()) -> ShellForm {
        let p = pageRows(page, s, x, c)
        let f = ShellForm(p.rows, sidebar: sidebar(c), selected: page.rawValue)
        f.sidePad = 24   // the Mac page rows start at the sidebar rule + 24 (control column 373)
        f.helps = p.helps
        f.checkLabels = p.checkLabels
        f.controlWidths = p.widths
        for (id, cells) in p.grids { f.setGrid(id, cells) }
        for (id, field, w) in p.checkFields { f.setCheckField(id, field, width: w) }
        f.labelTinted = p.labelTinted
        f.statuses = p.statuses
        f.listLines = p.listLines
        return f
    }

    /// One page: rows plus the Mac help lines, check row labels, fixed control widths, grids, check fields and status
    /// lines by row id.
    struct PageRows {
        var rows: [ShellForm.Row]
        var helps: [String: String]
        var checkLabels: [String: String]
        var widths: [String: CGFloat]
        var grids: [(String, [ShellForm.GridCell])]
        var checkFields: [(String, ShellForm.NumberField, CGFloat)]
        var labelTinted: Set<String>
        var statuses: [String: ShellForm.Status]
        var listLines: [String: [ShellForm.ListLine]] = [:]
    }

    static func pageRows(_ page: Page, _ s: AppSettings, _ x: Extras, _ c: Context) -> PageRows {
        var rows: [ShellForm.Row] = []
        var helps: [String: String] = [:], labels: [String: String] = [:], widths: [String: CGFloat] = [:]
        var grids: [(String, [ShellForm.GridCell])] = [], checkFields: [(String, ShellForm.NumberField, CGFloat)] = []
        var tinted: Set<String> = [], statuses: [String: ShellForm.Status] = [:]
        var listLines: [String: [ShellForm.ListLine]] = [:]
        /// `SQFormRow.row(label, fixed(popup, w), help:)`.
        func popup(_ id: String, _ label: String, _ options: [String], _ sel: Int, width: CGFloat = 180, help: String? = nil) {
            rows.append(.popup(id: id, label: label, options: options, selected: sel))
            widths[id] = width
            if let help { helps[id] = help }
        }
        /// `SQFormRow.row(label, checkItem(box, title), help:)`.
        func check(_ id: String, _ label: String, _ title: String, _ on: Bool, help: String? = nil) {
            rows.append(.check(id: id, title: title, on: on))
            labels[id] = label
            if let help { helps[id] = help }
        }
        switch page {
        case .general:
            popup("uiLanguage", "Interface Language", uiLanguages.map(uiLanguageTitle), uiLanguages.firstIndex(of: x.uiLanguage) ?? 0,
                  help: "The language of menus, panels and settings. Applies the next time Sequence Studio starts.")
            popup("uiScale", "Interface Size", InterfaceScale.steps.map(percent), InterfaceScale.steps.firstIndex(of: x.uiScale) ?? 2,
                  help: "Scales text and controls everywhere, right away.")
            // Appearance lives here in the shared shell (DECISIONS 2026-10-28); the Mac has it in the start window.
            popup("appearance", "Appearance", ["Dark", "Light"], x.appearance.mode == .light ? 1 : 0)
            rows += [
                .slider(id: "appearanceBackground", label: "Background", value: Double(x.appearance.background),
                        range: Double(AppearanceSettings.backgroundRange.lowerBound)...Double(AppearanceSettings.backgroundRange.upperBound)),
                .slider(id: "appearanceContrast", label: "Contrast", value: Double(x.appearance.contrast),
                        range: Double(AppearanceSettings.contrastRange.lowerBound)...Double(AppearanceSettings.contrastRange.upperBound)),
            ]
            popup("autosave", "Autosave", AppSettings.autosaveChoices.map { $0 < 120 ? "Every minute" : "Every \(Int($0 / 60)) minutes" },
                  AppSettings.autosaveChoices.firstIndex(of: s.autosaveInterval) ?? 2,
                  help: "Changed projects are saved to a recovery copy; your project file is only written when you save.")
            check("recovery", "Recovery", "Offer to restore after an unclean quit", s.offerRecovery,
                  help: "Changed projects are saved to a recovery copy; this offers to restore it after an unclean quit.")
            check("updates", "Updates", "Check for a newer version at launch", s.checkForUpdates,
                  help: UpdateCheck.feedURL.isEmpty ? "Not set up in this build yet: nothing is contacted."
                      : "Asks one address for the newest version number; nothing else is sent.")
            rows.append(.caption("New items"))
            popup("textLength", "New Text Length", AppSettings.textDurationChoices.map(seconds),
                  AppSettings.textDurationChoices.firstIndex(of: s.defaultTextSeconds) ?? 4)
            popup("transcription", "Transcription", transcriptionLanguages(s.captionLanguage).map(languageTitle),
                  transcriptionLanguages(s.captionLanguage).firstIndex(of: s.captionLanguage) ?? 0,
                  help: "The language spoken in your footage. A project can pick another language in the Captions panel.")
            check("autoLanguage", "Auto Language", "Run again in the language the text turns out to be", s.captionAutoLanguage,
                  help: "When a transcription clearly comes out in another language the list offers, it is transcribed once more in that language. Takes effect the next time a sequence opens.")
        case .playback:
            let ram = String(Int((Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)).rounded()))
            popup("quality", "Preview Quality", qualities.map(\.title),
                  s.previewQualityAuto ? 0 : (qualities.firstIndex(of: s.defaultQuality) ?? 1),
                  help: "The monitors' playback resolution at launch; change it any time in the monitor. Auto picks 1/2 on Macs with 8 GB or less and lowers the resolution while memory runs low. Export always uses full quality.")
            popup("frameCache", "Frame Cache", c.frameCacheTitles, c.frameCacheValues.firstIndex(of: s.frameCacheGB) ?? 0,
                  help: SQL10n.format("Memory for decoded frames of both monitors (this Mac: %@ GB). More plays back smoother, less leaves room for other apps. Auto scales with your Mac and shrinks when memory runs low.", ram))
            check("background", "Background Work", "Make proxies while you edit", s.backgroundWork,
                  help: "Heavy clips get a lighter playback copy in the background. Turn off on a slow Mac to keep it quiet; it also pauses by itself when the Mac is hot or memory runs low.")
            check("renderCache", "Render Cache", "Render heavy parts while idle", s.renderCache,
                  help: "Stretches with effects, speed changes, transitions or several layers are rendered to disk in the background while you do not edit or play, then play smoothly from there. Edits make a new render; old ones age out. Pauses when the Mac is hot or busy.")
            popup("renderCacheCap", "Render Cache Size", AppSettings.renderCacheCapChoices.map { "\($0) GB" },
                  AppSettings.renderCacheCapChoices.firstIndex(of: s.renderCacheCapGB) ?? 2, width: 120,
                  help: "Most disk the render cache may use. The least recently used renders go first.")
            rows.append(.caption("Play around"))
            popup("preroll", "Preroll", AppSettings.rollChoices.map(seconds), AppSettings.rollChoices.firstIndex(of: s.prerollSeconds) ?? 3,
                  width: 120, help: "Seconds played before the marked range (Shift+Space) or the playhead (Shift+K).")
            popup("postroll", "Postroll", AppSettings.rollChoices.map(seconds), AppSettings.rollChoices.firstIndex(of: s.postrollSeconds) ?? 2,
                  width: 120, help: "Seconds played after the marked range or the playhead.")
            rows.append(.caption("Feedback"))
            if let devices = c.audioOutputs {
                let entries = AudioOutputChoices.entries(devices: devices, stored: s.audioOutputUID)
                popup("audioOutput", "Audio Output", entries.map(\.title), AudioOutputChoices.index(of: s.audioOutputUID, in: entries),
                      width: 260, help: "Where both monitors play sound. System Default follows the Mac's output; a device that is not connected falls back to it.")
            }
            check("scrubbing", "Audio Scrubbing", "Play sound while dragging the playhead", s.audioScrubbing)
            check("dropIndicator", "Dropped Frames", "Show a dot when frames are dropped", s.dropIndicator,
                  help: "A small dot in the Program monitor turns amber for two seconds when playback drops a frame. Hover it for the count of the last play.")
        case .editing:
            // The Mac `SQSegmented`: two segments, no popup.
            rows.append(.segmented(id: "newSequence", label: "New Sequences Start in", options: ["Normal", "Fast Cut"],
                                   selected: s.newSequenceEditMode == .magnetic ? 1 : 0, segmentWidth: 0))
            helps["newSequence"] = ("Normal keeps classic tracks and Delete leaves a gap (Shift+Delete closes it). Fast Cut closes gaps on the main track by itself and keeps clips above and below attached to their clip. You can switch any sequence later in the timeline header.")
            rows += [
                .caption("Default transition length"),
                // The Mac `SQFormRow.numberRow`: a right-aligned 72 pt scrub field in `label` tint, unit and note after it.
                .number(label: "Video Transition", ShellForm.NumberField(id: "videoTransition", value: Double(x.transitions.videoFrames),
                        range: 0...10_000, step: 1, unit: "frames · 0 means 1 second", defaultValue: 0)),
                .number(label: "Audio Transition", ShellForm.NumberField(id: "audioTransition", value: x.transitions.audioSeconds,
                        range: 0.05...600, step: 0.05, decimals: 2, unit: "seconds", defaultValue: 1)),
            ]
            tinted.formUnion(["videoTransition", "audioTransition"])
            helps["videoTransition"] = "Default length of transitions placed with Command-D, Shift-Command-D and Shift-D. Existing transitions do not change."
            if let d = c.effectDefaults {
                rows.append(.caption("Your effect and transition defaults"))
                // The Mac `EffectDefaultsSettingsView`: one list box per kind; the shared help sits under the last one.
                for g in EffectDefaults.Group.allCases {
                    rows.append(.listBox(id: "default.\(g.rawValue)", label: g.title, lines: d.entries(in: g).map(\.title),
                                         button: "Restore Factory", empty: EffectDefaults.emptyGroupText))
                    if g == .audioTransitions { helps["default.\(g.rawValue)"] = EffectDefaults.settingsHelp }
                }
            }
        case .audio:
            check("deClick", "De-Click", "Fade clip edges to prevent clicks", x.deClick,
                  help: "A 3 ms fade at the start and end of every audio clip, so hard cuts never pop. Playback and export.")
            rows.append(.caption("Ducking"))
            check("liveDuck", "Live Ducking", "Duck music under dialogue while mixing", x.duckAmount != nil,
                  help: "Music-role tracks follow Dialogue-role tracks while mixing (playback and export). Off by default. A clip that also has baked Auto Duck keys ducks twice.")
            checkFields.append(("liveDuck", duckAmountField(x.duckAmount), 92))
            popup("duckPreset", "Duck Preset", duckPresetTitles, duckPresetIndex(x),
                  help: "Soft is a shallow duck with a slow return for voice-over. Hard is a deep, quick duck for fast speech. Change the amount or any timing value and it shows Custom.")
            popup("duckTiming", "Duck Timing", DuckTimingChoices.titles, DuckTimingChoices.index(of: x.duckTiming),
                  help: "Lookahead starts the duck early, Attack and Recovery are the ramps down and back up, Hold keeps the duck after speech, Minimum pause is the shortest gap that lets the music come back. Classic is the original 300 ms fade each way.")
            // `DuckTimingForm`: 0...max ms in 5 ms steps, double-click resets to 0; `SQFormRow.unitGrid` under the popup.
            grids.append(("duckTiming", timingFields.map {
                ShellForm.GridCell(title: $0.title, field: ShellForm.NumberField(id: "timing.\($0.id)", value: x.duckTiming.clamped[keyPath: $0.key],
                                                                                range: 0...$0.max, step: 5, defaultValue: 0), unit: "ms")
            }))
            rows.append(.caption("Roles"))
            popup("crossfade", "Crossfade", crossfadeKinds.map(\.name), crossfadeKinds.firstIndex(of: x.roles.crossfadeKind) ?? 0,
                  help: "The kind of crossfade the default audio transition places (Shift-Command-D).")
            // `roleOffsetFields` / `roleTransitionFields`: 0.05 steps, two decimals, the value in `label`, no unit; a grid per row.
            func roleGrid(_ id: String, _ label: String, _ range: ClosedRange<Double>, _ value: (AudioTag) -> Double?,
                          _ standard: (AudioTag) -> Double, help: String) {
                rows.append(.label(id: id, label: label))
                helps[id] = help
                var cells: [ShellForm.GridCell] = []
                for tag in AudioTag.allCases {
                    let fid = "\(id).\(tag.rawValue)", base = standard(tag)
                    tinted.insert(fid)
                    cells.append(ShellForm.GridCell(title: tag.title, field: ShellForm.NumberField(
                        id: fid, value: value(tag) ?? base, range: range, step: 0.05, decimals: 2, defaultValue: base)))
                }
                grids.append((id, cells))
            }
            roleGrid("offset", "J / L Offset", 0.05...10, { x.roles.splitOffsetSeconds[$0] }, { AudioRoleDefaults.standard.splitOffsetSeconds[$0] ?? 0.25 },
                     help: "Seconds the audio edit moves for a J or L cut with the offset shortcut, by the role of the clip.")
            roleGrid("length", "Crossfade Length", 0.05...600, { x.roles.transitionSeconds[$0] }, { AudioRoleDefaults.standard.transitionSeconds[$0] ?? 1 },
                     help: "Seconds a default audio transition gets on a clip with this role. Untagged clips use the Audio Transition length on the Editing page.")
            rows.append(.caption("Metering and fades"))
            popup("meterStyle", "Meter Response", MeterStyle.allCases.map(\.title), MeterStyle.allCases.firstIndex(of: x.meterStyle) ?? 1,
                  help: "How fast the level meters fall and how long the peak marker holds. Smooth is calm, Fast follows every peak.")
            popup("fadeCurve", "Fade Shape", FadeCurve.allCases.map(\.title), FadeCurve.allCases.firstIndex(of: x.fadeCurve) ?? 0,
                  help: "The shape a new audio fade gets when you drag its handle. Existing fades keep theirs.")
        case .media:
            let l = s.locations(from: c.defaults)
            popup("outside", "Outside Files", outsideModes.map(outsideTitle), outsideModes.firstIndex(of: x.media.outside) ?? 0,
                  help: "What happens to files dropped from outside the project folder. Files already inside the project folder are always used where they are. A project can override this in File > Media Management.")
            check("watchFolder", "Project Folder", "Add new files in the project folder to the bin", x.media.watchFolder,
                  help: "New files and folders appear in the bin, linked in place; removed files go offline.")
            if c.cardImport {
                check("cardImport", "Card Import", "Open the import window when a card is connected", x.cardImport,
                      help: "You choose per import: copy the files into the Media folder next to your project, or use them directly from the card.")
            }
            check("growing", "Growing Files", "Refresh clips of files that are still being recorded", s.refreshGrowingFiles,
                  help: "Looks every few seconds at project files that grow or get re-rendered and updates their length, thumbnails and waveform. It pauses during playback and export. Off: files are checked when you come back to the app.")
            rows.append(.caption("Library"))
            check("libraryCopy", "Library", "Copy library items used in a sequence into the project", x.media.copyLibraryItems,
                  help: "Sounds, music, video, images and LUTs are copied to Files/Library in the background, once per unique file.")
            if let folders = c.libraryFolders {
                rows.append(.listBox(id: "libFolder", label: "Library Folders", lines: folders.map(\.name), button: "Remove",
                                     empty: "No folders yet."))
                listLines["libFolder"] = folders.map {
                    ShellForm.ListLine(icon: .folder, detail: $0.path, warning: $0.offline ? "unavailable" : nil)
                }
                rows.append(.buttons(id: "libFolderAdd", label: "", detail: "", titles: ["Add Folder…"]))
                helps["libFolder"] = "Folders of sounds, music, graphics, video and LUTs. They appear in the Library panel of every project. Using an item in a sequence copies it into the project."
            }
            rows += [
                .caption("Cache"),
                .buttons(id: "cacheFolder", label: "Cache Folder", detail: StorageFolderChoice.shortPath(s.effectiveCacheFolder),
                         titles: ["Choose…", "Use Default"], enabled: [true, s.cacheFolder != nil]),
            ]
            helps["cacheFolder"] = "Proxies are stored in the Proxies folder inside it. A new folder applies at the next launch; proxies already made stay in the old folder (Delete Cache there is safe, they are rebuilt when needed)."
            popup("cacheCap", "Cache Size", AppSettings.cacheCapChoices.map { "\($0) GB" }, AppSettings.cacheCapChoices.firstIndex(of: s.cacheCapGB) ?? 1,
                  width: 120, help: "Most disk the proxy cache may use. The least recently used proxies go first, never one a monitor is playing.")
            check("proxyExport", "Export", "Use proxies when exporting", s.useProxiesForExport,
                  help: "Renders from the ready proxies instead of the original files: much faster, lower quality. For drafts and review copies only. Clips without a ready proxy use the original, and smart-render copies stay original. Off by default.")
            if let used = c.cacheUsed {
                rows.append(.buttons(id: "cacheClear", label: "", detail: used, titles: ["Delete Cache"]))
                helps["cacheClear"] = "Clearing the cache is safe: files are rebuilt when needed."
            }
            rows += [
                .caption("Folders"),
                .buttons(id: "scratchFolder", label: "Scratch Folder", detail: StorageFolderChoice.shortPath(l.scratchRoot),
                         titles: ["Choose…", "Use Default"], enabled: [true, l.scratchFolder != nil]),
                .buttons(id: "projectsFolder", label: "Projects Folder", detail: StorageFolderChoice.shortPath(l.projectsRoot),
                         titles: ["Choose…", "Use Default"], enabled: [true, l.projectsFolder != nil]),
            ]
            helps["scratchFolder"] = "Temporary working files such as pasted images of an unsaved project. Defaults to the Scratch folder inside the cache folder. Applies at once."
            helps["projectsFolder"] = "Where new projects are created and suggested. Defaults to ~/Movies/Sequence Studio."
            if !c.folderNote.isEmpty { rows.append(.text(c.folderNote)) }
        case .advanced:
            if let api = c.editAPI {
                check("api", "Edit API", "Allow local tools to edit the open project", api.on,
                      help: ShellPlatformText.editAPIHelp)
                statuses["api"] = apiStatus(api.state)
            }
        }
        return PageRows(rows: rows, helps: helps, checkLabels: labels, widths: widths, grids: grids, checkFields: checkFields,
                        labelTinted: tinted, statuses: statuses, listLines: listLines)
    }

    public static func apply(_ f: ShellForm, to s: inout AppSettings, _ c: Context = Context()) {
        func pick<T>(_ id: String, _ list: [T]) -> T? { f.index(id).flatMap { list.indices.contains($0) ? list[$0] : nil } }
        if let v = pick("autosave", AppSettings.autosaveChoices) { s.autosaveInterval = v }
        if let v = f.bool("recovery") { s.offerRecovery = v }
        if let v = f.bool("updates") { s.checkForUpdates = v }
        if let v = pick("textLength", AppSettings.textDurationChoices) { s.defaultTextSeconds = v }
        if let v = f.bool("autoLanguage") { s.captionAutoLanguage = v }
        if let v = pick("transcription", transcriptionLanguages(s.captionLanguage)) { s.captionLanguage = v }
        if let q = pick("quality", qualities) {
            s.previewQualityAuto = q == .auto
            if q != .auto { s.defaultQuality = q }
        }
        if let v = f.bool("background") { s.backgroundWork = v }
        if let v = f.bool("renderCache") { s.renderCache = v }
        if let v = pick("renderCacheCap", AppSettings.renderCacheCapChoices) { s.renderCacheCapGB = v }
        if let v = pick("frameCache", c.frameCacheValues) { s.frameCacheGB = v }
        if let devices = c.audioOutputs, let e = pick("audioOutput", AudioOutputChoices.entries(devices: devices, stored: s.audioOutputUID)) {
            s.audioOutputUID = e.uid
        }
        if let v = pick("preroll", AppSettings.rollChoices) { s.prerollSeconds = v }
        if let v = pick("postroll", AppSettings.rollChoices) { s.postrollSeconds = v }
        if let v = f.bool("scrubbing") { s.audioScrubbing = v }
        if let v = f.index("newSequence") { s.newSequenceEditMode = v == 1 ? .magnetic : .normal }
        if let v = f.bool("dropIndicator") { s.dropIndicator = v }
        if let v = f.bool("growing") { s.refreshGrowingFiles = v }
        if let v = f.bool("proxyExport") { s.useProxiesForExport = v }
        if let v = pick("cacheCap", AppSettings.cacheCapChoices) { s.cacheCapGB = v }
    }

    /// The Mac `uiLanguageChanged`, `transitionDefaultsChanged` and `roleDefaultsChanged`: same ranges, invalid text ignored.
    public static func apply(_ f: ShellForm, to x: inout Extras) {
        if let i = f.index("uiLanguage"), uiLanguages.indices.contains(i) { x.uiLanguage = uiLanguages[i] }
        if let v = f.number("videoTransition"), v.isFinite {
            let frames = Int(v.rounded())
            if frames >= 0, frames <= 10_000 { x.transitions.videoFrames = frames }
        }
        if let v = f.number("audioTransition") {
            let seconds = (v * 100).rounded() / 100
            if seconds.isFinite, seconds > 0, seconds <= 600 { x.transitions.audioSeconds = seconds }
        }
        if let i = f.index("crossfade"), crossfadeKinds.indices.contains(i) { x.roles.crossfadeKind = crossfadeKinds[i] }
        if let i = f.index("uiScale"), InterfaceScale.steps.indices.contains(i) { x.uiScale = InterfaceScale.steps[i] }
        if let i = f.index("appearance") { x.appearance.mode = i == 1 ? .light : .dark }
        if let v = f.number("appearanceBackground"), v.isFinite { x.appearance.background = Int(v.rounded()) }
        if let v = f.number("appearanceContrast"), v.isFinite { x.appearance.contrast = Int(v.rounded()) }
        if let v = f.bool("deClick") { x.deClick = v }
        // `liveDuckChanged`: the typed amount, clamped and rounded to 0.5 dB.
        if let on = f.bool("liveDuck") { x.duckAmount = on ? DuckPreset.clampedAmount(f.number("duckAmount") ?? 12) : nil }
        applyDucking(f, to: &x)
        if let i = f.index("outside"), outsideModes.indices.contains(i) { x.media.outside = outsideModes[i] }
        if let v = f.bool("watchFolder") { x.media.watchFolder = v }
        if let v = f.bool("libraryCopy") { x.media.copyLibraryItems = v }
        if let v = f.bool("cardImport") { x.cardImport = v }
        if let i = f.index("meterStyle"), MeterStyle.allCases.indices.contains(i) { x.meterStyle = MeterStyle.allCases[i] }
        if let i = f.index("fadeCurve"), FadeCurve.allCases.indices.contains(i) { x.fadeCurve = FadeCurve.allCases[i] }
        for r in AudioTag.allCases {
            if let v = f.number("offset.\(r.rawValue)"), v.isFinite, v > 0 { x.roles.splitOffsetSeconds[r] = (v * 100).rounded() / 100 }
            if let v = f.number("length.\(r.rawValue)"), v.isFinite, v > 0 { x.roles.transitionSeconds[r] = (v * 100).rounded() / 100 }
        }
    }

    /// The Mac `liveDuckPresetPicked` and `DuckTimingForm`: a picked Duck Preset sets the amount and the timing (and turns
    /// Live Ducking on); a picked Duck Timing sets the five fields; otherwise the fields are read. `sync` then shows the
    /// result in the form (the preset pop-ups follow the values: Custom when none matches).
    static func applyDucking(_ f: ShellForm, to x: inout Extras) {
        guard f.index("duckTiming") != nil else { return }
        let pickedPreset = f.index("duckPreset") ?? 0
        let pickedTiming = f.index("duckTiming") ?? DuckTimingChoices.presets.count
        if pickedPreset != duckPresetIndex(x), DuckPreset.all.indices.contains(pickedPreset - 1) {
            let p = DuckPreset.all[pickedPreset - 1]
            x.duckAmount = p.amountDB
            x.duckTiming = p.timing
        } else if pickedTiming != DuckTimingChoices.index(of: x.duckTiming), DuckTimingChoices.presets.indices.contains(pickedTiming) {
            x.duckTiming = DuckTimingChoices.presets[pickedTiming].timing
        } else {
            var t = x.duckTiming
            for field in timingFields {
                if let v = f.number("timing.\(field.id)"), v.isFinite { t[keyPath: field.key] = min(max(v.rounded(), 0), field.max) }
            }
            x.duckTiming = t.clamped
        }
    }

    /// Shows the values `x` holds in the derived rows of `f` (the Mac `syncDuckPresetPopup`).
    static func sync(_ f: ShellForm, _ x: Extras) {
        guard f.index("duckTiming") != nil else { return }
        if let on = f.bool("liveDuck"), on != (x.duckAmount != nil) { f.set("liveDuck", .bool(x.duckAmount != nil)) }
        if let db = x.duckAmount { f.set("duckAmount", .number(db)) }
        f.set("duckPreset", .index(duckPresetIndex(x)))
        f.set("duckTiming", .index(DuckTimingChoices.index(of: x.duckTiming)))
        for field in timingFields { f.set("timing.\(field.id)", .number(x.duckTiming.clamped[keyPath: field.key])) }
    }

    /// A button of a `.buttons` row: what the host does.
    enum ButtonAction: Equatable {
        case chooseFolder(Folder), useDefault(Folder), restoreFactory(EffectDefaults.Entry)
        case addLibraryFolder, removeLibraryFolder(Int), clearCache
    }
    enum Folder: String { case cache = "cacheFolder", scratch = "scratchFolder", projects = "projectsFolder" }

    static func buttonAction(_ id: String, button: Int, effectDefaults: EffectDefaults?) -> ButtonAction? {
        if let folder = Folder(rawValue: id) { return button == 0 ? .chooseFolder(folder) : .useDefault(folder) }
        if id == "libFolderAdd" { return .addLibraryFolder }
        if id == "cacheClear" { return .clearCache }
        if id == "libFolder" { return .removeLibraryFolder(button) }
        let parts = id.split(separator: ".")
        guard parts.count == 2, parts[0] == "default", let g = Int(parts[1]).flatMap(EffectDefaults.Group.init(rawValue:)),
              let list = effectDefaults?.entries(in: g), list.indices.contains(button) else { return nil }
        return .restoreFactory(list[button])
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Sets (url) or resets (nil) a storage folder; the note to show under the folder rows.
    static func setFolder(_ folder: Folder, _ url: URL?, settings s: inout AppSettings, defaults d: UserDefaults,
                          migrate: StorageFolderChoice.Migrate = StorageFolderChoice.migrateInBackground) -> String {
        switch folder {
        case .cache: StorageFolderChoice.setCacheFolder(url, settings: &s, defaults: d, migrate: migrate)
        case .scratch: StorageFolderChoice.setFolder(scratch: true, url, defaults: d) ?? ""
        case .projects: StorageFolderChoice.setFolder(scratch: false, url, defaults: d) ?? ""
        }
    }
}

extension ShellHost {
    /// Preferences (Ctrl+,): every change is saved at once, as in the Mac window; the sidebar swaps the page's rows.
    /// Choose… / Use Default and Restore Factory act at once and rebuild the page.
    public func showPreferences(defaults: UserDefaults = .standard) async {
        var settings = AppSettings.load(from: defaults)
        var extras = ShellPreferences.Extras.load(from: defaults)
        var page = ShellPreferences.Page.general
        var note = ""
        var cacheUsed = "Calculating…"
        let d = ShellDialog("Settings")   // the Mac `SettingsWindow` title
        // The Mac `SettingsWindowController`: an L modal (860 x 640) that keeps its size on every page.
        d.width = ShellDialog.M.widthL
        d.cardHeight = ShellDialog.M.heightL
        d.addButton("Done")
        func context() -> ShellPreferences.Context {
            var c = ShellPreferences.Context()
            c.audioOutputs = audioOutputs?()
            c.effectDefaults = effectDefaultsLibrary?.defaults
            c.cardImport = hasCardImport
            c.defaults = defaults
            c.folderNote = note
            c.libraryFolders = libraryFolders?()
            if clearCache != nil { c.cacheUsed = cacheUsed }
            c.editAPI = editAPI.map { ($0.isEnabled(), $0.state()) }
            return c
        }
        func install(_ p: ShellPreferences.Page) {
            page = p
            let c = context()
            let f = ShellPreferences.form(p, settings, extras, c)
            f.onChange = { [weak self, weak d, weak f] id, v in
                guard let self, let f else { return }
                if id == "page", case .index(let i) = v, let p = ShellPreferences.Page(rawValue: i) {
                    note = ""
                    install(p)
                    if let d { d.resetFormScroll(); self.relayout(d) }
                    return
                }
                // Advanced: the Edit API switch (`apiChanged`) and Copy address (`copyAPIAddress`), not stored here.
                if id == "api", case .bool(let on) = v {
                    self.editAPI?.setEnabled(on)
                    if let api = self.editAPI { f.statuses["api"] = ShellPreferences.apiStatus(api.state()) }
                    if let d { self.relayout(d) }
                    return
                }
                if id == "api.status" {
                    if let port = self.editAPI?.state().copyablePort { self.copyText?("127.0.0.1:\(port)") }
                    return
                }
                if case .index(let b) = v, let act = ShellPreferences.buttonAction(id, button: b, effectDefaults: c.effectDefaults) {
                    self.spawn { [weak self, weak d] in
                        guard let self else { return }
                        let url: URL?
                        if case .chooseFolder = act {
                            guard let picked = await self.files?.chooseFolder(prompt: SQL10n.string("Choose")) else { return }
                            url = picked
                        } else if case .addLibraryFolder = act {
                            guard let picked = await self.files?.chooseFolder(prompt: SQL10n.string("Add")) else { return }
                            url = picked
                        } else { url = nil }
                        if case .removeLibraryFolder(let i) = act {
                            if let list = c.libraryFolders, list.indices.contains(i) { let id = list[i].id; await self.removeLibraryFolder?(id) }
                        } else if case .addLibraryFolder = act, let url {
                            await self.addLibraryFolder?(url)
                        } else if case .clearCache = act {
                            self.clearCache?()
                            cacheUsed = "Calculating…"
                            refreshUsed()
                        } else if let n = self.perform(act, url: url, settings: &settings, defaults: defaults) { note = n }
                        install(page)
                        if let d { self.relayout(d) }
                    }
                    return
                }
                ShellPreferences.apply(f, to: &settings, c)
                settings.save(to: defaults)
                ShellPreferences.apply(f, to: &extras)
                extras.save(to: defaults)
                ShellPreferences.sync(f, extras)
                self.onSettingsChanged?(settings)
            }
            f.sidebarFocused = d.form?.sidebarFocused ?? false   // a page picked by key keeps the keyboard on the list
            d.form = f
        }
        func refreshUsed() {
            guard clearCache != nil else { return }
            let url = settings.effectiveCacheFolder, proxies = settings.proxyCacheDirectory
            Task { @MainActor in
                let text = await Task.detached(priority: .utility) { () -> String in
                    var bytes = ShellPreferences.folderSize(url)
                    if !proxies.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") { bytes += ShellPreferences.folderSize(proxies) }
                    return bytes == 0 ? "Empty" : SQByteSize.string(bytes)
                }.value
                cacheUsed = text
                if page == .media { install(page); self.relayout(d) }
            }
        }
        install(.general)
        refreshUsed()
        // A server that starts or fails after the switch updates the line while the page is open (`onState`).
        editAPI?.stateChanged = { [weak self, weak d] in
            guard let self, let d, page == .advanced, let f = d.form, let api = self.editAPI else { return }
            f.statuses["api"] = ShellPreferences.apiStatus(api.state())
            self.relayout(d)
        }
        _ = await ask(d)
        editAPI?.stateChanged = nil
    }

    /// Runs a button of a Preferences row (the folder already chosen); the new folder note, nil to keep the old one.
    private func perform(_ act: ShellPreferences.ButtonAction, url: URL?, settings: inout AppSettings,
                         defaults: UserDefaults) -> String? {
        switch act {
        case .chooseFolder(let folder), .useDefault(let folder):
            let note = ShellPreferences.setFolder(folder, url, settings: &settings, defaults: defaults)
            if folder == .projects { newProjectLocation = StorageLocations.load(from: defaults).projectsRoot }
            onSettingsChanged?(settings)
            return note
        case .addLibraryFolder, .removeLibraryFolder, .clearCache:
            return nil
        case .restoreFactory(let entry):
            guard let lib = effectDefaultsLibrary else { return nil }
            if !lib.update({ $0.remove(entry) }) { flash("Your defaults could not be saved.") }
            session.effectDefaults = lib.defaults
            return nil
        }
    }
}

import Foundation
import SQCore
import SQMonitorUI
import SQTimelineUI
import SQUIKit

/// The pages of the Settings window (windows proposal section 4): an L modal with a 200 wide sidebar. Pure model: the
/// order, titles, icons and which option lives on which page. `SettingsOption` is the full inventory, so a test can prove
/// that no option was dropped when the grouping changed.
public enum SettingsPage: Int, CaseIterable, Sendable {
    case general, playback, editing, audio, media, advanced

    public var title: String {
        switch self {
        case .general: "General"
        case .playback: "Playback"
        case .editing: "Editing"
        case .audio: "Audio"
        case .media: "Media"
        case .advanced: "Advanced"
        }
    }

    public var icon: SQIcon {
        switch self {
        case .general: .slidersHorizontal
        case .playback: .play
        case .editing: .pencil
        case .audio: .waveform
        case .media: .folder
        case .advanced: .code
        }
    }

    /// Title in the UI language (`title` stays English: `slug` and tests use it).
    public var localizedTitle: String { SQL10n.string(title) }

    /// Stable name for the render harness and tests.
    public var slug: String { title.lowercased() }

    /// Options of this page in display order.
    public var options: [SettingsOption] { SettingsOption.allCases.filter { $0.page == self } }

    /// Sidebar width of the L modal.
    public static let sidebarWidth: CGFloat = 200
}

/// Every option of the Settings window, one case each, in display order. `defaultsKey` is the UserDefaults key that
/// stores it (nil: not one plain key; library folders live in the Library model, effect defaults in `EffectDefaultsLibrary`).
public enum SettingsOption: String, CaseIterable, Sendable {
    // General
    case autosave, recovery, updateCheck, newTextLength, transcription
    // Playback
    case previewQuality, frameCache, backgroundWork, renderCache, preroll, postroll, audioScrubbing, droppedFrames
    // Editing
    case newSequenceMode, videoTransition, audioTransition, effectDefaults
    // Audio
    case deClick, liveDucking, duckTiming, meterBallistics, defaultFadeCurve
    // Media
    case outsideFiles, projectFolder, cardImport, growingFiles, libraryCopy, libraryFolders, cache
    // Advanced
    case editAPI

    public var page: SettingsPage {
        switch self {
        case .autosave, .recovery, .updateCheck, .newTextLength, .transcription: .general
        case .previewQuality, .frameCache, .backgroundWork, .renderCache, .preroll, .postroll, .audioScrubbing, .droppedFrames: .playback
        case .newSequenceMode, .videoTransition, .audioTransition, .effectDefaults: .editing
        case .deClick, .liveDucking, .duckTiming, .meterBallistics, .defaultFadeCurve: .audio
        case .outsideFiles, .projectFolder, .cardImport, .growingFiles, .libraryCopy, .libraryFolders, .cache: .media
        case .editAPI: .advanced
        }
    }

    /// Row label as shown.
    public var title: String {
        switch self {
        case .autosave: "Autosave"
        case .recovery: "Recovery"
        case .updateCheck: "Updates"
        case .newTextLength: "New Text Length"
        case .transcription: "Transcription"
        case .previewQuality: "Preview Quality"
        case .frameCache: "Frame Cache"
        case .backgroundWork: "Background Work"
        case .renderCache: "Render Cache"
        case .preroll: "Preroll"
        case .postroll: "Postroll"
        case .audioScrubbing: "Audio Scrubbing"
        case .droppedFrames: "Dropped Frames"
        case .newSequenceMode: "New Sequences Start in"
        case .videoTransition: "Video Transition"
        case .audioTransition: "Audio Transition"
        case .effectDefaults: "Effect Defaults"
        case .deClick: "De-Click"
        case .liveDucking: "Live Ducking"
        case .duckTiming: "Duck Timing"
        case .meterBallistics: "Meter Response"
        case .defaultFadeCurve: "Fade Shape"
        case .outsideFiles: "Outside Files"
        case .projectFolder: "Project Folder"
        case .cardImport: "Card Import"
        case .growingFiles: "Growing Files"
        case .libraryCopy: "Library"
        case .libraryFolders: "Library Folders"
        case .cache: "Cache"
        case .editAPI: "Edit API"
        }
    }

    /// UserDefaults key (`sq.*` or the older `settings.*`); nil when the value is not one plain key.
    public var defaultsKey: String? {
        switch self {
        case .autosave: "settings.autosaveInterval"
        case .recovery: "settings.offerRecovery"
        case .updateCheck: "sq.updates.check"
        case .newTextLength: "settings.defaultTextSeconds"
        case .transcription: "sq.captions.language"
        case .previewQuality: "sq.playback.previewQualityAuto"
        case .frameCache: "sq.playback.frameCacheGB"
        case .backgroundWork: "sq.playback.backgroundWork"
        case .renderCache: "sq.playback.renderCache"
        case .preroll: "settings.prerollSeconds"
        case .postroll: "settings.postrollSeconds"
        case .audioScrubbing: "sq.audioScrubbing"
        case .droppedFrames: "sq.playback.dropIndicator"
        case .newSequenceMode: "sq.newSequenceEditMode"
        case .videoTransition: "settings.videoTransitionFrames"
        case .audioTransition: "settings.audioTransitionSeconds"
        case .deClick: "sq.audio.autoDeClick"
        case .liveDucking: "sq.audio.liveDuckingDB"
        case .duckTiming: "sq.audio.liveDuckingLookaheadMs"
        case .meterBallistics: MeterStyle.defaultsKey
        case .defaultFadeCurve: DefaultFadeCurve.defaultsKey
        case .outsideFiles: "sq.media.outside"
        case .projectFolder: "sq.media.watchProjectFolder"
        case .libraryCopy: "sq.media.copyLibraryItems"
        case .cardImport: "sq.autoImportFromCards"
        case .growingFiles: "sq.media.refreshGrowing"
        case .editAPI: "sq.api.enabled"
        case .effectDefaults, .libraryFolders, .cache: nil
        }
    }
}

/// Run state of the Edit API server as the Settings page shows it (a dot and one line under the checkbox).
public enum EditAPIRunState: Sendable, Equatable {
    case notRunning
    case starting
    case listening(port: Int)
    /// Listening, but the connection file for local tools could not be written.
    case listeningNoFile(port: Int)
    case portInUse(port: Int)

    public var text: String {
        switch self {
        case .notRunning: "Not running"
        case .starting: "Starting…"
        case .listening(let p): "Listening on 127.0.0.1, port \(p)"
        case .listeningNoFile(let p): "Listening on 127.0.0.1, port \(p), but the connection file could not be written"
        case .portInUse: "Port in use, could not start"
        }
    }

    public enum Tone: Sendable, Equatable { case idle, ok, warning }
    public var tone: Tone {
        switch self {
        case .notRunning, .starting: .idle
        case .listening: .ok
        case .listeningNoFile, .portInUse: .warning
        }
    }

    /// Port to copy; nil unless the server listens.
    public var copyablePort: Int? {
        switch self {
        case .listening(let p), .listeningNoFile(let p): p
        default: nil
        }
    }
}

import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQMediaFFmpeg
import SQPlayback
import SQUIKit
import WinSDK

/// The monitor's DPI factor; the theme scale is this times Preferences > Interface Size.
@MainActor private var windowDPIScale: Float = 1

/// Preferences rows the Windows app reads itself (the Mac app has observers for each): Interface Size and Appearance (theme),
/// Meter Response (the meter ballistics), De-Click and Live Ducking (the WASAPI feeder), Audio Output (the WASAPI
/// device), Frame Cache (the Program engine's cache), Cache Size and Make proxies while you edit (`WinProxies`). Fade
/// Shape is read by the timeline when it draws fades, Transcription and the other AppSettings rows by the session; the
/// effect defaults library feeds the session.
extension AppController {
    func wirePreferences(dpiScale: Float) {
        windowDPIScale = dpiScale
        shell.audioOutputs = { WASAPIAudioEngine.outputDevices().map { AudioOutputChoices.Device(uid: $0.uid, name: $0.name) } }
        wireEffectDefaults()
        let previous = shell.onSettingsChanged
        shell.onSettingsChanged = { [weak self] s in
            previous?(s)
            self?.applyPreferences()
        }
        applyPreferences()
    }

    /// The window moved to a monitor with another DPI (WM_DPICHANGED).
    func setWindowDPIScale(_ dpiScale: Float) {
        guard dpiScale != windowDPIScale else { return }
        windowDPIScale = dpiScale
        applyPreferences()
    }

    func applyPreferences() {
        let scale = windowDPIScale * Float(InterfaceScale.load())
        let theme = DrawTheme(settings: AppearanceSettings(defaults: .standard), scale: scale)   // Preferences > General > Appearance
        if screen.theme != theme { screen.theme = theme }
        meters.meter.meter.style = MeterStyle.current()
        engine.audioOutput?.feeder.applyAudioPreferences()
        let settings = AppSettings.load()
        engine.audioOutput?.setOutputDevice(settings.audioOutputUID)
        let total = MemoryBudget.current().frameCacheBytes(userGB: settings.frameCacheGB)
        engine.frameCacheBytes = MemoryBudget.split(total).program
        WinProxies.shared.applySettings(settings)
    }

    /// The Mac `wireEffectDefaults`: the session reads the user's defaults from the one library and writes its changes
    /// there; Preferences > Editing lists them with Restore Factory.
    private func wireEffectDefaults() {
        let lib = EffectDefaultsLibrary.shared
        shell.effectDefaultsLibrary = lib
        session.effectDefaults = lib.defaults
        session.onEffectDefaultsChange = { [weak self] d in
            guard !lib.replace(with: d) else { return }
            self?.session.effectDefaults = lib.defaults
            self?.shell.onStatus?("Your defaults could not be saved.")
        }
    }
}

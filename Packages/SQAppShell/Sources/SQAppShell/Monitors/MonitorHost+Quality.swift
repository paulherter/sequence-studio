import Foundation
import SQDrawMonitor
import SQEditorSession

/// The remembered playback quality (the Mac `AppController.applyRememberedQuality` and its `onQualityChange`): the
/// Program monitor starts at the Preferences quality (`AppSettings.startQuality`), a hand pick in the monitor's popup is
/// saved as the new default (Auto as Auto), a programmatic apply saves nothing.
extension MonitorHost {
    /// Applies the saved quality now and saves later hand picks to `defaults`. `autoBase` is what Auto starts at.
    /// shortcut: the shared hosts pass Full as the Auto base (the Mac `MemoryBudget.autoPreviewQuality` halves it on
    /// low-memory Macs); upgrade when the memory budget has a portable seam.
    public func rememberQuality(in defaults: UserDefaults, autoBase: MonitorQuality = .full) {
        model.setAutoBase(autoBase)
        let engine = model.onQualityChange
        var applying = false
        model.onQualityChange = { [weak self] q in
            engine?(q)
            guard let self, !applying else { return }
            let s = AppSettings.load(from: defaults)
            if model.quality == .auto {
                guard !s.previewQualityAuto else { return }
                var a = s
                a.previewQualityAuto = true
                a.save(to: defaults)
                return
            }
            let fixed = s.choosingFixedQuality(q)
            if fixed != s { fixed.save(to: defaults) }
        }
        applyQuality = { [weak self] settings in
            guard let self else { return }
            applying = true
            defer { applying = false }
            model.setQuality(settings.startQuality(auto: autoBase))
        }
        applyQuality?(AppSettings.load(from: defaults))
    }
}

import AppKit
import SQAppShell
import SQCore
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQLibrary
import SQMonitorUI
import SQRender
import SQUIKit

/// What the shared shell rounds 9-11 added on the portable side, hooked up on the Mac shared UI as the Windows
/// AppController does (AppController+Timeline, +Project, +ViewOptions, WinCardWatcher): the Remove Silences red preview,
/// timeline check marks, Hover Scrub frames, card import (mount watcher and board posters), New Shape and View Gamma.
extension SharedUIController {
    func wireShellHooks() {
        // The start screen's search in the window bar, as the AppKit start window's title bar.
        shell.startSearchInBar = true
        // Check marks of the timeline toggles and thumbnail mode; the Remove Silences dialog's red preview.
        shell.menuChecks.append { [weak self] in
            guard let self else { return [] }
            return timelinePanel.viewChecks(session: session)
        }
        shell.silencePreview = { [weak self] ranges in self?.timelinePanel.silencePreview = ranges }
        // Hover Scrub: the frame under the pointer from the timeline atlas (the AppKit `ProjectThumbnails.scrub`).
        projectList.posterAt = { [mediaStore] id, t in
            mediaStore.picture(media: id, at: t).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
        // Project menu > Extract Audio: the AppKit `projectView.onExtractAudio` (EditorPanels), messages as there.
        projectList.onExtractAudio = { [weak self] id in
            guard let self, let model = shell.projectModel else { return }
            Task { @MainActor in
                do {
                    if try await model.extractAudio(of: id, resolver: self.session.media) == nil {
                        self.shell.presentMessage("Extract Audio", "Extract Audio: the file could not be added.")
                    }
                } catch AudioExtraction.Failure.noAudio {
                    self.shell.presentMessage("Extract Audio", "This item has no sound.")
                } catch AudioExtraction.Failure.offline {
                    self.shell.presentMessage("Extract Audio", SQL10n.string("The item is offline. Reconnect it first."))
                } catch {
                    self.shell.presentMessage("Extract Audio", SQL10n.format("Extract Audio failed: %@", SQL10n.errorText(error)))
                }
            }
        }
        // shortcut: Conform to Constant Frame Rate stays hidden in the shared UI (hook nil); wire it when the shared
        // shell gets the AppKit conform progress sheet.
        // Sequence > New Shape takes the Create tool's path, as on the AppKit monitor.
        shell.onNewShape = { [weak self] kind in
            guard let self else { return }
            monitors.monitor.createShapeAtCenter(kind, graphics: graphics.editor)
        }
        // Go to Timecode opens the monitor's timecode field, as on the AppKit monitor; a rejected text shows its hint.
        shell.focusTimecode = { [weak self] in self?.monitors.focusTimecodeField() ?? false }
        for panel in [monitors.monitor.panel, monitors.source.panel] {
            panel.onHint = { [weak self] in self?.shell.onStatus?($0) }
        }
        // View > View Gamma: the Presenter reads `ViewGamma.current` (the AppKit `MonitorPanelModel.setViewGamma`); both
        // monitors redraw so a paused picture follows at once.
        let next = shell.onCommand
        shell.onCommand = { [weak self] c in
            guard case .viewGamma(let choice) = c, let g = ViewGamma(rawValue: choice.rawValue) else { return next?(c) ?? false }
            ViewGamma.current = g
            self?.engine.redraw()
            self?.monitors.source.engine.player.redraw()
            return true
        }
        shell.menuChecks.append {
            Set(ViewGammaChoice.allCases.filter { $0.rawValue == ViewGamma.current.rawValue }.map { EditorCommand.viewGamma($0) })
        }
        wireCardImport()
        // Find Scene Changes, Auto Reframe, Stabilize: the shared `AnalysisFlows` over the Mac's AVFoundation / Vision backend.
        shell.analysisBackend = MacAnalysisBackend()
        // Match Color to Clip captures the solo clip from the engine; Weak Tracking and Quick Apply use the same caches and
        // catalog as the AppKit window.
        shell.frameSampler = MacFrameSampler(engine: engine)
        let health = MagicTrackHealthCache.mac()
        shell.magicHealth = health
        timelinePanel.trackWeakSpans = { [weak health] clip in health?.weakSpans(for: clip) }
        LibraryHost.connectQuickApply(shell: shell) { [weak self] in self?.library }
        shell.saveStackAsPreset = { [weak self] in _ = self?.timelineHost.open?(.saveClipPreset) }
        shell.onJob = { [weak self] in self?.job = $0 }
    }

    /// Card import on the shared dialog (`ShellHost.openCardImport`): the AppKit CardImportCoordinator's mount note and
    /// volume rule, the dialog closes on unmount, a camera card already mounted at launch is offered once
    /// (`CardAtLaunch`, as on Windows). Board tiles: the file's first frame from the timeline atlas.
    private func wireCardImport() {
        shell.hasCardImport = true
        ShellCardImport.poster = { [mediaStore] item in
            mediaStore.picture(media: mediaStore.id(forPath: item.url.path), at: nil).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        cardObservers = [
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
                let u = Self.volume(of: note)
                MainActor.assumeIsolated { if let u { self?.offerCard(u) } }
            },
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
                let u = Self.volume(of: note)
                MainActor.assumeIsolated { if let u { self?.shell.closeCardImport(volume: u) } }
            },
        ]
    }

    /// The volume a mount / unmount note names.
    nonisolated static func volume(of note: Notification) -> URL? {
        let path = (note.userInfo?["NSDevicePath"] as? String) ?? (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
        return path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// A mounted volume that is an import source opens the card dialog while Preferences > Media > Card Import is on.
    func offerCard(_ volume: URL) {
        guard CardImportSettings.enabled, let facts = CardImportCoordinator.facts(for: volume), facts.isImportSource else { return }
        shell.openCardImport(volume: volume)
    }

    /// Camera cards mounted before launch (call once the window is up).
    func offerCardsAtLaunch() {
        guard CardImportSettings.enabled else { return }
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for v in vols {
            guard let facts = CardImportCoordinator.facts(for: v), facts.isImportSource else { continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: v.path)) ?? []
            if CardAtLaunch.looksLikeCameraCard(topLevel: names) { shell.openCardImport(volume: v, atLaunch: true) }
        }
    }
}

/// Frame capture for Match Color to Clip on the shared Mac window: the Program engine's next render, linear.
@MainActor final class MacFrameSampler: ProgramFrameSampling {
    private let engine: any ProgramEngine
    init(engine: any ProgramEngine) { self.engine = engine }
    func sampleLinear(width: Int, key: String, done: @escaping @MainActor ([SIMD3<Float>]?) -> Void) {
        guard engine.lastRenderedTexture != nil else { return done(nil) }
        FrameSampler.sampleScaled(engine: engine, width: width, key: key) { r in done(r?.linear) }
        if engine.rate.isPaused { engine.redraw() }   // paused, nothing renders by itself
    }
}

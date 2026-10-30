import Foundation

/// System events after which project media may have changed on disk or the machine's state changed under playback.
public enum MediaDiskEvent: Sendable, Equatable {
    /// The app came to the front (a file may have been re-exported meanwhile).
    case activated
    /// A volume appeared or went away (SD card, USB disk, network drive).
    case mounted, unmounted
    /// The Mac goes to sleep or the displays do; and the matching wake-ups.
    case willSleep, didWake
}

/// Media files changing under the open project: re-exported or overwritten clips, volumes that unmount or come back,
/// the Mac sleeping. Decoders, caches and the viewer follow the files without a manual relink.
extension EditorSession {
    /// Starts listening to the workspace (app activation, volumes, sleep and wake). The app calls this once.
    /// shortcut: off the Mac nothing watches volumes and sleep yet (`refreshMediaFromDisk` still works when called);
    /// upgrade with a Windows watcher (WM_DEVICECHANGE, power broadcasts) that sends the same `MediaDiskEvent`s.
    public func startWatchingMediaFiles() {
        #if os(macOS)
        guard diskWatcher == nil else { return }
        diskWatcher = MediaDiskWatcher { [weak self] event in self?.handleDiskEvent(event) }
        #endif
    }

    public func stopWatchingMediaFiles() {
        #if os(macOS)
        diskWatcher?.stop()
        diskWatcher = nil
        #endif
    }

    func handleDiskEvent(_ event: MediaDiskEvent) {
        switch event {
        case .willSleep:
            // A sleeping Mac tears the audio device down under a running playback: stop first, the user presses Play after.
            stopPlayback()
        case .activated, .mounted, .unmounted, .didWake:
            Task { [weak self] in await self?.refreshMediaFromDisk() }
        }
    }

    /// Looks at every media file once (off the main thread) and reacts to what changed since the last look: open
    /// sources of changed, vanished and returned files are dropped and opened again, the viewer redraws, and
    /// `onMediaFilesChanged` lets the UI forget thumbnails and waveforms. The first look only records the state.
    /// Returns the items that changed.
    @discardableResult
    public func refreshMediaFromDisk() async -> Set<UUID> {
        guard !diskRefreshRunning else { return [] }
        diskRefreshRunning = true
        defer { diskRefreshRunning = false }
        let projectID = project.id
        let paths = Dictionary(project.media.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        let snapshot = await Task.detached(priority: .utility) { MediaDiskTracker.snapshot(paths) }.value
        guard project.id == projectID else { return [] }
        let changes = diskTracker.update(snapshot)
        return applyDiskChanges(changes)
    }

    @discardableResult
    func applyDiskChanges(_ changes: MediaDiskTracker.Changes) -> Set<UUID> {
        let touched = changes.all
        guard !touched.isEmpty else { return [] }
        media.invalidate(touched)
        requestedMedia.subtract(touched)
        engine.mediaChanged(touched)
        renderCache?.mediaChanged()
        for a in auxiliaryEngines { a.engine?.mediaChanged(touched) }
        onMediaFilesChanged?(touched)
        let reopen = Array(changes.modified.union(changes.appeared))
        if !reopen.isEmpty {
            requestedMedia.formUnion(reopen)
            Task { [weak self, media] in
                await media.prepare(reopen)
                self?.notify(.media)
            }
        }
        notify(.media)
        return touched
    }
}

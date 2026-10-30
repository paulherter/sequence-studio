import AppKit
import AVFoundation
import SQCore
import SQEditorSession
import SQMedia
import SQUIKit

// Clip > Sync Audio to Reference: reads the files (sound envelopes, start timecodes, capture dates), builds the fit
// with SQCore `AudioDriftFit`, and applies it with `EditorSession.syncAudio` (move plus drift retime, one undo step each).
extension AppController {
    private struct SyncSource: Sendable {
        var url: URL
        var ntsc: Bool
    }

    func requestSyncAudio() {
        guard let plan = session.syncAudioPlan else {
            SQDialog.info("Sync Audio to Reference",
                          message: "Select at least two clips. The clip that starts first is the reference; the others are lined up to it.",
                          in: window)
            return
        }
        func source(_ id: Clip.ID) -> SyncSource? {
            guard let c = session.activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }), let ref = session.project.media(c.media) else { return nil }
            let fd = ref.info?.video?.nominalFrameDuration
            return SyncSource(url: URL(fileURLWithPath: ref.path), ntsc: fd.map { $0.value % 1001 == 0 } ?? false)
        }
        guard let reference = source(plan.reference) else {
            SQDialog.warn("Sync Audio to Reference", message: "The reference clip has no media file.", in: window)
            return
        }
        let targets: [(id: Clip.ID, source: SyncSource)] = plan.targets.compactMap { id in source(id).map { (id, $0) } }
        shell.statusBar.flash("Lining up the audio…", seconds: 60)
        Task { @MainActor [weak self] in
            var fits: [(id: Clip.ID, fit: AudioDriftFit.Fit?)] = []
            for t in targets {
                fits.append((t.id, await Self.syncFit(reference: reference, other: t.source)))
            }
            self?.finishSyncAudio(reference: plan.reference, fits: fits)
        }
    }

    private func finishSyncAudio(reference: Clip.ID, fits: [(id: Clip.ID, fit: AudioDriftFit.Fit?)]) {
        var done = 0, unmatched = 0, byDate = 0
        var failure: String?
        for f in fits {
            guard let fit = f.fit else { unmatched += 1; continue }
            if session.syncAudio(f.id, to: reference, fit: fit, retime: true) {
                done += 1
                if fit.method == .captureDate { byDate += 1 }
            }
            else if failure == nil { failure = session.lastError }
        }
        if let failure {
            // Collision (destination occupied) and speedUnsupported (reference retimed, target reversed) end here.
            SQDialog.warn("Sync Audio to Reference", message: failure, in: window)
        } else if done == 0 {
            SQDialog.warn("Sync Audio to Reference",
                          message: "The recordings could not be matched: no shared sound and no timecode or capture date.", in: window)
        } else {
            var tail = unmatched > 0 ? " " + SQL10n.format("%@ could not be matched.", String(unmatched)) : ""
            if let w = EditorSession.captureDateWarning(count: byDate) { tail += " " + w }
            shell.statusBar.flash(SQL10n.plural(done, one: "Synced %@ clip to the reference.", other: "Synced %@ clips to the reference.") + tail, seconds: 5)
        }
    }

    /// Both files with a start timecode: the timecode difference. Otherwise the sound fit; when the sound does not
    /// match, the capture dates (to the second), so camera clips without shared sound still land near each other.
    private nonisolated static func syncFit(reference: SyncSource, other: SyncSource) async -> AudioDriftFit.Fit? {
        if let a = await AnglesSync.startTimecode(url: reference.url, ntsc: reference.ntsc),
           let b = await AnglesSync.startTimecode(url: other.url, ntsc: other.ntsc) {
            return AudioDriftFit.timecode(reference: a, other: b)
        }
        if let r = try? await AnglesSync.envelope(url: reference.url), !r.isEmpty,
           let o = try? await AnglesSync.envelope(url: other.url), !o.isEmpty {
            let fit = await Task.detached(priority: .userInitiated) {
                AudioDriftFit.fit(reference: r, other: o, rate: AnglesSync.envelopeRate)
            }.value
            if let fit { return fit }
        }
        guard let a = await captureDate(reference.url), let b = await captureDate(other.url) else { return nil }
        // shortcut: whole-second capture dates, no sub-second placement; upgrade when a camera writes finer stamps.
        return AudioDriftFit.captureDate(reference: seconds(a), other: seconds(b))
    }

    private nonisolated static func seconds(_ d: Date) -> Time { Time(Int64(d.timeIntervalSince1970.rounded()), 1) }

    private nonisolated static func captureDate(_ url: URL) async -> Date? {
        if let item = try? await AVURLAsset(url: url).load(.creationDate), let d = try? await item.load(.dateValue) { return d }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}

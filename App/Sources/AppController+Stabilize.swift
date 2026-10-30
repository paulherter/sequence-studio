import AppKit
import SQAnalysis
import SQCore
import SQEditorSession
import SQEditorUI
import SQUIKit

/// The running Stabilize analysis (extensions cannot add stored properties to AppController).
@MainActor private enum StabilizeRun {
    /// One picture analysis at a time (menu command, Analyze row, stale re-run). Cancel ends it for the UI at once.
    static let job = AnalysisJob<StabilizeOutcome>()
    /// Clip + source range already re-run automatically (a failure must not loop).
    static var autoTried: Set<String> = []
    static var autoTask: Task<Void, Never>?
    /// The clips of the running analysis, and those of them that carried a Stabilizer when it started (removing the
    /// effect or deleting the clip ends the run).
    static var shown: Set<Clip.ID> = []
    static var watched: Set<Clip.ID> = []
    /// The running analysis is ended because its effect or clip went: no "canceled" message.
    static var silentEnd = false
    /// Gyro data per media path (probing reads the file's moov once).
    static var gyroSources: [String: GyroDataSource?] = [:]
    /// The same engine the media resolver renders through (ProjectMediaResolver's default).
    static let gyroEngine: any GyroStabilizationEngine = GyroflowEngine.shared
}

/// Clip > Video Options > Stabilize (W9.7): Vision measures the camera shake of the selected clips (else the clips under
/// the playhead) in the background and a Stabilizer effect removes it. Results are cached per file and range, so running
/// it again (e.g. after switching Result to No Motion in Effect Controls) is quick. Choosing it again while it analyzes
/// cancels it (the menu item then reads "Cancel Stabilize").
extension AppController {
    var isStabilizing: Bool { StabilizeRun.job.isRunning }

    /// Cache-only lookup for the live re-plan (Effect Controls settings).
    static let stabilizationLookup: EditorSession.StabilizationLookup = { media, range, w, h in
        await Task.detached(priority: .userInitiated) {
            StabilizationCache().cached(url: URL(fileURLWithPath: media.path), range: range, pictureWidth: w, pictureHeight: h)
        }.value
    }

    /// Runs a picture analysis of `ids` (nil = the Stabilize targets): the Analyze rows of those clips and a status-bar
    /// line show the progress until it ends; the ending (result, canceled, or the error) is said in the status bar.
    private func runStabilize(_ ids: Set<Clip.ID>?, in timeline: Timeline.ID? = nil, what: String) {
        let model = panels.effectModel
        let shown = ids ?? Set(session.stabilizeTargets.map(\.id))
        let bar = shell.statusBar
        let timeline = timeline ?? session.activeTimelineID
        StabilizeRun.shown = shown
        StabilizeRun.watched = Set(shown.filter { id in
            session.project.timeline(timeline ?? UUID())?.tracks.flatMap(\.clips).first { $0.id == id }?.stabilizerID != nil
        })
        StabilizeRun.silentEnd = false
        let strips = panels.timelineView
        strips.analysisProgress = Dictionary(uniqueKeysWithValues: shown.map { ($0, 0.0) })
        model.stabilizeRun = StabilizeRunState(clips: shown, progress: 0)
        bar.setJob("Stabilize: analyzing \(what)…")
        StabilizeRun.job.start({ [weak self] progress in
            guard let self else { throw CancellationError() }
            return try await session.stabilize(only: ids, in: timeline, progress: progress) { media in
                VisionStabilizationAnalyzer(url: URL(fileURLWithPath: media.path), deinterlace: media.info?.video?.deinterlaceFieldOrder)
            }
        }, progress: { p in
            model.stabilizeRun?.progress = p
            strips.analysisProgress = Dictionary(uniqueKeysWithValues: shown.map { ($0, p) })
            bar.setJob("Stabilize: analyzing \(what)… \(Int((p * 100).rounded())) %")
        }, ended: { [weak self] ending in
            model.stabilizeRun = nil
            strips.analysisProgress = [:]
            bar.setJob(nil)
            let silent = StabilizeRun.silentEnd
            StabilizeRun.silentEnd = false
            StabilizeRun.shown = []; StabilizeRun.watched = []
            switch ending {
            case .done(let out): bar.flash(AnalysisFlows.stabilizeMessage(out), seconds: 5)
            case .cancelled: if !silent { bar.flash("Stabilize canceled.", seconds: 3) }
            case .failed(let why): bar.flash(SQL10n.format("Stabilize failed: %@", why), seconds: 8)
            }
            guard let self else { return }
            // Clips that asked while this run was going (Rolling Shutter switched on, an Analyze row) follow now;
            // Cancel stops them too.
            // The queue is per sequence: it runs whichever sequence is open now.
            if case .cancelled = ending { session.dropQueuedStabilizerAnalysis(); return }
            if case .failed = ending { session.withdrawRollingShutterRequests(clips: shown) }
            if let next = session.takeNextQueuedStabilizerAnalysis() { analyzeStabilizers(next.clips, in: next.timeline) }
        })
    }

    /// The effect was removed or the clip deleted while it was analyzed: the run ends (nothing would be written) and the
    /// status line clears.
    func endObsoleteStabilizeRun() {
        guard StabilizeRun.job.isRunning,
              session.stabilizeRunIsObsolete(clips: StabilizeRun.shown, watching: StabilizeRun.watched) else { return }
        StabilizeRun.silentEnd = true
        StabilizeRun.job.cancel()
    }

    /// A clip trimmed longer than its Stabilizer's analysis is analyzed again (after a pause, so a trim drag does not
    /// start a run per frame). Each clip and range is tried once automatically.
    func rerunStaleStabilizers() {
        endObsoleteStabilizeRun()
        StabilizeRun.autoTask?.cancel()
        let stale = session.staleStabilizerClips()
        guard !stale.isEmpty, !StabilizeRun.job.isRunning else { return }
        StabilizeRun.autoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !StabilizeRun.job.isRunning, !session.isPlaying else { return }
            let ids = session.staleStabilizerClips().filter { id in
                guard let c = session.activeTimeline?.tracks.flatMap(\.clips).first(where: { $0.id == id }) else { return false }
                return StabilizeRun.autoTried.insert("\(id)|\(c.source.start.value)/\(c.source.start.timescale)|\(c.source.duration.value)/\(c.source.duration.timescale)|\(c.speed)").inserted
            }
            guard !ids.isEmpty else { return }
            runStabilize(Set(ids), what: "the trimmed clip (longer than its analysis)")
        }
    }

    /// Stabilize as an effect: the Stabilizer's Analyze / Cancel row, dropping Stabilize from the Effects panel, and why
    /// Gyroflow cannot run on a clip.
    func wireStabilizeEffect() {
        let m = panels.effectModel
        m.onStabilizeAnalyze = { [weak self] id in self?.analyzeStabilizers([id]) }
        m.gyroflowStateOf = { [weak self] clip, options in
            guard let path = self?.session.project.media(clip.media)?.path else { return .idle }
            return StabilizeRun.gyroEngine.analysisState(path: path, options: options)
        }
        StabilizeRun.gyroEngine.addObserver { Task { @MainActor in m.gyroflowRevision &+= 1 } }
        m.onStabilizeCancel = { StabilizeRun.job.cancel() }
        m.onGyroflowCancel = { [weak self] clip, options in
            guard let path = self?.session.project.media(clip.media)?.path else { return }
            StabilizeRun.gyroEngine.cancel(path: path, options: options)
            self?.shell.statusBar.flash("Gyroflow analysis canceled.", seconds: 3)
        }
        m.stabilizeStaleOf = { [weak self] clip in self?.session.staleStabilizerClips().contains(clip.id) ?? false }
        m.gyroflowBlockOf = { [weak self] clip in self?.gyroflowBlock(clip) }
        session.onStabilizerNeedsAnalysis = { [weak self] tid, ids in self?.analyzeStabilizers(ids, in: tid) }
    }

    /// Why the Gyroflow method cannot stabilize this clip (nil = it can).
    func gyroflowBlock(_ clip: Clip) -> String? {
        guard let media = session.project.media(clip.media) else { return GyroStabilization.noGyroDataReason }
        let source: GyroDataSource?
        if let known = StabilizeRun.gyroSources[media.path] {
            source = known
        } else {
            source = GyroDataProbe.probe(URL(fileURLWithPath: media.path))
            StabilizeRun.gyroSources[media.path] = .some(source)
        }
        return GyroStabilization.block(source: source, engine: StabilizeRun.gyroEngine)
    }

    /// Analyzes these clips' Standard Stabilizers; Effect Controls shows the progress on their Analyze rows. Gyroflow
    /// Stabilizers start the engine's analysis (playback starts it too on the first frame drawn).
    func analyzeStabilizers(_ ids: Set<Clip.ID>, in timeline: Timeline.ID? = nil) {
        let tid = timeline ?? session.activeTimelineID
        let clips = tid.flatMap { session.project.timeline($0) }?.tracks.flatMap(\.clips).filter { ids.contains($0.id) } ?? []
        for c in clips {
            if let o = c.gyroflowOptions, let path = session.project.media(c.media)?.path {
                StabilizeRun.gyroEngine.prepare(path: path, options: o)
            }
        }
        let ids = ids.subtracting(clips.filter { $0.gyroflowOptions != nil }.map(\.id))
        guard !ids.isEmpty else { return }
        guard !StabilizeRun.job.isRunning else {
            session.queueStabilizerAnalysis(ids, in: tid)
            shell.statusBar.flash("Stabilize is analyzing another clip; this one follows when it ends.")
            return
        }
        StabilizeRun.autoTask?.cancel()
        let picked = clips.filter { ids.contains($0.id) }
        let what = picked.count == 1 ? "“\(picked[0].name)”" : "\(ids.count) clips"
        runStabilize(ids, in: tid, what: what)
    }

    func requestStabilize() {
        if StabilizeRun.job.isRunning {
            StabilizeRun.job.cancel()
            return
        }
        let targets = session.stabilizeTargets
        guard !targets.isEmpty else { shell.statusBar.flash("Select a video clip to stabilize."); return }
        let what = targets.count == 1 ? "“\(targets[0].name)”" : "\(targets.count) clips"
        guard GyroStabilization.offersGyroflow(blocks: targets.map { gyroflowBlock($0) }) else {
            runStabilize(nil, what: what)
            return
        }
        // The camera recorded motion data: offer the Gyroflow method instead of analyzing the picture.
        SQDialog.choice("Stabilize \(what)",
                        message: "This footage has gyro data. Gyroflow uses it for a steadier result than analyzing the picture.",
                        options: ["Use Gyroflow", "Analyze Picture"], in: window) { [weak self] pick in
            guard let self, let pick else { return }
            if pick == 0 { applyGyroflowStabilizer(to: Set(targets.map(\.id))) } else { runStabilize(nil, what: what) }
        }
    }

    /// Adds Stabilizers set to the Gyroflow method (one undo step per change like the Effect Controls) and prepares them.
    private func applyGyroflowStabilizer(to ids: Set<Clip.ID>) {
        let ask = session.onStabilizerNeedsAnalysis
        session.onStabilizerNeedsAnalysis = nil      // the new Standard Stabilizer must not start a picture analysis
        defer { session.onStabilizerNeedsAnalysis = ask }
        guard session.addStabilizer(to: ids) else { shell.statusBar.flash("These clips cannot be stabilized."); return }
        let live = session.activeTimeline?.tracks.flatMap(\.clips) ?? []
        for id in ids {
            guard let clip = live.first(where: { $0.id == id }), let eid = clip.stabilizerID else { continue }
            var g = clip
            g.setParameter(eid, ClipEffect.stabilizeMethodKey, to: Double(StabilizerMethod.gyroflow.rawValue))
            session.replaceDisplayedClip(g, name: "Method", continuesGesture: false)
        }
        analyzeStabilizers(ids)
    }
}

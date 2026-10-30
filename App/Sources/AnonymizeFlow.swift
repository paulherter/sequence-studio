import Foundation
import SQAnalysis
import SQCore
import SQEditorSession
import SQEditorUI

/// What a finished Anonymize analysis hands back to the main actor.
struct AnonymizeRunResult: Sendable {
    var checks: [AnonymizeCheck]
    var frames: Int
    /// The run's mattes, under staged keys until the masks are written.
    var staged: [Anonymizer.Staged]
}

/// The running Anonymize analysis (extensions cannot add stored properties to AppController).
@MainActor enum AnonymizeRun {
    static let job = AnalysisJob<AnonymizeRunResult>()
    static let source = AnonymizeJobSource { cancel() }
    /// The search for people on the playhead's frame, before the sheet.
    static var finding: Task<Void, Never>?
    /// The flow of the latest run (its tasks hold it weakly).
    static var flow: AnonymizeFlow?
    /// The analysis off the main actor has not ended yet (a canceled run takes a moment to stop; no second run before).
    static var working = false

    static var isRunning: Bool { job.isRunning || finding != nil || working }
    static func cancel() {
        finding?.cancel()
        job.cancel()
    }
}

/// What the Anonymize flow needs from the window it runs in: the AppKit app (`AppController.requestAnonymize`) and the shared
/// shell (`SharedUIController.requestAnonymize`) each bring their status line and dialogs.
struct AnonymizeUI {
    var setJob: @MainActor (String?) -> Void
    var flashLine: @MainActor (String, Double) -> Void
    var warn: @MainActor (String, String) -> Void
    var info: @MainActor (String, String) -> Void
    /// Clip name and the people found; the answer is nil when canceled.
    var ask: @MainActor (String, [AnonymizePerson], @escaping @MainActor (AnonymizeChoice?) -> Void) -> Void
    /// The frames to check after a run; the closure is called with the time "Go to First" jumps to.
    var checks: @MainActor ([AnonymizeCheckLine], @escaping @MainActor (Time) -> Void) -> Void

    @MainActor func flash(_ text: String, seconds: Double = 4) { flashLine(text, seconds) }
}

/// Clip > Video Options > Anonymize: finds the people on the playhead's frame of one clip, asks what to cover (Face, Whole
/// Person, Skin) with what (Mosaic, Blur), follows each chosen person with the Magic mask tracker and writes the masks and
/// the cover as one undo step. Running it again while it analyzes cancels it ("Cancel Anonymize"); nothing is written then.
/// A run stores its mattes under staged keys and they are taken over only once the masks are written, so a canceled,
/// failed or refused run never touches a cover that is already on the clip.
@MainActor
final class AnonymizeFlow {
    let session: EditorSession
    let ui: AnonymizeUI

    private init(session: EditorSession, ui: AnonymizeUI) { self.session = session; self.ui = ui }

    /// The command: starts a run, or cancels the running one. The flow stays alive in `AnonymizeRun.flow` until the next one.
    static func request(session: EditorSession, ui: AnonymizeUI) {
        if AnonymizeRun.isRunning { AnonymizeRun.cancel(); return }
        let flow = AnonymizeFlow(session: session, ui: ui)
        AnonymizeRun.flow = flow
        flow.requestAnonymize()
    }

    private func requestAnonymize() {
        if AnonymizeRun.isRunning { AnonymizeRun.cancel(); return }
        guard let request = session.anonymizeRequest() else {
            ui.flash("Select a video clip from a file to anonymize.")
            return
        }
        session.stopPlayback()
        let bar = ui
        let others = session.reframeTargets.map(\.id).filter { $0 != request.clip }
        let anonymizer = Self.anonymizer(for: request, in: session)
        bar.setJob("Anonymize: looking for people in “\(request.clipName)”…")
        AnonymizeRun.source.run = (request.clipName, nil)
        AnonymizeRun.finding = Task { @MainActor [self] in
            var found: [AnonymizeSighting]?
            var stalled = false
            do {
                found = try await anonymizer.findEveryone(first: request.first, last: request.last, anchor: request.anchor)
            } catch is BlockingLane.Stalled { stalled = true } catch {}
            let canceled = Task.isCancelled
            AnonymizeRun.finding = nil
            AnonymizeRun.source.run = nil
            bar.setJob(nil)
            guard !canceled else { bar.flash("Anonymize canceled.", seconds: 3); return }
            guard !stalled else {
                ui.warn("Anonymize stopped answering", "Reading “\(request.clipName)” hung at this frame, so the search was given up. Try again, or move the playhead to another frame of the clip.")
                return
            }
            guard let found else {
                ui.warn("Anonymize could not read this frame", "The file of “\(request.clipName)” could not be read here.")
                return
            }
            guard !found.isEmpty else {
                ui.info("No person found in this clip", "No person showed up on the frames Anonymize looked at. Move the playhead to a frame that shows the person clearly, then run it again. You can also pick them by hand with the Mask tool (Magic) and limit a Mosaic to that mask.")
                return
            }
            let keep = session.selection
            ui.ask(request.clipName, found.map(\.person)) { [self] choice in
                guard let choice else { return }
                let chosen = choice.people.map { found[$0] }
                if others.isEmpty {
                    runAnonymize(anonymizer, request: request, sightings: chosen, choice: choice)
                } else {
                    // Several clips: the picked people are for this clip; the others get everyone found in them.
                    runAnonymize(anonymizer, request: request, sightings: chosen, choice: choice, quiet: true) { [self] in
                        anonymizeQueued(others, choice: choice, restore: keep, done: 1)
                    }
                }
            }
        }
    }

    private static func anonymizer(for request: AnonymizeRequest, in session: EditorSession) -> Anonymizer {
        // The frames the monitor shows: the media item's pixel shape and Deinterlace switch.
        let video = session.project.media.first { $0.id == request.media }?.info?.video
        return Anonymizer(url: URL(fileURLWithPath: request.path), pixelAspect: video?.displayPixelAspect ?? .square,
                          deinterlace: video?.deinterlaceFieldOrder)
    }

    /// The rest of a multi-clip run: each clip is selected in turn (the request is built from the selection), searched and
    /// covered with the same target and cover, everyone found. The selection is restored at the end.
    private func anonymizeQueued(_ ids: [Clip.ID], choice: AnonymizeChoice, restore: Set<Clip.ID>, done: Int) {
        guard let id = ids.first else {
            session.select(clips: restore)
            ui.flash("Anonymize applied to \(done) clips. Check each clip before you export.", seconds: 6)
            return
        }
        let rest = Array(ids.dropFirst())
        session.select(clips: [id])
        guard let request = session.anonymizeRequest() else {
            anonymizeQueued(rest, choice: choice, restore: restore, done: done)
            return
        }
        let bar = ui
        let anonymizer = Self.anonymizer(for: request, in: session)
        bar.setJob("Anonymize: looking for people in “\(request.clipName)”…")
        AnonymizeRun.source.run = (request.clipName, nil)
        AnonymizeRun.finding = Task { @MainActor [self] in
            let found = (try? await anonymizer.findEveryone(first: request.first, last: request.last, anchor: request.anchor)) ?? nil
            let canceled = Task.isCancelled
            AnonymizeRun.finding = nil
            AnonymizeRun.source.run = nil
            bar.setJob(nil)
            guard !canceled else {
                session.select(clips: restore)
                bar.flash("Anonymize canceled.", seconds: 3)
                return
            }
            guard let found, !found.isEmpty else {
                anonymizeQueued(rest, choice: choice, restore: restore, done: done)
                return
            }
            runAnonymize(anonymizer, request: request, sightings: found, choice: choice, quiet: true) { [self] in
                anonymizeQueued(rest, choice: choice, restore: restore, done: done + 1)
            }
        }
    }

    /// `quiet`: part of a multi-clip run (no check list sheet; `then` starts the next clip when this one was written).
    private func runAnonymize(_ anonymizer: Anonymizer, request: AnonymizeRequest, sightings: [AnonymizeSighting], choice: AnonymizeChoice,
                              quiet: Bool = false, then: (@MainActor () -> Void)? = nil) {
        guard !AnonymizeRun.isRunning else { return }
        let people = sightings.map(\.person)
        let picks = sightings.map { Anonymizer.selection($0.person, pts: $0.pts, target: choice.target) }
        // The widest covered subject in px of the clip's frame sets the block size / blur amount.
        let widest = people.map { p in choice.target == .face ? (p.face?.box.width ?? p.box.width * 0.4) : p.box.width }.max() ?? 0.2
        let subjectWidth = widest * Double(request.pictureWidth)
        let store = MagicMatteStore.shared
        let bar = ui
        let what = "Anonymize: following \(people.count == 1 ? "1 person" : "\(people.count) people") in “\(request.clipName)”…"
        bar.setJob(what)
        AnonymizeRun.source.run = (request.clipName, 0)
        AnonymizeRun.job.start({ progress in
            // Off the main actor: the tracker reads and segments every frame. Canceling the job cancels this work, and the
            // run counts as running until the work has really ended.
            AnonymizeRun.working = true
            let work = Task.detached(priority: .userInitiated) {
                let out = try await anonymizer.run(picks, media: request.media, first: request.first, last: request.last,
                                                   frameGap: request.frameGap, store: store, progress: progress)
                return AnonymizeRunResult(checks: out.checks, frames: out.frames, staged: out.staged)
            }
            let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
            AnonymizeRun.working = false
            if Task.isCancelled {
                // Finished just as it was canceled: nobody takes the result over.
                if case .success(let out) = result { Anonymizer.discard(out.staged, store: store) }
                throw CancellationError()
            }
            return try result.get()
        }, progress: { p in
            AnonymizeRun.source.run = (request.clipName, p)
            bar.setJob("\(what) \(Int((p * 100).rounded())) %")
        }, ended: { [self] ending in
            bar.setJob(nil)
            AnonymizeRun.source.run = nil
            switch ending {
            case .cancelled:
                bar.flash("Anonymize canceled. Nothing was changed.", seconds: 4)
            case .failed(let why):
                bar.flash(SQL10n.format("Anonymize failed: %@", why), seconds: 8)
            case .done(let out):
                guard out.frames > 0 else {
                    Anonymizer.discard(out.staged, store: store)
                    bar.flash("Anonymize found nothing to follow. Nothing was changed.", seconds: 6)
                    return
                }
                let result = session.applyAnonymize(picks, target: choice.target, cover: choice.cover, subjectWidth: subjectWidth, request: request)
                guard result.applied else {
                    Anonymizer.discard(out.staged, store: store)
                    if result == .clipRetimed {
                        ui.warn("Anonymize was not applied", result.message)
                    } else {
                        bar.flash(result.message, seconds: 6)
                    }
                    return
                }
                // The masks are in the clip: now their mattes replace the staged ones.
                Anonymizer.commit(out.staged, store: store)
                session.engine.redraw()
                let lines = session.anonymizeCheckLines(out.checks, request: request)
                if let then {
                    then()
                } else if lines.isEmpty {
                    bar.flash("Anonymize applied. Check the whole clip before you export.", seconds: 6)
                } else {
                    ui.checks(lines) { [session] t in session.seek(to: t) }
                }
            }
        })
    }
}

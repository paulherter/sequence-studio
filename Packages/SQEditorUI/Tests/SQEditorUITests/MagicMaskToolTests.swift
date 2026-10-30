import AppKit
import Foundation
import SQAnalysis
import SQCore
import SQMedia
import Synchronization
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

// The Mask tool's Magic mode end to end without Vision: session, Effect Controls, overlay and `MagicMaskTool` wired like
// the app does it. The maintainer's report (2026-10-09): pick once, remove the mask, and Magic was dead for the rest of the run.

/// Set once a status line was shown: lets a test segmenter (off the main actor) wait for a condition instead of time.
private final class StatusFlag: Sendable {
    private let flag = Mutex(false)
    var isSet: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

@MainActor private final class Rig {
    let statusShown: StatusFlag
    let session: EditorSession
    let model = EffectControlsModel()
    let overlay = TransformOverlayView()
    let store = MagicMatteStore(directory: nil)
    let activity = MaskTrackActivity()
    let tool: MagicMaskTool
    let a: Clip.ID, b: Clip.ID
    var status: [String] = []
    var watch = MagicPickWatch()
    /// What the watch asked to follow again, in order.
    var restarts: [MagicPickWatch.Restart] = []
    /// Start a run for what the watch asks, like the app.
    var followsReturnedPicks = false
    /// The app's `surface.tool.maskModeValue == .magic`.
    var toolIsMagic = true

    /// `segment` nil = one object on the left third of every frame.
    init(retryDelay: Double = 1, timeout: Double = WorkLimits.subjectFrameDeadline, statusShown: StatusFlag = StatusFlag(),
         segment: MagicMaskSession.Segment? = nil) {
        self.statusShown = statusShown
        let fd = Time(1, 25)
        func media(_ n: String) -> MediaRef {
            let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                   nominalFrameDuration: fd, isVariableFrameRate: false)
            return MediaRef(name: n, path: "/nonexistent/\(n).mov", fingerprint: MediaFingerprint(size: 1),
                            duration: Time(10, 1), info: MediaInfo(duration: Time(10, 1), video: v, audio: nil))
        }
        let ma = media("A"), mb = media("B")
        let ca = Clip(name: "a", media: ma.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let cb = Clip(name: "b", media: mb.id, kind: .video, source: TimeRange(start: Time(2, 1), duration: Time(4, 1)), start: Time(4, 1))
        var v1 = Track(kind: .video)
        try! v1.overwrite(ca); try! v1.overwrite(cb)
        let tl = Timeline(name: "Main", frameDuration: fd, tracks: [v1])
        session = EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
        session.perform("Import") { $0.add(ma); $0.add(mb) }
        a = ca.id; b = cb.id
        tool = MagicMaskTool(model: model, overlay: overlay, session: MagicMaskSession(timeout: timeout, retryDelay: retryDelay, segment: segment ?? { _, s in (Rig.frame, s) }),
                             store: store)
        overlay.maskTool = .magic
        model.frameDuration = fd
        // The app's wiring (EditorPanels): edits go to the session, every session change syncs Effect Controls and the tool.
        model.onEdit = { [weak self] c, n, co in self?.session.replaceDisplayedClip(c, name: n, continuesGesture: co) }
        tool.targetClip = { [weak self] in
            guard let self, !session.isPlaying, let tl = session.displayTimeline, let c = session.displayedSelectedClip else { return nil }
            return OverlayTarget.make(clip: c, project: session.project, timeline: tl, at: session.playhead)?.clip
        }
        tool.mediaURL = { [weak self] id in self?.session.project.media(id).map { URL(fileURLWithPath: $0.path) } }
        tool.isPlaying = { [weak self] in self?.session.isPlaying ?? false }
        tool.onStatus = { [weak self] s in self?.status.append(s); self?.statusShown.set() }
        tool.onMaskChanged = { [weak self] in self?.tool.refresh() }
        session.onChange = { [weak self] change in
            guard let self else { return }
            model.sync(with: session, change: change)
            if change.contains(.project) {
                let project = session.project
                // The app's `stopTrackOfRemovedMask` and `stopTrackOfChangedPick`: a Magic track the project cut off is noted.
                let running = activity.runKey
                let automatic = activity.run?.automatic == true
                let gone = activity.stopIfMaskGone(owner: session) { MagicPickWatch.mask($1, clip: $0, in: project) != nil }
                let changed = activity.stopIfKeyChanged(owner: session) { MagicPickWatch.key($1, clip: $0, in: project) } != nil
                if gone || changed, let running { watch.cutOff(running, automatic: automatic) }
                // The app's `followReturnedPick`: a pick that came back incomplete is followed again.
                let again = watch.look(at: project, userStop: activity.userStop, stopped: activity.userStopMask, stoppedClip: activity.userStopClip,
                                   canReturn: session.canUndo || session.canRedo, times: { [store] in store.times(key: $0) }) { [activity, session] ref, key in
                    activity.isFollowing(clip: ref.clip, mask: ref.mask, key: key, owner: session)
                }
                restarts += again
                follow()
            }
            tool.refresh()
        }
        session.onChange?([.project, .selection, .playhead])
    }

    nonisolated static let frame: InstanceFrame = {
        var l = [UInt8](repeating: 0, count: 20 * 10)
        for y in 2..<8 { for x in 2..<8 { l[y * 20 + x] = 1 } }
        return InstanceFrame(labels: InstanceLabels(width: 20, height: 10, labels: l))
    }()

    static let object = Vec2(0.25, 0.5)

    func masks(_ id: Clip.ID) -> [ClipMask] {
        session.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }?.masks ?? []
    }

    /// Selects `clip`, parks on `seconds` and waits for the frame's segmentation.
    func park(on clip: Clip.ID, at seconds: Int64) async {
        session.select(clips: [clip])
        session.seek(to: Time(seconds, 1))
        if let s = tool.source { await tool.session.prepare(media: s.media, url: s.url, sourceTime: s.sourceTime) }
    }

    var selection: [Clip.ID] { session.selectedEditClips.map(\.id) }

    /// The pointer rests on the object of `clip` under the playhead while the selection gives Magic nothing to work on:
    /// what the app does on every pointer move there (`EditorPanels.previewMagic`). The pointer keeps moving until the
    /// preview shows (at most 2 s).
    func hoverUnselected(_ clip: Clip.ID) async {
        for _ in 0..<400 {
            guard let tl = session.displayTimeline, let c = tl.tracks.flatMap(\.clips).first(where: { $0.id == clip }),
                  let target = OverlayTarget.make(clip: c, project: session.project, timeline: tl, at: session.playhead) else { return }
            tool.preview(c, localPlayhead: session.playhead - c.start,
                         layer: .init(transform: target.displayTransform, mediaPixelSize: target.size), at: Rig.object)
            if overlay.magicPreview != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The second half of the app's `followReturnedPick`, also called when a run ends and when the Magic tool is
    /// chosen: the pick that waits longest gets the slot when it is free and the Magic tool is active.
    func follow(toolChosen: Bool = false) {
        guard followsReturnedPicks else { return }
        let project = session.project
        _ = watch.look(at: project, userStop: activity.userStop, stopped: activity.userStopMask, stoppedClip: activity.userStopClip,
                                   canReturn: session.canUndo || session.canRedo, times: { [store] in store.times(key: $0) }) { [activity, session] ref, key in
            activity.isFollowing(clip: ref.clip, mask: ref.mask, key: key, owner: session)
        }
        guard let first = watch.next(slotFree: !activity.isRunning, toolIsMagic: toolIsMagic, toolChosen: toolChosen) else { return }
        _ = startTrack(first.ref.mask, key: first.key, clip: first.ref.clip)
    }

    /// A track of `mask` that runs until it is stopped. `automatic` nil: the pick's own track when it has a `key`;
    /// false with a key: a Magic track started with a track button. Like the app's `runMagicTrack`, any run for a
    /// key tells the watch.
    @discardableResult
    func startTrack(_ mask: ClipMask.ID, key: String? = nil, clip: Clip.ID? = nil, automatic: Bool? = nil,
                    save: (@MainActor () -> Void)? = nil) -> Task<Void, Never> {
        let token = activity.start(mask: mask, forward: true, owner: session, automatic: automatic ?? (key != nil), key: key, clip: clip, save: save)
        if let key { watch.started(key, mask: mask, clip: clip) }
        let task = Task { @MainActor [activity, weak self] in
            defer { activity.finish(token); self?.follow() }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
        }
        activity.attach(task, to: token)
        return task
    }

    /// The maintainer's sequence on one clip: hover it (not selected), click (selects and picks), start Track, remove the mask
    /// while the track runs.
    func hoverPickTrackRemove(_ clip: Clip.ID, at seconds: Int64, _ note: Comment) async {
        session.seek(to: Time(seconds, 1))
        let before = selection
        #expect(tool.source == nil, note)
        await hoverUnselected(clip)
        #expect(overlay.magicPreview != nil && overlay.magicPreviewLayer != nil, note)
        #expect(selection == before, note)
        // The press: the monitor selects the clip under the pointer, then Magic picks with the same press.
        session.select(clips: [clip])
        #expect(overlay.magicPreview == nil && tool.previewSource == nil, note)
        tool.pointer(Rig.object)
        #expect(overlay.magicHover != nil, note)
        await tool.click(Rig.object, subtract: false, newMask: false)
        let made = masks(clip)
        #expect(made.count == 1 && made.first?.source == .magic, note)
        #expect(overlay.magicPick != nil, note)
        guard let id = made.first?.id else { return }
        let track = startTrack(id)
        #expect(activity.run?.mask == id, note)
        model.removeMask(id)
        #expect(masks(clip).isEmpty, note)
        // The slot is free at once (nothing waits for the task), and the task is told to stop.
        #expect(activity.run == nil && track.isCancelled, note)
        await track.value
        #expect(activity.run == nil, note)
    }

    /// Hover shows the object, a click makes one Magic mask with a stored matte, removing it leaves the clip clean.
    func pickAndRemove(_ clip: Clip.ID, at seconds: Int64, _ note: Comment) async {
        await park(on: clip, at: seconds)
        #expect(tool.refusal == nil, note)
        tool.pointer(Rig.object)
        #expect(overlay.magicHover != nil, note)
        await tool.click(Rig.object, subtract: false, newMask: false)
        let made = masks(clip)
        #expect(made.count == 1 && made.first?.source == .magic, note)
        #expect(overlay.magicPick != nil, note)
        guard let id = made.first?.id else { return }
        model.removeMask(id)
        #expect(masks(clip).isEmpty, note)
        #expect(overlay.magicPick == nil, note)
    }
}

@MainActor @Suite struct MagicMaskToolTests {
    /// Add, pick, remove, add again on a second clip, twice in a row.
    @Test func pickRemoveAndPickAgainOnASecondClipTwiceInARow() async {
        let r = Rig()
        for round in 1...2 {
            await r.pickAndRemove(r.a, at: 1, "round \(round), clip A")
            await r.pickAndRemove(r.b, at: 5, "round \(round), clip B")
        }
    }

    /// A pick stores its matte on its own frame only and starts no tracking; a click that picked nothing stores nothing.
    @Test func aStoredPickIsOneFrameAndStartsNothing() async throws {
        let r = Rig()
        await r.park(on: r.a, at: 1)
        await r.tool.click(Vec2(0.9, 0.9), subtract: false, newMask: false)
        #expect(r.masks(r.a).isEmpty)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        let id = try #require(r.masks(r.a).first?.id)
        #expect(r.store.times(key: try #require(r.model.magicCacheKey(id))) == [1])
        #expect(r.activity.run == nil)
    }

    /// A run follows the pick its mask had when it started. A second click, and undo of it, change the pick under the
    /// run: each time the run is stopped (whether the new pick stores a matte or not) and its frames are saved under
    /// its own key; after the undo the first pick is the mask's again and its matte is still there to follow from.
    @Test func aRunIsStoppedWhenItsMasksPickChangesByAClickOrUndo() async throws {
        let r = Rig()
        await r.park(on: r.a, at: 1)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        let id = try #require(r.masks(r.a).first?.id)
        let first = try #require(r.model.magicCacheKey(id))
        var saved: [String] = []
        let t1 = r.startTrack(id, key: first) { saved.append("first") }
        // A click that takes everything out of the pick stores nothing: the old run is stopped all the same.
        await r.tool.click(Rig.object, subtract: true, newMask: false)
        let second = try #require(r.model.magicCacheKey(id))
        #expect(second != first && r.activity.run == nil && t1.isCancelled && saved == ["first"])
        await t1.value
        let t2 = r.startTrack(id, key: second) { saved.append("second") }
        #expect(r.session.undo())
        #expect(r.model.magicCacheKey(id) == first && r.activity.run == nil && t2.isCancelled)
        #expect(saved == ["first", "second"])
        await t2.value
        #expect(!r.store.times(key: first).isEmpty)
        // Redo while a run follows the first pick again: stopped once more.
        let t3 = r.startTrack(id, key: first) { saved.append("first") }
        #expect(r.session.redo())
        #expect(r.activity.run == nil && t3.isCancelled && saved == ["first", "second", "first"])
        await t3.value
    }

    /// The maintainer's exact sequence (2026-10-09), twice: hover A, pick, Track, remove the mask while the track runs, hover B
    /// (A is still selected), pick, Track, remove. Every hover shows a preview and never changes the selection.
    @Test func hoverPickTrackRemoveOnTwoClipsTwiceInARow() async {
        let r = Rig()
        for round in 1...2 {
            await r.hoverPickTrackRemove(r.a, at: 1, "round \(round), clip A")
            await r.hoverPickTrackRemove(r.b, at: 5, "round \(round), clip B")
        }
        #expect(r.status.count == 4 && r.status.allSatisfy { $0.hasPrefix("Picked") })
    }

    /// The same with a segmenter whose very first call throws: the tool says why once and works from the next pointer move.
    @Test func theSameSequenceWhenTheFirstSegmentCallThrows() async {
        let runs = Mutex(0)
        let told = StatusFlag()
        // With retryDelay 0 the next pointer move can start the second request before the first failure's status line is
        // shown (the line needs a main-actor hop that load delays): the frame is then ready, the problem gone, nothing
        // is said. So the second call waits until a line was shown (a condition, not a time; the bound only keeps a
        // broken tool from hanging the test).
        let r = Rig(retryDelay: 0, statusShown: told) { _, s in
            if runs.withLock({ $0 += 1; return $0 }) == 1 { throw NSError(domain: "sq.test", code: 3) }
            for _ in 0..<2000 where !told.isSet { try? await Task.sleep(for: .milliseconds(10)) }
            return (Rig.frame, s)
        }
        for round in 1...2 {
            await r.hoverPickTrackRemove(r.a, at: 1, "round \(round), clip A")
            await r.hoverPickTrackRemove(r.b, at: 5, "round \(round), clip B")
        }
        #expect(r.status.filter { $0.contains("could not read this frame") && $0.contains("sq.test") }.count == 1)
    }

    /// Hover on an unselected clip only previews: no selection, no mask, and the preview goes when the pointer leaves.
    @Test func hoverPreviewsWithoutSelecting() async {
        let r = Rig()
        r.session.seek(to: Time(1, 1))
        await r.hoverUnselected(r.a)
        #expect(r.overlay.magicPreview != nil && r.selection.isEmpty && r.masks(r.a).isEmpty)
        #expect(r.overlay.magicHover == nil)
        r.tool.preview(nil)
        #expect(r.overlay.magicPreview == nil && r.overlay.magicPreviewLayer == nil && r.tool.previewSource == nil)
        // Beside every object: the clip is still the preview's target, nothing is highlighted.
        await r.hoverUnselected(r.a)
        let c = r.session.displayTimeline!.tracks.flatMap(\.clips).first { $0.id == r.a }!
        r.tool.preview(c, localPlayhead: Time(1, 1), layer: r.overlay.magicPreviewLayer, at: Vec2(0.9, 0.9))
        #expect(r.overlay.magicPreview == nil && r.tool.previewSource != nil)
    }

    /// Use, remove the mask, use again on the same clip and frame.
    @Test func pickRemoveAndPickAgainOnTheSameFrame() async {
        let r = Rig()
        for round in 1...3 { await r.pickAndRemove(r.a, at: 1, "round \(round)") }
    }

    /// Clip A, then clip B without removing anything: each clip gets its own mask, and going back shows A's pick.
    @Test func clipAThenClipB() async {
        let r = Rig()
        await r.park(on: r.a, at: 1)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        await r.park(on: r.b, at: 5)
        #expect(r.overlay.magicPick == nil)
        r.tool.pointer(Rig.object)
        #expect(r.overlay.magicHover != nil)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        #expect(r.masks(r.a).count == 1 && r.masks(r.b).count == 1)
        await r.park(on: r.a, at: 1)
        #expect(r.overlay.magicPick != nil)
    }

    /// The overlay drops its highlight when the tool is switched by key with the pointer resting on the object; back in
    /// Magic the same object (every frame numbers its main object 1) must light up again.
    @Test func hoverComesBackAfterTheOverlayDroppedIt() async {
        let r = Rig()
        await r.park(on: r.a, at: 1)
        r.tool.pointer(Rig.object)
        #expect(r.overlay.magicHover != nil)
        r.overlay.maskTool = nil          // V
        #expect(r.overlay.magicHover == nil)
        r.overlay.maskTool = .magic       // P
        r.tool.pointer(Rig.object)
        #expect(r.overlay.magicHover != nil)
    }

    /// The highlight belongs to its frame: on the next clip the same label is another object and is drawn anew.
    @Test func hoverIsRebuiltForAnotherClip() async {
        let r = Rig()
        await r.park(on: r.a, at: 1)
        r.tool.pointer(Rig.object)
        let first = r.overlay.magicHover
        await r.park(on: r.b, at: 5)
        r.tool.pointer(Rig.object)
        #expect(r.overlay.magicHover != nil && r.overlay.magicHover !== first)
    }

    /// One failed read of a frame (file busy, segmenter hiccup) must not switch Magic off there: a click tries again.
    @Test func aClickRetriesAFrameThatGaveNothing() async {
        let runs = Mutex(0)
        // No timed retry: only the click tries the frame again (the retry raced the first hover on a busy machine).
        let r = Rig(retryDelay: 3600, segment: { _, s in
            guard s == 1 else { return (Rig.frame, s) }
            let n = runs.withLock { $0 += 1; return $0 }
            if n == 1 { throw CancellationError() }       // the first read of this frame fails
            return (Rig.frame, s)
        })
        await r.park(on: r.a, at: 1)
        r.tool.pointer(Rig.object)
        #expect(r.overlay.magicHover == nil)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        #expect(r.masks(r.a).count == 1)
        r.tool.pointer(Rig.object)
        #expect(r.overlay.magicHover != nil)
    }

    /// Without a usable clip the tool says why (and logs it) instead of doing nothing.
    @Test func noTargetIsReportedNotSilent() async {
        let r = Rig()
        r.session.select(clips: [])
        r.session.seek(to: Time(1, 1))
        #expect(r.tool.source == nil && r.tool.refusal != nil)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        #expect(r.status.count == 1)
        // Selected clip not under the playhead: no target either.
        r.session.select(clips: [r.a])
        r.session.seek(to: Time(5, 1))
        #expect(r.tool.source == nil)
        // The overlay then lets presses through to the monitor, which selects the clip under the pointer.
        #expect(!r.overlay.magicUsable)
        r.session.select(clips: [r.b])
        #expect(r.overlay.magicUsable && r.tool.source != nil)
    }

    /// A pick whose matte never came (Vision hangs) leaves a mask with one point and no matte. The next click makes
    /// that matte; it does not add a second point (before: every retry click grew the pick).
    @Test func aClickAfterAPickThatGaveUpMakesItsMatteInsteadOfASecondPoint() async throws {
        let hang = Mutex(true)
        let release = DispatchSemaphore(value: 0)
        let base = Rig.frame.labels
        let frame = InstanceFrame(labels: base) { set in
            if hang.withLock({ $0 }) { release.wait() }
            return base.matte(of: set)
        }
        let r = Rig(timeout: 0.05, segment: { _, s in (frame, s) })
        await r.park(on: r.a, at: 1)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        let first = try #require(r.masks(r.a).first)
        let key = try #require(r.model.magicCacheKey(first.id))
        #expect(r.masks(r.a).count == 1 && first.magic?.points.count == 1)
        #expect(r.status.last?.contains("gave up") == true && r.store.times(key: key).isEmpty)
        hang.withLock { $0 = false }
        for _ in 0..<4 { release.signal() }
        await r.tool.click(Vec2(0.3, 0.55), subtract: false, newMask: false)
        #expect(r.masks(r.a).count == 1 && r.masks(r.a).first?.magic?.points.count == 1)
        #expect(r.status.last?.hasPrefix("Picked") == true && r.store.times(key: key).count == 1)
        // The pick has its matte: the next click adds to it as always.
        await r.tool.click(Vec2(0.3, 0.55), subtract: false, newMask: false)
        #expect(r.masks(r.a).first?.magic?.points.count == 2)
    }
}

/// The "Preparing…" / "Tracking…" line of a run that is stopped without a word is cleared, and only that line
/// (before: it stood there after the tool was switched, the mask removed or the pick changed).
@Suite struct TrackStatusLineTests {
    @Test func aSilentlyStoppedRunTakesItsGoingOnLineWithIt() {
        var line = TrackStatusLine()
        line.wrote(); line.goesOn(1)
        let clears = line.ended(1)
        // Cleared once.
        let again = line.ended(1)
        #expect(clears && !again)
    }

    @Test func aLineWrittenSinceStays() {
        var line = TrackStatusLine()
        // The run's own last word (tracked, stopped by the user, failed).
        line.wrote(); line.goesOn(1)
        line.wrote()
        let afterItsLastWord = line.ended(1)
        #expect(!afterItsLastWord)
        // Another run took the slot and wrote its line before the stopped one ended: it stays, and is the new run's.
        line.wrote(); line.goesOn(2)
        line.wrote(); line.goesOn(3)
        let older = line.ended(2), newer = line.ended(3)
        #expect(!older && newer)
        // A run that never wrote clears nothing.
        let silent = line.ended(4)
        #expect(!silent)
    }

    /// The path mask track writes "Tracking mask…" and a line per percent: each is the run's, so the run stopped
    /// without a word after any of them clears it, and its own last word ("Tracked the mask over n frames.") stays.
    @Test func everyProgressLineKeepsTheRunTheOwnerUntilItsLastWord() {
        var line = TrackStatusLine()
        line.wrote(); line.goesOn(7)
        line.wrote(); line.goesOn(7)
        var stopped = line
        let clears = stopped.ended(7)
        #expect(clears)
        line.wrote()
        let afterItsResult = line.ended(7)
        #expect(!afterItsResult)
    }
}

/// A pick that comes back is followed again because of what the project and the store hold, whether or not a run
/// was just stopped (`MagicPickWatch`; before, 2026-10-09: only while another run was still live).
@MainActor @Suite struct MagicPickWatchTests {
    static let matte = SubjectMatte(width: 1, height: 1, values: [1])

    /// Clip A with one pick at 1 s (its matte stored, nothing tracked): the rig, the mask and the pick's key.
    private func picked() async throws -> (Rig, ClipMask.ID, String) {
        let r = Rig()
        await r.park(on: r.a, at: 1)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        let id = try #require(r.masks(r.a).first?.id)
        let key = try #require(r.model.magicCacheKey(id))
        #expect(r.store.times(key: key) == [1])
        return (r, id, key)
    }

    @Test func aFreshClickIsNotFollowedByTheWatch() async throws {
        // Its matte is stored after the project changed: the watch does not follow it.
        let (r, _, _) = try await picked()
        #expect(r.restarts.isEmpty)
    }

    @Test func undoThenRedoOfAPickFollowsItAgainWithNoRunLive() async throws {
        let (r, id, key) = try await picked()
        #expect(r.session.undo())
        #expect(r.restarts.isEmpty && r.activity.run == nil)
        #expect(r.session.redo())
        // Clip A shows source 0 ... 4 s at 25 fps: from the pick's frame to both edges.
        let want = MagicPickWatch.Restart(ref: .init(clip: r.a, mask: id), key: key, legs: [
            .init(from: 1, to: 3.96, forward: true), .init(from: 1, to: 0, forward: false),
        ])
        #expect(r.restarts == [want])
        // Looking again at the same project asks for nothing more.
        r.session.onChange?([.project])
        r.session.onChange?([.project])
        #expect(r.restarts == [want])
    }

    @Test func thePickFollowedAgainGetsOneRunHoweverOftenTheProjectIsLookedAt() async throws {
        let (r, id, key) = try await picked()
        r.followsReturnedPicks = true
        #expect(r.session.undo() && r.activity.run == nil)
        #expect(r.session.redo())
        #expect(r.activity.run?.mask == id && r.activity.run?.clip == r.a)
        #expect(r.activity.isFollowing(clip: r.a, mask: id, key: key, owner: r.session))
        r.session.onChange?([.project])
        // Another edit elsewhere in the project: the run goes on, no second one is asked for.
        r.session.perform("Rename") { $0.name = "Q" }
        #expect(r.restarts.count == 1 && r.activity.isFollowing(clip: r.a, mask: id, key: key, owner: r.session))
        r.activity.stop(reason: "test ends")
    }

    /// K1 was stopped by a second click (K2), K2's run ended, then undo: K1 is the pick again with one frame and no
    /// run anywhere.
    @Test func anOlderPickThatReturnsAfterTheNewerOnesRunEndedIsFollowed() async throws {
        let (r, id, k1) = try await picked()
        let t1 = r.startTrack(id, key: k1, clip: r.a)
        await r.tool.click(Rig.object, subtract: true, newMask: false)
        let k2 = try #require(r.model.magicCacheKey(id))
        #expect(k2 != k1 && t1.isCancelled && r.restarts.isEmpty)
        await t1.value
        let t2 = r.startTrack(id, key: k2, clip: r.a)
        t2.cancel()
        await t2.value
        #expect(r.activity.run == nil)
        #expect(r.session.undo())
        #expect(r.model.magicCacheKey(id) == k1 && r.restarts.map(\.key) == [k1] && r.restarts.first?.legs.count == 2)
    }

    @Test func aPickFollowedToBothEdgesIsLeftAlone() async throws {
        let (r, _, key) = try await picked()
        r.store.put(Self.matte, key: key, pts: 0)
        r.store.put(Self.matte, key: key, pts: 3.96)
        #expect(r.session.undo() && r.session.redo())
        #expect(r.restarts.isEmpty)
    }

    @Test func onlyTheEdgeNotReachedIsALeg() async throws {
        let (r, id, key) = try await picked()
        let pick = try #require(MagicPickWatch.picks(in: r.session.project).first { $0.ref == .init(clip: r.a, mask: id) })
        #expect(MagicPickWatch.legs(pick, times: [1, 3.96]) == [.init(from: 1, to: 0, forward: false)])
        // With that frame on record the pick was followed before: coming back does not track it again.
        r.store.put(Self.matte, key: key, pts: 3.96)
        #expect(r.session.undo() && r.session.redo())
        #expect(r.restarts.isEmpty && r.watch.waiting.isEmpty)
    }

    /// The pick's own track was stopped by the user halfway, then the clip is deleted and the delete undone: the
    /// key is new to the watch, but its tracked frames are on record. No run, and the frames stay as they are
    /// (before: tracked again from the pick's frame, over the frames kept).
    @Test func aStoppedPickWhoseClipIsDeletedAndComesBackIsNotTrackedAgain() async throws {
        let (r, id, key) = try await picked()
        r.followsReturnedPicks = true
        let t = r.startTrack(id, key: key, clip: r.a)
        for f in 26...50 { r.store.put(Self.matte, key: key, pts: Double(f) / 25) }
        r.activity.stop(reason: "Stop", keeps: true)
        await t.value
        let frames = r.store.times(key: key)
        #expect(frames.count == 26 && r.activity.run == nil)
        try r.session.performTimeline("Delete") { tl in _ = try tl.rippleDelete([r.a]) }
        #expect(MagicPickWatch.key(id, clip: r.a, in: r.session.project) == nil)
        #expect(r.session.undo())
        #expect(MagicPickWatch.key(id, clip: r.a, in: r.session.project) == key)
        #expect(r.restarts.isEmpty && r.watch.waiting.isEmpty && r.activity.run == nil)
        #expect(r.store.times(key: key) == frames)
    }

    /// A pick returns by undo while another mask's run has the slot: it waits, the run goes on, and the pick is
    /// followed when the run ended and the Magic tool is active (before: never, the watch had forgotten it).
    @Test func aPickThatReturnsWhileAnotherRunIsLiveIsFollowedWhenTheSlotIsFree() async throws {
        let (r, id, key) = try await picked()
        r.followsReturnedPicks = true
        await r.park(on: r.b, at: 5)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        let other = try #require(r.masks(r.b).first?.id)
        await r.park(on: r.a, at: 1)
        r.model.removeMask(id)
        #expect(r.masks(r.a).isEmpty)
        let t = r.startTrack(other, clip: r.b)
        #expect(r.session.undo())
        #expect(r.restarts.map(\.key) == [key] && r.watch.waiting.map(\.key) == [key])
        #expect(r.activity.run?.mask == other && !t.isCancelled)
        // Edits elsewhere: still one run, the pick still waits.
        r.session.perform("Rename") { $0.name = "Q" }
        r.session.onChange?([.project])
        #expect(r.activity.run?.mask == other && !t.isCancelled && r.watch.waiting.map(\.key) == [key])
        // The run ends while another tool is active: nothing starts.
        r.toolIsMagic = false
        t.cancel()
        await t.value
        #expect(r.activity.run == nil && r.watch.waiting.map(\.key) == [key])
        // Back on the Magic tool: the pick gets the free slot, once.
        r.toolIsMagic = true
        r.follow(toolChosen: true)
        #expect(r.activity.isFollowing(clip: r.a, mask: id, key: key, owner: r.session) && r.watch.waiting.isEmpty)
        r.session.onChange?([.project])
        r.follow()
        #expect(r.restarts.count == 1 && r.activity.run?.mask == id)
        r.activity.stop(reason: "test ends")
    }

    /// The maintainer's sequence: click an object, its track stores some frames, undo, redo. Undo cuts the track off (its
    /// mask is gone; the frames stay in memory), so redo goes on towards both edges although frames are on record
    /// (before: the half-tracked mask stayed as it was). Stopped by the user after that, it stays stopped.
    @Test func undoThenRedoOfAPickWhoseTrackWasRunningGoesOn() async throws {
        let (r, id, key) = try await picked()
        r.followsReturnedPicks = true
        let t = r.startTrack(id, key: key, clip: r.a)
        for f in 26...50 { r.store.put(Self.matte, key: key, pts: Double(f) / 25) }
        #expect(r.session.undo())
        #expect(t.isCancelled && r.activity.run == nil && r.store.times(key: key).count == 26)
        await t.value
        #expect(r.session.redo())
        #expect(r.restarts == [.init(ref: .init(clip: r.a, mask: id), key: key, legs: [
            .init(from: 1, to: 3.96, forward: true), .init(from: 1, to: 0, forward: false),
        ])])
        #expect(r.activity.isFollowing(clip: r.a, mask: id, key: key, owner: r.session))
        // The user stops the run that went on: undo and redo leave it stopped now.
        let again = try #require(r.activity.run)
        #expect(again.automatic)
        r.activity.stop(reason: "Stop", keeps: true)
        for _ in 0..<50 { await Task.yield() }
        #expect(r.session.undo() && r.session.redo())
        #expect(r.restarts.count == 1 && r.activity.run == nil && r.watch.waiting.isEmpty)
    }

    /// The pick's track was cut off by undo, the pick came back while another tool was active (it waits), and the
    /// user tracked it with a track button and stopped that run. The cut-off note ended when that run started:
    /// the clip deleted and brought back, the pick stays stopped (before: the note was still there and the pick
    /// was tracked again, over the user's Stop).
    @Test func aRunStartedByHandEndsTheCutOffNoteSoItsStopStays() async throws {
        let (r, id, key) = try await picked()
        r.followsReturnedPicks = true
        let t = r.startTrack(id, key: key, clip: r.a)
        for f in 26...50 { r.store.put(Self.matte, key: key, pts: Double(f) / 25) }
        r.toolIsMagic = false
        #expect(r.session.undo())
        #expect(t.isCancelled)
        await t.value
        #expect(r.session.redo())
        #expect(r.restarts.count == 1 && r.watch.waiting.map(\.key) == [key] && r.activity.run == nil)
        let byHand = r.startTrack(id, key: key, clip: r.a, automatic: false)
        #expect(r.watch.waiting.isEmpty && r.activity.run?.automatic == false)
        r.activity.stop(reason: "Stop", keeps: true)
        await byHand.value
        r.toolIsMagic = true
        try r.session.performTimeline("Delete") { tl in _ = try tl.rippleDelete([r.a]) }
        #expect(r.session.undo())
        #expect(MagicPickWatch.key(id, clip: r.a, in: r.session.project) == key)
        #expect(r.restarts.count == 1 && r.watch.waiting.isEmpty && r.activity.run == nil)
    }

    /// A run started with a track button is cut off by undo: when the pick comes back nothing starts by itself
    /// (one direction was asked for; the user clicks the button again). Before: tracked towards both edges.
    @Test func aTrackButtonRunCutOffByTheProjectIsNotResumed() async throws {
        let (r, id, key) = try await picked()
        r.followsReturnedPicks = true
        let t = r.startTrack(id, key: key, clip: r.a, automatic: false)
        for f in 26...50 { r.store.put(Self.matte, key: key, pts: Double(f) / 25) }
        #expect(r.session.undo())
        #expect(t.isCancelled && r.activity.run == nil)
        await t.value
        #expect(r.session.redo())
        #expect(r.restarts.isEmpty && r.watch.waiting.isEmpty && r.activity.run == nil)
        #expect(r.store.times(key: key).count == 26)
    }

    /// A track cut off by Delete Mask had reached the clip's end: the mask returns (undo) and only the edge not
    /// reached is followed.
    @Test func onlyTheEdgeNotReachedIsFollowedWhenACutOffTrackComesBack() async throws {
        let (r, id, key) = try await picked()
        let t = r.startTrack(id, key: key, clip: r.a)
        for f in 26...99 { r.store.put(Self.matte, key: key, pts: Double(f) / 25) }
        r.model.removeMask(id)
        #expect(t.isCancelled && r.activity.run == nil)
        await t.value
        #expect(r.session.undo())
        #expect(r.restarts.map(\.legs) == [[.init(from: 1, to: 0, forward: false)]])
    }

    /// A pick waits for the slot and the user stops the run that has it: Stop ends tracking, the waiting pick does
    /// not start by itself, not on later edits either. Choosing the Magic tool again starts it.
    @Test func theUsersStopStartsNoWaitingPickUntilTheMagicToolIsChosen() async throws {
        let (r, id, key, t) = try await waitingBehindARun()
        r.activity.stop(reason: "Stop", keeps: true)
        await t.value
        #expect(r.activity.run == nil && r.watch.waiting.map(\.key) == [key] && r.watch.isHeld)
        r.session.perform("Rename") { $0.name = "Q" }
        r.follow()
        #expect(r.activity.run == nil && r.watch.waiting.map(\.key) == [key])
        r.follow(toolChosen: true)
        #expect(r.activity.isFollowing(clip: r.a, mask: id, key: key, owner: r.session) && !r.watch.isHeld)
        r.activity.stop(reason: "test ends")
    }

    /// The hold ends only with a subject-mask run for the stopped mask (or a waiting pick's): a path track starts
    /// and ends and the waiting pick stays held (before: any run start ended the hold).
    @Test func afterTheUsersStopOnlyASubjectRunOfThatMaskEndsTheHold() async throws {
        let (r, id, key, t) = try await waitingBehindARun()
        r.activity.stop(reason: "Stop", keeps: true)
        await t.value
        #expect(r.activity.run == nil && r.watch.isHeld)
        let other = try #require(r.masks(r.b).first?.id)
        // A path track (no key: the watch is not told) that ends by itself.
        let path = r.startTrack(other, clip: r.b)
        #expect(r.watch.isHeld)
        path.cancel()
        await path.value
        #expect(r.activity.run == nil && r.watch.isHeld && r.watch.waiting.map(\.key) == [key])
        r.session.perform("Rename") { $0.name = "R" }
        #expect(r.activity.run == nil && r.watch.isHeld)
        // The user tracks the stopped mask again: tracking goes on, the waiting pick follows when that run ends.
        let otherKey = try #require(MagicPickWatch.key(other, clip: r.b, in: r.session.project))
        let again = r.startTrack(other, key: otherKey, clip: r.b, automatic: false)
        #expect(!r.watch.isHeld && r.watch.waiting.map(\.key) == [key])
        again.cancel()
        await again.value
        #expect(r.activity.isFollowing(clip: r.a, mask: id, key: key, owner: r.session) && r.watch.waiting.isEmpty)
        r.activity.stop(reason: "test ends")
    }

    /// A subject-mask run for the waiting pick's own mask ends the hold too (it is that pick's run).
    @Test func aRunOfTheWaitingPicksMaskEndsTheHold() async throws {
        let (r, id, key, t) = try await waitingBehindARun()
        r.activity.stop(reason: "Stop", keeps: true)
        await t.value
        #expect(r.watch.isHeld)
        let byHand = r.startTrack(id, key: key, clip: r.a, automatic: false)
        #expect(!r.watch.isHeld && r.watch.waiting.isEmpty)
        r.followsReturnedPicks = false
        byHand.cancel()
        await byHand.value
    }

    /// The hold by itself: a subject-mask run of a mask that is neither the stopped one nor a waiting pick's
    /// leaves it, the Magic tool chosen ends it.
    @Test func aSubjectRunOfAnUnrelatedMaskLeavesTheHold() async throws {
        let (r, _, key, t) = try await waitingBehindARun()
        r.activity.stop(reason: "Stop", keeps: true)
        await t.value
        var w = r.watch
        #expect(w.isHeld)
        w.started("some other key", mask: ClipMask.makeMagic(name: "M", points: []).id)
        #expect(w.isHeld && w.waiting.map(\.key) == [key])
        #expect(w.next(slotFree: true, toolIsMagic: true) == nil)
        #expect(w.next(slotFree: true, toolIsMagic: true, toolChosen: true)?.key == key && !w.isHeld)
    }

    /// A cut-off note ends when the pick is back with mattes that reach both edges: nothing is left to go on
    /// with, so frames deleted by hand later do not start a track when the pick returns once more (before: the
    /// note stayed until another project opened and the pick was tracked again).
    @Test func aCutOffNoteEndsWhenThePickIsBackComplete() async throws {
        let (r, id, key) = try await picked()
        r.followsReturnedPicks = true
        let t = r.startTrack(id, key: key, clip: r.a)
        for f in 26...50 { r.store.put(Self.matte, key: key, pts: Double(f) / 25) }
        #expect(r.session.undo())
        await t.value
        #expect(r.watch.cutOffKeys == [key])
        for f in 0...99 { r.store.put(Self.matte, key: key, pts: Double(f) / 25) }
        #expect(r.session.redo())
        #expect(r.restarts.isEmpty && r.activity.run == nil && r.watch.cutOffKeys.isEmpty)
        #expect(r.store.removeFrames(key: key, times: (60...99).map { Double($0) / 25 }) == 40)
        #expect(r.session.undo() && r.session.redo())
        #expect(r.restarts.isEmpty && r.activity.run == nil)
    }

    /// A note stays while undo or redo can bring its pick back, and goes once nothing can.
    @Test func aCutOffNoteEndsWhenItsPickCannotComeBack() async throws {
        let (r, id, key) = try await picked()
        let t = r.startTrack(id, key: key, clip: r.a)
        for f in 26...50 { r.store.put(Self.matte, key: key, pts: Double(f) / 25) }
        #expect(r.session.undo())
        await t.value
        #expect(r.session.canRedo && r.watch.cutOffKeys == [key])
        let gone = r.session.project
        #expect(r.session.redo())
        let back = r.session.project
        #expect(MagicPickWatch.key(id, clip: r.a, in: back) == key)
        let times: (String) -> [Double] = { [store = r.store] in store.times(key: $0) }
        // The pick is in the project: its note stays whatever the history holds.
        var w = r.watch
        w.cutOff(key, automatic: true)
        _ = w.look(at: back, canReturn: false, times: times) { _, _ in true }
        #expect(w.cutOffKeys == [key])
        // The pick is gone and a step can bring it back: the note stays. No step: it goes.
        _ = w.look(at: gone, canReturn: true, times: times) { _, _ in false }
        #expect(w.cutOffKeys == [key])
        _ = w.look(at: gone, canReturn: false, times: times) { _, _ in false }
        #expect(w.cutOffKeys.isEmpty)
    }

    /// The halves of a split clip share their mask ids: a run of the same mask id on another clip is not the
    /// stopped mask's run and not the waiting pick's.
    @Test func theHoldIsReleasedByClipAndMaskNotByTheMaskIdAlone() async throws {
        let (r, id, _, t) = try await waitingBehindARun()
        let other = try #require(r.masks(r.b).first?.id)
        r.activity.stop(reason: "Stop", keeps: true)
        await t.value
        var w = r.watch
        #expect(w.isHeld)
        w.started("x", mask: id, clip: r.b)        // the waiting pick is on clip A
        #expect(w.isHeld)
        w.started("x", mask: other, clip: r.a)     // the stopped run was on clip B
        #expect(w.isHeld)
        var v = w
        v.started("x", mask: other, clip: r.b)
        #expect(!v.isHeld)
        w.started("x", mask: id, clip: r.a)
        #expect(!w.isHeld)
    }

    /// The rule by itself: who gets the slot.
    @Test func theWatchHandsTheSlotToOneWaitingPickAtATime() async throws {
        let (r, _, key, t) = try await waitingBehindARun()
        var w = r.watch
        #expect(w.next(slotFree: false, toolIsMagic: true) == nil && w.next(slotFree: true, toolIsMagic: false) == nil)
        #expect(w.next(slotFree: true, toolIsMagic: true)?.key == key)
        #expect(w.waiting.isEmpty && w.next(slotFree: true, toolIsMagic: true) == nil)
        t.cancel()
        r.followsReturnedPicks = false
        await t.value
    }

    /// Clip A's pick came back (undo of Delete Mask) while a track of clip B's mask has the slot.
    private func waitingBehindARun() async throws -> (Rig, ClipMask.ID, String, Task<Void, Never>) {
        let (r, id, key) = try await picked()
        r.followsReturnedPicks = true
        await r.park(on: r.b, at: 5)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        let other = try #require(r.masks(r.b).first?.id)
        await r.park(on: r.a, at: 1)
        r.model.removeMask(id)
        let t = r.startTrack(other, clip: r.b)
        #expect(r.session.undo())
        #expect(r.activity.run?.mask == other && r.watch.waiting.map(\.key) == [key])
        return (r, id, key, t)
    }

    /// The same with the Magic tool active all along: the end of the run hands the slot over by itself.
    @Test func aWaitingPickTakesTheSlotWhenTheRunEnds() async throws {
        let (r, id, key) = try await picked()
        r.followsReturnedPicks = true
        await r.park(on: r.b, at: 5)
        await r.tool.click(Rig.object, subtract: false, newMask: false)
        let other = try #require(r.masks(r.b).first?.id)
        await r.park(on: r.a, at: 1)
        r.model.removeMask(id)
        let t = r.startTrack(other, clip: r.b)
        #expect(r.session.undo() && r.activity.run?.mask == other)
        t.cancel()
        await t.value
        #expect(r.activity.isFollowing(clip: r.a, mask: id, key: key, owner: r.session) && r.watch.waiting.isEmpty)
        r.activity.stop(reason: "test ends")
    }

    @Test func aMaskWithoutAPickOrWithoutItsPicksFrameIsNotFollowed() async throws {
        let (r, id, key) = try await picked()
        // The pick's own frame is gone (nothing to start from).
        r.store.remove(key: key)
        r.store.put(Self.matte, key: key, pts: 2)
        #expect(r.session.undo() && r.session.redo())
        #expect(r.restarts.isEmpty)
        // No pick at all: a drawn mask, and a clip without masks.
        r.model.removeMask(id)
        #expect(r.session.undo())
        #expect(r.restarts.isEmpty)
        #expect(MagicPickWatch.legs(.init(ref: .init(clip: r.a, mask: id), key: key, anchor: 1, low: 0, high: 4, slack: 0.06), times: []).isEmpty)
    }

    /// Stop, a lost subject or deleted frames leave a pick incomplete on purpose: an edit elsewhere must not start it again.
    @Test func anIncompletePickThatDidNotComeBackIsNotFollowed() async throws {
        let (r, _, _) = try await picked()
        r.session.perform("Rename") { $0.name = "Q" }
        #expect(r.session.undo() && r.session.redo())
        #expect(r.restarts.isEmpty)
    }

    /// The halves of a split clip share their mask ids. A run on the right half is looked up by clip and mask: an
    /// edit elsewhere does not stop it (before: the lookup found the left half first), and removing the mask from
    /// the left half does not either.
    @Test func aRunOnTheRightHalfOfASplitClipSurvivesProjectEdits() async throws {
        let (r, id, key) = try await picked()
        try r.session.performTimeline("Split") { tl in
            let i = try #require(tl.tracks.firstIndex { $0.kind == .video })
            try tl.tracks[i].split(at: Time(2, 1))
        }
        let clips = r.session.activeTimeline!.tracks.flatMap(\.clips)
        let right = try #require(clips.first { $0.id != r.a && $0.mask(id) != nil })
        #expect(r.restarts.isEmpty)
        #expect(MagicPickWatch.key(id, clip: right.id, in: r.session.project) == key)
        var saved = 0
        let t = r.startTrack(id, key: key, clip: right.id) { saved += 1 }
        // The left half gets another pick: looked up by the mask id alone, the left half would answer for the run
        // with its new key and the run would be stopped on this and every later edit.
        await r.tool.click(Rig.object, subtract: true, newMask: false)
        #expect(MagicPickWatch.key(id, clip: r.a, in: r.session.project) != key)
        r.session.perform("Rename") { $0.name = "Q" }
        #expect(r.activity.run?.clip == right.id && !t.isCancelled && saved == 0)
        // The left half loses the mask: the run's mask is still on its own clip.
        r.model.removeMask(id)
        #expect(r.masks(r.a).isEmpty && r.activity.run != nil && !t.isCancelled && saved == 0)
        // A run on the left half is stopped by the same edits.
        #expect(r.session.undo())
        let left = try #require(MagicPickWatch.key(id, clip: r.a, in: r.session.project))
        let t2 = r.startTrack(id, key: left, clip: r.a)
        r.model.removeMask(id)
        #expect(t.isCancelled && t2.isCancelled && r.activity.run == nil)
        await t.value
        await t2.value
    }
}

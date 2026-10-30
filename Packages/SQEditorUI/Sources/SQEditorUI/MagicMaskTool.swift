import SQUIKit
import AppKit
import SQAnalysis
import SQCore

/// The Mask tool's Magic mode between the monitor overlay, Effect Controls and the segmenter (`MagicMaskSession`): which
/// frame is worked on, the hover highlight, the pick shown on the frame and what a click does. The host only says which
/// clip the monitor targets, where its file is and whether the sequence plays.
///
/// Nothing here outlives its reason: the hover highlight is tied to the frame it was made on and to what the overlay
/// really shows, a frame that gave nothing is tried again by a click, and every refused hover or click logs why.
/// Hover never changes the selection: with no usable clip selected, the clip under the pointer is only previewed.
@MainActor
public final class MagicMaskTool {
    /// The clip frame a hover or click works on.
    public struct Source: Equatable, Sendable {
        public var clip: Clip.ID
        public var media: UUID
        public var url: URL
        public var sourceTime: Time
    }

    public let session: MagicMaskSession
    private let model: EffectControlsModel
    private let overlay: TransformOverlayView
    private let store: MagicMatteStore

    /// The clip the monitor overlay targets (nil = none).
    public var targetClip: () -> Clip.ID? = { nil }
    /// The file of a media item (nil = offline or unknown).
    public var mediaURL: (UUID) -> URL? = { _ in nil }
    public var isPlaying: () -> Bool = { false }
    public var onStatus: ((String) -> Void)?
    /// A click changed the clip's masks: the host redraws its overlay.
    public var onMaskChanged: (() -> Void)?
    /// A matte was stored: the picture shows it.
    public var onPicked: (() -> Void)?
    /// A click on another tracked frame than the pick's (mask, point, subtract): the host corrects and tracks on.
    public var onCorrect: ((ClipMask.ID, Vec2, Bool) -> Void)?

    /// The highlight the overlay shows: the object `label` of this frame.
    private var hover: (source: Source, label: UInt8)?
    /// Where the pointer rests (frame fraction): the highlight comes back there once a new frame is segmented.
    private var hoverPoint: Vec2?
    private var lastRefusal: String?
    /// The mask whose last pick got no matte in time (`PickResult.gaveUp`): its point is in the project already, so
    /// the next click makes that matte instead of adding a second point.
    private var unpicked: ClipMask.ID?
    /// The frame previewed under the pointer while the selection gives Magic nothing to work on (`preview`).
    public private(set) var previewSource: Source?
    private var previewLabel: UInt8?
    /// The frame whose problem (read error, timeout) the status line already told.
    private var toldProblem: (source: Source, what: MagicMaskSession.Problem)?

    public init(model: EffectControlsModel, overlay: TransformOverlayView, session: MagicMaskSession = MagicMaskSession(),
                store: MagicMatteStore = .shared) {
        self.model = model; self.overlay = overlay; self.session = session; self.store = store
    }

    /// Magic segments frames of a video file: no title, graphic, still, nested sequence or hold frame.
    public nonisolated static func canUse(_ clip: Clip) -> Bool {
        clip.kind == .video && clip.sequence == nil && !clip.isGenerator && !clip.isStill && clip.holdFrame == nil
    }

    /// Why Magic cannot work right now, in the interface language; nil when `source` exists.
    public var refusal: String? { refusalKey.map { SQL10n.string($0) } }

    /// The English reason (the Localizable key); logs use it.
    private var refusalKey: String? {
        guard let clip = model.clip else { return "no clip selected" }
        guard clip.id == targetClip() else { return "the selected clip is not shown under the playhead" }
        guard Self.canUse(clip) else { return "not a video clip from a file" }
        guard mediaURL(clip.media) != nil else { return "the clip's file is unknown" }
        guard model.playheadInClip else { return "the playhead is outside the clip" }
        return nil
    }

    /// The selected clip's source frame under the playhead, when Magic can work on it (a video clip from a file that the
    /// monitor targets).
    public var source: Source? {
        guard refusalKey == nil, let clip = model.clip, let url = mediaURL(clip.media) else { return nil }
        let fd = model.frameDuration
        let local = min(model.localPlayhead.snapped(to: fd), max(clip.duration - fd, .zero))
        return Source(clip: clip.id, media: clip.media, url: url, sourceTime: clip.sourceInstant(atLocal: local))
    }

    /// Called whenever selection, playhead or the clip changed: in Magic mode with a parked playhead, segments the shown
    /// frame (once) and shows the active Magic mask's pick on it.
    public func refresh() {
        let usable = source != nil
        if overlay.magicUsable != usable { overlay.magicUsable = usable }
        guard overlay.maskTool == .magic, !isPlaying(), let src = source else {
            if overlay.maskTool == .magic, !isPlaying() { note(refusalKey) } else { clearPreview() }
            if overlay.magicPick != nil { overlay.magicPick = nil }
            if !overlay.magicMarkers.isEmpty { overlay.magicMarkers = [] }
            clearHover(keepPoint: previewSource != nil)
            return
        }
        note(nil)
        clearPreview()          // the selection works: the highlight is the selected clip's
        // A new frame (seek, scrub, step, another clip): segment it; the newer frame cancels a stale request, and the
        // hover highlight comes back under the resting pointer once it is ready.
        if !session.isReady(media: src.media, sourceTime: src.sourceTime) {
            clearHover(keepPoint: true)
            ensurePrepared(src)
        }
        refreshPick(scrubbing: true)
    }

    /// Starts the frame's segmentation unless it is ready, on its way, known to be empty or failed a moment ago (the
    /// session's rule); when it is ready the pick and the highlight under the resting pointer follow. A request that
    /// threw or timed out tells the status line once.
    private func ensurePrepared(_ src: Source) {
        guard session.wantsPrepare(media: src.media, sourceTime: src.sourceTime), waitingPrepare != src else { return }
        waitingPrepare = src
        Task { @MainActor [weak self] in
            // Scrubbing: segmenting every passed frame (a Vision pass each) is what made the Mask tool crawl. Only a frame
            // the playhead rests on for a moment is segmented.
            try? await Task.sleep(for: .milliseconds(180))
            if self?.waitingPrepare == src { self?.waitingPrepare = nil }
            // Only the frame still worked on: a request for a frame left meanwhile would cancel the current one.
            guard let self, source == src || previewSource == src else { return }
            let ready = await session.prepare(media: src.media, url: src.url, sourceTime: src.sourceTime)
            guard ready else { tellProblem(src); return }
            if source == src {
                refreshPick()
                pointer(hoverPoint)
            } else if previewSource == src {
                showPreview(src)
            }
        }
    }

    /// The status line for a frame whose request threw or timed out (once per frame and reason). False = no such problem.
    @discardableResult
    private func tellProblem(_ src: Source) -> Bool {
        guard source == src || previewSource == src,
              let what = session.problem(media: src.media, sourceTime: src.sourceTime) else { return false }
        if let t = toldProblem, t.source == src, t.what == what { return true }
        toldProblem = (src, what)
        switch what {
        case .failed(let why):
            onStatus?(SQL10n.format("Magic could not read this frame (%@): move the pointer or click to try again.", why))
        case .timedOut(let seconds):
            onStatus?(SQL10n.format("Magic got no answer for this frame within %@ seconds and gave up: click to try again.", String(Int(seconds.rounded(.up)))))
        }
        return true
    }

    /// The active Magic mask's matte and click dots on the shown frame.
    /// `scrubbing`: from the per-frame refresh, the matte is read off the main thread; after a pick or a segmentation
    /// (one per resting frame) it is made at once.
    public func refreshPick(scrubbing: Bool = false) {
        guard let id = model.activeMagicMaskID, let key = model.magicCacheKey(id), let src = source else {
            wantedPick = ""; shownPickMask = nil
            overlay.magicPick = nil; overlay.magicMarkers = []; return
        }
        let t = src.sourceTime
        overlay.magicMarkers = MagicMarker.markers(model.clip?.mask(id)?.magic, sourceTime: t, frameDuration: model.frameDuration)
        let pts = Double(t.value) / Double(max(t.timescale, 1))
        // A Face / Skin mask shows what it draws (the narrowed matte), the whole person where that is missing.
        let keys = [model.magicPartKey(id), key].compactMap { $0 }
        let rev = MagicTrackedFrames.shared.revision
        if rev != pickRevision { pickImages = [:]; pickRevision = rev }
        // Cached image of this frame: no matte read on the main thread. Otherwise the previous pick stays (no flicker
        // while scrubbing) and the matte is read and drawn off the main thread; only the newest wanted frame is made.
        let ck = keys.map { "\($0)@\(pts)" }
        if let hit = ck.lazy.compactMap({ self.pickImages[$0] }).first { overlay.magicPick = hit.image; shownPickMask = id; return }
        wantedPick = ck.joined(separator: "|")
        shownPickMask = id
        if !scrubbing || session.isReady(media: src.media, sourceTime: src.sourceTime) {
            let drawn = keys.lazy.compactMap { self.store.matte(key: $0, pts: pts) }.first
            let img = drawn.flatMap { MagicHighlight.image($0, color: Theme.Colors.yellow, alpha: 0.3) }
            if let img { pickImages[ck[0]] = PickImage(image: img) }
            overlay.magicPick = img
            return
        }
        // Another mask or clip: its pick is not the one on screen, so nothing is shown until its own is in.
        if shownPickMask != id { overlay.magicPick = nil; shownPickMask = id }
        let store = store, want = wantedPick
        Task.detached(priority: .userInitiated) { [weak self] in
            let cur = await MainActor.run { self?.wantedPick }
            guard cur == want else { return }                       // scrubbed on: this frame is not wanted any more
            var made: CGImage?
            for k in keys {
                if let m = store.matte(key: k, pts: pts) { made = MagicHighlight.image(m, color: Theme.Colors.yellow, alpha: 0.3); break }
            }
            let box = PickBox(image: made)
            await MainActor.run { self?.finishPick(box, ck: ck, want: want, revision: rev) }
        }
    }

    private func finishPick(_ box: PickBox, ck: [String], want: String, revision: Int) {
        guard pickRevision == revision else { return }
        if let img = box.image {
            if pickImages.count >= 12 { pickImages = [:] }
            pickImages[ck[0]] = PickImage(image: img)
        }
        guard wantedPick == want else { return }
        overlay.magicPick = box.image
    }

    private struct PickBox: @unchecked Sendable { let image: CGImage? }
    private struct PickImage { let image: CGImage }
    private var pickImages: [String: PickImage] = [:]
    private var pickRevision = -1
    private var wantedPick = ""
    private var shownPickMask: ClipMask.ID?
    /// The frame whose (debounced) segmentation is already scheduled.
    private var waitingPrepare: Source?

    /// The pointer moved to frame fraction `p` of the targeted clip (nil = left the picture).
    public func pointer(_ p: Vec2?) {
        hoverPoint = p
        guard let p, let src = source else { clearHover(keepPoint: true); return }
        guard session.isReady(media: src.media, sourceTime: src.sourceTime) else {
            clearHover(keepPoint: true)
            ensurePrepared(src)         // a frame whose request failed is tried again by the next pointer move
            return
        }
        guard let hit = session.hover(at: p) else { clearHover(keepPoint: true); return }
        // The same object of the same frame is already shown. The overlay may have dropped its image meanwhile (tool
        // switched, target lost): then it is drawn again.
        if let h = hover, h.source == src, h.label == hit.label, overlay.magicHover != nil { return }
        hover = (src, hit.label)
        overlay.magicHover = MagicHighlight.image(hit.matte)
        guard !hit.soft else { return }
        // The hard labels show at once; the soft matte is made off the main thread and swapped in when it is still wanted.
        let label = hit.label
        Task { @MainActor [weak self] in
            guard let self, let m = await session.softMatte(label),
                  let h = hover, h.source == src, h.label == label, overlay.magicHover != nil else { return }
            overlay.magicHover = MagicHighlight.image(m)
        }
    }

    private func clearHover(keepPoint: Bool = false) {
        hover = nil
        if !keepPoint { hoverPoint = nil }
        if overlay.magicHover != nil { overlay.magicHover = nil }
    }

    /// The selection gives Magic nothing to work on, and the pointer rests on `clip` (the topmost usable clip under it,
    /// with the playhead at `localPlayhead` of it): its object under frame fraction `p` is highlighted as a preview.
    /// Nothing is selected and nothing changes; the click picks and selects. `layer`: where that clip's picture lies on
    /// the monitor. A nil clip, layer or point (pointer left, nothing usable there, playback) clears the preview.
    public func preview(_ clip: Clip?, localPlayhead: Time = .zero, layer: TransformOverlayView.MagicPreviewLayer? = nil,
                        at p: Vec2? = nil) {
        guard overlay.maskTool == .magic, !isPlaying(), source == nil, let clip, Self.canUse(clip), let layer, let p,
              let url = mediaURL(clip.media) else { clearPreview(); return }
        let fd = model.frameDuration
        let local = min(max(localPlayhead, .zero).snapped(to: fd), max(clip.duration - fd, .zero))
        let src = Source(clip: clip.id, media: clip.media, url: url, sourceTime: clip.sourceInstant(atLocal: local))
        if previewSource != src {
            NSLog("[Magic] preview: the clip under the pointer (not selected), frame %.3f s",
                  Double(src.sourceTime.value) / Double(max(src.sourceTime.timescale, 1)))
            previewSource = src
            previewLabel = nil
            if overlay.magicPreview != nil { overlay.magicPreview = nil }
        }
        if overlay.magicPreviewLayer != layer { overlay.magicPreviewLayer = layer }
        hoverPoint = p
        guard session.isReady(media: src.media, sourceTime: src.sourceTime) else {
            previewLabel = nil
            if overlay.magicPreview != nil { overlay.magicPreview = nil }
            ensurePrepared(src)
            return
        }
        showPreview(src)
    }

    private func showPreview(_ src: Source) {
        guard previewSource == src, let p = hoverPoint, let hit = session.hover(at: p) else {
            previewLabel = nil
            if overlay.magicPreview != nil { overlay.magicPreview = nil }
            return
        }
        if previewLabel == hit.label, overlay.magicPreview != nil { return }
        let label = hit.label
        previewLabel = label
        overlay.magicPreview = MagicHighlight.image(hit.matte)
        guard !hit.soft else { return }
        Task { @MainActor [weak self] in
            guard let self, let m = await session.softMatte(label),
                  previewSource == src, previewLabel == label, overlay.magicPreview != nil else { return }
            overlay.magicPreview = MagicHighlight.image(m)
        }
    }

    private func clearPreview() {
        previewSource = nil; previewLabel = nil
        if overlay.magicPreview != nil { overlay.magicPreview = nil }
        if overlay.magicPreviewLayer != nil { overlay.magicPreviewLayer = nil }
    }

    /// A Magic click at frame fraction `p`: the frame under the playhead is segmented first (a frame that gave nothing
    /// before is tried again); only a click that hits an object (or removes from a pick) changes the mask, so a click on
    /// a frame that shows nothing never leaves a mask without a matte there. On another frame than the pick's the click
    /// corrects the tracked matte there (`onCorrect`).
    public func click(_ p: Vec2, subtract: Bool, newMask: Bool) async {
        guard let src = source else {
            NSLog("[Magic] click refused: %@", refusalKey ?? "?")
            onStatus?("Magic works on video clips: select one under the playhead (click it in the picture or the timeline).")
            return
        }
        let ready = await session.prepare(media: src.media, url: src.url, sourceTime: src.sourceTime, retry: true)
        guard source == src else { NSLog("[Magic] click dropped: the frame changed meanwhile"); return }
        guard ready else {
            toldProblem = nil           // a click always gets its answer
            if !tellProblem(src) {
                NSLog("[Magic] click refused: nothing segmented on this frame")
                onStatus?("Magic finds nothing on this frame: try another frame (people, animals and objects).")
            }
            return
        }
        if !newMask, let id = model.activeMagicMaskID, model.magicClickCorrects(id) {
            onCorrect?(id, p, subtract)
            return
        }
        // Only on the frame that pick was made on: a click on another frame is a click of its own (before: swallowed,
        // the old pick's points were tried on a frame they were not made for).
        if !newMask, let id = unpicked, id == model.activeMagicMaskID, let key = model.magicCacheKey(id),
           let points = model.clip?.mask(id)?.magic?.points, points.first?.sourceTime == src.sourceTime {
            NSLog("[Magic] click: the pick that got no matte is made again")
            await pick(id, points: points, key: key)
            return
        }
        unpicked = nil
        if !subtract, session.hover(at: p) == nil {
            NSLog("[Magic] click refused: no object at %.3f, %.3f", p.x, p.y)
            onStatus?("Nothing to pick there: Magic finds people, animals and objects.")
            return
        }
        guard let id = model.maskToolClick(.magic, at: p, subtract: subtract, newMask: newMask) else {
            if subtract { onStatus?("Click an object first; Remove (or Option-click) takes areas out of a pick.") }
            return
        }
        onMaskChanged?()
        guard let key = model.magicCacheKey(id), let points = model.clip?.mask(id)?.magic?.points else { return }
        await pick(id, points: points, key: key)
    }

    /// Makes and stores the matte of mask `id`'s points on the shown frame and says how it went.
    private func pick(_ id: ClipMask.ID, points: [MagicPoint], key: String) async {
        unpicked = nil
        switch await session.pick(points: points, key: key, store: store) {
        case .stored:
            onStatus?("Picked on this frame. Track it with the buttons in Effect Controls. Click to add, Remove (or Option-click) to take areas out, Shift-click for a new mask.")
        case .nothing, .refused:
            onStatus?("Nothing left in the pick on this frame: the picture stays as it is.")
        case .gaveUp(let seconds):
            unpicked = id
            onStatus?(SQL10n.format("Magic got no answer for this pick within %@ seconds and gave up: click to try again.", String(Int(seconds.rounded(.up)))))
        }
        onPicked?()
        refreshPick()
    }

    /// One log line per change of the reason Magic is off (never per redraw).
    private func note(_ reason: String?) {
        guard reason != lastRefusal else { return }
        lastRefusal = reason
        if let reason { NSLog("[Magic] off: %@", reason) } else { NSLog("[Magic] on") }
    }
}

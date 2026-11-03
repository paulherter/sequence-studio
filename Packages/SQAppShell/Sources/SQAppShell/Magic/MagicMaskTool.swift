import Foundation
import SQAnalysis
import SQCore
import SQEditorSession
import SQInspectorUI
import SQUIKit

/// The Mask tool's Magic mode between the shared monitor, Effect Controls and the segmenter (`MagicMaskSession`): which
/// frame is worked on, the matte under the pointer and what a click does. The host only says which clip the monitor
/// targets, where its file is, whether Magic is the chosen mask tool and whether the sequence plays. The shared monitor
/// draws the highlights itself from `hoverMatte` / `previewMatte`.
///
/// Nothing here outlives its reason: a frame that gave nothing is tried again by a click, and every refused hover or click
/// logs why. Hover never changes the selection: with no usable clip selected, the clip under the pointer is only previewed.
/// Apple-only (Vision / Core ML through `MagicMaskSession`, `MagicMatteStore`).
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
    private let store: MagicMatteStore

    /// The clip the monitor overlay targets (nil = none).
    public var targetClip: () -> Clip.ID? = { nil }
    /// The file of a media item (nil = offline or unknown).
    public var mediaURL: (UUID) -> URL? = { _ in nil }
    public var isPlaying: () -> Bool = { false }
    /// Magic is the chosen mask tool.
    public var isMagicOn: () -> Bool = { false }
    public var onStatus: ((String) -> Void)?
    /// A click changed the clip's masks: the host redraws its overlay.
    public var onMaskChanged: (() -> Void)?
    /// A matte was stored: the picture shows it.
    public var onPicked: (() -> Void)?
    /// A click on another tracked frame than the pick's (mask, point, subtract): the host corrects and tracks on.
    public var onCorrect: ((ClipMask.ID, Vec2, Bool) -> Void)?

    private var lastRefusal: String?
    /// The mask whose last pick got no matte in time (`PickResult.gaveUp`): its point is in the project already, so
    /// the next click makes that matte instead of adding a second point.
    private var unpicked: ClipMask.ID?
    /// The frame previewed under the pointer while the selection gives Magic nothing to work on (`preview`).
    public private(set) var previewSource: Source?
    /// The frame whose problem (read error, timeout) the status line already told.
    private var toldProblem: (source: Source, what: MagicMaskSession.Problem)?

    public init(model: EffectControlsModel, session: MagicMaskSession = MagicMaskSession(), store: MagicMatteStore = .shared) {
        self.model = model; self.session = session; self.store = store
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
    /// frame (once); the shared monitor then reads the matte under the pointer with `hoverMatte`.
    public func refresh() {
        guard isMagicOn(), !isPlaying(), let src = source else {
            if isMagicOn(), !isPlaying() { note(refusalKey) } else { clearPreview() }
            return
        }
        note(nil)
        clearPreview()          // the selection works: the highlight is the selected clip's
        // A new frame (seek, scrub, step, another clip): segment it; the newer frame cancels a stale request.
        if !session.isReady(media: src.media, sourceTime: src.sourceTime) { ensurePrepared(src) }
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
            if !ready { tellProblem(src) }
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

    /// The frame whose (debounced) segmentation is already scheduled.
    private var waitingPrepare: Source?

    private var softAsked: (Time, UInt8)?

    /// Hover without the tool's own overlay image (the shared monitor draws the highlight itself): the object under frame
    /// fraction `p` of the selected clip's frame, and the frame's segmentation is started when it is not ready. nil when the
    /// pointer is over the background, the frame is not ready (asked again by the next call) or Magic has no source.
    /// `soft` false: the hard labels; the soft matte is made in the background and returned by a later call.
    public func hoverMatte(at p: Vec2) -> (label: UInt8, matte: SubjectMatte, soft: Bool, frame: Time)? {
        guard isMagicOn(), !isPlaying(), let src = source else { return nil }
        guard session.isReady(media: src.media, sourceTime: src.sourceTime) else { ensurePrepared(src); return nil }
        guard let hit = session.hover(at: p) else { return nil }
        if !hit.soft, softAsked?.0 != src.sourceTime || softAsked?.1 != hit.label {
            let label = hit.label
            softAsked = (src.sourceTime, label)
            Task { @MainActor [weak self] in _ = await self?.session.softMatte(label) }
        }
        return (hit.label, hit.matte, hit.soft, src.sourceTime)
    }

    /// Hover on a clip that is not selected: the object under frame fraction
    /// `p` of `clip` at `localPlayhead`. Only while the selection gives Magic nothing to work on (as `preview`); the frame is
    /// segmented in the background and asked again by the next call.
    public func previewMatte(_ clip: Clip, localPlayhead: Time, at p: Vec2) -> (label: UInt8, matte: SubjectMatte, soft: Bool, frame: Time)? {
        guard isMagicOn(), !isPlaying(), source == nil, Self.canUse(clip), let url = mediaURL(clip.media) else { return nil }
        let fd = model.frameDuration
        let local = min(max(localPlayhead, .zero).snapped(to: fd), max(clip.duration - fd, .zero))
        let src = Source(clip: clip.id, media: clip.media, url: url, sourceTime: clip.sourceInstant(atLocal: local))
        previewSource = src
        guard session.isReady(media: src.media, sourceTime: src.sourceTime) else { ensurePrepared(src); return nil }
        guard let hit = session.hover(at: p) else { return nil }
        if !hit.soft, softAsked?.0 != src.sourceTime || softAsked?.1 != hit.label {
            let label = hit.label
            softAsked = (src.sourceTime, label)
            Task { @MainActor [weak self] in _ = await self?.session.softMatte(label) }
        }
        return (hit.label, hit.matte, hit.soft, src.sourceTime)
    }

    private func clearPreview() { previewSource = nil }

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
    }

    /// One log line per change of the reason Magic is off (never per redraw).
    private func note(_ reason: String?) {
        guard reason != lastRefusal else { return }
        lastRefusal = reason
        if let reason { NSLog("[Magic] off: %@", reason) } else { NSLog("[Magic] on") }
    }
}

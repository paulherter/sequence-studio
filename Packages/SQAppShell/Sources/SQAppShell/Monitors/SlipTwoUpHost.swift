import Foundation
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// Slip drag on the shared UI: the clip's first and last frame side by side in the Program monitor while the mouse is
/// down (the Mac `SlipTwoUpView` with its two parked engines, EditorPanels+Slip.swift). Two silent engines from the
/// platform (`AppMonitorBackend.makeStillEngine`) decode the drag preview at the head and tail times; both pictures are packed into one
/// image slot (`SlipTwoUpLayout.pack`) that the monitor panel draws as two panes. Trim mode shows its Before / After
/// frames through the same engines and slot (`syncTrim`, the Mac `TrimMonitorView`).
/// shortcut: the pictures go through a CPU readback and a nearest-sample pack each time one changes; upgrade to two
/// texture slots when the UI renderer samples engine pictures directly in more than the video quad.
@MainActor
public final class SlipTwoUpHost {
    /// The image slot the packed pictures use (0: timeline thumbnails, 2-3: scopes).
    public static let slot = 1
    private let session: EditorSession
    private let backend: AppMonitorBackend
    private var engines: (head: any AppMonitorEngine, tail: any AppMonitorEngine)?
    private var shown: (timeline: Timeline, sequences: [Timeline.ID: Timeline])?
    private var times: (head: Time?, tail: Time?)?
    private var labels: SlipTwoUpPicture?
    private var packedFrom: (Int, Int) = (-1, -1)
    public private(set) var image: (Int, RGBAImage, Int)?
    private var generation = 0
    private weak var trim: TrimModeModel?

    public init(session: EditorSession, backend: AppMonitorBackend) {
        self.session = session
        self.backend = backend
    }

    /// One drag step (TimelineHost.slipTwoUp); nil hides the two-up and parks the engines on an empty sequence.
    public func sync(_ two: SlipTwoUp?, preview: Timeline) {
        guard let two else { syncTrim(trim); return }   // drag over: back to Trim mode's two-up if it is on
        let tc = Timecode(frameDuration: preview.frameDuration, dropFrame: false)
        show(preview, sequences: session.pushedSnapshot?.sequences ?? [:], head: two.headTime, tail: two.tailTime,
             labels: SlipTwoUpPicture(headTimecode: tc.format(two.headTime), tailTimecode: tc.format(two.tailTime),
                                      offsetFrames: SlipTwoUpLayout.wholeFrames(two.offset, frameDuration: preview.frameDuration)))
    }

    /// Trim mode changed (the app's syncTrimMode): the last frame before the edit and the first after it, the
    /// trimmed side outlined (the Mac `TrimMonitorView`). Not active: hides.
    public func syncTrim(_ trim: TrimModeModel?) {
        self.trim = trim
        guard let trim, trim.isActive, let snap = session.pushedSnapshot else { hide(); return }
        let f = trim.frames
        let tc = Timecode(frameDuration: snap.timeline.frameDuration, dropFrame: false)
        show(snap.timeline, sequences: snap.sequences, head: f.outgoing, tail: f.incoming,
             labels: .trim(outgoingTimecode: f.outgoing.map(tc.format), incomingTimecode: f.incoming.map(tc.format),
                           outgoingActive: trim.side != .incoming, incomingActive: trim.side != .outgoing, note: trim.note))
    }

    /// Both engines on `preview` at `head` / `tail` (nil: that pane stays black).
    private func show(_ preview: Timeline, sequences: [Timeline.ID: Timeline], head: Time?, tail: Time?, labels new: SlipTwoUpPicture) {
        let e = engines ?? makeEngines()
        engines = e
        if shown == nil || shown!.timeline != preview || shown!.sequences != sequences {
            shown = (preview, sequences)
            for engine in [e.head, e.tail] {
                engine.setMedia(session.project.media)
                engine.player.setTimeline(preview, sequences: sequences)
            }
        }
        if let t = head, times?.head != t { e.head.player.seek(to: t) }
        if let t = tail, times?.tail != t { e.tail.player.seek(to: t) }
        if (head == nil) != (times?.head == nil) || (tail == nil) != (times?.tail == nil) { packedFrom = (-2, -2) }
        times = (head, tail)
        var l = new
        l.slot = labels?.slot
        labels = l
    }

    /// Per frame while shown: keeps both engines decoding, packs new pictures; what the monitor panel draws.
    public func tick() -> SlipTwoUpPicture? {
        guard var l = labels, let e = engines else { return nil }
        e.head.tick(); e.tail.tick()
        let gens = (e.head.hasPicture ? e.head.pictureGeneration : -1, e.tail.hasPicture ? e.tail.pictureGeneration : -1)
        if gens != packedFrom, gens.0 >= 0 || gens.1 >= 0 {
            packedFrom = gens
            let head = times?.head == nil ? nil : e.head.scopePicture()?.rgbaImage
            let tail = times?.tail == nil ? nil : e.tail.scopePicture()?.rgbaImage
            let ref = head ?? tail
            let h = min(540, ref?.height ?? 540)
            let w = ref.map { max(1, $0.width * h / max($0.height, 1)) } ?? 960
            generation += 1
            image = (Self.slot, SlipTwoUpLayout.pack(head: head, tail: tail, half: (w, h)), 1_000_000 + generation)
            l.slot = Self.slot
            labels = l
        }
        return l
    }

    private func hide() {
        labels = nil
        image = nil
        times = nil
        packedFrom = (-1, -1)
        guard shown != nil, let e = engines else { return }
        shown = nil
        let empty = Timeline(name: "", frameDuration: Time(1, 30))
        e.head.player.setTimeline(empty, sequences: [:])
        e.tail.player.setTimeline(empty, sequences: [:])
    }

    private func makeEngines() -> (head: any AppMonitorEngine, tail: any AppMonitorEngine) {
        (backend.makeStillEngine(), backend.makeStillEngine())
    }
}

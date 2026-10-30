import Foundation
import SQAnalysis
import SQCore

/// Weak stretches of tracked Magic masks for the timeline's confidence strip (MASK-UX 5.4) and "Go to Next Weak Tracking",
/// by matte cache key. Computed off the main thread from the stored matte areas the first time a key is asked for, then
/// served from memory; `forget` after a Track run so the next ask recomputes. Shared by the AppKit window and the shared
/// window (Mac and Windows); the platform supplies where the matte areas come from (`MagicMatteStore` on the Mac,
/// `FrameMatteStore` on Windows).
@MainActor
public final class MagicTrackHealthCache {
    /// The coverage of every stored frame of a matte key; runs off the main thread.
    public typealias Samples = @Sendable (String) -> [MagicTrackHealth.Sample]

    private var spans: [String: [MagicTrackHealth.Span]] = [:]
    private var pending: Set<String> = []
    private let samples: Samples
    /// Computed spans arrived or were forgotten: the strip draws again.
    public var onChange: (() -> Void)?
    /// `forget` ran: the host drops what else it keeps per key (the Mac's key lanes).
    public var onForget: (() -> Void)?

    public init(samples: @escaping Samples) { self.samples = samples }

    /// The matte cache key of the clip's tracked Magic mask, nil when it has none.
    public func key(for clip: Clip) -> String? {
        guard clip.sequence == nil, !clip.isGenerator, !clip.isStill else { return nil }
        return clip.masks.first(where: { $0.source == .magic && $0.magic?.points.isEmpty == false })?.magic?.cacheKey(media: clip.media)
    }

    /// True while the clip's weak stretches are being computed.
    public func isPending(_ clip: Clip) -> Bool { key(for: clip).map { pending.contains($0) } ?? false }

    /// nil = the clip has no Magic mask with stored mattes (no strip), or the answer is still being computed.
    public func weakSpans(for clip: Clip) -> [MagicTrackHealth.Span]? {
        guard let key = key(for: clip) else { return nil }
        if let s = spans[key] { return s }
        guard pending.insert(key).inserted else { return nil }
        let samples = samples
        Task.detached(priority: .utility) { [weak self] in
            let all = samples(key)
            let weak = all.count >= 3 ? MagicTrackHealth.weakSpans(all) : nil
            await MainActor.run {
                guard let self else { return }
                self.pending.remove(key)
                if let weak { self.spans[key] = weak; self.onChange?() }
            }
        }
        return nil
    }

    /// Tracking changed the mattes: every key is read again on its next ask.
    public func forget() {
        spans.removeAll()
        onForget?()
        onChange?()
    }

    // MARK: Go to Next Weak Tracking

    public enum Jump: Equatable, Sendable {
        case found(Time)
        /// Tracked masks exist but no weak stretch begins after the playhead.
        case none
        case noTrackedMask
        /// A clip's stretches are still being computed (the first ask starts it).
        case pending
    }

    /// "Go to Next Weak Tracking" (Option+Shift+M, Markers menu): where the next weak stretch of a tracked Magic mask begins,
    /// over every video clip of the sequence (the confidence strip's amber stretches).
    public func nextWeakStart(after t: Time, in timeline: Timeline?) -> Jump {
        guard let tl = timeline else { return .noTrackedMask }
        let clips = tl.tracks.flatMap(\.clips).filter { $0.kind == .video && key(for: $0) != nil }
        guard !clips.isEmpty else { return .noTrackedMask }
        if let next = MagicTrackHealth.nextWeakStart(after: t, clips: clips, spans: { self.weakSpans(for: $0) }, frameDuration: tl.frameDuration) {
            return .found(next)
        }
        return clips.contains(where: isPending) ? .pending : .none
    }

    /// The status line of a jump that did not find a stretch; nil when it did.
    public static func message(for jump: Jump) -> String? {
        switch jump {
        case .found: nil
        case .none: "No weak tracking after the playhead."
        case .noTrackedMask: "No tracked Magic mask in this sequence."
        case .pending: "Checking the tracking. Try again in a moment."
        }
    }
}

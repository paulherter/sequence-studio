import AppKit
import SQCore

/// Poster pictures for the thumbnail column of timeline video clips (board `.thh`): one small frame per media item,
/// made once by the same thumbnailer the Project panel uses and cached in memory.
@MainActor
public final class ClipThumbnailSource {
    private let store = ProjectThumbnails()
    /// Called when a requested picture has arrived (the timeline redraws).
    public var onLoad: (() -> Void)?
    /// Pixel height asked for (the column is 38 pt high at most; 2x display).
    private static let height = 96

    public init() {}

    /// The cached picture, or nil while it is being made (then `onLoad` fires).
    public func image(for ref: MediaRef) -> CGImage? {
        store.requestPoster(ref, height: Self.height) { [weak self] in self?.onLoad?() }
        return store.cachedPoster(ref.id)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The frame of `ref` at media time `t` for the thumbnail modes Head and Tail and Continuous: the cached picture, or nil
    /// while it is being made (then `onLoad` fires). Stills and audio have one picture only: the poster.
    public func frame(for ref: MediaRef, at t: Time) -> CGImage? {
        if ref.kind == .image || ref.kind == .audio || ref.info?.isStill == true { return image(for: ref) }
        store.requestPosterAndFrame(ref, frameAt: t, height: Self.height) { [weak self] in self?.onLoad?() }
        return store.cachedFrame(ref.id, at: t, height: Self.height)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    public func forget(_ id: MediaRef.ID) { store.forget(id) }
}

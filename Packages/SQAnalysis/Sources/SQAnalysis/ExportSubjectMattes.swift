import Foundation
import SQCore

/// Export's view of the subject matte store. Export draws person mattes at the accurate quality, so it only reads (and
/// writes) the store under the accurate cache key: mattes precomputed for playback (balanced) are never taken for them.
/// A clip is read from the store only when the stored frames cover its whole source range without a hole (smoothing needs
/// an unbroken frame sequence); otherwise export segments as before and stores what it made, so the next export of the
/// same clip is read.
public struct ExportSubjectMattes: Sendable {
    public let store: MagicMatteStore
    /// The media file behind an id (nil = unknown, nothing is read or stored).
    public let url: @Sendable (UUID) -> URL?
    /// The field order export's decoder deinterlaces that media with (the media item's setting; nil = progressive or
    /// Deinterlace off). Part of the key: mattes of deinterlaced frames are never read for the woven ones or back.
    public let deinterlace: @Sendable (UUID) -> FieldOrder?

    public init(store: MagicMatteStore = SubjectMattePrecompute.sharedStore,
                deinterlace: @escaping @Sendable (UUID) -> FieldOrder? = { _ in nil },
                url: @escaping @Sendable (UUID) -> URL?) {
        self.store = store; self.url = url; self.deinterlace = deinterlace
    }

    public func key(media: UUID) -> String? {
        url(media).map {
            SubjectMattePrecompute.cacheKey(media: media, path: $0.path, quality: .accurate, deinterlace: deinterlace(media))
        }
    }

    /// The store holds every frame of source seconds `from`...`to` of `media`.
    public func covers(media: UUID, from: Double, to: Double) -> Bool {
        guard let k = key(media: media) else { return false }
        store.preload(k)
        return SubjectMattePrecompute.covers(store.times(key: k), from: from, to: to)
    }

    public func matte(media: UUID, pts: Double) -> SubjectMatte? {
        key(media: media).flatMap { store.matte(key: $0, pts: pts) }
    }

    public func put(_ m: SubjectMatte, media: UUID, pts: Double) {
        if let k = key(media: media) { store.put(m, key: k, pts: pts) }
    }

    public func save(media: UUID) {
        if let k = key(media: media) { store.save(key: k) }
    }
}

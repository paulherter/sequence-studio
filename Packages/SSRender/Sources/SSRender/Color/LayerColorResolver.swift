import Foundation
import SSCore
import Synchronization

/// Turns a layer's `ClipColor` + its media into the `ColorPipeline` the compositor needs, once per distinct
/// (clip colour, media, detected properties) and cached. Shared by playback and export.
/// Returns nil (identity fast path) when the layer is plain Rec.709 with no correction and no LUT: the compositor then
/// takes its cheap inverse-OETF path and never allocates the colour intermediate.
public final class LayerColorResolver: Sendable {
    public typealias MediaInfoLookup = @Sendable (UUID) -> MediaInfo?

    private struct Key: Hashable {
        var color: ClipColor
        var media: UUID
        var space: ColorSpaceID?
        var embeddedLUT: String?
    }

    private let lutProvider: (any LUTProvider)?
    private let mediaInfo: MediaInfoLookup
    private let cache = Mutex<[Key: ColorPipeline?]>([:])
    private static let cacheLimit = 256
    /// `SS_COLOR_LOG=1`: logs each newly built pipeline (diagnostics).
    private static let logging = ProcessInfo.processInfo.environment["SS_COLOR_LOG"] == "1"

    public init(lutProvider: (any LUTProvider)?, mediaInfo: @escaping MediaInfoLookup) {
        self.lutProvider = lutProvider; self.mediaInfo = mediaInfo
    }

    /// nil = identity Rec.709 (use the fast path).
    public func pipeline(for color: ClipColor, media: UUID) -> ColorPipeline? {
        let info = mediaInfo(media)
        // Default settings on Rec.709 media: nothing to do (automatic embedded LUT applies to S-Log3 only).
        if color.isDefault, (info?.colorSpace ?? .rec709) == .rec709 { return nil }
        let key = Key(color: color, media: media, space: info?.detectedColorSpace, embeddedLUT: info?.embeddedLUTName)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let built = ColorPipeline.from(clipColor: color, mediaID: media, mediaInfo: info, lutProvider: lutProvider)
        let result: ColorPipeline? = Self.isIdentity(built) ? nil : built
        if Self.logging {
            let what = result.map { "\($0.source) conversionLUT=\($0.conversionLUT?.title ?? "none") creative=\($0.creativeLUT?.title ?? "none")" }
            NSLog("COLOR: media=\(media) pipeline=\(what ?? "identity")")
        }
        cache.withLock { c in
            if c.count >= Self.cacheLimit { c.removeAll() }
            c[key] = .some(result)
        }
        return result
    }

    /// Number of cached entries (tests).
    var cachedCount: Int { cache.withLock { $0.count } }

    /// Drops cached pipelines (media relinked, LUT file changed).
    public func invalidate() {
        cache.withLock { $0.removeAll() }
    }

    static func isIdentity(_ p: ColorPipeline) -> Bool {
        p.source == .rec709 && p.correction.isNeutral && p.conversionLUT == nil
            && (p.creativeLUT == nil || p.creativeIntensity <= 0)
    }
}

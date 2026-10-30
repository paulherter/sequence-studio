import CoreMedia
import Foundation
import SQCore
import SQMedia

/// Rules for decoding a proxy instead of the original (monitor and, with "use proxies for export", the export render).
public enum ProxyPicture {
    /// A proxy may stand in for the original only when it has the same frames: same count and same first and last
    /// presentation time. Otherwise edit points would shift, so the original is used.
    public static func hasOriginalFrameTimes(proxy: SampleIndex, original: SampleIndex) -> Bool {
        let a = proxy.entries, b = original.entries
        return !a.isEmpty && a.count == b.count && a.first?.pts == b.first?.pts && a.last?.pts == b.last?.pts
    }

    /// Track info of a proxy frame: geometry and color tags of the original (see `RenderLoop.proxyInfo`).
    public static func info(of proxy: VideoTrackInfo, original: any Demuxing) -> VideoTrackInfo {
        RenderLoop.proxyInfo(proxy, original: nil, originalFormat: original.formatDescription, rotation: original.rotation)
    }
}

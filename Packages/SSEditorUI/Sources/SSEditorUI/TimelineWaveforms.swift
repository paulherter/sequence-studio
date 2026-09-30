import Foundation
import SSCore
import SSMedia

/// Waveform peaks for the audio clips on the timeline. Every import path ends with a clip on the timeline, so the
/// timeline asks for what it shows (`ensure`) and redraws through `onReady` when a build finishes.
@MainActor
public final class TimelineWaveforms {
    public typealias Builder = @Sendable (URL) async throws -> WaveformData

    public private(set) var data: [UUID: WaveformData] = [:]
    public let cache = WaveformCache()
    /// Called on the main actor after new peaks arrived.
    public var onReady: (() -> Void)?
    private var pending: Set<UUID> = []
    private var failed: Set<UUID> = []
    private let builder: Builder

    public init(builder: @escaping Builder = { try await WaveformBuilder.build(url: $0) }) { self.builder = builder }

    public var pendingCount: Int { pending.count }

    /// Starts a build for every media item used by an audio clip of `timeline` that has none yet.
    public func ensure(timeline: Timeline, project: Project) {
        for track in timeline.tracks where track.kind == .audio {
            for clip in track.clips { request(clip.media, project: project) }
        }
    }

    public func request(_ id: UUID, project: Project) {
        guard data[id] == nil, !pending.contains(id), !failed.contains(id),
              let ref = project.media(id), ref.info?.audio != nil || ref.info == nil else { return }
        pending.insert(id)
        let url = URL(fileURLWithPath: ref.path)
        let builder = self.builder
        let name = ref.name
        Task { [weak self] in
            let result = try? await builder(url)
            guard let self else { return }
            pending.remove(id)
            if let result {
                data[id] = result
                NSLog("Waveform ready for \(name) (\(result.totalFrames) frames)")
                onReady?()
            } else {
                failed.insert(id)
                NSLog("Waveform failed for \(name)")
            }
        }
    }

    /// Forget a media item (relinked or replaced file).
    public func invalidate(_ id: UUID) {
        data[id] = nil; failed.remove(id); cache.remove(media: id)
    }
}

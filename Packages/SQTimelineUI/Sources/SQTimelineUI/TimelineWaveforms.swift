import Foundation
import SQCore
import SQMedia
import SQPlayback

/// Waveform peaks for the audio clips on the timeline. Every import path ends with a clip on the timeline, so the
/// timeline asks for what it shows (`ensure`) and redraws through `onReady` when a build finishes.
@MainActor
public final class TimelineWaveforms {
    public typealias Builder = @Sendable (URL) async throws -> WaveformData

    public private(set) var data: [UUID: WaveformData] = [:]
    public let cache = WaveformCache()
    /// N8b: the same peaks as dialogue pauses for live ducking (playback, scrub and export read it off the main actor).
    public let silences = WaveformSilences()
    /// Called on the main actor after new peaks arrived.
    public var onReady: (() -> Void)?
    /// More listeners (the Source monitor's audio-only view); called with the media id after `onReady`.
    private var observers: [(UUID) -> Void] = []
    public func addObserver(_ f: @escaping (UUID) -> Void) { observers.append(f) }
    private var pending: Set<UUID> = []
    /// Pending builds that run on the urgent lane.
    private var urgentBuilds: Set<UUID> = []
    /// The running build per media (awaited by `prepareDialogue`).
    private var builds: [UUID: Task<Void, Never>] = [:]
    private var failed: Set<UUID> = []
    /// Bumped by `invalidate`: a build that started before it must not store its (old file's) peaks.
    private var generation: [UUID: Int] = [:]
    /// F7.10: the channel map (nil = the file's layout) the peaks of a media item were built or are being built with.
    private var maps: [UUID: AudioChannelMap?] = [:]
    private let builder: @Sendable (URL, AudioChannelMap?, Int?) async throws -> WaveformData

    /// The default builder draws the channels the media item plays; an injected one (tests) gets the file only.
    public init(builder: Builder? = nil) {
        if let builder { self.builder = { url, _, _ in try await builder(url) } } else {
            self.builder = { try await WaveformBuilder.build(url: $0, channelMap: $1, expectedChannels: $2) }
        }
    }

    public var pendingCount: Int { pending.count }

    /// Starts a build for every media item used by an audio clip of `timeline` that has none yet.
    public func ensure(timeline: Timeline, project: Project) {
        syncChannelMaps(project: project)
        var clips: Set<Clip.ID> = []
        for track in timeline.tracks where track.kind == .audio {
            for clip in track.clips {
                request(clip.media, project: project); clips.insert(clip.id)
                // An Angles piece draws the waveform of the angle it plays (`Clip.angleProxy`).
                if clip.isAnglesClip, let inner = clip.sequence.flatMap({ project.timeline($0) }) {
                    for t in clip.angleView(of: inner).tracks where t.kind == .audio { for ic in t.clips { request(ic.media, project: project) } }
                }
            }
        }
        silences.prune(keeping: clips)          // deleted / replaced clips leave the pause cache
    }

    /// N8b: export and bake hear the dialogue pauses even right after open or for a sequence never shown: builds (or waits
    /// for) the waveform of every dialogue clip `timeline` ducks with, then returns the pause provider. Media that cannot be
    /// analyzed stay unknown, so their clips duck whole (fail safe).
    public func prepareDialogue(of timeline: Timeline, project: Project) async -> WaveformSilences {
        for id in LiveDucking.dialogueMedia(in: timeline) {
            request(id, project: project)
            await builds[id]?.value
        }
        return silences
    }

    /// F7.10: peaks built for other channels than the media item plays now are dropped and built again (the timeline
    /// and the Source monitor then draw what is heard). One pass over the media, nothing to do while no map changed.
    public func syncChannelMaps(project: Project) {
        guard !maps.isEmpty else { return }
        for m in project.media {
            guard let used = maps[m.id], used != m.info?.audio?.channelMap else { continue }
            invalidate(m.id)
            request(m.id, project: project)
        }
    }

    /// `urgent`: the media the user looks at right now (Source monitor audio view). Its build runs on `BlockingLane`'s
    /// urgent queue, ahead of every waiting import / timeline build; a normal build of the same media that is still
    /// pending is superseded (restarted urgent, its late result ignored).
    public func request(_ id: UUID, project: Project, urgent: Bool = false) {
        guard data[id] == nil, !failed.contains(id),
              let ref = project.media(id), ref.info?.audio != nil || ref.info == nil else { return }
        if pending.contains(id) {
            guard urgent, !urgentBuilds.contains(id) else { return }
            generation[id, default: 0] += 1
            builds[id]?.cancel()
        }
        pending.insert(id)
        if urgent { urgentBuilds.insert(id) }
        let url = URL(fileURLWithPath: ref.path)
        let builder = self.builder
        let name = ref.name
        let gen = generation[id, default: 0]
        let map = ref.info?.audio?.channelMap
        let expected = ref.info?.audio?.channels
        maps[id] = .some(map)
        builds[id] = Task { [weak self] in
            let result = await BlockingLane.$urgent.withValue(urgent) { try? await builder(url, map, expected) }
            guard let self, generation[id, default: 0] == gen else { return }     // invalidated / superseded meanwhile
            pending.remove(id); urgentBuilds.remove(id); builds[id] = nil
            if let result {
                data[id] = result
                silences.setWaveform(result, for: id)
                NSLog("Waveform ready for \(name) (\(result.totalFrames) frames)")
                onReady?()
                for f in observers { f(id) }
            } else {
                failed.insert(id)
                NSLog("Waveform failed for \(name)")
            }
        }
    }

    /// Stores peaks directly (tests and benchmarks; the app goes through `request`).
    func setData(_ d: WaveformData, for id: UUID) { data[id] = d; silences.setWaveform(d, for: id) }

    /// Forget a media item (relinked or replaced file).
    public func invalidate(_ id: UUID) {
        generation[id, default: 0] += 1
        data[id] = nil; silences.setWaveform(nil, for: id); failed.remove(id); pending.remove(id); urgentBuilds.remove(id); builds[id] = nil; cache.remove(media: id)
        maps[id] = nil
    }
}

import Foundation
import SQCore
import SQLibrary

/// When the growing-file poll looks at the disk. Pure, so the "cheap timer" rules are testable.
public enum GrowingFilePolicy {
    /// Seconds between looks while nothing happens.
    public static let activeInterval: TimeInterval = 3
    /// While playing or exporting no `stat` runs; the timer only checks back this often.
    public static let busyInterval: TimeInterval = 10
    public static let exportInterval: TimeInterval = 20
    /// After this many looks without a change the interval grows to `calmInterval`.
    public static let quietPollsBeforeBackoff = 20
    public static let calmInterval: TimeInterval = 10

    /// `poll`: look at the files now; `next`: seconds until the next decision.
    public static func decide(enabled: Bool, onlineCount: Int, isPlaying: Bool, isExporting: Bool,
                              quietPolls: Int) -> (poll: Bool, next: TimeInterval) {
        guard enabled, onlineCount > 0 else { return (false, busyInterval) }
        if isExporting { return (false, exportInterval) }
        if isPlaying { return (false, busyInterval) }
        return (true, quietPolls >= quietPollsBeforeBackoff ? calmInterval : activeInterval)
    }
}

public enum GrowingFileProbe {
    /// The item as it is after a re-probe of its changed file: new probe info, length and size/date stamp. The hash of the
    /// first bytes and everything else stays.
    public static func refreshed(_ ref: MediaRef, info: MediaInfo, stamp: MediaFileStamp?) -> MediaRef {
        var r = ref
        r.info = info
        r.duration = info.duration
        if let stamp { r.fingerprint.size = stamp.size; r.fingerprint.modified = stamp.modified }
        return r
    }
}

extension EditorSession {
    /// One step of the growing-file timer (footage still being recorded or re-rendered over its path). Stats the online
    /// files in one batch off the main thread; a file whose size or date changed gets its decoders, thumbnails and
    /// waveform dropped (`refreshMediaFromDisk`) and is probed again for its new length. Skips offline items, and does
    /// nothing while playing, exporting or switched off. Returns the seconds until the next tick.
    @discardableResult
    public func growingFileTick(enabled: Bool, isExporting: Bool) async -> TimeInterval {
        guard !growPollRunning else { return GrowingFilePolicy.activeInterval }
        growPollRunning = true
        defer { growPollRunning = false }
        if diskTracker.knownCount == 0, !project.media.isEmpty, enabled { await refreshMediaFromDisk() }   // baseline
        let online = project.media.filter { diskTracker.isOnline($0.id) && $0.info?.isStill != true }
        let plan = GrowingFilePolicy.decide(enabled: enabled, onlineCount: online.count, isPlaying: isPlaying,
                                            isExporting: isExporting, quietPolls: growQuietPolls)
        guard plan.poll else {
            if !enabled { growTracker = MediaFileStampTracker() }
            return plan.next
        }
        let projectID = project.id
        let urls = Set(online.map { URL(fileURLWithPath: $0.path) })
        var tracker = growTracker
        let result = await Task.detached(priority: .utility) { () -> (MediaFileStampTracker, [URL]) in
            tracker.setTracked(urls)
            return (tracker, tracker.poll())
        }.value
        guard project.id == projectID else { return plan.next }
        growTracker = result.0
        let changedPaths = Set(result.1.map(\.path))
        guard !changedPaths.isEmpty else {
            growQuietPolls += 1
            return plan.next
        }
        growQuietPolls = 0
        let ids = online.filter { changedPaths.contains($0.path) }.map(\.id)
        await refreshMediaFromDisk()
        await reprobeMedia(ids, projectID: projectID)
        return GrowingFilePolicy.activeInterval
    }

    /// Probes `ids` again and folds the new info, length and stamp into the project (no undo step, like the other
    /// probe refreshes). A file that cannot be read yet (still being written) keeps its old info and is tried again at
    /// its next change.
    private func reprobeMedia(_ ids: [MediaRef.ID], projectID: UUID) async {
        let probe = mediaInfoProbe
        var found: [MediaRef.ID: (info: MediaInfo, stamp: MediaFileStamp?)] = [:]
        for id in ids {
            guard let ref = project.media(id), let info = await probe(URL(fileURLWithPath: ref.path)) else { continue }
            found[id] = (info, MediaFileStamp.read(URL(fileURLWithPath: ref.path)))
        }
        guard project.id == projectID else { return }
        foldRefreshedProbes(found)
    }
}

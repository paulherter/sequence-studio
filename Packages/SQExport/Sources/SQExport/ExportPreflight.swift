#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation
import SQCore

/// Checks that run before an export starts (so the user decides first) and the friendly text for a failed one.
public enum ExportPreflight {
    /// Files an export of `jobs` would overwrite: the exact `<name>.<ext>` (and sidecar `.srt`) already in the folder.
    /// Without a choice the queue keeps both (`name 2.mp4`); with `replaceExisting` the old file is replaced.
    public static func existingTargets(of jobs: [ExportJob], fileManager: FileManager = .default) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        for job in jobs {
            let stem = ExportQueue.sanitize(job.name)
            var exts = [job.settings.fileExtension]
            if let e = job.settings.captions.sidecarExtension { exts.append(e) }
            for e in exts {
                let url = job.outputDirectory.appendingPathComponent("\(stem).\(e)")
                if fileManager.fileExists(atPath: url.path), seen.insert(url.standardizedFileURL.path.lowercased()).inserted {
                    out.append(url)
                }
            }
        }
        return out
    }

    /// Media of the sequence (and every sequence nested in it) that its clips use.
    static func usedMedia(in sequence: Timeline.ID, project: Project) -> [MediaRef] {
        var ids = Set<Timeline.ID>([sequence])
        ids.formUnion(project.reachableSequences(from: sequence))
        var used = Set<UUID>()
        for t in project.timelines where ids.contains(t.id) {
            for track in t.tracks { for clip in track.clips where clip.sequence == nil { used.insert(clip.media) } }
        }
        return project.media.filter { used.contains($0.id) }
    }

    /// Media files of the sequence (and every sequence nested in it) that are not at their path.
    public static func offlineMedia(in sequence: Timeline.ID, project: Project, fileManager: FileManager = .default) -> [MediaRef] {
        usedMedia(in: sequence, project: project).filter { $0.status(fileManager: fileManager) == .missing }
    }

    /// Used media whose source is HDR (HLG / PQ). The export is Rec. 709 only, so these are tone-mapped down.
    public static func hdrMedia(in sequence: Timeline.ID, project: Project) -> [MediaRef] {
        usedMedia(in: sequence, project: project).filter { $0.info?.colorSpace.isHDR == true }
    }

    /// Extensions AVFoundation opens itself: only these can be judged unreadable here (other containers have their own
    /// demuxer, which this check must not second-guess).
    private static let probeExtensions: Set<String> = ["mov", "mp4", "m4v", "m4a", "wav", "aif", "aiff", "caf", "mp3"]

    /// Media the export would hit as damaged frames: files that are there but empty, or that AVFoundation-native
    /// containers cannot open or show no track in. Offline (missing) files are `offlineMedia`, not listed here.
    public static func unreadableMedia(in sequence: Timeline.ID, project: Project, fileManager: FileManager = .default) async -> [MediaRef] {
        var out: [MediaRef] = []
        for m in usedMedia(in: sequence, project: project) {
            guard let attrs = try? fileManager.attributesOfItem(atPath: m.path) else { continue }   // missing
            if ((attrs[.size] as? NSNumber)?.int64Value ?? 0) == 0 { out.append(m); continue }
            guard probeExtensions.contains(URL(fileURLWithPath: m.path).pathExtension.lowercased()) else { continue }
            #if canImport(AVFoundation)
            let asset = AVURLAsset(url: URL(fileURLWithPath: m.path))
            let readable = (try? await asset.load(.isReadable)) ?? false
            let tracks = readable ? ((try? await asset.load(.tracks)) ?? []) : []
            if !readable || tracks.isEmpty { out.append(m) }
            #endif
            // shortcut: off the Mac only empty files count as unreadable; upgrade with an FFmpeg probe in SQMediaFFmpeg.
        }
        return out
    }

    public enum SpaceVerdict: Sendable, Equatable { case ok, tight, insufficient }

    /// The estimate against the free bytes: `tight` when less than 20 % of the estimate would be left over.
    public static func spaceVerdict(freeBytes: Int64?, estimatedBytes: Int64) -> SpaceVerdict {
        guard let free = freeBytes else { return .ok }
        if free < estimatedBytes { return .insufficient }
        return Double(free - estimatedBytes) < 0.2 * Double(estimatedBytes) ? .tight : .ok
    }

    /// A running export stops when the output volume has less than this left.
    public static let runningFloorBytes: Int64 = 200_000_000

    public static func ranOutOfSpaceMessage(freeBytes: Int64?) -> String {
        guard let free = freeBytes else {
            return "The output disk ran out of space. The export stopped and the partial file was removed. Free some space and export again."
        }
        let left = String(format: "%.0f", Double(max(0, free)) / 1_000_000)
        return "The output disk ran out of space (\(left) MB left). The export stopped and the partial file was removed. Free some space and export again."
    }

    /// Free bytes (for important usage) on the volume of `folder`; nil when unknown.
    public static func freeBytes(at folder: URL) -> Int64? {
        #if os(macOS)
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        #else
        // shortcut: unknown free space off the Mac (no low-space stop); upgrade with GetDiskFreeSpaceExW on Windows.
        nil
        #endif
    }

    /// Below this the volume counts as full when a write failed.
    static let lowSpaceBytes: Int64 = 100_000_000

    /// Text for a failed job. A disk-full error (or any write failure on a nearly full volume) says so in plain words.
    public static func failureMessage(_ error: any Error, freeBytes: Int64?) -> String {
        let ns = error as NSError
        let outOfSpace = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
            || (ns.domain == "AVFoundationErrorDomain" && ns.code == -11807)
        var lowAndWriteFailed = false
        if case ExportError.writerFailed = error, let free = freeBytes, free < lowSpaceBytes { lowAndWriteFailed = true }
        if outOfSpace || lowAndWriteFailed {
            return "The disk is full. Free some space on the output volume and export again."
        }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

import Foundation
import SQCore
import SQExport
import SQPlayback

/// Extract Audio: the sound of a media item as its own M4A file, which then becomes a Project item ("Name (audio)").
public enum AudioExtraction {
    public enum Failure: Error, Sendable, Equatable { case noAudio, offline }

    /// "Name (audio).m4a" in `folder`; "Name (audio 2).m4a"... when taken. The media's own extension is dropped.
    public static func destination(for ref: MediaRef, in folder: URL, fileManager: FileManager = .default) -> URL {
        var stem = (ref.name as NSString).deletingPathExtension
        if stem.isEmpty { stem = "Audio" }
        stem = stem.replacingOccurrences(of: "/", with: "-")
        var n = 1
        while true {
            let name = n == 1 ? "\(stem) (audio).m4a" : "\(stem) (audio \(n)).m4a"
            let url = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// The one-clip sequence the writer mixes: the whole sound of `ref`, nothing else.
    static func timeline(for ref: MediaRef, duration: Time) throws -> Timeline {
        var tracks = Timeline.defaultTracks(video: 1, audio: 1)
        guard let a = tracks.firstIndex(where: { $0.kind == .audio }) else { throw Failure.noAudio }
        try tracks[a].overwrite(Clip(name: ref.name, media: ref.id, kind: .audio,
                                     source: TimeRange(start: .zero, duration: duration), start: .zero))
        let rate = ref.info?.audio?.sampleRate ?? 48_000
        let format = SequenceFormat(width: 16, height: 16, frameDuration: Time(1, 30), audioSampleRate: rate > 0 ? rate : 48_000)
        return Timeline(name: ref.name, format: format, tracks: tracks)
    }

    /// Writes the sound of `ref` to `url` (M4A, AAC 192 kbit/s, stereo). The file is removed again on failure or cancel.
    public static func write(_ ref: MediaRef, resolver: any MediaResolver, to url: URL,
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let info = ref.info, info.audio != nil else { throw Failure.noAudio }
        guard let duration = ref.duration ?? Optional(info.duration), duration.value > 0 else { throw Failure.noAudio }
        let t = try timeline(for: ref, duration: duration)
        var s = ExportSettings()
        s.audioOnly = .m4a
        s.video.width = 16; s.video.height = 16
        s.video.frameDuration = t.format.frameDuration
        s.audio.sampleRate = t.format.audioSampleRate
        let sources = try ExportSourceBuilder.make(timeline: t, sequences: [:], settings: s, resolver: resolver)
        do {
            try await ExportWriter.export(video: sources.video, audio: sources.audio, settings: s, to: url, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

extension ProjectPanelModel {
    /// Extract Audio to a library item: writes "Name (audio).m4a" into `folder` (default: the project folder, else next
    /// to the source file) and imports it into the current bin. Returns the new item, nil when it was not imported.
    @discardableResult
    public func extractAudio(of id: MediaRef.ID, resolver: any MediaResolver, folder: URL? = nil) async throws -> MediaRef.ID? {
        guard let ref = project.media(id) else { return nil }
        guard !isOffline(id) else { throw AudioExtraction.Failure.offline }
        let dir = folder ?? projectFolder?() ?? URL(fileURLWithPath: ref.path).deletingLastPathComponent()
        let url = AudioExtraction.destination(for: ref, in: dir)
        try await AudioExtraction.write(ref, resolver: resolver, to: url)
        await importFiles([url])
        return mediaID(forImported: url)
    }
}

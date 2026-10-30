import Foundation
import SQCore

/// Writes the stems of `StemPlan` as audio files next to each other: one file per role plus the M&E mix.
public enum StemExporter {
    public struct Written: Sendable, Equatable {
        public var stem: StemPlan.Stem
        public var url: URL
    }

    /// `audioFor` builds the mix source of a stem's timeline (muted tracks stay silent, so each file is the mix by role).
    /// Files are `<base>_<suffix>.<ext>` in `directory`, written by `encoder` (Mac `AVExportEncoder`, Windows
    /// `FFmpegExportEncoder`); `progress` is 0...1 over all stems.
    @discardableResult
    public static func export(
        stems: [StemPlan.Stem], base: String, directory: URL, format: AudioFileFormat, duration: Time,
        settings: AudioSettings, encoder: any ExportEncoding, audioFor: @Sendable (StemPlan.Stem) throws -> any AudioSource,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Written] {
        let names = StemPlan.fileNames(base: base, stems: stems, ext: format.fileExtension)
        var out: [Written] = []
        let n = Double(stems.count)
        for (i, stem) in stems.enumerated() {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(names[i])
            let done = Double(i)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            _ = try await encoder.exportAudioFile(try audioFor(stem), format: format, duration: duration, settings: settings, to: url) {
                progress((done + $0) / n)
            }
            out.append(Written(stem: stem, url: url))
        }
        progress(1)
        return out
    }
}

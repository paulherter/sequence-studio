import AVFoundation
import Foundation

/// SpeechAnalyzer reads an `AVAudioFile`. Audio files and most mp4/mov open directly; anything else (other
/// containers, odd codecs, several tracks) is exported to a temporary m4a first.
enum AudioExtraction {
    struct Source { var url: URL; var isTemporary: Bool }

    static func readableAudio(at url: URL) async throws -> Source {
        if (try? AVAudioFile(forReading: url)) != nil { return Source(url: url, isTemporary: false) }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            throw TranscriptionError.noAudio
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.noAudio
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ss-transcribe-\(UUID().uuidString).m4a")
        do { try await export.export(to: out, as: .m4a) } catch {
            try? FileManager.default.removeItem(at: out)   // a failed or cancelled export may leave a partial file
            throw error
        }
        return Source(url: out, isTemporary: true)
    }
}

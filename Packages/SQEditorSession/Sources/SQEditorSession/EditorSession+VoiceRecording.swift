import Foundation
import SQCore
import SQMedia
import SQPlayback

/// What one press of Record Voice-Over did.
public enum VoiceRecordingStep: Equatable, Sendable {
    /// The countdown ran out and the microphone is recording.
    case started
    /// The take was imported and placed.
    case placed(VoiceoverPlacement)
    /// A countdown or recording was dropped.
    case canceled
    /// The microphone is not allowed (System Settings > Privacy & Security > Microphone).
    case denied
    case failed(String)
}

extension EditorSession {
    /// Shortest take that is kept.
    public static let minimumVoiceRecording = Time(1, 10)

    /// Record Voice-Over, one command: idle starts (access, countdown, record from the playhead while the sequence plays),
    /// during the countdown it cancels, while recording it stops, imports the take through `importer` and places it as a
    /// voiceover at the time recording began. Returns when that step is done (a start returns after the countdown).
    @discardableResult
    public func toggleVoiceRecording(folder: URL, importer: (URL) async -> MediaRef.ID?) async -> VoiceRecordingStep {
        switch voiceRecorder.state {
        case .recording: return await finishVoiceRecording(importer: importer)
        case .requestingAccess, .countdown: voiceRecorder.cancel(); return .canceled
        case .idle: return await startVoiceRecording(folder: folder)
        }
    }

    /// Drops a countdown or a running take (and its file).
    public func cancelVoiceRecording() {
        guard voiceRecorder.isBusy else { return }
        voiceRecorder.cancel()
        stopPlayback()
    }

    private func startVoiceRecording(folder: URL) async -> VoiceRecordingStep {
        guard activeTimelineID != nil else { setError("Open a sequence first."); return .failed("Open a sequence first.") }
        stopPlayback()
        let taken = Set(project.media.map { ($0.path as NSString).lastPathComponent })
            .union((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var name = "Voice-Over.wav", n = 2
        while taken.contains(name) { name = "Voice-Over \(n).wav"; n += 1 }
        let anchor = playhead
        do { try await voiceRecorder.start(to: folder.appendingPathComponent(name), anchor: anchor) }
        catch VoiceRecorderError.canceled { return .canceled }
        catch VoiceRecorderError.accessDenied { return .denied }
        catch { setError("Could not start the microphone."); return .failed("Could not start the microphone.") }
        // Voice-over to picture: the sequence plays from the start point while the take runs (unless it is at the very end).
        if anchor < monitorDuration { playPause() }
        return .started
    }

    private func finishVoiceRecording(importer: (URL) async -> MediaRef.ID?) async -> VoiceRecordingStep {
        stopPlayback()
        let take: VoiceRecording
        do { take = try voiceRecorder.stop() } catch { setError("The recording failed."); return .failed("The recording failed.") }
        guard take.duration >= Self.minimumVoiceRecording else {
            try? FileManager.default.removeItem(at: take.url)
            setError("The recording was too short.")
            return .failed("The recording was too short.")
        }
        guard let media = await importer(take.url) else {
            setError("Could not import the recording.")
            return .failed("Could not import the recording.")
        }
        let clipName = (take.url.lastPathComponent as NSString).deletingPathExtension
        guard let placed = placeVoiceover(media: media, name: clipName, duration: take.duration, at: take.anchor) else {
            return .failed(lastError ?? "Could not place the recording.")
        }
        return .placed(placed)
    }
}

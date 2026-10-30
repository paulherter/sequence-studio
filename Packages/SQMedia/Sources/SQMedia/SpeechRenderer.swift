import AVFoundation
import Foundation
import SQCore

/// One installed system voice, as the voiceover dialog lists it.
public struct SpeechVoice: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var language: String
    /// Enhanced or premium quality download.
    public var isEnhanced: Bool
}

public enum SpeechError: Error, Sendable, Equatable {
    case noVoice, emptyText, noAudio, timedOut
}

/// On-device text to speech: renders a script with `AVSpeechSynthesizer.write(_:toBufferCallback:)` into a CAF file. Nothing
/// is sent anywhere. The result is an ordinary audio file that the project imports like any other media.
public enum SpeechRenderer {
    /// Installed voices, the current language first, then by name.
    public static func voices() -> [SpeechVoice] {
        let own = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices().map {
            SpeechVoice(id: $0.identifier, name: $0.name, language: $0.language, isEnhanced: $0.quality != .default)
        }.sorted {
            let a = $0.language.hasPrefix(own), b = $1.language.hasPrefix(own)
            if a != b { return a }
            return ($0.language, $0.name) < ($1.language, $1.name)
        }
    }

    /// The voice to preselect: the one used last, else the first of the current language.
    public static func defaultVoiceID(in list: [SpeechVoice], remembered: String?) -> String? {
        if let remembered, list.contains(where: { $0.id == remembered }) { return remembered }
        return list.first?.id
    }

    /// Speaks `text` with `voiceID` at `rate` (0...1, 0.5 = normal) into `url` (CAF, the voice's own sample rate). Returns the
    /// length written. The partial file is removed on failure.
    @MainActor
    public static func render(text: String, voiceID: String, rate: Double, to url: URL, timeout: TimeInterval = 300) async throws -> Time {
        let script = Voiceover.cleaned(text)
        guard !script.isEmpty else { throw SpeechError.emptyText }
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { throw SpeechError.noVoice }
        let utterance = AVSpeechUtterance(string: script)
        utterance.voice = voice
        utterance.rate = Float(Voiceover.clampedRate(rate))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let job = Job(url: url)
        do {
            let result: Time = try await withCheckedThrowingContinuation { cont in
                job.start(utterance: utterance, timeout: timeout, continuation: cont)
            }
            return result
        } catch {
            job.cancel()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Owns the synthesizer and the file for one render. The buffer callback arrives on a background queue, so the state is locked.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private let url: URL
        private var synth: AVSpeechSynthesizer?
        private var file: AVAudioFile?
        private var frames: Int64 = 0
        private var rate = 0
        private var cont: CheckedContinuation<Time, Error>?

        init(url: URL) { self.url = url }

        func start(utterance: AVSpeechUtterance, timeout: TimeInterval, continuation: CheckedContinuation<Time, Error>) {
            lock.lock()
            cont = continuation
            let s = AVSpeechSynthesizer()
            synth = s
            lock.unlock()
            s.write(utterance) { [self] buffer in handle(buffer) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in finish(.failure(SpeechError.timedOut)) }
        }

        func cancel() { finish(.failure(CancellationError())) }

        private func handle(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            lock.lock()
            defer { lock.unlock() }
            guard cont != nil else { return }
            if pcm.frameLength == 0 {                        // end marker
                complete()
                return
            }
            do {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat,
                                           interleaved: pcm.format.isInterleaved)
                    rate = Int(pcm.format.sampleRate.rounded())
                }
                try file?.write(from: pcm)
                frames += Int64(pcm.frameLength)
            } catch {
                resume(.failure(error))
            }
        }

        /// Called with the lock held.
        private func complete() {
            guard frames > 0, rate > 0 else { resume(.failure(SpeechError.noAudio)); return }
            resume(.success(Time(frames, Int64(rate))))
        }

        private func finish(_ r: Result<Time, Error>) {
            lock.lock()
            defer { lock.unlock() }
            resume(r)
        }

        /// Called with the lock held; closes the file so it can be read as soon as the continuation resumes.
        private func resume(_ r: Result<Time, Error>) {
            guard let c = cont else { return }
            cont = nil
            file = nil
            synth?.stopSpeaking(at: .immediate)
            synth = nil
            c.resume(with: r)
        }
    }
}

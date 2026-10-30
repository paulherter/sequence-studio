internal import CSQWhisper
import Foundation

/// whisper.cpp behind `WhisperEngine`: `whisper.dll` is loaded at run time (CSQWhisper), so the app starts without it and the
/// Transcribe tab says what is missing. Off Windows the C layer reports "not available" (the Mac uses the Speech framework).
public final class WhisperRuntime: WhisperEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var context: OpaquePointer?
    private var contextPath: String?
    private var loadError: String?
    private let folder: String?

    /// `folder`: where whisper.dll lives (nil: beside the exe, `SQ_WHISPER_DIR`, then PATH).
    public init(folder: String? = nil) { self.folder = folder }

    deinit { if let context { sqwh_close(context) } }

    public func unavailableReason() -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> String? {
        if sqwh_available() != 0 { return nil }
        var err = [CChar](repeating: 0, count: 256)
        if sqwh_load(folder, &err, Int32(err.count)) == 0 { return nil }
        return String(cString: err)
    }

    private final class Callbacks {
        let progress: @Sendable (Double) -> Void
        let isCancelled: @Sendable () -> Bool
        init(progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool) {
            self.progress = progress; self.isCancelled = isCancelled
        }
    }

    public func recognize(modelPath: String, samples: [Float], language: String, progress: @Sendable (Double) -> Void,
                          isCancelled: @Sendable () -> Bool) throws -> [WhisperToken] {
        lock.lock(); defer { lock.unlock() }       // one run at a time: a context is not thread safe
        if let why = loadLocked() { throw TranscriptionError.engineMissing(why) }
        var err = [CChar](repeating: 0, count: 256)
        if contextPath != modelPath {
            if let context { sqwh_close(context) }
            context = nil; contextPath = nil
            guard let c = sqwh_open(modelPath, 0, &err, Int32(err.count)) else { throw TranscriptionError.engineMissing(String(cString: err)) }
            context = c; contextPath = modelPath
        }
        guard let ctx = context else { throw TranscriptionError.engineMissing("no model loaded") }
        let threads = Int32(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 1)))
        let result: Int32 = withoutActuallyEscaping(progress) { progress in
            withoutActuallyEscaping(isCancelled) { isCancelled in
                let box = Callbacks(progress: progress, isCancelled: isCancelled)
                return withExtendedLifetime(box) {
                    samples.withUnsafeBufferPointer { buf in
                        sqwh_run(ctx, buf.baseAddress, Int32(buf.count), language, threads,
                                 { percent, user in
                                     guard let user else { return }
                                     Unmanaged<Callbacks>.fromOpaque(user).takeUnretainedValue().progress(Double(percent) / 100)
                                 },
                                 { user in
                                     guard let user else { return 0 }
                                     return Unmanaged<Callbacks>.fromOpaque(user).takeUnretainedValue().isCancelled() ? 1 : 0
                                 },
                                 Unmanaged.passUnretained(box).toOpaque(), &err, Int32(err.count))
                    }
                }
            }
        }
        if result == 2 { throw CancellationError() }
        guard result == 0 else { throw TranscriptionError.engineMissing(String(cString: err)) }
        var tokens: [WhisperToken] = []
        for i in 0..<sqwh_token_count(ctx) {
            var special: Int32 = 0
            var t0: Int64 = 0, t1: Int64 = 0
            var p: Float = 0
            let text = sqwh_token_text(ctx, i, &special)
            sqwh_token_info(ctx, i, &t0, &t1, &p)
            let bytes = text.map { Array(UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), count: strlen($0))) } ?? []
            tokens.append(WhisperToken(bytes: bytes, isSpecial: special != 0, startCs: t0, endCs: t1, probability: p))
        }
        return tokens
    }
}

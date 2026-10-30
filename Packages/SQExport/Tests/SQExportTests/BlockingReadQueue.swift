import Foundation

/// Runs blocking AVAssetReader loops (`copyNextSampleBuffer`) on one dedicated serial queue instead of the
/// cooperative pool or the global concurrent queue. Parallel suites used to park ~28 threads in these reads and
/// starve everything else (export writers, segmenter, frame sources), which stalled the full run for minutes.
private let sqBlockingReadQueue = DispatchQueue(label: "sq.tests.blocking-read", qos: .userInitiated)

func onBlockingReadQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        sqBlockingReadQueue.async { cont.resume(with: Result { try body() }) }
    }
}

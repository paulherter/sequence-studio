import Foundation

/// The running Anonymize analysis as a background job. The host keeps `run` current.
@MainActor
public final class AnonymizeJobSource: BackgroundJobSource {
    /// Clip name and progress 0...1 (nil = finding people), nil when nothing runs.
    public var run: (clip: String, progress: Double?)?
    private let cancel: @MainActor @Sendable () -> Void
    public init(cancel: @escaping @MainActor @Sendable () -> Void) { self.cancel = cancel }

    public func currentJobs() async -> [BackgroundJob] {
        guard let r = run else { return [] }
        return [BackgroundJob(id: "anonymize", kind: .other, title: SQL10n.format("Anonymizing “%@”", r.clip), progress: r.progress, cancel: cancel)]
    }
}

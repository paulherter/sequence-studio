import Foundation
import Observation
import SQCore
import SQMedia

/// "Conform to Constant Frame Rate" for variable-frame-rate media: the file is re-encoded to a constant rate in the
/// background (`VFRConform`), probed, and the library item takes it over (`replaceFootage`, one undo step), so clips,
/// marks and labels stay and cuts and audio stay in sync. The original file is never touched.
public enum ConstantFrameRateConform {
    public enum Failure: Error, Sendable, Equatable { case notVariable, offline, alreadyRunning, itemGone }

    /// Variable-frame-rate video that is not a still.
    public static func isEligible(_ ref: MediaRef) -> Bool {
        guard let v = ref.info?.video, ref.info?.isStill != true else { return false }
        return v.isVariableFrameRate
    }

    /// "Name (CFR).mov" in `folder`; "Name (CFR 2).mov"... when taken.
    public static func destination(for ref: MediaRef, in folder: URL, fileManager: FileManager = .default) -> URL {
        var stem = (ref.name as NSString).deletingPathExtension
        if stem.isEmpty { stem = "Media" }
        stem = stem.replacingOccurrences(of: "/", with: "-")
        var n = 1
        while true {
            let name = n == 1 ? "\(stem) (CFR).mov" : "\(stem) (CFR \(n)).mov"
            let url = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}

/// Runs and tracks conform jobs (the Jobs popover lists `runs`).
@MainActor @Observable
public final class ConformRunner {
    public struct Run: Identifiable, Equatable, Sendable {
        public let id: MediaRef.ID
        public var title: String
        /// 0...1.
        public var progress: Double
    }
    public typealias Convert = @Sendable (_ source: URL, _ destination: URL, _ frameDuration: Time,
                                         _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
    public typealias Probe = @Sendable (URL) async throws -> MediaRef

    public private(set) var runs: [Run] = []
    @ObservationIgnored private var work: [MediaRef.ID: Task<MediaRef, Error>] = [:]
    @ObservationIgnored private let convert: Convert
    @ObservationIgnored private let probe: Probe

    #if os(macOS)
    public init(convert: @escaping Convert = { src, dst, fd, progress in
                    _ = try await VFRConform.conform(source: src, destination: dst, frameDuration: fd, progress: progress)
                },
                probe: @escaping Probe = { try await MediaImporter.probe($0).0 }) {
        self.convert = convert; self.probe = probe
    }
    #else
    /// shortcut: no conform or probe off the Mac yet (the defaults throw `MediaError.unsupportedCodec`); upgrade with the
    /// FFmpeg transcoder and probe.
    public init(convert: @escaping Convert = { _, _, _, _ in throw MediaError.unsupportedCodec("conform") },
                probe: @escaping Probe = { _ in throw MediaError.unsupportedCodec("probe") }) {
        self.convert = convert; self.probe = probe
    }
    #endif

    public func isRunning(_ id: MediaRef.ID) -> Bool { work[id] != nil }

    public func cancel(_ id: MediaRef.ID) { work[id]?.cancel() }

    /// Conforms item `id` into `folder` and, when done, lets the item take over the new file. Returns the new file.
    /// Throws `CancellationError` when canceled (the partial file is removed).
    @discardableResult
    public func conform(_ id: MediaRef.ID, in session: EditorSession, folder: URL) async throws -> URL {
        guard work[id] == nil else { throw ConstantFrameRateConform.Failure.alreadyRunning }
        guard let ref = session.project.media(id) else { throw ConstantFrameRateConform.Failure.itemGone }
        guard ConstantFrameRateConform.isEligible(ref), let fd = ref.info?.video?.nominalFrameDuration else {
            throw ConstantFrameRateConform.Failure.notVariable
        }
        guard ref.status() != .missing else { throw ConstantFrameRateConform.Failure.offline }
        let source = URL(fileURLWithPath: ref.path)
        let destination = ConstantFrameRateConform.destination(for: ref, in: folder)
        let convert = self.convert, probe = self.probe
        runs.append(Run(id: id, title: "Conform: \(ref.name)", progress: 0))
        let report: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in self?.setProgress(p, of: id) }
        }
        let task = Task.detached(priority: .utility) { () throws -> MediaRef in
            try await convert(source, destination, fd, report)
            try Task.checkCancellation()
            return try await probe(destination)
        }
        work[id] = task
        defer { work[id] = nil; runs.removeAll { $0.id == id } }
        do {
            let probed = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard session.project.media(id) != nil else { throw ConstantFrameRateConform.Failure.itemGone }
            session.replaceFootage(id, with: probed)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func setProgress(_ p: Double, of id: MediaRef.ID) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].progress = min(max(p, 0), 1)
    }
}

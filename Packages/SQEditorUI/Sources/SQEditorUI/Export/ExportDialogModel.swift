import Foundation
import Observation
import SQCore
import SQExport

/// State of the Export sheet (docs/UX.md 4.6, DESIGN.md 4a/4b). Every sequence carries its own settings;
/// the detail properties (codec, size, ...) read and write the settings of `selectedID`.
/// The renderer is not wired yet, so sources come from an injected closure.
@MainActor @Observable
public final class ExportDialogModel {
    public struct SequenceItem: Identifiable, Sendable, Hashable {
        public let id: UUID
        public var name: String
        public var duration: Time
        /// The sequence's In/Out range, if the user set one.
        public var inOut: TimeRange?
        /// The sequence format: presets that follow the source (Match Source, YouTube frame rate) read it.
        public var format: SequenceFormat?
        public init(id: UUID = UUID(), name: String, duration: Time, inOut: TimeRange? = nil, format: SequenceFormat? = nil) {
            self.id = id; self.name = name; self.duration = duration; self.inOut = inOut; self.format = format
        }
    }

    public typealias SourceProvider = @Sendable (_ sequenceID: UUID, _ settings: ExportSettings) async throws -> ExportSources

    public static let customPresetID = "custom"
    public static let loudnessTargetLUFS = -14
    public static let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    public let sequences: [SequenceItem]
    public var checkedIDs: Set<UUID>
    public var selectedID: UUID
    private var perSequence: [UUID: ExportSettings]
    private var perSequencePreset: [UUID: String]
    private let sourceProvider: SourceProvider

    public init(sequences: [SequenceItem], initialPreset: ExportPreset = .default, sources: @escaping SourceProvider) {
        precondition(!sequences.isEmpty, "Export needs at least one sequence")
        self.sequences = sequences
        self.sourceProvider = sources
        self.selectedID = sequences[0].id
        self.checkedIDs = [sequences[0].id]
        self.perSequence = Dictionary(uniqueKeysWithValues: sequences.map { ($0.id, initialPreset.settings(matching: $0.format)) })
        self.perSequencePreset = Dictionary(uniqueKeysWithValues: sequences.map { ($0.id, initialPreset.id) })
    }

    // MARK: Selection

    public var presets: [ExportPreset] { ExportPreset.all }

    public func isChecked(_ id: UUID) -> Bool { checkedIDs.contains(id) }
    public func setChecked(_ id: UUID, _ on: Bool) {
        if on { checkedIDs.insert(id) } else { checkedIDs.remove(id) }
    }
    public var checkedSequences: [SequenceItem] { sequences.filter { checkedIDs.contains($0.id) } }
    private var selectedItem: SequenceItem { sequences.first { $0.id == selectedID } ?? sequences[0] }

    // MARK: Settings of the selected sequence

    public var settings: ExportSettings {
        get { perSequence[selectedID] ?? ExportPreset.default.settings }
        set { perSequence[selectedID] = newValue }
    }

    public func settings(for id: UUID) -> ExportSettings { perSequence[id] ?? ExportPreset.default.settings }

    /// Preset id, or `customPresetID` once a video detail was edited by hand.
    public var presetID: String {
        get { perSequencePreset[selectedID] ?? Self.customPresetID }
        set {
            guard let p = ExportPreset.all.first(where: { $0.id == newValue }) else { return }
            var s = p.settings(matching: selectedItem.format)
            // A preset never touches captions/loudness/range: those are per-export choices.
            s.captions = settings.captions; s.audio.loudnessTarget = settings.audio.loudnessTarget; s.range = settings.range
            perSequence[selectedID] = s
            perSequencePreset[selectedID] = p.id
        }
    }

    private func editVideo(_ f: (inout VideoSettings) -> Void) {
        f(&settings.video)
        perSequencePreset[selectedID] = Self.customPresetID
    }

    public var codec: VideoCodec {
        get { settings.video.codec }
        set { editVideo { $0.codec = newValue } }
    }
    public var width: Int {
        get { settings.video.width }
        set { editVideo { $0.width = newValue } }
    }
    public var height: Int {
        get { settings.video.height }
        set { editVideo { $0.height = newValue } }
    }

    public var fps: Double {
        get {
            let d = settings.video.frameDuration
            return d.value > 0 ? Double(d.timescale) / Double(d.value) : 0
        }
        set {
            let t: Time
            switch newValue {
            case 23.976: t = Time(1001, 24000)
            case 29.97: t = Time(1001, 30000)
            case 59.94: t = Time(1001, 60000)
            default: t = Time(1, max(1, Int64(newValue.rounded())))
            }
            editVideo { $0.frameDuration = t }
        }
    }

    /// Average video bitrate in Mbit/s. A max bitrate, if present, follows at 1.5x.
    public var bitrateMbps: Double {
        get { Double(settings.video.bitrate.averageBitsPerSecond) / 1_000_000 }
        set {
            let avg = Int((newValue * 1_000_000).rounded())
            editVideo { v in
                v.bitrate = v.bitrate.maxBitsPerSecond == nil ? .average(avg) : .averageAndMax(average: avg, max: avg * 3 / 2)
            }
        }
    }

    public var normalizeLoudness: Bool {
        get { settings.audio.loudnessTarget != nil }
        set { settings.audio.loudnessTarget = newValue ? Self.loudnessTargetLUFS : nil }
    }

    public var captions: CaptionMode {
        get { settings.captions }
        set { settings.captions = newValue }
    }

    public var canUseInOut: Bool { selectedItem.inOut != nil }
    public var useInOut: Bool {
        get { if case .inOut = settings.range { true } else { false } }
        set {
            if newValue, let r = selectedItem.inOut { settings.range = .inOut(r) } else { settings.range = .entireSequence }
        }
    }

    // MARK: Derived

    public func effectiveDuration(of id: UUID) -> Time {
        if case .inOut(let r) = settings(for: id).range { return r.duration }
        return sequences.first { $0.id == id }?.duration ?? .zero
    }

    /// Total estimated size of all checked sequences, in bytes.
    public var estimatedBytes: Int64 {
        checkedSequences.reduce(0) { $0 + settings(for: $1.id).estimatedFileSize(duration: effectiveDuration(of: $1.id)) }
    }

    /// "1920×1080 · 29.97 fps · H.264 · 12 Mbit/s" for the selected sequence.
    public var summaryText: String {
        let v = settings.video
        let codecName = v.codec == .h264 ? "H.264" : v.codec == .hevc ? "HEVC" : "ProRes 422 HQ"
        let fpsText = fps == fps.rounded() ? "\(Int(fps))" : String(format: "%.5g", fps)
        var parts = ["\(v.width)×\(v.height)", "\(fpsText) fps", codecName]
        if !v.codec.isMastering { parts.append(String(format: "%.3g Mbit/s", bitrateMbps)) }
        return parts.joined(separator: " · ")
    }

    public var estimatedSizeText: String {
        "About " + ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
    }

    public var validationMessages: [String] {
        if checkedIDs.isEmpty { return ["Select at least one sequence to export."] }
        var issues = Set<ExportSettingsIssue>()
        var emptyRange = false
        for s in checkedSequences {
            issues.formUnion(settings(for: s.id).validate())
            if effectiveDuration(of: s.id) <= .zero { emptyRange = true }
        }
        var out: [String] = []
        if issues.contains(.oddDimensions) { out.append("Width and height must be even numbers greater than 0.") }
        if issues.contains(.nonPositiveBitrate) { out.append("Bitrate must be greater than 0, and the maximum not below the average.") }
        if issues.contains(.invalidKeyframeInterval) { out.append("Keyframe interval must be at least 1 frame.") }
        if issues.contains(.invalidFrameDuration) { out.append("Frame rate is not valid.") }
        if issues.contains(.invalidAudio) { out.append("Audio settings are not valid.") }
        if emptyRange { out.append("The export range is empty.") }
        return out
    }

    public var canExport: Bool { validationMessages.isEmpty }

    // MARK: Jobs

    /// One job per checked sequence, in project order.
    public func buildJobs(outputDirectory: URL) -> [ExportJob] {
        let provider = sourceProvider
        return checkedSequences.map { item in
            let s = settings(for: item.id)
            let id = item.id
            return ExportJob(name: item.name, settings: s, outputDirectory: outputDirectory) {
                try await provider(id, s)
            }
        }
    }

    /// Enqueues the jobs; with `run` the queue starts processing in the background. Returns the job ids.
    @discardableResult
    public func submit(to queue: ExportQueue, outputDirectory: URL, run: Bool = true) async -> [UUID] {
        guard canExport else { return [] }
        var ids: [UUID] = []
        for job in buildJobs(outputDirectory: outputDirectory) { ids.append(await queue.enqueue(job)) }
        if run { Task { await queue.runAll() } }
        return ids
    }
}

import Foundation
import Observation
import SQCore
import SQExport
import SQUIKit

/// State of the Export sheet (docs/UX.md 4.6, DESIGN.md 4a/4b). Every sequence carries its own settings;
/// the detail properties (codec, size, ...) read and write the settings of `selectedID`.
/// Sources come from an injected closure. Portable (SQEditorSession) so the Mac sheet and the Windows canvas form share it.
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
        /// The sequence's platform and loudness target: sets its default preset and loudness normalization.
        public var deliveryTarget: DeliveryTarget?
        /// The sequence's format variants (W5.1): "Export All Formats" makes one job per variant.
        public var variants: [FormatVariant]
        /// Where the sequence's marker named "Cover" sits (`CoverFrame.time`); nil = no such marker.
        public var coverTime: Time?
        /// The sequence plays nested under a clip with Disguise Voice: exported on its own, that voice is not disguised.
        public var nestedUnderDisguiseVoice: Bool
        /// Audio clips whose sync offset against their linked picture is not zero (`Timeline.syncOffsets`): the audio
        /// check warns about them.
        public var unsyncedAudioClips: Int
        /// The clips selected in the timeline when the dialog opened (time order): "Selected clips" exports their span,
        /// and "One file per clip" one file each. Only the active sequence has any.
        public var selectedClips: [SelectedClipRange]
        /// The sequence's markers: named ones become the chapter list ("Copy Chapters").
        public var markers: [Marker] = []
        /// What the sequence's used media looks like (variable frame rate, interlaced): the delivery chips read it.
        public var sourceTraits: DeliveryCheck.SourceTraits = .init()
        /// The HDR transfer the sequence's clips target (`ClipColor.targetSpace`): the dialog suggests that HDR delivery.
        public var hdrTarget: HDRDelivery.Transfer?
        public init(id: UUID = UUID(), name: String, duration: Time, inOut: TimeRange? = nil, format: SequenceFormat? = nil,
                    deliveryTarget: DeliveryTarget? = nil, variants: [FormatVariant] = [], coverTime: Time? = nil,
                    nestedUnderDisguiseVoice: Bool = false, unsyncedAudioClips: Int = 0,
                    selectedClips: [SelectedClipRange] = [], markers: [Marker] = [],
                    sourceTraits: DeliveryCheck.SourceTraits = .init(), hdrTarget: HDRDelivery.Transfer? = nil) {
            self.hdrTarget = hdrTarget
            self.markers = markers; self.sourceTraits = sourceTraits
            self.selectedClips = selectedClips.sorted { $0.range.start < $1.range.start }
            self.nestedUnderDisguiseVoice = nestedUnderDisguiseVoice
            self.unsyncedAudioClips = unsyncedAudioClips
            self.id = id; self.name = name; self.duration = duration; self.inOut = inOut; self.format = format
            self.deliveryTarget = deliveryTarget; self.variants = variants; self.coverTime = coverTime
        }
    }

    /// A selected clip's name and span on the sequence timeline.
    public struct SelectedClipRange: Sendable, Hashable {
        public var name: String
        public var range: TimeRange
        public init(name: String, range: TimeRange) { self.name = name; self.range = range }
    }

    /// One output of a sequence: a preset (possibly edited by hand) and its settings. A sequence has one or more.
    public struct FormatEntry: Identifiable, Sendable, Hashable {
        public let id: UUID
        public var presetID: String
        public var settings: ExportSettings
        /// Unchecked formats stay in the list but are not exported.
        public var enabled: Bool
        /// The name typed in the dialog's File Name field (nil = derived from the sequence name).
        public var fileName: String?
        public init(id: UUID = UUID(), presetID: String, settings: ExportSettings, enabled: Bool = true, fileName: String? = nil) {
            self.id = id; self.presetID = presetID; self.settings = settings; self.enabled = enabled; self.fileName = fileName
        }
    }

    public typealias SourceProvider = @Sendable (_ sequenceID: UUID, _ settings: ExportSettings) async throws -> ExportSources

    public static let customPresetID = "custom"
    public static let loudnessTargetLUFS = Int(AudioTag.dialogue.targetLUFS)
    public static let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    public let sequences: [SequenceItem]
    public var checkedIDs: Set<UUID>
    public var selectedID: UUID
    private var formatsBySequence: [UUID: [FormatEntry]]
    /// The format the detail properties edit (of the selected sequence); falls back to its first one.
    public var selectedFormatID: UUID
    /// Footage preview (nil = the dialog shows no picture). Set by the host; the settings it gets are the preview's own (small, silent).
    public var previewSource: PreviewSourceProvider?
    private let sourceProvider: SourceProvider
    /// W5.1: also export every format variant of the checked sequences (one file each, named after the variant).
    public var exportAllFormats = false
    /// Whether any checked sequence has variants (the "Export All Formats" checkbox is shown then).
    public var hasVariants: Bool { checkedSequences.contains { !$0.variants.isEmpty } }

    public typealias PreviewSourceProvider = @Sendable (_ sequenceID: UUID, _ settings: ExportSettings) async throws -> any FrameSource

    /// Free bytes on the volume of a folder (nil = unknown, no warning). Injected for tests.
    public typealias FreeSpaceProvider = @MainActor (URL) -> Int64?
    private let freeSpace: FreeSpaceProvider
    /// Where the files will go; nil until the user picks a folder (the check then uses the home volume).
    public var outputDirectory: URL?

    /// `initialPreset == nil`: every sequence starts with its own platform's preset (`ExportPreset.defaultPreset`).
    public init(sequences: [SequenceItem], initialPreset: ExportPreset? = .default,
                freeSpace: @escaping FreeSpaceProvider = ExportDialogModel.systemFreeSpace,
                sources: @escaping SourceProvider) {
        precondition(!sequences.isEmpty, "Export needs at least one sequence")
        self.freeSpace = freeSpace
        self.sequences = sequences
        self.sourceProvider = sources
        self.selectedID = sequences[0].id
        self.checkedIDs = [sequences[0].id]
        func preset(_ s: SequenceItem) -> ExportPreset {
            initialPreset ?? Self.hdrPreset(for: s) ?? .defaultPreset(format: s.format, target: s.deliveryTarget)
        }
        // Premiere: with In/Out set the export covers that range; "Entire sequence" is the switch off.
        let formats = Dictionary(uniqueKeysWithValues: sequences.map { s -> (UUID, [FormatEntry]) in
            var settings = Self.withHDRSuggestion(Self.withDialogDefaults(preset(s).settings(matching: s.format, target: s.deliveryTarget)), for: s)
            if let r = s.inOut { settings.range = .inOut(r) }
            return (s.id, [FormatEntry(presetID: preset(s).id, settings: settings)])
        })
        self.formatsBySequence = formats
        self.selectedFormatID = formats[sequences[0].id]![0].id
    }

    // MARK: Selection

    public var presets: [ExportPreset] { ExportPreset.all }

    public func isChecked(_ id: UUID) -> Bool { checkedIDs.contains(id) }
    public func setChecked(_ id: UUID, _ on: Bool) {
        if on { checkedIDs.insert(id) } else { checkedIDs.remove(id) }
    }
    public var checkedSequences: [SequenceItem] { sequences.filter { checkedIDs.contains($0.id) } }
    private var selectedItem: SequenceItem { sequences.first { $0.id == selectedID } ?? sequences[0] }

    // MARK: Formats (several per sequence)

    public func formats(for id: UUID) -> [FormatEntry] { formatsBySequence[id] ?? [] }

    /// The selected sequence's format being edited.
    public var selectedFormat: FormatEntry {
        let fs = formats(for: selectedID)
        return fs.first { $0.id == selectedFormatID } ?? fs[0]
    }

    private func mutateSelectedFormat(_ f: (inout FormatEntry) -> Void) {
        let id = selectedFormat.id
        guard var fs = formatsBySequence[selectedID], let i = fs.firstIndex(where: { $0.id == id }) else { return }
        f(&fs[i])
        formatsBySequence[selectedID] = fs
    }

    public func selectFormat(_ id: UUID) {
        for s in sequences where formats(for: s.id).contains(where: { $0.id == id }) {
            selectedID = s.id; selectedFormatID = id; return
        }
    }

    /// Adds a format to the selected sequence and selects it. `presetID == nil`: the first preset the sequence does not use yet.
    public func addFormat(presetID: String? = nil) {
        let used = Set(formats(for: selectedID).map(\.presetID))
        guard let p = ExportPreset.all.first(where: { $0.id == presetID })
                ?? ExportPreset.all.first(where: { !used.contains($0.id) }) ?? ExportPreset.all.first else { return }
        let entry = FormatEntry(presetID: p.id, settings: carry(Self.withHDRSuggestion(Self.withDialogDefaults(p.settings(matching: selectedItem.format, target: selectedItem.deliveryTarget)), for: selectedItem),
                                                                from: selectedFormat.settings, preset: p))
        formatsBySequence[selectedID, default: []].append(entry)
        selectedFormatID = entry.id
    }

    public func duplicateFormat(_ id: UUID) {
        guard var fs = formatsBySequence[selectedID], let i = fs.firstIndex(where: { $0.id == id }) else { return }
        let copy = FormatEntry(presetID: fs[i].presetID, settings: fs[i].settings, enabled: fs[i].enabled, fileName: fs[i].fileName)
        fs.insert(copy, at: i + 1)
        formatsBySequence[selectedID] = fs
        selectedFormatID = copy.id
    }

    /// Removes a format of the selected sequence; the last one stays.
    public func removeFormat(_ id: UUID) {
        guard var fs = formatsBySequence[selectedID], fs.count > 1, let i = fs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedFormat.id == id
        fs.remove(at: i)
        formatsBySequence[selectedID] = fs
        if wasSelected { selectedFormatID = fs[min(i, fs.count - 1)].id }
    }

    public func setFormatEnabled(_ id: UUID, _ on: Bool) {
        for (seq, var fs) in formatsBySequence {
            if let i = fs.firstIndex(where: { $0.id == id }) { fs[i].enabled = on; formatsBySequence[seq] = fs; return }
        }
    }

    /// Enabled formats of the checked sequences, in project order.
    private var activeFormats: [(item: SequenceItem, format: FormatEntry)] {
        checkedSequences.flatMap { item in formats(for: item.id).filter(\.enabled).map { (item, $0) } }
    }

    /// Number of files the Export button writes.
    public var jobCount: Int {
        activeFormats.reduce(0) {
            if let clips = perClipRanges(item: $1.item, settings: $1.format.settings) { return $0 + clips.count }
            return $0 + 1 + (exportAllFormats && $1.format.settings.audioOnly == nil ? $1.item.variants.count : 0)
        }
    }

    public var exportButtonTitle: String { jobCount > 1 ? SQL10n.format("Export %@ files", String(jobCount)) : SQL10n.string("Export") }

    /// Which preset a format came from, by name ("Custom" once edited by hand).
    public func presetName(of entry: FormatEntry) -> String {
        ExportPreset.all.first { $0.id == entry.presetID }.map { SQL10n.localized($0.name) } ?? SQL10n.string("Custom")
    }

    /// Short label of a format row: "1080×1920 · H.264".
    public func formatLabel(_ entry: FormatEntry) -> String {
        if let f = entry.settings.audioOnly { return SQL10n.format("Audio only · %@", f.fileExtension.uppercased()) }
        if let o = entry.settings.frameOutput { return "\(entry.settings.video.width)×\(entry.settings.video.height) · \(SQL10n.localized(o.displayName))" }
        return "\(entry.settings.video.width)×\(entry.settings.video.height) · \(entry.settings.video.codec.displayName)"
    }

    // MARK: Settings of the selected format

    public var settings: ExportSettings {
        get { selectedFormat.settings }
        set { mutateSelectedFormat { $0.settings = newValue } }
    }

    /// The first enabled format of a sequence (its main output); used where one number per sequence is needed.
    public func settings(for id: UUID) -> ExportSettings {
        let fs = formats(for: id)
        return (fs.first { $0.enabled } ?? fs.first)?.settings ?? ExportPreset.default.settings
    }

    /// A preset never touches captions/loudness/range: those are per-export choices (kept from `old`).
    private func carry(_ new: ExportSettings, from old: ExportSettings, preset p: ExportPreset) -> ExportSettings {
        var s = new
        s.captions = old.captions; s.range = old.range
        s.coverImage = old.coverImage
        s.continueOnDamagedFrames = old.continueOnDamagedFrames
        s.hdrToSDR = old.hdrToSDR
        s.hdrDelivery = old.hdrDelivery
        s.encoderSpeed = old.encoderSpeed
        s.audio.loudness = old.audio.loudness == nil ? nil : defaultLoudness(preset: p)
        if s.audioOnly != nil, s.captions == .burnIn { s.captions = .none }   // no picture to burn into
        return s
    }

    /// Preset id, or `customPresetID` once a video detail was edited by hand.
    public var presetID: String {
        get { selectedFormat.presetID }
        set {
            guard let p = ExportPreset.all.first(where: { $0.id == newValue }) else { return }
            let s = carry(p.settings(matching: selectedItem.format), from: settings, preset: p)
            maxEditedByHand.remove(selectedFormat.id)
            mutateSelectedFormat { $0.settings = s; $0.presetID = p.id }
        }
    }

    /// Formats whose Maximum bitrate the user set by hand: it stops following the target at 1.5x.
    private var maxEditedByHand: Set<UUID> = []

    /// What double-click resets a numeric field to: the selected preset's settings for this sequence, or the default
    /// preset's once the format is "Custom".
    public var presetSettings: ExportSettings {
        let p = ExportPreset.all.first { $0.id == presetID } ?? ExportPreset.default
        return p.settings(matching: selectedItem.format, target: selectedItem.deliveryTarget)
    }

    /// Edits the selected format's settings; a change to the video part turns the preset into "Custom".
    public func edit(_ f: (inout ExportSettings) -> Void) {
        mutateSelectedFormat { e in
            let before = e.settings.video
            f(&e.settings)
            if e.settings.video != before { e.presetID = Self.customPresetID }
        }
    }

    private func editVideo(_ f: (inout VideoSettings) -> Void) {
        mutateSelectedFormat { f(&$0.settings.video); $0.presetID = Self.customPresetID }
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
            guard d.value > 0 else { return 0 }
            let raw = Double(d.timescale) / Double(d.value)
            // The NTSC rates are 24000/1001 etc.: report the picker's tag (23.976) so the Picker can match it.
            return Self.frameRates.first { abs($0 - raw) < 0.01 } ?? raw
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

    /// Average video bitrate in Mbit/s. A max bitrate, if present, follows at 1.5x until it was edited by hand;
    /// then it stays, but is raised to the target when the target goes above it.
    public var bitrateMbps: Double {
        get { Double(settings.video.bitrate.averageBitsPerSecond) / 1_000_000 }
        set {
            let avg = Int((newValue * 1_000_000).rounded())
            let manual = maxEditedByHand.contains(selectedFormat.id)
            editVideo { v in
                guard let oldMax = v.bitrate.maxBitsPerSecond else { v.bitrate = .average(avg); return }
                v.bitrate = .averageAndMax(average: avg, max: manual ? max(oldMax, avg) : avg * 3 / 2)
            }
        }
    }

    /// VBR or CBR (H.264 / HEVC). CBR has no Maximum: the hand-edit state resets and a stored Maximum goes back to
    /// following Target at 1.5x, so it is sensible again when the mode returns to VBR.
    public var bitrateKind: BitrateKind {
        get { settings.video.bitrateKind }
        set {
            guard newValue != settings.video.bitrateKind else { return }
            if newValue == .cbr { maxEditedByHand.remove(selectedFormat.id) }
            editVideo { v in
                v.bitrateKind = newValue
                let avg = v.bitrate.averageBitsPerSecond
                if newValue == .cbr, v.bitrate.maxBitsPerSecond != nil { v.bitrate = .averageAndMax(average: avg, max: avg * 3 / 2) }
            }
        }
    }

    public var hasMaxBitrate: Bool {
        get { settings.video.bitrate.maxBitsPerSecond != nil }
        set {
            maxEditedByHand.remove(selectedFormat.id)
            editVideo { v in
                let avg = v.bitrate.averageBitsPerSecond
                v.bitrate = newValue ? .averageAndMax(average: avg, max: avg * 3 / 2) : .average(avg)
            }
        }
    }

    /// Maximum video bitrate in Mbit/s (only meaningful while `hasMaxBitrate`).
    public var maxBitrateMbps: Double {
        get { Double(settings.video.bitrate.maxBitsPerSecond ?? settings.video.bitrate.averageBitsPerSecond) / 1_000_000 }
        set {
            maxEditedByHand.insert(selectedFormat.id)
            editVideo { v in v.bitrate = .averageAndMax(average: v.bitrate.averageBitsPerSecond, max: max(Int((newValue * 1_000_000).rounded()), v.bitrate.averageBitsPerSecond)) }
        }
    }

    public var normalizeLoudness: Bool {
        get { settings.audio.loudnessTarget != nil }
        set {
            settings.audio.loudness = newValue ? defaultLoudness(preset: ExportPreset.all.first { $0.id == presetID }) : nil
        }
    }

    /// The sequence's delivery target wins over the preset's platform target.
    private func defaultLoudness(preset: ExportPreset?, item: SequenceItem? = nil) -> LoudnessNormalization {
        if let t = (item ?? selectedItem).deliveryTarget { return LoudnessNormalization(targetLUFS: t.targetLUFS, truePeakCeilingDB: t.truePeakDB) }
        return preset?.loudness ?? LoudnessNormalization()
    }

    /// Toggle label: the active target and true-peak ceiling.
    public var loudnessLabel: String {
        let l = settings.audio.loudness ?? defaultLoudness(preset: ExportPreset.all.first { $0.id == presetID })
        return SQL10n.format("Normalize loudness to %@ LUFS, max %@ dBTP", String(Int(l.targetLUFS.rounded())), String(Int(l.truePeakCeilingDB.rounded())))
    }

    public var captions: CaptionMode {
        get { settings.captions }
        set { settings.captions = newValue }
    }

    /// "Also save cover image": a still next to the video, taken at the sequence's "Cover" marker (else the first frame).
    public var coverImage: CoverImageFormat? {
        get { settings.coverImage }
        set { settings.coverImage = newValue }
    }

    /// What the cover image shows, for the dialog: the marker's time or the first-frame fallback.
    public var coverFrameText: String {
        guard let t = selectedItem.coverTime else { return SQL10n.string("First frame (add a marker named \"Cover\" to choose)") }
        let fd = settings.video.frameDuration
        return SQL10n.format("Marker \"%@\" at %@", CoverFrame.markerName, ExportDecodeError.timecode(t, frameDuration: fd))
    }

    /// Off: a frame that cannot be decoded stops the export with the clip and time. On: it is drawn as a placeholder.
    /// Encoder speed (AppSettings `sq.export.encoderSpeed`): a per-Mac choice, so it applies to every format at once
    /// and never turns a preset into "Custom".
    public var encoderSpeed: EncoderSpeed {
        get { settings.encoderSpeed }
        set {
            formatsBySequence = formatsBySequence.mapValues { fs in
                fs.map { var f = $0; f.settings.encoderSpeed = newValue; return f }
            }
        }
    }

    /// Note under the Encoder Speed row: on a Mac with 8 GB or less, while Quality is picked, suggest Balanced.
    public static func encoderSpeedHint(_ speed: EncoderSpeed,
                                        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String? {
        guard speed == .quality, let s = EncoderSpeed.suggested(physicalMemory: physicalMemory) else { return nil }
        return "\(s.displayName) exports faster on this Mac"
    }

    public var continueOnDamagedFrames: Bool {
        get { settings.continueOnDamagedFrames }
        set { settings.continueOnDamagedFrames = newValue }
    }

    public var canUseInOut: Bool { selectedItem.inOut != nil }
    public var useInOut: Bool {
        get { if case .inOut = settings.range { true } else { false } }
        set {
            if newValue, let r = selectedItem.inOut { settings.range = .inOut(r) } else { settings.range = .entireSequence }
        }
    }

    // MARK: Custom range

    /// Sequences whose range the user typed in (a sub-range that is neither the whole sequence nor its In/Out).
    private var customRangeIDs: Set<UUID> = []

    /// Sequences whose range is the span of the selected clips.
    private var selectionRangeIDs: Set<UUID> = []
    /// Export every selected clip as its own file (only while the range is "Selected clips").
    public var oneFilePerClip = false

    public var selectedClipCount: Int { selectedItem.selectedClips.count }
    public var canUseSelection: Bool { !selectedItem.selectedClips.isEmpty }

    /// First start to last end of the selected clips of `item`.
    static func selectionSpan(of item: SequenceItem) -> TimeRange? {
        guard let first = item.selectedClips.first else { return nil }
        let end = item.selectedClips.map(\.range.end).max() ?? first.range.end
        return TimeRange(start: first.range.start, end: end)
    }

    /// The per-clip ranges a format of `item` is split into; nil when it is one file.
    func perClipRanges(item: SequenceItem, settings: ExportSettings) -> [SelectedClipRange]? {
        guard oneFilePerClip, selectionRangeIDs.contains(item.id), !item.selectedClips.isEmpty,
              case .inOut(let r) = settings.range, r == Self.selectionSpan(of: item) else { return nil }
        return item.selectedClips
    }

    /// 0 = entire sequence, 1 = In to Out, 2 = custom start and end, 3 = the selected clips.
    public var rangeMode: Int {
        get {
            guard case .inOut(let r) = settings.range else { return 0 }
            if selectionRangeIDs.contains(selectedID), r == Self.selectionSpan(of: selectedItem) { return 3 }
            return customRangeIDs.contains(selectedID) ? 2 : 1
        }
        set {
            if newValue != 3 { selectionRangeIDs.remove(selectedID) }
            switch newValue {
            case 3:
                guard let span = Self.selectionSpan(of: selectedItem) else { break }
                customRangeIDs.remove(selectedID)
                selectionRangeIDs.insert(selectedID)
                settings.range = .inOut(span)
            case 2:
                customRangeIDs.insert(selectedID)
                if case .inOut = settings.range { break }
                settings.range = .inOut(selectedItem.inOut ?? TimeRange(start: .zero, duration: selectedItem.duration))
            case 1:
                customRangeIDs.remove(selectedID)
                useInOut = true
            default:
                customRangeIDs.remove(selectedID)
                useInOut = false
            }
        }
    }

    /// Start and end of the exported range in seconds (the whole sequence when no range is set).
    public var rangeSeconds: (start: Double, end: Double) {
        if case .inOut(let r) = settings.range { return (r.start.exportSeconds, r.end.exportSeconds) }
        return (0, selectedItem.duration.exportSeconds)
    }

    /// Sets one edge of the custom range, snapped to whole frames and kept inside the sequence with at least one frame.
    public func setCustomRange(startSeconds: Double? = nil, endSeconds: Double? = nil) {
        let fd = settings.video.frameDuration
        let frame = max(fd.exportSeconds, 0.000_001)
        let total = selectedItem.duration.exportSeconds
        func snap(_ v: Double) -> Time { Time(Int64((v / frame).rounded()) * fd.value, fd.timescale) }
        var (a, b) = rangeSeconds
        if let v = startSeconds { a = min(max(0, v), max(0, total - frame)) }
        if let v = endSeconds { b = min(max(v, frame), total) }
        var start = snap(a), end = snap(b)
        if end <= start { if startSeconds != nil { end = start + fd } else { start = end - fd } }
        if start < .zero { start = .zero }
        customRangeIDs.insert(selectedID)
        selectionRangeIDs.remove(selectedID)
        settings.range = .inOut(TimeRange(start: start, end: end))
    }

    // MARK: Derived

    public func effectiveDuration(of id: UUID) -> Time { effectiveDuration(of: id, settings: settings(for: id)) }

    public func effectiveDuration(of id: UUID, settings: ExportSettings) -> Time {
        if case .inOut(let r) = settings.range { return r.duration }
        return sequences.first { $0.id == id }?.duration ?? .zero
    }

    /// Total estimated size of every enabled format of all checked sequences, in bytes.
    public var estimatedBytes: Int64 {
        activeFormats.reduce(0) {
            $0 + $1.format.settings.estimatedFileSize(duration: effectiveDuration(of: $1.item.id, settings: $1.format.settings))
        }
    }

    /// The frame rate as written: exact NTSC tags (23.976, 29.97, 59.94), whole rates without decimals. Derived from the
    /// frame duration the export writer receives, so the summary can never disagree with the file.
    public static func frameRateText(_ d: Time) -> String {
        guard d.value > 0 else { return "0" }
        let raw = Double(d.timescale) / Double(d.value)
        if let tag = frameRates.first(where: { abs($0 - raw) < 0.01 }) { return tag == tag.rounded() ? "\(Int(tag))" : String(format: "%g", tag) }
        return raw == raw.rounded() ? "\(Int(raw))" : String(format: "%.2f", raw)
    }

    /// "1920×1080 · 29.97 fps · H.264 · 12 Mbit/s" for the selected output.
    public var summaryText: String {
        let v = settings.video
        let codecName = v.codec.displayName + (!v.codec.isProRes && v.bitDepth == 10 ? " 10-bit" : "")
        var parts = ["\(v.width)×\(v.height)", "\(Self.frameRateText(v.frameDuration)) fps", codecName]
        if !v.codec.isMastering { parts.append(String(format: "%.3g Mbit/s", bitrateMbps)) }
        return parts.joined(separator: " · ")
    }

    /// "~ 48 MB": bitrate x duration (+ audio) of every enabled output of the checked sequences.
    public var estimatedSizeText: String {
        "~ " + SQByteSize.string(estimatedBytes)
    }

    /// Settings every new output starts with that the presets do not own: captions are burned in.
    /// A sequence without a platform target whose clips target HDR starts on the HEVC 10-bit preset (H.264 cannot carry it).
    static func hdrPreset(for item: SequenceItem) -> ExportPreset? {
        item.hdrTarget != nil && item.deliveryTarget == nil ? .hevc10 : nil
    }

    /// Switches the HDR delivery on for the clips' target transfer (HEVC only); the user can set it back to SDR.
    static func withHDRSuggestion(_ s: ExportSettings, for item: SequenceItem) -> ExportSettings {
        guard let t = item.hdrTarget, s.video.codec == .hevc, s.audioOnly == nil, s.frameOutput == nil, s.hdrDelivery == nil else { return s }
        var s = s
        s.hdrDelivery = HDRDelivery(transfer: t)
        return s
    }

    public static func withDialogDefaults(_ s: ExportSettings) -> ExportSettings {
        var s = s
        s.captions = .burnIn
        return s
    }

    // MARK: Output list (one flat list, one row per output file)

    public struct OutputRow: Identifiable, Sendable, Hashable {
        public let id: UUID                  // the format entry
        public let sequenceID: UUID
        public let title: String             // "Main · Vertical 9:16"
        public let sizeText: String          // "1080 × 1920"
        public let isChecked: Bool
        public let isSelected: Bool
    }

    /// "Vertical 9:16", "Horizontal 16:9", "Square 1:1", "Portrait 4:5"; other shapes read as their size.
    public static func aspectName(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "\(width) × \(height)" }
        func is_(_ a: Int, _ b: Int) -> Bool { width * b == height * a }
        if is_(9, 16) { return SQL10n.string("Vertical 9:16") }
        if is_(16, 9) { return SQL10n.string("Horizontal 16:9") }
        if is_(1, 1) { return SQL10n.string("Square 1:1") }
        if is_(4, 5) { return SQL10n.string("Portrait 4:5") }
        return "\(width) × \(height)"
    }

    public var outputRows: [OutputRow] {
        sequences.flatMap { item in
            formats(for: item.id).map { f in
                let v = f.settings.video
                let audioOnly = f.settings.audioOnly
                return OutputRow(id: f.id, sequenceID: item.id,
                                 title: audioOnly == nil ? "\(item.name) · \(Self.aspectName(width: v.width, height: v.height))"
                                                          : SQL10n.format("%@ · Audio only", item.name),
                                 sizeText: audioOnly.map { $0.fileExtension.uppercased() } ?? f.settings.frameOutput.map { SQL10n.localized($0.displayName) } ?? "\(v.width) × \(v.height)",
                                 isChecked: checkedIDs.contains(item.id) && f.enabled,
                                 isSelected: f.id == selectedFormat.id && item.id == selectedID)
            }
        }
    }

    /// Ticks or unticks one output. Ticking also ticks its sequence; unticking the last output of a sequence unticks it.
    public func setOutputChecked(_ id: UUID, _ on: Bool) {
        guard let seq = sequences.first(where: { formats(for: $0.id).contains { $0.id == id } }) else { return }
        if on, !checkedIDs.contains(seq.id) {
            // The sequence was unticked: its other outputs carry stale "enabled" flags and must not start exporting with it.
            for f in formats(for: seq.id) where f.id != id { setFormatEnabled(f.id, false) }
        }
        setFormatEnabled(id, on)
        if on { checkedIDs.insert(seq.id) }
        else if !formats(for: seq.id).contains(where: \.enabled) { checkedIDs.remove(seq.id) }
    }

    public func selectOutput(_ id: UUID) { selectFormat(id) }

    /// "2 files · about 72 MB · 00:00:18:00 each" under the list.
    public var outputSummaryText: String {
        let n = jobCount
        let sizeText = SQByteSize.string(estimatedBytes)
        var parts = [SQL10n.plural(n, one: "%@ file", other: "%@ files"), SQL10n.format("about %@", sizeText)]
        let active = activeFormats
        if let first = active.first {
            let durations = active.map { effectiveDuration(of: $0.item.id, settings: $0.format.settings) }
            let fd = first.format.settings.video.frameDuration
            parts.append(ExportDecodeError.timecode(durations[0], frameDuration: fd) + (n > 1 && durations.allSatisfy { $0 == durations[0] } ? SQL10n.string(" each") : ""))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: File name

    /// Characters a file name cannot carry, plus control characters; leading and trailing dots/blanks go too.
    public static func sanitizedFileName(_ s: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?*|\"<>%").union(.controlCharacters).union(.newlines)
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { !illegal.contains($0) }))
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return String(trimmed.prefix(120))
    }

    /// The name of the selected output without extension: what was typed, else the sequence name.
    public var fileName: String {
        get { selectedFormat.fileName ?? Self.sanitizedFileName(selectedItem.name) }
        set {
            let clean = Self.sanitizedFileName(newValue)
            mutateSelectedFormat { $0.fileName = clean.isEmpty ? nil : clean }
        }
    }

    public var fileExtension: String { settings.fileExtension }

    /// Free space for "important usage" (what the system will let us write), falling back to the plain figure.
    public static let systemFreeSpace: FreeSpaceProvider = { url in
        #if os(macOS)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        if let n = v.volumeAvailableCapacityForImportantUsage { return n }
        return v.volumeAvailableCapacity.map(Int64.init)
        #else
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]) else { return nil }
        return v.volumeAvailableCapacity.map(Int64.init)
        #endif
    }

    /// Free bytes on the target volume, nil if unknown.
    public var availableBytes: Int64? {
        freeSpace(outputDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    /// EXP-19: the estimated output does not fit on the target volume.
    public var diskSpaceMessage: String? {
        guard !checkedIDs.isEmpty, let free = availableBytes, estimatedBytes > free else { return nil }
        let f = { (n: Int64) in SQByteSize.string(n) }
        return SQL10n.format("Not enough free disk space: the export needs about %@, %@ available.", f(estimatedBytes), f(max(0, free)))
    }

    public var validationMessages: [String] {
        if checkedIDs.isEmpty { return [SQL10n.string("Select at least one sequence to export.")] }
        var issues = Set<ExportSettingsIssue>()
        var emptyRange = false
        if jobCount == 0 { return [SQL10n.string("Tick at least one format to export.")] }
        for (item, f) in activeFormats {
            issues.formUnion(f.settings.validate())
            if effectiveDuration(of: item.id, settings: f.settings) <= .zero { emptyRange = true }
        }
        var out: [String] = []
        if issues.contains(.oddDimensions) { out.append(SQL10n.string("Width and height must be even numbers greater than 0.")) }
        if issues.contains(.nonPositiveBitrate) { out.append(SQL10n.string("Bitrate must be greater than 0, and the maximum not below the average.")) }
        if issues.contains(.invalidKeyframeInterval) { out.append(SQL10n.string("Keyframe interval must be at least 1 frame.")) }
        if issues.contains(.invalidFrameDuration) { out.append(SQL10n.string("Frame rate is not valid.")) }
        if issues.contains(.invalidAudio) { out.append(SQL10n.string("Audio settings are not valid.")) }
        if emptyRange { out.append(SQL10n.string("The export range is empty.")) }
        out.append(contentsOf: platformLimitMessages)
        if let d = diskSpaceMessage { out.append(d) }
        return out
    }

    /// Upload limits of a checked format's platform preset (X: length and file size) that the export would exceed.
    public var platformLimitMessages: [String] {
        var out: [String] = []
        for (item, f) in activeFormats {
            guard let preset = ExportPreset.all.first(where: { $0.id == f.presetID }), let lim = preset.limits else { continue }
            let d = effectiveDuration(of: item.id, settings: f.settings)
            let bytes = f.settings.estimatedFileSize(duration: d)
            if d > lim.maxDuration {
                out.append(SQL10n.format("%@ allows at most %@ seconds; this export is %@ seconds.", SQL10n.localized(preset.name), String(Int(lim.maxDuration.exportSeconds)), String(Int(d.exportSeconds.rounded()))))
            } else if bytes > lim.maxFileBytes {
                out.append(SQL10n.format("%@ allows at most %@; this export is about %@.", SQL10n.localized(preset.name), SQByteSize.string(lim.maxFileBytes), SQByteSize.string(bytes)))
            }
        }
        return out
    }

    public var canExport: Bool { validationMessages.isEmpty }

    /// Delivery chips for the checked formats (source traits, frame rate, audio rate, platform length); never block.
    public var deliveryIssues: [DeliveryCheck.Issue] {
        var out: [DeliveryCheck.Issue] = []
        for (item, f) in activeFormats {
            guard let preset = ExportPreset.all.first(where: { $0.id == f.presetID }) else { continue }
            let d = effectiveDuration(of: item.id, settings: f.settings)
            out.append(contentsOf: DeliveryCheck.issues(settings: f.settings, preset: preset, duration: d, source: item.sourceTraits,
                                                platform: item.deliveryTarget?.platform))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    /// Quiet note lines under the chips: odd sequence size and which encoder runs (and why software).
    public var deliveryNotes: [String] {
        var out: [String] = []
        for (item, f) in activeFormats {
            guard let preset = ExportPreset.all.first(where: { $0.id == f.presetID }) else { continue }
            if let fmt = item.format, let w = DeliveryAdvice.oddSizeNote(width: fmt.width, height: fmt.height),
               [.matchSource, .hevc10, .proRes, .proRes422, .proRes4444].contains(preset.kind) { out.append(w) }
        }
        if let e = DeliveryCheck.encoder(settings) { out.append(e.reason) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Everything the sheet shows as a quiet note line under the warning.
    public var exportNotes: String {
        ([disguiseVoiceHint].compactMap { $0 } + deliveryNotes.map { SQL10n.localized($0) }).joined(separator: "\n")
    }

    /// A one-line note (no block) when a checked sequence sits under a Disguise Voice clip of another sequence.
    public var disguiseVoiceHint: String? {
        guard checkedSequences.contains(where: \.nestedUnderDisguiseVoice) else { return nil }
        return SQL10n.string("Disguise Voice sits on a clip outside this sequence. Exported alone, the original voice is heard.")
    }

    // MARK: Remembered choices (UserDefaults, kept by the app)

    /// The selected output's preset and per-export choices, for the app to store after an export.
    public var preferences: ExportPreferences {
        ExportPreferences(presetID: selectedFormat.presetID, settings: selectedFormat.settings, exportAllFormats: exportAllFormats)
    }

    /// Starts every sequence's first output from the remembered choices. A sequence with a delivery target keeps its own
    /// platform preset and loudness target (the remembered preset only decides sequences without one, and audio-only);
    /// captions, cover, audio and the other choices apply to all.
    public func applyPreferences(_ p: ExportPreferences) {
        exportAllFormats = p.exportAllFormats && hasVariants
        for item in sequences {
            guard var fs = formatsBySequence[item.id], !fs.isEmpty else { continue }
            let own = ExportPreset.defaultPreset(format: item.format, target: item.deliveryTarget)
            var preset = own
            if let c = p.preset, item.deliveryTarget == nil || c.isAudioOnly { preset = c }
            let custom = p.presetID == ExportPreferences.customPresetID && item.deliveryTarget == nil
            var s = Self.withHDRSuggestion(Self.withDialogDefaults(preset.settings(matching: item.format, target: item.deliveryTarget)), for: item)
            if let r = item.inOut { s.range = .inOut(r) }
            var pref = p
            if !custom { pref.presetID = preset.id }
            pref.apply(to: &s, loudness: defaultLoudness(preset: preset, item: item))
            if s.audioOnly != nil {
                s.audio.enabled = true
                if s.captions == .burnIn { s.captions = .none }
            }
            fs[0].settings = s
            fs[0].presetID = custom ? Self.customPresetID : preset.id
            formatsBySequence[item.id] = fs
        }
        audioChecks = [:]
    }

    // MARK: Audio check (opt-in: it mixes the whole sequence once)

    private struct AudioCheckResult: Sendable {
        var analysis: AudioAnalysis
        var range: RangeSelection
        /// What Normalize will really do (peak limiter included), predicted for `predictedTarget`; nil without Normalize.
        var predicted: LoudnessReport?
        var predictedTarget: LoudnessNormalization?
    }
    private var audioChecks: [UUID: AudioCheckResult] = [:]
    /// The outputs whose audio check is running.
    public private(set) var audioCheckRunning: Set<UUID> = []
    /// Set when the check could not read the audio (shown under the button).
    public private(set) var audioCheckError: String?

    /// Whether the selected output has an audio check that still matches its range.
    public var hasAudioCheck: Bool { audioChecks[selectedFormat.id]?.range == settings.range }
    public var isCheckingAudio: Bool { audioCheckRunning.contains(selectedFormat.id) }

    /// The result of the audio check of the selected output, judged against its loudness target; empty before a check.
    public var audioFindings: [AudioFinding] {
        guard let r = audioChecks[selectedFormat.id], r.range == settings.range else { return [] }
        let normalizing = settings.audio.loudness != nil
        let target = settings.audio.loudness ?? defaultLoudness(preset: ExportPreset.all.first { $0.id == presetID })
        return AudioPreflight.evaluate(r.analysis, target: target, normalizing: normalizing,
                                       unsyncedClips: selectedItem.unsyncedAudioClips,
                                       predicted: normalizing && r.predictedTarget == target ? r.predicted : nil,
                                       toleranceLU: AudioDeliveryTarget.matching(target)?.toleranceLU ?? AudioPreflight.loudnessToleranceLU)
    }

    /// Loudness Range (EBU Tech 3342) is meaningless under 60 s: the dialog greys it out for short programs.
    public var loudnessRangeAvailable: Bool {
        AudioDeliveryTarget.loudnessRangeAvailable(durationSeconds: effectiveDuration(of: selectedItem.id).exportSeconds)
    }

    /// Index into `AudioDeliveryTarget.allCases` of the current normalization target, nil when custom or off.
    public var deliveryTargetIndex: Int? {
        settings.audio.loudness.flatMap(AudioDeliveryTarget.matching).flatMap { AudioDeliveryTarget.allCases.firstIndex(of: $0) }
    }

    /// Findings that make the export unwise (a pass or a warning never blocks).
    public var audioCheckFailures: [AudioFinding] { audioFindings.filter { $0.severity == .fail } }

    /// Mixes the selected output's audio once (no picture, no captions) and measures it.
    public func runAudioCheck() {
        let entry = selectedFormat, id = selectedID
        guard settings.audio.enabled, !audioCheckRunning.contains(entry.id) else { return }
        var probe = entry.settings
        probe.captions = .none; probe.coverImage = nil; probe.coverTime = nil; probe.audio.loudness = nil
        let range = entry.settings.range
        let normalizeTarget = entry.settings.audio.loudness
        let provider = sourceProvider
        audioCheckRunning.insert(entry.id)
        audioCheckError = nil
        Task { [weak self] in
            var result: AudioCheckResult?
            var failure: String?
            do {
                let sources = try await provider(id, probe)
                if let a = sources.audio as? any RewindableAudioSource {
                    let analysis = try await AudioPreflight.analyze(a)
                    var predicted: LoudnessReport?
                    if let normalizeTarget, !analysis.isSilent {
                        predicted = try await AudioPreflight.predict(a, analysis: analysis, target: normalizeTarget)
                    }
                    result = AudioCheckResult(analysis: analysis, range: range, predicted: predicted,
                                              predictedTarget: predicted == nil ? nil : normalizeTarget)
                } else {
                    failure = SQL10n.string("This sequence has no audio to check.")
                }
            } catch is CancellationError {
            } catch {
                failure = SQL10n.format("The audio could not be read: %@", SQL10n.errorText(error))
            }
            guard let self else { return }
            self.audioCheckRunning.remove(entry.id)
            if let result { self.audioChecks[entry.id] = result }
            self.audioCheckError = failure
        }
    }

    // MARK: Chapters

    /// The selected output's chapter list from the sequence's named markers (shifted to the export range); nil without markers.
    public var chapters: YouTubeChapters.Result? {
        let markers = selectedItem.markers
        guard !markers.isEmpty else { return nil }
        var start = Time.zero
        if case .inOut(let r) = settings.range { start = r.start }
        return YouTubeChapters.make(from: markers, rangeStart: start, duration: effectiveDuration(of: selectedID))
    }

    // MARK: Stems

    /// Builds the mix source of one stem of a sequence (the host knows the renderer); nil = stems unavailable.
    public typealias StemAudioProvider = @Sendable (_ sequenceID: UUID, _ stem: StemPlan.Stem, _ range: TimeRange) throws -> any AudioSource
    public var stemAudio: StemAudioProvider?
    /// Writes the stem files (Windows: `FFmpegExportEncoder`); nil on the Mac = `AVExportEncoder`.
    public var stemEncoder: (any ExportEncoding)?
    /// `StemPlan.stems(for:)` of every sequence the host can export stems of.
    public var stemPlans: [UUID: [StemPlan.Stem]] = [:]
    public private(set) var isExportingStems = false
    public private(set) var stemProgress: Double = 0
    /// Result line under the button: written files or the reason it failed.
    public private(set) var stemStatus: String?

    public var canExportStems: Bool { stemAudio != nil && !(stemPlans[selectedID] ?? []).isEmpty }

    /// Where the user's saved stem presets live (the host sets it; nil = presets cannot be saved).
    public var stemPresetStore: StemPresetStore? {
        didSet { userStemPresets = stemPresetStore?.load() ?? [] }
    }
    public private(set) var userStemPresets: [StemPreset] = []
    /// Stem ids the user unchecked (all stems start checked).
    public private(set) var stemUnchecked: Set<String> = []

    public var stemPlan: [StemPlan.Stem] { stemPlans[selectedID] ?? [] }
    /// The stems that will be written: the plan minus the unchecked ones.
    public var activeStems: [StemPlan.Stem] { stemPlan.filter { !stemUnchecked.contains($0.id) } }
    public func isStemChecked(_ id: String) -> Bool { !stemUnchecked.contains(id) }
    public func setStemChecked(_ id: String, _ on: Bool) {
        if on { stemUnchecked.remove(id) } else { stemUnchecked.insert(id) }
    }
    /// Built-in plus saved presets for the selected sequence's stems.
    public var stemPresets: [StemPreset] { StemPreset.builtIn(for: stemPlan) + userStemPresets }
    public func applyStemPreset(_ p: StemPreset) {
        let keep = Set(p.select(from: stemPlan).map(\.id))
        stemUnchecked = Set(stemPlan.map(\.id)).subtracting(keep)
    }
    /// Saves the current selection under a name made from its stems (an existing preset of that name is replaced).
    public func saveStemSelection() {
        let ids = activeStems.map(\.id)
        guard let store = stemPresetStore, !ids.isEmpty else { return }
        let p = StemPreset(name: StemPreset.autoName(ids: ids, plan: stemPlan), stemIDs: ids, format: settings.audioOnly ?? .wav)
        if let all = try? store.save(p) { userStemPresets = all }
    }
    public func deleteStemPreset(_ id: UUID) {
        if let store = stemPresetStore, let all = try? store.delete(id: id) { userStemPresets = all }
    }
    /// Estimated size of the checked stem files, in bytes.
    public var stemEstimatedBytes: Int64 {
        StemPreset.estimatedBytes(count: activeStems.count, duration: effectiveDuration(of: selectedID),
                                  format: settings.audioOnly ?? .wav, audio: settings.audio)
    }

    /// Writes one audio file per role plus the M&E mix next to the output, named after the output file name.
    /// WAV unless the output is an audio-only file (then its format and audio settings).
    public func exportStems(to directory: URL) async {
        let stems = activeStems
        guard let provider = stemAudio, !stems.isEmpty, !isExportingStems else { return }
        let id = selectedID, s = settings
        let base = fileName.isEmpty ? Self.sanitizedFileName(selectedItem.name) : fileName
        let duration = effectiveDuration(of: id)
        let stemRange: TimeRange
        if case .inOut(let r) = s.range { stemRange = r } else { stemRange = TimeRange(start: .zero, duration: duration) }
        var audio = s.audio
        let format = s.audioOnly ?? .wav
        audio.codec = format.codec
        audio.enabled = true
        audio.loudness = nil   // stems keep their level so they sum back to the mix
        #if canImport(AVFoundation)
        let encoder = stemEncoder ?? AVExportEncoder()
        #else
        guard let encoder = stemEncoder else {
            stemStatus = SQL10n.string("Stems are not available on this computer.")
            return
        }
        #endif
        isExportingStems = true; stemProgress = 0; stemStatus = nil
        defer { isExportingStems = false }
        do {
            let written = try await StemExporter.export(
                stems: stems, base: base, directory: directory, format: format, duration: duration, settings: audio,
                encoder: encoder, audioFor: { try provider(id, $0, stemRange) }, progress: { _ in })
            stemProgress = 1
            stemStatus = SQL10n.format("%@ stem files written.", String(written.count))
        } catch is CancellationError {
        } catch {
            stemStatus = SQL10n.format("Stems could not be exported: %@", SQL10n.errorText(error))
        }
    }

    // MARK: Cut-downs

    /// One planned cut-down range: target length, position inside that target's plan.
    public struct CutDownKey: Hashable, Sendable {
        public var target: Int
        public var index: Int
        public init(target: Int, index: Int) { self.target = target; self.index = index }
    }
    /// Ranges the user unchecked (all planned ranges start checked).
    public private(set) var cutDownUnchecked: Set<CutDownKey> = []
    /// Set by the host: called when "Export Cut-downs" is pressed.
    public var onExportCutDowns: (@MainActor () -> Void)?

    /// The selected sequence's cut-down plans that hold at least one range; empty without cut-down markers.
    public var cutDownPlans: [CutDownPlanner.Plan] {
        CutDownPlanner.plans(from: selectedItem.markers).filter { !$0.ranges.isEmpty }
    }
    public func isCutDownChecked(_ k: CutDownKey) -> Bool { !cutDownUnchecked.contains(k) }
    public func setCutDownChecked(_ k: CutDownKey, _ on: Bool) {
        if on { cutDownUnchecked.remove(k) } else { cutDownUnchecked.insert(k) }
    }
    public var checkedCutDownCount: Int {
        cutDownPlans.reduce(0) { n, p in n + p.ranges.indices.filter { isCutDownChecked(CutDownKey(target: p.targetSeconds, index: $0)) }.count }
    }

    /// One job per checked range of the selected sequence: the in/out range path, file name suffixed `_60s` (`_60s_2` for a
    /// second range of the same target).
    public func buildCutDownJobs(outputDirectory: URL) -> [ExportJob] {
        let item = selectedItem
        let provider = sourceProvider
        let id = item.id
        let f = formats(for: id).first(where: \.enabled) ?? selectedFormat
        let base = Self.sanitizedFileName(item.name).isEmpty ? item.name : Self.sanitizedFileName(item.name)
        var jobs: [ExportJob] = []
        for plan in cutDownPlans {
            for (i, range) in plan.ranges.enumerated() where isCutDownChecked(CutDownKey(target: plan.targetSeconds, index: i)) {
                var s = f.settings.forDelivery
                s.range = .inOut(range)
                s.coverTime = nil
                let cs = s
                let suffix = "_\(plan.targetSeconds)s" + (i == 0 ? "" : "_\(i + 1)")
                jobs.append(ExportJob(name: (f.fileName ?? base) + suffix, settings: cs, outputDirectory: outputDirectory) {
                    try await provider(id, cs)
                })
            }
        }
        return jobs
    }

    @discardableResult
    public func submitCutDowns(to queue: ExportQueue, outputDirectory: URL, run: Bool = true) async -> [UUID] {
        var ids: [UUID] = []
        for job in buildCutDownJobs(outputDirectory: outputDirectory) { ids.append(await queue.enqueue(job)) }
        if run, !ids.isEmpty { Task { await queue.runAll() } }
        return ids
    }

    // MARK: Jobs

    /// The selected sequence's loudness target for the dialog's caption, e.g. "-14 LUFS / -1 dBTP".
    public var deliveryText: String? {
        guard let t = selectedItem.deliveryTarget else { return nil }
        return String(format: "%.0f LUFS / %.0f dBTP", t.targetLUFS, t.truePeakDB)
    }

    /// One job per checked sequence, in project order.
    public func buildJobs(outputDirectory: URL) -> [ExportJob] {
        let provider = sourceProvider
        return checkedSequences.flatMap { item -> [ExportJob] in
            let active = formats(for: item.id).filter(\.enabled)
            let id = item.id
            return active.flatMap { f -> [ExportJob] in
                var settings = f.settings.forDelivery
                settings.coverTime = settings.coverImage == nil ? nil : item.coverTime
                let s = settings
                // Several formats of one sequence: the file name says which one it is.
                let base = Self.sanitizedFileName(item.name).isEmpty ? item.name : Self.sanitizedFileName(item.name)
                let name = f.fileName ?? (active.count > 1 ? "\(base) \(fileTag(f))" : base)
                if let clips = perClipRanges(item: item, settings: settings) {
                    return clips.enumerated().map { i, clip -> ExportJob in
                        var edited = s
                        edited.range = .inOut(clip.range)
                        edited.coverTime = nil
                        let cs = edited
                        let tag = Self.sanitizedFileName(clip.name)
                        let clipName = "\(name) - \(i + 1)" + (tag.isEmpty ? "" : " \(tag)")
                        return ExportJob(name: clipName, settings: cs, outputDirectory: outputDirectory) { try await provider(id, cs) }
                    }
                }
                if exportAllFormats, settings.audioOnly == nil, !item.variants.isEmpty, let format = item.format {
                    var shape = Timeline(name: item.name, format: format)
                    shape.variants = item.variants
                    return ExportJob.variantJobs(name: name, settings: s, outputDirectory: outputDirectory, timeline: shape) { vs in
                        try await provider(id, vs)
                    }
                }
                return [ExportJob(name: name, settings: s, outputDirectory: outputDirectory) {
                    try await provider(id, s)
                }]
            }
        }
    }

    /// "1080x1920 H.264": distinguishes the files of one sequence.
    private func fileTag(_ f: FormatEntry) -> String {
        "\(f.settings.video.width)x\(f.settings.video.height) \(f.settings.video.codec.displayName)"
    }

    /// Enqueues the jobs; with `run` the queue starts processing in the background. Returns the job ids.
    @discardableResult
    public func submit(to queue: ExportQueue, outputDirectory: URL, run: Bool = true, replaceExisting: Bool = false) async -> [UUID] {
        guard canExport else { return [] }
        var ids: [UUID] = []
        for var job in buildJobs(outputDirectory: outputDirectory) {
            job.replaceExisting = replaceExisting
            ids.append(await queue.enqueue(job))
        }
        if run { Task { await queue.runAll() } }
        return ids
    }
}

public extension Time {
    /// Seconds as a Double, for dialog fields only (never stored).
    var exportSeconds: Double { Double(value) / Double(max(timescale, 1)) }
}

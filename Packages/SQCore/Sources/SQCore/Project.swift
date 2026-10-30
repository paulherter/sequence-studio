import Foundation

public struct MediaFingerprint: Codable, Hashable, Sendable {
    public var size: Int64
    public var modified: Date?
    /// Hash of the first bytes of the file (computed by the media layer).
    public var headHash: String?

    public init(size: Int64, modified: Date? = nil, headHash: String? = nil) {
        self.size = size; self.modified = modified; self.headHash = headHash
    }
}

public enum MediaStatus: Sendable, Equatable { case ok, missing, changed }

public struct MediaRef: Codable, Hashable, Sendable, Identifiable {
    /// Equals `Clip.media`.
    public var id: UUID
    public var name: String
    public var path: String
    /// Security-scoped bookmark, resolved by the app layer.
    public var bookmark: Data?
    public var fingerprint: MediaFingerprint
    public var duration: Time?
    /// Probed media properties; nil for projects saved before probing existed.
    public var info: MediaInfo?
    /// Label color; nil = default for the media type.
    public var label: LabelColor?
    /// Poster frame (Cmd+P in the Project panel): the time shown as the thumbnail; nil = automatic.
    public var posterTime: Time?
    /// Markers on the media itself (M in the Source monitor), sorted by time; nil = none.
    public var sourceMarkers: [Marker]?
    /// Set on a subclip (v57, Subclip.swift): the media item it was made from and the range it covers. The file, its
    /// fingerprint and probe info are copies of the parent's, so everything that plays media plays a subclip unchanged.
    public var subclip: Subclip?

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil,
                fingerprint: MediaFingerprint, duration: Time? = nil, info: MediaInfo? = nil, label: LabelColor? = nil,
                posterTime: Time? = nil, sourceMarkers: [Marker]? = nil) {
        self.posterTime = posterTime; self.sourceMarkers = sourceMarkers
        self.label = label
        self.id = id; self.name = name; self.path = path; self.bookmark = bookmark
        self.fingerprint = fingerprint; self.duration = duration; self.info = info
    }

    /// `.missing` if nothing is at `path`, `.changed` if size or modification date differ, else `.ok`.
    public func status(fileManager: FileManager = .default) -> MediaStatus {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return .missing }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        if size != fingerprint.size { return .changed }
        if let expected = fingerprint.modified, let actual = attrs[.modificationDate] as? Date,
           abs(actual.timeIntervalSince(expected)) > 1 { return .changed }
        return .ok
    }
}

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var media: [MediaRef]
    public var timelines: [Timeline]
    public var activeTimeline: UUID?
    /// Project panel tree. Every media item and timeline is in exactly one bin.
    public var rootBin: Bin
    /// Source-monitor In/Out per media item. Empty entries are never stored.
    public var sourceMarks: [MediaRef.ID: SourceMarks]
    /// What import does with files (copy into `Files/`, move, leave); nil = copy. Absent in older files.
    public var importMode: ImportMode?
    /// Media management choices (outside media, library copies, folder watching); nil = app defaults. Optional additive
    /// key that older readers ignore.
    public var mediaPolicy: MediaPolicy?
    /// W5.1: the format variant the Program monitor shows per sequence (view state, saved with the project, not undoable).
    /// Absent = the sequence's own format. Decoding drops entries for unknown sequences or variants.
    public var activeVariants: [Timeline.ID: FormatVariant.ID] = [:]
    /// W8.3 brand tokens (fonts, colors, pill, caption style, motion defaults, looks); nil = no kit (all files before v33).
    public var styleKit: StyleKit?
    /// W9.3 camera input color space for clips whose media detected nothing beyond Rec.709 (InputColorSpace.swift);
    /// nil = none (all files before v34).
    public var inputColorSpace: ColorSpaceID?
    /// N8b live ducking of this project (v43); nil = follow Preferences > Audio.
    public var liveDucking: ProjectLiveDucking?
    /// Which set of built-in text and caption styles this project resolves its `styleRef`s with. Absent (every file written
    /// before the Inter built-ins) = 0, the Helvetica built-ins, so an old project renders exactly as before; new projects
    /// write `currentBuiltInStyles`. Never upgraded on load or save.
    public var builtInStyles: Int?
    public static let currentBuiltInStyles = 1
    /// v83: the project's free-text notes (ProjectFile+V83.swift). Stored only when not empty.
    var notesStore: String?
    /// Saved Project-panel filters (Project+SmartBins.swift). nil = none; the key is absent then, so no file version gates it.
    public var smartBins: [SmartBin]?
    public var notes: String {
        get { notesStore ?? "" }
        set { notesStore = newValue.isEmpty ? nil : newValue }
    }

    public init(id: UUID = UUID(), name: String, media: [MediaRef] = [],
                timelines: [Timeline] = [], activeTimeline: UUID? = nil,
                rootBin: Bin? = nil, sourceMarks: [MediaRef.ID: SourceMarks] = [:],
                importMode: ImportMode? = nil) {
        self.importMode = importMode
        self.id = id; self.name = name; self.media = media
        self.timelines = timelines; self.activeTimeline = activeTimeline ?? timelines.first?.id
        self.rootBin = rootBin ?? Bin(id: id, name: "Root")
        self.sourceMarks = sourceMarks
        builtInStyles = Project.currentBuiltInStyles
        normalizeBins()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, media, timelines, activeTimeline, rootBin, sourceMarks, importMode, mediaPolicy, activeVariants, styleKit, inputColorSpace, liveDucking, builtInStyles, smartBins
        case notesStore = "notes"
    }

    /// `rootBin` and `sourceMarks` are absent in files before version 4: everything lands in the root bin, no marks.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        media = try c.decode([MediaRef].self, forKey: .media)
        timelines = try c.decode([Timeline].self, forKey: .timelines)
        activeTimeline = try c.decodeIfPresent(UUID.self, forKey: .activeTimeline)
        rootBin = try c.decodeIfPresent(Bin.self, forKey: .rootBin) ?? Bin(id: id, name: "Root")
        let marks = try c.decodeIfPresent([String: SourceMarks].self, forKey: .sourceMarks) ?? [:]
        var parsed: [MediaRef.ID: SourceMarks] = [:]
        for (k, v) in marks { if let u = UUID(uuidString: k), !v.isEmpty { parsed[u] = v } }
        sourceMarks = parsed
        importMode = try? c.decodeIfPresent(ImportMode.self, forKey: .importMode)
        mediaPolicy = try? c.decodeIfPresent(MediaPolicy.self, forKey: .mediaPolicy)
        styleKit = try? c.decodeIfPresent(StyleKit.self, forKey: .styleKit)   // a malformed kit is dropped, the project opens
        inputColorSpace = try? c.decodeIfPresent(ColorSpaceID.self, forKey: .inputColorSpace)
        liveDucking = try? c.decodeIfPresent(ProjectLiveDucking.self, forKey: .liveDucking)
        builtInStyles = try? c.decodeIfPresent(Int.self, forKey: .builtInStyles)
        notesStore = (try? c.decodeIfPresent(String.self, forKey: .notesStore)).flatMap { $0.isEmpty ? nil : $0 }
        smartBins = (try? c.decodeIfPresent([SmartBin].self, forKey: .smartBins)).flatMap { $0.isEmpty ? nil : $0 }
        let av = (try? c.decodeIfPresent([String: String].self, forKey: .activeVariants)) ?? [:]
        for (k, v) in av {
            guard let t = UUID(uuidString: k), let vid = UUID(uuidString: v),
                  timelines.contains(where: { $0.id == t && $0.variant(vid) != nil }) else { continue }
            activeVariants[t] = vid
        }
        normalizeBins()
    }

    /// Marks are keyed by the media UUID string so the file stays a plain JSON object.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(media, forKey: .media)
        try c.encode(timelines, forKey: .timelines)
        try c.encodeIfPresent(activeTimeline, forKey: .activeTimeline)
        try c.encode(rootBin, forKey: .rootBin)
        var marks: [String: SourceMarks] = [:]
        for (k, v) in sourceMarks { marks[k.uuidString] = v }
        try c.encode(marks, forKey: .sourceMarks)
        try c.encodeIfPresent(importMode, forKey: .importMode)
        try c.encodeIfPresent(mediaPolicy, forKey: .mediaPolicy)
        try c.encodeIfPresent(styleKit, forKey: .styleKit)
        try c.encodeIfPresent(inputColorSpace, forKey: .inputColorSpace)
        try c.encodeIfPresent(liveDucking, forKey: .liveDucking)
        try c.encodeIfPresent(builtInStyles, forKey: .builtInStyles)
        try c.encodeIfPresent(notesStore, forKey: .notesStore)
        try c.encodeIfPresent(smartBins, forKey: .smartBins)
        if !activeVariants.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: activeVariants.map { ($0.key.uuidString, $0.value.uuidString) }),
                         forKey: .activeVariants)
        }
    }

    public func media(_ id: UUID) -> MediaRef? { media.first { $0.id == id } }

    /// Adds `ref`, or replaces the entry with the same ID. New media is filed in the root bin.
    public mutating func add(_ ref: MediaRef) {
        if let i = media.firstIndex(where: { $0.id == ref.id }) { media[i] = ref } else {
            media.append(ref)
            rootBin.children.append(.media(ref.id))
        }
    }
}

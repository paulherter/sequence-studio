import Foundation

/// Premiere-style label colour of a Project item or clip. Stored by name; `nil` on the model means "default for its type".
public enum LabelColor: String, Sendable, Hashable, Codable, CaseIterable {
    case violet, iris, caribbean, lavender, cerulean, forest, rose, mango
    case purple, blue, teal, magenta, tan, green, brown, yellow

    public var displayName: String { rawValue.capitalized }

    /// sRGB as 0xRRGGBB. The type defaults equal the clip colours of docs/DESIGN.md.
    public var rgb: UInt32 {
        switch self {
        case .violet: 0x8C5FBF
        case .iris: 0x5F6FD0
        case .caribbean: 0x2A8E8A
        case .lavender: 0x9A8FC8
        case .cerulean: 0x3B8CC4
        case .forest: 0x3F7A4A
        case .rose: 0xC0607A
        case .mango: 0x8A6320
        case .purple: 0x6A4DBD
        case .blue: 0x3D67B8
        case .teal: 0x2F8F9D
        case .magenta: 0x9C3F79
        case .tan: 0xA58B64
        case .green: 0x2F6B3A
        case .brown: 0x7A5237
        case .yellow: 0xB8A02E
        }
    }

    // Type defaults (video blue, audio green, nest mango, title magenta, caption purple: the DESIGN.md clip colours).
    public static let videoDefault = LabelColor.blue
    public static let audioDefault = LabelColor.green
    public static let imageDefault = LabelColor.violet
    public static let sequenceDefault = LabelColor.forest
    public static let nestedDefault = LabelColor.mango
    public static let textDefault = LabelColor.magenta
    public static let generatorDefault = LabelColor.rose
    public static let captionDefault = LabelColor.purple
    public static let binDefault = LabelColor.mango
}

/// What a media item is, for icons and default labels. Derived from probe info and the file extension.
public enum MediaKind: Sendable, Hashable {
    case video          // video only
    case audio          // audio only
    case videoAudio
    case image
    case unknown        // not probed
}

extension MediaRef {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "bmp", "gif", "webp", "psd", "exr", "dng"]

    public var kind: MediaKind {
        if Self.imageExtensions.contains((path as NSString).pathExtension.lowercased()) { return .image }
        guard let info else { return .unknown }
        switch (info.video != nil, info.audio != nil) {
        case (true, true): return .videoAudio
        case (true, false): return .video
        case (false, true): return .audio
        default: return .unknown
        }
    }

    /// Label when `label` is nil.
    public var defaultLabel: LabelColor {
        switch kind {
        case .audio: .audioDefault
        case .image: .imageDefault
        default: .videoDefault
        }
    }
    public var effectiveLabel: LabelColor { label ?? defaultLabel }
}

/// Value snapshot of everything needed to colour clips; the timeline view holds one (no Project dependency).
public struct LabelResolver: Sendable, Equatable {
    var mediaLabels: [MediaRef.ID: LabelColor] = [:]
    var imageMedia: Set<MediaRef.ID> = []
    var sequenceLabels: [Timeline.ID: LabelColor] = [:]

    public init() {}

    /// Colour a clip draws in: its own label, else the label of its sequence / media, else the default for its type.
    public func label(for clip: Clip) -> LabelColor {
        if let l = clip.label { return l }
        if let g = clip.generator { return g.kind == GeneratorRef.text ? .textDefault : .generatorDefault }
        if let s = clip.sequence { return sequenceLabels[s] ?? .nestedDefault }
        if let l = mediaLabels[clip.media] { return l }
        if imageMedia.contains(clip.media) { return .imageDefault }
        return clip.kind == .audio ? .audioDefault : .videoDefault
    }
}

extension Project {
    public var labelResolver: LabelResolver {
        var r = LabelResolver()
        for m in media {
            if let l = m.label { r.mediaLabels[m.id] = l }
            if m.kind == .image { r.imageMedia.insert(m.id) }
        }
        for t in timelines { if let l = t.label { r.sequenceLabels[t.id] = l } }
        return r
    }

    /// Sequences that are used as a nested clip in some sequence.
    public var nestedSequenceIDs: Set<Timeline.ID> {
        Set(timelines.flatMap { $0.tracks.flatMap { $0.clips.compactMap(\.sequence) } })
    }

    /// Label shown for a bin item. Bins have no label (fixed default).
    public func label(of ref: BinItemRef) -> LabelColor {
        switch ref {
        case .bin: return .binDefault
        case .media(let id): return media(id)?.effectiveLabel ?? .videoDefault
        case .sequence(let id):
            guard let t = timelines.first(where: { $0.id == id }) else { return .sequenceDefault }
            return t.label ?? (nestedSequenceIDs.contains(id) ? .nestedDefault : .sequenceDefault)
        }
    }

    /// Sets (or with nil resets) the label of media items and sequences in `refs`; bins are ignored.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func setLabel(_ label: LabelColor?, for refs: [BinItemRef]) -> Bool {
        var changed = false
        for r in refs {
            switch r {
            case .bin: continue
            case .media(let id):
                guard let i = media.firstIndex(where: { $0.id == id }), media[i].label != label else { continue }
                media[i].label = label; changed = true
            case .sequence(let id):
                guard let i = timelines.firstIndex(where: { $0.id == id }), timelines[i].label != label else { continue }
                timelines[i].label = label; changed = true
            }
        }
        return changed
    }

    /// All media items and sequences whose effective label equals `label` ("Select Label Group").
    public func items(withLabel label: LabelColor) -> [BinItemRef] {
        rootBin.allRefs.filter { if case .bin = $0 { return false } else { return self.label(of: $0) == label } }
    }
}

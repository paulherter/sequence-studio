import Foundation

/// Premiere-style label color of a Project item or clip. Stored by name; `nil` on the model means "default for its type".
public enum LabelColor: String, Sendable, Hashable, Codable, CaseIterable {
    case violet, iris, caribbean, lavender, cerulean, forest, rose, mango
    case purple, blue, teal, magenta, tan, green, brown, yellow

    /// Display names of the design (docs/design-source/menus.txt); the raw values stay the stored identifiers.
    public var displayName: String {
        switch self {
        case .iris: "Indigo"
        case .caribbean: "Aqua"
        case .lavender: "Lilac"
        case .cerulean: "Sky"
        case .forest: "Dark Green"
        case .rose: "Pink"
        case .mango: "Orange"
        case .tan: "Sand"
        default: rawValue.capitalized
        }
    }

    /// sRGB as 0xRRGGBB. The type defaults equal the clip colors of the design board (sq.css `.clip`).
    public var rgb: UInt32 {
        switch self {
        case .violet: 0x9A50C8
        case .iris: 0x5F6FD0
        case .caribbean: 0x2A8E8A
        case .lavender: 0x9A8FC8
        case .cerulean: 0x4F78A3
        case .forest: 0x3F7A4A
        case .rose: 0xBC4F78
        case .mango: 0xA8741C
        case .purple: 0x7350C0
        case .blue: 0x2F6FB0
        case .teal: 0x2F8F9D
        case .magenta: 0x9C3F79
        case .tan: 0x4A4A4A
        case .green: 0x1E8449
        case .brown: 0x7A5237
        case .yellow: 0xB8A02E
        }
    }

    // Type defaults per board: video blue 2F6FB0, audio green 1E8449, text purple 7350C0, caption mango A8741C,
    // nested cerulean 4F78A3, still violet 9A50C8, folder rose BC4F78, generator / adjustment tan 4A4A4A (the board's neutral gray).
    public static let videoDefault = LabelColor.blue
    public static let audioDefault = LabelColor.green
    public static let imageDefault = LabelColor.violet
    public static let sequenceDefault = LabelColor.forest
    public static let nestedDefault = LabelColor.cerulean
    public static let textDefault = LabelColor.purple
    public static let generatorDefault = LabelColor.tan
    public static let captionDefault = LabelColor.mango
    public static let binDefault = LabelColor.rose
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
        if Self.imageExtensions.contains(NSString(string: path).pathExtension.lowercased()) { return .image }
        guard let info else { return .unknown }
        switch (info.video != nil, info.audio != nil) {
        case (true, true): return .videoAudio
        case (true, false): return .video
        case (false, true): return .audio
        default: return .unknown
        }
    }

    /// Colors the item wears in the Project panel, the same colors its clips get on the timeline (`LabelResolver`):
    /// the label if set (picture and sound clips share it), else the type defaults. Video with audio has two (picture, sound).
    public var clipLabels: [LabelColor] {
        if let label { return [label] }
        switch kind {
        case .audio: return [.audioDefault]
        case .image: return [.imageDefault]
        case .videoAudio: return [.videoDefault, .audioDefault]
        default: return [.videoDefault]
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

/// Value snapshot of everything needed to color clips; the timeline view holds one (no Project dependency).
public struct LabelResolver: Sendable, Equatable {
    var mediaLabels: [MediaRef.ID: LabelColor] = [:]
    var imageMedia: Set<MediaRef.ID> = []
    var sequenceLabels: [Timeline.ID: LabelColor] = [:]

    public init() {}

    /// Color a clip draws in: its own label, else the label of its sequence / media, else the default for its type.
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

    /// Colors a Project panel item wears (see `MediaRef.clipLabels`); sequences and bins have one.
    public func clipLabels(of ref: BinItemRef) -> [LabelColor] {
        if case .media(let id) = ref, let m = media(id) { return m.clipLabels }
        return [label(of: ref)]
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

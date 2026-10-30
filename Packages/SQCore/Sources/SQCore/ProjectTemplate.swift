import Foundation

/// A starting point for a new project: sequence format, track counts and format variants, plus (user templates) the
/// media-free clips of the sequence it was saved from: title lines, emoji, adjustment layers and their element
/// transitions, so a new video starts with the title in place and only the text is replaced. Lives in its own
/// `.sqtemplate` file (never inside the project file). Built-ins cover the start window's 9:16 / 16:9 / Variants cards.
public struct ProjectTemplate: Sendable, Hashable, Codable, Identifiable {
    public struct VariantSpec: Sendable, Hashable, Codable {
        public var name: String
        public var width: Int
        public var height: Int
        public init(name: String, width: Int, height: Int) { self.name = name; self.width = width; self.height = height }
    }

    public static let maxTracks = 16

    public var id: String
    public var name: String
    public var summary: String
    public var format: SequenceFormat
    public var videoTracks: Int
    public var audioTracks: Int
    public var variants: [VariantSpec]
    public var deliveryTarget: DeliveryTarget?
    /// The template sequence with only its generator clips (text, shapes, adjustment layers) and the transitions between
    /// them; no media, captions, markers or In/Out. nil = an empty sequence of `videoTracks` + `audioTracks`.
    public var content: Timeline?
    /// The Style Kit (caption look, fonts, colors) the template was saved with; a new project starts with it.
    public var styleKit: StyleKit?

    /// True when new projects start with clips (titles, emoji, adjustment layers).
    public var hasContent: Bool { content.map { $0.tracks.contains { !$0.clips.isEmpty } } ?? false }

    /// On-disk format. 2 (G11): the content has a graphics layer that follows another; it is then written under
    /// `contentV2`, so a build without Follow drops it (as any content it cannot read) instead of drawing the followers
    /// where they were authored. 3: the content has Fast Cut attachments between its graphics (v67 field); a build without
    /// Fast Cut drops the content instead of losing them silently. 4: an item of a Graphic has a range
    /// (`GraphicsLayer.range`, v74 field); a build without item ranges drops the content instead of drawing every item for
    /// the whole clip. Templates without any of these write no version and stay byte-identical.
    public static let formatVersion = 4
    public var writtenFormatVersion: Int {
        if content?.containsItemRanges == true { return 4 }
        if content?.hasAttachments == true { return 3 }
        return content?.containsFollow == true ? 2 : 1
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, summary, format, videoTracks, audioTracks, variants, deliveryTarget, content, contentV2,
             styleKit
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(summary, forKey: .summary)
        try c.encode(format, forKey: .format)
        try c.encode(videoTracks, forKey: .videoTracks)
        try c.encode(audioTracks, forKey: .audioTracks)
        try c.encode(variants, forKey: .variants)
        try c.encodeIfPresent(deliveryTarget, forKey: .deliveryTarget)
        let v = writtenFormatVersion
        if v > 1 { try c.encode(v, forKey: .formatVersion) }
        try c.encodeIfPresent(content, forKey: v > 1 ? .contentV2 : .content)
        try c.encodeIfPresent(styleKit, forKey: .styleKit)
    }

    /// Content a build cannot read (a newer build saved it) is dropped; the template itself still loads.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        format = try c.decode(SequenceFormat.self, forKey: .format)
        videoTracks = try c.decodeIfPresent(Int.self, forKey: .videoTracks) ?? SequenceDefaults.videoTrackCount
        audioTracks = try c.decodeIfPresent(Int.self, forKey: .audioTracks) ?? SequenceDefaults.audioTrackCount
        variants = try c.decodeIfPresent([VariantSpec].self, forKey: .variants) ?? []
        deliveryTarget = try c.decodeIfPresent(DeliveryTarget.self, forKey: .deliveryTarget)
        let v = (try? c.decodeIfPresent(Int.self, forKey: .formatVersion)) ?? 1
        if v > Self.formatVersion {
            content = nil
        } else {
            content = (try? c.decodeIfPresent(Timeline.self, forKey: v > 1 ? .contentV2 : .content)) ?? nil
        }
        styleKit = (try? c.decodeIfPresent(StyleKit.self, forKey: .styleKit)) ?? nil
    }

    public init(id: String, name: String, summary: String = "", format: SequenceFormat, videoTracks: Int = SequenceDefaults.videoTrackCount, audioTracks: Int = SequenceDefaults.audioTrackCount,
                variants: [VariantSpec] = [], deliveryTarget: DeliveryTarget? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.format = format
        self.videoTracks = videoTracks; self.audioTracks = audioTracks
        self.variants = variants; self.deliveryTarget = deliveryTarget
    }

    /// Captures the sequence's format, track counts, variants, delivery target and its media-free clips (`content`).
    public init(capturing t: Timeline, name: String, styleKit: StyleKit? = nil, id: String = "user-" + UUID().uuidString) {
        let content = Self.graphicsOnly(t)
        let n = content.map { $0.tracks.reduce(0) { $0 + $1.clips.count } } ?? 0
        self.init(id: id, name: name, summary: "\(t.format.width) × \(t.format.height)" + (n > 0 ? ", \(n) graphics" : ""),
                  format: t.format,
                  videoTracks: t.tracks.filter { $0.kind == .video }.count,
                  audioTracks: t.tracks.filter { $0.kind == .audio }.count,
                  variants: t.variants.map { VariantSpec(name: $0.name, width: $0.width, height: $0.height) },
                  deliveryTarget: t.deliveryTarget)
        self.content = content
        self.styleKit = styleKit
    }

    /// `t` with only its generator clips (and the transitions that touch nothing else); nil when none is left. Track
    /// layout, names, locks and audio roles stay; media, nested sequences, captions, markers and In/Out go.
    static func graphicsOnly(_ t: Timeline) -> Timeline? {
        var out = t
        out.markers = []; out.inOut = nil; out.inOutKind = nil; out.captionTracks = []; out.group = nil
        // A new sequence's edit mode comes from the preference, not from the template; attachments to clips that are not
        // kept (media) go, those between kept graphics stay (and gate the format, see `writtenFormatVersion`).
        out.editMode = .normal
        out.tracks = t.tracks.map { tr in
            let kept = tr.clips.filter { $0.generator != nil }
            let ids = Set(kept.map(\.id))
            let transitions = tr.transitions.filter { x in [x.incoming, x.outgoing].compactMap { $0 }.allSatisfy(ids.contains) }
            var n = Track(id: tr.id, kind: tr.kind, clips: kept, isLocked: tr.isLocked, syncLock: tr.syncLock, name: tr.name,
                          isVisible: tr.isVisible, isMuted: tr.isMuted, isSolo: tr.isSolo, isTargeted: tr.isTargeted,
                          height: tr.height, transitions: transitions)
            n.volumeDB = tr.volumeDB; n.pan = tr.pan; n.audioRole = tr.audioRole
            return n
        }
        out.dropAttachmentsToMissingHosts()
        return out.tracks.contains { !$0.clips.isEmpty } ? out : nil
    }

    /// First unused name: "Reel", "Reel 2", "Reel 3"... (case-insensitive, trimmed).
    public static func freeName(_ base: String, taken: [String]) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let used = Set(taken.map { $0.lowercased() })
        var name = base
        var n = 1
        while used.contains(name.lowercased()) { n += 1; name = "\(base) \(n)" }
        return name
    }

    public enum Invalid: Error, Equatable { case emptyName, badSize }

    /// A template needs a name and positive, sane sizes (format and variants).
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid.emptyName }
        let range = 1...SequenceFormatPresets.maxDimension
        let sizes = [(format.width, format.height)] + variants.map { ($0.width, $0.height) }
        guard sizes.allSatisfy({ range.contains($0.0) && range.contains($0.1) }) else { throw Invalid.badSize }
    }

    /// A ready project: one locked sequence (so imported footage never changes the format), 4V + 4A by default.
    public func makeProject(name: String) -> Project {
        if var tl = content {
            tl.id = UUID()
            tl.name = "Sequence 01"
            tl.format = format
            tl.formatLocked = true
            tl.deliveryTarget = deliveryTarget
            var p = Project(name: name, timelines: [tl])
            p.styleKit = styleKit
            return p
        }
        var tl = Timeline(name: "Sequence 01", format: format,
                          tracks: Timeline.defaultTracks(video: min(max(videoTracks, 0), Self.maxTracks),
                                                         audio: min(max(audioTracks, 0), Self.maxTracks)),
                          formatLocked: true)
        tl.deliveryTarget = deliveryTarget
        for v in variants { _ = try? tl.addVariant(name: v.name, width: v.width, height: v.height) }
        var p = Project(name: name, timelines: [tl])
        p.styleKit = styleKit
        return p
    }

    /// A new sequence for an existing project (File > New Sequence from Template): same layout as `makeProject`'s
    /// sequence, but the format stays unlocked like any other sequence.
    public func makeSequence(name: String) -> Timeline {
        var tl = makeProject(name: name).timelines[0]
        tl.name = name
        tl.formatLocked = false
        return tl
    }

    // MARK: Built-ins

    public static let vertical = ProjectTemplate(
        id: "builtin-vertical-9x16", name: "Vertical 9:16", summary: "1080 × 1920, 30 fps. TikTok, Reels, Shorts.",
        format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
        deliveryTarget: DeliveryTarget(platform: .tiktok))

    public static let horizontal = ProjectTemplate(
        id: "builtin-horizontal-16x9", name: "Horizontal 16:9", summary: "1920 × 1080, 30 fps. YouTube.",
        format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
        deliveryTarget: DeliveryTarget(platform: .youtube))

    public static let variants = ProjectTemplate(
        id: "builtin-variants", name: "Variants", summary: "9:16 master with 16:9 and 1:1 variants.",
        format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
        variants: [VariantSpec(name: "16:9", width: 1920, height: 1080), VariantSpec(name: "1:1", width: 1080, height: 1080)],
        deliveryTarget: DeliveryTarget(platform: .tiktok))

    public static let builtIn: [ProjectTemplate] = [vertical, horizontal, variants]
}

/// A folder of `.sqtemplate` files (JSON, one template each). Foundation only; unreadable files are skipped.
public struct TemplateFolder: Sendable {
    public static let fileExtension = "sqtemplate"
    public var url: URL
    public init(url: URL) { self.url = url }

    private func file(for t: ProjectTemplate) -> URL {
        let safe = t.id.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return url.appendingPathComponent(safe).appendingPathExtension(Self.fileExtension)
    }

    public func save(_ t: ProjectTemplate) throws {
        try t.validate()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(t).write(to: file(for: t), options: .atomic)
    }

    /// Renames in place (same id, same file). Throws `emptyName` for a blank name.
    @discardableResult
    public func rename(_ t: ProjectTemplate, to name: String) throws -> ProjectTemplate {
        var n = t
        n.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(n)
        return n
    }

    public func delete(_ t: ProjectTemplate) throws { try FileManager.default.removeItem(at: file(for: t)) }

    /// Sorted by name. Invalid templates are skipped; an id that collides with a built-in or an earlier template is replaced.
    public func load() -> [ProjectTemplate] {
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        var seen = Set(ProjectTemplate.builtIn.map(\.id))
        var out: [ProjectTemplate] = []
        for f in files.filter({ $0.pathExtension == Self.fileExtension }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard var t = try? JSONDecoder().decode(ProjectTemplate.self, from: Data(contentsOf: f)), (try? t.validate()) != nil else { continue }
            if !seen.insert(t.id).inserted {
                t.id = "user-" + UUID().uuidString
                seen.insert(t.id)
            }
            out.append(t)
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

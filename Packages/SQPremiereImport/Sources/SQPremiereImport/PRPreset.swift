import Foundation
import SQCore

// Premiere effect presets (.prfpset, "Effect Presets and Custom Items"): the same object table as a project
// (docs/PRPROJ-IMPORT.md "Effect presets"). Tree "1" -> RootBin -> BinTreeItem folders (TreeItemBase/Name, Items/Item)
// -> leaf TreeItem (TreeItemBase/Data) -> FilterPresetItem (FilterPresets/FilterPreset) -> FilterPreset (Type, anchor
// points, Component) -> VideoFilterComponent / AudioFilterComponent, read like a clip's components.

/// One effect of a preset with its timing frame.
public struct PRPresetFilter: Sendable {
    /// Premiere's preset type: 0 Scale (keys stretch with the clip), 1 Anchor to In Point, 2 Anchor to Out Point.
    public var type: Int
    /// The saved clip's source range (ticks); key times are absolute in that range.
    public var anchorIn: Int64, anchorOut: Int64
    public var speed: Double
    /// Audio only: 0 mono, 1 stereo, 2 5.1. Premiere saves one instance per channel type.
    public var channelType: Int?
    public var component: PRComponent
    /// Object id of the FilterPreset (dedupes shortcut copies of a folder).
    public var objectID: String

    public var anchor: EffectPreset.Anchor {
        switch type { case 1: .start; case 2: .end; default: .stretch }
    }
    /// Length of the clip the preset was saved from.
    public var referenceDuration: Time { PRTicks.time(max(0, anchorOut - anchorIn)) }
}

public struct PRPreset: Sendable {
    /// Folders below the root bin, outermost first.
    public var folders: [String]
    public var name: String
    public var filters: [PRPresetFilter]
    /// Other folders listing the same preset (a folder added again as a shortcut, or copied into another folder).
    public var aliasFolders: [[String]] = []
    public var path: String { (folders + [name]).joined(separator: " / ") }

    /// The content (timing + every param), independent of object ids.
    var signature: String {
        filters.map { "\($0.type)|\($0.anchorOut - $0.anchorIn)|\($0.channelType ?? -1)|\($0.component.matchName)|\($0.component.params)" }
            .joined(separator: "\n")
    }
}

public enum PRPresetReader {
    public static func read(url: URL) throws -> [PRPreset] { try read(data: Data(contentsOf: url)) }

    /// Every preset leaf in tree order. A preset whose filters are already listed (a shortcut copy of a folder) is not
    /// repeated: its folder joins the first one's `aliasFolders`.
    public static func read(data: Data) throws -> [PRPreset] {
        let t = try PRObjectTable(xml: PRGzip.inflate(data))
        guard let tree = t["1"] ?? t.all(named: "Tree").first, let root = t.deref(tree.child("RootBin")) else {
            throw PRImportError.notPremiereProject
        }
        var out = [PRPreset](), seenFilters = [[String]: Int](), visited = Set<String>()
        func walk(_ n: PRNode, _ folders: [String]) {
            if let id = n.objectID { guard visited.insert(id).inserted else { return } }
            let name = n.text("TreeItemBase/Name") ?? ""
            if n.child("Items") != nil {
                for item in n.children("Items/Item") { if let c = t.deref(item) { walk(c, folders + [name]) } }
                return
            }
            guard let data = t.deref(n.child("TreeItemBase/Data")), data.name == "FilterPresetItem" else { return }
            let refs = data.children("FilterPresets/FilterPreset").compactMap(\.reference)
            guard !refs.isEmpty else { return }
            let below = Array(folders.dropFirst())
            if let i = seenFilters[refs] { out[i].aliasFolders.append(below); return }
            seenFilters[refs] = out.count
            let filters = refs.compactMap { r in t[r].flatMap { filter($0, t) } }
            out.append(PRPreset(folders: below, name: name, filters: filters))
        }
        walk(root, [])
        return out
    }

    static func filter(_ f: PRNode, _ t: PRObjectTable) -> PRPresetFilter? {
        guard let c = t.deref(f.child("Component")), let comp = PRReader.component(c, t) else { return nil }
        let channel = c.name == "AudioFilterComponent" ? c.text("AudioComponent/ChannelType").flatMap { Int($0) } : nil
        return PRPresetFilter(type: f.text("Type").flatMap { Int($0) } ?? 0,
                              anchorIn: f.int("AnchorInPoint") ?? 0, anchorOut: f.int("AnchorOutPoint") ?? 0,
                              speed: PRParamValue.double(f.text("Speed")) ?? 1, channelType: channel,
                              component: comp, objectID: f.objectID ?? "")
    }
}

/// A Premiere preset as an SQ effect preset.
public struct PRMappedPreset: Sendable {
    /// Library name: the preset's own name, with its folder added when another imported preset has the same name.
    public var name: String
    public var path: String
    public var preset: EffectPreset
    /// What was approximated or dropped for this preset (empty = 1:1).
    public var notes: [String]
}

public struct PRPresetImport: Sendable {
    public struct Skipped: Sendable, Equatable { public var path: String; public var reason: String }
    public var presets: [PRMappedPreset]
    public var skipped: [Skipped]
    public var report: PRImportReport
}

public enum PRPresetMapper {
    /// Folders never imported (none: the maintainer wants his Zoom Transition presets, 2026-10-25).
    public static let ignoredFolders: Set<String> = []
    /// Dropped parts that leave the rest of a preset usable (imported with a note).
    static let partialDrops: Set<String> = ["Volume in a preset", "Blend mode in a preset"]

    /// `frame`: the picture size positions and anchors are converted against (Premiere stores them normalized).
    public static func map(_ presets: [PRPreset], frame: (width: Int, height: Int) = (1080, 1920),
                           ignoring ignored: Set<String> = ignoredFolders) -> PRPresetImport {
        var out = [PRMappedPreset](), skipped = [PRPresetImport.Skipped](), report = PRImportReport()
        var signatures = Set<String>()
        for p in presets {
            if ([p.folders] + p.aliasFolders).contains(where: { !ignored.isDisjoint(with: $0) }) {
                skipped.append(.init(path: p.path, reason: "ignored folder")); continue
            }
            // Same name, same content (a preset saved twice): import once.
            guard signatures.insert(p.name + "\n" + p.signature).inserted else { continue }
            let (preset, r) = mapOne(p, frame: frame)
            for e in r.entries { for _ in 0..<e.count { report.note(e.feature, e.status, e.note) } }
            // An effect SQ cannot do would leave a different look or sound than the preset promises: not imported.
            let missing = r.entries.filter { $0.status == .dropped && !partialDrops.contains($0.feature) }
                .map { $0.note.isEmpty ? $0.feature : "\($0.feature) (\($0.note))" }
            guard let preset, !preset.isEmpty, missing.isEmpty else {
                skipped.append(.init(path: p.path, reason: missing.isEmpty ? "nothing to import" : "no SQ equivalent: " + missing.joined(separator: ", ")))
                continue
            }
            let notes = r.entries.filter { $0.status != .mapped }.map { "\($0.status.label): \($0.feature)" + ($0.note.isEmpty ? "" : " (\($0.note))") }
            out.append(PRMappedPreset(name: p.name, path: p.path, preset: preset, notes: notes))
        }
        // Same name, other content: add the folder.
        var unique = out
        let counts = Dictionary(grouping: unique, by: \.name).mapValues(\.count)
        for i in unique.indices where counts[unique[i].name, default: 0] > 1 {
            if let folder = presets.first(where: { $0.path == unique[i].path })?.folders.last { unique[i].name += " (\(folder))" }
        }
        return PRPresetImport(presets: unique, skipped: skipped, report: report)
    }

    /// One preset; nil when it has no filters.
    static func mapOne(_ p: PRPreset, frame size: (width: Int, height: Int)) -> (EffectPreset?, PRImportReport) {
        // Audio: Premiere keeps a mono, stereo and 5.1 instance of every effect; the stereo one is the one edited.
        let channels = Set(p.filters.compactMap(\.channelType))
        let channel = channels.contains(1) ? 1 : channels.min()
        let filters = p.filters.filter { $0.channelType == nil || $0.channelType == channel }
        guard let first = filters.first else { return (nil, PRImportReport()) }
        let seq = PRSequence(id: "preset", name: "Preset", width: size.width, height: size.height,
                             frameDuration: Time(1, 30), videoTracks: [], audioTracks: [])
        var m = Mapping(doc: PRDocument(sequences: []), probed: [:])
        let frame = Vec2(Double(size.width), Double(size.height))
        var preset = EffectPreset(anchor: first.anchor, referenceDuration: first.referenceDuration)
        let defaults = ClipAnimation()
        for f in filters {
            if f.speed != 1 { m.report.note("Preset clip speed", .approximated, "keys read at 100 %") }
            // Key times into the first filter's frame (all of the maintainer's presets share one frame; mixed ones are approximated).
            let retime: (Time) -> Time
            if f.anchor == first.anchor {
                let (r, r0) = (f.referenceDuration, first.referenceDuration)
                switch f.anchor {
                case .start: retime = { $0 }
                case .end: retime = { $0 - r + r0 }
                case .stretch: retime = { EffectPreset.mapTime($0, anchor: .stretch, reference: r, target: r0) }
                }
            } else {
                m.report.note("Preset with mixed anchors", .approximated, "keys placed as on the saved clip")
                let (a, r, r0) = (f.anchor, f.referenceDuration, first.referenceDuration)
                retime = { EffectPreset.mapTime($0, anchor: a, reference: r, target: r0) }
            }
            let ctx = ClipContext(inPoint: f.anchorIn, speed: .normal, sequence: seq)
            let c = f.component
            let item = PRItem(name: p.name, start: 0, end: f.anchorOut - f.anchorIn, inPoint: f.anchorIn, outPoint: f.anchorOut,
                              speed: 1, source: .unknown, components: [c], isAdjustmentLayer: false, isAudio: c.isAudio)
            if c.isAudio {
                var clip = Clip(name: p.name, media: UUID(), kind: .audio,
                                source: TimeRange(start: .zero, duration: f.referenceDuration), start: .zero)
                m.audio(item, ctx: ctx, into: &clip)
                if clip.animation.volume.isAnimated || clip.animation.volume.value != 1 {
                    m.report.note("Volume in a preset", .dropped, "SQ presets carry no clip volume")
                }
                preset.effects += clip.effects.map { retimed($0, retime) }
                continue
            }
            if c.matchName == "AE.ADBE Motion" || c.matchName == "AE.ADBE Opacity" {
                // Only what the preset changes (keyed or not at its default), as a preset saved in SQ.
                let a = m.motion(item, ctx: ctx, frame: frame, textOffset: .zero)
                func take<V>(_ v: AnimatedProperty<V>, _ d: AnimatedProperty<V>) -> AnimatedProperty<V>? {
                    v.isAnimated || v.value != d.value ? retimed(v, retime) : nil
                }
                if c.matchName == "AE.ADBE Motion" {
                    preset.position = take(a.position, defaults.position) ?? preset.position
                    preset.scale = take(a.scale, defaults.scale) ?? preset.scale
                    preset.rotation = take(a.rotation, defaults.rotation) ?? preset.rotation
                    preset.anchorPoint = take(a.anchor, defaults.anchor) ?? preset.anchorPoint
                    if preset.position != nil || preset.anchorPoint != nil {
                        m.report.note("Motion position / anchor in a preset", .approximated, "pixels of a \(size.width)x\(size.height) frame")
                    }
                } else {
                    preset.opacity = take(a.opacity, defaults.opacity) ?? preset.opacity
                    if m.blendMode(item) != .normal { m.report.note("Blend mode in a preset", .dropped, "SQ presets carry no blend mode") }
                }
            }
            let fx = m.effects(item, ctx: ctx, frame: frame, textOffset: .zero)
            if c.matchName == "AE.ADBE Geometry2", (PRParamValue.point(c.param(1)?.staticValue) ?? Vec2(0.5, 0.5)) != Vec2(0.5, 0.5) {
                m.report.note("Transform anchor in a preset", .approximated, "pixels of a \(size.width)x\(size.height) frame")
            }
            preset.effects += fx.map { retimed($0, retime) }
        }
        preset.effects = voiceChainOrdered(preset.effects)
        return (preset, m.report)
    }

    /// A .prfpset stores the effects grouped per effect type in no meaningful order (the maintainer's NTG preset is stored
    /// Multiband, Noise Reduction, EQ; Premiere applies it as EQ, Compressor, Noise Reduction; the file has no index
    /// field). The voice chain effects are put in Premiere's applied order, other effects keep their slots.
    static func voiceChainOrdered(_ effects: [ClipEffect]) -> [ClipEffect] {
        let order = [ClipEffect.audioParametricEQKind, ClipEffect.audioMultibandKind, ClipEffect.audioNoiseReductionKind]
        let slots = effects.indices.filter { order.contains(effects[$0].kind) }
        let sorted = slots.map { effects[$0] }.enumerated()
            .sorted { (order.firstIndex(of: $0.element.kind)!, $0.offset) < (order.firstIndex(of: $1.element.kind)!, $1.offset) }
            .map(\.element)
        var out = effects
        for (slot, e) in zip(slots, sorted) { out[slot] = e }
        return out
    }

    static func retimed<V>(_ p: AnimatedProperty<V>, _ f: (Time) -> Time) -> AnimatedProperty<V> {
        var c = p
        c.track = KeyframeTrack(keys: p.track.keys.map { var k = $0; k.time = f(k.time); return k })
        return c
    }

    static func retimed(_ e: ClipEffect, _ f: (Time) -> Time) -> ClipEffect {
        var e = e
        e.parameters = e.parameters.mapValues { retimed($0, f) }
        e.colors = e.colors.mapValues { retimed($0, f) }
        e.points = e.points.mapValues { retimed($0, f) }
        return e
    }
}

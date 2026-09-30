import Foundation
import Observation
import SSCore
import SSMedia

/// State and edit logic of the Project panel. Holds a `Project` value; every mutating action applies to a copy,
/// reports it through `onEdit(project, actionName)` (one undo step per action) and then adopts it.
/// The app pushes external changes (undo, open) in with `setProject`.
@MainActor @Observable
public final class ProjectPanelModel {
    public typealias Probe = @Sendable (URL) async throws -> MediaRef
    public typealias EditHandler = (Project, String) -> Void

    public enum Column: String, Sendable, CaseIterable { case name, format, duration }

    public private(set) var project: Project
    /// Bin that receives imports and new bins.
    public var currentBin: Bin.ID
    public var searchText = "" { didSet { revision += 1 } }
    public private(set) var sortColumn: Column?
    public private(set) var sortAscending = true
    /// Number of files still being probed.
    public private(set) var pendingImports = 0
    /// File names of the last imports that could not be read.
    public private(set) var importFailures: [String] = []
    public private(set) var offline: Set<MediaRef.ID> = []
    /// Bumped on every change the view must reload for.
    public private(set) var revision = 0

    @ObservationIgnored private let probe: Probe
    @ObservationIgnored private let onEdit: EditHandler
    @ObservationIgnored private let status: @Sendable (MediaRef) -> MediaStatus

    public init(project: Project,
                probe: @escaping Probe = { try await MediaImporter.probe($0).0 },
                status: @escaping @Sendable (MediaRef) -> MediaStatus = { $0.status() },
                onEdit: @escaping EditHandler) {
        var p = project
        p.normalizeBins()
        self.project = p
        self.currentBin = p.rootBin.id
        self.probe = probe
        self.status = status
        self.onEdit = onEdit
        refreshOffline()
    }

    public func setProject(_ p: Project) {
        var p = p
        p.normalizeBins()
        project = p
        if project.bin(currentBin) == nil { currentBin = project.rootBin.id }
        refreshOffline()
        revision += 1
    }

    /// Re-checks the files of all media items. Offline means nothing is at the stored path.
    public func refreshOffline() {
        offline = Set(project.media.filter { status($0) == .missing }.map(\.id))
        revision += 1
    }

    public func isOffline(_ id: MediaRef.ID) -> Bool { offline.contains(id) }

    // MARK: Editing

    private func commit(_ name: String, _ body: (inout Project) -> Bool) -> Bool {
        var p = project
        guard body(&p), p != project else { return false }
        project = p
        revision += 1
        onEdit(p, name)
        return true
    }

    /// Creates a bin in the current bin and returns its ID.
    @discardableResult
    public func newBin(name: String = "Bin") -> Bin.ID? {
        var id: Bin.ID?
        let parent = currentBin
        _ = commit("New Bin") { id = $0.newBin(name: name, in: parent); return id != nil }
        return id
    }

    @discardableResult
    public func rename(_ ref: BinItemRef, to name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return commit("Rename") { p in
            switch ref {
            case .bin(let id): return p.renameBin(id, to: name)
            case .media(let id):
                guard let i = p.media.firstIndex(where: { $0.id == id }) else { return false }
                p.media[i].name = name; return true
            case .sequence(let id):
                guard let i = p.timelines.firstIndex(where: { $0.id == id }) else { return false }
                p.timelines[i].name = name; return true
            }
        }
    }

    @discardableResult
    public func move(_ items: [BinItemRef], to dest: Bin.ID, at index: Int? = nil) -> Bool {
        commit("Move") { $0.move(items, to: dest, at: index) }
    }

    /// Deletes bins (their content moves up) and media not used by any sequence. The root bin and sequences are kept.
    /// Returns false when nothing was deleted.
    @discardableResult
    public func delete(_ items: [BinItemRef]) -> Bool {
        commit("Delete") { p in
            var changed = false
            for r in items {
                switch r {
                case .bin(let id): if p.deleteBin(id) { changed = true }
                case .media(let id):
                    let used = p.timelines.contains { $0.tracks.contains { $0.clips.contains { $0.media == id } } }
                    guard !used, p.media.contains(where: { $0.id == id }) else { continue }
                    p.media.removeAll { $0.id == id }
                    p.normalizeBins()
                    changed = true
                case .sequence: continue
                }
            }
            return changed
        }
    }

    // MARK: Import

    /// Probes `urls` in the background and files the new items in the current bin as one undo step.
    /// Files already in the project (same path) are skipped; unreadable files end up in `importFailures`.
    public func importFiles(_ urls: [URL]) async {
        let known = Set(project.media.map(\.path))
        var seen = Set<String>()
        let todo = urls.filter { !known.contains($0.path) && seen.insert($0.path).inserted }
        guard !todo.isEmpty else { return }
        importFailures = []
        pendingImports += todo.count
        let probe = self.probe
        let results: [(URL, MediaRef?)] = await withTaskGroup(of: (Int, URL, MediaRef?).self) { group in
            for (i, url) in todo.enumerated() {
                group.addTask { (i, url, try? await probe(url)) }
            }
            var out: [(Int, URL, MediaRef?)] = []
            for await r in group { out.append(r); pendingImports -= 1 }
            return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
        importFailures = results.filter { $0.1 == nil }.map { $0.0.lastPathComponent }
        let refs = results.compactMap(\.1)
        guard !refs.isEmpty else { revision += 1; return }
        let dest = project.bin(currentBin) != nil ? currentBin : project.rootBin.id
        _ = commit(refs.count == 1 ? "Import Media" : "Import \(refs.count) Media Items") { p in
            for r in refs { p.add(r) }
            if dest != p.rootBin.id { p.move(refs.map { .media($0.id) }, to: dest) }
            return true
        }
        refreshOffline()
    }

    // MARK: Display (sort + filter are display-only)

    public func setSort(_ column: Column?, ascending: Bool) {
        sortColumn = column; sortAscending = ascending; revision += 1
    }

    /// Children of `bin` as shown: filtered by the search text, sorted by the active column (bins first).
    public func children(of bin: Bin) -> [BinItem] {
        var q = searchText.trimmingCharacters(in: .whitespaces)
        // A bin whose own name matches shows its full content.
        if !q.isEmpty, bin.id != project.rootBin.id, bin.name.localizedCaseInsensitiveContains(q) { q = "" }
        var items = bin.children
        if !q.isEmpty { items = items.filter { matches($0, q) } }
        guard let col = sortColumn else { return items }
        func rank(_ i: BinItem) -> Int { if case .bin = i.ref { 0 } else { 1 } }
        func key(_ i: BinItem) -> String {
            switch (col, i) {
            case (.name, _): return project.displayName(of: i.ref)
            case (.format, .media(let id)): return project.media(id).map(Self.formatString) ?? ""
            case (.duration, .media(let id)): return String(format: "%020.6f", project.media(id)?.duration.map(Self.seconds) ?? 0)
            default: return ""
            }
        }
        let keys = items.map(key)
        let order = items.indices.sorted { l, r in
            let a = items[l], b = items[r]
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            let c = keys[l].localizedStandardCompare(keys[r])
            if c == .orderedSame { return l < r }
            return (c == .orderedAscending) == sortAscending
        }
        return order.map { items[$0] }
    }

    private func matches(_ item: BinItem, _ q: String) -> Bool {
        switch item {
        case .bin(let b):
            return b.name.localizedCaseInsensitiveContains(q) || b.children.contains { matches($0, q) }
        default:
            return project.displayName(of: item.ref).localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: Formatting

    static func seconds(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

    static func codecName(_ fourCC: String) -> String {
        switch fourCC {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "apch": "ProRes 422 HQ"
        case "apcn": "ProRes 422"
        case "apcs": "ProRes 422 LT"
        case "apco": "ProRes 422 Proxy"
        case "ap4h": "ProRes 4444"
        case "ap4x": "ProRes 4444 XQ"
        case "av01": "AV1"
        default: fourCC.trimmingCharacters(in: .whitespaces)
        }
    }

    /// "3840×2160 29.97 H.264 4:2:2 10-bit"; audio-only: "48 kHz 2 ch AAC"; "" without probe info.
    public static func formatString(_ m: MediaRef) -> String {
        if let v = m.info?.video {
            let fps = Double(v.nominalFrameDuration.timescale) / Double(v.nominalFrameDuration.value)
            var f = String(format: "%.2f", fps)
            while f.hasSuffix("0") { f.removeLast() }
            if f.hasSuffix(".") { f.removeLast() }
            return "\(v.width)×\(v.height) \(f)\(v.isVariableFrameRate ? " VFR" : "") \(codecName(v.codec)) \(v.chroma) \(v.bitDepth)-bit"
        }
        if let a = m.info?.audio {
            var khz = String(format: "%.1f", Double(a.sampleRate) / 1000)
            if khz.hasSuffix(".0") { khz.removeLast(2) }
            return "\(khz) kHz \(a.channels) ch \(a.codec.trimmingCharacters(in: .whitespaces))"
        }
        return ""
    }

    /// HH:MM:SS:FF (non-drop, frame rate rounded); audio-only HH:MM:SS; "" when unknown.
    public static func durationString(_ m: MediaRef) -> String {
        guard let d = m.duration ?? m.info?.duration, !d.isNegative else { return "" }
        func two(_ n: Int64) -> String { n < 10 ? "0\(n)" : "\(n)" }
        if let fd = m.info?.video?.nominalFrameDuration {
            let fps = max(1, Int64((Double(fd.timescale) / Double(fd.value)).rounded()))
            let frames = d.frameIndex(frameDuration: fd)
            let s = frames / fps
            return "\(two(s / 3600)):\(two(s / 60 % 60)):\(two(s % 60)):\(two(frames % fps))"
        }
        let s = d.value / d.timescale
        return "\(two(s / 3600)):\(two(s / 60 % 60)):\(two(s % 60))"
    }

    // MARK: Pasteboard

    /// Custom pasteboard type carrying item IDs.
    nonisolated public static let pasteboardTypeName = "com.sequencestudio.media-ids"

    public static func encodeItems(_ refs: [BinItemRef]) -> String {
        refs.map { r in
            switch r {
            case .bin(let id): "b:\(id.uuidString)"
            case .media(let id): "m:\(id.uuidString)"
            case .sequence(let id): "s:\(id.uuidString)"
            }
        }.joined(separator: "\n")
    }

    public static func decodeItems(_ s: String) -> [BinItemRef] {
        s.split(separator: "\n").compactMap { line in
            guard line.count > 2, let id = UUID(uuidString: String(line.dropFirst(2))) else { return nil }
            switch line.prefix(2) {
            case "b:": return .bin(id)
            case "m:": return .media(id)
            case "s:": return .sequence(id)
            default: return nil
            }
        }
    }
}

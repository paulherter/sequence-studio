import Foundation
import Observation
import SQCore
import SQMedia

/// State and edit logic of the Project panel. Holds a `Project` value; every mutating action applies to a copy,
/// reports it through `onEdit(project, actionName)` (one undo step per action) and then adopts it.
/// The app pushes external changes (undo, open) in with `setProject`.
@MainActor @Observable
public final class ProjectPanelModel {
    public typealias Probe = @Sendable (URL) async throws -> MediaRef
    public typealias EditHandler = (Project, String) -> Void

    /// Columns the Project panel can show. `name` is always shown, first.
    public enum Column: String, Sendable, CaseIterable, Codable {
        case name, label, frameRate, duration, resolution, codec, audio, inPoint, filePath, format

        public var title: String {
            switch self {
            case .name: "Name"
            case .label: "Label"
            case .frameRate: "Frame Rate"
            case .duration: "Duration"
            case .resolution: "Resolution"
            case .codec: "Codec"
            case .audio: "Audio"
            case .inPoint: "Source In"
            case .filePath: "File Path"
            case .format: "Format"
            }
        }
        public var defaultWidth: CGFloat {
            switch self {
            case .name: 200
            case .label: 80
            case .frameRate: 90
            case .duration: 90
            case .resolution: 90
            case .codec: 110
            case .audio: 100
            case .inPoint: 90
            case .filePath: 260
            case .format: 210
            }
        }
        public var minWidth: CGFloat { self == .name ? 100 : 50 }
    }

    public private(set) var project: Project
    /// Bin that receives imports and new bins.
    public var currentBin: Bin.ID
    /// Bin the icon view shows (double-click a bin to enter it).
    public var browseBin: Bin.ID { didSet { if oldValue != browseBin { revision += 1 } } }
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

    /// Source In/Out set from the panel (`I` / `O` while hover scrubbing): not an undo step, the host stores the marks.
    @ObservationIgnored public var onSourceMarks: ((MediaRef.ID, SourceMarks?) -> Void)?
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
        self.browseBin = p.rootBin.id
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
        if project.bin(browseBin) == nil { browseBin = project.rootBin.id }
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
        // Dropping items on the bin they already sit in (no insertion position) is a no-op, not "move to the bottom".
        if index == nil, let d = project.bin(dest), items.allSatisfy({ r in d.children.contains { $0.ref == r } }) { return false }
        return commit("Move") { $0.move(items, to: dest, at: index) }
    }

    /// Sets the label of the media items and sequences in `items` (nil = back to the type default): one undo step.
    @discardableResult
    public func setLabel(_ label: LabelColor?, for items: [BinItemRef]) -> Bool {
        commit("Change Label") { $0.setLabel(label, for: items) }
    }

    /// Label colour shown for an item.
    public func label(of ref: BinItemRef) -> LabelColor { project.label(of: ref) }

    /// What `delete` did. `blockedBy` lists the sequence names that kept items from being deleted: sequences that still
    /// use a media item, or that nest a sequence (each name once, project order). `message` is the status line for it.
    public struct DeleteResult: Sendable, Equatable {
        public var changed = false
        public var blockedBy: [String] = []
        public var blockedItems = 0
        public var message: String? {
            guard blockedItems > 0 else { return nil }
            let names = blockedBy.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ") + (blockedBy.count > 3 ? " and more" : "")
            return blockedBy.isEmpty ? "The last sequence cannot be deleted." : "Not deleted: still used in \(names)."
        }
    }

    /// Deletes bins (their content moves up), media not used by any sequence, and sequences (never the last one, nor one
    /// that another sequence nests). The root bin is kept. One undo step. Items that are in use stay and their sequence
    /// names come back in `blockedBy`.
    @discardableResult
    public func delete(_ items: [BinItemRef]) -> DeleteResult {
        var result = DeleteResult()
        func block(_ names: [String]) {
            result.blockedItems += 1
            for n in names where !result.blockedBy.contains(n) { result.blockedBy.append(n) }
        }
        result.changed = commit("Delete") { p in
            var changed = false
            for r in items {
                switch r {
                case .bin(let id): if p.deleteBin(id) { changed = true }
                case .media(let id):
                    guard p.media.contains(where: { $0.id == id }) else { continue }
                    let users = p.sequenceNames(using: id)
                    guard users.isEmpty else { block(users); continue }
                    p.media.removeAll { $0.id == id }
                    p.sourceMarks[id] = nil
                    p.normalizeBins()
                    changed = true
                case .sequence(let id):
                    let nesting = p.sequenceNames(nesting: id)
                    if p.deleteSequence(id) { changed = true } else { block(nesting) }
                }
            }
            return changed
        }
        return result
    }

    // MARK: Hover marks (I / O over a thumbnail)

    /// `I` (`isIn`) or `O` while hover scrubbing at `time`: writes the media's Source marks like the Source monitor does
    /// (Out includes its own frame, so it is stored one frame later). Returns false for unknown media.
    @discardableResult
    public func markFromHover(isIn: Bool, media id: MediaRef.ID, time: Time) -> Bool {
        guard let ref = project.media(id) else { return false }
        let fd = ref.info?.video?.nominalFrameDuration ?? Time(1, 30)
        var p = project
        if isIn { p.setSourceIn(time, for: id) } else { p.setSourceOut(time + fd, for: id) }
        project = p
        revision += 1
        onSourceMarks?(id, p.sourceMarks[id])
        return true
    }

    // MARK: Find (Cmd+F)

    /// Find criteria of the Project panel: text in the name (or label name) and/or offline items only.
    public struct FindCriteria: Sendable, Equatable {
        public enum Field: String, Sendable, CaseIterable { case name, label }
        public var text = ""
        public var field: Field = .name
        public var offlineOnly = false
        public init(text: String = "", field: Field = .name, offlineOnly: Bool = false) {
            self.text = text; self.field = field; self.offlineOnly = offlineOnly
        }
        public var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && !offlineOnly }
    }

    /// Items (media and sequences, in tree order, bins skipped) that match all criteria. Empty criteria match nothing.
    public func find(_ c: FindCriteria) -> [BinItemRef] {
        guard !c.isEmpty else { return [] }
        let q = c.text.trimmingCharacters(in: .whitespaces)
        var out: [BinItemRef] = []
        func walk(_ bin: Bin) {
            for child in bin.children {
                if case .bin(let b) = child { walk(b); continue }
                let ref = child.ref
                if c.offlineOnly {
                    guard case .media(let id) = ref, offline.contains(id) else { continue }
                }
                if !q.isEmpty {
                    let hay = c.field == .name ? project.displayName(of: ref) : project.label(of: ref).displayName
                    guard hay.localizedCaseInsensitiveContains(q) else { continue }
                }
                out.append(ref)
            }
        }
        walk(project.rootBin)
        return out
    }

    // MARK: Poster frame (Cmd+P / Option+P)

    /// Sets (or with nil clears) the poster frame of media items: one undo step. Items that are not media are skipped.
    @discardableResult
    public func setPoster(_ time: Time?, for items: [BinItemRef]) -> Bool {
        commit(time == nil ? "Clear Poster Frame" : "Set Poster Frame") { p in
            var changed = false
            for r in items { if case .media(let id) = r, p.setPosterTime(time, for: id) { changed = true } }
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
            case (.duration, .media(let id)): return String(format: "%020.6f", project.media(id)?.duration.map(Self.seconds) ?? 0)
            case (.frameRate, .media(let id)):
                return String(format: "%020.6f", project.media(id)?.info?.video.map { 1 / Self.seconds($0.nominalFrameDuration) } ?? 0)
            default: return cellText(col, i.ref)
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
            if m.info?.isStill == true { return "\(v.displayWidth)×\(v.displayHeight) Still image" }
            return "\(v.displayWidth)×\(v.displayHeight) \(f)\(v.isVariableFrameRate ? " VFR" : "") \(codecName(v.codec)) \(v.chroma) \(v.bitDepth)-bit"
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

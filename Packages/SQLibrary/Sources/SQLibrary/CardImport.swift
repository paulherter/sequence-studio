import Foundation
import SQCore

/// Logic behind the "import from SD card / external drive" window. No AppKit: the App target feeds it volume facts and
/// shows the result.

public enum CardMediaKind: String, Sendable, CaseIterable {
    case video, photo
}

/// One importable file found on a volume.
public struct CardCandidate: Sendable, Equatable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let kind: CardMediaKind
    public let size: Int64
    public let modified: Date
    public var name: String { url.lastPathComponent }
    public init(url: URL, kind: CardMediaKind, size: Int64, modified: Date) {
        self.url = url; self.kind = kind; self.size = size; self.modified = modified
    }
}

public enum CardSort: String, Sendable, CaseIterable {
    case newestFirst, oldestFirst, name, size

    public var title: String {
        switch self {
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        case .name: "Name"
        case .size: "Size"
        }
    }

    public func apply(_ items: [CardCandidate]) -> [CardCandidate] {
        // Name is the tie-breaker everywhere so the order is stable between runs.
        items.sorted { a, b in
            let byName = a.name.localizedStandardCompare(b.name) == .orderedAscending
            switch self {
            case .newestFirst: return a.modified != b.modified ? a.modified > b.modified : byName
            case .oldestFirst: return a.modified != b.modified ? a.modified < b.modified : byName
            case .name: return byName
            case .size: return a.size != b.size ? a.size > b.size : byName
            }
        }
    }
}

/// Facts about a mounted volume, read by the App from URL resource values.
public struct VolumeFacts: Sendable, Equatable {
    public var url: URL
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isLocal: Bool
    public var isBrowsable: Bool
    /// A mounted .dmg / sparse image (DiskArbitration model "Disk Image"), not a physical device.
    public var isDiskImage: Bool
    public init(url: URL, isInternal: Bool, isRemovable: Bool, isEjectable: Bool, isLocal: Bool = true, isBrowsable: Bool = true, isDiskImage: Bool = false) {
        self.isDiskImage = isDiskImage
        self.url = url; self.isInternal = isInternal; self.isRemovable = isRemovable
        self.isEjectable = isEjectable; self.isLocal = isLocal; self.isBrowsable = isBrowsable
    }

    /// An SD card or external drive, not the boot disk, a network share or an internal partition.
    public var isImportSource: Bool {
        guard isLocal, isBrowsable, !isDiskImage else { return false }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/Volumes/"), path.count > "/Volumes/".count else { return false }
        return isRemovable || isEjectable || !isInternal
    }
}

/// A Windows drive letter, read by the Windows app (GetDriveTypeW, the storage bus from IOCTL_STORAGE_QUERY_PROPERTY).
/// The Windows counterpart of `VolumeFacts`: USB and Thunderbolt SSDs report DRIVE_FIXED, so the bus decides.
public struct DriveFacts: Sendable, Equatable {
    public enum Kind: Sendable { case removable, fixed, other }
    public enum Bus: Sendable { case usb, firewire, sd, mmc, other }
    /// "E:\\".
    public var root: String
    public var kind: Kind
    public var bus: Bus
    /// The drive Windows runs from.
    public var isSystem: Bool
    public init(root: String, kind: Kind, bus: Bus = .other, isSystem: Bool = false) {
        self.root = root; self.kind = kind; self.bus = bus; self.isSystem = isSystem
    }

    /// A card, stick or external disk on USB, FireWire, SD or MMC; never the system drive, an internal disk, a share.
    public var isImportSource: Bool {
        guard !isSystem else { return false }
        switch kind {
        case .removable: return true
        case .fixed: return bus != .other
        case .other: return false
        }
    }
}

/// New drives since the last look (the Mac reacts to new mounts only: what is there at launch is not offered).
public struct DriveArrivals: Sendable {
    public struct Change: Sendable, Equatable {
        public var added: [String]
        public var removed: [String]
        public init(added: [String], removed: [String]) { self.added = added; self.removed = removed }
    }
    private var known: Set<String>
    public init(present: [DriveFacts]) { known = Set(present.map(\.root)) }

    /// `now`: the ready drives. Added = new import sources, removed = drives that went away (in drive order).
    public mutating func update(_ now: [DriveFacts]) -> Change {
        let roots = Set(now.map(\.root))
        let added = now.filter { !known.contains($0.root) && $0.isImportSource }.map(\.root)
        let removed = known.subtracting(roots).sorted()
        known = roots
        return Change(added: added, removed: removed)
    }
}

public enum CardScanner {
    /// Photos and videos below `root`, all subfolders flat. Hidden files (including the `._` copies macOS writes on
    /// FAT cards) and packages are skipped; everything that is neither photo nor video is left out.
    public static func scan(_ root: URL, kinds: Set<CardMediaKind> = Set(CardMediaKind.allCases)) -> [CardCandidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [CardCandidate] = []
        for case let url as URL in e {
            guard let kind = kind(of: url), kinds.contains(kind),
                  let v = FileWalk.Values.read(url, keys: Set(keys)), v.isRegularFile == true else { continue }
            out.append(CardCandidate(url: url, kind: kind, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
        }
        return out
    }

    public static func kind(of url: URL) -> CardMediaKind? {
        switch LibraryItemKind.classifyIfVisible(url) {
        case .video: .video
        case .image: .photo
        default: nil
        }
    }

    /// Destination for a copied file: `folder/name`, or `name 2.ext`, `name 3.ext` when taken.
    public static func uniqueDestination(for name: String, in folder: URL, taken: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appendingPathComponent(name)
        guard taken(first) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}

/// Multi-selection over an ordered list: click, Command/checkbox toggle, Shift range.
public struct CardSelection: Sendable, Equatable {
    public private(set) var ids: Set<String> = []
    public private(set) var anchor: String?
    public init() {}

    public mutating func click(_ id: String, in order: [String], shift: Bool = false, toggle: Bool = false) {
        if shift, let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            let range = order[min(i, j)...max(i, j)]
            if toggle { ids.formUnion(range) } else { ids = Set(range) }
        } else if toggle {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        } else {
            ids = [id]
            anchor = id
        }
    }

    public mutating func selectAll(_ order: [String]) { ids = Set(order); anchor = order.last }
    public mutating func clear() { ids = []; anchor = nil }
    public mutating func deselect(_ remove: Set<String>) {
        ids.subtract(remove)
        if let a = anchor, remove.contains(a) { anchor = ids.first }
    }
    /// Drops ids no longer listed (after a kind switch or rescan).
    public mutating func prune(to order: [String]) {
        ids.formIntersection(order)
        if let a = anchor, !ids.contains(a) { anchor = ids.first }
    }
}

public struct CardCopyResult: Sendable, Equatable {
    public var copied: [URL] = []
    public var failed: [String] = []
    /// Sources whose copy failed or was incomplete.
    public var failedSources: [URL] = []
    /// Sources that were copied completely, in the order of `copied`.
    public var copiedSources: [URL] = []
    public init() {}
}

public enum CardCopier {
    /// Copies each source into `folder` (created if missing) under a unique name. Never throws: failures are listed.
    /// `progress(done, total)` is called before each file.
    public static func copy(_ sources: [URL], to folder: URL, progress: (Int, Int) -> Void = { _, _ in },
                            copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) -> CardCopyResult {
        var result = CardCopyResult()
        let fm = FileManager.default
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            result.failed = sources.map(\.lastPathComponent)
            result.failedSources = sources
            return result
        }
        for (i, src) in sources.enumerated() {
            progress(i, sources.count)
            let target = CardScanner.uniqueDestination(for: src.lastPathComponent, in: folder)
            do {
                try copyItem(src, target)
                // A card pulled mid-copy can leave a short file without an error: verify the size.
                let want = FileWalk.Values.read(URL(fileURLWithPath: src.path), keys: [.fileSizeKey])?.fileSize ?? -1
                let got = FileWalk.Values.read(URL(fileURLWithPath: target.path), keys: [.fileSizeKey])?.fileSize ?? -2
                guard want == got else { try? fm.removeItem(at: target); throw CocoaError(.fileWriteUnknown) }
                result.copied.append(target); result.copiedSources.append(src)
            } catch {
                result.failed.append(src.lastPathComponent); result.failedSources.append(src)
            }
        }
        progress(sources.count, sources.count)
        return result
    }
}

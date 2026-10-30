import Foundation

/// One cached file for `CacheDiskPolicy.evictionPlan`.
public struct CacheEntry: Sendable, Hashable {
    public var id: String
    public var bytes: Int64
    public var lastUse: Date
    public init(id: String, bytes: Int64, lastUse: Date) { self.id = id; self.bytes = bytes; self.lastUse = lastUse }
}

/// Shared disk-space rule for every cache (proxies, previews, waveforms): stop writing when the volume would drop
/// below max(5 GB, min(5 % of its size, 10 GB)) free, and evict least recently used files beyond a size cap.
/// The free-space reader is injectable; unknown space allows the write.
public struct CacheDiskPolicy: Sendable {
    public static let minimumFloorBytes: Int64 = 5 << 30
    public static let floorFraction = 0.05
    /// A 1 TB disk would otherwise demand 50 GB free and block every cache on a normally full Mac.
    public static let maximumFloorBytes: Int64 = 10 << 30

    public typealias Space = @Sendable (URL) -> (free: Int64?, total: Int64?)
    private let space: Space

    public init(space: @escaping Space = CacheDiskPolicy.realSpace) { self.space = space }

    /// The app-wide policy reading the real volume.
    public static let standard = CacheDiskPolicy()

    /// Never blocks (free space unknown): for tests that must not depend on this machine's disk.
    public static let unchecked = CacheDiskPolicy(space: { _ in (nil, nil) })

    public static func floorBytes(volumeBytes: Int64?) -> Int64 {
        max(minimumFloorBytes, min(maximumFloorBytes, Int64(Double(volumeBytes ?? 0) * floorFraction)))
    }

    /// Free and total bytes of the volume holding `url` (nil when unknown). The file need not exist yet: the nearest
    /// existing parent is asked.
    public static func volumeSpace(of url: URL) -> (free: Int64?, total: Int64?) {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        #if canImport(Darwin)
        let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacityForImportantUsage, v?.volumeTotalCapacity.map(Int64.init))
        #else
        let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacity.map(Int64.init), v?.volumeTotalCapacity.map(Int64.init))
        #endif
    }
    public static let realSpace: Space = { volumeSpace(of: $0) }

    public func isBelowFloor(at url: URL) -> Bool { !allowsWrite(bytes: 0, at: url) }

    /// True when writing `bytes` leaves at least the floor free.
    public func allowsWrite(bytes: Int64, at url: URL) -> Bool {
        let s = space(url)
        guard let free = s.free else { return true }
        return free - max(0, bytes) >= Self.floorBytes(volumeBytes: s.total)
    }

    /// IDs to delete (oldest use first) so the rest fits `limitBytes`; `protecting` entries are never chosen.
    public static func evictionPlan(_ entries: [CacheEntry], limitBytes: Int64, protecting: Set<String>) -> [String] {
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var out: [String] = []
        for e in entries.sorted(by: { ($0.lastUse, $0.id) < ($1.lastUse, $1.id) }) where total > limitBytes {
            if protecting.contains(e.id) { continue }
            out.append(e.id); total -= e.bytes
        }
        return out
    }
}

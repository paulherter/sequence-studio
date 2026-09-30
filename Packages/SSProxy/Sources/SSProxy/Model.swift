import CryptoKit
import Foundation
import SSCore

public enum ProxyKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// ProRes 422, source resolution.
    case optimized
    /// ProRes 422 Proxy, 1/2 width and height.
    case proxyHalf
    /// ProRes 422 Proxy, 1/4 width and height.
    case proxyQuarter

    /// Integer divisor applied to width and height relative to the source.
    public var scaleDivisor: Int {
        switch self {
        case .optimized: 1
        case .proxyHalf: 2
        case .proxyQuarter: 4
        }
    }

    /// Codec FourCC of the video track written for this kind.
    public var codecFourCC: String { self == .optimized ? "apcn" : "apco" }
}

public struct ProxyDimensions: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }

    /// Divides by `divisor`, rounding down to even numbers (minimum 2).
    public func scaled(divisor: Int) -> ProxyDimensions {
        func even(_ v: Int) -> Int { max(2, (v / divisor) & ~1) }
        return ProxyDimensions(width: even(width), height: even(height))
    }
}

/// Path-independent identity of a source file: size, mtime and a hash of its first and last 64 KB.
/// Only small chunks are read, so it is cheap for multi-GB files.
public struct SourceFingerprint: Sendable, Hashable, Codable {
    public static let chunkSize = 64 * 1024

    public var size: Int64
    public var modifiedMillis: Int64
    public var headHash: String
    public var tailHash: String

    public init(size: Int64, modifiedMillis: Int64, headHash: String, tailHash: String) {
        self.size = size; self.modifiedMillis = modifiedMillis
        self.headHash = headHash; self.tailHash = tailHash
    }

    /// Stable, file-name safe identifier.
    public var id: String {
        "\(size)-\(modifiedMillis)-\(headHash.prefix(16))\(tailHash.prefix(16))"
    }

    public static func compute(for url: URL) throws -> SourceFingerprint {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let millis = Int64((mtime.timeIntervalSince1970 * 1000).rounded())
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let n = Int64(chunkSize)
        let head = try handle.read(upToCount: chunkSize) ?? Data()
        var tail = Data()
        if size > n {
            try handle.seek(toOffset: UInt64(max(0, size - n)))
            tail = try handle.read(upToCount: chunkSize) ?? Data()
        }
        return SourceFingerprint(size: size, modifiedMillis: millis, headHash: hex(head), tailHash: hex(tail))
    }

    private static func hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProxyRecord: Sendable, Hashable, Codable {
    public var fingerprint: SourceFingerprint
    public var kind: ProxyKind
    /// File name relative to the cache folder.
    public var fileName: String
    public var dimensions: ProxyDimensions
    public var createdAt: Date
    public var sourceDuration: Time

    public init(fingerprint: SourceFingerprint, kind: ProxyKind, fileName: String,
                dimensions: ProxyDimensions, createdAt: Date, sourceDuration: Time) {
        self.fingerprint = fingerprint; self.kind = kind; self.fileName = fileName
        self.dimensions = dimensions; self.createdAt = createdAt; self.sourceDuration = sourceDuration
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `~/Library/Application Support/Sequence Studio/edit-api.json` (mode 0600): how local tools (sqmcp) find the running
/// API. Written while the server runs, removed when it stops.
public struct EditAPIDiscovery: Codable, Sendable, Equatable {
    public var port: UInt16
    public var token: String
    public var pid: Int32

    public init(port: UInt16, token: String, pid: Int32) { self.port = port; self.token = token; self.pid = pid }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sequence Studio/edit-api.json")
    }

    /// Created fresh with `O_CREAT | O_EXCL | O_NOFOLLOW` and mode 0600 (an old file or a planted symlink is unlinked
    /// first, never followed), then verified: a regular file owned by this user with mode exactly 0600.
    public func write(to url: URL = Self.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        try Self.writeOwnerOnly(data, to: url)
    }

#if os(Windows)
    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        // shortcut: plain write, no owner-only ACL yet (the file sits in the user's own AppData); upgrade with SetNamedSecurityInfo.
        try data.write(to: url, options: .atomic)
    }
#else
    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        unlink(url.path)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = false
        defer { close(fd); if !ok { unlink(url.path) } }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.EPERM) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, (st.st_mode & 0o777) == 0o600, st.st_uid == getuid()
        else { throw POSIXError(.EPERM) }
        let written = data.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw POSIXError(.EIO) }
        ok = true
    }
#endif

    public static func remove(at url: URL = Self.defaultURL) { try? FileManager.default.removeItem(at: url) }
}

/// Counts open connections against a cap.
struct ConnectionLimiter {
    let max: Int
    private(set) var open = 0
    init(max: Int) { self.max = max }
    mutating func acquire() -> Bool {
        guard open < max else { return false }
        open += 1
        return true
    }
    mutating func release() { open = Swift.max(open - 1, 0) }
}

import Foundation
#if os(Windows)
import WinSDK
#endif

/// File-system set-up the tests need where the system differs (kept apart: WinSDK also declares `UUID`).
enum TestFileSystem {
    /// Windows makes symlinks only in Developer Mode or as admin (error 1314); tests that need one run where it works.
    static let canMakeSymlinks: Bool = {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sqlinkprobe-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? fm.removeItem(at: dir) }
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return false }
        return (try? fm.createSymbolicLink(at: dir.appendingPathComponent("l"), withDestinationURL: dir)) != nil
    }()

    /// Sets the modification date of a file or folder. On Windows `FileManager.setAttributes` opens the item without
    /// FILE_FLAG_BACKUP_SEMANTICS, so it cannot touch a folder (access denied).
    static func setModificationDate(_ date: Date, of path: String) throws {
        #if os(Windows)
        let handle = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(FILE_WRITE_ATTRIBUTES), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw CocoaError(.fileWriteNoPermission) }
        defer { CloseHandle(handle) }
        // FILETIME counts 100 ns ticks since 1601-01-01.
        let ticks = UInt64((date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000)
        var time = FILETIME(dwLowDateTime: DWORD(ticks & 0xFFFF_FFFF), dwHighDateTime: DWORD(ticks >> 32))
        guard SetFileTime(handle, nil, nil, &time) else { throw CocoaError(.fileWriteNoPermission) }
        #else
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        #endif
    }
}

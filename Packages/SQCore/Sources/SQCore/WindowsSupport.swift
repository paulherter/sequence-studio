#if os(Windows)
import Foundation
import WinSDK

/// Win32 calls used by SQCore. Kept in its own file because WinSDK also declares `UUID`.
enum WindowsProcess {
    static func isAlive(_ pid: Int32) -> Bool {
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else {
            return GetLastError() == DWORD(ERROR_ACCESS_DENIED)
        }
        defer { CloseHandle(handle) }
        var code: DWORD = 0
        return GetExitCodeProcess(handle, &code) && code == DWORD(STILL_ACTIVE)
    }

    static func startTime(of pid: Int32) -> Date? {
        guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return nil }
        defer { CloseHandle(handle) }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(handle, &created, &exited, &kernel, &user) else { return nil }
        // FILETIME counts 100 ns ticks since 1601-01-01.
        let ticks = (UInt64(created.dwHighDateTime) << 32) | UInt64(created.dwLowDateTime)
        return Date(timeIntervalSince1970: TimeInterval(ticks) / 10_000_000 - 11_644_473_600)
    }
}

enum WindowsFile {
    /// Atomic replace of `destination` by `source` (rename(2) fails on Windows when the target exists).
    static func replace(_ source: String, with destination: String) -> Bool {
        source.withCString(encodedAs: UTF16.self) { src in
            destination.withCString(encodedAs: UTF16.self) { dst in
                MoveFileExW(src, dst, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
    }
}
#endif

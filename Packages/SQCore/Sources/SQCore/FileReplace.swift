import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Moves `source` onto `file` in one step: the name `file` never disappears and never shows a partial file.
/// The Mac uses `replaceItemAt`, Windows `MoveFileExW` (corelibs `replaceItemAt` is missing there), Linux rename(2).
public enum FileReplace {
    public static func replace(_ file: URL, withItemAt source: URL, fileManager fm: FileManager = .default) throws {
        #if canImport(Darwin)
        if fm.fileExists(atPath: file.path) {
            _ = try fm.replaceItemAt(file, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: file)
        }
        #elseif os(Windows)
        // A reader that holds the target open for a moment (attribute read, another process) makes MoveFileExW fail
        // with a sharing violation: retry briefly before giving up (about 0.5 s in all).
        for attempt in 0..<20 {
            if WindowsFile.replace(source.path, with: file.path) { return }
            if attempt < 19 { Thread.sleep(forTimeInterval: 0.025) }
        }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        #else
        // swift-corelibs replaceItemAt fails when the target exists; rename(2) replaces atomically.
        guard rename(source.path, file.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
        #endif
    }
}

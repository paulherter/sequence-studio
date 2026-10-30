import Foundation
import os

/// Bookmark data for a media file. Tries a security-scoped bookmark first, then a plain one; a failure of both is
/// logged (a file on a network share used to get no bookmark and no trace).
public enum MediaBookmark {
    private static let log = Logger(subsystem: "app.sequencestudio", category: "MediaBookmark")

    public static func make(for url: URL) -> Data? {
        var firstError: Error?
        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch { firstError = error }
        do {
            return try url.bookmarkData()
        } catch {
            log.error("no bookmark for \(url.path, privacy: .public): scoped \(String(describing: firstError), privacy: .public), plain \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

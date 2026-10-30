import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// "Is there a newer version?" against a configurable address. Default: the GitHub releases API of the public
/// repository; `SQ_UPDATE_URL` (environment) or the `sq.updateFeedURL` default replaces it, and an empty value switches
/// the check off (it never touches the network and the UI says so).
///
/// The address returns either our small document `{"version": "1.2.0", "url": "https://...", "notes": "optional"}` or a
/// GitHub release (`tag_name`, `html_url`, `body`, `assets`); for a GitHub release the download is the installer asset
/// of this system (`.exe` on Windows, `.dmg` on the Mac), else the release page.
public enum UpdateCheck {
    public static let defaultFeedURL = "https://api.github.com/repos/paulherter/sequence-studio/releases/latest"

    /// The address in use: `SQ_UPDATE_URL`, else the `sq.updateFeedURL` default, else `defaultFeedURL`. Empty = inert.
    public static var feedURL: String {
        if let e = ProcessInfo.processInfo.environment["SQ_UPDATE_URL"] { return e }
        return UserDefaults.standard.string(forKey: "sq.updateFeedURL") ?? defaultFeedURL
    }

    #if os(Windows)
    static let installerSuffix = ".exe"
    #else
    static let installerSuffix = ".dmg"
    #endif

    public struct Release: Sendable, Equatable, Decodable {
        public var version: String
        public var url: String
        public var notes: String?
    }

    public enum Outcome: Sendable, Equatable {
        case notConfigured
        case upToDate
        case available(Release)
        case failed
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable { var name: String; var browser_download_url: String }
        var tag_name: String
        var html_url: String
        var body: String?
        var assets: [Asset]?
    }

    /// A GitHub release as our `Release`; the download is the installer asset when there is one.
    static func githubRelease(from data: Data, suffix: String = installerSuffix) -> Release? {
        guard let g = try? JSONDecoder().decode(GitHubRelease.self, from: data) else { return nil }
        let asset = g.assets?.first { $0.name.lowercased().hasSuffix(suffix) }?.browser_download_url
        let notes = g.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Release(version: g.tag_name, url: asset ?? g.html_url, notes: (notes?.isEmpty ?? true) ? nil : notes)
    }

    public static func release(from data: Data) -> Release? {
        guard let r = (try? JSONDecoder().decode(Release.self, from: data)) ?? githubRelease(from: data),
              !parts(r.version).isEmpty, URL(string: r.url)?.scheme == "https" else { return nil }
        return r
    }

    /// Dotted numeric version parts; a leading "v" and a suffix after "-" or "+" are ignored. Empty when not numeric.
    static func parts(_ v: String) -> [Int] {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("v") { s.removeFirst() }
        if let i = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<i]) }
        let nums = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        return nums.contains(nil) ? [] : nums.compactMap { $0 }
    }

    /// True when `remote` is a higher version than `local`. A version that cannot be read is never newer.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = parts(remote), l = parts(local)
        guard !r.isEmpty, !l.isEmpty else { return false }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    public static func outcome(data: Data, localVersion: String) -> Outcome {
        guard let r = release(from: data) else { return .failed }
        return isNewer(r.version, than: localVersion) ? .available(r) : .upToDate
    }

    /// Fetches `feed` (default: `feedURL`) and compares it with `localVersion`.
    public static func check(localVersion: String, feed: String = feedURL,
                             fetch: @Sendable (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }) async -> Outcome {
        guard let url = URL(string: feed), url.scheme == "https" else { return .notConfigured }
        guard let data = try? await fetch(url) else { return .failed }
        return outcome(data: data, localVersion: localVersion)
    }
}

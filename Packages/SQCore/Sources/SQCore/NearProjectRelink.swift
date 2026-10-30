import Foundation

/// Media of a project that was copied to another machine or folder (a Mac project opened on Windows, a moved project
/// folder): the stored paths point at the old place. On open, files that sit next to the project file are linked again:
/// 1. the stored path's trailing part below the project's folder, longest first
///    (`/Users/…/Oppo/Files/Imported/C2171.MP4` -> `<folder>/Files/Imported/C2171.MP4`), POSIX or Windows stored paths;
/// 2. else the same file name below the folder (`depth` levels) with the recorded size (`RelinkPlanner`: ties by the
///    recorded date and the stored folders, never a guess).
/// A recorded size of 0 (unknown) accepts the name. File system only: call off the main thread.
// shortcut: name + size only, no probed duration (a probe per candidate is slow); upgrade when same-name, same-size
// files of another length turn up in real projects.
public enum NearProjectRelink {
    /// Folder levels searched by name below the project's folder.
    public static let depth = 5

    /// Media id -> found path for the `missing` items that have a file near `folder` (the project file's folder).
    public static func plan(missing: [MediaRef], folder: URL, maxTrailing: Int = 8) -> [MediaRef.ID: String] {
        guard !missing.isEmpty else { return [:] }
        var plan: [MediaRef.ID: String] = [:]
        var rest: [MediaRef] = []
        for m in missing {
            if let p = trailingMatch(m.path, in: folder, size: m.fingerprint.size, maxTrailing: maxTrailing) { plan[m.id] = p } else { rest.append(m) }
        }
        guard !rest.isEmpty else { return plan }
        let wanted = Set(rest.map { MediaPathResolver.fileName(of: $0.path).lowercased() })
        let found = RelinkScanner.scan(roots: [(folder, depth)], named: wanted)
        plan.merge(RelinkPlanner.match(missing: rest, candidates: found).plan) { a, _ in a }
        return plan
    }

    /// The longest trailing part of `storedPath` (up to `maxTrailing` components, the file name at least) that is a file
    /// below `folder` with the recorded `size` (0 = unknown, any size).
    public static func trailingMatch(_ storedPath: String, in folder: URL, size: Int64, maxTrailing: Int = 8) -> String? {
        let parts = storedPath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init).filter { !$0.hasSuffix(":") }
        guard !parts.isEmpty else { return nil }
        for n in stride(from: min(maxTrailing, parts.count), through: 1, by: -1) {
            let url = parts.suffix(n).reduce(folder) { $0.appendingPathComponent($1) }.standardizedFileURL
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue else { continue }
            if size > 0, (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value != size { continue }
            return url.path
        }
        return nil
    }
}

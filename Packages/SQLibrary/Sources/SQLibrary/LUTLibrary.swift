import Foundation

/// One LUT of the library.
public struct LUTEntry: Sendable, Equatable, Identifiable {
    public var fileName: String
    public var path: String
    public var isFavourite: Bool
    public var id: String { fileName }
    /// Display name: file name without extension.
    public var name: String { (fileName as NSString).deletingPathExtension }
}

/// The user's LUT collection: `.cube` files copied into one directory (App Support), plus starred favorites.
/// Favorites are stored next to the files and always list first.
public struct LUTLibrary: Sendable {
    public static let favouritesFileName = "favourites.json"
    public let directory: URL
    private var favourites: Set<String>
    /// Set when favourites.json was unreadable; the bad file was moved aside (favourites.json.corrupt-*), not overwritten.
    public private(set) var loadError: String?

    public init(directory: URL) {
        self.directory = directory
        let url = directory.appendingPathComponent(Self.favouritesFileName)
        do {
            favourites = try FavouriteFile.load(url)
        } catch {
            favourites = []
            loadError = "Favorites could not be read (\(error)); the old file was kept as a backup."
            try? JSONFileIO.backupCorrupt(url)
        }
    }

    /// Drops stars of LUT files that no longer exist. Returns true if anything changed.
    @discardableResult
    public mutating func pruneMissingFavourites() throws -> Bool {
        let missing = favourites.filter { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        guard !missing.isEmpty else { return false }
        favourites.subtract(missing)
        try saveFavourites()
        return true
    }

    /// `~/Library/Application Support/<app>/LUTs`.
    public static func defaultDirectory(appName: String = "Sequence Studio") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("LUTs", isDirectory: true)
    }

    public func isFavourite(_ fileName: String) -> Bool { favourites.contains(fileName) }

    /// Favorites first, then the rest; each group in natural, case-insensitive name order.
    public func entries() -> [LUTEntry] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".cube") }
        let all = names.map {
            LUTEntry(fileName: $0, path: directory.appendingPathComponent($0).path, isFavourite: favourites.contains($0))
        }
        let byName: (LUTEntry, LUTEntry) -> Bool = {
            let r = $0.fileName.localizedStandardCompare($1.fileName)
            return r == .orderedSame ? $0.fileName < $1.fileName : r == .orderedAscending
        }
        return all.filter(\.isFavourite).sorted(by: byName) + all.filter { !$0.isFavourite }.sorted(by: byName)
    }

    public struct ImportResult: Sendable {
        public var added: [LUTEntry] = []
        public var failures: [(url: URL, message: String)] = []
    }

    /// Copies the `.cube` files among `urls` into the library (never moves or edits the originals);
    /// name clashes get a numeric suffix. A file that fails to copy is reported and does not stop the others.
    @discardableResult
    public mutating func importLUTs(from urls: [URL]) -> ImportResult {
        let fm = FileManager.default
        var result = ImportResult()
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            result.failures = urls.map { ($0, "\(error)") }
            return result
        }
        for url in urls where url.pathExtension.lowercased() == "cube" {
            let stem = url.deletingPathExtension().lastPathComponent
            var name = "\(stem).cube", n = 2
            while fm.fileExists(atPath: directory.appendingPathComponent(name).path) { name = "\(stem) \(n).cube"; n += 1 }
            let dest = directory.appendingPathComponent(name)
            do { try fm.copyItem(at: url, to: dest) } catch { result.failures.append((url, "\(error)")); continue }
            result.added.append(LUTEntry(fileName: name, path: dest.path, isFavourite: false))
        }
        return result
    }

    /// Stars or unstars a LUT; returns the new state.
    @discardableResult
    public mutating func toggleFavourite(_ fileName: String) throws -> Bool {
        let now = !favourites.contains(fileName)
        if now { favourites.insert(fileName) } else { favourites.remove(fileName) }
        try saveFavourites()
        return now
    }

    /// Deletes the library copy (and its star).
    public mutating func remove(_ fileName: String) throws {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        if favourites.remove(fileName) != nil { try saveFavourites() }
    }

    private func saveFavourites() throws {
        try JSONFileIO.writeAtomically(FavouriteFile(formatVersion: 1, items: favourites.sorted()),
                                       to: directory.appendingPathComponent(Self.favouritesFileName))
    }

    private struct FavouriteFile: Codable {
        var formatVersion: Int
        var items: [String]
        static func load(_ url: URL) throws -> Set<String> {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return Set(try JSONDecoder().decode(FavouriteFile.self, from: Data(contentsOf: url)).items)
        }
    }
}

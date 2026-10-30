import Foundation

/// What happens to a file when it is imported: copied into the project's `Files/` folder (default), moved there
/// (original removed only after a verified copy), or left where it is.
public enum ImportMode: String, Codable, Sendable, CaseIterable {
    case copy, move, leave
}

/// One file to bring into the project's `Files/` folder.
public struct CollectItem: Sendable, Hashable {
    public var id: MediaRef.ID
    public var source: String
    public var destination: String
}

/// Pure planning for the project folder (`<Name>/<Name>.sqproj` + `<Name>/Files/`) and for collecting media into it.
/// No file access except the injected `exists` closure, so tests need no disk.
public enum MediaManagement {
    public static let filesFolderName = "Files"

    /// Project folder layout for a new project named `name` inside `parent`.
    public struct Layout: Sendable, Equatable {
        public var folder: URL
        public var projectFile: URL
        public var filesFolder: URL
    }

    public static func layout(name: String, in parent: URL) -> Layout {
        let clean = sanitized(name)
        let folder = parent.appendingPathComponent(clean, isDirectory: true)
        return Layout(folder: folder,
                      projectFile: folder.appendingPathComponent(clean).appendingPathExtension(ProjectFile.fileExtension),
                      filesFolder: folder.appendingPathComponent(filesFolderName, isDirectory: true))
    }

    public static let exportsFolderName = "Exports"

    /// Where Quick Export writes for a saved project: `Exports/` next to the project file.
    public static func exportsFolder(forProjectAt url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(exportsFolderName, isDirectory: true)
    }

    /// First free folder name: "Reel", "Reel 2", ... (`exists` is the disk check, injected so tests need none).
    public static func freeFolderName(_ base: String, exists: (String) -> Bool) -> String {
        let clean = sanitized(base)
        var name = clean
        var n = 1
        while exists(name) { n += 1; name = "\(clean) \(n)" }
        return name
    }

    /// True for `<Name>/<Name>.sqproj`: the package sits in a folder of the same name (a project folder).
    public static func isProjectFolderLayout(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().lastPathComponent == stem
    }

    /// The media folder of a project file: `Files/` next to the package in a project folder, otherwise
    /// `<Name> Files/` next to it (older projects that live loose in a folder never share a bare `Files/`).
    public static func filesFolder(forProjectAt url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        if isProjectFolderLayout(url) { return dir.appendingPathComponent(filesFolderName, isDirectory: true) }
        return dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " " + filesFolderName, isDirectory: true)
    }

    /// Mode that applies on import for a project at `url`: project folders default to copy, loose older projects
    /// only import into a folder when their mode was chosen explicitly.
    public static func importMode(of project: Project, projectURL url: URL?) -> ImportMode {
        guard let url else { return .leave }
        return isProjectFolderLayout(url) ? project.effectiveImportMode : (project.importMode ?? .leave)
    }

    /// File-system safe folder name: no path separators or colons, no leading dots, never empty.
    public static func sanitized(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Untitled" : s
    }

    /// True when `path` lies inside `folder` (component-wise, so `/a/Files2/x` is not inside `/a/Files`).
    /// Symlinks are resolved on both sides (`/var` = `/private/var`), and names compare case-insensitively unless
    /// the folder's volume is case-sensitive: a wrong "inside" only skips a copy, a wrong "outside" could lose data.
    public static func isInside(_ path: String, folder: URL) -> Bool {
        let f = resolved(folder)
        let caseSensitive = (try? (existingAncestor(f)).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        func norm(_ u: URL) -> [String] { u.pathComponents.map { caseSensitive ? $0 : $0.lowercased() } }
        let fc = norm(f)
        let pc = norm(resolved(URL(fileURLWithPath: path)))
        return pc.count > fc.count && Array(pc.prefix(fc.count)) == fc
    }

    /// Symlinks resolved for the part that exists; a missing tail is appended unchanged.
    private static func resolved(_ url: URL) -> URL {
        let base = existingAncestor(url.standardizedFileURL)
        var out = base.resolvingSymlinksInPath()
        let tail = url.standardizedFileURL.pathComponents.dropFirst(base.pathComponents.count)
        for c in tail { out.appendPathComponent(c) }
        return out.standardizedFileURL
    }

    private static func existingAncestor(_ url: URL) -> URL {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        return u
    }

    /// `name`, or `name 2.ext`, `name 3.ext` … the first that `taken` does not claim (called with the real-case candidate; callers fold case themselves).
    public static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ns = NSString(string: name)
        let ext = ns.pathExtension, stem = ns.deletingPathExtension
        var n = 2
        while true {
            let c = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken(c) { return c }
            n += 1
        }
    }

    /// Media that must be copied to bring the project into `files`: skips media already inside it and media whose
    /// source is gone (`exists` false). Destination names are unique among each other and against `existing`
    /// (lowercased names already in `files`). Media sharing one source path share one destination.
    public static func collectPlan(media: [MediaRef], into files: URL, existing: Set<String>,
                                   exists: (String) -> Bool) -> [CollectItem] {
        var used = existing
        var bySource: [String: String] = [:]
        var out: [CollectItem] = []
        for m in media {
            guard !isInside(m.path, folder: files), exists(m.path) else { continue }
            let dest: String
            if let d = bySource[m.path] { dest = d } else {
                let name = uniqueName(NSString(string: m.path).lastPathComponent) { used.contains($0.lowercased()) }
                used.insert(name.lowercased())
                dest = files.appendingPathComponent(name).path
                bySource[m.path] = dest
            }
            out.append(CollectItem(id: m.id, source: m.path, destination: dest))
        }
        return out
    }
}

extension Project {
    /// Import mode of this project; nil (older files) behaves as `.copy`.
    public var effectiveImportMode: ImportMode { importMode ?? .copy }

    /// Re-points media at their copies in `Files/` after a collect: same single mutation as a relink; the
    /// fingerprint is kept (the copy is verified identical), the stale bookmark is dropped.
    public mutating func repoint(_ items: [CollectItem]) {
        relink(Dictionary(items.map { ($0.id, $0.destination) }, uniquingKeysWith: { a, _ in a }))
    }
}

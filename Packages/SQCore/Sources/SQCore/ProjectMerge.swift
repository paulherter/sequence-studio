import Foundation

/// Importing another Sequence Studio project into the current one (File > Import Project, drop a .sqproj on the Project
/// panel): everything of the other project lands in one new bin, the current sequence is untouched.
public enum ProjectMerge {
    /// Ids that are part of the app, not of a project (built-in easing curves, keystone presets, anchored-animation keys).
    /// They are written into project files and must keep their value when a project's ids are replaced.
    static func isFixedID(_ s: String) -> Bool {
        let u = s.uppercased()
        return u.hasPrefix("00000000-0000-0000-0000-") || u.hasPrefix("6B657973-746F-6E65-")
    }

    /// Reads the project package at `url` through the normal path (migrations included).
    public static func load(from url: URL) throws -> Project {
        try ProjectFile.read(from: url)
    }

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

    /// `project` with every identifier replaced by a fresh one (media, sequences, clips, bins, links, groups, effects,
    /// keyframes, marks), consistently, so references between the parts still hold. `keeping` maps an old id to the id it
    /// must become instead (media that already exists in the destination).
    static func remapIDs(in project: Project, keeping: [UUID: UUID]) -> Project? {
        guard let data = try? ProjectFile.encoder().encode(project) else { return nil }
        let ns = NSString(string: String(decoding: data, as: UTF8.self))
        var table: [String: String] = [:]
        for (k, v) in keeping { table[k.uuidString.uppercased()] = v.uuidString }
        var out = ""
        var last = 0
        for m in uuidPattern.matches(in: String(ns), range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let id = ns.substring(with: m.range)
            if isFixedID(id) {
                out += id
            } else {
                let key = id.uppercased()
                if let n = table[key] {
                    out += n
                } else {
                    let n = UUID().uuidString
                    table[key] = n
                    out += n
                }
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return try? ProjectFile.decoder().decode(Project.self, from: Data(out.utf8))
    }

    /// Plain-language text for a failed project import.
    public static func message(for error: Error, fileName: String) -> (title: String, detail: String) {
        let title = "Could not import “\(fileName)”"
        switch error as? ProjectFileError {
        case .missing?:
            return (title, "There is no project inside “\(fileName)”. Choose a .\(ProjectFile.fileExtension) project made by Sequence Studio.")
        case .corrupt?:
            return (title, "“\(fileName)” is damaged and cannot be read.")
        case .newerVersion?:
            return (title, "“\(fileName)” was saved by a newer version of Sequence Studio. Update the app to import it.")
        case nil:
            return (title, "“\(fileName)” could not be read. Check that the file is there and that you have permission to read it.")
        }
    }
}

extension Project {
    /// Adds everything of `other` (media, sequences with their clips, nested sequences, bins, marks) under one new bin
    /// named `binName` (default: the other project's name) inside `dest` (default: the root bin) and returns that bin.
    /// All ids are replaced so nothing collides, also when the same project is imported twice. Media whose path is
    /// already in this project reuses the existing item. Relative media paths are resolved against `sourceFolder`
    /// (the other project's folder). The active sequence, the format and every other setting stay as they are.
    @discardableResult
    public mutating func merge(_ other: Project, binName: String? = nil, into dest: Bin.ID? = nil,
                               sourceFolder: URL? = nil) -> Bin.ID? {
        let target = dest ?? rootBin.id
        guard rootBin.bin(target) != nil else { return nil }
        var src = other
        if let sourceFolder {
            for i in src.media.indices where !LocalPath.isAbsolute(src.media[i].path) && !src.media[i].path.contains("\\") {
                src.media[i].path = sourceFolder.appendingPathComponent(src.media[i].path).standardizedFileURL.path
            }
        }
        var existing: [UUID: UUID] = [:]   // old id of a media item -> the id already here
        var byPath: [String: UUID] = [:]
        for m in media where byPath[m.path] == nil { byPath[m.path] = m.id }
        for m in src.media { if let id = byPath[m.path] { existing[m.id] = id } }

        // A project that cannot be re-encoded is not merged: reusing its ids would collide with ours.
        guard var fresh = ProjectMerge.remapIDs(in: src, keeping: existing) else { return nil }
        let reused = Set(existing.values)
        let have = Set(media.map(\.id))
        let newMedia = fresh.media.filter { !have.contains($0.id) }
        fresh.rootBin.prune { ref in
            if case .media(let id) = ref { return !reused.contains(id) }
            return true
        }
        media.append(contentsOf: newMedia)
        timelines.append(contentsOf: fresh.timelines)
        for m in newMedia { if let marks = fresh.sourceMarks[m.id] { sourceMarks[m.id] = marks } }
        var bin = Bin(name: binName ?? other.name, children: fresh.rootBin.children)
        if bin.name.trimmingCharacters(in: .whitespaces).isEmpty { bin.name = "Imported Project" }
        rootBin.modify(target) { $0.children.append(.bin(bin)) }
        normalizeBins()
        return bin.id
    }
}
